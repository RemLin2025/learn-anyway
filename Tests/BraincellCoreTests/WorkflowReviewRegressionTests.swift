import Testing
import Foundation
import GRDB
@testable import BraincellCore

/// Regressions found in the independent Workflow V2 review. Fixtures are synthetic; models are scripted.
extension AgentTests {
    /// A → B → A: reverting a document to earlier content must bring the earlier analysis back, not leave it permanently "stale" and hidden.
    @Test func revertedDocumentContentReactivatesItsCachedAnalysis() async throws {
        let calls = LockedBox<Int>(0)
        let (e, c, d) = try await bankEnv { _, _ in calls.withLock { $0 += 1 }; return self.analysisJSON([Self.srcQ("Q1")]) }
        let svc = SourceAnalysisService(db: e.db, gateway: e.ctx.gateway)
        _ = try await svc.analyze(d)
        let n = calls.value
        var b = d; b.sha256 = "content-B"; try e.db.write { try b.update($0) }
        _ = try await svc.analyze(b)
        var a = b; a.sha256 = d.sha256; try e.db.write { try a.update($0) }
        let out = try await svc.analyze(a)
        guard case .cached = out else { Issue.record("expected cached, got \(out)"); return }
        #expect(try svc.sourceQuestions(courseId: c.id, documentIds: [d.id]).count == 1)      // visible again
        #expect(try svc.summary(documentId: d.id)?.status == "complete")
        #expect(calls.value > n)                                                              // only B's own windows were new calls
        let afterB = calls.value
        _ = try await svc.analyze(a)
        #expect(calls.value == afterB)
    }

    /// Two overlapping analyze() calls for the same unchanged document must not send the same window twice.
    @Test func concurrentAnalysisOfOneDocumentSendsEachWindowOnce() async throws {
        let calls = LockedBox<Int>(0)
        let (e, _, d) = try await bankEnv { _, _ in calls.withLock { $0 += 1 }; Thread.sleep(forTimeInterval: 0.05); return self.analysisJSON([Self.srcQ("Q1")]) }
        let svc = SourceAnalysisService(db: e.db, gateway: e.ctx.gateway)
        async let x = svc.analyze(d), y = svc.analyze(d)
        _ = try await (x, y)
        let windows = try e.db.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM source_analysis_windows") } ?? 0
        #expect(calls.value == windows)
    }

    static let bigChunks = (0..<6).map { String(repeating: Character(UnicodeScalar(97 + $0)!), count: 5000) }   // several windows

    /// One of two overlapping callers is cancelled: the other still gets the full result and each window is sent once.
    @Test func cancellingOneSharedCallerDoesNotInterruptTheOther() async throws {
        let calls = LockedBox<Int>(0)
        let (e, _, d) = try await bankEnv(chunks: Self.bigChunks) { _, _ in calls.withLock { $0 += 1 }; Thread.sleep(forTimeInterval: 0.05); return self.analysisJSON([Self.srcQ("Q\(calls.value)")]) }
        let svc = SourceAnalysisService(db: e.db, gateway: e.ctx.gateway)
        let a = Task { try await svc.analyze(d) }
        let b = Task { try await svc.analyze(d) }
        try await Task.sleep(nanoseconds: 80_000_000)
        a.cancel()
        await #expect(throws: CancellationError.self) { _ = try await a.value }
        let out = try await b.value
        guard case .analyzed = out else { Issue.record("expected analyzed, got \(out)"); return }
        let windows = try e.db.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM source_analysis_windows WHERE status = 'done'") } ?? 0
        #expect(windows > 1 && calls.value == windows)
    }

    /// The only caller is cancelled: the work stops, finished windows stay stored, and a retry sends only what is missing.
    @Test func cancellingTheLastCallerStopsWorkAndRetryResumes() async throws {
        let calls = LockedBox<Int>(0)
        let (e, _, d) = try await bankEnv(chunks: Self.bigChunks) { _, _ in calls.withLock { $0 += 1 }; Thread.sleep(forTimeInterval: 0.1); return self.analysisJSON([Self.srcQ("Q\(calls.value)")]) }
        let svc = SourceAnalysisService(db: e.db, gateway: e.ctx.gateway)
        let t = Task { try await svc.analyze(d) }
        while calls.value < 2 { try await Task.sleep(nanoseconds: 10_000_000) }              // first window is stored, second is in flight
        t.cancel()
        await #expect(throws: CancellationError.self) { _ = try await t.value }
        try await Task.sleep(nanoseconds: 400_000_000)
        let stopped = calls.value
        try await Task.sleep(nanoseconds: 300_000_000)
        #expect(calls.value == stopped)                                                       // nobody is waiting, nothing keeps running
        let total = try e.db.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM source_analysis_windows") } ?? 0
        let done = try e.db.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM source_analysis_windows WHERE status = 'done'") } ?? 0
        #expect(done >= 1 && done < total)                                                    // partial progress kept
        let out = try await svc.analyze(d)
        guard case .analyzed = out else { Issue.record("expected analyzed, got \(out)"); return }
        #expect(calls.value - stopped == total - done)                                        // only the missing windows were sent
    }

    /// Same content hash, different extracted chunks: a new analysis over the new layout, old one retired, nothing skipped, no crash.
    @Test func reExtractionWithTheSameHashStartsAFreshAnalysis() async throws {
        let calls = LockedBox<Int>(0)
        let (e, _, d) = try await bankEnv(chunks: Self.bigChunks) { _, _ in calls.withLock { $0 += 1 }; return self.analysisJSON([Self.srcQ("Q1")]) }
        let svc = SourceAnalysisService(db: e.db, gateway: e.ctx.gateway)
        guard case .analyzed(let first) = try await svc.analyze(d) else { Issue.record("first run"); return }
        try e.db.write { try $0.execute(sql: "DELETE FROM document_chunks WHERE documentId = ? AND ordinal >= 2", arguments: [d.id]) }   // re-extraction produced fewer chunks
        let before = calls.value
        guard case .analyzed(let second) = try await svc.analyze(d) else { Issue.record("second run should analyze, not reuse"); return }
        #expect(second != first && calls.value > before)
        #expect(try e.db.read { try String.fetchOne($0, sql: "SELECT status FROM source_analyses WHERE id = ?", arguments: [first]) } == "stale")
        let maxTo = try e.db.read { try Int.fetchOne($0, sql: "SELECT MAX(chunkTo) FROM source_analysis_windows WHERE analysisId = ?", arguments: [second]) } ?? 99
        #expect(maxTo == 1)
    }

    /// A stored window pointing past the chunk list (corruption or an old row) is reported as failed, never skipped or crashed on.
    @Test func outOfRangeWindowsAreReportedAsFailed() async throws {
        let (e, _, d) = try await bankEnv { _, _ in self.analysisJSON([Self.srcQ("Q1")]) }
        let svc = SourceAnalysisService(db: e.db, gateway: e.ctx.gateway)
        guard case .analyzed(let id) = try await svc.analyze(d) else { Issue.record("first run"); return }
        try e.db.write {
            try $0.execute(sql: "UPDATE source_analysis_windows SET status = 'pending', chunkTo = 99 WHERE analysisId = ?", arguments: [id])
            try $0.execute(sql: "UPDATE source_analyses SET status = 'partial' WHERE id = ?", arguments: [id])
        }
        let out = try await svc.analyze(d)
        guard case .partial(_, let failed) = out else { Issue.record("expected partial, got \(out)"); return }
        #expect(failed >= 1)
    }
}

extension AgentTests {
    /// Analyses made before the chunk layout joined the cache key are adopted when provably identical, and redone when not.
    @Test func legacyAnalysesAreReusedOnlyWhenTheirStoredRequestsMatchTheCurrentText() async throws {
        let calls = LockedBox<Int>(0)
        let (e, _, d) = try await bankEnv(chunks: Self.bigChunks) { _, _ in calls.withLock { $0 += 1 }; return self.analysisJSON([Self.srcQ("Q1")]) }
        let svc = SourceAnalysisService(db: e.db, gateway: e.ctx.gateway)
        guard case .analyzed(let id) = try await svc.analyze(d) else { Issue.record("first run"); return }
        let n = calls.value
        // pretend it was created by the previous version: bare config hash
        try e.db.write { try $0.execute(sql: "UPDATE source_analyses SET configHash = ? WHERE id = ?", arguments: [SourceAnalysisService.configHash(), id]) }
        #expect(try await svc.analyze(d) == .cached(id) && calls.value == n)                  // identical text: adopted, no model call
        // same hash and window plan, but the extracted text differs: not provably the same work, so it is analyzed again
        try e.db.write {
            try $0.execute(sql: "UPDATE source_analyses SET configHash = ? WHERE id = ?", arguments: [SourceAnalysisService.configHash(), id])
            try $0.execute(sql: "UPDATE document_chunks SET text = text || ' (re-extracted)' WHERE documentId = ? AND ordinal = 0", arguments: [d.id])
        }
        guard case .analyzed(let id2) = try await svc.analyze(d) else { Issue.record("expected a new analysis"); return }
        #expect(id2 != id && calls.value > n)
    }
}

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
}

import Testing
import Foundation
import GRDB
@testable import BraincellCore

/// Phase 1: assessment-aware passage selection. Synthetic material only.
extension AgentTests {
    func link(_ e: E, _ d: Document, _ a: Assessment) throws { try e.db.write { try $0.execute(sql: "INSERT INTO document_assessments (documentId, assessmentId) VALUES (?,?)", arguments: [d.id, a.id]) } }

    @Test func twoAssessmentsOverTheSameDocumentsSelectDifferentExcerpts() async throws {
        let e = try await env { _, _, _ in "ok" }
        let c = try e.ctx.courses.createCourse(name: "STOR435")
        let notes = try insertDoc(e, c, name: "notes.pdf", status: .ok, pages: 4)
        try insertChunk(e, notes, 0, page: 1, "GEOMETRIC-PASSAGE: the geometric distribution counts trials until the first success.")
        try insertChunk(e, notes, 1, page: 2, "NORMAL-PASSAGE: the normal distribution is symmetric about its mean.")
        try insertChunk(e, notes, 2, page: 3, "PREREQ-PASSAGE: review of sums, series and conditional probability notation.")
        let m1 = try e.ctx.courses.addAssessment(courseId: c.id, name: "Midterm 1"), m2 = try e.ctx.courses.addAssessment(courseId: c.id, name: "Midterm 2")
        _ = try e.ctx.courses.addSkill(courseId: c.id, name: "Geometric distributions"); _ = try e.ctx.courses.addSkill(courseId: c.id, name: "Normal distributions")
        for (a, inc, exc) in [(m1, "Geometric distributions", "Normal distributions"), (m2, "Normal distributions", "Geometric distributions")] {
            var cfg = AssessmentConfig(); cfg.scopeIncludes = [inc]; cfg.scopeExcludes = [exc]; try AssessmentService(db: e.db).setConfig(cfg, assessmentId: a.id)
            try link(e, notes, a)
        }
        func prompt(_ a: Assessment) throws -> (String, SelectionLog) {
            let t = try e.ctx.ai.createGenerationTask(courseId: c.id, assessmentId: a.id, params: GenerationParams(count: 2))
            let b = try e.ctx.ai.batches(taskId: t.id)[0]
            let p = try e.ctx.ai.prepare(batchId: b.id).singlePrompt
            return (p, try #require(try e.ctx.ai.selectionLog(batchId: b.id)))
        }
        let (p1, log1) = try prompt(m1), (p2, log2) = try prompt(m2)
        #expect(p1.contains("GEOMETRIC-PASSAGE") && !p1.contains("NORMAL-PASSAGE"))
        #expect(p2.contains("NORMAL-PASSAGE") && !p2.contains("GEOMETRIC-PASSAGE"))
        #expect(p1.contains("PREREQ-PASSAGE") && p2.contains("PREREQ-PASSAGE"))                       // general prerequisite text is not dropped for lacking a keyword
        let g = try #require(log1.records.first { $0.page == 1 })
        #expect(g.basis == .confirmed && g.linked && g.reasons.contains { $0.contains("stated scope") })    // linked material is confirmed; the reason is recorded
        #expect(log1.skipped.contains { $0.contains("p.2") && $0.contains("excluded") } && log2.skipped.contains { $0.contains("p.1") })
        let pre = try #require(log1.records.first { $0.page == 3 })
        #expect(pre.reasons.contains { $0.contains("general background") })
    }

    @Test func relevantPassagesBeatEarlierIrrelevantOnesEvenInLinkedMaterial() {
        func chunk(_ i: Int, _ t: String) -> DocumentChunk { DocumentChunk(id: UUID(), documentId: UUID(), ordinal: i, pageNumber: i + 1, text: t, isLowContent: false) }
        let doc = AssessmentSelector.Doc(id: UUID(), title: "d", chunks: [chunk(0, String(repeating: "x", count: 500)), chunk(1, "Joint distributions " + String(repeating: "y", count: 480))], linked: true)
        let r = AssessmentSelector.select(.init(docs: [doc], includes: ["Joint distributions"], includeBasis: .userProvided, excludes: [], topics: [], sources: [], assessmentName: "A"), budget: 600)
        #expect(r.records.first?.ordinal == 1 && r.records.count >= 1 && r.extracts.first?.text.hasPrefix("Joint") == true)
    }

    @Test func analyzedPracticeProblemsOutrankPlainTextAndNoWeightsAreInvented() {
        let docId = UUID()
        func chunk(_ i: Int, _ t: String) -> DocumentChunk { DocumentChunk(id: UUID(), documentId: docId, ordinal: i, pageNumber: i + 1, text: t, isLowContent: false) }
        var p = SourceQuestionPayload(locator: "Q7"); p.pages = [2]; p.topics = ["Covariance"]; p.solution = "Use Cov = E[XY] - E[X]E[Y]."
        let src = SourceQuestionRow(id: UUID(), analysisId: UUID(), documentId: docId, documentTitle: "bank", payload: p)
        let doc = AssessmentSelector.Doc(id: docId, title: "bank", chunks: [chunk(0, String(repeating: "a", count: 400)), chunk(1, String(repeating: "b", count: 400))], linked: false)
        let r = AssessmentSelector.select(.init(docs: [doc], includes: [], includeBasis: .userProvided, excludes: [], topics: ["Covariance"], sources: [src], assessmentName: "A"), budget: 450)
        #expect(r.records.count == 1 && r.records[0].page == 2 && r.records[0].reasons.contains { $0.contains("Q7") && $0.contains("worked solution") })
        #expect(r.records[0].basis == .inferred)                                                       // unlinked, unstated scope: inferred, not confirmed
        #expect(r.limitations.contains { $0.contains("no confirmed scope") })
    }
}

import Testing
import Foundation
import GRDB
@testable import BraincellCore

/// Exam simulation (SYNTHETIC STOR435-like setup: 19 questions, 75 minutes, 1 point each, single choice — user-provided settings).
@Suite struct ExamSimulationTests {
    final class Clock: @unchecked Sendable { private let l = NSLock(); private var t: Date; init(_ t: Date) { self.t = t }; var now: Date { l.withLock { t } }; func advance(_ s: Double) { l.withLock { t = t.addingTimeInterval(s) } } }

    func seed(_ db: AppDatabase, questions: Int, configure: Bool = true, count: Int = 19) throws -> (Course, Assessment) {
        let cs = CourseService(db: db); let c = try cs.createCourse(name: "STOR435"); let a = try cs.addAssessment(courseId: c.id, name: "Midterm 3")
        if configure { var cfg = AssessmentConfig(); cfg.examQuestionCount = count; cfg.durationMinutes = 75; cfg.pointsPerQuestion = 1; cfg.format = "single_choice"; cfg.basis = ["examQuestionCount": .userProvided]; try AssessmentService(db: db).setConfig(cfg, assessmentId: a.id) }
        let ai = AITaskService(db: db); let t = try ai.createGenerationTask(courseId: c.id, params: GenerationParams(count: min(200, max(1, questions))))
        var made = 0
        for b in try ai.batches(taskId: t.id) {
            let qs = (0..<b.expectedCount).map { i in Fx.base("single_choice", title: "Q\(made + i)", answer: ["choices": [["id": "a", "text": "A"], ["id": "b", "text": "B"]], "correctIds": ["a"]], method: "choice", skills: ["Topic"], extra: ["content": [Fx.md("Unique statement number \(made + i) about topic")]]) }
            made += b.expectedCount
            _ = try ai.importResponse(Fx.envelope(b.requestId, qs), targetBatchId: b.id)
        }
        return (c, a)
    }

    @Test func startNeedsSettingsAndEnoughQuestions() throws {
        let db = try AppDatabase.inMemory()
        let (c, a) = try seed(db, questions: 5, configure: false)
        #expect(throws: ExamError.self) { _ = try ExamService(db: db).start(courseId: c.id, assessmentId: a.id) }
        var cfg = AssessmentConfig(); cfg.examQuestionCount = 19; cfg.durationMinutes = 75; try AssessmentService(db: db).setConfig(cfg, assessmentId: a.id)
        #expect(throws: ExamError.insufficientQuestions(have: 5, need: 19)) { _ = try ExamService(db: db).start(courseId: c.id, assessmentId: a.id) }
    }

    @Test func clockPauseResumeExpiryDeferredFeedbackAndIdempotentSubmission() throws {
        let db = try AppDatabase.inMemory(); let (c, a) = try seed(db, questions: 25)
        let clock = Clock(Date(timeIntervalSince1970: 1_800_000_000)); let svc = ExamService(db: db, now: { clock.now })
        let ex = try svc.start(courseId: c.id, assessmentId: a.id)
        let practice = PracticeService(db: db); let items = try practice.items(sessionId: ex.sessionId)
        #expect(items.count == 19 && Set(items.map(\.questionId)).count == 19 && ex.durationSeconds == 4500)
        #expect(svc.remainingSeconds(ex) == 4500)
        clock.advance(600); #expect(svc.remainingSeconds(try svc.attempt(ex.id)) == 3900)
        try svc.pause(ex.id); clock.advance(3000)                                           // paused time does not count
        #expect(svc.remainingSeconds(try svc.attempt(ex.id)) == 3900)
        try svc.resume(ex.id); clock.advance(100); #expect(svc.remainingSeconds(try svc.attempt(ex.id)) == 3800)
        // answers are drafts only: no attempts, evaluations or scores exist before submission
        for (i, it) in items.enumerated() { try svc.saveAnswer(attemptId: ex.id, itemId: it.id, selected: [i < 12 ? "a" : "b"]) }
        #expect(try db.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM attempts") } == 0 && (try db.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM evaluations") }) == 0)
        #expect(try svc.attempt(ex.id).score == nil)
        let s1 = try svc.submit(ex.id); let s2 = try svc.submit(ex.id)
        #expect(s1.status == "submitted" && s1.score == 12 && s1.maxScore == 19 && s2 == s1)    // one point each, submitted exactly once
        #expect(try db.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM attempts") } == 19)
        try svc.saveAnswer(attemptId: ex.id, itemId: items[0].id, selected: ["b"])           // ignored after submission
        #expect(try svc.submit(ex.id).score == 12)
    }

    @Test func expiryIsDetectedAndSubmitGradesWhatWasSaved() throws {
        let db = try AppDatabase.inMemory(); let (c, a) = try seed(db, questions: 20, count: 5)
        let clock = Clock(Date(timeIntervalSince1970: 1_800_000_000)); let svc = ExamService(db: db, now: { clock.now })
        let ex = try svc.start(courseId: c.id, assessmentId: a.id); let items = try PracticeService(db: db).items(sessionId: ex.sessionId)
        try svc.saveAnswer(attemptId: ex.id, itemId: items[0].id, selected: ["a"])
        clock.advance(4501)
        #expect(try svc.refresh(ex.id).status == "expired")
        try svc.saveAnswer(attemptId: ex.id, itemId: items[1].id, selected: ["a"])         // too late: not saved
        let done = try svc.submit(ex.id)
        #expect(done.score == 1 && done.maxScore == 5)
    }

    @Test func selectionOrderAndProgressSurviveARestart() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString); try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("e.sqlite"); var id = UUID(); var order: [UUID] = []
        do {
            let db = try AppDatabase.open(at: url); let (c, a) = try seed(db, questions: 22, count: 6)
            let svc = ExamService(db: db); let ex = try svc.start(courseId: c.id, assessmentId: a.id); id = ex.id
            let items = try PracticeService(db: db).items(sessionId: ex.sessionId); order = items.map(\.questionId)
            try svc.saveAnswer(attemptId: ex.id, itemId: items[2].id, selected: ["a"]); try svc.pause(ex.id)
        }
        let db2 = try AppDatabase.open(at: url); let svc = ExamService(db: db2)
        let ex = try svc.attempt(id)
        let reopened = try PracticeService(db: db2).items(sessionId: ex.sessionId).map(\.questionId)
        #expect(ex.status == "paused" && reopened == order)
        let draft = try db2.read { try AttemptDraft.fetchAll($0) }
        #expect(draft.count == 1)
        try svc.resume(id); #expect(try svc.submit(id).score == 1)
    }
}

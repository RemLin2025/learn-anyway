import Testing
import Foundation
import GRDB
@testable import BraincellCore

@Suite struct PracticeTests {
    let db: AppDatabase, courses: CourseService, qs: QuestionService, practice: PracticeService
    let course: Course

    init() throws {
        db = try AppDatabase.inMemory(); courses = CourseService(db: db); qs = QuestionService(db: db); practice = PracticeService(db: db)
        course = try courses.createCourse(name: "COMP 211")
    }

    @discardableResult
    func add(_ i: Int, title: String? = nil) throws -> Question {
        var spec = QuestionValidator.validate(entry: Fx.all[i], index: 0).question!.spec
        if let title { spec.title = title }
        return try qs.create(courseId: course.id, spec: spec)
    }

    func start(_ ids: [UUID]) throws -> (StudySession, [SessionItem]) {
        let s = try practice.start(questionIds: ids, title: "Test", courseId: course.id)
        return (s, try practice.items(sessionId: s.id))
    }

    @Test func layoutByType() {
        #expect(PracticeLayout.for(.flashcard) == .focus && PracticeLayout.for(.singleChoice) == .focus && PracticeLayout.for(.numeric) == .focus)
        #expect(PracticeLayout.for(.coding) == .workspace && PracticeLayout.for(.derivationProof) == .workspace && PracticeLayout.for(.longForm) == .workspace && PracticeLayout.for(.codeTracing) == .workspace)
    }

    @Test func sessionPinsRevisionsSoEditsNeverChangeWhatWasAnswered() throws {
        let q = try add(1)
        let (_, items) = try start([q.id])
        let pinned = items[0].revisionId
        var spec = try qs.detail(q.id).spec; spec.title = "Edited later"
        try qs.edit(questionId: q.id, spec: spec)
        try practice.saveDraft(itemId: items[0].id, response: { var r = PracticeResponse(); r.selected = ["a"]; return r }())
        let a = try practice.submit(itemId: items[0].id)
        #expect(a.revisionId == pinned)
        #expect(try qs.detail(q.id).revision.id != pinned)
    }

    @Test func draftsAutosaveAndSurviveRestart() throws {
        let dir = try tempDir(); let path = dir.appendingPathComponent("p.sqlite")
        let file = try AppDatabase.open(at: path)
        let c = try CourseService(db: file).createCourse(name: "X")
        let spec = QuestionValidator.validate(entry: Fx.all[6], index: 0).question!.spec
        let q = try QuestionService(db: file).create(courseId: c.id, spec: spec)
        let svc = PracticeService(db: file)
        let s = try svc.start(questionIds: [q.id], title: "T", courseId: c.id)
        let item = try svc.items(sessionId: s.id)[0]
        // Untouched: starter code is offered.
        var r = try svc.response(for: item, spec: spec)
        #expect(r.files.first?.content == "class A {}" && r.files.first?.name == "Main.java")
        r.files[0].content = "class A { int x = 1; }"
        try svc.saveDraft(itemId: item.id, response: r)
        try svc.addActiveSeconds(itemId: item.id, 42)
        try svc.moveTo(sessionId: s.id, ordinal: 0)

        let reopened = PracticeService(db: try AppDatabase.open(at: path))   // "restart"
        let resumed = try #require(try reopened.resumableSession())
        #expect(resumed.id == s.id)
        let item2 = try reopened.items(sessionId: resumed.id)[0]
        #expect(item2.status == .inProgress && item2.activeSeconds == 42)
        #expect(try reopened.response(for: item2, spec: spec).files[0].content == "class A { int x = 1; }")
        try reopened.setStatus(s.id, .completed)
        #expect(try reopened.resumableSession() == nil)
    }

    @Test func submissionIsImmutableAndIdempotent() throws {
        let q = try add(3)
        let (_, items) = try start([q.id])
        var r = PracticeResponse(); r.text = "hasNext"
        try practice.saveDraft(itemId: items[0].id, response: r)
        let a1 = try practice.submit(itemId: items[0].id)
        let a2 = try practice.submit(itemId: items[0].id)           // double click
        #expect(a1.id == a2.id && a1.decodedResponse.text == "hasNext")
        #expect(try db.read { try Attempt.fetchCount($0) } == 1)
        #expect(try practice.items(sessionId: items[0].sessionId)[0].status == .submitted)
        #expect(throws: PracticeError.alreadySubmitted) { try practice.saveDraft(itemId: items[0].id, response: PracticeResponse()) }
        #expect(throws: DatabaseError.self) {
            try db.write { try $0.execute(sql: "UPDATE attempts SET response = '{}' WHERE id = ?", arguments: [a1.id]) }
        }
        #expect(try db.read { try AttemptDraft.fetchCount($0) } == 0)            // draft consumed
        // A different later response can't sneak in either.
        var other = PracticeResponse(); other.text = "changed"
        #expect(try practice.submit(itemId: items[0].id, response: other).decodedResponse.text == "hasNext")
    }

    @Test func emptySubmissionIsRefused() throws {
        let q = try add(3); let (_, items) = try start([q.id])
        #expect(throws: PracticeError.nothingToSubmit) { try practice.submit(itemId: items[0].id) }
        #expect(throws: PracticeError.nothingToSubmit) { try practice.submit(itemId: items[0].id, response: PracticeResponse()) }
    }

    @Test func hintsAreProgressiveCappedAndRecorded() throws {
        var spec = QuestionValidator.validate(entry: Fx.all[3], index: 0).question!.spec
        spec.hints = ["one", "two"]
        let q = try qs.create(courseId: course.id, spec: spec)
        let (_, items) = try start([q.id])
        try practice.revealHint(itemId: items[0].id, level: 1)
        try practice.revealHint(itemId: items[0].id, level: 5)   // capped at 2
        try practice.revealHint(itemId: items[0].id, level: 1)   // never goes back
        #expect(try practice.items(sessionId: items[0].sessionId)[0].hintsUsed == 2)
        var r = PracticeResponse(); r.text = "x"
        #expect(try practice.submit(itemId: items[0].id, response: r).hintsUsed == 2)
    }

    @Test func skippingKeepsWorkAndCanBeResumed() throws {
        let q = try add(5); let (s, items) = try start([q.id])
        var r = PracticeResponse(); r.text = "partial answer"
        try practice.saveDraft(itemId: items[0].id, response: r)
        try practice.skip(itemId: items[0].id)
        var item = try practice.items(sessionId: s.id)[0]
        #expect(item.status == .skipped)
        let spec = try qs.detail(q.id).spec
        #expect(try practice.response(for: item, spec: spec).text == "partial answer")
        r.text = "partial answer, continued"
        try practice.saveDraft(itemId: item.id, response: r)
        item = try practice.items(sessionId: s.id)[0]
        #expect(item.status == .inProgress)
        let sum = try practice.summary(sessionId: s.id)
        #expect(sum == SessionSummary(total: 1, submitted: 0, skipped: 0, unanswered: 1, hintsUsed: 0, activeSeconds: 0))
    }

    @Test func selectionByAssessmentAndArchive() throws {
        let q1 = try add(0), q2 = try add(1), q3 = try add(2)
        let m1 = try courses.addAssessment(courseId: course.id, name: "M1")
        let fin = try courses.addAssessment(courseId: course.id, name: "Final", kind: .final, isCumulative: true)
        try qs.addToAssessment(questionIds: [q1.id, q2.id], assessmentId: m1.id)
        #expect(try practice.questionIds(courseId: course.id, assessmentId: m1.id) == [q1.id, q2.id])
        #expect(Set(try practice.questionIds(courseId: course.id, assessmentId: fin.id)) == [q1.id, q2.id, q3.id])
        try qs.setArchived([q1.id], archived: true)
        #expect(try practice.questionIds(courseId: course.id) == [q2.id, q3.id])
        #expect(throws: PracticeError.noQuestions) { try practice.start(questionIds: [], title: "x") }
        #expect(throws: PracticeError.noQuestions) { try practice.start(questionIds: [q1.id], title: "x") } // archived only
    }

    @Test func timeAccumulatesAndNothingIsFabricatedForCode() async throws {
        let q = try add(3); let (_, items) = try start([q.id])
        try practice.addActiveSeconds(itemId: items[0].id, 10); try practice.addActiveSeconds(itemId: items[0].id, 5)
        try practice.addActiveSeconds(itemId: items[0].id, 100_000) // capped per call
        #expect(try practice.items(sessionId: items[0].sessionId)[0].activeSeconds == 615)
        let runner = UnavailableCodeRunner()
        #expect(!runner.isAvailable)
        let result = await runner.run(CodeRunRequest(files: [], language: "python"))
        #expect(result == .unavailable(reason: UnavailableCodeRunner.reason))
    }
}

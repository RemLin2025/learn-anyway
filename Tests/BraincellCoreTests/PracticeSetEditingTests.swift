import Testing
import Foundation
import GRDB
@testable import BraincellCore

extension AgentTests {
    func manualSet(_ e: E, _ c: Course) throws -> (PracticeSet, PracticeSetService) {
        let svc = PracticeSetService(db: e.db, ai: e.ctx.ai)
        return (try svc.createEmpty(courseId: c.id, title: "Manual"), svc)
    }

    @Test func practiceSetEditingAddsRemovesReordersByReferenceAndNeverDuplicates() async throws {
        let e = try await env { _, _, _ in "x" }
        let c1 = try e.ctx.courses.createCourse(name: "A"), c2 = try e.ctx.courses.createCourse(name: "B")
        try seedQuestions(e, c1, Array(Fx.all.prefix(3)))
        try seedQuestions(e, c2, Array(Fx.all.dropFirst(3).prefix(2)))
        let qs = QuestionService(db: e.db)
        let a = try qs.list(QuestionFilter()).filter { $0.question.courseId == c1.id }.map(\.id), b = try qs.list(QuestionFilter()).filter { $0.question.courseId == c2.id }.map(\.id)
        let (set, svc) = try manualSet(e, c1)
        for q in [a[0], a[1], b[0]] { try svc.add(questionId: q, to: set.id) }                // includes another course's question, by reference
        #expect(throws: PracticeSetError.alreadyInSet) { try svc.add(questionId: a[0], to: set.id) }
        let slots = { try svc.items(setId: set.id) }
        #expect(try slots().map(\.questionId) == [a[0], a[1], b[0]])
        let before = try svc.practiceSet(set.id)!.revision
        try svc.reorder(setId: set.id, slotOrder: try slots().map(\.slot.id).reversed())
        #expect(try slots().map(\.questionId) == [b[0], a[1], a[0]])
        try svc.remove(questionId: a[1], from: set.id)
        #expect(try slots().map(\.questionId) == [b[0], a[0]])
        #expect(try svc.practiceSet(set.id)!.revision > before)
        #expect(try qs.list(QuestionFilter()).count == 5)                                       // questions themselves are untouched
        try svc.update(setId: set.id, title: "Renamed", description: "d", templateId: "builtin.guided")
        let s2 = try svc.practiceSet(set.id)!
        #expect(s2.title == "Renamed" && s2.description == "d" && s2.templateId == "builtin.guided")
        #expect(throws: PracticeSetError.emptyTitle) { try svc.update(setId: set.id, title: "  ") }
        let dup = try svc.duplicate(setId: set.id)
        let dupQs = try svc.items(setId: dup.id).compactMap(\.questionId), srcQs = try svc.items(setId: set.id).compactMap(\.questionId)
        #expect(dup.id != set.id && dupQs == srcQs)
        try svc.delete(setId: dup.id)
        let live = try svc.sets(courseId: c1.id), gone = try svc.deletedSets().map(\.id)
        #expect(live.contains { $0.id == dup.id } == false && gone == [dup.id])
        try svc.restore(setId: dup.id)
        #expect(try svc.sets(courseId: c1.id).contains { $0.id == dup.id })
    }

    @Test func editingASetNeverChangesAnExistingAttemptAndANewAttemptUsesTheNewQuestions() async throws {
        let e = try await env { _, _, _ in "x" }
        let c = try e.ctx.courses.createCourse(name: "A")
        try seedQuestions(e, c, Array(Fx.all.prefix(4)))
        let ids = try QuestionService(db: e.db).list(QuestionFilter()).map(\.id)
        let (set, svc) = try manualSet(e, c)
        try svc.add(questionId: ids[0], to: set.id); try svc.add(questionId: ids[1], to: set.id)
        let tpl = TemplateService(db: e.db)
        #expect(try svc.progress(setId: set.id).state == .notStarted)
        let first = try svc.startSession(setId: set.id, template: .interactive, templates: tpl)
        #expect(!first.resumed)
        try svc.add(questionId: ids[2], to: set.id)                                                // edit while the attempt is open
        let p = try svc.progress(setId: set.id)
        #expect(p.state == .inProgress && p.stale && p.total == 2 && p.sessionId == first.session.id)
        let again = try svc.startSession(setId: set.id, template: .interactive, templates: tpl)    // default: resume, never silently restart
        #expect(again.resumed && again.session.id == first.session.id)
        #expect(try PracticeService(db: e.db).items(sessionId: first.session.id).count == 2)       // the attempt kept its own questions
        let fresh = try svc.startSession(setId: set.id, template: .interactive, templates: tpl, newAttempt: true)
        let freshCount = try PracticeService(db: e.db).items(sessionId: fresh.session.id).count
        #expect(!fresh.resumed && fresh.session.id != first.session.id && freshCount == 3)
        #expect(try svc.progress(setId: set.id).stale == false)
    }
}

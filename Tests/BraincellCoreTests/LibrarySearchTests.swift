import Testing
import Foundation
import GRDB
@testable import BraincellCore

extension AgentTests {
    @Test func universalSearchFindsEveryKindWithoutCopyingAnything() async throws {
        let e = try await env { _, _, _ in "x" }
        let c = try e.ctx.courses.createCourse(name: "STOR435 Probability")
        try seedQuestions(e, c, Array(Fx.all.prefix(3)))
        let lib = LibraryService(db: e.db, storage: e.ctx.storage)
        let svc = LibrarySearchService(db: e.db, library: lib, questions: QuestionService(db: e.db), templates: TemplateService(db: e.db))
        let empty = try svc.search("")
        #expect(empty.hits.isEmpty && (empty.counts[.question] ?? 0) >= 3 && (empty.counts[.template] ?? 0) >= 4 && empty.counts[.course] == 1)
        let r = try svc.search("probability")
        #expect(r.hits(.course).map(\.title) == ["STOR435 Probability"])
        let t = try svc.search("flashcards")
        #expect(t.hits(.template).contains { $0.title.lowercased().contains("flashcard") })
        let none = try svc.search("zzzz-not-here")
        #expect(none.hits.isEmpty)
        // all words must match, in any order
        #expect(try svc.search("probability stor435").hits(.course).count == 1)
        #expect(try svc.search("probability nothing").hits(.course).isEmpty)
    }
}

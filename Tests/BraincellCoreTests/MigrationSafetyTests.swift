import Testing
import Foundation
import GRDB
@testable import BraincellCore

@Suite struct MigrationSafetyTests {
    /// A database as it was before this branch (through v21: practice sets, templates, saved Question views) keeps every row and works after v22–v24.
    @Test func existingDataSurvivesTheNewMigrationsAndGetsSafeDefaults() throws {
        let q = try DatabaseQueue(configuration: AppDatabase.configuration)
        try AppDatabase.migrator(upTo: nil).migrate(q, upTo: "v21_templates_worksheets")
        let course = UUID(), set = UUID(), view = UUID()
        try q.write { d in
            try d.execute(sql: "INSERT INTO courses (id, name, kind, createdAt) VALUES (?,?,?,?)", arguments: [course, "STOR435", "structured", Date()])
            try d.execute(sql: "INSERT INTO practice_sets (id, courseId, title, requestKey, paramsJSON, fresh, createdAt) VALUES (?,?,?,?,?,?,?)", arguments: [set, course, "Old set", "k", "{}", false, Date()])
            try d.execute(sql: "INSERT INTO saved_views (id, name, filterJSON, createdAt) VALUES (?,?,?,?)", arguments: [view, "Hard ones", "{}", Date()])
        }
        let db = try AppDatabase(q)                                                                         // applies v22, v23, v24
        let svc = PracticeSetService(db: db, ai: AITaskService(db: db))
        let old = try #require(try svc.practiceSet(set))
        #expect(old.title == "Old set" && old.revision == 1 && old.deletedAt == nil && old.description == nil && old.templateId == nil)
        #expect(try svc.sets(courseId: course).map(\.id) == [set])                                          // still listed
        #expect(try svc.progress(setId: set).state == .notStarted)
        let views = try QuestionService(db: db).savedViews()
        #expect(views.map(\.name) == ["Hard ones"] && views[0].category == "questions")                    // existing views remain Question views
        #expect(try LibraryViews(db: db).views(category: "materials").isEmpty)
        for t in ["question_tutor_messages", "library_favorites", "note_summaries"] { #expect(try db.read { try $0.tableExists(t) }) }
        // running the migrator again is a no-op
        let again = try AppDatabase(q)
        #expect(try PracticeSetService(db: again, ai: AITaskService(db: again)).sets(courseId: course).count == 1)
    }

    @Test func migrationsAreRegisteredInNumericOrder() throws {
        let names = AppDatabase.migrator(upTo: nil).migrations
        let nums = names.compactMap { Int($0.dropFirst().prefix { $0.isNumber }) }
        #expect(nums == nums.sorted() && Set(nums).count == nums.count)
    }
}

import Testing
import Foundation
import GRDB
@testable import BraincellCore

@Suite struct PersistenceTests {
    @Test func courseSurvivesReopen() throws {
        let dir = try tempDir()
        let path = dir.appendingPathComponent("db.sqlite")
        let id: UUID
        do {
            let db = try AppDatabase.open(at: path)
            id = try CourseService(db: db).createCourse(name: "COMP 211").id
        }
        let reopened = try AppDatabase.open(at: path)
        let courses = try CourseService(db: reopened).courses()
        #expect(courses.map(\.id) == [id])
        #expect(courses.first?.name == "COMP 211")
    }

    @Test func migrationUpgradePreservesData() throws {
        let q = try DatabaseQueue(configuration: AppDatabase.configuration)
        try AppDatabase.migrator(upTo: nil).migrate(q, upTo: "v1_foundation")
        let c = Course(id: UUID(), name: "Old", kind: .structured, createdAt: Date(), archivedAt: nil)
        try q.write { try c.insert($0) }
        let db = try AppDatabase(q) // applies v2
        #expect(try CourseService(db: db).courses().count == 1)
        #expect(try db.read { try $0.tableExists("documents") })
    }

    @Test func foreignKeysEnforced() throws {
        let db = try AppDatabase.inMemory()
        #expect(throws: DatabaseError.self) {
            try db.write {
                try Assessment(id: UUID(), courseId: UUID(), name: "Orphan", kind: .quiz, deadline: nil, isCumulative: false,
                               importance: nil, importanceSource: .unset, sortOrder: 0, createdAt: Date()).insert($0)
            }
        }
    }

    @Test func settingsPersistAndDefault() throws {
        let db = try AppDatabase.inMemory()
        let s = SettingsStore(db: db)
        #expect(try s.appearance() == .system)
        try s.set(.appearance, AppearanceSetting.dark.rawValue)
        try s.set(.appearance, AppearanceSetting.light.rawValue) // upsert
        #expect(try s.appearance() == .light)
        #expect(try s.bool(.onboardingDismissed) == false)
    }
}

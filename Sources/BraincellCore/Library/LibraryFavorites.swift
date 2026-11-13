import Foundation
import GRDB

/// Stars for Library items that have no row of their own to flag (questions, practice sets, templates). Files and folders keep their own `favorite` column.
public final class LibraryFavorites: @unchecked Sendable {
    let db: AppDatabase
    public enum Kind: String, Sendable { case question, practiceSet, template }
    public init(db: AppDatabase) { self.db = db }

    public func set(_ kind: Kind, _ id: String, _ on: Bool) throws {
        try db.write { d in
            if on { try d.execute(sql: "INSERT OR IGNORE INTO library_favorites (kind, itemId, createdAt) VALUES (?,?,?)", arguments: [kind.rawValue, id, Date()]) }
            else { try d.execute(sql: "DELETE FROM library_favorites WHERE kind = ? AND itemId = ?", arguments: [kind.rawValue, id]) }
        }
    }
    public func ids(_ kind: Kind) throws -> Set<String> {
        Set(try db.read { try String.fetchAll($0, sql: "SELECT itemId FROM library_favorites WHERE kind = ?", arguments: [kind.rawValue]) })
    }
    public func isFavorite(_ kind: Kind, _ id: String) -> Bool { (try? ids(kind).contains(id)) ?? false }
}

/// Saved filters for the Library sections other than Questions (which keep `QuestionService`'s views). Stored in the same `saved_views` table by category.
public final class LibraryViews: @unchecked Sendable {
    let db: AppDatabase
    public init(db: AppDatabase) { self.db = db }
    public func save<F: Encodable>(category: String, name: String, filter: F) throws {
        let n = try CourseService.clean(name)
        let json = String(data: try JSONEncoder().encode(filter), encoding: .utf8) ?? "{}"
        try db.write { try SavedView(id: UUID(), name: n, filterJSON: json, createdAt: Date(), category: category).insert($0) }
    }
    public func views(category: String) throws -> [SavedView] { try db.read { try SavedView.filter(Column("category") == category).order(Column("createdAt")).fetchAll($0) } }
    public func delete(_ id: UUID) throws { _ = try db.write { try SavedView.deleteOne($0, key: id) } }
    public static func filter<F: Decodable>(_ v: SavedView, as: F.Type) -> F? { try? JSONDecoder().decode(F.self, from: Data(v.filterJSON.utf8)) }
}

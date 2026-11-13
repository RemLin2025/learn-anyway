import Foundation
import GRDB

/// One result of the Universal Library search. A view over existing data (courses, files, questions, practice sets, templates); nothing is copied or indexed separately.
public struct LibraryHit: Identifiable, Equatable, Sendable {
    public enum Kind: String, CaseIterable, Sendable {
        case course, material, question, practiceSet, template
        public var title: String {
            switch self { case .course: "Courses"; case .material: "Materials"; case .question: "Questions"; case .practiceSet: "Practice Sets"; case .template: "Templates" }
        }
    }
    public var kind: Kind
    public var key: String                 // UUID string, or the template id
    public var title: String
    public var subtitle: String
    public var courseId: UUID?
    public var id: String { kind.rawValue + ":" + key }
}

public struct LibrarySearchResult: Equatable, Sendable {
    public var hits: [LibraryHit]
    /// Total matches per kind (hits are capped per kind).
    public var counts: [LibraryHit.Kind: Int]
    public init(hits: [LibraryHit], counts: [LibraryHit.Kind: Int]) { self.hits = hits; self.counts = counts }
    public func hits(_ k: LibraryHit.Kind) -> [LibraryHit] { hits.filter { $0.kind == k } }
}

public final class LibrarySearchService: @unchecked Sendable {
    let db: AppDatabase
    let library: LibraryService, questions: QuestionService, templates: TemplateService
    public init(db: AppDatabase, library: LibraryService, questions: QuestionService, templates: TemplateService) {
        self.db = db; self.library = library; self.questions = questions; self.templates = templates
    }

    public static func matches(_ text: String, in hay: String) -> Bool {
        text.split(separator: " ").allSatisfy { hay.range(of: String($0), options: [.caseInsensitive, .diacriticInsensitive]) != nil }
    }

    /// Every word of `text` must appear (any order) in an item's name/title (and course name). An empty query returns only counts.
    public func search(_ raw: String, perKind: Int = 8) throws -> LibrarySearchResult {
        let text = raw.trimmingCharacters(in: .whitespaces)
        let courses = try db.read { try Row.fetchAll($0, sql: "SELECT id, name FROM courses WHERE archivedAt IS NULL") }
        let courseName = Dictionary(uniqueKeysWithValues: courses.map { ($0["id"] as UUID, $0["name"] as String) })
        var all: [LibraryHit] = []
        for c in courses where text.isEmpty || Self.matches(text, in: c["name"]) {
            all.append(LibraryHit(kind: .course, key: (c["id"] as UUID).uuidString, title: c["name"], subtitle: "Course", courseId: c["id"]))
        }
        var q = LibraryQuery(); q.text = text
        for e in try library.list(.root, q) where e.kind != .courseFolder && text.isEmpty == false {
            all.append(LibraryHit(kind: .material, key: e.id.uuidString, title: e.name, subtitle: [e.kind.label, e.courseId.flatMap { courseName[$0] }].compactMap { $0 }.joined(separator: " · "), courseId: e.courseId))
        }
        if text.isEmpty {                           // counts only: materials are counted without listing them all
            let n = try db.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM documents WHERE deletedAt IS NULL") } ?? 0
            var counts = Dictionary(grouping: all, by: \.kind).mapValues(\.count); counts[.material] = n
            counts[.question] = try db.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM questions WHERE archivedAt IS NULL") } ?? 0
            counts[.practiceSet] = try db.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM practice_sets") } ?? 0
            counts[.template] = try templates.all().count
            return LibrarySearchResult(hits: [], counts: counts)
        }
        var f = QuestionFilter(); f.text = text
        for r in try questions.list(f) {
            all.append(LibraryHit(kind: .question, key: r.id.uuidString, title: r.title, subtitle: [r.question.type.label, courseName[r.question.courseId]].compactMap { $0 }.joined(separator: " · "), courseId: r.question.courseId))
        }
        for s in try db.read({ try Row.fetchAll($0, sql: "SELECT id, courseId, title FROM practice_sets ORDER BY createdAt DESC") }) {
            let cid: UUID = s["courseId"], title: String = s["title"]
            if Self.matches(text, in: title + " " + (courseName[cid] ?? "")) { all.append(LibraryHit(kind: .practiceSet, key: (s["id"] as UUID).uuidString, title: title, subtitle: courseName[cid] ?? "Practice set", courseId: cid)) }
        }
        for t in try templates.all() where Self.matches(text, in: t.name + " " + t.description) {
            all.append(LibraryHit(kind: .template, key: t.id, title: t.name, subtitle: t.isBuiltIn ? "Built-in template" : "Custom template", courseId: nil))
        }
        let counts = Dictionary(grouping: all, by: \.kind).mapValues(\.count)
        var out: [LibraryHit] = []
        for k in LibraryHit.Kind.allCases { out += all.filter { $0.kind == k }.prefix(perKind) }
        return LibrarySearchResult(hits: out, counts: counts)
    }
}

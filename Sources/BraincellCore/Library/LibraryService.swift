import Foundation
import GRDB

/// One service for the global Library AND each course's Materials: both are views of the same `documents` / `library_folders` rows.
/// A file belongs to exactly one place (a course folder tree, or the global Library); moving it changes that one record, never copies bytes.
/// Deletion is a soft delete with a seven-day recovery window; the clock is injected so the boundary is testable.
public struct LibraryService: Sendable {
    public static let retention: TimeInterval = 7 * 24 * 3600

    public let db: AppDatabase
    public let storage: ManagedStorage
    let docs: DocumentService
    let now: @Sendable () -> Date

    public init(db: AppDatabase, storage: ManagedStorage, now: @escaping @Sendable () -> Date = { Date() }) {
        self.db = db; self.storage = storage; self.now = now; docs = DocumentService(db: db, storage: storage)
    }

    static let liveCourse = "(courseId IS NULL OR EXISTS (SELECT 1 FROM courses c WHERE c.id = courseId AND c.archivedAt IS NULL))"

    // MARK: Browsing

    private func scope(_ l: LibraryLocation, _ d: Database) throws -> (course: UUID?, folder: UUID?) {
        switch l {
        case .root: return (nil, nil)
        case .course(let c): return (c, nil)
        case .folder(let f):
            guard let row = try Row.fetchOne(d, sql: "SELECT courseId FROM library_folders WHERE id = ? AND deletedAt IS NULL", arguments: [f]) else { throw LibraryError.notFound }
            return (row["courseId"], f)
        }
    }

    public func list(_ l: LibraryLocation, _ q: LibraryQuery = LibraryQuery()) throws -> [LibraryEntry] {
        var entries: [LibraryEntry] = try db.read { d in
            let (course, folder) = try scope(l, d)
            var out: [LibraryEntry] = []
            let courseNames = Dictionary(uniqueKeysWithValues: try Row.fetchAll(d, sql: "SELECT id, name FROM courses").map { ($0["id"] as UUID, $0["name"] as String) })
            if q.isFlat {
                // Subtree of the current location (the whole Library at the root).
                var folderIds: Set<UUID>? = nil
                if let f = folder {
                    var ids: Set<UUID> = [f], frontier = [f]
                    while !frontier.isEmpty {
                        let kids = try UUID.fetchAll(d, sql: "SELECT id FROM library_folders WHERE parentId IN (\(frontier.map { _ in "?" }.joined(separator: ","))) AND deletedAt IS NULL", arguments: StatementArguments(frontier))
                        frontier = kids.filter { ids.insert($0).inserted }
                    }
                    folderIds = ids
                }
                for f in try Row.fetchAll(d, sql: "SELECT * FROM library_folders WHERE deletedAt IS NULL AND \(Self.liveCourse)") {
                    let id: UUID = f["id"]; let cid: UUID? = f["courseId"]
                    if let course, cid != course { continue }
                    if let folderIds, !folderIds.contains(id) || id == folder { continue }
                    out.append(LibraryEntry(id: id, kind: .folder, name: f["name"], courseId: cid, parentId: f["parentId"], byteCount: 0, addedAt: f["createdAt"], modifiedAt: f["modifiedAt"], favorite: f["favorite"], storedPath: nil, childCount: 0))
                }
                for x in try Document.fetchAll(d, sql: "SELECT * FROM documents WHERE deletedAt IS NULL AND \(Self.liveCourse)") {
                    if let course, x.courseId != course { continue }
                    if let folderIds, !(x.folderId.map(folderIds.contains) ?? false) { continue }
                    out.append(Self.entry(x))
                }
                if folder == nil && course == nil { // course folders are searchable too
                    for c in try Row.fetchAll(d, sql: "SELECT id, name, createdAt FROM courses WHERE archivedAt IS NULL") {
                        out.append(LibraryEntry(id: c["id"], kind: .courseFolder, name: c["name"], courseId: c["id"], parentId: nil, byteCount: 0, addedAt: c["createdAt"], modifiedAt: c["createdAt"], favorite: false, storedPath: nil, childCount: 0))
                    }
                }
                let text = q.text.trimmingCharacters(in: .whitespaces)
                if !text.isEmpty {
                    out = out.filter { e in
                        let hay = [e.name, e.kind.label, e.courseId.flatMap { courseNames[$0] } ?? ""].joined(separator: " ")
                        return text.split(separator: " ").allSatisfy { hay.range(of: String($0), options: [.caseInsensitive, .diacriticInsensitive]) != nil }
                    }
                }
            } else {
                if case .root = l {
                    for c in try Row.fetchAll(d, sql: "SELECT id, name, createdAt FROM courses WHERE archivedAt IS NULL") {
                        out.append(LibraryEntry(id: c["id"], kind: .courseFolder, name: c["name"], courseId: c["id"], parentId: nil, byteCount: 0, addedAt: c["createdAt"], modifiedAt: c["createdAt"], favorite: false, storedPath: nil, childCount: 0))
                    }
                }
                for f in try Row.fetchAll(d, sql: "SELECT * FROM library_folders WHERE deletedAt IS NULL AND courseId IS ? AND parentId IS ?", arguments: [course, folder]) {
                    out.append(LibraryEntry(id: f["id"], kind: .folder, name: f["name"], courseId: course, parentId: folder, byteCount: 0, addedAt: f["createdAt"], modifiedAt: f["modifiedAt"], favorite: f["favorite"], storedPath: nil, childCount: 0))
                }
                for x in try Document.fetchAll(d, sql: "SELECT * FROM documents WHERE deletedAt IS NULL AND courseId IS ? AND folderId IS ?", arguments: [course, folder]) { out.append(Self.entry(x)) }
            }
            // Child counts for the folders shown (two grouped queries, not one per card).
            var counts: [UUID: Int] = [:]
            for r in try Row.fetchAll(d, sql: "SELECT folderId, COUNT(*) n FROM documents WHERE deletedAt IS NULL AND folderId IS NOT NULL GROUP BY folderId") { counts[r["folderId"]] = r["n"] }
            for r in try Row.fetchAll(d, sql: "SELECT parentId, COUNT(*) n FROM library_folders WHERE deletedAt IS NULL AND parentId IS NOT NULL GROUP BY parentId") { counts[r["parentId"], default: 0] += r["n"] }
            for r in try Row.fetchAll(d, sql: "SELECT courseId, COUNT(*) n FROM documents WHERE deletedAt IS NULL AND folderId IS NULL AND courseId IS NOT NULL GROUP BY courseId") { counts[r["courseId"], default: 0] += r["n"] }
            for r in try Row.fetchAll(d, sql: "SELECT courseId, COUNT(*) n FROM library_folders WHERE deletedAt IS NULL AND parentId IS NULL AND courseId IS NOT NULL GROUP BY courseId") { counts[r["courseId"], default: 0] += r["n"] }
            return out.map { var e = $0; if e.isFolder { e.childCount = counts[e.id] ?? 0 }; return e }
        }
        entries = entries.filter { e in
            if q.favoritesOnly && !e.favorite { return false }
            switch q.filter {
            case .all: return true
            case .folders: return e.isFolder
            case .images: return e.kind == .image
            case .videos: return e.kind == .video
            case .documents: return [.pdf, .text, .other].contains(e.kind)
            }
        }
        return Self.sorted(entries, q)
    }

    static func entry(_ x: Document) -> LibraryEntry {
        let k: LibraryKind
        switch x.kind { case .pdf: k = .pdf; case .text, .pasted: k = .text; case .image: k = .image; case .video: k = .video; case .other: k = .other }
        return LibraryEntry(id: x.id, kind: k, name: x.name, courseId: x.courseId, parentId: x.folderId, byteCount: x.byteCount, addedAt: x.importedAt, modifiedAt: x.modifiedAt, favorite: x.favorite, storedPath: x.storedPath, childCount: 0)
    }

    /// Folders always sort before files, then by the chosen key.
    static func sorted(_ es: [LibraryEntry], _ q: LibraryQuery) -> [LibraryEntry] {
        func key(_ a: LibraryEntry, _ b: LibraryEntry) -> Bool {
            switch q.sort {
            case .name: return a.name.localizedStandardCompare(b.name) == .orderedAscending
            case .dateAdded: return a.addedAt < b.addedAt
            case .dateModified: return a.modifiedAt < b.modifiedAt
            case .type: return a.kind.label == b.kind.label ? a.name.localizedStandardCompare(b.name) == .orderedAscending : a.kind.label < b.kind.label
            }
        }
        return es.sorted { a, b in
            if a.isFolder != b.isFolder { return a.isFolder }
            if q.ascending { return key(a, b) } else { return key(b, a) }
        }
    }

    public func breadcrumbs(_ l: LibraryLocation) throws -> [LibraryCrumb] {
        try db.read { d in
            var out: [LibraryCrumb] = []
            switch l {
            case .root: break
            case .course(let c):
                guard let n = try String.fetchOne(d, sql: "SELECT name FROM courses WHERE id = ?", arguments: [c]) else { throw LibraryError.notFound }
                out.append(LibraryCrumb(name: n, location: l))
            case .folder(let f):
                var cur: UUID? = f; var course: UUID?
                while let id = cur {
                    guard let r = try Row.fetchOne(d, sql: "SELECT name, parentId, courseId FROM library_folders WHERE id = ?", arguments: [id]) else { throw LibraryError.notFound }
                    out.insert(LibraryCrumb(name: r["name"], location: .folder(id)), at: 0); cur = r["parentId"]; course = r["courseId"]
                }
                if let course, let n = try String.fetchOne(d, sql: "SELECT name FROM courses WHERE id = ?", arguments: [course]) { out.insert(LibraryCrumb(name: n, location: .course(course)), at: 0) }
            }
            return [LibraryCrumb(name: "Library", location: .root)] + out
        }
    }

    // MARK: Folders, names, favorites

    static func cleanName(_ s: String) throws -> String {
        let n = s.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !n.isEmpty, n != ".", n != ".." else { throw LibraryError.emptyName }
        return String(n.prefix(200))
    }

    func folderNames(_ d: Database, course: UUID?, parent: UUID?, excluding: UUID? = nil) throws -> Set<String> {
        Set(try Row.fetchAll(d, sql: "SELECT id, name FROM library_folders WHERE courseId IS ? AND parentId IS ? AND deletedAt IS NULL", arguments: [course, parent])
            .filter { ($0["id"] as UUID) != excluding }.map { ($0["name"] as String).lowercased() })
    }

    @discardableResult
    public func createFolder(_ name: String, in l: LibraryLocation) throws -> UUID {
        let n = try Self.cleanName(name)
        return try db.write { d in
            let (course, parent) = try scope(l, d)
            if let course, !(try Bool.fetchOne(d, sql: "SELECT archivedAt IS NULL FROM courses WHERE id = ?", arguments: [course]) ?? false) { throw LibraryError.notFound }
            let unique = DocumentService.deduped(n, taken: try folderNames(d, course: course, parent: parent))
            let id = UUID(), t = now()
            try d.execute(sql: "INSERT INTO library_folders (id, parentId, courseId, name, favorite, createdAt, modifiedAt) VALUES (?, ?, ?, ?, 0, ?, ?)", arguments: [id, parent, course, unique, t, t])
            return id
        }
    }

    public func rename(_ ref: LibraryRef, to name: String) throws {
        let n = try Self.cleanName(name)
        switch ref.kind {
        case .courseFolder: try CourseService(db: db).renameCourse(ref.id, to: n)       // the Library folder IS the course, so it follows automatically
        case .folder:
            try db.write { d in
                guard let r = try Row.fetchOne(d, sql: "SELECT courseId, parentId FROM library_folders WHERE id = ?", arguments: [ref.id]) else { throw LibraryError.notFound }
                let unique = DocumentService.deduped(n, taken: try folderNames(d, course: r["courseId"], parent: r["parentId"], excluding: ref.id))
                try d.execute(sql: "UPDATE library_folders SET name = ?, modifiedAt = ? WHERE id = ?", arguments: [unique, now(), ref.id])
            }
        default:
            try db.write { d in
                guard let x = try Document.fetchOne(d, key: ref.id) else { throw LibraryError.notFound }
                let ext = (x.name as NSString).pathExtension
                var desired = n
                if (n as NSString).pathExtension.isEmpty, !ext.isEmpty { desired += "." + ext }    // keep the file type when the user types a bare name
                let siblings = Set(try String.fetchAll(d, sql: "SELECT name FROM documents WHERE courseId IS ? AND folderId IS ? AND deletedAt IS NULL AND id != ?", arguments: [x.courseId, x.folderId, x.id]).map { $0.lowercased() })
                let unique = DocumentService.deduped(desired, taken: siblings)
                try d.execute(sql: "UPDATE documents SET name = ?, title = ?, modifiedAt = ? WHERE id = ?", arguments: [unique, (unique as NSString).deletingPathExtension, now(), ref.id])
            }
        }
    }

    public func setFavorite(_ refs: [LibraryRef], _ on: Bool) throws {
        try db.write { d in
            for r in refs {
                if r.kind == .folder { try d.execute(sql: "UPDATE library_folders SET favorite = ? WHERE id = ?", arguments: [on, r.id]) }
                else if !r.kind.isFolder { try d.execute(sql: "UPDATE documents SET favorite = ? WHERE id = ?", arguments: [on, r.id]) }
            }
        }
    }

    // MARK: Moving

    /// Moves records (never bytes). One transaction, so a failure leaves everything where it was.
    public func move(_ refs: [LibraryRef], to target: LibraryLocation) throws {
        try db.write { d in
            let (course, parent) = try scope(target, d)
            if let course, !(try Bool.fetchOne(d, sql: "SELECT archivedAt IS NULL FROM courses WHERE id = ?", arguments: [course]) ?? false) { throw LibraryError.invalidMove("That course is deleted or archived.") }
            for r in refs {
                switch r.kind {
                case .courseFolder: throw LibraryError.invalidMove("Course folders can’t be moved. They are your courses.")
                case .folder:
                    guard let f = try Row.fetchOne(d, sql: "SELECT courseId, parentId FROM library_folders WHERE id = ? AND deletedAt IS NULL", arguments: [r.id]) else { throw LibraryError.notFound }
                    // No cycles: the destination can't be the folder itself or anything inside it.
                    var cur = parent
                    while let c = cur { if c == r.id { throw LibraryError.invalidMove("A folder can’t be moved into itself or one of its own subfolders.") }
                        cur = try UUID.fetchOne(d, sql: "SELECT parentId FROM library_folders WHERE id = ?", arguments: [c]) }
                    let old: UUID? = f["courseId"]
                    let name = try String.fetchOne(d, sql: "SELECT name FROM library_folders WHERE id = ?", arguments: [r.id])!
                    let unique = DocumentService.deduped(name, taken: try folderNames(d, course: course, parent: parent, excluding: r.id))
                    try d.execute(sql: "UPDATE library_folders SET parentId = ?, courseId = ?, name = ?, modifiedAt = ? WHERE id = ?", arguments: [parent, course, unique, now(), r.id])
                    if old != course { try reassignSubtree(d, root: r.id, course: course) }
                default:
                    guard let x = try Document.fetchOne(d, key: r.id), x.deletedAt == nil else { throw LibraryError.notFound }
                    let siblings = Set(try String.fetchAll(d, sql: "SELECT name FROM documents WHERE courseId IS ? AND folderId IS ? AND deletedAt IS NULL AND id != ?", arguments: [course, parent, x.id]).map { $0.lowercased() })
                    try d.execute(sql: "UPDATE documents SET courseId = ?, folderId = ?, name = ?, modifiedAt = ? WHERE id = ?", arguments: [course, parent, DocumentService.deduped(x.name, taken: siblings), now(), x.id])
                    if x.courseId != course { try d.execute(sql: "DELETE FROM document_assessments WHERE documentId = ?", arguments: [x.id]) }   // assessments belong to the old course
                }
            }
        }
    }

    private func reassignSubtree(_ d: Database, root: UUID, course: UUID?) throws {
        var frontier = [root]
        while !frontier.isEmpty {
            let ph = frontier.map { _ in "?" }.joined(separator: ",")
            try d.execute(sql: "DELETE FROM document_assessments WHERE documentId IN (SELECT id FROM documents WHERE folderId IN (\(ph)))", arguments: StatementArguments(frontier))   // assessments belong to the old course
            try d.execute(sql: "UPDATE documents SET courseId = ? WHERE folderId IN (\(ph))", arguments: StatementArguments([course] as [UUID?]) + StatementArguments(frontier))
            try d.execute(sql: "UPDATE library_folders SET courseId = ? WHERE parentId IN (\(ph))", arguments: StatementArguments([course] as [UUID?]) + StatementArguments(frontier))
            frontier = try UUID.fetchAll(d, sql: "SELECT id FROM library_folders WHERE parentId IN (\(ph))", arguments: StatementArguments(frontier))
        }
    }
}

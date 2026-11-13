import Foundation
import GRDB

/// Soft delete, restore and purge. Nothing is destroyed until `purgeAfter` (seven days) passes or the user explicitly deletes it now.
extension LibraryService {
    // MARK: Delete (recoverable)

    /// Files and folders. A folder takes everything inside it with it; restoring the folder brings it all back.
    public func softDelete(_ refs: [LibraryRef]) throws {
        let t = now(), until = t.addingTimeInterval(Self.retention)
        try db.write { d in
            for r in refs {
                switch r.kind {
                case .courseFolder: throw LibraryError.blocked("Delete a course from the Courses page.")
                case .folder:
                    var ids = [r.id], frontier = [r.id]
                    while !frontier.isEmpty {
                        let ph = frontier.map { _ in "?" }.joined(separator: ",")
                        frontier = try UUID.fetchAll(d, sql: "SELECT id FROM library_folders WHERE parentId IN (\(ph)) AND deletedAt IS NULL", arguments: StatementArguments(frontier))
                        ids += frontier
                    }
                    let ph = ids.map { _ in "?" }.joined(separator: ",")
                    try d.execute(sql: "UPDATE documents SET deletedAt = ?, purgeAfter = ?, deletedWith = ? WHERE folderId IN (\(ph)) AND deletedAt IS NULL", arguments: [t, until, r.id] + StatementArguments(ids))
                    try d.execute(sql: "UPDATE library_folders SET deletedAt = ?, purgeAfter = ?, deletedWith = ? WHERE id IN (\(ph)) AND id != ? AND deletedAt IS NULL", arguments: [t, until, r.id] + StatementArguments(ids) + [r.id])
                    try d.execute(sql: "UPDATE library_folders SET deletedAt = ?, purgeAfter = ?, deletedWith = NULL WHERE id = ?", arguments: [t, until, r.id])
                default:
                    try d.execute(sql: "UPDATE documents SET deletedAt = ?, purgeAfter = ?, deletedWith = NULL WHERE id = ? AND deletedAt IS NULL", arguments: [t, until, r.id])
                }
            }
        }
    }

    /// Courses: hidden everywhere (they reuse the existing "archived" exclusion that every study screen already honours).
    public func deleteCourse(_ id: UUID) throws {
        let t = now()
        try db.write { d in
            guard let r = try Row.fetchOne(d, sql: "SELECT archivedAt, deletedAt FROM courses WHERE id = ?", arguments: [id]), (r["deletedAt"] as Date?) == nil else { throw LibraryError.notFound }
            let wasArchived = (r["archivedAt"] as Date?) != nil
            try d.execute(sql: "UPDATE courses SET deletedAt = ?, purgeAfter = ?, archivedByDelete = ?, archivedAt = COALESCE(archivedAt, ?) WHERE id = ?",
                          arguments: [t, t.addingTimeInterval(Self.retention), !wasArchived, t, id])
        }
    }

    // MARK: Recently deleted

    public func recentlyDeleted() throws -> [DeletedItem] {
        let t = now()
        return try db.read { d in
            var out: [DeletedItem] = []
            for r in try Row.fetchAll(d, sql: "SELECT id, name, deletedAt, purgeAfter FROM courses WHERE deletedAt IS NOT NULL AND purgedAt IS NULL AND purgeAfter > ?", arguments: [t]) {
                let n = try Int.fetchOne(d, sql: "SELECT (SELECT COUNT(*) FROM documents WHERE courseId = ?) + (SELECT COUNT(*) FROM library_folders WHERE courseId = ?)", arguments: [r["id"] as UUID, r["id"] as UUID]) ?? 0
                out.append(DeletedItem(ref: LibraryRef(id: r["id"], kind: .courseFolder), name: r["name"], deletedAt: r["deletedAt"], purgeAfter: r["purgeAfter"], detail: "Course · \(n) item\(n == 1 ? "" : "s")"))
            }
            for r in try Row.fetchAll(d, sql: "SELECT id, name, deletedAt, purgeAfter FROM library_folders WHERE deletedAt IS NOT NULL AND deletedWith IS NULL AND purgeAfter > ? AND \(Self.liveCourse)", arguments: [t]) {
                let n = try Int.fetchOne(d, sql: "SELECT (SELECT COUNT(*) FROM documents WHERE deletedWith = ?) + (SELECT COUNT(*) FROM library_folders WHERE deletedWith = ?)", arguments: [r["id"] as UUID, r["id"] as UUID]) ?? 0
                out.append(DeletedItem(ref: LibraryRef(id: r["id"], kind: .folder), name: r["name"], deletedAt: r["deletedAt"], purgeAfter: r["purgeAfter"], detail: "Folder · \(n) item\(n == 1 ? "" : "s")"))
            }
            for x in try Document.fetchAll(d, sql: "SELECT * FROM documents WHERE deletedAt IS NOT NULL AND deletedWith IS NULL AND purgeAfter > ? AND \(Self.liveCourse)", arguments: [t]) {
                out.append(DeletedItem(ref: LibraryRef(id: x.id, kind: Self.entry(x).kind), name: x.name, deletedAt: x.deletedAt!, purgeAfter: x.purgeAfter!, detail: Self.entry(x).kind.label))
            }
            for r in try Row.fetchAll(d, sql: "SELECT s.id, s.title, s.deletedAt, (SELECT COUNT(*) FROM practice_set_items i WHERE i.setId = s.id) AS n FROM practice_sets s WHERE s.deletedAt IS NOT NULL") {
                let at: Date = r["deletedAt"], until = at.addingTimeInterval(Self.retention)
                guard until > t else { continue }
                let n: Int = r["n"]
                out.append(DeletedItem(ref: LibraryRef(id: r["id"], kind: .practiceSet), name: r["title"], deletedAt: at, purgeAfter: until, detail: "Practice set · \(n) question\(n == 1 ? "" : "s")"))
            }
            return out.sorted { $0.deletedAt > $1.deletedAt }
        }
    }

    // MARK: Restore

    public func restore(_ ref: LibraryRef) throws {
        let t = now()
        try db.write { d in
            switch ref.kind {
            case .courseFolder:
                guard let r = try Row.fetchOne(d, sql: "SELECT purgeAfter, archivedByDelete FROM courses WHERE id = ? AND deletedAt IS NOT NULL AND purgedAt IS NULL", arguments: [ref.id]) else { throw LibraryError.notFound }
                guard let p: Date = r["purgeAfter"], p > t else { throw LibraryError.expired }
                try d.execute(sql: "UPDATE courses SET deletedAt = NULL, purgeAfter = NULL, archivedAt = CASE WHEN archivedByDelete THEN NULL ELSE archivedAt END, archivedByDelete = 0 WHERE id = ?", arguments: [ref.id])
            case .folder:
                guard let r = try Row.fetchOne(d, sql: "SELECT purgeAfter, parentId FROM library_folders WHERE id = ? AND deletedAt IS NOT NULL", arguments: [ref.id]) else { throw LibraryError.notFound }
                guard let p: Date = r["purgeAfter"], p > t else { throw LibraryError.expired }
                try d.execute(sql: "UPDATE library_folders SET deletedAt = NULL, purgeAfter = NULL, deletedWith = NULL WHERE id = ? OR deletedWith = ?", arguments: [ref.id, ref.id])
                try d.execute(sql: "UPDATE documents SET deletedAt = NULL, purgeAfter = NULL, deletedWith = NULL WHERE deletedWith = ?", arguments: [ref.id])
                try reparentIfOrphaned(d, folder: ref.id, file: nil)
            case .practiceSet:
                guard let at = try Date.fetchOne(d, sql: "SELECT deletedAt FROM practice_sets WHERE id = ? AND deletedAt IS NOT NULL", arguments: [ref.id]) else { throw LibraryError.notFound }
                guard at.addingTimeInterval(Self.retention) > t else { throw LibraryError.expired }
                try d.execute(sql: "UPDATE practice_sets SET deletedAt = NULL, updatedAt = ? WHERE id = ?", arguments: [t, ref.id])
            default:
                guard let x = try Document.fetchOne(d, key: ref.id), x.deletedAt != nil else { throw LibraryError.notFound }
                guard let p = x.purgeAfter, p > t else { throw LibraryError.expired }
                try d.execute(sql: "UPDATE documents SET deletedAt = NULL, purgeAfter = NULL, deletedWith = NULL WHERE id = ?", arguments: [ref.id])
                try reparentIfOrphaned(d, folder: nil, file: ref.id)
            }
        }
    }

    /// If the place an item lived in was deleted meanwhile, it returns to the root of its course (or the Library) instead of into a hidden folder.
    private func reparentIfOrphaned(_ d: Database, folder: UUID?, file: UUID?) throws {
        if let f = folder {
            if let p = try UUID.fetchOne(d, sql: "SELECT parentId FROM library_folders WHERE id = ?", arguments: [f]),
               try Bool.fetchOne(d, sql: "SELECT deletedAt IS NOT NULL FROM library_folders WHERE id = ?", arguments: [p]) == true {
                try d.execute(sql: "UPDATE library_folders SET parentId = NULL WHERE id = ?", arguments: [f])
            }
        }
        if let x = file, let p = try UUID.fetchOne(d, sql: "SELECT folderId FROM documents WHERE id = ?", arguments: [x]),
           try Bool.fetchOne(d, sql: "SELECT deletedAt IS NOT NULL FROM library_folders WHERE id = ?", arguments: [p]) == true {
            try d.execute(sql: "UPDATE documents SET folderId = NULL WHERE id = ?", arguments: [x])
        }
    }

    // MARK: Permanent deletion

    /// Deletes one recoverable item now (the UI asks twice before calling this).
    public func purge(_ ref: LibraryRef) throws {
        switch ref.kind {
        case .courseFolder: try purgeCourse(ref.id)
        case .practiceSet: try db.write { try $0.execute(sql: "DELETE FROM practice_sets WHERE id = ? AND deletedAt IS NOT NULL", arguments: [ref.id]) }   // its questions and past attempts are untouched
        case .folder:
            let paths = try db.write { d -> [String] in
                let ps = try String.fetchAll(d, sql: "SELECT storedPath FROM documents WHERE deletedWith = ?", arguments: [ref.id])
                try d.execute(sql: "DELETE FROM documents WHERE deletedWith = ?", arguments: [ref.id])
                try d.execute(sql: "DELETE FROM library_folders WHERE id = ? OR deletedWith = ?", arguments: [ref.id, ref.id])
                return ps
            }
            try removeFiles(paths)
        default:
            let path = try db.write { d -> String? in
                let p = try String.fetchOne(d, sql: "SELECT storedPath FROM documents WHERE id = ? AND deletedAt IS NOT NULL", arguments: [ref.id])
                try d.execute(sql: "DELETE FROM documents WHERE id = ? AND deletedAt IS NOT NULL", arguments: [ref.id])
                return p
            }
            try removeFiles(path.map { [$0] } ?? [])
        }
    }

    /// Removes a course's materials and folders for good. The course row and its study history stay (hidden, tombstoned):
    /// learning evidence is append-only in this database, so a purge deliberately never cascades into it.
    func purgeCourse(_ id: UUID) throws {
        let paths = try db.write { d -> [String] in
            let ps = try String.fetchAll(d, sql: "SELECT storedPath FROM documents WHERE courseId = ?", arguments: [id])
            try d.execute(sql: "DELETE FROM documents WHERE courseId = ?", arguments: [id])
            try d.execute(sql: "DELETE FROM library_folders WHERE courseId = ?", arguments: [id])
            try d.execute(sql: "UPDATE courses SET purgedAt = ? WHERE id = ? AND deletedAt IS NOT NULL", arguments: [now(), id])
            return ps
        }
        try removeFiles(paths)
    }

    /// Runs at launch and whenever the Library or Courses opens: no timer is involved, so retention survives restarts.
    @discardableResult
    public func purgeExpired() throws -> Int {
        let t = now()
        var n = 0
        let courses = try db.read { try UUID.fetchAll($0, sql: "SELECT id FROM courses WHERE deletedAt IS NOT NULL AND purgedAt IS NULL AND purgeAfter <= ?", arguments: [t]) }
        for c in courses { try purgeCourse(c); n += 1 }
        n += try db.write { d in try d.execute(sql: "DELETE FROM practice_sets WHERE deletedAt IS NOT NULL AND deletedAt <= ?", arguments: [t.addingTimeInterval(-Self.retention)]); return d.changesCount }
        let paths = try db.write { d -> [String] in
            let ps = try String.fetchAll(d, sql: "SELECT storedPath FROM documents WHERE deletedAt IS NOT NULL AND purgeAfter <= ?", arguments: [t])
            try d.execute(sql: "DELETE FROM documents WHERE deletedAt IS NOT NULL AND purgeAfter <= ?", arguments: [t])
            try d.execute(sql: "DELETE FROM library_folders WHERE deletedAt IS NOT NULL AND purgeAfter <= ?", arguments: [t])
            return ps
        }
        try removeFiles(paths)
        return n + paths.count
    }

    /// Deletes stored copies only when no remaining record points at the same stored path, so a shared copy can never be destroyed.
    func removeFiles(_ paths: [String]) throws {
        let fm = FileManager.default
        for p in Set(paths) {
            let stillUsed = try db.read { try Bool.fetchOne($0, sql: "SELECT EXISTS (SELECT 1 FROM documents WHERE storedPath = ?)", arguments: [p]) ?? false }
            guard !stillUsed else { continue }
            let dir = storage.url(forStoredPath: p).deletingLastPathComponent()
            guard dir.path.hasPrefix(storage.root.path), dir.lastPathComponent != storage.root.lastPathComponent else { continue }   // never leave managed storage
            try? fm.removeItem(at: dir)
        }
    }
}

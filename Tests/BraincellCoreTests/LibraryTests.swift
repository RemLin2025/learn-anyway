import Testing
import Foundation
import GRDB
@testable import BraincellCore

final class TestClock: @unchecked Sendable {
    private let l = NSLock(); private var t: Date
    init(_ t: Date = Date(timeIntervalSince1970: 1_800_000_000)) { self.t = t }
    var now: Date { l.withLock { t } }
    func advance(_ s: TimeInterval) { l.withLock { t = t.addingTimeInterval(s) } }
}

@Suite struct LibraryTests {
    struct Env { let db: AppDatabase; let lib: LibraryService; let courses: CourseService; let clock: TestClock; let dir: URL; let storage: ManagedStorage }
    func env() throws -> Env {
        let dir = try tempDir(); let db = try AppDatabase.inMemory(); let clock = TestClock(); let st = ManagedStorage(root: dir.appendingPathComponent("store"))
        return Env(db: db, lib: LibraryService(db: db, storage: st, now: { clock.now }), courses: CourseService(db: db), clock: clock, dir: dir, storage: st)
    }
    func file(_ e: Env, _ name: String, _ content: String = "x") throws -> URL {
        let u = e.dir.appendingPathComponent("src").appendingPathComponent(name)
        try FileManager.default.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(content.utf8).write(to: u); return u
    }
    func names(_ es: [LibraryEntry]) -> [String] { es.map(\.name) }
    func storedExists(_ e: Env, _ x: LibraryEntry) -> Bool { FileManager.default.fileExists(atPath: e.lib.fileURL(x)!.path) }

    // MARK: Migration

    @Test func migrationPreservesExistingMaterials() throws {
        let q = try DatabaseQueue(configuration: AppDatabase.configuration)
        try AppDatabase.migrator(upTo: nil).migrate(q, upTo: "v11_ai_gateway")
        let cid = UUID(), did = UUID(), chunk = UUID(), aid = UUID()
        try q.write { d in
            try d.execute(sql: "INSERT INTO courses (id, name, kind, createdAt) VALUES (?, 'Old', 'structured', ?)", arguments: [cid, Date()])
            try d.execute(sql: "INSERT INTO assessments (id, courseId, name, kind, isCumulative, createdAt) VALUES (?, ?, 'Final', 'final', 1, ?)", arguments: [aid, cid, Date()])
            try d.execute(sql: "INSERT INTO documents (id, courseId, title, originalFilename, storedPath, sha256, byteCount, kind, extractionStatus, extractionMethod, importedAt) VALUES (?, ?, 'Notes', 'Notes.pdf', 'Documents/x/original.pdf', 'abc', 10, 'pdf', 'ok', 'pdfkit-text', ?)", arguments: [did, cid, Date()])
            try d.execute(sql: "INSERT INTO document_chunks (id, documentId, ordinal, text) VALUES (?, ?, 0, 'hello')", arguments: [chunk, did])
            try d.execute(sql: "INSERT INTO document_assessments (documentId, assessmentId) VALUES (?, ?)", arguments: [did, aid])
        }
        let db = try AppDatabase(q)                                          // applies v12
        let doc = try #require(try db.read { try Document.fetchOne($0, key: did) })
        #expect(doc.courseId == cid && doc.name == "Notes.pdf" && doc.title == "Notes" && doc.folderId == nil && !doc.favorite && doc.deletedAt == nil)
        #expect(try db.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM document_chunks WHERE documentId = ?", arguments: [did]) } == 1)
        #expect(try db.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM document_assessments WHERE documentId = ?", arguments: [did]) } == 1)
        #expect(try DocumentService(db: db, storage: ManagedStorage(root: URL(fileURLWithPath: "/tmp"))).documents(courseId: cid).map(\.id) == [did])
        #expect(try db.read { try Row.fetchAll($0, sql: "PRAGMA foreign_key_check").isEmpty })
    }

    // MARK: Materials and Library are one store

    @Test func courseFolderFollowsRenameAndShowsMaterials() throws {
        let e = try env()
        let c = try e.courses.createCourse(name: "COMP211")
        let r = e.lib.importFiles([try file(e, "notes.txt", "hello"), try file(e, "pic.png", "p"), try file(e, "clip.mp4", "v"), try file(e, "weird.xyz", "w")], into: .course(c.id))
        #expect(r.imported == 4 && r.failures.isEmpty)
        let root = try e.lib.list(.root)
        let folder = try #require(root.first { $0.kind == .courseFolder })
        #expect(folder.id == c.id && folder.name == "COMP211" && folder.childCount == 4)
        #expect(Set(names(try e.lib.list(.course(c.id)))) == ["notes.txt", "pic.png", "clip.mp4", "weird.xyz"])
        let kinds = Dictionary(uniqueKeysWithValues: try e.lib.list(.course(c.id)).map { ($0.name, $0.kind) })
        #expect(kinds["pic.png"] == .image && kinds["clip.mp4"] == .video && kinds["weird.xyz"] == .other && kinds["notes.txt"] == .text)
        try e.lib.rename(LibraryRef(id: c.id, kind: .courseFolder), to: "Systems Programming")
        #expect(try e.lib.list(.root).first { $0.kind == .courseFolder }?.name == "Systems Programming")
        #expect(try e.lib.breadcrumbs(.course(c.id)).map(\.name) == ["Library", "Systems Programming"])
        // Study generation still sees only the course's text material.
        #expect(try DocumentService(db: e.db, storage: e.storage).documents(courseId: c.id).count == 4)
    }

    @Test func nestedFolderImportKeepsHierarchyAndIsSafe() throws {
        let e = try env()
        let c = try e.courses.createCourse(name: "C")
        _ = try file(e, "Tree/a.txt", "a"); _ = try file(e, "Tree/Sub/b.png", "b"); _ = try file(e, "Tree/Sub/Deep/c.mp4", "c"); _ = try file(e, "Tree/.hidden", "h")
        _ = try file(e, "Tree/Sub/copy-of-a.txt", "a")                         // same bytes, different folder: must still be imported
        let outside = try file(e, "outside/secret.txt", "secret")
        try FileManager.default.createSymbolicLink(at: e.dir.appendingPathComponent("src/Tree/link.txt"), withDestinationURL: outside)
        try FileManager.default.createSymbolicLink(at: e.dir.appendingPathComponent("src/Tree/Sub/loop"), withDestinationURL: e.dir.appendingPathComponent("src/Tree"))
        let r = e.lib.importFolder(e.dir.appendingPathComponent("src/Tree"), into: .course(c.id))
        #expect(r.imported == 4 && r.folders == 3 && r.skipped == 2 && r.failures.isEmpty, "\(r.summary)")
        let top = try e.lib.list(.course(c.id)); let tree = try #require(top.first)
        #expect(tree.name == "Tree" && tree.isFolder && tree.childCount == 2)
        let level1 = try e.lib.list(.folder(tree.id)); #expect(Set(names(level1)) == ["a.txt", "Sub"])
        let sub = try #require(level1.first { $0.name == "Sub" })
        #expect(Set(names(try e.lib.list(.folder(sub.id)))) == ["b.png", "Deep", "copy-of-a.txt"])
        #expect(try e.lib.breadcrumbs(.folder(sub.id)).map(\.name) == ["Library", "C", "Tree", "Sub"])
        let again = e.lib.importFolder(e.dir.appendingPathComponent("src/Tree"), into: .course(c.id))   // same name again: no overwrite
        #expect(try e.lib.list(.course(c.id)).filter(\.isFolder).map(\.name).sorted() == ["Tree", "Tree 2"] && again.imported == 4)
        #expect(try e.lib.list(.root, { var q = LibraryQuery(); q.text = "secret"; return q }()).isEmpty)           // nothing outside the tree was read
    }

    @Test func importReportsUnreadableAndMissingFiles() throws {
        let e = try env()
        let r = e.lib.importFiles([e.dir.appendingPathComponent("nope.txt"), try file(e, "ok.txt")], into: .root)
        #expect(r.imported == 1 && r.failures.count == 1)
        #expect(e.lib.importFiles([try file(e, "z.txt")], into: .folder(UUID())).failures.count == 1)
    }

    @Test func renameAndMoveAreOneRecordSeenEverywhere() throws {
        let e = try env()
        let a = try e.courses.createCourse(name: "A"), b = try e.courses.createCourse(name: "B")
        _ = e.lib.importFiles([try file(e, "doc.txt", "1")], into: .course(a.id))
        let f = try e.lib.createFolder("Slides", in: .course(a.id))
        let x = try #require(try e.lib.list(.course(a.id)).first { $0.name == "doc.txt" })
        try e.lib.rename(x.ref, to: "lecture")                                      // bare name keeps the extension
        try e.lib.move([x.ref], to: .folder(f))
        #expect(names(try e.lib.list(.folder(f))) == ["lecture.txt"])
        var q = LibraryQuery(); q.text = "lecture"
        #expect(try e.lib.list(.root, q).map(\.id) == [x.id] && (try e.lib.list(.course(a.id), q)).map(\.id) == [x.id])       // same id from both entry points
        try e.lib.move([x.ref], to: .course(b.id))                                   // across courses: courseId changes, bytes don't
        #expect(try DocumentService(db: e.db, storage: e.storage).documents(courseId: a.id).isEmpty && DocumentService(db: e.db, storage: e.storage).documents(courseId: b.id).count == 1)
        try e.lib.move([x.ref], to: .root)                                           // out to the global Library
        #expect(try e.lib.list(.root).contains { $0.id == x.id } && (try e.db.read { try Document.fetchOne($0, key: x.id)?.courseId }) == nil)
        #expect(try e.db.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM documents") } == 1)                           // never duplicated
        #expect(storedExists(e, x))
    }

    @Test func movesAreSafe() throws {
        let e = try env()
        let a = try e.courses.createCourse(name: "A"), b = try e.courses.createCourse(name: "B")
        let top = try e.lib.createFolder("Top", in: .course(a.id)), mid = try e.lib.createFolder("Mid", in: .folder(top))
        _ = e.lib.importFiles([try file(e, "deep.txt", "d")], into: .folder(mid))
        #expect(throws: LibraryError.self) { try e.lib.move([LibraryRef(id: top, kind: .folder)], to: .folder(mid)) }        // cycle
        #expect(throws: LibraryError.self) { try e.lib.move([LibraryRef(id: top, kind: .folder)], to: .folder(top)) }
        #expect(throws: LibraryError.self) { try e.lib.move([LibraryRef(id: a.id, kind: .courseFolder)], to: .root) }         // courses aren't movable
        try e.lib.move([LibraryRef(id: top, kind: .folder)], to: .course(b.id))                                              // subtree changes owner
        let deep = try #require(try e.lib.list(.root, { var q = LibraryQuery(); q.text = "deep"; return q }()).first)
        #expect(deep.courseId == b.id)
        // Name clash on move gets a suffix, never an overwrite.
        let t2 = try e.lib.createFolder("Top", in: .course(a.id))
        try e.lib.move([LibraryRef(id: t2, kind: .folder)], to: .course(b.id))
        #expect(try e.lib.list(.course(b.id)).map(\.name).sorted() == ["Top", "Top 2"])
    }

    // MARK: Deletion and the seven-day boundary

    @Test func deletedCourseDisappearsEverywhereAndRestoresWithinSevenDays() throws {
        let e = try env()
        let c = try e.courses.createCourse(name: "Gone"), keep = try e.courses.createCourse(name: "Keep")
        _ = e.lib.importFiles([try file(e, "m.txt", "m")], into: .course(c.id))
        try e.lib.createFolder("Sub", in: .course(c.id))
        try e.lib.deleteCourse(c.id)
        #expect(try e.courses.courses().map(\.id) == [keep.id])
        #expect(try e.lib.list(.root).filter { $0.kind == .courseFolder }.map(\.name) == ["Keep"])
        #expect(try e.lib.list(.root, { var q = LibraryQuery(); q.text = "m.txt"; return q }()).isEmpty)
        let item = try #require(try e.lib.recentlyDeleted().first)
        #expect(item.name == "Gone" && item.deletedAt == e.clock.now && item.purgeAfter == e.clock.now.addingTimeInterval(7 * 86400) && item.detail.contains("2 items"))
        e.clock.advance(7 * 86400 - 1)                                                  // one second before expiry
        try e.lib.restore(item.ref)
        #expect(try Set(try e.courses.courses().map(\.id)) == [c.id, keep.id] && (try e.lib.recentlyDeleted()).isEmpty)
        #expect(names(try e.lib.list(.course(c.id))).sorted() == ["Sub", "m.txt"])      // associations came back with it
    }

    @Test func archivedStateSurvivesDeleteAndRestore() throws {
        let e = try env()
        let c = try e.courses.createCourse(name: "Old")
        try e.courses.archiveCourse(c.id)
        try e.lib.deleteCourse(c.id); try e.lib.restore(LibraryRef(id: c.id, kind: .courseFolder))
        #expect(try e.courses.courses().isEmpty && e.courses.courses(includeArchived: true).count == 1)     // still archived, not accidentally revived
    }

    @Test func expiryBoundaryPurgesMaterialsButNotSharedFiles() throws {
        let e = try env()
        let c = try e.courses.createCourse(name: "Doomed"), other = try e.courses.createCourse(name: "Other")
        _ = e.lib.importFiles([try file(e, "own.txt", "own"), try file(e, "moved.txt", "moved"), try file(e, "shared.txt", "shared")], into: .course(c.id))
        let es = try e.lib.list(.course(c.id)); let own = es.first { $0.name == "own.txt" }!, moved = es.first { $0.name == "moved.txt" }!, shared = es.first { $0.name == "shared.txt" }!
        try e.lib.move([moved.ref], to: .root)                                                  // rescued into the global Library before deletion
        _ = e.lib.importFiles([try file(e, "keep.txt", "k")], into: .course(other.id))
        let keepFile = try #require(try e.lib.list(.course(other.id)).first)
        // Another record pointing at the same stored copy (e.g. a future "reference"): its file must survive.
        try e.db.write { d in try d.execute(sql: "INSERT INTO documents (id, courseId, title, originalFilename, name, storedPath, sha256, byteCount, kind, extractionStatus, extractionMethod, importedAt, modifiedAt) SELECT ?, ?, title, originalFilename, name, storedPath, sha256, byteCount, kind, extractionStatus, extractionMethod, importedAt, modifiedAt FROM documents WHERE id = ?", arguments: [UUID(), other.id, shared.id]) }
        try e.lib.deleteCourse(c.id)
        e.clock.advance(7 * 86400 - 1)
        #expect(try e.lib.purgeExpired() == 0 && storedExists(e, own))                           // a second before: nothing happens
        e.clock.advance(1)                                                                       // exactly at expiry
        #expect(throws: LibraryError.expired) { try e.lib.restore(LibraryRef(id: c.id, kind: .courseFolder)) }   // too late to restore even before the purge runs
        #expect(try e.lib.purgeExpired() == 1)
        #expect(!storedExists(e, own))
        #expect(storedExists(e, moved) && storedExists(e, keepFile))
        #expect(storedExists(e, shared))                                                        // still referenced by another record
        #expect(throws: LibraryError.notFound) { try e.lib.restore(LibraryRef(id: c.id, kind: .courseFolder)) }
        #expect(try e.lib.recentlyDeleted().isEmpty && e.courses.courses().map(\.id) == [other.id])
        #expect(try e.db.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM documents WHERE courseId = ?", arguments: [c.id]) } == 0)
        #expect(try e.db.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM courses WHERE id = ?", arguments: [c.id]) } == 1)   // study history untouched
    }

    @Test func fileAndFolderDeletionIsRecoverable() throws {
        let e = try env()
        let c = try e.courses.createCourse(name: "C")
        let f = try e.lib.createFolder("Box", in: .course(c.id))
        _ = e.lib.importFiles([try file(e, "in.txt", "i")], into: .folder(f)); _ = e.lib.importFiles([try file(e, "top.txt", "t")], into: .course(c.id))
        let top = try #require(try e.lib.list(.course(c.id)).first { $0.name == "top.txt" })
        try e.lib.softDelete([top.ref, LibraryRef(id: f, kind: .folder)])
        #expect(try e.lib.list(.course(c.id)).isEmpty && DocumentService(db: e.db, storage: e.storage).documents(courseId: c.id).isEmpty)
        let del = try e.lib.recentlyDeleted(); #expect(Set(del.map(\.name)) == ["top.txt", "Box"] && del.first { $0.name == "Box" }!.detail.contains("1 item"))
        try e.lib.restore(del.first { $0.name == "Box" }!.ref); try e.lib.restore(top.ref)
        #expect(try Set(names(try e.lib.list(.course(c.id)))) == ["Box", "top.txt"] && names(try e.lib.list(.folder(f))) == ["in.txt"])
        // Purging now (explicit) removes the file for good.
        try e.lib.softDelete([top.ref]); try e.lib.purge(top.ref)
        #expect(try !storedExists(e, top) && (try e.lib.recentlyDeleted()).isEmpty)
        // Expiry of a single file.
        let kept = try #require(try e.lib.list(.folder(f)).first)
        try e.lib.softDelete([kept.ref]); e.clock.advance(7 * 86400)
        #expect(throws: LibraryError.expired) { try e.lib.restore(kept.ref) }
        #expect(try e.lib.purgeExpired() == 1 && !storedExists(e, kept))
    }

    @Test func restoringIntoADeletedFolderFallsBackToTheRoot() throws {
        let e = try env()
        let f = try e.lib.createFolder("F", in: .root)
        _ = e.lib.importFiles([try file(e, "x.txt")], into: .folder(f))
        let x = try #require(try e.lib.list(.folder(f)).first)
        try e.lib.softDelete([x.ref]); try e.lib.softDelete([LibraryRef(id: f, kind: .folder)])
        try e.lib.restore(x.ref)
        #expect(try e.lib.list(.root).contains { $0.id == x.id })
    }

    // MARK: Browsing features

    @Test func filtersSortFavoritesAndSearch() throws {
        let e = try env()
        _ = e.lib.importFiles([try file(e, "b.txt", "bb"), try file(e, "a.png", "aaa"), try file(e, "c.mp4", "c"), try file(e, "d.docx", "doc")], into: .root)
        try e.lib.createFolder("Folder", in: .root)
        func q(_ f: (inout LibraryQuery) -> Void) -> LibraryQuery { var x = LibraryQuery(); f(&x); return x }
        #expect(names(try e.lib.list(.root)) == ["Folder", "a.png", "b.txt", "c.mp4", "d.docx"])                      // folders first, then by name
        #expect(try names(try e.lib.list(.root, q { $0.filter = .images })) == ["a.png"] && names(try e.lib.list(.root, q { $0.filter = .videos })) == ["c.mp4"])
        #expect(try names(try e.lib.list(.root, q { $0.filter = .folders })) == ["Folder"] && Set(names(try e.lib.list(.root, q { $0.filter = .documents }))) == ["b.txt", "d.docx"])
        #expect(names(try e.lib.list(.root, q { $0.sort = .name; $0.ascending = false })) == ["Folder", "d.docx", "c.mp4", "b.txt", "a.png"])
        #expect(try e.lib.list(.root, q { $0.sort = .type }).dropFirst().first?.kind == .other)      // labels sort File < Image < Text
        let c = try #require(try e.lib.list(.root).first { $0.name == "c.mp4" })
        try e.lib.setFavorite([c.ref], true)
        #expect(names(try e.lib.list(.root, q { $0.favoritesOnly = true })) == ["c.mp4"])
        #expect(names(try e.lib.list(.root, q { $0.text = "PNG" })) == ["a.png"])                                     // matches the type label too
        e.clock.advance(60); try e.lib.rename(c.ref, to: "z.mp4")
        #expect(try e.lib.list(.root, q { $0.sort = .dateModified; $0.ascending = false }).first { !$0.isFolder }?.name == "z.mp4")
        #expect(throws: LibraryError.emptyName) { try e.lib.rename(c.ref, to: "  ") }
    }

    @Test func largeLibraryStaysFast() throws {
        let e = try env()
        let c = try e.courses.createCourse(name: "Big")
        try e.db.write { d in
            for i in 0..<4000 {
                try d.execute(sql: "INSERT INTO documents (id, courseId, title, originalFilename, name, storedPath, sha256, byteCount, kind, extractionStatus, extractionMethod, importedAt, modifiedAt) VALUES (?, ?, 'f', 'f', ?, 'Documents/x/original.txt', ?, 1, 'text', 'ok', 'plain-text', ?, ?)",
                              arguments: [UUID(), i % 2 == 0 ? c.id : nil, "file \(i).txt", "h\(i)", Date(), Date()])
            }
        }
        var q = LibraryQuery(); q.text = "file 39"
        let t0 = Date()
        let all = try e.lib.list(.root, LibraryQuery()), hit = try e.lib.list(.root, q), flat = try e.lib.list(.course(c.id), { var x = LibraryQuery(); x.filter = .documents; return x }())
        let ms = Date().timeIntervalSince(t0) * 1000
        #expect(all.count == 2001 && flat.count == 2000 && hit.count == (0..<4000).filter { String($0).contains("39") }.count)    // every word must match somewhere in the name
        #expect(ms < 1500, "browse + search + filter over 4000 records took \(ms) ms")
    }
}

import Foundation
import GRDB

extension LibraryService {
    /// Imports files into a Library location. Failures are collected, not thrown, so one bad file doesn't abort the rest.
    /// Checks for cancellation between files; everything already imported stays imported.
    public func importFiles(_ urls: [URL], into l: LibraryLocation, progress: (@Sendable (Int, Int) -> Void)? = nil) -> LibraryImportReport {
        var report = LibraryImportReport()
        let (course, folder): (UUID?, UUID?)
        do { (course, folder) = try db.read { try scopeFor(l, $0) } } catch { report.failures.append(.init(path: "Library", message: error.localizedDescription)); return report }
        for (i, u) in urls.enumerated() {
            if Task.isCancelled { report.cancelled = true; break }
            progress?(i, urls.count)
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: u.path, isDirectory: &isDir), isDir.boolValue {
                let r = importFolder(u, into: l); report.imported += r.imported; report.duplicates += r.duplicates; report.folders += r.folders; report.skipped += r.skipped; report.failures += r.failures
                if r.cancelled { report.cancelled = true; break }
                continue
            }
            do { let r = try docs.importAnyFile(at: u, courseId: course, folderId: folder); if r.wasDuplicate { report.duplicates += 1 } else { report.imported += 1 } }
            catch { report.failures.append(.init(path: u.lastPathComponent, message: error.localizedDescription)) }
        }
        progress?(urls.count, urls.count)
        return report
    }

    /// Mirrors a folder tree. Symlinks are never followed (so nothing outside the chosen tree is read and loops are impossible),
    /// hidden files are skipped, and name clashes get a numeric suffix.
    public func importFolder(_ url: URL, into l: LibraryLocation) -> LibraryImportReport {
        var report = LibraryImportReport()
        do {
            let root = try createFolder(url.lastPathComponent, in: l)
            report.folders += 1
            let (course, _) = try db.read { try scopeFor(.folder(root), $0) }
            walk(url, parent: root, course: course, depth: 0, report: &report)
        } catch { report.failures.append(.init(path: url.lastPathComponent, message: error.localizedDescription)) }
        return report
    }

    private func walk(_ dir: URL, parent: UUID, course: UUID?, depth: Int, report: inout LibraryImportReport) {
        guard depth < 32 else { report.skipped += 1; report.failures.append(.init(path: dir.lastPathComponent, message: "Folders nested deeper than 32 levels were skipped.")); return }
        let keys: [URLResourceKey] = [.isSymbolicLinkKey, .isDirectoryKey, .isRegularFileKey]
        let items: [URL]
        do { items = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]) }
        catch { report.failures.append(.init(path: dir.lastPathComponent, message: "Couldn’t read this folder.")); return }
        for u in items.sorted(by: { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }) {
            if Task.isCancelled { report.cancelled = true; return }
            let v = try? u.resourceValues(forKeys: Set(keys))
            if v?.isSymbolicLink == true { report.skipped += 1; continue }
            if v?.isDirectory == true {
                do { let f = try createFolder(u.lastPathComponent, in: .folder(parent)); report.folders += 1; walk(u, parent: f, course: course, depth: depth + 1, report: &report) }
                catch { report.failures.append(.init(path: u.lastPathComponent, message: error.localizedDescription)) }
            } else if v?.isRegularFile == true {
                do { let r = try docs.importAnyFile(at: u, courseId: course, folderId: parent); if r.wasDuplicate { report.duplicates += 1 } else { report.imported += 1 } }
                catch { report.failures.append(.init(path: u.lastPathComponent, message: error.localizedDescription)) }
            } else { report.skipped += 1 }
        }
    }

    func scopeFor(_ l: LibraryLocation, _ d: Database) throws -> (UUID?, UUID?) {
        switch l {
        case .root: return (nil, nil)
        case .course(let c):
            guard try Bool.fetchOne(d, sql: "SELECT archivedAt IS NULL FROM courses WHERE id = ?", arguments: [c]) == true else { throw LibraryError.notFound }
            return (c, nil)
        case .folder(let f):
            guard let row = try Row.fetchOne(d, sql: "SELECT courseId FROM library_folders WHERE id = ? AND deletedAt IS NULL", arguments: [f]) else { throw LibraryError.notFound }
            return (row["courseId"], f)
        }
    }

    /// Absolute location of the stored copy, for previews and "Reveal in Finder".
    public func fileURL(_ e: LibraryEntry) -> URL? { e.storedPath.map { storage.url(forStoredPath: $0) } }
}

public struct LibraryDestination: Identifiable, Hashable, Sendable {
    public var id: String { "\(location)" }
    public let location: LibraryLocation; public let name: String; public let depth: Int
}

extension LibraryService {
    /// Every place something can be moved to: the Library root, then each global folder and each live course with its folders, indented by depth.
    public func destinations() throws -> [LibraryDestination] {
        try db.read { d in
            let folders = try Row.fetchAll(d, sql: "SELECT id, parentId, courseId, name FROM library_folders WHERE deletedAt IS NULL ORDER BY name COLLATE NOCASE")
            func tree(course: UUID?, parent: UUID?, depth: Int) -> [LibraryDestination] {
                folders.filter { ($0["courseId"] as UUID?) == course && ($0["parentId"] as UUID?) == parent }.flatMap { f -> [LibraryDestination] in
                    [LibraryDestination(location: .folder(f["id"]), name: f["name"], depth: depth)] + tree(course: course, parent: f["id"], depth: depth + 1)
                }
            }
            var out = [LibraryDestination(location: .root, name: "Library", depth: 0)] + tree(course: nil, parent: nil, depth: 1)
            for c in try Row.fetchAll(d, sql: "SELECT id, name FROM courses WHERE archivedAt IS NULL ORDER BY name COLLATE NOCASE") {
                out.append(LibraryDestination(location: .course(c["id"]), name: c["name"], depth: 0))
                out += tree(course: c["id"], parent: nil, depth: 1)
            }
            return out
        }
    }

    /// Everything the Get Info sheet shows, from one record.
    public func info(_ id: UUID) throws -> [(String, String)] {
        try db.read { d in
            guard let x = try Document.fetchOne(d, key: id) else { throw LibraryError.notFound }
            let course = try x.courseId.flatMap { try String.fetchOne(d, sql: "SELECT name FROM courses WHERE id = ?", arguments: [$0]) } ?? "Library (no course)"
            var rows = [("Name", x.name), ("Kind", Self.entry(x).kind.label), ("Size", ByteCountFormatter.string(fromByteCount: Int64(x.byteCount), countStyle: .file)),
                        ("Location", course), ("Added", x.importedAt.formatted()), ("Modified", x.modifiedAt.formatted()), ("Original file name", x.originalFilename)]
            if let p = x.pageCount { rows.append(("Pages", "\(p)")) }
            if x.kind == .pdf || x.kind == .text || x.kind == .pasted { rows.append(("Text extraction", x.extractionStatus == .ok ? "Complete" : x.extractionStatus == .partial ? "\(x.lowContentPageCount) low-content page(s)" : "No text found")) }
            return rows
        }
    }
}

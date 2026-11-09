import Foundation
import GRDB
import CryptoKit
import PDFKit

public enum DocumentError: Error, Equatable, LocalizedError {
    case unsupportedType(String)
    case tooLarge(Int)
    case notAPDF
    case lockedPDF
    case emptyText
    case unreadable
    case notFound

    public var errorDescription: String? {
        switch self {
        case .unsupportedType(let e): "“.\(e)” files aren’t supported yet. Supported: PDF, TXT, Markdown, or pasted text."
        case .tooLarge(let mb): "That file is larger than the \(mb) MB limit."
        case .notAPDF: "That file isn’t a valid PDF."
        case .lockedPDF: "That PDF is password-protected. Remove the password and try again."
        case .emptyText: "There is no text to import."
        case .unreadable: "The file couldn’t be read."
        case .notFound: "That course no longer exists."
        }
    }
}

/// Where managed copies of imported files live. Injectable so tests use a temp directory.
public struct ManagedStorage: Sendable {
    public let root: URL
    public init(root: URL) { self.root = root }

    public static func defaultRoot() -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Braincell", isDirectory: true)
    }

    /// The pre-rename (CramLab) data folder.
    public static func legacyRoot() -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("CramLab", isDirectory: true)
    }

    /// First launch after the CramLab → Braincell rename: copies the old data folder to `new` (the old one is left
    /// untouched) and renames its database files. Does nothing when `new` already exists or `old` doesn't.
    /// The copy is built beside `new` and moved into place, so a failure never leaves a half-migrated folder.
    @discardableResult
    public static func migrateLegacy(from old: URL, to new: URL) throws -> Bool {
        let fm = FileManager.default
        guard fm.fileExists(atPath: old.path), !fm.fileExists(atPath: new.path) else { return false }
        let tmp = new.deletingLastPathComponent().appendingPathComponent(new.lastPathComponent + ".migrating", isDirectory: true)
        try? fm.removeItem(at: tmp)
        try fm.copyItem(at: old, to: tmp)
        for suffix in ["", "-wal", "-shm"] {
            let from = tmp.appendingPathComponent("cramlab.sqlite" + suffix)
            if fm.fileExists(atPath: from.path) { try fm.moveItem(at: from, to: tmp.appendingPathComponent("braincell.sqlite" + suffix)) }
        }
        try fm.moveItem(at: tmp, to: new)
        return true
    }

    public func url(forStoredPath p: String) -> URL { root.appendingPathComponent(p) }
}

public struct ExtractedPage: Sendable, Equatable {
    public var pageNumber: Int?
    public var text: String
}

public struct ImportResult: Sendable {
    public var document: Document
    /// True when identical bytes were already imported into this course; nothing was written.
    public var wasDuplicate: Bool
}

/// Copies files into managed storage, records provenance, extracts text with page references.
/// Never replaces reliable extracted text with OCR (OCR is not implemented yet; scans are flagged).
public struct DocumentService: Sendable {
    public static let maxFileBytes = 100 * 1024 * 1024
    public static let maxTextChars = 5_000_000
    public static let lowContentThreshold = 25
    static let chunkTarget = 2_000

    let db: AppDatabase
    let storage: ManagedStorage
    public init(db: AppDatabase, storage: ManagedStorage) { self.db = db; self.storage = storage }

    static let imageExts: Set<String> = ["png", "jpg", "jpeg", "gif", "heic", "heif", "tif", "tiff", "bmp", "webp"]
    static let videoExts: Set<String> = ["mp4", "mov", "m4v", "avi", "mkv", "webm"]
    /// Larger than text limits: these files are copied and hashed in a stream, never loaded into memory.
    public static let maxBinaryBytes = 4 * 1024 * 1024 * 1024

    public static func kind(forExtension ext: String) -> DocumentKind {
        switch ext.lowercased() {
        case "pdf": .pdf
        case "txt", "md", "markdown", "text": .text
        case let e where imageExts.contains(e): .image
        case let e where videoExts.contains(e): .video
        default: .other
        }
    }

    /// Study-material import: only PDF and text, because only those can feed question generation.
    public func importFile(at url: URL, courseId: UUID) throws -> ImportResult {
        let ext = url.pathExtension.lowercased()
        guard Self.kind(forExtension: ext) == .pdf || Self.kind(forExtension: ext) == .text else { throw DocumentError.unsupportedType(ext) }
        return try importAnyFile(at: url, courseId: courseId, folderId: nil)
    }

    /// Library import: any file type. Text and PDFs are extracted; everything else is stored and previewable only.
    public func importAnyFile(at url: URL, courseId: UUID?, folderId: UUID?, name: String? = nil) throws -> ImportResult {
        let ext = url.pathExtension.lowercased()
        let kind = Self.kind(forExtension: ext)
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        let textual = kind == .pdf || kind == .text
        guard size <= (textual ? Self.maxFileBytes : Self.maxBinaryBytes) else { throw DocumentError.tooLarge((textual ? Self.maxFileBytes : Self.maxBinaryBytes) / 1_048_576) }
        let title = url.deletingPathExtension().lastPathComponent
        if !textual {
            guard FileManager.default.isReadableFile(atPath: url.path) else { throw DocumentError.unreadable }
            return try storeBinary(at: url, ext: ext, kind: kind, title: title, originalFilename: name ?? url.lastPathComponent, courseId: courseId, folderId: folderId)
        }
        guard let data = try? Data(contentsOf: url) else { throw DocumentError.unreadable }
        if kind == .pdf, !data.starts(with: Data("%PDF".utf8)) { throw DocumentError.notAPDF }
        return try store(data: data, ext: ext, kind: kind, title: title, originalFilename: name ?? url.lastPathComponent, courseId: courseId, folderId: folderId)
    }

    public func importPasted(text: String, title: String, courseId: UUID?, folderId: UUID? = nil) throws -> ImportResult {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { throw DocumentError.emptyText }
        guard t.count <= Self.maxTextChars else { throw DocumentError.tooLarge(Self.maxTextChars / 1_000_000) }
        let name = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let finalTitle = name.isEmpty ? "Pasted notes" : String(name.prefix(200))
        return try store(data: Data(t.utf8), ext: "txt", kind: .pasted, title: finalTitle,
                         originalFilename: finalTitle + ".txt", courseId: courseId, folderId: folderId)
    }

    public func chunks(documentId: UUID) throws -> [DocumentChunk] {
        try db.read { try DocumentChunk.filter(Column("documentId") == documentId).order(Column("ordinal")).fetchAll($0) }
    }

    public func documents(courseId: UUID) throws -> [Document] {
        // Deleted files (still recoverable) never feed study generation or the Materials list.
        try db.read { try Document.filter(Column("courseId") == courseId && Column("deletedAt") == nil).order(Column("importedAt").desc).fetchAll($0) }
    }

    public func setAssessmentCoverage(documentId: UUID, assessmentIds: Set<UUID>) throws {
        try db.write { d in
            try d.execute(sql: "DELETE FROM document_assessments WHERE documentId = ?", arguments: [documentId])
            for a in assessmentIds { try DocumentAssessment(documentId: documentId, assessmentId: a).insert(d) }
        }
    }

    public func assessmentIds(documentId: UUID) throws -> Set<UUID> {
        try db.read { Set(try UUID.fetchAll($0, sql: "SELECT assessmentId FROM document_assessments WHERE documentId = ?", arguments: [documentId])) }
    }

    // MARK: Internals

    /// A name that doesn't collide with a live sibling in the same course/folder: "a.pdf", "a 2.pdf", "a 3.pdf"…
    func uniqueName(_ d: Database, _ desired: String, courseId: UUID?, folderId: UUID?) throws -> String {
        let taken = Set(try String.fetchAll(d, sql: "SELECT name FROM documents WHERE courseId IS ? AND folderId IS ? AND deletedAt IS NULL", arguments: [courseId, folderId]).map { $0.lowercased() })
        return Self.deduped(desired, taken: taken)
    }
    static func deduped(_ desired: String, taken: Set<String>) -> String {
        guard taken.contains(desired.lowercased()) else { return desired }
        let ns = desired as NSString, ext = ns.pathExtension, base = ns.deletingPathExtension
        var n = 2
        while true { let c = ext.isEmpty ? "\(base) \(n)" : "\(base) \(n).\(ext)"; if !taken.contains(c.lowercased()) { return c }; n += 1 }
    }

    private func existingDuplicate(courseId: UUID?, folderId: UUID?, hash: String) throws -> Document? {
        try db.read { d in
            if let courseId, !(try Course.exists(d, key: courseId)) { throw DocumentError.notFound }
            return try Document.filter(sql: "courseId IS ? AND folderId IS ? AND sha256 = ? AND deletedAt IS NULL", arguments: [courseId, folderId, hash]).fetchOne(d)
        }
    }

    private func make(id: UUID, courseId: UUID?, folderId: UUID?, title: String, originalFilename: String, rel: String, hash: String, bytes: Int,
                      kind: DocumentKind, pages: Int?, status: ExtractionStatus, method: String, low: Int) throws -> Document {
        let now = Date()
        return try db.write { d in
            let name = try uniqueName(d, originalFilename, courseId: courseId, folderId: folderId)
            let doc = Document(id: id, courseId: courseId, folderId: folderId, title: (name as NSString).deletingPathExtension.isEmpty ? title : (name as NSString).deletingPathExtension,
                               originalFilename: originalFilename, name: name, storedPath: rel, sha256: hash, byteCount: bytes, kind: kind, pageCount: pages,
                               extractionStatus: status, extractionMethod: method, lowContentPageCount: low, importedAt: now, modifiedAt: now, favorite: false,
                               deletedAt: nil, purgeAfter: nil, deletedWith: nil)
            try doc.insert(d)
            return doc
        }
    }

    /// Images, video and other files: streamed copy + streamed hash, no extraction, never held in memory.
    private func storeBinary(at url: URL, ext: String, kind: DocumentKind, title: String, originalFilename: String, courseId: UUID?, folderId: UUID?) throws -> ImportResult {
        let hash = try Self.streamingSHA256(url)
        if let existing = try existingDuplicate(courseId: courseId, folderId: folderId, hash: hash) { return ImportResult(document: existing, wasDuplicate: true) }
        let id = UUID()
        let rel = "Documents/\(id.uuidString)/original" + (ext.isEmpty ? "" : ".\(ext)")
        let dest = storage.url(forStoredPath: rel)
        let fm = FileManager.default
        try fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
        do {
            try fm.copyItem(at: url, to: dest)
            let bytes = (try? dest.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            let doc = try make(id: id, courseId: courseId, folderId: folderId, title: title, originalFilename: originalFilename, rel: rel, hash: hash, bytes: bytes,
                               kind: kind, pages: nil, status: .notApplicable, method: "none", low: 0)
            return ImportResult(document: doc, wasDuplicate: false)
        } catch { try? fm.removeItem(at: dest.deletingLastPathComponent()); throw error }
    }

    static func streamingSHA256(_ url: URL) throws -> String {
        guard let h = try? FileHandle(forReadingFrom: url) else { throw DocumentError.unreadable }
        defer { try? h.close() }
        var hasher = SHA256()
        while let chunk = try h.read(upToCount: 1 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private func store(data: Data, ext: String, kind: DocumentKind, title: String,
                       originalFilename: String, courseId: UUID?, folderId: UUID?) throws -> ImportResult {
        let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        if let existing = try existingDuplicate(courseId: courseId, folderId: folderId, hash: hash) { return ImportResult(document: existing, wasDuplicate: true) }

        let id = UUID()
        let rel = "Documents/\(id.uuidString)/original.\(ext)"
        let dest = storage.url(forStoredPath: rel)
        let fm = FileManager.default
        try fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
        do {
            try data.write(to: dest, options: .atomic)
            let extraction = try Self.extract(from: dest, kind: kind)
            let chunks = Self.chunk(extraction.pages, documentId: id)
            let low = chunks.filter(\.isLowContent).count
            let status: ExtractionStatus = chunks.isEmpty || low == chunks.count ? .failed : (low > 0 ? .partial : .ok)
            let doc = try make(id: id, courseId: courseId, folderId: folderId, title: title, originalFilename: originalFilename, rel: rel, hash: hash, bytes: data.count,
                               kind: kind, pages: extraction.pageCount, status: status, method: extraction.method, low: low)
            try db.write { d in for c in chunks { try c.insert(d) } }
            return ImportResult(document: doc, wasDuplicate: false)
        } catch {
            try? db.write { _ = try Document.deleteOne($0, key: id) }
            try? fm.removeItem(at: dest.deletingLastPathComponent()) // no orphaned copy on failure
            throw error
        }
    }

    struct Extraction { var pages: [ExtractedPage]; var pageCount: Int?; var method: String }

    static func extract(from url: URL, kind: DocumentKind) throws -> Extraction {
        switch kind {
        case .pdf:
            guard let pdf = PDFDocument(url: url) else { throw DocumentError.notAPDF }
            if pdf.isLocked { throw DocumentError.lockedPDF }
            let pages = (0..<pdf.pageCount).map { i in
                ExtractedPage(pageNumber: i + 1, text: pdf.page(at: i)?.string ?? "")
            }
            return Extraction(pages: pages, pageCount: pdf.pageCount, method: "pdfkit-text")
        case .image, .video, .other: return Extraction(pages: [], pageCount: nil, method: "none")
        case .text, .pasted:
            guard let s = (try? String(contentsOf: url, encoding: .utf8)) ?? (try? String(contentsOf: url, encoding: .isoLatin1))
            else { throw DocumentError.unreadable }
            return Extraction(pages: splitText(String(s.prefix(maxTextChars))).map { ExtractedPage(pageNumber: nil, text: $0) },
                              pageCount: nil, method: "plain-text")
        }
    }

    /// Splits on paragraph boundaries into ~chunkTarget-character pieces.
    static func splitText(_ s: String) -> [String] {
        var out: [String] = [], cur = ""
        for para in s.components(separatedBy: "\n\n") {
            let p = para.trimmingCharacters(in: .whitespacesAndNewlines)
            if p.isEmpty { continue }
            if !cur.isEmpty, cur.count + p.count > chunkTarget { out.append(cur); cur = "" }
            cur += (cur.isEmpty ? "" : "\n\n") + p
            while cur.count > chunkTarget * 2 { // one giant paragraph
                out.append(String(cur.prefix(chunkTarget))); cur = String(cur.dropFirst(chunkTarget))
            }
        }
        if !cur.isEmpty { out.append(cur) }
        return out
    }

    static func chunk(_ pages: [ExtractedPage], documentId: UUID) -> [DocumentChunk] {
        pages.enumerated().map { i, p in
            let t = p.text.trimmingCharacters(in: .whitespacesAndNewlines)
            return DocumentChunk(id: UUID(), documentId: documentId, ordinal: i, pageNumber: p.pageNumber,
                                 text: t, isLowContent: t.count < lowContentThreshold)
        }
    }
}

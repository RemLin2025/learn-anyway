import Foundation
import GRDB
import CryptoKit

public struct BackupManifest: Codable, Sendable, Equatable {
    public struct FileEntry: Codable, Sendable, Equatable { public var path: String; public var sha256: String; public var bytes: Int }
    public var format: Int
    public var createdAt: Date
    public var app: String
    public var migrations: [String]
    public var database: FileEntry
    public var files: [FileEntry]
    /// Documents whose stored original was missing when the backup was made.
    public var missingFiles: [String]
    public var counts: [String: Int]
}

public enum BackupError: Error, LocalizedError, Equatable {
    case notABackup
    case unsupportedFormat(Int)
    case newerThanApp
    case unsafePath(String)
    case missingFile(String)
    case hashMismatch(String)
    case corruptDatabase(String)
    case tooLarge
    case safetyBackupFailed

    public var errorDescription: String? {
        switch self {
        case .notABackup: "That folder isn’t a Learn Anyway backup (no readable manifest)."
        case .unsupportedFormat(let f): "This backup uses format \(f), which this version can’t read."
        case .newerThanApp: "This backup was made by a newer version of Learn Anyway. Update the app to restore it."
        case .unsafePath(let p): "The backup lists an unsafe file path (“\(p)”) and was rejected."
        case .missingFile(let p): "The backup is incomplete: “\(p)” is missing."
        case .hashMismatch(let p): "“\(p)” doesn’t match its recorded checksum; the backup is damaged or was modified."
        case .corruptDatabase(let m): "The backup’s database is damaged (\(m))."
        case .tooLarge: "The backup manifest is unreasonably large."
        case .safetyBackupFailed: "Learn Anyway couldn’t save a safety copy of your current data, so nothing was changed."
        }
    }
}

public struct BackupResult: Sendable { public var url: URL; public var manifest: BackupManifest }

/// Portable backup/restore. A backup is a folder (`.braincellbackup`) holding a consistent SQLite copy, every imported
/// original, and a manifest with SHA-256 checksums. No secrets are stored in Learn Anyway, so none can be exported.
/// Restore validates everything first, saves a safety backup of the current data, stages files, then replaces the
/// database in a single SQLite backup operation.
public struct BackupService: Sendable {
    public static let format = 1
    static let dbName = "database.sqlite"
    static let manifestName = "manifest.json"
    static let maxManifestBytes = 20 * 1024 * 1024

    let db: AppDatabase
    let storage: ManagedStorage
    public init(db: AppDatabase, storage: ManagedStorage) { self.db = db; self.storage = storage }

    // MARK: Create

    @discardableResult
    public func create(in parent: URL, now: Date = Date()) throws -> BackupResult {
        let f = DateFormatter(); f.dateFormat = "yyyyMMdd-HHmmss"; f.locale = Locale(identifier: "en_US_POSIX")
        var dir = parent.appendingPathComponent("Braincell-Backup-\(f.string(from: now)).braincellbackup", isDirectory: true)
        var n = 1
        while FileManager.default.fileExists(atPath: dir.path) { n += 1; dir = parent.appendingPathComponent("Braincell-Backup-\(f.string(from: now))-\(n).braincellbackup", isDirectory: true) }
        let fm = FileManager.default
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        do {
            let dbURL = dir.appendingPathComponent(Self.dbName)
            let dest = try DatabaseQueue(path: dbURL.path)
            try db.writer.backup(to: dest)
            // A portable single-file copy: WAL mode needs side files and can't be opened read-only from a read-only folder.
            try dest.writeWithoutTransaction { try $0.execute(sql: "PRAGMA journal_mode = DELETE") }
            try dest.close()
            var files: [BackupManifest.FileEntry] = [], missing: [String] = []
            let docs = try db.read { try Document.fetchAll($0) }
            for doc in docs {
                guard Self.isSafe(doc.storedPath) else { throw BackupError.unsafePath(doc.storedPath) }
                let src = storage.url(forStoredPath: doc.storedPath)
                guard fm.fileExists(atPath: src.path) else { missing.append(doc.storedPath); continue }
                let out = dir.appendingPathComponent(doc.storedPath)
                try fm.createDirectory(at: out.deletingLastPathComponent(), withIntermediateDirectories: true)
                try fm.copyItem(at: src, to: out)
                files.append(try Self.entry(out, path: doc.storedPath))
            }
            let counts = try db.read { d -> [String: Int] in
                var c: [String: Int] = [:]
                for t in ["courses", "assessments", "skills", "documents", "questions", "attempts", "evaluations", "xp_events", "review_states", "study_sessions"] {
                    c[t] = try Int.fetchOne(d, sql: "SELECT COUNT(*) FROM \(t)") ?? 0
                }
                return c
            }
            let manifest = BackupManifest(format: Self.format, createdAt: now, app: "Braincell \(BraincellCoreInfo.version)", migrations: AppDatabase.migrator.migrations,
                                          database: try Self.entry(dbURL, path: Self.dbName), files: files, missingFiles: missing, counts: counts)
            let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]; enc.dateEncodingStrategy = .iso8601
            try enc.encode(manifest).write(to: dir.appendingPathComponent(Self.manifestName), options: .atomic)
            return BackupResult(url: dir, manifest: manifest)
        } catch {
            try? fm.removeItem(at: dir)   // never leave a half-written backup that looks real
            throw error
        }
    }

    // MARK: Validate

    /// Checks structure, paths, checksums and database health without touching current data.
    public static func validate(at dir: URL) throws -> BackupManifest {
        let fm = FileManager.default
        let mURL = dir.appendingPathComponent(manifestName)
        guard let size = (try? mURL.resourceValues(forKeys: [.fileSizeKey]))?.fileSize else { throw BackupError.notABackup }
        guard size <= maxManifestBytes else { throw BackupError.tooLarge }
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        guard let data = try? Data(contentsOf: mURL), let m = try? dec.decode(BackupManifest.self, from: data) else { throw BackupError.notABackup }
        guard m.format == Self.format else { throw BackupError.unsupportedFormat(m.format) }
        let known = Set(AppDatabase.migrator.migrations)
        guard Set(m.migrations).isSubset(of: known) else { throw BackupError.newerThanApp }
        guard m.database.path == dbName else { throw BackupError.unsafePath(m.database.path) }

        for e in [m.database] + m.files {
            guard e.path == dbName || isSafe(e.path) else { throw BackupError.unsafePath(e.path) }
            let u = dir.appendingPathComponent(e.path)
            let rv = try? u.resourceValues(forKeys: [.isSymbolicLinkKey, .isRegularFileKey])
            guard fm.fileExists(atPath: u.path) else { throw BackupError.missingFile(e.path) }
            guard rv?.isSymbolicLink != true, rv?.isRegularFile == true else { throw BackupError.unsafePath(e.path) }
            guard (try? sha256(u)) == e.sha256 else { throw BackupError.hashMismatch(e.path) }
        }
        var cfg = Configuration(); cfg.readonly = true
        do {
            let q = try DatabaseQueue(path: dir.appendingPathComponent(dbName).path, configuration: cfg)
            try q.read { d in
                let r = try String.fetchOne(d, sql: "PRAGMA integrity_check") ?? "?"
                if r != "ok" { throw BackupError.corruptDatabase(r) }
                if try Row.fetchOne(d, sql: "PRAGMA foreign_key_check") != nil { throw BackupError.corruptDatabase("foreign key violations") }
            }
        } catch let e as BackupError { throw e } catch { throw BackupError.corruptDatabase(error.localizedDescription) }
        return m
    }

    // MARK: Restore

    /// Replaces the current data with the backup's. `safetyBackupIn` receives a full copy of the current data first;
    /// if that can't be made, nothing is changed.
    @discardableResult
    public func restore(from dir: URL, safetyBackupIn: URL?) throws -> BackupManifest {
        let manifest = try Self.validate(at: dir)             // 1. nothing is touched until this passes
        if let safety = safetyBackupIn {
            do { try FileManager.default.createDirectory(at: safety, withIntermediateDirectories: true); _ = try create(in: safety) }
            catch { throw BackupError.safetyBackupFailed }
        }
        let fm = FileManager.default
        let staging = storage.root.appendingPathComponent(".restore-staging-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        do {                                                   // 2. stage and re-verify every file
            for e in manifest.files {
                let out = staging.appendingPathComponent(e.path)
                try fm.createDirectory(at: out.deletingLastPathComponent(), withIntermediateDirectories: true)
                try fm.copyItem(at: dir.appendingPathComponent(e.path), to: out)
                guard try Self.sha256(out) == e.sha256 else { throw BackupError.hashMismatch(e.path) }
            }
            var cfg = Configuration(); cfg.readonly = true
            let source = try DatabaseQueue(path: dir.appendingPathComponent(Self.dbName).path, configuration: cfg)
            try source.backup(to: db.writer)                   // 3. one atomic SQLite operation
            try AppDatabase.migrator.migrate(db.writer)        //    bring an older backup up to date
        } catch { try? fm.removeItem(at: staging); throw error }
        for e in manifest.files {                              // 4. move originals into place
            let dest = storage.url(forStoredPath: e.path)
            try fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
            if fm.fileExists(atPath: dest.path) { try fm.removeItem(at: dest) }
            try fm.moveItem(at: staging.appendingPathComponent(e.path), to: dest)
        }
        try? fm.removeItem(at: staging)
        return manifest
    }

    // MARK: Helpers

    /// Relative path under `Documents/` with plain components only: no absolute paths, `..`, hidden or empty parts.
    static func isSafe(_ p: String) -> Bool {
        guard p.hasPrefix("Documents/"), !p.hasPrefix("/"), !p.contains("\\"), !p.contains("\0") else { return false }
        let parts = p.split(separator: "/", omittingEmptySubsequences: false)
        return parts.count >= 3 && parts.allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." && !$0.hasPrefix(".") }
    }

    static func entry(_ url: URL, path: String) throws -> BackupManifest.FileEntry {
        BackupManifest.FileEntry(path: path, sha256: try sha256(url), bytes: (try url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
    }

    static func sha256(_ url: URL) throws -> String {
        let h = try FileHandle(forReadingFrom: url); defer { try? h.close() }
        var hasher = SHA256()
        while let chunk = try h.read(upToCount: 1 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

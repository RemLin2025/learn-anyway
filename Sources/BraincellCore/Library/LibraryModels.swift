import Foundation
import GRDB

/// Where the Library is being browsed. Courses are the roots of their own subtrees; global folders hang off `.root`.
public enum LibraryLocation: Hashable, Sendable { case root, course(UUID), folder(UUID) }

public enum LibraryKind: String, Sendable, CaseIterable {
    case courseFolder, folder, pdf, text, image, video, other
    public var label: String {
        switch self { case .courseFolder: "Course"; case .folder: "Folder"; case .pdf: "PDF"; case .text: "Text"; case .image: "Image"; case .video: "Video"; case .other: "File" }
    }
    public var isFolder: Bool { self == .courseFolder || self == .folder }
}

public enum LibraryFilter: String, Sendable, CaseIterable { case all = "All", documents = "Documents", images = "Images", videos = "Videos", folders = "Folders" }
public enum LibrarySort: String, Sendable, CaseIterable { case name = "Name", dateAdded = "Date Added", dateModified = "Date Modified", type = "Type" }

public struct LibraryQuery: Sendable, Equatable {
    public var text = ""
    public var filter: LibraryFilter = .all
    public var favoritesOnly = false
    public var sort: LibrarySort = .name
    public var ascending = true
    public init() {}
    /// Searches and type filters look across the whole subtree; plain browsing shows one level.
    var isFlat: Bool { !text.trimmingCharacters(in: .whitespaces).isEmpty || filter != .all || favoritesOnly }
}

public struct LibraryEntry: Identifiable, Hashable, Sendable {
    public let id: UUID
    public let kind: LibraryKind
    public var name: String
    public var courseId: UUID?
    public var parentId: UUID?
    public var byteCount: Int
    public var addedAt: Date
    public var modifiedAt: Date
    public var favorite: Bool
    public var storedPath: String?
    public var childCount: Int
    public var isFolder: Bool { kind.isFolder }
    public var ref: LibraryRef { LibraryRef(id: id, kind: kind) }
}

/// A stable handle for acting on an entry.
public struct LibraryRef: Hashable, Sendable {
    public let id: UUID; public let kind: LibraryKind
    public init(id: UUID, kind: LibraryKind) { self.id = id; self.kind = kind }
}

public struct LibraryCrumb: Hashable, Sendable { public let name: String; public let location: LibraryLocation }

public struct DeletedItem: Identifiable, Hashable, Sendable {
    public var id: UUID { ref.id }
    public let ref: LibraryRef
    public let name: String
    public let deletedAt: Date
    public let purgeAfter: Date
    public let detail: String
}

public struct LibraryImportReport: Sendable {
    public struct Failure: Sendable, Identifiable { public let id = UUID(); public let path: String; public let message: String }
    public var imported = 0, duplicates = 0, folders = 0, skipped = 0
    public var failures: [Failure] = []
    public var cancelled = false
    public var summary: String {
        var parts = ["\(imported) imported"]
        if folders > 0 { parts.append("\(folders) folder\(folders == 1 ? "" : "s")") }
        if duplicates > 0 { parts.append("\(duplicates) already there") }
        if skipped > 0 { parts.append("\(skipped) skipped") }
        if !failures.isEmpty { parts.append("\(failures.count) failed") }
        if cancelled { parts.append("cancelled") }
        return parts.joined(separator: " · ")
    }
}

public enum LibraryError: Error, Equatable, LocalizedError {
    case notFound, invalidMove(String), expired, emptyName, blocked(String)
    public var errorDescription: String? {
        switch self {
        case .notFound: "That item no longer exists."
        case .invalidMove(let m): m
        case .expired: "The seven-day recovery period for this item has ended."
        case .emptyName: "Enter a name."
        case .blocked(let m): m
        }
    }
}

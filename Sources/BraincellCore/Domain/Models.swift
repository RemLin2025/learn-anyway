import Foundation
import GRDB

// Domain records. They carry GRDB conformances (no SwiftUI/AppKit dependency),
// which keeps repositories trivial. See docs/ARCHITECTURE_DECISIONS.md (ADR-002).

public enum CourseKind: String, Codable, Sendable, DatabaseValueConvertible {
    case structured, quickCram
}

public enum AssessmentKind: String, Codable, Sendable, CaseIterable, DatabaseValueConvertible {
    case midterm, final, quiz, assignment, other
}

/// Where an importance value came from. AI guesses are never presented as confirmed.
public enum ImportanceSource: String, Codable, Sendable, DatabaseValueConvertible {
    case unset, instructorConfirmed, userAdjusted, aiEstimate
}

public enum SkillRelationKind: String, Codable, Sendable, DatabaseValueConvertible {
    /// from = parent, to = child
    case hierarchy
    /// from = prerequisite, to = dependent skill
    case prerequisite
    /// user-approved link between skills (possibly across courses)
    case related
}

public struct Course: Codable, Sendable, Identifiable, Hashable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "courses"
    public var id: UUID
    public var name: String
    public var kind: CourseKind
    public var createdAt: Date
    public var archivedAt: Date?
}

public struct Assessment: Codable, Sendable, Identifiable, Hashable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "assessments"
    public var id: UUID
    public var courseId: UUID
    public var name: String
    public var kind: AssessmentKind
    public var deadline: Date?
    /// A cumulative assessment covers every skill in its course (current and future).
    public var isCumulative: Bool
    /// 0...1 weight of the whole assessment, optional.
    public var importance: Double?
    public var importanceSource: ImportanceSource
    public var sortOrder: Int
    public var createdAt: Date
}

public struct Skill: Codable, Sendable, Identifiable, Hashable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "skills"
    public var id: UUID
    public var name: String
    public var normalizedName: String
    public var summary: String
    public var createdAt: Date
    public var archivedAt: Date?
}

public struct CourseSkill: Codable, Sendable, Hashable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "course_skills"
    public var courseId: UUID
    public var skillId: UUID
}

public struct AssessmentSkill: Codable, Sendable, Hashable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "assessment_skills"
    public var assessmentId: UUID
    public var skillId: UUID
    public var importance: Double?
    public var importanceSource: ImportanceSource
}

public struct SkillRelation: Codable, Sendable, Identifiable, Hashable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "skill_relations"
    public var id: UUID
    public var fromSkillId: UUID
    public var toSkillId: UUID
    public var kind: SkillRelationKind
}

public enum DocumentKind: String, Codable, Sendable, DatabaseValueConvertible {
    case pdf, text, pasted, image, video, other
}

public enum ExtractionStatus: String, Codable, Sendable, DatabaseValueConvertible {
    /// Text extracted from every page.
    case ok
    /// Some pages had little or no text (possible scans; OCR is not yet implemented).
    case partial
    /// Nothing usable could be extracted. The original file is still preserved.
    case failed
    /// Images, videos and other files that have no text to extract.
    case notApplicable
}

public struct Document: Codable, Sendable, Identifiable, Hashable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "documents"
    public var id: UUID
    /// The owning course, or nil for a file that lives directly in the global Library.
    public var courseId: UUID?
    public var folderId: UUID?
    public var title: String
    public var originalFilename: String
    /// Display name with extension; renaming changes this (and `title`), never the stored copy.
    public var name: String
    /// Path relative to the managed storage root.
    public var storedPath: String
    public var sha256: String
    public var byteCount: Int
    public var kind: DocumentKind
    public var pageCount: Int?
    public var extractionStatus: ExtractionStatus
    public var extractionMethod: String
    public var lowContentPageCount: Int
    public var importedAt: Date
    public var modifiedAt: Date
    public var favorite: Bool
    public var deletedAt: Date?
    public var purgeAfter: Date?
    public var deletedWith: UUID?
}

public struct DocumentChunk: Codable, Sendable, Identifiable, Hashable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "document_chunks"
    public var id: UUID
    public var documentId: UUID
    public var ordinal: Int
    /// 1-based page (PDF) when known; nil for plain text.
    public var pageNumber: Int?
    public var text: String
    public var isLowContent: Bool
}

public struct DocumentAssessment: Codable, Sendable, Hashable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "document_assessments"
    public var documentId: UUID
    public var assessmentId: UUID
}

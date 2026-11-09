import Foundation
import GRDB

public enum SessionStatus: String, Codable, Sendable, DatabaseValueConvertible {
    case active, paused, completed
}

/// How a session was planned. `timed` sessions (mock exams) suppress unsolicited coaching.
public enum SessionMode: String, Codable, Sendable, DatabaseValueConvertible {
    case free, cram, mastery, diagnostic, review
}

public enum ItemKind: String, Codable, Sendable, DatabaseValueConvertible {
    case practice, review, repair, advance, diagnostic
}

public enum ItemStatus: String, Codable, Sendable, DatabaseValueConvertible {
    case notStarted, inProgress, submitted, skipped
}

public struct StudySession: Codable, Sendable, Identifiable, Hashable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "study_sessions"
    public var id: UUID
    public var courseId: UUID?
    public var assessmentId: UUID?
    public var title: String
    public var status: SessionStatus
    public var currentOrdinal: Int
    public var startedAt: Date
    public var updatedAt: Date
    public var completedAt: Date?
    public var mode: SessionMode = .free
    public var timed: Bool = false
}

/// One planned question in a session. `revisionId` is pinned at creation so later edits never change what was answered.
public struct SessionItem: Codable, Sendable, Identifiable, Hashable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "session_items"
    public var id: UUID
    public var sessionId: UUID
    public var ordinal: Int
    public var questionId: UUID
    public var revisionId: UUID
    public var status: ItemStatus
    public var hintsUsed: Int
    public var activeSeconds: Int
    public var kind: ItemKind = .practice
    /// Why the planner chose this question (empty for free practice).
    public var reason: String = ""
}

public struct CodeFile: Codable, Hashable, Sendable {
    public var name: String
    public var language: String
    public var content: String
    public init(name: String, language: String, content: String) { self.name = name; self.language = language; self.content = content }
}

/// Everything a learner can enter. Which fields are used depends on the question type.
public struct PracticeResponse: Codable, Hashable, Sendable {
    public var selected: [String] = []
    public var text: String = ""
    public var files: [CodeFile] = []
    /// Flashcards: the back was revealed before continuing.
    public var revealed: Bool = false
    public init() {}

    public var isEmpty: Bool { selected.isEmpty && text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && files.allSatisfy { $0.content.isEmpty } && !revealed }
}

public struct AttemptDraft: Codable, Sendable, Hashable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "attempt_drafts"
    public var sessionItemId: UUID
    public var response: String
    public var updatedAt: Date
}

/// Immutable snapshot of a submission (a database trigger rejects updates).
public struct Attempt: Codable, Sendable, Identifiable, Hashable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "attempts"
    public var id: UUID
    public var sessionItemId: UUID
    public var questionId: UUID
    public var revisionId: UUID
    public var response: String
    public var hintsUsed: Int
    public var activeSeconds: Int
    public var submittedAt: Date

    public var decodedResponse: PracticeResponse { PracticeService.decode(response) }
}

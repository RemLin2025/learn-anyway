import Foundation
import GRDB

public enum VerificationSource: String, Codable, Sendable, DatabaseValueConvertible {
    case none, computed, user
}

public enum RevisionOrigin: String, Codable, Sendable, DatabaseValueConvertible {
    case manual, aiImport = "ai_import", edit, duplicate
}

public struct QuestionFamily: Codable, Sendable, Identifiable, Hashable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "question_families"
    public var id: UUID
    public var title: String
    public var createdAt: Date
}

/// The stable identity of a question. Its content lives in immutable `QuestionRevision`s.
public struct Question: Codable, Sendable, Identifiable, Hashable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "questions"
    public var id: UUID
    public var courseId: UUID
    public var familyId: UUID?
    public var currentRevisionId: UUID
    public var type: QuestionType
    public var readiness: Readiness
    public var verificationSource: VerificationSource
    /// JSON array of human-readable review reasons.
    public var reviewNotes: String
    public var archivedAt: Date?
    public var createdAt: Date

    public var notes: [String] {
        (try? JSONDecoder().decode([String].self, from: Data(reviewNotes.utf8))) ?? []
    }
}

public struct QuestionRevision: Codable, Sendable, Identifiable, Hashable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "question_revisions"
    public var id: UUID
    public var questionId: UUID
    public var number: Int
    public var title: String
    public var difficulty: Int
    public var learningObjective: String
    /// JSON-encoded `QuestionSpec`. Never updated (a DB trigger enforces this).
    public var payload: String
    public var contentHash: String
    public var origin: RevisionOrigin
    public var aiImportId: UUID?
    public var createdAt: Date

    public var spec: QuestionSpec? { try? JSONDecoder().decode(QuestionSpec.self, from: Data(payload.utf8)) }
}

public struct QuestionSkill: Codable, Sendable, Hashable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "question_skills"
    public var questionId: UUID
    public var skillId: UUID
}

public struct QuestionAssessment: Codable, Sendable, Hashable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "question_assessments"
    public var questionId: UUID
    public var assessmentId: UUID
}

public struct SavedView: Codable, Sendable, Identifiable, Hashable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "saved_views"
    public var id: UUID
    public var name: String
    public var filterJSON: String
    public var createdAt: Date
}

// MARK: AI bridge records

public enum AITaskKind: String, Codable, Sendable, DatabaseValueConvertible {
    case questionGeneration
    case subjectiveGrading
    /// Propose a skill hierarchy for a course; reviewed by the learner before anything changes.
    case topicAnalysis
}

public enum BatchKind: String, Codable, Sendable, DatabaseValueConvertible {
    case generate, repair, `continue`
    /// Ask ChatGPT to grade written/code answers (see `GradingPrompt`).
    case grade
    /// Topic analysis (see `TopicSchema`).
    case topics
}

public enum BatchStatus: String, Codable, Sendable, DatabaseValueConvertible {
    /// Request not yet prepared/exported.
    case draft
    /// Exported by the user; waiting for ChatGPT's JSON response to be imported.
    case awaitingImport
    /// Everything requested was accepted (or recognised as already present).
    case imported
    /// Some entries were rejected; a repair request can be generated.
    case needsRepair
    /// Fewer questions than requested came back; a continuation request can be generated.
    case incomplete
}

public enum TransferMethod: String, Codable, Sendable, CaseIterable, DatabaseValueConvertible {
    case clipboard, file
    /// Sent straight to the provider API by `DirectAIService` (opt-in; the prompt leaves the device).
    case api
}

public struct AITask: Codable, Sendable, Identifiable, Hashable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "ai_tasks"
    public var id: UUID
    public var kind: AITaskKind
    public var courseId: UUID
    public var assessmentId: UUID?
    public var title: String
    /// JSON-encoded `GenerationParams`.
    public var params: String
    public var createdAt: Date
}

public struct AITaskBatch: Codable, Sendable, Identifiable, Hashable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "ai_task_batches"
    public var id: UUID
    public var taskId: UUID
    public var parentBatchId: UUID?
    public var ordinal: Int
    public var kind: BatchKind
    /// Echoed back by the response; used to match responses to batches.
    public var requestId: String
    public var expectedCount: Int
    public var requestText: String
    /// JSON-encoded `RequestManifest` (what the user is about to share).
    public var manifest: String
    public var transferMethod: TransferMethod?
    public var status: BatchStatus
    public var exportedAt: Date?
    public var createdAt: Date
}

public enum ImportOutcomeKind: String, Codable, Sendable, DatabaseValueConvertible {
    case imported, rejected, malformed
}

public struct AIImport: Codable, Sendable, Identifiable, Hashable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "ai_imports"
    public var id: UUID
    public var batchId: UUID?
    public var responseHash: String
    /// The response exactly as pasted/imported; always preserved.
    public var rawResponse: String
    public var outcome: ImportOutcomeKind
    public var returnedCount: Int
    public var acceptedCount: Int
    public var duplicateCount: Int
    public var rejectedCount: Int
    /// JSON array of `ValidationIssue` (+ envelope problems).
    public var issues: String
    /// JSON array of the original rejected question objects (for repair requests).
    public var rejectedEntries: String
    public var createdAt: Date
}

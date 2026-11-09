import Foundation
import GRDB

public enum EvaluationState: String, Codable, Sendable, DatabaseValueConvertible {
    /// Waiting for a self-review or an imported AI grade. Never counted as incorrect.
    case pending
    case graded
    /// A grade under dispute or one the evaluator could not decide; carries no evidence or correctness XP.
    case needsReview
    case evaluatorUnavailable
}

public enum EvaluationSource: String, Codable, Sendable, DatabaseValueConvertible {
    case deterministic
    case selfReview = "self_review"
    case aiImport = "ai_import"
}

/// How much a grade can be trusted. Drives evidence weight and whether correctness XP is awarded.
public enum GradeTrust: String, Codable, Sendable, DatabaseValueConvertible {
    /// Machine-checked against a *verified* answer key.
    case trusted
    /// Machine-checked, but the answer key is not independently verified.
    case provisional
    /// The learner graded themselves (lower-confidence evidence).
    case selfReported
    /// Imported from a manual ChatGPT grading round.
    case aiGraded
}

public enum MasteryDimension: String, Codable, Sendable, CaseIterable, DatabaseValueConvertible {
    case recognition, recall, application, transfer

    public var label: String {
        switch self { case .recognition: "Recognition"; case .recall: "Recall & explanation"; case .application: "Independent application"; case .transfer: "Transfer & reasoning" }
    }

    /// Which dimension a question provides evidence for.
    public static func `for`(_ type: QuestionType, difficulty: Int) -> MasteryDimension {
        switch type {
        case .singleChoice, .multipleSelect: .recognition
        case .flashcard, .shortAnswer, .longForm: .recall
        case .numeric, .codeTracing: .application
        case .coding: difficulty >= 4 ? .transfer : .application
        case .derivationProof: .transfer
        }
    }
}

/// One grade for one attempt. Never edited: a new grade supersedes the old one and history is kept.
public struct Evaluation: Codable, Sendable, Identifiable, Hashable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "evaluations"
    public var id: UUID
    public var attemptId: UUID
    /// The question revision the response was graded against (may differ from the attempt's after a regrade).
    public var revisionId: UUID
    public var method: EvaluationMethod
    public var source: EvaluationSource
    public var state: EvaluationState
    /// 0…1; nil unless graded.
    public var score: Double?
    public var trust: GradeTrust
    public var feedback: String
    /// JSON, e.g. rubric points or the flashcard rating.
    public var detail: String
    public var reason: String
    public var supersedesId: UUID?
    public var supersededAt: Date?
    public var batchId: UUID?
    public var createdAt: Date

    public var isCorrect: Bool { state == .graded && (score ?? 0) >= 0.8 }
}

public struct LearningEvidence: Codable, Sendable, Identifiable, Hashable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "learning_evidence"
    public var id: UUID
    public var evaluationId: UUID
    public var attemptId: UUID
    public var questionId: UUID
    public var revisionId: UUID
    public var skillId: UUID
    public var courseId: UUID
    public var dimension: MasteryDimension
    public var score: Double
    public var difficulty: Int
    public var hintsUsed: Int
    public var attemptNumber: Int
    public var trust: GradeTrust
    public var occurredAt: Date
    public var supersededAt: Date?
}

public enum XPKind: String, Codable, Sendable, DatabaseValueConvertible { case award, correction }

/// Append-only XP ledger. `eventKey` is unique, so a reward can never be recorded twice.
public struct XPEvent: Codable, Sendable, Identifiable, Hashable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "xp_events"
    public var id: UUID
    public var eventKey: String
    /// Groups the events that adjust one reward (e.g. `correct:<questionId>`); net XP = SUM(amount).
    public var subject: String
    public var courseId: UUID
    public var attemptId: UUID?
    public var kind: XPKind
    public var reason: String
    public var amount: Int
    public var createdAt: Date
}

/// How an event's amount is attributed to skills. Sums to the event amount, so course totals never double count.
public struct XPEventSkill: Codable, Sendable, Hashable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "xp_event_skills"
    public var eventId: UUID
    public var skillId: UUID
    public var amount: Int
}

public struct SkillEstimateSnapshot: Codable, Sendable, Identifiable, Hashable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "skill_estimates"
    public var id: UUID
    public var skillId: UUID
    public var computedAt: Date
    public var dimensions: String   // JSON [DimensionEstimate]
    public var overall: Double?
    public var overallWeight: Double
    public var evidenceCount: Int
    public var estimatorVersion: String
    public var causeEvaluationId: UUID?
}

public struct Milestone: Codable, Sendable, Identifiable, Hashable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "milestones"
    public var id: UUID
    public var key: String
    public var title: String
    public var courseId: UUID?
    public var skillId: UUID?
    public var achievedAt: Date
}

public struct ReviewState: Codable, Sendable, Hashable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "review_states"
    public var questionId: UUID
    public var state: Int
    public var step: Int?
    public var stability: Double?
    public var difficulty: Double?
    public var due: Date
    public var lastReview: Date?
    public var reps: Int
    public var lapses: Int
    public var schedulerVersion: String
    /// JSON of the scheduler parameters in force (kept so history can be rescheduled faithfully).
    public var parameters: String
    public var updatedAt: Date

    public var card: FSRSCard {
        FSRSCard(state: FSRSState(rawValue: state) ?? .learning, step: step, stability: stability, difficulty: difficulty, due: due, lastReview: lastReview)
    }
}

public struct ReviewLog: Codable, Sendable, Identifiable, Hashable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "review_logs"
    public var id: UUID
    public var questionId: UUID
    public var attemptId: UUID
    public var rating: Int
    public var reviewedAt: Date
    public var stateBefore: Int?
    public var stateAfter: Int
    public var stabilityAfter: Double?
    public var difficultyAfter: Double?
    public var dueAfter: Date
    public var schedulerVersion: String
}

public enum ReflectionKind: String, Codable, Sendable, DatabaseValueConvertible { case confidence, reflection }

public struct LearningReflection: Codable, Sendable, Identifiable, Hashable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "learning_reflections"
    public var id: UUID
    public var courseId: UUID
    public var sessionId: UUID?
    public var attemptId: UUID?
    public var skillId: UUID?
    public var kind: ReflectionKind
    /// Confidence only: 1 guessing, 2 unsure, 3 sure.
    public var level: Int?
    public var text: String
    public var createdAt: Date
}

public struct CoachEvent: Codable, Sendable, Identifiable, Hashable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "coach_events"
    public var id: UUID
    public var sessionId: UUID
    public var trigger: String
    public var subject: String
    public var message: String
    public var shownAt: Date
    public var dismissedAt: Date?
    public var accepted: Bool?
}

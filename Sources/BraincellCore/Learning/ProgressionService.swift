import Foundation
import GRDB

public struct XPSummary: Sendable, Equatable {
    public var xp: Int
    public var level: Int
    public var xpIntoLevel: Int
    public var xpForNextLevel: Int
    public init(xp: Int) {
        self.xp = xp; level = XPRules.level(forXP: xp)
        xpIntoLevel = xp - XPRules.xpForLevel(level); xpForNextLevel = XPRules.xpForLevel(level + 1) - XPRules.xpForLevel(level)
    }
}

public struct AssessmentProgress: Sendable, Equatable {
    public var skillCount: Int
    /// Skills with at least some evidence (not "Unknown").
    public var assessedSkillCount: Int
    public var questionCount: Int
    public var attemptedQuestionCount: Int
    /// Evidence-weighted mean over assessed skills; nil when nothing is assessed. Always read with `confidence`.
    public var meanMastery: Double?
    public var confidence: ConfidenceLevel
}

public struct ItemResult: Sendable, Identifiable {
    public var item: SessionItem
    public var title: String
    public var type: QuestionType
    public var evaluation: Evaluation?
    public var xp: Int
    public var id: UUID { item.id }
}

public struct SessionResults: Sendable {
    public var items: [ItemResult]
    public var correct = 0, incorrect = 0, partial = 0, pending = 0, needsReview = 0, skipped = 0, unanswered = 0
    public var provisional = 0
    public var xp = 0
    public var hintsUsed = 0
    public var activeSeconds = 0
}

/// Read side of progression: XP, levels, mastery, progress and milestones.
public struct ProgressionService: Sendable {
    let db: AppDatabase
    let estimator: any MasteryEstimator
    public init(db: AppDatabase, estimator: any MasteryEstimator = HeuristicMasteryEstimator()) { self.db = db; self.estimator = estimator }

    // MARK: XP

    public func courseXP(_ courseId: UUID) throws -> XPSummary {
        XPSummary(xp: try db.read { try Int.fetchOne($0, sql: "SELECT COALESCE(SUM(amount),0) FROM xp_events WHERE courseId = ?", arguments: [courseId]) ?? 0 })
    }

    public func skillXP(_ skillId: UUID) throws -> XPSummary {
        XPSummary(xp: try db.read { try Int.fetchOne($0, sql: "SELECT COALESCE(SUM(amount),0) FROM xp_event_skills WHERE skillId = ?", arguments: [skillId]) ?? 0 })
    }

    /// Full audit trail, newest first.
    public func ledger(courseId: UUID) throws -> [XPEvent] {
        try db.read { try XPEvent.filter(Column("courseId") == courseId).order(Column("createdAt").desc, Column("rowid").desc).fetchAll($0) }
    }

    public func milestones(courseId: UUID? = nil) throws -> [Milestone] {
        try db.read { d in
            var q = Milestone.order(Column("achievedAt").desc, Column("rowid").desc)
            if let c = courseId { q = q.filter(Column("courseId") == c) }
            return try q.fetchAll(d)
        }
    }

    // MARK: Mastery

    /// Live estimate from current (non-superseded) evidence; recency is evaluated at `now`.
    public func mastery(skillId: UUID, now: Date = Date()) throws -> SkillMastery {
        estimator.estimate(skillId: skillId, evidence: try db.read { try ProgressionEngine.evidenceInputs($0, skillId: skillId) }, now: now)
    }

    public func masteries(courseId: UUID, now: Date = Date()) throws -> [UUID: SkillMastery] {
        let skills = try CourseService(db: db).skills(courseId: courseId)
        return Dictionary(uniqueKeysWithValues: try skills.map { ($0.id, try mastery(skillId: $0.id, now: now)) })
    }

    /// How a skill's estimate changed over time (one point per grading event).
    public func history(skillId: UUID) throws -> [SkillEstimateSnapshot] {
        try db.read { try SkillEstimateSnapshot.filter(Column("skillId") == skillId).order(Column("computedAt"), Column("rowid")).fetchAll($0) }
    }

    public func evidence(skillId: UUID) throws -> [LearningEvidence] {
        try db.read { try LearningEvidence.filter(Column("skillId") == skillId && Column("supersededAt") == nil).order(Column("occurredAt").desc).fetchAll($0) }
    }

    // MARK: Progress (course and assessment are deliberately separate views)

    public func assessmentProgress(assessmentId: UUID, now: Date = Date()) throws -> AssessmentProgress {
        let cs = CourseService(db: db)
        let skills = try cs.scopedSkills(assessmentId: assessmentId)
        let ms = try skills.map { try mastery(skillId: $0.id, now: now) }
        let assessed = ms.filter { !$0.isUnknown }
        let w = assessed.reduce(0) { $0 + $1.overallWeight }
        let mean = w > 0 ? assessed.reduce(0.0) { $0 + ($1.overall ?? 0) * $1.overallWeight } / w : nil
        let (qCount, attempted) = try db.read { d -> (Int, Int) in
            guard let a = try Assessment.fetchOne(d, key: assessmentId) else { return (0, 0) }
            let where_ = a.isCumulative ? "q.courseId = ?" : "q.id IN (SELECT questionId FROM question_assessments WHERE assessmentId = ?)"
            let arg: DatabaseValueConvertible = a.isCumulative ? a.courseId : a.id
            let total = try Int.fetchOne(d, sql: "SELECT COUNT(*) FROM questions q WHERE q.archivedAt IS NULL AND \(where_)", arguments: [arg]) ?? 0
            let att = try Int.fetchOne(d, sql: "SELECT COUNT(DISTINCT q.id) FROM questions q JOIN attempts t ON t.questionId = q.id WHERE q.archivedAt IS NULL AND \(where_)", arguments: [arg]) ?? 0
            return (total, att)
        }
        return AssessmentProgress(skillCount: skills.count, assessedSkillCount: assessed.count, questionCount: qCount, attemptedQuestionCount: attempted,
                                  meanMastery: mean, confidence: HeuristicMasteryEstimator.confidence(weight: w))
    }

    // MARK: Session summary

    public func sessionResults(sessionId: UUID) throws -> SessionResults {
        try db.read { d in
            let items = try SessionItem.filter(Column("sessionId") == sessionId).order(Column("ordinal")).fetchAll(d)
            var out = SessionResults(items: [])
            for it in items {
                let rev = try QuestionRevision.fetchOne(d, key: it.revisionId)
                let q = try Question.fetchOne(d, key: it.questionId)
                let a = try Attempt.fetchOne(d, key: ["sessionItemId": it.id])
                let e = try a.flatMap { try ProgressionEngine.active(d, attemptId: $0.id) }
                let xp = try a.map { try Int.fetchOne(d, sql: "SELECT COALESCE(SUM(amount),0) FROM xp_events WHERE attemptId = ?", arguments: [$0.id]) ?? 0 } ?? 0
                out.items.append(ItemResult(item: it, title: rev?.title ?? "Question", type: q?.type ?? .flashcard, evaluation: e, xp: xp))
                out.xp += xp; out.hintsUsed += it.hintsUsed; out.activeSeconds += it.activeSeconds
                switch it.status {
                case .skipped: out.skipped += 1
                case .notStarted, .inProgress: out.unanswered += 1
                case .submitted:
                    guard let e else { out.pending += 1; continue }
                    switch e.state {
                    case .pending, .evaluatorUnavailable: out.pending += 1
                    case .needsReview: out.needsReview += 1
                    case .graded:
                        let s = e.score ?? 0
                        if s >= 0.8 { out.correct += 1 } else if s > 0 { out.partial += 1 } else { out.incorrect += 1 }
                        if e.trust == .provisional { out.provisional += 1 }
                    }
                }
            }
            return out
        }
    }
}

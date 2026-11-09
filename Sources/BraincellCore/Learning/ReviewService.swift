import Foundation
import GRDB

public struct DueReview: Sendable, Identifiable {
    public var questionId: UUID
    public var title: String
    public var type: QuestionType
    public var courseId: UUID
    public var due: Date
    public var retrievability: Double
    public var lastReview: Date?
    public var id: UUID { questionId }
}

/// Spaced repetition for recall questions. Uses FSRS (see `FSRSScheduler`); long coding/proof tasks are left to the
/// skill-based planner instead.
enum ReviewEngine {
    static let scheduler = FSRSScheduler()!

    /// Question types whose answers are short, repeatable recall.
    static func isReviewable(_ t: QuestionType) -> Bool { t == .flashcard || t == .shortAnswer }

    /// Maps a grade to an FSRS rating. A flashcard's explicit self-rating wins; otherwise the score decides,
    /// and hinted answers never count as better than Hard-to-Good.
    static func rating(for e: Evaluation, hints: Int) -> FSRSRating {
        if let data = e.detail.data(using: .utf8), let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let label = obj["rating"] as? String, let r = FSRSRating(label: label) { return hints > 0 && r == .easy ? .good : r }
        let s = e.score ?? 0
        if s < 0.4 { return .again }
        if s < 0.8 { return .hard }
        return hints > 0 ? .hard : .good
    }

    /// Records exactly one review per graded attempt (idempotent via the unique attempt id on the log).
    static func record(_ d: Database, attempt a: Attempt, evaluation e: Evaluation, type: QuestionType) throws {
        guard isReviewable(type), e.state == .graded, e.score != nil else { return }
        guard try ReviewLog.filter(Column("attemptId") == a.id).fetchCount(d) == 0 else { return }
        let existing = try ReviewState.fetchOne(d, key: a.questionId)
        let now = max(a.submittedAt, existing?.lastReview ?? .distantPast)
        let before = existing?.card ?? FSRSCard.new(now: now)
        let r = rating(for: e, hints: a.hintsUsed)
        let after = scheduler.review(before, rating: r, at: now)
        let params = (try? JSONEncoder().encode(scheduler.parameters)).flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
        try ReviewState(questionId: a.questionId, state: after.state.rawValue, step: after.step, stability: after.stability, difficulty: after.difficulty,
                        due: after.due, lastReview: after.lastReview, reps: (existing?.reps ?? 0) + 1, lapses: (existing?.lapses ?? 0) + (r == .again ? 1 : 0),
                        schedulerVersion: FSRSScheduler.version, parameters: params, updatedAt: Date()).save(d)
        try ReviewLog(id: UUID(), questionId: a.questionId, attemptId: a.id, rating: r.rawValue, reviewedAt: now, stateBefore: existing?.state,
                      stateAfter: after.state.rawValue, stabilityAfter: after.stability, difficultyAfter: after.difficulty, dueAfter: after.due,
                      schedulerVersion: FSRSScheduler.version).insert(d)
    }
}

public struct ReviewService: Sendable {
    let db: AppDatabase
    public init(db: AppDatabase) { self.db = db }

    public func state(questionId: UUID) throws -> ReviewState? { try db.read { try ReviewState.fetchOne($0, key: questionId) } }

    public func logs(questionId: UUID) throws -> [ReviewLog] {
        try db.read { try ReviewLog.filter(Column("questionId") == questionId).order(Column("reviewedAt"), Column("rowid")).fetchAll($0) }
    }

    /// Cards due now (or earlier), least-remembered first. Archived questions never come due.
    public func due(courseId: UUID? = nil, now: Date = Date(), limit: Int = 200) throws -> [DueReview] {
        try db.read { try Self.dueRows($0, courseId: courseId, now: now, limit: limit) }
    }

    static func dueRows(_ d: Database, courseId: UUID?, now: Date, limit: Int = 200) throws -> [DueReview] {
        var sql = """
            SELECT s.*, q.courseId AS qCourse, q.type AS qType, r.title AS qTitle FROM review_states s
            JOIN questions q ON q.id = s.questionId JOIN question_revisions r ON r.id = q.currentRevisionId
            WHERE s.due <= ? AND q.archivedAt IS NULL
            """
        var args: [DatabaseValueConvertible] = [now]
        if let c = courseId { sql += " AND q.courseId = ?"; args.append(c) }
        return try Row.fetchAll(d, sql: sql, arguments: StatementArguments(args)).map { row -> DueReview in
            let st = try ReviewState(row: row)
            return DueReview(questionId: st.questionId, title: row["qTitle"], type: row["qType"], courseId: row["qCourse"], due: st.due,
                             retrievability: ReviewEngine.scheduler.retrievability(st.card, at: now), lastReview: st.lastReview)
        }.sorted { $0.retrievability < $1.retrievability }.prefix(limit).map { $0 }
    }

    public func dueCount(courseId: UUID? = nil, now: Date = Date()) throws -> Int { try due(courseId: courseId, now: now).count }
}

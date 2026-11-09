import Foundation
import GRDB

public struct Mistake: Sendable, Identifiable {
    public var attemptId: UUID
    public var questionId: UUID
    public var title: String
    public var type: QuestionType
    public var skillNames: [String]
    public var score: Double
    public var hintsUsed: Int
    public var submittedAt: Date
    /// How many graded attempts on this question scored below 0.5 (including this one).
    public var timesMissed: Int
    /// 1 guessing … 3 sure, when the learner recorded it.
    public var confidence: Int?
    public var responseSnippet: String
    public var id: UUID { attemptId }
    public var wasHighConfidence: Bool { confidence == 3 }
}

public struct WeakSpot: Sendable { public var skill: Skill; public var recentMisses: Int; public var lastMissAt: Date }
public struct Breakthrough: Sendable, Identifiable {
    public var attemptId: UUID; public var skillName: String; public var questionTitle: String; public var at: Date
    public var id: UUID { attemptId }
}

/// Observed behaviour only: mistakes, breakthroughs, confidence and reflections. Nothing here guesses at feelings.
public struct LearningHistoryService: Sendable {
    let db: AppDatabase
    public init(db: AppDatabase) { self.db = db }

    static let missThreshold = 0.5

    // MARK: Mistakes

    public func mistakes(courseId: UUID, limit: Int = 50) throws -> [Mistake] {
        try db.read { d in
            let rows = try Row.fetchAll(d, sql: """
                SELECT a.*, e.score AS eScore, q.type AS qType, r.title AS qTitle FROM attempts a
                JOIN evaluations e ON e.attemptId = a.id AND e.supersededAt IS NULL AND e.state = 'graded' AND e.score < ?
                JOIN questions q ON q.id = a.questionId JOIN question_revisions r ON r.id = a.revisionId
                WHERE q.courseId = ? ORDER BY a.submittedAt DESC LIMIT ?
                """, arguments: [Self.missThreshold, courseId, limit])
            return try rows.map { row in
                let a = try Attempt(row: row)
                let names = try String.fetchAll(d, sql: "SELECT s.name FROM skills s JOIN question_skills x ON x.skillId = s.id WHERE x.questionId = ? ORDER BY s.name", arguments: [a.questionId])
                let missed = try Int.fetchOne(d, sql: """
                    SELECT COUNT(*) FROM attempts t JOIN evaluations e ON e.attemptId = t.id AND e.supersededAt IS NULL AND e.state = 'graded' AND e.score < ?
                    WHERE t.questionId = ? AND t.submittedAt <= ?
                    """, arguments: [Self.missThreshold, a.questionId, a.submittedAt]) ?? 1
                let conf = try Int.fetchOne(d, sql: "SELECT level FROM learning_reflections WHERE attemptId = ? AND kind = 'confidence' ORDER BY createdAt DESC LIMIT 1", arguments: [a.id])
                let r = a.decodedResponse
                let snippet = String((r.files.first?.content ?? (r.selected.isEmpty ? r.text : r.selected.joined(separator: ", "))).prefix(160))
                return Mistake(attemptId: a.id, questionId: a.questionId, title: row["qTitle"], type: row["qType"], skillNames: names, score: row["eScore"],
                               hintsUsed: a.hintsUsed, submittedAt: a.submittedAt, timesMissed: missed, confidence: conf, responseSnippet: snippet)
            }
        }
    }

    /// Skills with at least two misses among their last five graded pieces of evidence.
    public func weakSpots(courseId: UUID) throws -> [WeakSpot] {
        try db.read { d in
            try CourseService.skills(d, courseId: courseId).compactMap { s in
                let last5 = try LearningEvidence.filter(Column("skillId") == s.id && Column("supersededAt") == nil).order(Column("occurredAt").desc).limit(5).fetchAll(d)
                let misses = last5.filter { $0.score < Self.missThreshold }
                guard misses.count >= 2, let at = misses.first?.occurredAt else { return nil }
                return WeakSpot(skill: s, recentMisses: misses.count, lastMissAt: at)
            }.sorted { $0.recentMisses > $1.recentMisses }
        }
    }

    // MARK: Breakthroughs

    /// A breakthrough is an unassisted, correct answer to a *different* question on a skill where the learner had
    /// recently missed or needed hints.
    public func breakthroughs(courseId: UUID, limit: Int = 20) throws -> [Breakthrough] {
        try db.read { d in
            let wins = try Row.fetchAll(d, sql: """
                SELECT a.* FROM attempts a JOIN evaluations e ON e.attemptId = a.id AND e.supersededAt IS NULL AND e.state = 'graded' AND e.score >= 0.8
                JOIN questions q ON q.id = a.questionId WHERE q.courseId = ? AND a.hintsUsed = 0 AND a.submittedAt >= ?
                ORDER BY a.submittedAt DESC LIMIT 150
                """, arguments: [courseId, Date().addingTimeInterval(-180 * 86_400)])
            var out: [Breakthrough] = []
            for row in wins {
                let a = try Attempt(row: row)
                if let b = try Self.breakthrough(d, for: a) { out.append(b); if out.count >= limit { break } }
            }
            return out
        }
    }

    static func breakthrough(_ d: Database, for a: Attempt, window: TimeInterval = 14 * 86_400) throws -> Breakthrough? {
        let skills = try UUID.fetchAll(d, sql: "SELECT skillId FROM question_skills WHERE questionId = ?", arguments: [a.questionId])
        for s in skills {
            let earlier = try Row.fetchOne(d, sql: """
                SELECT t.id FROM attempts t JOIN question_skills x ON x.questionId = t.questionId AND x.skillId = ?
                LEFT JOIN evaluations e ON e.attemptId = t.id AND e.supersededAt IS NULL
                WHERE t.questionId != ? AND t.submittedAt < ? AND t.submittedAt >= ?
                  AND (t.hintsUsed >= 2 OR (e.state = 'graded' AND e.score < 0.5)) LIMIT 1
                """, arguments: [s, a.questionId, a.submittedAt, a.submittedAt.addingTimeInterval(-window)])
            if earlier != nil {
                let name = try String.fetchOne(d, sql: "SELECT name FROM skills WHERE id = ?", arguments: [s]) ?? "this skill"
                let title = try String.fetchOne(d, sql: "SELECT title FROM question_revisions WHERE id = ?", arguments: [a.revisionId]) ?? "a question"
                return Breakthrough(attemptId: a.id, skillName: name, questionTitle: title, at: a.submittedAt)
            }
        }
        return nil
    }

    // MARK: Confidence and reflections (all optional, asked rarely)

    public static func confidenceLabel(_ level: Int) -> String { ["Guessing", "Unsure", "Sure"][min(2, max(0, level - 1))] }

    /// Minimal-interruption policy: only for difficult questions, questions missed before, or skills with two recent misses.
    public func shouldAskConfidence(itemId: UUID, setting: String = "minimal") throws -> Bool {
        guard setting != "off" else { return false }
        return try db.read { d in
            guard let item = try SessionItem.fetchOne(d, key: itemId), let rev = try QuestionRevision.fetchOne(d, key: item.revisionId) else { return false }
            if rev.difficulty >= 4 { return true }
            let missedBefore = try Int.fetchOne(d, sql: """
                SELECT COUNT(*) FROM attempts t JOIN evaluations e ON e.attemptId = t.id AND e.supersededAt IS NULL AND e.state = 'graded' AND e.score < 0.5
                WHERE t.questionId = ?
                """, arguments: [item.questionId]) ?? 0
            if missedBefore > 0 { return true }
            for s in try UUID.fetchAll(d, sql: "SELECT skillId FROM question_skills WHERE questionId = ?", arguments: [item.questionId]) {
                let last2 = try LearningEvidence.filter(Column("skillId") == s && Column("supersededAt") == nil).order(Column("occurredAt").desc).limit(2).fetchAll(d)
                if last2.count == 2, last2.allSatisfy({ $0.score < Self.missThreshold }) { return true }
            }
            return false
        }
    }

    public func recordConfidence(attemptId: UUID, level: Int) throws {
        guard (1...3).contains(level) else { return }
        try db.write { d in
            guard let a = try Attempt.fetchOne(d, key: attemptId), let q = try Question.fetchOne(d, key: a.questionId) else { return }
            let sid = try SessionItem.fetchOne(d, key: a.sessionItemId)?.sessionId
            try LearningReflection(id: UUID(), courseId: q.courseId, sessionId: sid, attemptId: attemptId, skillId: nil, kind: .confidence, level: level, text: "", createdAt: Date()).insert(d)
        }
    }

    public func addReflection(courseId: UUID, text: String, sessionId: UUID? = nil, attemptId: UUID? = nil, skillId: UUID? = nil) throws {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        try db.write { try LearningReflection(id: UUID(), courseId: courseId, sessionId: sessionId, attemptId: attemptId, skillId: skillId, kind: .reflection, level: nil, text: String(t.prefix(2_000)), createdAt: Date()).insert($0) }
    }

    public func reflections(courseId: UUID) throws -> [LearningReflection] {
        try db.read { try LearningReflection.filter(Column("courseId") == courseId && Column("kind") == ReflectionKind.reflection).order(Column("createdAt").desc).fetchAll($0) }
    }

    public func confidence(attemptId: UUID) throws -> Int? {
        try db.read { try Int.fetchOne($0, sql: "SELECT level FROM learning_reflections WHERE attemptId = ? AND kind = 'confidence' ORDER BY createdAt DESC LIMIT 1", arguments: [attemptId]) }
    }
}

extension CourseService {
    static func skills(_ d: Database, courseId: UUID) throws -> [Skill] {
        try Skill.fetchAll(d, sql: "SELECT s.* FROM skills s JOIN course_skills c ON c.skillId = s.id WHERE c.courseId = ? AND s.archivedAt IS NULL ORDER BY s.name COLLATE NOCASE", arguments: [courseId])
    }
}

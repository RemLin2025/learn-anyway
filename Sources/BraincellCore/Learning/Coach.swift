import Foundation
import GRDB

public enum CoachTrigger: String, Codable, Sendable {
    case repeatedMistakes, manyHints, breakthrough, highConfidenceMiss
}

public struct CoachSuggestion: Sendable, Identifiable {
    public var id: UUID
    public var trigger: CoachTrigger
    public var title: String
    public var message: String
    public var skillName: String?
    /// Prerequisite skills that look weak (or have no evidence), for the "review first" option.
    public var prerequisiteNames: [String]
    public var offersReflection: Bool
}

/// Deterministic, local, dismissible coaching. It never changes the question, never auto-asks the AI, never
/// interrupts a timed (mock exam) session, and respects a cooldown between unsolicited suggestions.
public struct CoachService: Sendable {
    public static let cooldown: TimeInterval = 600
    let db: AppDatabase
    public init(db: AppDatabase) { self.db = db }

    /// Call after an attempt has been graded. Returns at most one suggestion and records it as shown.
    public func suggestion(sessionId: UUID, attemptId: UUID, enabled: Bool = true, now: Date = Date()) throws -> CoachSuggestion? {
        guard enabled else { return nil }
        return try db.write { d in
            guard let session = try StudySession.fetchOne(d, key: sessionId), !session.timed, session.status != .completed,
                  let attempt = try Attempt.fetchOne(d, key: attemptId), let eval = try ProgressionEngine.active(d, attemptId: attemptId) else { return nil }
            // Cooldown between unsolicited interventions.
            if let last = try CoachEvent.filter(Column("sessionId") == sessionId).order(Column("shownAt").desc).fetchOne(d), now.timeIntervalSince(last.shownAt) < Self.cooldown { return nil }

            func show(_ t: CoachTrigger, subject: String, title: String, message: String, skill: String?, prereqs: [String] = [], reflect: Bool = false) throws -> CoachSuggestion? {
                guard try CoachEvent.filter(Column("sessionId") == sessionId && Column("trigger") == t.rawValue && Column("subject") == subject).fetchCount(d) == 0 else { return nil }
                let e = CoachEvent(id: UUID(), sessionId: sessionId, trigger: t.rawValue, subject: subject, message: message, shownAt: now, dismissedAt: nil, accepted: nil)
                try e.insert(d)
                return CoachSuggestion(id: e.id, trigger: t, title: title, message: message, skillName: skill, prerequisiteNames: prereqs, offersReflection: reflect)
            }
            let skillIds = try UUID.fetchAll(d, sql: "SELECT skillId FROM question_skills WHERE questionId = ? ORDER BY skillId", arguments: [attempt.questionId])
            func name(_ id: UUID) throws -> String { try String.fetchOne(d, sql: "SELECT name FROM skills WHERE id = ?", arguments: [id]) ?? "this skill" }
            let graded = eval.state == .graded
            let score = eval.score ?? 0

            // 1. A confident miss is the most informative kind of mistake.
            if graded, score < LearningHistoryService.missThreshold,
               try Int.fetchOne(d, sql: "SELECT level FROM learning_reflections WHERE attemptId = ? AND kind = 'confidence' ORDER BY createdAt DESC LIMIT 1", arguments: [attemptId]) == 3 {
                return try show(.highConfidenceMiss, subject: attemptId.uuidString, title: "You felt sure about that one",
                                message: "Confident misses are often the most useful ones to learn from. If you like, note what you expected and what surprised you.",
                                skill: try skillIds.first.map(name), reflect: true)
            }
            // 2. Independent success on a new variation after earlier trouble.
            if graded, score >= 0.8, attempt.hintsUsed == 0, let b = try LearningHistoryService.breakthrough(d, for: attempt) {
                return try show(.breakthrough, subject: b.skillName, title: "That looks like a breakthrough",
                                message: "You solved “\(b.questionTitle)” on your own. Earlier you needed help on “\(b.skillName)”. Want to note what changed?",
                                skill: b.skillName, reflect: true)
            }
            // 3. Two misses in a row on the same skill within this session.
            let recent = try Row.fetchAll(d, sql: """
                SELECT a.id AS aid, a.questionId AS qid, e.score AS score FROM attempts a JOIN session_items i ON i.id = a.sessionItemId
                JOIN evaluations e ON e.attemptId = a.id AND e.supersededAt IS NULL AND e.state = 'graded'
                WHERE i.sessionId = ? ORDER BY a.submittedAt DESC, a.rowid DESC LIMIT 3
                """, arguments: [sessionId])
            var misses: [UUID: Int] = [:]
            for row in recent where (row["score"] as Double) < LearningHistoryService.missThreshold {
                for s in try UUID.fetchAll(d, sql: "SELECT skillId FROM question_skills WHERE questionId = ?", arguments: [row["qid"] as UUID]) { misses[s, default: 0] += 1 }
            }
            if let (sid, _) = misses.filter({ $0.value >= 2 && skillIds.contains($0.key) }).first {
                let sname = try name(sid)
                var prereqs: [String] = []
                for pid in try UUID.fetchAll(d, sql: "SELECT fromSkillId FROM skill_relations WHERE toSkillId = ? AND kind = 'prerequisite'", arguments: [sid]) {
                    let m = HeuristicMasteryEstimator().estimate(skillId: pid, evidence: try ProgressionEngine.evidenceInputs(d, skillId: pid), now: now)
                    if m.isUnknown || (m.overall ?? 1) < 0.6 { prereqs.append(try name(pid)) }
                }
                return try show(.repeatedMistakes, subject: sid.uuidString, title: "A couple of misses on “\(sname)”",
                                message: "That’s useful information, not a verdict. You could use a hint, look at the explanation after submitting, or\(prereqs.isEmpty ? " try an easier question on this skill." : " refresh a prerequisite first.")",
                                skill: sname, prereqs: prereqs)
            }
            // 4. Leaning on hints repeatedly.
            let hints = try Int.fetchOne(d, sql: """
                SELECT COALESCE(SUM(h), 0) FROM (SELECT a.hintsUsed AS h FROM attempts a JOIN session_items i ON i.id = a.sessionItemId
                WHERE i.sessionId = ? ORDER BY a.submittedAt DESC, a.rowid DESC LIMIT 4)
                """, arguments: [sessionId]) ?? 0
            if hints >= 3 {
                return try show(.manyHints, subject: "hints", title: "Hints are doing a lot of work",
                                message: "Needing several hints suggests the underlying idea may need another pass. A break or an easier warm-up question can help; it’s your call.",
                                skill: nil)
            }
            return nil
        }
    }

    public func dismiss(eventId: UUID, accepted: Bool, now: Date = Date()) throws {
        try db.write { d in
            guard var e = try CoachEvent.fetchOne(d, key: eventId) else { return }
            e.dismissedAt = now; e.accepted = accepted; try e.update(d)
        }
    }

    public func events(sessionId: UUID) throws -> [CoachEvent] {
        try db.read { try CoachEvent.filter(Column("sessionId") == sessionId).order(Column("shownAt")).fetchAll($0) }
    }
}

import Foundation
import GRDB

/// Everything that must change together when a grade is recorded. Always runs inside the caller's transaction.
enum ProgressionEngine {
    static let estimator: any MasteryEstimator = HeuristicMasteryEstimator()

    static func active(_ d: Database, attemptId: UUID) throws -> Evaluation? {
        try Evaluation.filter(Column("attemptId") == attemptId && Column("supersededAt") == nil).fetchOne(d)
    }

    @discardableResult
    static func commit(_ d: Database, attempt a: Attempt, outcome o: EvaluationOutcome, source: EvaluationSource, revisionId: UUID,
                       reason: String, detail: String, batchId: UUID?) throws -> Evaluation {
        let now = Date()
        guard let q = try Question.fetchOne(d, key: a.questionId), let spec = try QuestionRevision.fetchOne(d, key: revisionId)?.spec else { throw EvaluationError.notFound }
        var touched = Set<UUID>()

        // 1. Supersede the current grade and its evidence (history is kept, nothing is deleted).
        let prev = try active(d, attemptId: a.id)
        if var p = prev {
            p.supersededAt = now; try p.update(d)
            touched.formUnion(try UUID.fetchAll(d, sql: "SELECT skillId FROM learning_evidence WHERE evaluationId = ? AND supersededAt IS NULL", arguments: [p.id]))
            try d.execute(sql: "UPDATE learning_evidence SET supersededAt = ? WHERE evaluationId = ? AND supersededAt IS NULL", arguments: [now, p.id])
        }

        // 2. The new grade.
        let e = Evaluation(id: UUID(), attemptId: a.id, revisionId: revisionId, method: o.method, source: source, state: o.state, score: o.score,
                           trust: o.trust, feedback: o.feedback, detail: detail, reason: reason, supersedesId: prev?.id, supersededAt: nil,
                           batchId: batchId, createdAt: now)
        try e.insert(d)

        // 3. Evidence: only real grades. Pending / disputed / unavailable answers prove nothing either way.
        let skillIds = try UUID.fetchAll(d, sql: "SELECT skillId FROM question_skills WHERE questionId = ? ORDER BY skillId", arguments: [q.id])
        if o.state == .graded, let score = o.score {
            let n = try attemptNumber(d, a)
            for s in skillIds {
                try LearningEvidence(id: UUID(), evaluationId: e.id, attemptId: a.id, questionId: q.id, revisionId: revisionId, skillId: s, courseId: q.courseId,
                                     dimension: MasteryDimension.for(spec.type, difficulty: spec.difficulty), score: score, difficulty: spec.difficulty,
                                     hintsUsed: a.hintsUsed, attemptNumber: n, trust: o.trust, occurredAt: a.submittedAt, supersededAt: nil).insert(d)
            }
            touched.formUnion(skillIds)
        }

        // 4. XP.
        let n = try attemptNumber(d, a)
        let attemptSpec = try QuestionRevision.fetchOne(d, key: a.revisionId)?.spec ?? spec
        try reconcile(d, subject: "participation:\(a.id)", desired: XPRules.participation(difficulty: attemptSpec.difficulty, attemptNumber: n),
                      courseId: q.courseId, attemptId: a.id, skillIds: skillIds, reason: "Completed a question")
        try reconcileCorrectness(d, question: q)

        // 4b. Spaced repetition: a graded recall attempt is one review.
        if o.state == .graded { try ReviewEngine.record(d, attempt: a, evaluation: e, type: spec.type) }

        // 5. Mastery snapshots for every skill whose evidence changed.
        for s in touched { try snapshot(d, skillId: s, cause: e.id, now: now) }

        // 6. Milestones.
        try milestones(d, courseId: q.courseId, skillIds: Array(touched.union(skillIds)))
        return e
    }

    /// 1-based position of this attempt among all attempts on the question (novelty: repeats count for less).
    static func attemptNumber(_ d: Database, _ a: Attempt) throws -> Int {
        let ids = try UUID.fetchAll(d, sql: "SELECT id FROM attempts WHERE questionId = ? ORDER BY submittedAt, rowid", arguments: [a.questionId])
        return (ids.firstIndex(of: a.id) ?? 0) + 1
    }

    // MARK: XP ledger

    /// Brings the net XP of `subject` to `desired` by appending an award or a correction. No-op when already equal,
    /// so calling it repeatedly (retries, regrades) can never double-award.
    static func reconcile(_ d: Database, subject: String, desired: Int, courseId: UUID, attemptId: UUID?, skillIds: [UUID], reason: String) throws {
        let net = try Int.fetchOne(d, sql: "SELECT COALESCE(SUM(amount), 0) FROM xp_events WHERE subject = ?", arguments: [subject]) ?? 0
        let delta = desired - net
        guard delta != 0 else { return }
        // A correction belongs to the attempt that earned the original award, so per-attempt totals stay right.
        let attemptId = try attemptId ?? UUID.fetchOne(d, sql: "SELECT attemptId FROM xp_events WHERE subject = ? AND attemptId IS NOT NULL ORDER BY rowid DESC LIMIT 1", arguments: [subject])
        let seq = (try Int.fetchOne(d, sql: "SELECT COUNT(*) FROM xp_events WHERE subject = ?", arguments: [subject]) ?? 0) + 1
        let ev = XPEvent(id: UUID(), eventKey: "\(subject)#\(seq)", subject: subject, courseId: courseId, attemptId: attemptId,
                         kind: delta > 0 ? .award : .correction, reason: delta > 0 ? reason : "Correction: \(reason)", amount: delta, createdAt: Date())
        try ev.insert(d)
        if delta > 0 {
            for (s, amt) in zip(skillIds, XPRules.split(delta, among: skillIds.count)) where amt != 0 { try XPEventSkill(eventId: ev.id, skillId: s, amount: amt).insert(d) }
        } else {
            let rows = try Row.fetchAll(d, sql: """
                SELECT s.skillId, SUM(s.amount) AS total FROM xp_event_skills s JOIN xp_events e ON e.id = s.eventId
                WHERE e.subject = ? GROUP BY s.skillId HAVING total > 0 ORDER BY s.skillId
                """, arguments: [subject])
            let ids: [UUID] = rows.map { $0["skillId"] }, weights: [Int] = rows.map { $0["total"] }
            for (s, amt) in zip(ids, XPRules.proportional(delta, weights: weights)) where amt != 0 { try XPEventSkill(eventId: ev.id, skillId: s, amount: amt).insert(d) }
        }
    }

    /// One correctness bonus per question, for the earliest attempt that qualifies *now*:
    /// graded ≥ 0.8, trusted machine grade or AI grade (not self-report / provisional), and no hints.
    static func reconcileCorrectness(_ d: Database, question q: Question) throws {
        var desired = 0
        var winner: Attempt?
        for a in try Attempt.filter(Column("questionId") == q.id).order(Column("submittedAt"), Column("rowid")).fetchAll(d) {
            guard let e = try active(d, attemptId: a.id), e.state == .graded, (e.score ?? 0) >= 0.8,
                  e.trust == .trusted || e.trust == .aiGraded, a.hintsUsed == 0 else { continue }
            winner = a
            desired = XPRules.correctness(difficulty: try QuestionRevision.fetchOne(d, key: e.revisionId)?.difficulty ?? 1)
            break
        }
        let skillIds = try UUID.fetchAll(d, sql: "SELECT skillId FROM question_skills WHERE questionId = ? ORDER BY skillId", arguments: [q.id])
        try reconcile(d, subject: "correct:\(q.id)", desired: desired, courseId: q.courseId, attemptId: winner?.id, skillIds: skillIds, reason: "First independent correct answer")
    }

    // MARK: Mastery snapshots

    static func evidenceInputs(_ d: Database, skillId: UUID) throws -> [EvidenceInput] {
        try LearningEvidence.filter(Column("skillId") == skillId && Column("supersededAt") == nil).fetchAll(d).map {
            EvidenceInput(dimension: $0.dimension, score: $0.score, difficulty: $0.difficulty, hintsUsed: $0.hintsUsed,
                          attemptNumber: $0.attemptNumber, trust: $0.trust, occurredAt: $0.occurredAt)
        }
    }

    static func snapshot(_ d: Database, skillId: UUID, cause: UUID?, now: Date) throws {
        let m = estimator.estimate(skillId: skillId, evidence: try evidenceInputs(d, skillId: skillId), now: now)
        let dims = (try? JSONEncoder().encode(m.dimensions)).flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
        try SkillEstimateSnapshot(id: UUID(), skillId: skillId, computedAt: now, dimensions: dims, overall: m.overall, overallWeight: m.overallWeight,
                                  evidenceCount: m.evidenceCount, estimatorVersion: m.estimatorVersion, causeEvaluationId: cause).insert(d)
    }

    // MARK: Milestones

    static func milestones(_ d: Database, courseId: UUID, skillIds: [UUID]) throws {
        func award(_ key: String, _ title: String, course: UUID?, skill: UUID?) throws {
            guard try Milestone.filter(Column("key") == key).fetchCount(d) == 0 else { return }
            try Milestone(id: UUID(), key: key, title: title, courseId: course, skillId: skill, achievedAt: Date()).insert(d)
        }
        try award("first_attempt", "First answer submitted", course: courseId, skill: nil)
        let courseXP = try Int.fetchOne(d, sql: "SELECT COALESCE(SUM(amount),0) FROM xp_events WHERE courseId = ?", arguments: [courseId]) ?? 0
        let name = try String.fetchOne(d, sql: "SELECT name FROM courses WHERE id = ?", arguments: [courseId]) ?? "Course"
        for l in stride(from: 2, through: XPRules.level(forXP: courseXP), by: 1) { try award("course_level:\(courseId):\(l)", "\(name) reached level \(l)", course: courseId, skill: nil) }
        for s in Set(skillIds) {
            let xp = try Int.fetchOne(d, sql: "SELECT COALESCE(SUM(amount),0) FROM xp_event_skills WHERE skillId = ?", arguments: [s]) ?? 0
            let sname = try String.fetchOne(d, sql: "SELECT name FROM skills WHERE id = ?", arguments: [s]) ?? "Skill"
            for l in stride(from: 2, through: XPRules.level(forXP: xp), by: 1) { try award("skill_level:\(s):\(l)", "\(sname) reached level \(l)", course: courseId, skill: s) }
        }
    }
}

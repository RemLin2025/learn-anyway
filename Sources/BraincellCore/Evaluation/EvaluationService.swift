import Foundation
import GRDB

public enum EvaluationError: Error, LocalizedError, Equatable {
    case notFound
    case invalidScore
    case notPending
    case notCodeTests
    case runnerUnavailable(String)

    public var errorDescription: String? {
        switch self {
        case .notFound: "That attempt no longer exists."
        case .invalidScore: "A score must be between 0 and 1."
        case .notPending: "This answer has already been graded."
        case .notCodeTests: "This question isn’t graded by running tests."
        case .runnerUnavailable(let r): r
        }
    }
}

public struct AttemptResult: Sendable {
    public var attempt: Attempt
    public var evaluation: Evaluation
    /// Net XP recorded for this attempt (participation + correctness, after any corrections).
    public var xp: Int
}

public struct PendingAttempt: Sendable, Identifiable {
    public var attempt: Attempt
    public var title: String
    public var type: QuestionType
    public var courseId: UUID
    public var id: UUID { attempt.id }
}

/// Grades attempts and records everything that follows from a grade (evidence, XP, mastery snapshots, milestones)
/// in one transaction. Grades are never edited: a new grade supersedes the old and both stay in the history.
public struct EvaluationService: Sendable {
    let db: AppDatabase
    public init(db: AppDatabase) { self.db = db }

    // MARK: Grading

    /// Grades a submitted attempt. Idempotent: an attempt that already has a current evaluation just returns it.
    @discardableResult
    public func evaluate(attemptId: UUID) throws -> AttemptResult {
        try db.write { d in
            guard let a = try Attempt.fetchOne(d, key: attemptId) else { throw EvaluationError.notFound }
            if let e = try ProgressionEngine.active(d, attemptId: attemptId) { return try Self.result(d, a, e) }
            let (spec, verified) = try Self.specAndTrust(d, a, revisionId: a.revisionId)
            let o = Evaluator.evaluate(spec: spec, response: a.decodedResponse, answerKeyVerified: verified)
            let e = try ProgressionEngine.commit(d, attempt: a, outcome: o, source: .deterministic, revisionId: a.revisionId, reason: "Automatic", detail: "{}", batchId: nil)
            return try Self.result(d, a, e)
        }
    }

    /// The learner grades themselves. `rubricPoints` (criterion → points) or a plain `score` 0…1.
    /// Stored as lower-confidence evidence (`selfReported`).
    @discardableResult
    public func selfReview(attemptId: UUID, score: Double, rubricPoints: [String: Double]? = nil, rating: String? = nil, note: String = "") throws -> AttemptResult {
        guard (0...1).contains(score) else { throw EvaluationError.invalidScore }
        return try db.write { d in
            guard let a = try Attempt.fetchOne(d, key: attemptId) else { throw EvaluationError.notFound }
            var detail: [String: Any] = [:]
            if let rubricPoints { detail["rubricPoints"] = rubricPoints }
            if let rating { detail["rating"] = rating }
            let json = (try? JSONSerialization.data(withJSONObject: detail, options: [.sortedKeys])).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
            let spec = try Self.specAndTrust(d, a, revisionId: a.revisionId).0
            let o = EvaluationOutcome(method: .selfReview, state: .graded, score: score, trust: .selfReported,
                                      feedback: note.isEmpty ? "Self-reviewed." : note)
            _ = spec
            let e = try ProgressionEngine.commit(d, attempt: a, outcome: o, source: .selfReview, revisionId: a.revisionId,
                                                 reason: rating.map { "Self-rating: \($0)" } ?? "Self-review", detail: json, batchId: nil)
            return try Self.result(d, a, e)
        }
    }

    /// "I disagree with this grade": replaces it with the learner's own call, keeping the original in history.
    @discardableResult
    public func overrideGrade(attemptId: UUID, correct: Bool, note: String = "") throws -> AttemptResult {
        try selfReview(attemptId: attemptId, score: correct ? 1 : 0, note: note.isEmpty ? "Learner override" : note)
    }

    /// Marks the current grade as disputed. A disputed grade carries no evidence or correctness XP until re-graded.
    @discardableResult
    public func dispute(attemptId: UUID, note: String) throws -> AttemptResult {
        try db.write { d in
            guard let a = try Attempt.fetchOne(d, key: attemptId), let cur = try ProgressionEngine.active(d, attemptId: attemptId) else { throw EvaluationError.notFound }
            let o = EvaluationOutcome(method: cur.method, state: .needsReview, score: nil, trust: cur.trust, feedback: "Disputed: \(note)")
            let e = try ProgressionEngine.commit(d, attempt: a, outcome: o, source: .selfReview, revisionId: cur.revisionId, reason: "Disputed: \(note)", detail: "{}", batchId: nil)
            return try Self.result(d, a, e)
        }
    }

    /// Re-runs automatic grading against the question's *current* revision and answer-key trust.
    /// Use after an answer changed or after verifying a question. Old evaluation stays in history.
    @discardableResult
    public func regrade(attemptId: UUID) throws -> AttemptResult {
        try db.write { d in
            guard let a = try Attempt.fetchOne(d, key: attemptId), let q = try Question.fetchOne(d, key: a.questionId) else { throw EvaluationError.notFound }
            let (spec, verified) = try Self.specAndTrust(d, a, revisionId: q.currentRevisionId)
            // Test-graded code needs the sandbox runner (see `evaluateCode`); never replace its grade with "pending".
            if spec.evaluation.method == .codeTests, let cur = try ProgressionEngine.active(d, attemptId: attemptId) { return try Self.result(d, a, cur) }
            let o = Evaluator.evaluate(spec: spec, response: a.decodedResponse, answerKeyVerified: verified)
            let e = try ProgressionEngine.commit(d, attempt: a, outcome: o, source: .deterministic, revisionId: q.currentRevisionId,
                                                 reason: "Regraded against current revision", detail: "{}", batchId: nil)
            return try Self.result(d, a, e)
        }
    }

    /// Regrades every attempt on this question whose grade came from automatic checking. Subjective grades
    /// (self-review, AI) are left alone. Returns how many were regraded.
    @discardableResult
    public func regradeQuestion(questionId: UUID) throws -> Int {
        let ids = try db.read { d in
            try Attempt.fetchAll(d, sql: "SELECT a.* FROM attempts a JOIN evaluations e ON e.attemptId = a.id AND e.supersededAt IS NULL WHERE a.questionId = ? AND e.source = 'deterministic'", arguments: [questionId]).map(\.id)
        }
        for id in ids { try regrade(attemptId: id) }
        return ids.count
    }

    /// Attempts graded against an answer key that has since changed (a newer revision has a different answer/evaluation).
    public func affectedAttempts(questionId: UUID) throws -> [Attempt] {
        try db.read { d in
            guard let q = try Question.fetchOne(d, key: questionId), let cur = try QuestionRevision.fetchOne(d, key: q.currentRevisionId)?.spec else { return [] }
            return try Attempt.filter(Column("questionId") == questionId).fetchAll(d).filter { a in
                guard let e = try? ProgressionEngine.active(d, attemptId: a.id), e.revisionId != q.currentRevisionId,
                      let old = try? QuestionRevision.fetchOne(d, key: e.revisionId)?.spec else { return false }
                return old.answer != cur.answer || old.evaluation != cur.evaluation
            }
        }
    }

    /// Grades a `code_tests` attempt by running the learner's files against the question's tests in the sandbox.
    /// Idempotent. If the runner is unavailable or fails internally nothing is recorded (the answer stays pending):
    /// a tooling problem is never turned into a wrong answer.
    @discardableResult
    public func evaluateCode(attemptId: UUID, runner: any CodeRunner) async throws -> AttemptResult {
        // Read first; the run happens outside any database transaction.
        let (attempt, spec, verified, existing): (Attempt, QuestionSpec, Bool, Evaluation?) = try db.read { d in
            guard let a = try Attempt.fetchOne(d, key: attemptId) else { throw EvaluationError.notFound }
            let (spec, verified) = try Self.specAndTrust(d, a, revisionId: a.revisionId)
            return (a, spec, verified, try ProgressionEngine.active(d, attemptId: attemptId))
        }
        guard spec.evaluation.method == .codeTests, let tests = spec.answer.tests, !tests.isEmpty else { throw EvaluationError.notCodeTests }
        if let e = existing, e.state == .graded, e.source == .deterministic { return try db.read { try Self.result($0, attempt, e) } }
        let files = attempt.decodedResponse.files
        let report = await runner.runTests(CodeRunRequest(files: files, language: spec.answer.language ?? "python"), tests: tests)

        let outcome: EvaluationOutcome, detail: String
        let trust: GradeTrust = verified ? .trusted : .provisional
        switch report {
        case .unavailable(let reason): throw EvaluationError.runnerUnavailable(reason)
        case .internalError(let m): throw EvaluationError.runnerUnavailable("The test runner failed (\(m)). Your answer was kept; you can retry or review it yourself.")
        case .compileError(let m):
            outcome = EvaluationOutcome(method: .codeTests, state: .graded, score: 0, trust: trust, feedback: "It didn’t compile: " + String(m.prefix(300)))
            detail = "{\"compileError\":true}"
        case .ran(let outcomes):
            let passed = outcomes.filter { $0.status == .passed }.count
            outcome = EvaluationOutcome(method: .codeTests, state: .graded, score: Double(passed) / Double(outcomes.count), trust: trust,
                                        feedback: "\(passed) of \(outcomes.count) tests passed.")
            let rows = outcomes.map { ["name": $0.name, "status": $0.status.rawValue, "hidden": $0.hidden] as [String: Any] }
            detail = (try? JSONSerialization.data(withJSONObject: ["tests": rows], options: [.sortedKeys])).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        }
        return try db.write { d in
            guard let a = try Attempt.fetchOne(d, key: attemptId) else { throw EvaluationError.notFound }
            if let e = try ProgressionEngine.active(d, attemptId: attemptId), e.state == .graded, e.source == .deterministic { return try Self.result(d, a, e) }   // raced with another run
            let e = try ProgressionEngine.commit(d, attempt: a, outcome: outcome, source: .deterministic, revisionId: a.revisionId, reason: "Tests run in the sandbox", detail: detail, batchId: nil)
            return try Self.result(d, a, e)
        }
    }

    // MARK: Reading

    public func result(attemptId: UUID) throws -> AttemptResult? {
        try db.read { d in
            guard let a = try Attempt.fetchOne(d, key: attemptId), let e = try ProgressionEngine.active(d, attemptId: attemptId) else { return nil }
            return try Self.result(d, a, e)
        }
    }

    public func history(attemptId: UUID) throws -> [Evaluation] {
        try db.read { try Evaluation.filter(Column("attemptId") == attemptId).order(Column("createdAt"), Column("rowid")).fetchAll($0) }
    }

    /// Attempts waiting for a subjective grade (optionally for one course).
    public func pendingAttempts(courseId: UUID? = nil) throws -> [PendingAttempt] {
        try db.read { d in
            var sql = """
                SELECT a.*, q.courseId AS qCourse, q.type AS qType, r.title AS qTitle FROM attempts a
                JOIN evaluations e ON e.attemptId = a.id AND e.supersededAt IS NULL AND e.state = 'pending'
                JOIN questions q ON q.id = a.questionId JOIN question_revisions r ON r.id = a.revisionId
                """
            var args: [DatabaseValueConvertible] = []
            if let c = courseId { sql += " WHERE q.courseId = ?"; args.append(c) }
            sql += " ORDER BY a.submittedAt"
            return try Row.fetchAll(d, sql: sql, arguments: StatementArguments(args)).map {
                PendingAttempt(attempt: try Attempt(row: $0), title: $0["qTitle"], type: $0["qType"], courseId: $0["qCourse"])
            }
        }
    }

    // MARK: Helpers

    static func result(_ d: Database, _ a: Attempt, _ e: Evaluation) throws -> AttemptResult {
        let xp = try Int.fetchOne(d, sql: "SELECT COALESCE(SUM(amount), 0) FROM xp_events WHERE attemptId = ?", arguments: [a.id]) ?? 0
        return AttemptResult(attempt: a, evaluation: e, xp: xp)
    }

    /// The spec to grade against, and whether its answer key counts as verified. Only the question's *current*
    /// revision can be verified; attempts graded against older revisions are provisional.
    static func specAndTrust(_ d: Database, _ a: Attempt, revisionId: UUID) throws -> (QuestionSpec, Bool) {
        guard let rev = try QuestionRevision.fetchOne(d, key: revisionId), let spec = rev.spec,
              let q = try Question.fetchOne(d, key: a.questionId) else { throw EvaluationError.notFound }
        return (spec, q.currentRevisionId == revisionId && q.readiness == .verified)
    }
}

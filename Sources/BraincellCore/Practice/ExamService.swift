import Foundation
import GRDB

public enum ExamError: Error, LocalizedError, Equatable {
    case insufficientQuestions(have: Int, need: Int)
    case notFound, notConfigured(String)
    public var errorDescription: String? {
        switch self {
        case .insufficientQuestions(let h, let n): "Only \(h) eligible multiple-choice question(s) are available but the exam needs \(n). Generate more practice or lower the question count."
        case .notFound: "That exam attempt no longer exists."
        case .notConfigured(let m): m
        }
    }
}

public struct ExamAttempt: Codable, Identifiable, Sendable, Equatable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "exam_attempts"
    public var id: UUID, sessionId: UUID
    public var assessmentId: UUID?
    public var durationSeconds: Int
    public var pointsPerQuestion: Double
    public var startedAt: Date
    public var pausedAt: Date?
    public var pausedSeconds: Int
    public var status: String          // active | paused | submitted | expired
    public var submittedAt: Date?
    public var score: Double?
    public var maxScore: Double?
}

/// Exam simulation on top of ordinary sessions: a fixed, persisted question selection and order, one exam-wide clock, and no feedback
/// or score until submission. Answers are autosaved drafts, so closing the app loses nothing.
///
/// Clock rules: time runs only while the exam is active. Pausing stops it; resuming continues with the same remaining time. When the
/// remaining time reaches zero the exam is *expired*; expiry is detected on the next check and submitting after expiry grades what was saved.
public struct ExamService: Sendable {
    let db: AppDatabase
    let now: @Sendable () -> Date
    public init(db: AppDatabase, now: @escaping @Sendable () -> Date = { Date() }) { self.db = db; self.now = now }

    @discardableResult
    public func start(courseId: UUID, assessmentId: UUID, title: String? = nil) throws -> ExamAttempt {
        let svc = AssessmentService(db: db)
        let cfg = try svc.config(assessmentId: assessmentId)
        guard let need = cfg.examQuestionCount, let minutes = cfg.durationMinutes else { throw ExamError.notConfigured("This assessment has no exam question count or duration yet. Set them first (assessments.configure).") }
        let practice = PracticeService(db: db)
        let scope = try svc.scope(courseId: courseId, assessmentId: assessmentId, requested: [], tasks: AITaskService(db: db))
        let allowed = Set(scope.skillIds)
        let eligible = try practice.candidates(courseId: courseId, assessmentId: nil).filter { c in
            c.type == .singleChoice && (c.skillIds.isEmpty || c.skillIds.contains { allowed.contains($0) })
        }
        guard eligible.count >= need else { throw ExamError.insufficientQuestions(have: eligible.count, need: need) }
        let ids = PracticeSelector.select(eligible, count: need, skills: [], weights: [:], difficulty: .mixed, types: [.singleChoice])
        let s = try practice.start(planned: ids.map { .init(questionId: $0, kind: .practice, reason: "Exam simulation") }, title: title ?? "Exam simulation", courseId: courseId, assessmentId: assessmentId, mode: .free, timed: true)
        let a = ExamAttempt(id: UUID(), sessionId: s.id, assessmentId: assessmentId, durationSeconds: minutes * 60, pointsPerQuestion: cfg.pointsPerQuestion ?? 1, startedAt: now(), pausedAt: nil, pausedSeconds: 0, status: "active", submittedAt: nil, score: nil, maxScore: nil)
        try db.write { try a.insert($0) }
        return a
    }

    public func attempt(_ id: UUID) throws -> ExamAttempt { guard let a = try db.read({ try ExamAttempt.fetchOne($0, key: id) }) else { throw ExamError.notFound }; return a }
    public func attempt(sessionId: UUID) throws -> ExamAttempt? { try db.read { try ExamAttempt.filter(Column("sessionId") == sessionId).fetchOne($0) } }

    public func remainingSeconds(_ a: ExamAttempt) -> Int {
        let end = a.pausedAt ?? now()
        let elapsed = Int(end.timeIntervalSince(a.startedAt)) - a.pausedSeconds
        return a.status == "submitted" ? 0 : max(0, a.durationSeconds - elapsed)
    }

    /// Marks an active exam expired once its time is up (idempotent). Returns the current state.
    @discardableResult
    public func refresh(_ id: UUID) throws -> ExamAttempt {
        var a = try attempt(id)
        if a.status == "active", remainingSeconds(a) == 0 { a.status = "expired"; let x = a; try db.write { try x.update($0) } }
        return a
    }

    public func pause(_ id: UUID) throws {
        var a = try refresh(id); guard a.status == "active" else { return }
        a.status = "paused"; a.pausedAt = now(); let x = a; try db.write { try x.update($0) }
    }
    public func resume(_ id: UUID) throws {
        var a = try attempt(id); guard a.status == "paused", let p = a.pausedAt else { return }
        a.pausedSeconds += Int(now().timeIntervalSince(p)); a.pausedAt = nil; a.status = "active"; let x = a; try db.write { try x.update($0) }
    }

    /// Saves the choice as a draft only: no evaluation, no feedback. Refused once the exam is submitted.
    public func saveAnswer(attemptId: UUID, itemId: UUID, selected: [String]) throws {
        let a = try refresh(attemptId)
        guard a.status == "active" || a.status == "paused" else { return }
        var r = PracticeResponse(); r.selected = selected
        try PracticeService(db: db).saveDraft(itemId: itemId, response: r)
    }

    /// Grades every saved answer once. Calling it again returns the stored result and never grades or scores twice.
    @discardableResult
    public func submit(_ id: UUID) throws -> ExamAttempt {
        let a = try refresh(id)
        if a.status == "submitted" { return a }
        let practice = PracticeService(db: db), eval = EvaluationService(db: db)
        var score = 0.0
        let items = try practice.items(sessionId: a.sessionId)
        for it in items {
            guard let at = try? practice.submit(itemId: it.id) else { continue }          // unanswered items simply score 0
            let r = try eval.evaluate(attemptId: at.id)
            if (r.evaluation.score ?? 0) >= 0.999 { score += a.pointsPerQuestion }
        }
        let max = Double(items.count) * a.pointsPerQuestion
        let changed = try db.write { d -> Int in
            try d.execute(sql: "UPDATE exam_attempts SET status = 'submitted', submittedAt = ?, score = ?, maxScore = ? WHERE id = ? AND status != 'submitted'", arguments: [now(), score, max, id])
            return d.changesCount
        }
        _ = changed
        try practice.setStatus(a.sessionId, .completed)
        return try attempt(id)
    }
}

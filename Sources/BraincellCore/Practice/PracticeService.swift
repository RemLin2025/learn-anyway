import Foundation
import GRDB

public enum PracticeError: Error, LocalizedError, Equatable {
    case noQuestions
    case notFound
    case alreadySubmitted
    case nothingToSubmit
    case sessionCompleted

    public var errorDescription: String? {
        switch self {
        case .noQuestions: "There are no questions to practice yet."
        case .notFound: "That session no longer exists."
        case .alreadySubmitted: "This question was already submitted."
        case .nothingToSubmit: "Enter an answer before submitting (or skip the question)."
        case .sessionCompleted: "This session is finished."
        }
    }
}

public enum PracticeLayout: Sendable {
    /// Spacious, question-centred: recall and short answers.
    case focus
    /// Resizable problem/answer regions: code, derivations, long-form.
    case workspace

    public static func `for`(_ t: QuestionType) -> PracticeLayout {
        switch t {
        case .flashcard, .singleChoice, .multipleSelect, .shortAnswer, .numeric: .focus
        case .codeTracing, .coding, .longForm, .derivationProof: .workspace
        }
    }
}

public struct SessionSummary: Sendable, Equatable {
    public var total: Int, submitted: Int, skipped: Int, unanswered: Int, hintsUsed: Int, activeSeconds: Int
}

/// Study sessions, autosaved drafts and immutable attempts. Grading and XP are deliberately not here (see EvaluationService):
/// a submitted attempt is stored as-is and is never treated as correct or incorrect by this service.
public struct PracticeService: Sendable {
    let db: AppDatabase
    public init(db: AppDatabase) { self.db = db }

    // MARK: Selecting questions

    /// Questions for an assessment (cumulative → the whole course) or for a whole course. Archived ones are excluded.
    public func questionIds(courseId: UUID, assessmentId: UUID? = nil) throws -> [UUID] {
        try db.read { d in
            if let a = assessmentId, let asm = try Assessment.fetchOne(d, key: a), !asm.isCumulative {
                return try UUID.fetchAll(d, sql: """
                    SELECT q.id FROM questions q JOIN question_assessments qa ON qa.questionId = q.id
                    WHERE qa.assessmentId = ? AND q.archivedAt IS NULL ORDER BY q.createdAt, q.rowid
                    """, arguments: [a])
            }
            return try UUID.fetchAll(d, sql: "SELECT id FROM questions WHERE courseId = ? AND archivedAt IS NULL ORDER BY createdAt, rowid", arguments: [courseId])
        }
    }

    // MARK: Sessions

    @discardableResult
    public func start(questionIds: [UUID], title: String, courseId: UUID? = nil, assessmentId: UUID? = nil) throws -> StudySession {
        guard !questionIds.isEmpty else { throw PracticeError.noQuestions }
        return try db.write { d in
            let s = StudySession(id: UUID(), courseId: courseId, assessmentId: assessmentId, title: title, status: .active,
                                 currentOrdinal: 0, startedAt: Date(), updatedAt: Date(), completedAt: nil)
            try s.insert(d)
            var ordinal = 0
            for qid in questionIds {
                guard let q = try Question.fetchOne(d, key: qid), q.archivedAt == nil else { continue }
                try SessionItem(id: UUID(), sessionId: s.id, ordinal: ordinal, questionId: qid, revisionId: q.currentRevisionId,
                                status: .notStarted, hintsUsed: 0, activeSeconds: 0).insert(d)
                ordinal += 1
            }
            guard ordinal > 0 else { throw PracticeError.noQuestions }
            return s
        }
    }

    public struct PlannedStart: Sendable {
        public var questionId: UUID
        public var kind: ItemKind
        public var reason: String
        public init(questionId: UUID, kind: ItemKind, reason: String) { self.questionId = questionId; self.kind = kind; self.reason = reason }
    }

    /// Starts a session from a plan, keeping each item's kind and the reason it was suggested.
    @discardableResult
    public func start(planned: [PlannedStart], title: String, courseId: UUID?, assessmentId: UUID? = nil, mode: SessionMode, timed: Bool = false) throws -> StudySession {
        guard !planned.isEmpty else { throw PracticeError.noQuestions }
        return try db.write { d in
            let s = StudySession(id: UUID(), courseId: courseId, assessmentId: assessmentId, title: title, status: .active, currentOrdinal: 0,
                                 startedAt: Date(), updatedAt: Date(), completedAt: nil, mode: mode, timed: timed)
            try s.insert(d)
            var ordinal = 0
            for p in planned {
                guard let q = try Question.fetchOne(d, key: p.questionId), q.archivedAt == nil else { continue }
                try SessionItem(id: UUID(), sessionId: s.id, ordinal: ordinal, questionId: p.questionId, revisionId: q.currentRevisionId,
                                status: .notStarted, hintsUsed: 0, activeSeconds: 0, kind: p.kind, reason: p.reason).insert(d)
                ordinal += 1
            }
            guard ordinal > 0 else { throw PracticeError.noQuestions }
            return s
        }
    }

    public func session(_ id: UUID) throws -> StudySession {
        guard let s = try db.read({ try StudySession.fetchOne($0, key: id) }) else { throw PracticeError.notFound }
        return s
    }

    /// The most recent unfinished session, for resuming after a relaunch.
    public func resumableSession() throws -> StudySession? {
        try db.read { try StudySession.filter(Column("status") != SessionStatus.completed).order(Column("updatedAt").desc).fetchOne($0) }
    }

    public func items(sessionId: UUID) throws -> [SessionItem] {
        try db.read { try SessionItem.filter(Column("sessionId") == sessionId).order(Column("ordinal")).fetchAll($0) }
    }

    public func setStatus(_ id: UUID, _ status: SessionStatus) throws {
        try db.write { d in
            guard var s = try StudySession.fetchOne(d, key: id) else { throw PracticeError.notFound }
            s.status = status; s.updatedAt = Date()
            if status == .completed { s.completedAt = Date() }
            try s.update(d)
        }
    }

    public func moveTo(sessionId: UUID, ordinal: Int) throws {
        try db.write { d in
            guard var s = try StudySession.fetchOne(d, key: sessionId) else { throw PracticeError.notFound }
            let n = try SessionItem.filter(Column("sessionId") == sessionId).fetchCount(d)
            s.currentOrdinal = min(max(0, ordinal), n - 1); s.updatedAt = Date()
            try s.update(d)
        }
    }

    // MARK: Drafts

    /// Idempotent upsert; called on every (debounced) edit. Refuses once the item is submitted.
    public func saveDraft(itemId: UUID, response: PracticeResponse) throws {
        try db.write { d in
            guard var item = try SessionItem.fetchOne(d, key: itemId) else { throw PracticeError.notFound }
            guard item.status != .submitted else { throw PracticeError.alreadySubmitted }
            try AttemptDraft(sessionItemId: itemId, response: Self.encode(response), updatedAt: Date()).save(d)
            if item.status == .notStarted || item.status == .skipped { item.status = .inProgress; try item.update(d) }
        }
    }

    /// The saved draft, the submitted response, or the question's starter content.
    public func response(for item: SessionItem, spec: QuestionSpec) throws -> PracticeResponse {
        try db.read { d in
            if let a = try Attempt.fetchOne(d, key: ["sessionItemId": item.id]) { return a.decodedResponse }
            if let draft = try AttemptDraft.fetchOne(d, key: item.id) { return Self.decode(draft.response) }
            return Self.initialResponse(for: spec)
        }
    }

    public static func initialResponse(for spec: QuestionSpec) -> PracticeResponse {
        var r = PracticeResponse()
        if spec.type == .coding {
            let lang = spec.answer.language ?? "python"
            r.files = [CodeFile(name: defaultFileName(lang), language: lang, content: spec.answer.starterCode ?? "")]
        }
        return r
    }

    public static func defaultFileName(_ lang: String) -> String {
        switch lang { case "java": "Main.java"; case "c": "main.c"; default: "main.py" }
    }

    // MARK: Hints, time, skip

    /// Reveals hints progressively: level n shows the first n hints. Never decreases.
    public func revealHint(itemId: UUID, level: Int) throws {
        try db.write { d in
            guard var item = try SessionItem.fetchOne(d, key: itemId), let rev = try QuestionRevision.fetchOne(d, key: item.revisionId),
                  let spec = rev.spec else { throw PracticeError.notFound }
            guard item.status != .submitted else { throw PracticeError.alreadySubmitted }
            item.hintsUsed = max(item.hintsUsed, min(level, spec.hints.count))
            try item.update(d)
        }
    }

    public func addActiveSeconds(itemId: UUID, _ seconds: Int) throws {
        guard seconds > 0 else { return }
        try db.write { d in
            guard var item = try SessionItem.fetchOne(d, key: itemId) else { throw PracticeError.notFound }
            guard item.status != .submitted else { return } // attempt snapshot already holds the time
            item.activeSeconds += min(seconds, 600)
            try item.update(d)
        }
    }

    /// Skipping keeps any draft; the learner can return to the item later.
    public func skip(itemId: UUID) throws {
        try db.write { d in
            guard var item = try SessionItem.fetchOne(d, key: itemId) else { throw PracticeError.notFound }
            guard item.status != .submitted else { throw PracticeError.alreadySubmitted }
            item.status = .skipped; try item.update(d)
        }
    }

    // MARK: Submission

    /// Creates the immutable attempt from the latest draft. Submitting an already-submitted item returns the
    /// existing attempt, so a double click or retry can never create a second one.
    @discardableResult
    public func submit(itemId: UUID, response: PracticeResponse? = nil) throws -> Attempt {
        try db.write { d in
            guard var item = try SessionItem.fetchOne(d, key: itemId) else { throw PracticeError.notFound }
            if let existing = try Attempt.fetchOne(d, key: ["sessionItemId": itemId]) { return existing }
            let draft = try AttemptDraft.fetchOne(d, key: itemId).map { Self.decode($0.response) }
            guard let final = response ?? draft, !final.isEmpty else { throw PracticeError.nothingToSubmit }
            let a = Attempt(id: UUID(), sessionItemId: itemId, questionId: item.questionId, revisionId: item.revisionId,
                            response: Self.encode(final), hintsUsed: item.hintsUsed, activeSeconds: item.activeSeconds, submittedAt: Date())
            try a.insert(d)
            item.status = .submitted; try item.update(d)
            try d.execute(sql: "DELETE FROM attempt_drafts WHERE sessionItemId = ?", arguments: [itemId])
            return a
        }
    }

    public func attempt(itemId: UUID) throws -> Attempt? {
        try db.read { try Attempt.fetchOne($0, key: ["sessionItemId": itemId]) }
    }

    public func attempts(questionId: UUID) throws -> [Attempt] {
        try db.read { try Attempt.filter(Column("questionId") == questionId).order(Column("submittedAt").desc).fetchAll($0) }
    }

    public func summary(sessionId: UUID) throws -> SessionSummary {
        let items = try items(sessionId: sessionId)
        return SessionSummary(total: items.count, submitted: items.filter { $0.status == .submitted }.count,
                              skipped: items.filter { $0.status == .skipped }.count,
                              unanswered: items.filter { $0.status == .notStarted || $0.status == .inProgress }.count,
                              hintsUsed: items.reduce(0) { $0 + $1.hintsUsed }, activeSeconds: items.reduce(0) { $0 + $1.activeSeconds })
    }

    /// The pinned revision's content for an item.
    public func spec(for item: SessionItem) throws -> QuestionSpec {
        guard let rev = try db.read({ try QuestionRevision.fetchOne($0, key: item.revisionId) }), let spec = rev.spec else { throw PracticeError.notFound }
        return spec
    }

    // MARK: Encoding

    static func encode(_ r: PracticeResponse) -> String {
        let e = JSONEncoder(); e.outputFormatting = .sortedKeys
        return (try? e.encode(r)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
    }
    static func decode(_ s: String) -> PracticeResponse {
        (try? JSONDecoder().decode(PracticeResponse.self, from: Data(s.utf8))) ?? PracticeResponse()
    }
}

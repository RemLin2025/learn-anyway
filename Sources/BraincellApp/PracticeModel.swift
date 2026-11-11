import SwiftUI
import BraincellCore

/// State for one practice session: current item, autosaved draft, hints, active time. All persistence goes through
/// `PracticeService`; this class only schedules it (debounced autosave, periodic time flush, flush on exit/quit).
@MainActor
final class PracticeModel: ObservableObject {
    let app: AppModel
    let svc: PracticeService
    let evalSvc: EvaluationService
    let progSvc: ProgressionService
    let sessionID: UUID
    let exams: ExamService
    /// Exam simulation: answers are saved as drafts only; no feedback, hints or score until the exam is submitted.
    @Published var exam: ExamAttempt?
    @Published var examRemaining = 0

    @Published var session: StudySession?
    @Published var items: [SessionItem] = []
    @Published var specs: [UUID: QuestionSpec] = [:]
    @Published var index = 0
    @Published var response = PracticeResponse() { didSet { if !loading, attempt == nil { dirty = true; scheduleSave() } } }
    @Published var attempt: Attempt?
    @Published var paused = false
    @Published var seconds = 0
    @Published var summary: SessionResults?
    @Published var result: AttemptResult?
    @Published var skills: [Skill] = []
    @Published var coachSuggestion: CoachSuggestion?
    @Published var askConfidence = false
    @Published var confidence: Int?
    @Published var testReport: CodeTestReport?
    @Published var tryOutput: CodeRunOutput?
    @Published var tryMessage: String?
    @Published var running = false

    private var loading = false
    private var dirty = false
    private var pendingSeconds = 0
    private var saveTask: Task<Void, Never>?

    init(app: AppModel, sessionID: UUID) {
        self.app = app; self.sessionID = sessionID
        self.svc = app.practice ?? PracticeService(db: app.db!)
        self.evalSvc = app.evaluation ?? EvaluationService(db: app.db!)
        self.progSvc = app.progression ?? ProgressionService(db: app.db!)
        self.exams = ExamService(db: app.db!)
        load()
    }

    var examActive: Bool { exam.map { $0.status != "submitted" } ?? false }
    var item: SessionItem? { items.indices.contains(index) ? items[index] : nil }
    var spec: QuestionSpec? { item.flatMap { specs[$0.id] } }
    var locked: Bool { attempt != nil }
    var layout: PracticeLayout { spec.map { PracticeLayout.for($0.type) } ?? .focus }
    var hintsUsed: Int { item?.hintsUsed ?? 0 }
    var isLast: Bool { index >= items.count - 1 }

    private func fail(_ e: Error) { app.alertMessage = e.localizedDescription }

    func load() {
        do {
            let s = try svc.session(sessionID)
            session = s
            exam = try exams.attempt(sessionId: sessionID)
            if let e = exam { examRemaining = exams.remainingSeconds(e) }
            items = try svc.items(sessionId: sessionID)
            for it in items { specs[it.id] = try svc.spec(for: it) }
            paused = s.status == .paused
            if s.status == .completed { summary = try progSvc.sessionResults(sessionId: sessionID) }
            enter(min(s.currentOrdinal, max(0, items.count - 1)))
        } catch { fail(error) }
    }

    func enter(_ i: Int) {
        guard items.indices.contains(i) else { return }
        loading = true; defer { loading = false }
        index = i
        let it = items[i]
        do {
            attempt = try svc.attempt(itemId: it.id)
            // Idempotent: grades the attempt if nothing has yet (e.g. submitted before grading existed).
            result = try attempt.map { try evalSvc.evaluate(attemptId: $0.id) }
            response = try svc.response(for: it, spec: specs[it.id]!)
            seconds = it.activeSeconds
            skills = (try? app.questions?.detail(it.questionId).skills) ?? []
            coachSuggestion = nil; confidence = nil; testReport = nil; tryOutput = nil; tryMessage = nil
            askConfidence = attempt == nil && ((try? app.history?.shouldAskConfidence(itemId: it.id, setting: app.confidencePrompts)) ?? false)
            if SnapshotRunner.isActive, let a = attempt { coachSuggestion = try? app.coach?.suggestion(sessionId: sessionID, attemptId: a.id, enabled: true, now: Date().addingTimeInterval(7200)) } // screenshot aid
            try svc.moveTo(sessionId: sessionID, ordinal: i)
        } catch { fail(error) }
    }

    // MARK: Persistence

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 600_000_000)
            if !Task.isCancelled { self?.flush() }
        }
    }

    /// Writes the draft and any unsaved active time. Cheap and idempotent; called on every navigation and on exit.
    func flush() {
        saveTask?.cancel()
        guard let it = item else { return }
        do {
            if dirty, attempt == nil { try svc.saveDraft(itemId: it.id, response: response); dirty = false }
            if pendingSeconds > 0, attempt == nil { try svc.addActiveSeconds(itemId: it.id, pendingSeconds); pendingSeconds = 0 }
            items = try svc.items(sessionId: sessionID)
        } catch { fail(error) }
    }

    func tick(active: Bool) {
        if examActive, let e = exam {
            examRemaining = exams.remainingSeconds(e)
            if examRemaining == 0, !paused { app.alertMessage = "Time is up. Your saved answers were submitted."; finish(); return }
        }
        guard active, !paused, attempt == nil, summary == nil else { return }
        seconds += 1; pendingSeconds += 1
        if pendingSeconds >= 10 { flush() }
    }

    func togglePause() {
        flush()
        paused.toggle()
        if let e = exam, examActive { if paused { try? exams.pause(e.id) } else { try? exams.resume(e.id) }; exam = try? exams.attempt(e.id) }
        try? svc.setStatus(sessionID, paused ? .paused : .active)
    }

    // MARK: Actions

    func go(_ delta: Int) { flush(); enter(index + delta) }

    func revealHint() {
        guard let it = item, let s = spec, hintsUsed < s.hints.count, !locked, !examActive else { return }
        flush()
        do { try svc.revealHint(itemId: it.id, level: hintsUsed + 1); items = try svc.items(sessionId: sessionID) } catch { fail(error) }
    }

    func submit() {
        guard let it = item, !locked else { return }
        flush()
        if examActive { if !isLast { enter(index + 1) }; return }          // exam: the answer is saved, never graded or revealed here
        do {
            attempt = try svc.submit(itemId: it.id, response: response)
            result = try attempt.map { try evalSvc.evaluate(attemptId: $0.id) }
            items = try svc.items(sessionId: sessionID)
            if spec?.evaluation.method == .codeTests, app.codeRunner.isAvailable { Task { await gradeCode() } }
            if let a = attempt {
                if let c = confidence { try app.history?.recordConfidence(attemptId: a.id, level: c) }
                coachSuggestion = try app.coach?.suggestion(sessionId: sessionID, attemptId: a.id, enabled: app.coachEnabled)
            }
        } catch { fail(error) }
    }

    private func refreshCoach(_ a: Attempt) {
        guard coachSuggestion == nil else { return }
        coachSuggestion = try? app.coach?.suggestion(sessionId: sessionID, attemptId: a.id, enabled: app.coachEnabled)
    }

    func dismissCoach(accepted: Bool = false) {
        if let s = coachSuggestion { try? app.coach?.dismiss(eventId: s.id, accepted: accepted) }
        coachSuggestion = nil
    }

    func addReflection(_ text: String) {
        guard let cid = session?.courseId else { return }
        try? app.history?.addReflection(courseId: cid, text: text, sessionId: sessionID, attemptId: attempt?.id)
    }

    // MARK: Running code (sandboxed child process; nothing runs in this app)

    func runTests() async {
        guard let spec, spec.type == .coding, !running else { return }
        running = true; defer { running = false }
        testReport = await app.codeRunner.runTests(CodeRunRequest(files: response.files, language: spec.answer.language ?? "python"), tests: spec.answer.tests ?? [])
    }

    func tryRun(stdin: String) async {
        guard let spec, spec.type == .coding, !running else { return }
        running = true; defer { running = false }
        tryOutput = nil; tryMessage = nil
        switch await app.codeRunner.run(CodeRunRequest(files: response.files, language: spec.answer.language ?? "python", stdin: stdin)) {
        case .unavailable(let r): tryMessage = r
        case .finished(let o): tryOutput = o
        }
    }

    /// Grades a submitted test-based answer in the sandbox. A runner problem leaves the answer pending, never wrong.
    func gradeCode() async {
        guard let a = attempt, spec?.evaluation.method == .codeTests else { return }
        running = true; defer { running = false }
        do { result = try await evalSvc.evaluateCode(attemptId: a.id, runner: app.codeRunner); refreshCoach(a) }
        catch { app.alertMessage = error.localizedDescription }
    }

    func selfReview(score: Double, rubricPoints: [String: Double]? = nil, rating: String? = nil) {
        guard let a = attempt else { return }
        do { result = try evalSvc.selfReview(attemptId: a.id, score: score, rubricPoints: rubricPoints, rating: rating); refreshCoach(a) } catch { fail(error) }
    }

    func overrideGrade(correct: Bool) {
        guard let a = attempt else { return }
        do { result = try evalSvc.overrideGrade(attemptId: a.id, correct: correct, note: "Learner override of the automatic grade"); refreshCoach(a) } catch { fail(error) }
    }

    func skip() {
        guard let it = item, !locked else { return }
        flush()
        do { try svc.skip(itemId: it.id); items = try svc.items(sessionId: sessionID) } catch { fail(error) }
        if !isLast { enter(index + 1) }
    }

    func finish() {
        flush()
        if let e = exam, examActive { do { exam = try exams.submit(e.id); items = try svc.items(sessionId: sessionID) } catch { fail(error); return } }
        do { try svc.setStatus(sessionID, .completed); summary = try progSvc.sessionResults(sessionId: sessionID); session = try svc.session(sessionID) } catch { fail(error) }
    }

    func exit() {
        flush()
        if summary == nil { try? svc.setStatus(sessionID, .paused) }
        app.activeSessionID = nil
        app.reload()
    }
}

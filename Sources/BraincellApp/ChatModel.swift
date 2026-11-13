import SwiftUI
import AppKit
import BraincellCore

/// UI-facing state for the Home chat. All behaviour lives in BraincellCore's AgentRunner/AgentStore; this holds published copies and runs the app-side
/// actions (navigation, file picking, starting practice) that chat buttons map to.
@MainActor
final class ChatModel: ObservableObject {
    let ctx: AgentContext
    let runner: AgentRunner
    unowned let app: AppModel
    @Published private(set) var conversations: [ChatConversation] = []
    @Published private(set) var currentId: UUID?
    @Published private(set) var messages: [ChatMessage] = []
    @Published private(set) var thinking = false
    @Published var draft = ""
    @Published var courseId: UUID?
    @Published private(set) var attached: [URL] = []
    @Published var importing = false
    @Published var notice: String?
    /// The real workflow stage being run ("Reading sources"), shown while thinking. Never model reasoning.
    @Published private(set) var stage: String?
    @Published var historyQuery = "" { didSet { reloadList() } }
    private var task: Task<Void, Never>?
    /// Identifies the running operation. Events from a stopped, superseded or other-conversation operation carry an old id and are ignored.
    private var currentOp: UUID?

    init(app: AppModel, ctx: AgentContext) {
        self.app = app; self.ctx = ctx; runner = AgentRunner(ctx)
        try? StudyPrep.recoverInterrupted(ctx.db)
        _ = try? ctx.store.recoverInterrupted()           // work cut short by the last quit is reported honestly, with Retry
        reloadList()
    }

    var store: AgentStore { ctx.store }
    var isEmpty: Bool { messages.isEmpty }

    private func events(op: UUID, conv: UUID) -> @Sendable (AgentEvent) -> Void {
        { [weak self] e in Task { @MainActor in
            guard let self, self.currentOp == op, self.currentId == conv else { return }          // late event from a cancelled or other operation
            switch e { case .changed: self.reload(); case .thinking(let on): self.thinking = on; if !on { self.stage = nil }; case .stage(let s): self.stage = s }
        } }
    }

    func reloadList() { conversations = (try? (historyQuery.trimmed.isEmpty ? store.conversations() : store.search(historyQuery))) ?? [] }
    func reload() {
        reloadList()
        messages = (currentId.flatMap { try? store.messages($0) } ?? []).filter { $0.kind != .call }      // raw tool-call replies stay out of the transcript
    }
    var canRegenerate: Bool { !thinking && messages.last.map { $0.role == .assistant && $0.kind == .text } == true }

    // MARK: Conversations

    func newChat() { stop(); currentId = nil; messages = []; draft = ""; attached = []; notice = nil }
    func open(_ id: UUID) { stop(); currentId = id; courseId = (try? store.conversation(id))?.courseId; reload() }
    func rename(_ id: UUID, _ t: String) { try? store.rename(id, to: t); reloadList() }
    func delete(_ id: UUID) { try? store.delete(id); if currentId == id { newChat() }; reloadList() }
    func setCourse(_ id: UUID?) { courseId = id; if let c = currentId { try? store.setCourse(c, id) } }

    // MARK: Sending

    func send() {
        let text = draft.trimmed
        guard !text.isEmpty || !attached.isEmpty, !thinking else { return }
        var full = text
        if !attached.isEmpty {
            let place = courseId.flatMap { id in app.courseList.first { $0.id == id }?.name } ?? "the Library"
            full += (full.isEmpty ? "" : "\n\n") + "(I attached: " + attached.map(\.lastPathComponent).joined(separator: ", ") + ". They were imported into \(place); use library.search to find them.)"
        }
        draft = ""; attached = []
        let message = full
        let id: UUID
        if let c = currentId { id = c } else {
            guard let made = try? store.createConversation(courseId: courseId) else { return }
            id = made.id; currentId = id
        }
        run(id) { await $0.send(id, text: message, events: $1) }
    }

    func edit(_ messageId: UUID, text: String) { guard let id = currentId, !thinking else { return }; run(id) { await $0.edit(messageId, text: text, events: $1) } }
    func regenerate() { guard let id = currentId, canRegenerate else { return }; run(id) { await $0.regenerate(id, events: $1) } }
    func restoreEdit(_ messageId: UUID) { guard !thinking else { return }; try? store.restoreEdit(messageId); reload() }

    func stop() { task?.cancel(); task = nil; currentOp = nil; thinking = false; stage = nil }
    func approve(_ actionId: UUID) { guard let id = currentId else { return }; run(id) { await $0.approve(actionId, events: $1) } }
    func decline(_ actionId: UUID) { guard let id = currentId else { return }; run(id) { await $0.decline(actionId, events: $1) } }
    func retry() { guard let id = currentId else { return }; run(id) { await $0.retry(id, events: $1) } }
    func savePreview(_ generationId: UUID) { guard let id = currentId else { return }; run(id) { await $0.saveGeneration(generationId, events: $1) } }
    func discardPreview(_ generationId: UUID) { guard let id = currentId else { return }; runner.discardGeneration(generationId, events: events(op: currentOp ?? UUID(), conv: id)); reload() }

    private func run(_ conv: UUID, _ work: @escaping @Sendable (AgentRunner, @escaping @Sendable (AgentEvent) -> Void) async -> Void) {
        let op = UUID(); currentOp = op
        let r = runner, ev = events(op: op, conv: conv)
        thinking = true; stage = nil
        task = Task { await work(r, ev); await MainActor.run { guard self.currentOp == op else { return }; self.thinking = false; self.stage = nil; self.task = nil; self.reload() } }
    }

    // MARK: Attachments (imported through the Library, so Materials and Library show them too)

    func attachFiles(_ urls: [URL]) {
        guard !urls.isEmpty, let lib = app.library else { return }
        let loc: LibraryLocation = courseId.map { .course($0) } ?? .root
        importing = true
        Task.detached {
            let r = lib.importFiles(urls, into: loc)
            await MainActor.run {
                self.importing = false
                self.attached += urls
                self.notice = r.failures.isEmpty ? nil : "Some files couldn’t be imported: " + r.failures.map { "\($0.path) (\($0.message))" }.joined(separator: "; ")
                self.app.reload()
            }
        }
    }
    func removeAttachment(_ u: URL) { attached.removeAll { $0 == u } }

    func pickFiles(into course: UUID? = nil, thenSend: Bool = false) {
        let p = NSOpenPanel(); p.canChooseFiles = true; p.canChooseDirectories = true; p.allowsMultipleSelection = true
        p.message = "Choose files or folders to add"; p.prompt = "Add"
        guard p.runModal() == .OK else { return }
        if let course { courseId = course }
        attachFiles(p.urls)
        if thenSend { draft = draft.isEmpty ? "I added files. Please continue." : draft }
    }

    // MARK: Chip actions: each performs a real app operation

    func perform(_ chip: ActionChip) {
        switch chip.action {
        case "openCourse": if let id = chip.courseId { app.selectedCourseID = id; app.selection = .courses }
        case "openPracticeSet": if let id = chip.courseId { app.selectedCourseID = id; app.selection = .courses; app.courseTabRequest = "assessments"; app.openPracticeSetID = chip.setId }
        case "openLibrary": app.selection = .library
        case "openQuestionBank": app.openQuestionBank(course: chip.courseId)
        case "openSkills": if let id = chip.courseId { app.selectedCourseID = id }; app.selection = .skills
        case "addFiles": pickFiles(into: chip.courseId, thenSend: true)
        case "startPractice":
            if let p = chip.planId { startPlanDay(planId: p, dayIndex: chip.dayIndex ?? 0) }
            else if let id = chip.courseId { app.practiceSetup = PracticeSetupRequest(courseId: id, assessmentId: chip.assessmentId) }
        case "prepareExam":
            // Resume or regenerate: the job is idempotent, so this continues from the saved stage and skips finished work.
            let c = app.courseList.first { $0.id == chip.courseId }?.name ?? "my course", a = (try? app.courses?.assessments(courseId: chip.courseId ?? UUID()))?.first { $0.id == chip.assessmentId }?.name
            draft = "Prepare \(a ?? "my exam") in \(c)."; send()
        case "startReviews": app.startReviews()
        case "resumeSession": if let s = app.resumableSession { app.activeSessionID = s.id } else { app.alertMessage = "There is no unfinished session to resume." }
        case "openPlan": if let p = chip.planId, let conv = try? store.plan(p)?.conversationId { open(conv) }
        default: break
        }
    }

    /// Runs the saved-progress exam preparation in Home chat (topics + questions); finished work is reused.
    func analyzeTopics(course: Course, assessment: Assessment?) {
        app.selection = .home
        draft = "Prepare \(assessment?.name ?? "my exam") in \(course.name)."; send()
    }

    func startPlanDay(planId: UUID, dayIndex: Int) {
        guard let rec = try? store.plan(planId), let doc = AgentStore.decode(rec), doc.days.indices.contains(dayIndex) else { return }
        let day = doc.days[dayIndex]
        guard !day.items.isEmpty else { app.alertMessage = "That day has no scheduled questions yet. Generate questions, then ask me to rebuild the plan."; return }
        app.perform {
            let items = day.items.map { PracticeService.PlannedStart(questionId: $0.questionId, kind: .practice, reason: $0.reason) }
            app.activeSessionID = try app.practice?.start(planned: items, title: "\(rec.title) · \(day.label)", courseId: rec.courseId, assessmentId: rec.assessmentId, mode: .mastery).id
        }
    }

    // MARK: Model selection (writes the same task route the AI Workflow page edits)

    var resolution: Resolution { (try? ctx.gateway.resolve(WorkflowTask.find("chatAssistant")!)) ?? Resolution() }
    func chooseModel(connection: AIConnection?, model: AIModelRecord?) {
        guard let cfg = app.aiConfig else { return }
        var r = cfg.route(WorkflowTask.find("chatAssistant")!)
        if let connection, let model { r.inherit = false; r.manualBridge = false; r.connectionId = connection.id; r.modelId = model.modelId }
        else { r.inherit = true; r.manualBridge = false; r.connectionId = nil; r.modelId = nil }
        cfg.save(r); objectWillChange.send()
    }
}

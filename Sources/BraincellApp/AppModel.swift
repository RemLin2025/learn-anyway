import SwiftUI
import BraincellCore

enum SidebarItem: String, CaseIterable, Identifiable {
    case home = "Home", courses = "Courses", library = "Library", questionBank = "Question Bank", skills = "Skills", insights = "Insights", aiTasks = "AI Tasks"
    var id: String { rawValue }
    var symbol: String {
        switch self {
        case .home: "house"
        case .courses: "graduationcap"
        case .library: "books.vertical"
        case .questionBank: "rectangle.stack"
        case .skills: "point.3.connected.trianglepath.dotted"
        case .insights: "chart.line.uptrend.xyaxis"
        case .aiTasks: "tray.and.arrow.up"
        }
    }
}

/// Application container: owns services and the UI-facing selection state.
@MainActor
final class AppModel: ObservableObject {
    let db: AppDatabase?
    let storage: ManagedStorage?
    let startupError: String?
    let courses: CourseService?
    let documents: DocumentService?
    let settings: SettingsStore?
    let questions: QuestionService?
    let ai: AITaskService?
    let practice: PracticeService?
    let evaluation: EvaluationService?
    let progression: ProgressionService?
    let planner: PlannerService?
    let reviews: ReviewService?
    let history: LearningHistoryService?
    let coach: CoachService?
    let stuck: StuckService?
    /// Routes every model request (task routing, retries, usage). nil only when the database failed to open.
    let gateway: AIGateway?
    /// Library + course Materials (one store). Soft-deleted items are purged on launch once their seven days are up.
    let library: LibraryService?

    @Published var selection: SidebarItem? = .home
    lazy var aiConfig: AIConfig? = gateway.map { AIConfig(gateway: $0) }
    @Published var selectedCourseID: UUID?
    /// Set to ask for confirmation before deleting this course (from the Courses page or a Library course folder).
    @Published var askDeleteCourse: UUID?
    @Published var courseList: [Course] = []
    @Published var appearance: AppearanceSetting = .system
    @Published var onboardingDismissed = false
    @Published var alertMessage: String?
    /// Bumped after every mutation so detail views reload.
    @Published var revision = 0
    @Published var activeSessionID: UUID?
    /// Opens the "grade pending answers" sheet in AI Tasks.
    @Published var showGradingSheet = false
    @Published var codeFontSize = 13
    @Published var coachEnabled = true
    @Published var codeExecutionEnabled = false
    @Published var directAPIEnabled = false
    @Published var directAPIModel = DirectAIService.defaultModel
    @Published var hasAPIKey = false
    let secrets: SecretStore = KeychainSecretStore(legacyService: "com.cramlab.api-keys")
    private lazy var sandboxRunner = SandboxedCodeRunner()
    @Published var confidencePrompts = "minimal"
    @Published var snapshotMap = false
    /// Screenshot aid: asks the root view to open the Settings window.
    @Published var snapshotOpenSettings = false
    /// Screenshot aids for the Courses page (which tab to show / open Recently Deleted).
    @Published var snapshotCourseTab: String?
    @Published var snapshotShowDeleted = false
    @Published var snapshotLibrarySearch: String?
    /// Screenshot aid: jumps the practice view to this item.
    @Published var snapshotIndex: Int?
    /// Set to open the "new AI task" sheet prefilled (e.g. Generate Similar).
    @Published var generateRequest: GenerateRequest?

    init(databaseURL: URL? = nil, storage: ManagedStorage = AppModel.defaultStorage()) {
        do {
            if databaseURL == nil, storage.root == ManagedStorage.defaultRoot() { try ManagedStorage.migrateLegacy(from: ManagedStorage.legacyRoot(), to: storage.root) }
            let url = databaseURL ?? storage.root.appendingPathComponent("braincell.sqlite")
            let db = try AppDatabase.open(at: url)
            self.db = db
            self.storage = storage
            courses = CourseService(db: db)
            documents = DocumentService(db: db, storage: storage)
            settings = SettingsStore(db: db)
            questions = QuestionService(db: db)
            ai = AITaskService(db: db)
            practice = PracticeService(db: db)
            evaluation = EvaluationService(db: db)
            progression = ProgressionService(db: db)
            planner = PlannerService(db: db)
            reviews = ReviewService(db: db)
            history = LearningHistoryService(db: db)
            coach = CoachService(db: db)
            stuck = StuckService(db: db)
            gateway = AIGateway(db: db, secrets: secrets)
            library = LibraryService(db: db, storage: storage)
            _ = try? library?.purgeExpired()
            coachEnabled = (try? settings?.bool(.coachEnabled, default: true)) ?? true
            codeExecutionEnabled = (try? settings?.bool(.codeExecutionEnabled)) ?? false
            directAPIEnabled = (try? settings?.bool(.directAPIEnabled)) ?? false
            if let m = (try? settings?.string(.directAPIModel)) ?? nil, !m.isEmpty { directAPIModel = m }
            hasAPIKey = ((try? secrets.read(DirectAIService.keyAccount)) ?? nil) != nil
            confidencePrompts = (try? settings?.string(.confidencePrompts)) ?? "minimal"
            startupError = nil
            appearance = (try? settings?.appearance()) ?? .system
            onboardingDismissed = (try? settings?.bool(.onboardingDismissed)) ?? false
            codeFontSize = (try? settings?.int(.codeFontSize, default: 13)) ?? 13
            reload()
        } catch {
            db = nil; self.storage = nil; courses = nil; documents = nil; settings = nil; questions = nil; ai = nil; practice = nil; evaluation = nil; progression = nil; planner = nil; reviews = nil; history = nil; coach = nil; stuck = nil; gateway = nil; library = nil
            startupError = "Learn Anyway couldn’t open its database: \(error.localizedDescription)\nYour data has not been modified."
        }
    }

    /// BRAINCELL_DATA_DIR redirects all data (used for tests/demos so real data is never touched).
    nonisolated static func defaultStorage() -> ManagedStorage {
        if let d = ProcessInfo.processInfo.environment["BRAINCELL_DATA_DIR"] { return ManagedStorage(root: URL(fileURLWithPath: d, isDirectory: true)) }
        return ManagedStorage(root: ManagedStorage.defaultRoot())
    }

    func reload() {
        courseList = (try? courses?.courses()) ?? []
        revision += 1
    }

    /// Runs a throwing mutation, surfaces failures to the user, and refreshes.
    func perform(_ work: () throws -> Void) {
        do { try work() } catch { alertMessage = error.localizedDescription }
        reload()
    }

    func setAppearance(_ a: AppearanceSetting) {
        appearance = a
        perform { try settings?.set(.appearance, a.rawValue) }
    }

    func dismissOnboarding() {
        onboardingDismissed = true
        perform { try settings?.set(.onboardingDismissed, true) }
    }

    func open(course: Course) {
        selectedCourseID = course.id
        selection = .courses
    }

    // MARK: Backup & restore

    /// The logic behind "Create Backup…" (the menu item only adds the folder picker).
    func performBackup(into dir: URL) throws -> BackupResult {
        guard let db, let storage else { throw BackupError.notABackup }
        return try BackupService(db: db, storage: storage).create(in: dir)
    }

    /// The logic behind "Restore from Backup…" after the learner has confirmed: safety copy, restore, reset UI state.
    @discardableResult
    func performRestore(from dir: URL) throws -> BackupManifest {
        guard let db, let storage else { throw BackupError.notABackup }
        let m = try BackupService(db: db, storage: storage).restore(from: dir, safetyBackupIn: storage.root.appendingPathComponent("Safety Backups", isDirectory: true))
        activeSessionID = nil; selectedCourseID = nil; selection = .home
        reload()
        return m
    }

    func createBackup() {
        guard db != nil, storage != nil else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.canCreateDirectories = true
        panel.prompt = "Save Backup Here"; panel.message = "Choose where to create the backup folder"
        guard panel.runModal() == .OK, let dir = panel.url else { return }
        do {
            let r = try performBackup(into: dir)
            NSWorkspace.shared.activateFileViewerSelecting([r.url])
            let warn = r.manifest.missingFiles.isEmpty ? "" : "\n\n\(r.manifest.missingFiles.count) imported file(s) were missing from storage and could not be included."
            alertMessage = "Backup saved: \(r.url.lastPathComponent)\n\(r.manifest.counts["courses"] ?? 0) course(s), \(r.manifest.counts["questions"] ?? 0) question(s), \(r.manifest.counts["attempts"] ?? 0) answer(s), \(r.manifest.files.count) file(s).\(warn)"
        } catch { alertMessage = error.localizedDescription }
    }

    func restoreBackup() {
        guard db != nil, storage != nil else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true; panel.canChooseFiles = false
        panel.prompt = "Choose Backup"; panel.message = "Choose a Learn Anyway backup folder (.braincellbackup)"
        guard panel.runModal() == .OK, let dir = panel.url else { return }
        do {
            let m = try BackupService.validate(at: dir)          // nothing changes until this passes and you confirm
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "Replace all current data with this backup?"
            alert.informativeText = "Backup from \(m.createdAt.formatted(date: .abbreviated, time: .shortened)): \(m.counts["courses"] ?? 0) course(s), \(m.counts["questions"] ?? 0) question(s), \(m.counts["attempts"] ?? 0) answer(s).\n\nEverything currently in Learn Anyway will be replaced. A safety copy of your current data is saved first (in “Safety Backups” inside Learn Anyway’s data folder)."
            alert.addButton(withTitle: "Cancel"); alert.addButton(withTitle: "Replace My Data")
            alert.buttons[1].hasDestructiveAction = true
            guard alert.runModal() == .alertSecondButtonReturn else { return }
            try performRestore(from: dir)
            alertMessage = "Backup restored."
        } catch { alertMessage = error.localizedDescription }
    }

    /// The only way the app can run learner code: a sandboxed child process, and only after the learner opts in.
    var codeRunner: any CodeRunner { codeExecutionEnabled ? sandboxRunner : UnavailableCodeRunner() }
    /// For the Settings description (works even while execution is switched off).
    var sandboxLanguages: Set<CodeLanguage> { sandboxRunner.languages }
    var sandboxProblem: String? { sandboxRunner.unavailableReason }

    func setCodeExecution(_ on: Bool) { codeExecutionEnabled = on; perform { try settings?.set(.codeExecutionEnabled, on) } }

    /// Direct API requests: opt-in, key in the Keychain, one explicit confirmation per request.
    var directAI: DirectAIService? { ai.flatMap { a in settings.map { DirectAIService(ai: a, settings: $0, secrets: secrets) } } }
    func setDirectAPI(_ on: Bool) { directAPIEnabled = on; perform { try settings?.set(.directAPIEnabled, on) } }
    func setDirectAPIModel(_ m: String) { directAPIModel = m; perform { try settings?.set(.directAPIModel, m.trimmingCharacters(in: .whitespaces)) } }
    func saveAPIKey(_ key: String) {
        let k = key.trimmingCharacters(in: .whitespacesAndNewlines)
        do { if k.isEmpty { try secrets.delete(DirectAIService.keyAccount) } else { try secrets.write(DirectAIService.keyAccount, value: k) }
             hasAPIKey = !k.isEmpty } catch { alertMessage = error.localizedDescription }
    }

    func setCoachEnabled(_ on: Bool) { coachEnabled = on; perform { try settings?.set(.coachEnabled, on) } }
    func setConfidencePrompts(_ v: String) { confidencePrompts = v; perform { try settings?.set(.confidencePrompts, v) } }

    /// Starts a session from (possibly user-edited) plan items; each keeps the reason it was suggested.
    func startPlan(_ items: [PlannedItem], title: String, courseId: UUID, assessmentId: UUID?, mode: SessionMode) {
        perform {
            activeSessionID = try practice?.start(planned: items.map { .init(questionId: $0.questionId, kind: $0.kind, reason: $0.reason) },
                                                  title: title, courseId: courseId, assessmentId: assessmentId, mode: mode).id
        }
    }

    func startReviews(courseId: UUID? = nil) {
        perform {
            let due = try reviews?.due(courseId: courseId) ?? []
            guard !due.isEmpty, let first = due.first else { alertMessage = "No reviews are due right now."; return }
            let items = due.map { PracticeService.PlannedStart(questionId: $0.questionId, kind: .review, reason: "Due for review; predicted recall ≈ \(Int(($0.retrievability * 100).rounded()))%.") }
            activeSessionID = try practice?.start(planned: items, title: "Reviews due", courseId: courseId ?? first.courseId, mode: .review).id
        }
    }

    func setCodeFontSize(_ n: Int) {
        codeFontSize = min(24, max(10, n))
        perform { try settings?.set(.codeFontSize, String(codeFontSize)) }
    }

    /// Starts a session and opens the immersive practice workspace.
    func startPractice(questionIds: [UUID], title: String, courseId: UUID?, assessmentId: UUID? = nil) {
        perform { activeSessionID = try practice?.start(questionIds: questionIds, title: title, courseId: courseId, assessmentId: assessmentId).id }
    }

    func practiceCourse(_ course: Course, assessment: Assessment? = nil) {
        perform {
            let ids = try practice?.questionIds(courseId: course.id, assessmentId: assessment?.id) ?? []
            if ids.isEmpty { alertMessage = "There are no questions for \(assessment?.name ?? course.name) yet. Generate some from AI Tasks, or import a ChatGPT reply." }
            else { activeSessionID = try practice?.start(questionIds: ids, title: assessment.map { "\(course.name) · \($0.name)" } ?? course.name, courseId: course.id, assessmentId: assessment?.id).id }
        }
    }

    func loadDemo() {
        guard let db else { return }
        perform { open(course: try DemoWorkspace.load(into: db)) }
    }

    func startQuickCram(topic: String) {
        perform {
            if let c = try courses?.startQuickCram(topic: topic) { open(course: c) }
        }
    }

    func createCourse(name: String) {
        perform {
            if let c = try courses?.createCourse(name: name) { open(course: c) }
        }
    }

    /// Imports off the main thread; reports a one-line summary or the first error.
    func importFiles(_ urls: [URL], courseId: UUID) {
        guard let documents else { return }
        Task {
            var imported = 0, duplicates = 0, errors: [String] = []
            for url in urls {
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                do {
                    let r = try await Task.detached { try documents.importFile(at: url, courseId: courseId) }.value
                    if r.wasDuplicate { duplicates += 1 } else { imported += 1 }
                } catch { errors.append("\(url.lastPathComponent): \(error.localizedDescription)") }
            }
            if !errors.isEmpty { alertMessage = errors.joined(separator: "\n") }
            else if duplicates > 0 && imported == 0 { alertMessage = "Already imported — nothing changed." }
            reload()
        }
    }
}

struct GenerateRequest: Identifiable {
    let id = UUID()
    var courseId: UUID?
    var skillIds: [UUID] = []
    var notes = ""
}

extension AppModel {
    /// Real completion state for the Getting-started checklist.
    struct OnboardingState { var course = false, material = false, questions = false, session = false, progress = false }

    var onboarding: OnboardingState {
        _ = revision
        guard let db else { return OnboardingState() }
        let c = (try? db.read { d -> (Int, Int, Int) in
            (try Int.fetchOne(d, sql: "SELECT (SELECT COUNT(*) FROM documents) + (SELECT COUNT(*) FROM course_skills cs JOIN courses c ON c.id = cs.courseId WHERE c.kind = 'structured')") ?? 0,
             try Int.fetchOne(d, sql: "SELECT COUNT(*) FROM questions") ?? 0, try Int.fetchOne(d, sql: "SELECT COUNT(*) FROM attempts") ?? 0)
        }) ?? (0, 0, 0)
        return OnboardingState(course: !courseList.isEmpty, material: c.0 > 0, questions: c.1 > 0, session: c.2 > 0, progress: (try? settings?.bool(.viewedProgress)) ?? false)
    }
}

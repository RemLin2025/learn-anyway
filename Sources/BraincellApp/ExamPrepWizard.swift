import SwiftUI
import BraincellCore

struct PrepRequest: Identifiable { let id = UUID(); var courseId: UUID?; var assessmentName: String? }

enum PrepStep: String, CaseIterable, Identifiable {
    case course, materials, analyze, review, template, configure, create
    var id: String { rawValue }
    var title: String { ["Course", "Materials", "Analyze", "Study map", "Template", "Practice", "Create"][Self.allCases.firstIndex(of: self)!] }
}

/// Drives `ExamPrepCoordinator`. Every choice is saved on the job as it is made, so closing the window or quitting resumes at the same step.
@MainActor
final class ExamPrepModel: ObservableObject {
    let app: AppModel
    let co: ExamPrepCoordinator
    @Published var step: PrepStep = .course
    @Published var courseId: UUID?
    @Published var assessmentName = ""
    @Published var job: StudyPrepJob?
    @Published var materials: ExamPrepCoordinator.Materials?
    @Published var map: StudyMapDocument?
    @Published var excluded: Set<String> = []
    @Published var templates: [LearningTemplate] = []
    @Published var templateId = LearningTemplate.interactive.id
    @Published var count = 10
    @Published var minD = 1
    @Published var maxD = 5
    @Published var types: Set<QuestionType> = []
    @Published var fresh = false
    @Published var plan: ExamPrepCoordinator.Plan?
    @Published var busy = false
    @Published var status = ""
    @Published var error: String?
    @Published var finished = false

    init(app: AppModel, co: ExamPrepCoordinator, request: PrepRequest) {
        self.app = app; self.co = co
        templates = (try? app.templates?.all()) ?? LearningTemplate.builtIns
        courseId = request.courseId ?? app.selectedCourseID ?? app.courseList.first?.id
        assessmentName = request.assessmentName ?? ""
        if request.courseId != nil || request.assessmentName != nil { resumeIfPossible() }
    }

    var course: Course? { app.courseList.first { $0.id == courseId } }
    var assessments: [Assessment] { courseId.flatMap { try? app.courses?.assessments(courseId: $0) } ?? [] }

    /// A known course + assessment with a saved job jumps straight to where it left off.
    func resumeIfPossible() {
        guard let c = course, !assessmentName.trimmed.isEmpty, let j = co.existingJob(courseId: c.id, assessmentName: assessmentName) else { return }
        load(j)
        step = PrepStep(rawValue: j.state.wizardStep ?? "") ?? (j.state.mapId != nil ? .review : .materials)
    }

    private func load(_ j: StudyPrepJob) {
        job = j
        materials = try? co.materials(courseId: j.courseId, job: j)
        map = try? co.studyMap(j)
        excluded = Set(j.state.excludedTopics ?? [])
        if let t = j.state.templateId { templateId = t }
        plan = co.currentPlan(j.id)
        if let p = j.state.params { count = p.count; minD = p.minDifficulty; maxD = p.maxDifficulty; types = Set(p.types) }
    }

    func go(_ s: PrepStep) { step = s; if let j = job { try? co.setStep(j.id, s.rawValue) } }
    func next() { if let i = PrepStep.allCases.firstIndex(of: step), i + 1 < PrepStep.allCases.count { go(PrepStep.allCases[i + 1]) } }
    func back() { if let i = PrepStep.allCases.firstIndex(of: step), i > 0 { go(PrepStep.allCases[i - 1]) } }

    func begin() {
        guard let c = course, !assessmentName.trimmed.isEmpty else { return }
        error = nil
        do { let j = try co.start(course: c, assessmentName: assessmentName.trimmed); load(j); app.reload(); go(.materials) } catch { self.error = error.localizedDescription }
    }

    func analyze() {
        guard let j = job, !busy else { return }
        busy = true; error = nil; status = "Reading your materials…"
        let co = co, id = j.id
        Task {
            do { let done = try await co.analyze(id) { s in Task { @MainActor in self.status = s } }; load(done); if done.status == .paused, let e = done.error { error = e } }
            catch is CancellationError {} catch { self.error = error.localizedDescription }
            busy = false; app.reload()
        }
    }

    func saveReview() {
        guard let j = job else { return }
        try? co.setExcluded(j.id, topics: Array(excluded)); try? co.setTemplate(j.id, templateId: templateId)
    }

    func makePlan() {
        guard let j = job else { return }
        saveReview(); error = nil
        do { plan = try co.plan(j.id, count: count, minDifficulty: minD, maxDifficulty: max(minD, maxD), types: Array(types), fresh: fresh); app.reload() } catch { self.error = error.localizedDescription }
    }

    func generate() {
        guard let j = job, !busy else { return }
        busy = true; error = nil; status = "Generating and validating new questions…"
        let co = co, id = j.id
        Task {
            do {
                let r = try await co.generate(id)
                if r.missing > 0 { error = "\(r.missing) question(s) could not be generated. Your saved work is kept; run it again to retry only those." } else { finished = true }
                if let j = try? co.job(id) { load(j) }
            } catch is CancellationError {} catch { self.error = error.localizedDescription }
            busy = false; app.reload()
        }
    }
}

struct ExamPrepWizard: View {
    @EnvironmentObject var app: AppModel
    @Environment(\.dismiss) private var dismiss
    @StateObject private var m: ExamPrepModel

    init(request: PrepRequest, app: AppModel) {
        _m = StateObject(wrappedValue: ExamPrepModel(app: app, co: ExamPrepCoordinator(app.chat!.ctx), request: request))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.md) {
            HStack { Text("Prepare for an exam").font(Theme.sectionTitle); Spacer(); Button("Close") { dismiss() }.keyboardShortcut(.cancelAction) }
            stepper
            Divider()
            ScrollView { content.frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 4) }
            if let e = m.error { Label(e, systemImage: "exclamationmark.triangle").font(.callout).foregroundStyle(Theme.attention) }
            if m.busy { HStack(spacing: 8) { ProgressView().controlSize(.small); Text(m.status).foregroundStyle(Theme.textSecondary) }.accessibilityElement(children: .combine) }
            Divider()
            footer
        }
        .padding(Theme.Space.xl).frame(minWidth: 720, idealWidth: 780, minHeight: 600, idealHeight: 660).background(Theme.background)
    }

    private var stepper: some View {
        HStack(spacing: 6) {
            ForEach(PrepStep.allCases) { s in
                let reached = PrepStep.allCases.firstIndex(of: s)! <= PrepStep.allCases.firstIndex(of: m.step)!
                HStack(spacing: 4) {
                    Image(systemName: s == m.step ? "circle.inset.filled" : (reached ? "checkmark.circle.fill" : "circle")).foregroundStyle(reached ? Theme.accent : Theme.textSecondary)
                    Text(s.title).font(.caption.weight(s == m.step ? .semibold : .regular)).foregroundStyle(s == m.step ? Color.primary : Theme.textSecondary)
                }.accessibilityElement(children: .combine).accessibilityLabel("\(s.title)\(s == m.step ? ", current step" : "")")
                if s != PrepStep.allCases.last { Rectangle().fill(Theme.border).frame(height: 1).frame(maxWidth: 16) }
            }
        }
    }

    @ViewBuilder private var content: some View {
        switch m.step {
        case .course: courseStep
        case .materials: materialsStep
        case .analyze: analyzeStep
        case .review: reviewStep
        case .template: templateStep
        case .configure: configureStep
        case .create: createStep
        }
    }

    private var courseStep: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Which exam?").font(Theme.cardTitle)
            FilterMenu(title: "Course", selection: $m.courseId, options: app.courseList.map { ($0.id, $0.name) }, allowsAny: false)
            TextField("Assessment, e.g. Midterm 3", text: $m.assessmentName)
            if !m.assessments.isEmpty {
                Text("Existing assessments").font(.caption).foregroundStyle(Theme.textSecondary)
                FlowLayout(spacing: 6, lineSpacing: 6) { ForEach(m.assessments) { a in Button(a.name) { m.assessmentName = a.name }.buttonStyle(.secondary) } }
            }
            Text("A new assessment is created only if the name isn’t already in the course. No date or scope is invented.").font(.caption).foregroundStyle(Theme.textSecondary)
        }
    }

    private var materialsStep: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Course materials").font(Theme.cardTitle)
            if let mat = m.materials {
                if mat.readable.isEmpty { Label("Nothing readable yet. Add notes, slides, a syllabus or past exams (PDF, text) from the course’s Materials tab, then come back.", systemImage: "exclamationmark.triangle").foregroundStyle(Theme.attention) }
                ForEach(mat.readable) { d in Label(d.name, systemImage: "doc.text").lineLimit(1) }
                if !mat.gaps.isEmpty { Text("Not fully readable: " + mat.gaps.joined(separator: ", ")).font(.callout).foregroundStyle(Theme.attention) }
                if mat.analysisStale { Label("These files changed since the last analysis, so it will be redone.", systemImage: "arrow.triangle.2.circlepath").font(.callout).foregroundStyle(Theme.textSecondary) }
                Text("Text is already extracted and saved; nothing is re-read unless a file changed.").font(.caption).foregroundStyle(Theme.textSecondary)
            }
        }
    }

    private var analyzeStep: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Analyze topics").font(Theme.cardTitle)
            if let j = m.job, j.state.mapId != nil, m.map != nil, m.materials?.analysisStale != true {
                Label("Study map ready: \(m.map?.topics.count ?? 0) topics. Reused from earlier; no model call is made.", systemImage: "checkmark.circle.fill").foregroundStyle(Theme.mastery)
                Button("Re-analyze anyway") { m.analyze() }.buttonStyle(.secondary).disabled(m.busy)
            } else {
                Text("One model call reads your materials and proposes topics with the evidence for each. Nothing is generated yet.").foregroundStyle(Theme.textSecondary)
                Button { m.analyze() } label: { Label(m.error == nil ? "Analyze materials" : "Retry analysis", systemImage: "sparkles") }.buttonStyle(.primary).disabled(m.busy)
            }
        }
    }

    private var reviewStep: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Review the study map").font(Theme.cardTitle)
            Text("Switch off topics you don’t want practised. Importance is an estimate from your materials unless a topic says instructor-stated.").font(.callout).foregroundStyle(Theme.textSecondary)
            if let map = m.map {
                ForEach(map.topics) { t in
                    Toggle(isOn: Binding(get: { !m.excluded.contains(t.name) }, set: { on in if on { m.excluded.remove(t.name) } else { m.excluded.insert(t.name) }; m.saveReview() })) {
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 6) { Text(t.name).font(.callout.weight(.medium)); Badge(text: importance(t), color: t.importance.source == .instructor ? Theme.mastery : Theme.textSecondary)
                                if !t.sourced { Badge(text: "No source found", color: Theme.attention) } }
                            if !t.importance.evidence.isEmpty { Text("“\(t.importance.evidence)”").font(.caption).foregroundStyle(Theme.textSecondary).lineLimit(2) }
                            if t.sourced { Text("Sources: " + t.sources.prefix(3).map { "\($0.documentName)\($0.page.map { " p.\($0)" } ?? "")" }.joined(separator: ", ")).font(.caption).foregroundStyle(Theme.textSecondary) }
                        }
                    }.accessibilityElement(children: .combine)
                }
                if !map.warnings.isEmpty { Text(map.warnings.joined(separator: " ")).font(.caption).foregroundStyle(Theme.attention) }
            } else { Text("No study map yet. Go back and analyze.").foregroundStyle(Theme.textSecondary) }
        }
    }

    private func importance(_ t: StudyMapDocument.Topic) -> String {
        switch t.importance.source {
        case .instructor: t.importance.weightPercent.map { "Instructor-stated \(Int($0))%" } ?? "Instructor-stated"
        case .estimated: "Estimated \(t.importance.level)"
        case .unknown: "Importance unknown"
        }
    }

    private var templateStep: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("How should it be presented?").font(Theme.cardTitle)
            Text("Changing the template never regenerates questions.").font(.callout).foregroundStyle(Theme.textSecondary)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 200), spacing: 10, alignment: .top)], spacing: 10) {
                ForEach(m.templates) { t in
                    Button { m.templateId = t.id; m.saveReview() } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            HStack { Text(t.name).font(.callout.weight(.semibold)); Spacer(); if m.templateId == t.id { Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.accent) } }
                            Text(t.description).font(.caption).foregroundStyle(Theme.textSecondary).lineLimit(3)
                            if t.isBuiltIn { Badge(text: "Built-in", color: Theme.mastery) }
                        }.padding(10).frame(maxWidth: .infinity, alignment: .leading)
                        .background(m.templateId == t.id ? Theme.accent.opacity(0.10) : Theme.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.control))
                        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.control).strokeBorder(m.templateId == t.id ? Theme.accent : Theme.border, lineWidth: m.templateId == t.id ? 1.5 : 1)).contentShape(Rectangle())
                    }.buttonStyle(.plain).accessibilityAddTraits(m.templateId == t.id ? .isSelected : [])
                }
            }
        }
    }

    private var configureStep: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Configure practice").font(Theme.cardTitle)
            Stepper("Questions: \(m.count)", value: $m.count, in: 1...60)
            HStack { Stepper("Min difficulty: \(m.minD)", value: $m.minD, in: 1...5); Stepper("Max: \(m.maxD)", value: $m.maxD, in: 1...5) }
            Text("Question types (none selected = any)").font(.caption).foregroundStyle(Theme.textSecondary)
            FlowLayout(spacing: 6, lineSpacing: 6) {
                ForEach(QuestionType.allCases, id: \.self) { q in Toggle(q.label, isOn: Binding(get: { m.types.contains(q) }, set: { if $0 { m.types.insert(q) } else { m.types.remove(q) } })).toggleStyle(.button) }
            }
            Toggle("Fresh questions only (skip ones already practised or in another set)", isOn: $m.fresh)
            Button { m.makePlan() } label: { Label("Check what can be reused", systemImage: "arrow.triangle.branch") }.buttonStyle(.primary)
            if let p = m.plan {
                Label("\(p.reused) saved question\(p.reused == 1 ? "" : "s") will be reused · \(p.missing) to generate", systemImage: p.missing == 0 ? "checkmark.circle.fill" : "sparkles")
                    .foregroundStyle(p.missing == 0 ? Theme.mastery : Theme.accent).font(.callout.weight(.medium))
                Text(p.missing == 0 ? "No model call is needed." : "Only the \(p.missing) missing question\(p.missing == 1 ? "" : "s") will be generated. This needs a configured model.").font(.caption).foregroundStyle(Theme.textSecondary)
            }
        }
    }

    private var createStep: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Create the practice set").font(Theme.cardTitle)
            if let p = m.plan {
                Text("“\(p.set.title)” is saved in your Library and on the course’s Practice tab.").foregroundStyle(Theme.textSecondary)
                if p.missing > 0 && !m.finished { Button { m.generate() } label: { Label("Generate \(p.missing) missing question\(p.missing == 1 ? "" : "s")", systemImage: "sparkles") }.buttonStyle(.primary).disabled(m.busy) }
                else {
                    Label("Ready", systemImage: "checkmark.circle.fill").foregroundStyle(Theme.mastery)
                    HStack {
                        Button { startPractice(p.set) } label: { Label("Start practice", systemImage: "play.fill") }.buttonStyle(.primary)
                        Button("Open on Practice tab") { app.selectedCourseID = p.set.courseId; app.selection = .courses; app.courseTabRequest = "practice"; app.openPracticeSetID = p.set.id; dismiss() }.buttonStyle(.secondary)
                    }
                    Text("New questions are validated and saved as Unverified; they’re generated practice, not the real exam.").font(.caption).foregroundStyle(Theme.textSecondary)
                }
            } else { Text("Go back and choose “Check what can be reused” first.").foregroundStyle(Theme.textSecondary) }
        }
    }

    private func startPractice(_ s: PracticeSet) {
        let t = (try? app.templates?.template(m.templateId)) ?? .interactive
        dismiss(); app.startSetSession(setId: s.id, template: t)
    }

    private var footer: some View {
        HStack {
            Button("Back") { m.back() }.disabled(m.step == .course || m.busy)
            Spacer()
            switch m.step {
            case .course: Button("Continue") { m.begin() }.buttonStyle(.primary).disabled(m.courseId == nil || m.assessmentName.trimmed.isEmpty)
            case .materials: Button("Continue") { m.next() }.buttonStyle(.primary).disabled(m.materials?.readable.isEmpty ?? true)
            case .analyze: Button("Continue") { m.next() }.buttonStyle(.primary).disabled(m.map == nil || m.busy || m.materials?.analysisStale == true)
            case .review: Button("Approve study map") { m.saveReview(); m.next() }.buttonStyle(.primary).disabled(m.map == nil)
            case .template: Button("Continue") { m.saveReview(); m.next() }.buttonStyle(.primary)
            case .configure: Button("Continue") { m.next() }.buttonStyle(.primary).disabled(m.plan == nil)
            case .create: EmptyView()
            }
        }
    }
}

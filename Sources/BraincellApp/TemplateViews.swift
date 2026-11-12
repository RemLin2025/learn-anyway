import SwiftUI
import BraincellCore

/// The Learning Template Library. Every preview is the real renderer applied to sample questions; nothing here is a placeholder.
struct TemplateGalleryView: View {
    @EnvironmentObject var model: AppModel
    let course: Course
    @State private var templates: [LearningTemplate] = []
    @State private var editing: LearningTemplate?
    @State private var showAI = false
    @State private var detail: (PracticeSet, String)?
    @State private var showNew = false

    private let examples = TemplateExamples.questions.map { (UUID(), $0, Optional("Probability")) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.lg) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) { Text("Learning Templates").font(Theme.sectionTitle); Text("How a saved practice set is presented. Switching template never regenerates questions.").font(.callout).foregroundStyle(Theme.textSecondary) }
                    Spacer()
                    Button { showAI = true } label: { Label("Create with AI", systemImage: "sparkles") }.buttonStyle(.secondary)
                }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 340), spacing: Theme.Space.lg, alignment: .top)], alignment: .leading, spacing: Theme.Space.lg) {
                    ForEach(templates) { t in card(t) }
                }
            }.padding(Theme.Space.xl)
        }
        .task(id: model.revision) { reload() }
        .sheet(item: $editing) { t in TemplateEditorSheet(course: course, template: t) { reload() } }
        .sheet(isPresented: $showAI) { AITemplateSheet(course: course) { editing = $0 } }
        .sheet(isPresented: $showNew) { NewPracticeSetSheet(course: course, assessment: nil) { id in showNew = false; detail = (try? model.practiceSets?.practiceSet(id)).map { ($0, "") } } }
        .sheet(item: Binding(get: { detail.map { IdentifiedSet(practiceSet: $0.0, templateId: $0.1) } }, set: { if $0 == nil { detail = nil } })) { PracticeSetDetailSheet(course: course, set: $0.practiceSet, initialTemplateId: $0.templateId.isEmpty ? nil : $0.templateId) }
    }

    private func reload() { templates = (try? model.templates?.all(courseId: course.id)) ?? LearningTemplate.builtIns }

    @ViewBuilder private func card(_ t: LearningTemplate) -> some View {
        let doc = RenderBuilder.build(template: t, title: t.kind == .flashcards ? "Flashcards" : "Sample", questions: examples)
        Card(padding: 16) {
            VStack(alignment: .leading, spacing: 10) {
                HStack { Text(t.name).font(Theme.cardTitle); Badge(text: t.kind.title); if t.isBuiltIn { Badge(text: "Built-in", color: Theme.mastery) } else if t.baseId != nil { Badge(text: "Customized") } }
                Text(t.description).font(.callout).foregroundStyle(Theme.textSecondary)
                RenderDocumentView(doc: doc, limit: t.kind == .flashcards ? 1 : 2).frame(height: 230, alignment: .top).clipped().overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.border))
                    .accessibilityLabel("Preview of \(t.name)")
                FlowLayout(spacing: 4) { ForEach(t.supportedFormats, id: \.self) { Badge(text: $0.replacingOccurrences(of: "_", with: " ")) } }
                Text(customization(t)).font(.caption).foregroundStyle(Theme.textSecondary)
                HStack {
                    Menu {
                        let sets = ((try? model.practiceSets?.sets(courseId: course.id)) ?? []).prefix(10)
                        ForEach(Array(sets)) { s in Button(s.title + " · " + s.createdAt.formatted(date: .abbreviated, time: .omitted)) { detail = (s, t.id) } }
                        if !sets.isEmpty { Divider() }
                        Button("New practice set…") { showNew = true }
                    } label: { Label(t.kind == .examWorksheet ? "Create worksheet" : "Start practice", systemImage: "play.fill") }.menuStyle(.button).fixedSize()
                    Button("Duplicate & customize") { if let d = try? model.templates?.duplicate(t.id) { editing = d } }.buttonStyle(.secondary)
                    if !t.isBuiltIn { Button("Edit") { editing = t }.buttonStyle(.secondary); Button("Delete", role: .destructive) { model.perform { try model.templates?.delete(t.id) }; reload() } }
                }
            }
        }
    }

    private func customization(_ t: LearningTemplate) -> String {
        switch t.kind {
        case .examWorksheet: "Customize: question count, answer space, points, page size, header and instructions, solutions file."
        case .interactive: "Customize: order, difficulty range, hints, question limit."
        case .guided: "Customize: hint levels, feedback timing, difficulty range, order."
        case .flashcards: "Customize: shuffle seed, question limit, formats."
        }
    }
}

struct IdentifiedSet: Identifiable, Equatable {
    let practiceSet: PracticeSet
    let templateId: String
    var id: UUID { practiceSet.id }
}

/// Bounded controls only: every value is clamped to what `LearningTemplate.validate` accepts, and the same validation runs before saving.
struct TemplateEditorSheet: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let course: Course
    @State var template: LearningTemplate
    let saved: () -> Void
    @State private var global = true

    var body: some View {
        let issues = template.validate()
        VStack(alignment: .leading, spacing: Theme.Space.md) {
            Text("Customize Template").font(Theme.sectionTitle)
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Space.md) {
                    TextField("Name", text: $template.name); TextField("Description", text: $template.description, axis: .vertical).lineLimit(1...3)
                    Group {
                        Picker("Page size", selection: $template.layout.pageSize) { ForEach(LearningTemplate.PageSize.allCases, id: \.self) { Text($0.rawValue.capitalized).tag($0) } }
                        Stepper("Font size: \(Int(template.layout.fontSize)) pt", value: $template.layout.fontSize, in: 8...16)
                        Picker("Answer space", selection: $template.layout.answerSpace) { ForEach(LearningTemplate.AnswerSpace.allCases, id: \.self) { Text($0.rawValue.capitalized).tag($0) } }
                        Toggle("Show points", isOn: $template.layout.showPoints); Toggle("Show topics", isOn: $template.layout.showTopics); Toggle("Show source references", isOn: $template.layout.showSourceRefs)
                        TextField("Header", text: $template.layout.header); TextField("Instructions", text: $template.layout.instructions, axis: .vertical).lineLimit(1...4)
                    }
                    Group {
                        Picker("Order", selection: $template.sequencing.order) { ForEach(LearningTemplate.Order.allCases, id: \.self) { Text($0.rawValue).tag($0) } }
                        Stepper("Question limit: \(template.sequencing.maxQuestions == 0 ? "all" : String(template.sequencing.maxQuestions))", value: $template.sequencing.maxQuestions, in: 0...200)
                        Stepper("Min difficulty: \(template.difficulty.min)", value: $template.difficulty.min, in: 1...5); Stepper("Max difficulty: \(template.difficulty.max)", value: $template.difficulty.max, in: 1...5)
                        Picker("Timing", selection: $template.timing.mode) { ForEach(LearningTemplate.TimingMode.allCases, id: \.self) { Text($0.rawValue).tag($0) } }
                        if template.timing.mode != .none { Stepper("Seconds: \(template.timing.seconds)", value: $template.timing.seconds, in: 0...14_400, step: 30) }
                        Toggle("Hints allowed", isOn: $template.hints.allowed); if template.hints.allowed { Stepper("Hint levels: \(template.hints.maxLevels)", value: $template.hints.maxLevels, in: 0...5) }
                        Picker("Feedback", selection: $template.feedback.mode) { ForEach(LearningTemplate.FeedbackMode.allCases, id: \.self) { Text($0.rawValue).tag($0) } }
                        Picker("Show solution", selection: $template.feedback.solution) { ForEach(LearningTemplate.SolutionVisibility.allCases, id: \.self) { Text($0.rawValue).tag($0) } }
                        Picker("Scoring", selection: $template.scoring.mode) { ForEach(LearningTemplate.ScoringMode.allCases, id: \.self) { Text($0.rawValue).tag($0) } }
                        if template.scoring.mode == .points { Stepper("Points per question: \(template.scoring.pointsPerQuestion, specifier: "%.1f")", value: $template.scoring.pointsPerQuestion, in: 0.5...100, step: 0.5) }
                    }
                    Text("Question formats").font(.callout.weight(.semibold))
                    FlowLayout(spacing: 6) { ForEach(QuestionType.allCases, id: \.self) { q in
                        Toggle(q.rawValue.replacingOccurrences(of: "_", with: " "), isOn: Binding(get: { template.supportedFormats.contains(q.rawValue) }, set: { on in template.supportedFormats.removeAll { $0 == q.rawValue }; if on { template.supportedFormats.append(q.rawValue) } })).toggleStyle(.button)
                    } }
                    Toggle("Available in every course", isOn: $global)
                }
            }.frame(maxHeight: 420)
            ForEach(issues, id: \.self) { Text($0).font(.caption).foregroundStyle(Theme.error) }
            HStack { Spacer(); Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save") { model.perform { try model.templates?.save(template, courseId: global ? nil : course.id) }; saved(); dismiss() }.buttonStyle(.primary).keyboardShortcut(.defaultAction).disabled(!issues.isEmpty) }
        }.dialogSurface(width: 560)
    }
}

/// Describe a format in plain language; the model returns a schema-checked draft (data, never code). Capabilities the app doesn't have are listed, not faked.
struct AITemplateSheet: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let course: Course
    let use: (LearningTemplate) -> Void
    @State private var text = ""
    @State private var busy = false
    @State private var draft: TemplateDraft?

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.md) {
            Text("Create a Template with AI").font(Theme.sectionTitle)
            Text("Describe how you want to practise, for example “a 20-minute printable quiz, hardest questions first, with big answer boxes”.").font(.callout).foregroundStyle(Theme.textSecondary)
            TextEditor(text: $text).frame(height: 90).overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.border))
            if busy { HStack { ProgressView().controlSize(.small); Text("Drafting…") } }
            if let d = draft {
                if let t = d.template { Text("Draft: \(t.name) (\(t.kind.title))").font(.callout.weight(.semibold)); Text(t.description).font(.caption) }
                ForEach(d.issues, id: \.self) { Text("Not valid: \($0)").font(.caption).foregroundStyle(Theme.error) }
                ForEach(d.limitations, id: \.self) { Text($0).font(.caption).foregroundStyle(Theme.attention) }
            }
            HStack { Spacer(); Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                if let t = draft?.template { Button("Review & save") { use(t); dismiss() }.buttonStyle(.primary) }
                else { Button("Draft") { run() }.buttonStyle(.primary).disabled(busy || text.trimmed.isEmpty) } }
        }.dialogSurface(width: 480)
    }

    private func run() {
        guard let svc = model.templates, let gw = model.gateway else { return }
        busy = true; let d = text
        Task { do { draft = try await svc.draft(description: d, gateway: gw) } catch { model.alertMessage = error.localizedDescription }; busy = false }
    }
}

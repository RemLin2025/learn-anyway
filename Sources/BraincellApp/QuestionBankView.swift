import GRDB
import SwiftUI
import BraincellCore

struct QuestionBankView: View {
    @EnvironmentObject var model: AppModel
    @State private var filter = QuestionFilter()
    @State private var rows: [QuestionRow] = []
    @State private var selection: Set<UUID> = []
    @State private var detail: QuestionDetail?
    @State private var courses: [Course] = []
    @State private var assessments: [Assessment] = []
    @State private var skills: [Skill] = []
    @State private var views: [SavedView] = []
    @State private var editing: QuestionDetail?
    @State private var tagging = false
    @State private var saveName = ""
    @State private var saving = false

    var body: some View {
        VStack(spacing: 0) {
            filterBar
            HSplitView {
                list.sidePanel().listPaneWidth()
                Group {
                    if selection.count > 1 { bulkPanel }
                    else if let detail { QuestionPreview(detail: detail) { editing = detail }.id(detail.revision.id) }
                    else { EmptyStateView(symbol: "doc.text.magnifyingglass", title: "Select a question", message: "Preview its content, answer and review status here.") }
                }.frame(minWidth: 380)
            }
        }
        .toolbar {
            Button { practiceVisible() } label: { Label(selection.count > 1 ? "Practice \(selection.count)" : "Practice", systemImage: "play.fill") }
                .disabled(rows.isEmpty).help("Practice the selected questions, or everything shown")
        }
        .task(id: model.revision) { load() }
        .onAppear { applyCourseFocus() }
        .onChange(of: model.questionBankCourse) { _, _ in applyCourseFocus() }
        .onChange(of: filter.courseId) { _, _ in filter.assessmentId = nil; filter.skillId = nil }   // hidden filters must not keep applying
        .onChange(of: filter) { _, _ in load() }
        .onChange(of: selection) { _, _ in loadDetail() }
        .sheet(item: $editing) { QuestionEditor(detail: $0) }
        .sheet(isPresented: $tagging) { SkillTagSheet(questionIds: Array(selection), skills: skills) }
        .sheet(isPresented: $saving) { NameSheet(title: "Save View", prompt: "View name", text: $saveName, confirm: "Save") {
            model.perform { try model.questions?.saveView(name: saveName, filter: filter) }; saveName = "" } }
    }

    private var filterBar: some View {
        // Fits without scrolling when there is room (menus inside a scroll view are less reliable); scrolls only on a narrow window.
        ViewThatFits(in: .horizontal) { filterControls; ScrollView(.horizontal, showsIndicators: false) { filterControls } }.controlStrip()
    }

    private var filterControls: some View {
        HStack(spacing: 8) {
            SearchField(prompt: "Search questions", text: $filter.text).frame(width: 200)
            FilterMenu(title: "Course", selection: $filter.courseId, options: courses.map { ($0.id, $0.name) })
            if filter.courseId != nil {          // assessment and skill only mean something inside one course
                FilterMenu(title: "Assessment", selection: $filter.assessmentId, options: assessments.map { ($0.id, $0.name) })
                FilterMenu(title: "Skill", selection: $filter.skillId, options: skills.map { ($0.id, $0.name) })
            }
            FilterMenu(title: "Type", selection: $filter.type, options: QuestionType.allCases.map { ($0, $0.label) })
            FilterMenu(title: "Status", selection: $filter.readiness, options: [Readiness.verified, .unverified, .needsReview].map { ($0, $0.label) })
            Menu {
                Section("Difficulty") {
                    Button("Any") { filter.minDifficulty = nil; filter.maxDifficulty = nil }
                    Button("Easy (1–2)") { filter.minDifficulty = 1; filter.maxDifficulty = 2 }
                    Button("Medium (3)") { filter.minDifficulty = 3; filter.maxDifficulty = 3 }
                    Button("Hard (4–5)") { filter.minDifficulty = 4; filter.maxDifficulty = 5 }
                }
                Picker("Sort", selection: $filter.sort) { ForEach(QuestionFilter.Sort.allCases, id: \.self) { Text($0.rawValue.capitalized).tag($0) } }
                Toggle("Show archived", isOn: $filter.includeArchived)
            } label: { Label("More", systemImage: "slider.horizontal.3") }
            Menu {
                Button("Save Current View…") { saving = true }
                if !views.isEmpty { Divider() }
                ForEach(views) { v in
                    Button(v.name) { filter = QuestionService.filter(from: v) }
                }
                if !views.isEmpty { Menu("Delete View") { ForEach(views) { v in Button(v.name, role: .destructive) { model.perform { try model.questions?.deleteView(v.id) } } } } }
            } label: { Label("Views", systemImage: "bookmark") }
            Spacer()
            Text("\(rows.count) question\(rows.count == 1 ? "" : "s")").foregroundStyle(Theme.textSecondary).font(Theme.meta)
        }
        .padding(Theme.Space.md)
    }

    private var list: some View {
        Group {
            if rows.isEmpty {
                EmptyStateView(symbol: "rectangle.stack",
                               title: model.hasAnyQuestions ? "No questions match" : "No questions yet",
                               message: model.hasAnyQuestions ? "Adjust or clear the filters." :
                                "Generate questions with ChatGPT from AI Tasks (no API key needed), or import a response you already have.",
                               actionTitle: model.hasAnyQuestions ? "Clear Filters" : "Open AI Tasks") {
                    if model.hasAnyQuestions { filter = QuestionFilter() } else { model.selection = .aiTasks }
                }
            } else {
                List(rows, selection: $selection) { r in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(r.title).font(.system(.body, design: .rounded, weight: .medium)).lineLimit(2)
                            HStack(spacing: 4) { Badge(text: r.question.type.label); Badge(text: "D\(r.difficulty)", color: Theme.textSecondary) }
                        }
                        Spacer()
                        Badge(text: r.question.readiness.label, color: r.question.readiness.color)
                    }
                    .tag(r.id)
                    .opacity(r.question.archivedAt == nil ? 1 : 0.5)
                    .accessibilityElement(children: .combine)
                    .contextMenu { menu(for: r) }
                }
            }
        }
    }

    @ViewBuilder private func menu(for r: QuestionRow) -> some View {
        let ids = selection.contains(r.id) ? Array(selection) : [r.id]
        Button("Practice") { model.startPractice(questionIds: ids, title: ids.count == 1 ? r.title : "\(ids.count) selected questions", courseId: r.question.courseId) }
        Button("Edit…") { if let d = try? model.questions?.detail(r.id) { editing = d } }.disabled(ids.count > 1)
        Button("Duplicate") { model.perform { for id in ids { try model.questions?.duplicate(id) } } }
        Button("Generate Similar…") {
            let d = try? model.questions?.detail(r.id)
            model.generateRequest = GenerateRequest(courseId: r.question.courseId, skillIds: d?.skills.map(\.id) ?? [], notes: "Create variations similar to: “\(r.title)”")
        }
        Button("Change Skill Tags…") { selection = Set(ids); loadSkills(for: r.question.courseId); tagging = true }
        Menu("Add to Assessment") {
            let asm = (try? model.courses?.assessments(courseId: r.question.courseId)) ?? []
            if asm.isEmpty { Text("No assessments in this course") }
            ForEach(asm) { a in Button(a.name) { model.perform { try model.questions?.addToAssessment(questionIds: ids, assessmentId: a.id) } } }
        }
        Button("Show Answers in Insights") { model.selectedCourseID = r.question.courseId; model.activeSessionID = nil; model.selection = .insights }
        Divider()
        Button(r.question.archivedAt == nil ? "Archive" : "Unarchive", role: .destructive) {
            model.perform { try model.questions?.setArchived(ids, archived: r.question.archivedAt == nil) }
        }
    }

    private var bulkPanel: some View {
        VStack(spacing: 14) {
            Text("\(selection.count) questions selected").font(Theme.sectionTitle)
            HStack {
                Button("Archive") { model.perform { try model.questions?.setArchived(Array(selection), archived: true) }; selection = [] }
                Button("Change Skill Tags…") {
                    if let first = rows.first(where: { selection.contains($0.id) }) { loadSkills(for: first.question.courseId) }
                    tagging = true
                }
                Menu("Add to Assessment") {
                    let courseIds = Set(rows.filter { selection.contains($0.id) }.map(\.question.courseId))
                    if courseIds.count == 1, let c = courseIds.first {
                        ForEach((try? model.courses?.assessments(courseId: c)) ?? []) { a in
                            Button(a.name) { model.perform { try model.questions?.addToAssessment(questionIds: Array(selection), assessmentId: a.id) } }
                        }
                    } else { Text("Select questions from one course") }
                }
            }
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func applyCourseFocus() {
        guard let c = model.questionBankCourse else { return }
        var f = QuestionFilter(); f.courseId = c; filter = f
        model.questionBankCourse = nil
    }

    private func load() {
        guard let qs = model.questions, let cs = model.courses else { return }
        courses = (try? cs.courses()) ?? []
        if let c = filter.courseId { assessments = (try? cs.assessments(courseId: c)) ?? []; skills = (try? cs.skills(courseId: c)) ?? [] }
        else { assessments = []; skills = []; filter.assessmentId = nil; filter.skillId = nil }
        rows = (try? qs.list(filter)) ?? []
        views = (try? qs.savedViews()) ?? []
        selection = selection.filter { id in rows.contains { $0.id == id } }
        if SnapshotRunner.isActive, selection.isEmpty, let first = rows.first { selection = [first.id] } // screenshot aid
        loadDetail()
    }

    private func practiceVisible() {
        let chosen = rows.filter { selection.contains($0.id) }
        let use = chosen.isEmpty ? rows : chosen
        model.startPractice(questionIds: use.map(\.id), title: chosen.isEmpty ? "Question Bank" : "\(use.count) selected questions", courseId: filter.courseId)
    }

    private func loadDetail() {
        detail = selection.count == 1 ? selection.first.flatMap { try? model.questions?.detail($0) } : nil
    }

    private func loadSkills(for courseId: UUID) { skills = (try? model.courses?.skills(courseId: courseId)) ?? [] }
}

struct SkillTagSheet: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let questionIds: [UUID]
    let skills: [Skill]
    @State private var chosen: Set<UUID> = []
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Change Skill Tags").font(Theme.sectionTitle)
            Text("Replaces the tags on \(questionIds.count) question(s).").font(Theme.meta).foregroundStyle(Theme.textSecondary)
            List(skills) { s in
                Toggle(s.name, isOn: Binding(get: { chosen.contains(s.id) }, set: { if $0 { chosen.insert(s.id) } else { chosen.remove(s.id) } }))
            }.scrollContentBackground(.hidden).background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.control)).frame(height: 220)
            HStack { Spacer(); Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Apply") { model.perform { try model.questions?.setSkills(questionIds: questionIds, skillIds: Array(chosen)) }; dismiss() }.buttonStyle(.primary).keyboardShortcut(.defaultAction) }
        }.dialogSurface(width: 380)
    }
}

extension AppModel {
    var hasAnyQuestions: Bool {
        _ = revision
        return ((try? db?.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM questions") ?? 0 }) ?? 0) > 0
    }
}

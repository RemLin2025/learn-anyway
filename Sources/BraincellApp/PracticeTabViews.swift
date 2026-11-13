import SwiftUI
import BraincellCore

/// A saved practice set with everything the course Practice tab shows, read from saved sets and real attempts.
struct PracticeSetCard: Identifiable {
    var practiceSet: PracticeSet
    var questionCount: Int
    var unfilled: Int
    var templateName: String
    var assessmentName: String?
    var progress: SetProgress
    var id: UUID { practiceSet.id }
}

/// Course → Practice: every saved set for this course, with Start/Resume, editing and the usual actions.
struct CoursePracticeTab: View {
    @EnvironmentObject var model: AppModel
    let course: Course
    enum Filter: String, CaseIterable { case all = "All", notStarted = "Not Started", inProgress = "In Progress", completed = "Completed" }
    @State private var filter: Filter = .all
    @State private var cards: [PracticeSetCard] = []
    @State private var deleted: [PracticeSet] = []
    @State private var showNew = false
    @State private var editing: PracticeSet?
    @State private var detail: PracticeSet?
    @State private var confirmDelete: PracticeSet?
    @State private var showDeleted = false

    private var shown: [PracticeSetCard] {
        cards.filter { c in
            switch filter {
            case .all: true
            case .notStarted: c.progress.state == .notStarted
            case .inProgress: c.progress.state == .inProgress
            case .completed: c.progress.state == .completed
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.md) {
            HStack {
                SegmentedControl(selection: $filter, options: Filter.allCases) { $0.rawValue }
                Spacer()
                if !deleted.isEmpty { Button { showDeleted.toggle() } label: { Label("Recently deleted (\(deleted.count))", systemImage: "trash") }.buttonStyle(.borderless) }
                Button { model.librarySection = .templates; model.selection = .library } label: { Label("Templates", systemImage: "rectangle.3.group") }.buttonStyle(.secondary)
                Button { showNew = true } label: { Label("New Practice Set", systemImage: "plus") }.buttonStyle(.primary)
            }
            if showDeleted {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(deleted) { s in HStack { Text(s.title); Spacer(); Button("Restore") { model.perform { try model.practiceSets?.restore(setId: s.id) }; load() }.buttonStyle(.borderless) } }
                }.padding(10).background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.control))
            }
            if shown.isEmpty {
                EmptyStateView(symbol: "list.bullet.rectangle", title: cards.isEmpty ? "No practice sets yet" : "Nothing in “\(filter.rawValue)”",
                               message: cards.isEmpty ? "Create a set, or add questions to one from the Library. Saved questions are reused; only what’s missing is generated." : "Try another filter.",
                               actionTitle: cards.isEmpty ? "New Practice Set" : "Show All") { if cards.isEmpty { showNew = true } else { filter = .all } }
            } else {
                ScrollView { VStack(spacing: 8) { ForEach(shown) { card($0) } } }
            }
        }
        .padding(Theme.Space.lg)
        .task(id: model.revision) { load() }
        .onChange(of: model.openPracticeSetID) { _, _ in focus() }
        .sheet(isPresented: $showNew) { NewPracticeSetSheet(course: course, assessment: nil) { id in showNew = false; load(); editing = try? model.practiceSets?.practiceSet(id) } }
        .sheet(item: $editing, onDismiss: load) { PracticeSetEditorSheet(course: course, set: $0) }
        .sheet(item: $detail) { PracticeSetDetailSheet(course: course, set: $0) }
        .confirmationDialog("Delete this practice set?", isPresented: Binding(get: { confirmDelete != nil }, set: { if !$0 { confirmDelete = nil } }), titleVisibility: .visible) {
            Button("Delete Set", role: .destructive) { if let s = confirmDelete { model.perform { try model.practiceSets?.delete(setId: s.id) }; load() }; confirmDelete = nil }
            Button("Cancel", role: .cancel) { confirmDelete = nil }
        } message: { Text("The questions and your past attempts are kept. You can restore the set from “Recently deleted”.") }
    }

    private func card(_ c: PracticeSetCard) -> some View {
        let p = c.progress
        return HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) { Text(c.practiceSet.title).font(Theme.cardTitle).lineLimit(1); stateBadge(p) }
                Text(meta(c)).font(.caption).foregroundStyle(Theme.textSecondary).lineLimit(2)
                if p.state != .notStarted, p.total > 0 {
                    HStack(spacing: 8) { MeterBar(value: Double(p.answered) / Double(p.total), tint: Theme.mastery).frame(width: 140); Text("\(p.answered) of \(p.total) answered").font(.caption).foregroundStyle(Theme.textSecondary) }
                        .accessibilityElement(children: .combine)
                }
            }
            Spacer()
            Button { start(c, newAttempt: false) } label: { Label(p.state == .inProgress ? "Resume" : (p.state == .completed ? "Practice again" : "Start"), systemImage: p.state == .inProgress ? "play.circle" : "play.fill") }
                .buttonStyle(.primary).disabled(c.questionCount == 0)
            Button("Edit") { editing = c.practiceSet }.buttonStyle(.secondary)
            Menu {
                Button("Open") { detail = c.practiceSet }
                if p.state == .inProgress { Button("Start a New Attempt") { start(c, newAttempt: true) } }
                Button("Duplicate") { model.perform { try model.practiceSets?.duplicate(setId: c.practiceSet.id) }; load() }
                Divider()
                Button("Delete…", role: .destructive) { confirmDelete = c.practiceSet }
            } label: { Image(systemName: "ellipsis.circle").frame(width: 30, height: 28).contentShape(Rectangle()) }.menuStyle(.borderlessButton).fixedSize().accessibilityLabel("More actions")
        }
        .padding(12).background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.card)).overlay(RoundedRectangle(cornerRadius: Theme.Radius.card).strokeBorder(Theme.border))
    }

    @ViewBuilder private func stateBadge(_ p: SetProgress) -> some View {
        switch p.state {
        case .notStarted: EmptyView()
        case .inProgress: Badge(text: p.stale ? "In progress · set edited" : "In progress", color: Theme.attention)
        case .completed: Badge(text: "Completed", color: Theme.mastery)
        }
    }

    private func meta(_ c: PracticeSetCard) -> String {
        var parts = ["\(c.questionCount) question\(c.questionCount == 1 ? "" : "s")", c.templateName]
        if let a = c.assessmentName { parts.append(a) }
        if c.unfilled > 0 { parts.append("\(c.unfilled) still to generate") }
        parts.append("Last activity " + (c.progress.lastActivity ?? c.practiceSet.updatedAt ?? c.practiceSet.createdAt).formatted(date: .abbreviated, time: .omitted))
        return parts.joined(separator: " · ")
    }

    private func start(_ c: PracticeSetCard, newAttempt: Bool) {
        let t = (try? model.templates?.template(c.progress.templateId ?? c.practiceSet.templateId ?? LearningTemplate.interactive.id)) ?? .interactive
        model.startSetSession(setId: c.practiceSet.id, template: t, newAttempt: newAttempt)
    }

    private func focus() {
        if let id = model.openPracticeSetID, let s = cards.first(where: { $0.id == id })?.practiceSet { detail = s; model.openPracticeSetID = nil }
    }

    private func load() {
        guard let svc = model.practiceSets else { return }
        let asm = (try? model.courses?.assessments(courseId: course.id)) ?? []
        cards = ((try? svc.sets(courseId: course.id)) ?? []).map { s in
            let it = (try? svc.items(setId: s.id)) ?? []
            let tpl = s.templateId.flatMap { try? model.templates?.template($0) }?.name ?? LearningTemplate.interactive.name
            return PracticeSetCard(practiceSet: s, questionCount: it.filter { $0.questionId != nil }.count, unfilled: it.filter { $0.questionId == nil }.count, templateName: tpl,
                                   assessmentName: s.assessmentId.flatMap { id in asm.first { $0.id == id }?.name }, progress: (try? svc.progress(setId: s.id)) ?? .none)
        }
        deleted = (try? svc.deletedSets(courseId: course.id)) ?? []
        focus()
    }
}

/// Edit what is in a set and how it is presented. Questions are references: adding one never copies it, and removing one never deletes it.
struct PracticeSetEditorSheet: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let course: Course
    let set: PracticeSet
    @State private var title = ""
    @State private var desc = ""
    @State private var templateId = LearningTemplate.interactive.id
    @State private var templates: [LearningTemplate] = []
    @State private var rows: [Row] = []
    @State private var adding = false
    @State private var notice: String?

    struct Row: Identifiable { var id: String; var slotId: String; var questionId: UUID?; var title: String; var detail: String }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.md) {
            HStack { Text("Edit Practice Set").font(Theme.sectionTitle); Spacer(); Button("Done") { save(); dismiss() }.keyboardShortcut(.defaultAction) }
            TextField("Name", text: $title)
            TextField("Description (optional)", text: $desc, axis: .vertical).lineLimit(1...3)
            FilterMenu(title: "Template", selection: Binding(get: { Optional(templateId) }, set: { templateId = $0 ?? templateId }), options: templates.map { ($0.id, $0.name) }, allowsAny: false)
            HStack {
                Text("Questions (\(rows.filter { $0.questionId != nil }.count))").font(.callout.weight(.semibold))
                Spacer()
                Button { adding = true } label: { Label("Add from Library…", systemImage: "plus") }.buttonStyle(.secondary)
            }
            if let n = notice { Text(n).font(.caption).foregroundStyle(Theme.attention) }
            if rows.isEmpty { Text("No questions yet. Add saved questions from any course.").foregroundStyle(Theme.textSecondary).frame(maxWidth: .infinity, minHeight: 120) }
            else {
                List {
                    ForEach(rows) { r in
                        HStack {
                            Image(systemName: "line.3.horizontal").foregroundStyle(Theme.textSecondary).accessibilityHidden(true)
                            VStack(alignment: .leading, spacing: 1) { Text(r.title).lineLimit(2); Text(r.detail).font(.caption).foregroundStyle(Theme.textSecondary) }
                            Spacer()
                            if let q = r.questionId { Button { remove(q) } label: { Image(systemName: "minus.circle") }.buttonStyle(.borderless).accessibilityLabel("Remove \(r.title)") }
                        }
                    }.onMove(perform: move)
                }.frame(minHeight: 220)
            }
            Text("Editing a set never changes an attempt that’s already started or finished. Resume continues the old attempt; “Start a New Attempt” uses the current questions.").font(.caption).foregroundStyle(Theme.textSecondary)
        }
        .dialogSurface(width: 620)
        .onAppear { title = set.title; desc = set.description ?? ""; templateId = set.templateId ?? LearningTemplate.interactive.id; templates = (try? model.templates?.all(courseId: course.id)) ?? LearningTemplate.builtIns; reload() }
        .sheet(isPresented: $adding) { AddQuestionsSheet(set: set, currentCourse: course) { reload() } }
    }

    private func save() { model.perform { try model.practiceSets?.update(setId: set.id, title: title, description: desc, templateId: templateId) } }

    private func reload() {
        guard let svc = model.practiceSets else { return }
        let qs = Dictionary(uniqueKeysWithValues: ((try? svc.questions(setId: set.id)) ?? []).map { ($0.id, $0) })
        rows = ((try? svc.items(setId: set.id)) ?? []).map { i in
            if let q = i.questionId, let s = qs[q] { return Row(id: i.slot.id, slotId: i.slot.id, questionId: q, title: s.spec.title, detail: s.spec.type.label + " · difficulty \(s.spec.difficulty)") }
            return Row(id: i.slot.id, slotId: i.slot.id, questionId: nil, title: "Not generated yet", detail: i.slot.topic)
        }
        model.reload()
    }
    private func remove(_ q: UUID) { do { try model.practiceSets?.remove(questionId: q, from: set.id) } catch { notice = error.localizedDescription }; reload() }
    private func move(_ from: IndexSet, _ to: Int) {
        var order = rows.map(\.slotId); order.move(fromOffsets: from, toOffset: to)
        do { try model.practiceSets?.reorder(setId: set.id, slotOrder: order) } catch { notice = error.localizedDescription }
        reload()
    }
}

/// Pick saved questions from the whole Library. The course each came from is always shown; ones already in the set are marked and can’t be added twice.
struct AddQuestionsSheet: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let set: PracticeSet
    let currentCourse: Course
    let added: () -> Void
    @State private var filter = QuestionFilter()
    @State private var rows: [QuestionRow] = []
    @State private var inSet: Set<UUID> = []
    @State private var chosen: Set<UUID> = []
    @State private var courses: [Course] = []

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.md) {
            Text("Add Questions").font(Theme.sectionTitle)
            HStack {
                SearchField(prompt: "Search questions", text: $filter.text)
                FilterMenu(title: "Course", selection: $filter.courseId, options: courses.map { ($0.id, $0.name) })
                FilterMenu(title: "Type", selection: $filter.type, options: QuestionType.allCases.map { ($0, $0.label) })
            }
            List(rows) { r in
                let already = inSet.contains(r.id)
                Toggle(isOn: Binding(get: { chosen.contains(r.id) }, set: { if $0 { chosen.insert(r.id) } else { chosen.remove(r.id) } })) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(r.title).lineLimit(2)
                        Text([r.question.type.label, "D\(r.difficulty)", courses.first { $0.id == r.question.courseId }?.name, already ? "Already in this set" : nil].compactMap { $0 }.joined(separator: " · ")).font(.caption).foregroundStyle(Theme.textSecondary)
                    }
                }.disabled(already).accessibilityElement(children: .combine)
            }.frame(minHeight: 260)
            HStack { Text("\(chosen.count) selected").foregroundStyle(Theme.textSecondary); Spacer(); Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Add") { add() }.buttonStyle(.primary).disabled(chosen.isEmpty) }
        }
        .dialogSurface(width: 620)
        .task(id: "\(filter.text)|\(filter.courseId?.uuidString ?? "")|\(filter.type?.rawValue ?? "")") { load() }
    }

    private func load() {
        courses = (try? model.courses?.courses()) ?? []
        rows = (try? model.questions?.list(filter)) ?? []
        inSet = Set(((try? model.practiceSets?.items(setId: set.id)) ?? []).compactMap(\.questionId))
    }
    private func add() {
        let order = rows.map(\.id).filter(chosen.contains)
        do { for q in order { try model.practiceSets?.add(questionId: q, to: set.id) } } catch { model.alertMessage = error.localizedDescription }
        model.reload(); added(); dismiss()
    }
}

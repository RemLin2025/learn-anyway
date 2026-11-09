import SwiftUI
import UniformTypeIdentifiers
import BraincellCore

struct CoursesView: View {
    @EnvironmentObject var model: AppModel
    @State private var showNew = false
    @State private var newName = ""

    var body: some View {
        HSplitView {
            List(selection: $model.selectedCourseID) {
                ForEach(model.courseList) { c in
                    Label(c.name, systemImage: c.kind == .quickCram ? "bolt" : "graduationcap").tag(c.id)
                        .contextMenu { Button("Archive") { model.perform { try model.courses?.archiveCourse(c.id) } } }
                }
            }
            .frame(minWidth: 190, idealWidth: 220, maxWidth: 300)
            .overlay { if model.courseList.isEmpty { Text("No courses yet").foregroundStyle(.secondary) } }

            Group {
                if let id = model.selectedCourseID, let course = model.courseList.first(where: { $0.id == id }) {
                    CourseDetailView(course: course).id(course.id)
                } else if model.courseList.isEmpty {
                    EmptyStateView(symbol: "graduationcap", title: "No courses yet",
                                   message: "Create a course for an exam, or start a Quick Cram on a single topic.",
                                   actionTitle: "New Course") { showNew = true }
                } else {
                    EmptyStateView(symbol: "sidebar.left", title: "Select a course", message: "Choose a course to manage its assessments, topics and materials.")
                }
            }
            .frame(minWidth: 520)
        }
        .toolbar { Button { showNew = true } label: { Label("New Course", systemImage: "plus") }.keyboardShortcut("n") }
        .sheet(isPresented: $showNew) {
            NameSheet(title: "New Course", prompt: "Course name", text: $newName, confirm: "Create") {
                model.createCourse(name: newName); newName = ""
            }
        }
    }
}

struct NameSheet: View {
    @Environment(\.dismiss) private var dismiss
    let title: String; let prompt: String
    @Binding var text: String
    let confirm: String
    let action: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title).font(.headline)
            TextField(prompt, text: $text).onSubmit(go).frame(width: 300).accessibilityLabel(prompt)
            HStack { Spacer(); Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(confirm, action: go).keyboardShortcut(.defaultAction).disabled(text.trimmed.isEmpty) }
        }.padding(20)
    }
    private func go() { guard !text.trimmed.isEmpty else { return }; action(); dismiss() }
}

struct CourseDetailView: View {
    enum Tab: String, CaseIterable { case assessments = "Assessments", topics = "Topics", materials = "Materials", plan = "Plan" }

    @EnvironmentObject var model: AppModel
    let course: Course
    @State private var tab: Tab = .assessments
    @State private var convertName = ""
    @State private var showConvert = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text(course.name).font(.title.weight(.semibold))
                    if course.kind == .quickCram { Badge(text: "Quick Cram", color: Theme.attention) }
                    if let x = try? model.progression?.courseXP(course.id), x.xp > 0 { Badge(text: "Level \(x.level) · \(x.xp) XP") }
                    Spacer()
                    Button { model.practiceCourse(course) } label: { Label("Practice", systemImage: "play.fill") }
                        .buttonStyle(.primary)
                    if course.kind == .quickCram { Button("Convert to Course…") { convertName = course.name; showConvert = true } }
                }
                Picker("Section", selection: $tab) { ForEach(Tab.allCases, id: \.self) { Text($0.rawValue).tag($0) } }
                    .pickerStyle(.segmented).labelsHidden().frame(maxWidth: 440)
            }
            .padding([.horizontal, .top], 20).padding(.bottom, 12)
            Divider()
            Group {
                switch tab {
                case .assessments: AssessmentsTab(course: course)
                case .topics: TopicsTab(course: course)
                case .materials: MaterialsTab(course: course)
                case .plan: StudyPlanTab(course: course)
                }
            }
        }
        .onAppear { if model.requestedCourseTab == "plan" || SnapshotRunner.isActive && model.requestedCourseTab != nil { tab = .plan } }
        .onChange(of: model.requestedCourseTab) { _, t in if t == "plan" { tab = .plan } }
        .sheet(isPresented: $showConvert) {
            NameSheet(title: "Convert to Course", prompt: "Course name", text: $convertName, confirm: "Convert") {
                model.perform { try model.courses?.convertToCourse(course.id, name: convertName) }
            }
        }
    }
}

// MARK: Assessments

struct AssessmentsTab: View {
    @EnvironmentObject var model: AppModel
    let course: Course
    @State private var assessments: [Assessment] = []
    @State private var skills: [Skill] = []
    @State private var scope: Set<UUID> = []
    @State private var selected: UUID?
    @State private var editing: Assessment?
    @State private var adding = false

    var body: some View {
        HSplitView {
            VStack(alignment: .leading) {
                if assessments.isEmpty {
                    EmptyStateView(symbol: "calendar.badge.plus", title: "No assessments",
                                   message: "Add a midterm, quiz or final. Mark a final as cumulative to cover the whole course.",
                                   actionTitle: "Add Assessment") { adding = true }
                } else {
                    List(selection: $selected) {
                        ForEach(assessments) { a in
                            VStack(alignment: .leading, spacing: 3) {
                                HStack { Text(a.name).font(.headline)
                                    if a.isCumulative { Badge(text: "Cumulative", color: Theme.mastery) } }
                                if let d = a.deadline { Text("Due \(d.formatted(date: .abbreviated, time: .omitted))").font(.caption).foregroundStyle(.secondary) }
                            }.tag(a.id)
                            .contextMenu {
                                Button("Edit…") { editing = a }
                                Button("Delete", role: .destructive) { model.perform { try model.courses?.deleteAssessment(a.id) } }
                            }
                        }
                    }
                    Button { adding = true } label: { Label("Add Assessment", systemImage: "plus") }.padding(8)
                }
            }
            .frame(minWidth: 240, idealWidth: 280, maxWidth: 360)

            Group {
                if let a = assessments.first(where: { $0.id == selected }) { scopeEditor(a) }
                else { EmptyStateView(symbol: "checklist", title: "Select an assessment", message: "Choose which topics it covers.") }
            }.frame(minWidth: 260)
        }
        .task(id: model.revision) { load() }
        .onChange(of: selected) { _, _ in load() }
        .sheet(isPresented: $adding) { AssessmentSheet(course: course, existing: nil) }
        .sheet(item: $editing) { AssessmentSheet(course: course, existing: $0) }
    }

    @ViewBuilder private func scopeEditor(_ a: Assessment) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Coverage for \(a.name)").font(.headline)
                Spacer()
                Button { model.practiceCourse(course, assessment: a) } label: { Label("Practice \(a.name)", systemImage: "play.fill") }
            }
            if a.isCumulative {
                Text("Cumulative: covers every topic in this course, including ones you add later.").font(.callout).foregroundStyle(.secondary)
            } else if skills.isEmpty {
                Text("Add topics in the Topics tab first.").foregroundStyle(.secondary)
            }
            List(skills) { s in
                Toggle(s.name, isOn: Binding(
                    get: { a.isCumulative || scope.contains(s.id) },
                    set: { on in model.perform {
                        if on { try model.courses?.addToScope(assessmentId: a.id, skillId: s.id) }
                        else { try model.courses?.removeFromScope(assessmentId: a.id, skillId: s.id) } } }))
                .disabled(a.isCumulative)
            }
        }.padding(16)
    }

    private func load() {
        guard let c = model.courses else { return }
        assessments = (try? c.assessments(courseId: course.id)) ?? []
        skills = (try? c.skills(courseId: course.id)) ?? []
        if let s = selected, assessments.contains(where: { $0.id == s }) {
            scope = Set(((try? c.scopedSkills(assessmentId: s)) ?? []).map(\.id))
        } else { selected = nil; scope = [] }
    }
}

struct AssessmentSheet: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let course: Course
    let existing: Assessment?
    @State private var name = ""
    @State private var kind: AssessmentKind = .midterm
    @State private var hasDeadline = false
    @State private var deadline = Date()
    @State private var cumulative = false

    var body: some View {
        Form {
            TextField("Name", text: $name)
            Picker("Type", selection: $kind) { ForEach(AssessmentKind.allCases, id: \.self) { Text($0.rawValue.capitalized).tag($0) } }
            Toggle("Has a deadline", isOn: $hasDeadline)
            if hasDeadline { DatePicker("Deadline", selection: $deadline) }
            Toggle("Cumulative (covers the whole course)", isOn: $cumulative)
            HStack { Spacer(); Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(existing == nil ? "Add" : "Save", action: save).keyboardShortcut(.defaultAction).disabled(name.trimmed.isEmpty) }
        }
        .formStyle(.grouped).frame(width: 420).padding(.vertical, 8)
        .onAppear {
            guard let e = existing else { return }
            name = e.name; kind = e.kind; hasDeadline = e.deadline != nil; deadline = e.deadline ?? Date(); cumulative = e.isCumulative
        }
    }

    private func save() {
        model.perform {
            if var e = existing {
                e.name = name; e.kind = kind; e.deadline = hasDeadline ? deadline : nil; e.isCumulative = cumulative
                try model.courses?.updateAssessment(e)
            } else {
                try model.courses?.addAssessment(courseId: course.id, name: name, kind: kind,
                                                 deadline: hasDeadline ? deadline : nil, isCumulative: cumulative)
            }
        }
        dismiss()
    }
}

// MARK: Topics

struct TopicsTab: View {
    @EnvironmentObject var model: AppModel
    let course: Course
    @State private var rows: [SkillTree.Row] = []
    @State private var relations: [SkillRelation] = []
    @State private var name = ""
    @State private var parent: UUID?
    @State private var renaming: Skill?
    @State private var renameText = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                TextField("Add a topic", text: $name).onSubmit(add).accessibilityLabel("New topic name")
                Picker("Under", selection: $parent) {
                    Text("Top level").tag(UUID?.none)
                    ForEach(rows, id: \.skill.id) { Text($0.skill.name).tag(UUID?.some($0.skill.id)) }
                }.frame(maxWidth: 220)
                Button("Add", action: add).disabled(name.trimmed.isEmpty)
            }.padding([.horizontal, .top], 16)
            if rows.isEmpty {
                EmptyStateView(symbol: "list.bullet.indent", title: "No topics yet",
                               message: "Enter the topics this course covers. Adding a name that already exists in this course reuses it rather than duplicating it.")
            } else {
                List(rows, id: \.skill.id) { r in
                    HStack {
                        Text(r.skill.name).padding(.leading, CGFloat(r.depth) * 18)
                        Spacer()
                        let prereqs = prerequisiteNames(for: r.skill)
                        if !prereqs.isEmpty { Badge(text: "needs " + prereqs.joined(separator: ", "), color: Theme.attention) }
                        Badge(text: "Not assessed", color: .secondary)
                    }
                    .contextMenu {
                        Button("Rename…") { renaming = r.skill; renameText = r.skill.name }
                        Menu("Add Prerequisite") {
                            ForEach(rows.filter { $0.skill.id != r.skill.id }, id: \.skill.id) { p in
                                Button(p.skill.name) { model.perform { try model.courses?.addRelation(from: p.skill.id, to: r.skill.id, kind: .prerequisite) } }
                            }
                        }
                        Button("Archive", role: .destructive) { model.perform { try model.courses?.archiveSkill(r.skill.id) } }
                    }
                }
            }
        }
        .task(id: model.revision) { load() }
        .sheet(item: $renaming) { s in
            NameSheet(title: "Rename Topic", prompt: "Name", text: $renameText, confirm: "Rename") {
                model.perform { try model.courses?.renameSkill(s.id, to: renameText) }
            }
        }
    }

    private func prerequisiteNames(for s: Skill) -> [String] {
        let byId = Dictionary(uniqueKeysWithValues: rows.map { ($0.skill.id, $0.skill.name) })
        return relations.filter { $0.kind == .prerequisite && $0.toSkillId == s.id }.compactMap { byId[$0.fromSkillId] }
    }

    private func add() {
        guard !name.trimmed.isEmpty else { return }
        model.perform { try model.courses?.addSkill(courseId: course.id, name: name, parentId: parent) }
        name = ""
    }

    private func load() {
        guard let c = model.courses else { return }
        let skills = (try? c.skills(courseId: course.id)) ?? []
        relations = (try? c.relations(courseId: course.id)) ?? []
        rows = SkillTree.flatten(skills, relations: relations)
    }
}

// MARK: Materials

struct MaterialsTab: View {
    @EnvironmentObject var model: AppModel
    let course: Course
    @State private var docs: [Document] = []
    @State private var picking = false
    @State private var pasting = false
    @State private var pasteTitle = ""
    @State private var pasteText = ""
    @State private var targeted = false

    private static let types: [UTType] = [.pdf, .plainText, UTType(filenameExtension: "md") ?? .plainText]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Button { picking = true } label: { Label("Import Files…", systemImage: "square.and.arrow.down") }
                Button { pasting = true } label: { Label("Paste Notes…", systemImage: "doc.on.clipboard") }
                Spacer()
                Text("PDF, text and Markdown. Scanned PDFs are flagged; OCR isn’t available yet.").font(.caption).foregroundStyle(.secondary)
            }.padding(16)
            if docs.isEmpty {
                EmptyStateView(symbol: "doc.badge.plus", title: "No materials",
                               message: "Drop PDFs or text files here, or paste notes. Originals are copied into Braincell’s managed storage.")
            } else {
                List(docs) { d in
                    HStack(alignment: .top) {
                        Image(systemName: d.kind == .pdf ? "doc.richtext" : "doc.text").foregroundStyle(Theme.accent)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(d.title).font(.headline)
                            Text(detail(d)).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        switch d.extractionStatus {
                        case .ok: Badge(text: "Text extracted", color: Theme.mastery)
                        case .partial: Badge(text: "\(d.lowContentPageCount) low-content page(s)", color: Theme.attention)
                        case .failed: Badge(text: "No text found", color: Theme.attention)
                        }
                    }.accessibilityElement(children: .combine)
                }
            }
        }
        .overlay { if targeted { RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.accent, style: StrokeStyle(lineWidth: 2, dash: [6])).padding(6) } }
        .dropDestination(for: URL.self, action: { urls, _ in model.importFiles(urls, courseId: course.id); return true }, isTargeted: { targeted = $0 })
        .fileImporter(isPresented: $picking, allowedContentTypes: Self.types, allowsMultipleSelection: true) { result in
            if case .success(let urls) = result { model.importFiles(urls, courseId: course.id) }
        }
        .sheet(isPresented: $pasting) {
            VStack(alignment: .leading, spacing: 10) {
                Text("Paste Notes").font(.headline)
                TextField("Title (optional)", text: $pasteTitle).accessibilityLabel("Title for pasted notes")
                TextEditor(text: $pasteText).font(.body).frame(minHeight: 220).border(Color.secondary.opacity(0.3))
                HStack { Spacer(); Button("Cancel") { pasting = false }.keyboardShortcut(.cancelAction)
                    Button("Import") { importPasted() }.keyboardShortcut(.defaultAction).disabled(pasteText.trimmed.isEmpty) }
            }.padding(20).frame(width: 520)
        }
        .task(id: model.revision) { docs = (try? model.documents?.documents(courseId: course.id)) ?? [] }
    }

    private func detail(_ d: Document) -> String {
        var parts = [d.originalFilename, ByteCountFormatter.string(fromByteCount: Int64(d.byteCount), countStyle: .file)]
        if let p = d.pageCount { parts.append("\(p) pages") }
        return parts.joined(separator: " · ")
    }

    private func importPasted() {
        model.perform { _ = try model.documents?.importPasted(text: pasteText, title: pasteTitle, courseId: course.id) }
        pasteText = ""; pasteTitle = ""; pasting = false
    }
}

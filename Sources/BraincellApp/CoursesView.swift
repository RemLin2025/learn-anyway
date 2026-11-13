import SwiftUI
import UniformTypeIdentifiers
import BraincellCore

struct CoursesView: View {
    @EnvironmentObject var model: AppModel
    @State private var showNew = false
    @State private var newName = ""
    @State private var renaming: Course?
    @State private var renameText = ""
    @State private var showDeleted = false

    var body: some View {
        HSplitView {
            List(selection: $model.selectedCourseID) {
                ForEach(model.courseList) { c in
                    ListRowLabel(title: c.name, symbol: c.kind == .quickCram ? "bolt.fill" : "graduationcap.fill", tint: c.kind == .quickCram ? Theme.attention : Theme.accent).tag(c.id)
                        .contextMenu {
                            Button("Rename…") { renameText = c.name; renaming = c }
                            Button("Delete…", role: .destructive) { model.askDeleteCourse = c.id }
                        }
                }
            }
            .sidePanel()
            .frame(minWidth: 200, idealWidth: 240, maxWidth: 300)   // course picker; narrower than a list pane because a second list sits beside it
            .overlay { if model.courseList.isEmpty { Text("No courses yet").foregroundStyle(Theme.textSecondary) } }

            Group {
                if let id = model.selectedCourseID, let course = model.courseList.first(where: { $0.id == id }) {
                    CourseDetailView(course: course).id(course.id)
                } else if model.courseList.isEmpty {
                    EmptyStateView(symbol: "graduationcap", title: "No courses yet",
                                   message: "Create a course for an exam, or start a Quick Cram on a single topic.",
                                   actionTitle: "New Course") { showNew = true }
                } else {
                    CourseCardGrid(onNew: { showNew = true })
                }
            }
            .frame(minWidth: 520)
        }
        .toolbar {
            Button { showDeleted = true } label: { Label("Recently Deleted", systemImage: "trash") }.help("Courses, folders and files you deleted in the last seven days")
            Button { showNew = true } label: { Label("New Course", systemImage: "plus") }.keyboardShortcut("n")
        }
        .sheet(item: $renaming) { c in NameSheet(title: "Rename Course", prompt: "Course name", text: $renameText, confirm: "Rename") { model.perform { try model.courses?.renameCourse(c.id, to: renameText) } } }
        .sheet(isPresented: $showDeleted) { DeletedSheet() }
        .onChange(of: model.snapshotShowDeleted) { _, on in if on { showDeleted = true } }
        .modifier(DeleteCourseDialog())
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
        VStack(alignment: .leading, spacing: Theme.Space.lg) {
            Text(title).font(Theme.sectionTitle)
            TextField(prompt, text: $text).onSubmit(go).accessibilityLabel(prompt)
            HStack { Spacer(); Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(confirm, action: go).buttonStyle(.primary).keyboardShortcut(.defaultAction).disabled(text.trimmed.isEmpty) }
        }.dialogSurface(width: 380)
    }
    private func go() { guard !text.trimmed.isEmpty else { return }; action(); dismiss() }
}

struct CourseDetailView: View {
    enum Tab: String, CaseIterable { case assessments = "Assessments", topics = "Topics", materials = "Materials", practice = "Practice" }

    @EnvironmentObject var model: AppModel
    let course: Course
    @State private var tab: Tab = .assessments
    @State private var convertName = ""
    @State private var showConvert = false
    @State private var showRename = false
    @State private var renameText = ""

    private var titleBlock: some View {
        HStack(spacing: Theme.Space.sm) {
            Text(course.name).font(Theme.pageTitle).lineLimit(1)
            if course.kind == .quickCram { Badge(text: "Quick Cram", color: Theme.attention) }
            if let x = try? model.progression?.courseXP(course.id), x.xp > 0 { Badge(text: "Level \(x.level) · \(x.xp) XP") }
        }
    }
    private var tabs: some View { SegmentedControl(selection: $tab, options: Tab.allCases) { $0.rawValue } }
    private var actions: some View {
        HStack(spacing: Theme.Space.md) {
            Button { model.practiceCourse(course) } label: { Label("Practice", systemImage: "play.fill").lineLimit(1).fixedSize() }.buttonStyle(.primary)
            Menu {
                Button("Rename…") { renameText = course.name; showRename = true }
                Divider()
                Button("Delete Course…", role: .destructive) { model.askDeleteCourse = course.id }
            } label: { Image(systemName: "ellipsis.circle").frame(width: 34, height: 30).contentShape(Rectangle()) }.menuStyle(.borderlessButton).fixedSize().accessibilityLabel("Course actions")
            if course.kind == .quickCram { Button("Convert to Course…") { convertName = course.name; showConvert = true } }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: Theme.Space.lg) { titleBlock.fixedSize(); tabs; Spacer(minLength: Theme.Space.md); actions }        // one line when it fits
                VStack(alignment: .leading, spacing: 10) { HStack { titleBlock; Spacer(); actions }; tabs }                         // narrow windows keep two
            }
            .padding([.horizontal, .top], 20).padding(.bottom, 12)
            .controlStrip()
            Group {
                switch tab {
                case .assessments: AssessmentsTab(course: course)
                case .topics: TopicsTab(course: course)
                case .materials: MaterialsTab(course: course)
                case .practice: CoursePracticeTab(course: course)
                }
            }
        }
        .onAppear { if SnapshotRunner.isActive, model.snapshotCourseTab == "materials" { tab = .materials } }
        .onChange(of: model.courseTabRequest) { _, r in if let r, let t = Tab.allCases.first(where: { $0.rawValue.lowercased() == r }) { tab = t; model.courseTabRequest = nil } }
        .sheet(isPresented: $showRename) { NameSheet(title: "Rename Course", prompt: "Course name", text: $renameText, confirm: "Rename") { model.perform { try model.courses?.renameCourse(course.id, to: renameText) } } }
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
                                HStack { Text(a.name).font(Theme.cardTitle)
                                    if a.isCumulative { Badge(text: "Cumulative", color: Theme.mastery) } }
                                Text(a.deadline.map { "Due \($0.formatted(date: .abbreviated, time: .omitted))" } ?? "No due date").font(.caption).foregroundStyle(Theme.textSecondary)
                            }.tag(a.id)
                            .contextMenu {
                                Button("Edit…") { editing = a }
                                Button("Delete", role: .destructive) { model.perform { try model.courses?.deleteAssessment(a.id) } }
                            }
                        }
                    }
                    Button { adding = true } label: { Label("Add Assessment", systemImage: "plus") }.padding(Theme.Space.md)
                }
            }
            .sidePanel().listPaneWidth()

            Group {
                if let a = assessments.first(where: { $0.id == selected }) {
                    VStack(spacing: 0) { scopeEditor(a); Divider(); PracticeSetsSection(course: course, assessment: a).frame(minHeight: 200, maxHeight: 300) }
                }
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
                Text("Cumulative: covers every topic in this course, including ones you add later.").font(.callout).foregroundStyle(Theme.textSecondary)
            } else if skills.isEmpty {
                Text("Add topics in the Topics tab first.").foregroundStyle(Theme.textSecondary)
            }
            List(skills) { s in
                Toggle(s.name, isOn: Binding(
                    get: { a.isCumulative || scope.contains(s.id) },
                    set: { on in model.perform {
                        if on { try model.courses?.addToScope(assessmentId: a.id, skillId: s.id) }
                        else { try model.courses?.removeFromScope(assessmentId: a.id, skillId: s.id) } } }))
                .disabled(a.isCumulative)
            }.scrollContentBackground(.hidden).background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.card))
                .overlay(RoundedRectangle(cornerRadius: Theme.Radius.card).strokeBorder(Theme.border))
        }.padding(Theme.Space.lg)
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
                Button(existing == nil ? "Add" : "Save", action: save).buttonStyle(.primary).keyboardShortcut(.defaultAction).disabled(name.trimmed.isEmpty) }
        }
        .formStyle(.grouped).scrollContentBackground(.hidden).frame(width: 440).padding(.vertical, Theme.Space.sm).background(Theme.background)
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
    @State private var rows: [TopicRow] = []
    @State private var assessments: [Assessment] = []
    @State private var assessmentId: UUID?
    @State private var search = ""
    @State private var collapsed: Set<UUID> = []
    @State private var minImportance = "any"
    @State private var name = ""
    @State private var parent: UUID?
    @State private var renaming: Skill?
    @State private var renameText = ""
    @State private var sourcesFor: TopicRow?
    @State private var showProfile = false

    /// Rows after search, importance filter and collapsed parents (a collapsed parent hides everything deeper until the next sibling).
    private var visible: [TopicRow] {
        var out: [TopicRow] = [], hideBelow: Int?
        for r in rows {
            if let d = hideBelow { if r.depth > d { continue } else { hideBelow = nil } }
            if collapsed.contains(r.id) { hideBelow = r.depth }
            out.append(r)
        }
        let q = search.trimmed.lowercased()
        return out.filter { r in
            (q.isEmpty || r.skill.name.lowercased().contains(q)) && (minImportance == "any" || r.level == minImportance)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Picker("Assessment", selection: $assessmentId) { Text("All topics").tag(UUID?.none); ForEach(assessments) { Text($0.name).tag(UUID?.some($0.id)) } }.frame(maxWidth: 220)
                Picker("Importance", selection: $minImportance) { Text("Any importance").tag("any"); Text("High").tag("high"); Text("Medium").tag("medium"); Text("Low").tag("low") }.frame(maxWidth: 170)
                TextField("Search topics", text: $search).frame(maxWidth: 200).accessibilityLabel("Search topics")
                Spacer()
                Button { model.practiceSetup = PracticeSetupRequest(courseId: course.id, assessmentId: assessmentId) } label: { Label("Practice", systemImage: "play.fill") }.buttonStyle(.primary).disabled(rows.allSatisfy { $0.questionCount == 0 })
                Button("Style profile") { showProfile = true }.help("What was detected about the instructor's question style, with confidence and limitations")
                Button("Analyze with Chat") { model.chat?.analyzeTopics(course: course, assessment: assessments.first { $0.id == assessmentId }) }.help("Re-run topic analysis and question generation in Chat. Your edits are kept; new topics are added.")
            }.padding([.horizontal, .top], 16)
            HStack {
                TextField("Add a topic", text: $name).onSubmit(add).accessibilityLabel("New topic name")
                Picker("Under", selection: $parent) {
                    Text("Top level").tag(UUID?.none)
                    ForEach(rows) { Text($0.skill.name).tag(UUID?.some($0.id)) }
                }.frame(maxWidth: 220)
                Button("Add", action: add).disabled(name.trimmed.isEmpty)
            }.padding(.horizontal, 16)
            if rows.isEmpty {
                EmptyStateView(symbol: "list.bullet.indent", title: "No topics yet",
                               message: "Ask Home chat to “prepare me for” an exam and topics are built from your materials, or add them by hand. Adding a name that already exists reuses it.")
            } else {
                if assessmentId != nil { Text("Estimated study priority is a suggestion based on your materials, not the real exam split. Only “Official” values come from your instructor.").font(.caption).foregroundStyle(Theme.textSecondary).padding(.horizontal, 16) }
                List(visible) { r in row(r) }.listStyle(.plain).scrollContentBackground(.hidden).background(Theme.surface)
            }
        }
        .task(id: "\(model.revision)-\(assessmentId?.uuidString ?? "")") { load() }
        .sheet(isPresented: $showProfile) { StyleProfileSheet(courseId: course.id, assessment: assessments.first { $0.id == assessmentId }) }
        .sheet(item: $renaming) { s in
            NameSheet(title: "Rename Topic", prompt: "Name", text: $renameText, confirm: "Rename") {
                model.perform { try model.courses?.renameSkill(s.id, to: renameText) }
            }
        }
        .popover(item: $sourcesFor) { r in
            VStack(alignment: .leading, spacing: 6) {
                Text("Sources for “\(r.skill.name)”").font(.headline)
                if !r.evidence.isEmpty { Text(r.evidence).font(.caption).foregroundStyle(Theme.textSecondary) }
                ForEach(r.sources, id: \.self) { Text("\($0.documentName)\($0.page.map { ", p.\($0)" } ?? "")") }
            }.padding(12).frame(width: 320)
        }
    }

    @ViewBuilder private func row(_ r: TopicRow) -> some View {
        HStack(spacing: 8) {
            Group {
                if r.hasChildren { Button { if collapsed.contains(r.id) { collapsed.remove(r.id) } else { collapsed.insert(r.id) } } label: { Image(systemName: collapsed.contains(r.id) ? "chevron.right" : "chevron.down").frame(width: 14) }.buttonStyle(.plain).accessibilityLabel(collapsed.contains(r.id) ? "Expand" : "Collapse") }
                else { Color.clear.frame(width: 14, height: 1) }
            }.padding(.leading, CGFloat(r.depth) * 18)
            Text(r.skill.name).foregroundStyle(r.inScope ? Theme.textPrimary : Theme.textSecondary).strikethrough(!r.inScope)
            Spacer()
            if let l = r.level { Badge(text: l.capitalized, color: l == "high" ? Theme.attention : Theme.accent) }
            Badge(text: r.weight.label, color: { if case .official = r.weight { return Theme.mastery }; return Theme.textSecondary }())
            if !r.sources.isEmpty { Button { sourcesFor = r } label: { Label("\(r.sources.count)", systemImage: "doc.text") }.buttonStyle(.plain).help("View sources").accessibilityLabel("\(r.sources.count) sources") }
            Text(r.questionCount == 0 ? "no questions" : "\(r.questionCount) q").font(.caption).foregroundStyle(Theme.textSecondary)
            Button { model.practiceSetup = PracticeSetupRequest(courseId: course.id, assessmentId: assessmentId, skillIds: [r.id]) } label: { Image(systemName: "play.circle") }.buttonStyle(.plain).disabled(r.questionCount == 0).help("Practice this topic").accessibilityLabel("Practice \(r.skill.name)")
        }
        .contextMenu {
            Button("Rename…") { renaming = r.skill; renameText = r.skill.name }
            if let a = assessmentId {
                Menu("Importance for this assessment") { ForEach(["high", "medium", "low"], id: \.self) { l in Button(l.capitalized) { model.perform { try model.courses?.setImportance(assessmentId: a, skillId: r.id, level: l) } } } }
                if r.inScope { Button("Exclude from this assessment") { model.perform { try model.courses?.removeFromScope(assessmentId: a, skillId: r.id) } } }
                else { Button("Mark as exam-relevant") { model.perform { try model.courses?.addToScope(assessmentId: a, skillId: r.id, importance: nil, source: .userAdjusted) } } }
            }
            Button("Generate practice questions…") { model.generateRequest = GenerateRequest(courseId: course.id, skillIds: [r.id], notes: "Create new questions for “\(r.skill.name)”.") }
            Menu("Merge into…") { ForEach(rows.filter { $0.id != r.id }) { t in Button(t.skill.name) { model.perform { try model.courses?.mergeSkills(from: r.id, into: t.id) } } } }
            Button("Archive", role: .destructive) { model.perform { try model.courses?.archiveSkill(r.skill.id) } }
        }
    }

    private func add() {
        guard !name.trimmed.isEmpty else { return }
        model.perform { try model.courses?.addSkill(courseId: course.id, name: name, parentId: parent) }
        name = ""
    }

    private func load() {
        guard let c = model.courses, let st = model.agentStore else { return }
        assessments = (try? c.assessments(courseId: course.id)) ?? []
        rows = ((try? c.topicRows(courseId: course.id, assessmentId: assessmentId, store: st)) ?? [])
    }
}

// MARK: Materials

/// A course's Materials are the Library rooted at that course: same records, same folders, same actions.
struct MaterialsTab: View {
    let course: Course
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Documents, images and videos for this course. They also appear in Library.")
                .font(.callout).foregroundStyle(Theme.textSecondary).lineLimit(1).padding(.horizontal, Theme.Space.lg).padding(.top, Theme.Space.sm)
            LibraryBrowser(base: .course(course.id)).id(course.id)
        }
    }
}

// MARK: Deleting courses

/// One confirmation for every way of deleting a course (list, detail header, Library course folder).
struct DeleteCourseDialog: ViewModifier {
    @EnvironmentObject var model: AppModel
    private var course: Course? { model.askDeleteCourse.flatMap { id in model.courseList.first { $0.id == id } } }
    func body(content: Content) -> some View {
        content.confirmationDialog("Delete “\(course?.name ?? "")”?", isPresented: Binding(get: { course != nil }, set: { if !$0 { model.askDeleteCourse = nil } }), titleVisibility: .visible) {
            Button("Delete Course", role: .destructive) {
                if let c = course {
                    model.perform { try model.library?.deleteCourse(c.id) }
                    if model.selectedCourseID == c.id { model.selectedCourseID = nil }
                }
                model.askDeleteCourse = nil
            }
            Button("Cancel", role: .cancel) { model.askDeleteCourse = nil }
        } message: {
            let until = Date().addingTimeInterval(LibraryService.retention).formatted(date: .long, time: .omitted)
            Text("The course and its materials and folders move to Recently Deleted. You can restore them until \(until). After that, the materials are permanently deleted. Questions and study progress are kept.")
        }
    }
}

struct DeletedSheet: View {
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(spacing: 0) {
            HStack { Text("Recently Deleted").font(Theme.sectionTitle); Spacer(); Button("Done") { dismiss() }.buttonStyle(.primary).keyboardShortcut(.defaultAction) }.padding(Theme.Space.lg)
            Divider()
            RecentlyDeletedView()
        }.frame(width: 680, height: 480).background(Theme.background)
    }
}


// MARK: Course overview

/// What you see before opening a course: one card per course with what matters at a glance.
struct CourseCardGrid: View {
    @EnvironmentObject var model: AppModel
    let onNew: () -> Void
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.lg) {
                HStack {
                    Text("Your courses").font(Theme.pageTitle)
                    Spacer()
                    Button { onNew() } label: { Label("New Course", systemImage: "plus") }.buttonStyle(.primary)
                }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 250, maximum: 360), spacing: Theme.Space.lg)], spacing: Theme.Space.lg) {
                    ForEach(model.courseList) { c in CourseCard(course: c) { model.selectedCourseID = c.id } }
                }
            }.padding(Theme.Space.xl)
        }
    }
}

struct CourseCard: View {
    @EnvironmentObject var model: AppModel
    let course: Course
    let open: () -> Void
    @State private var questions: Int?
    @State private var materials: Int?
    @State private var next: Assessment?
    @State private var hover = false
    var body: some View {
        Button(action: open) {
            VStack(alignment: .leading, spacing: Theme.Space.md) {
                HStack(spacing: Theme.Space.sm) {
                    Image(systemName: course.kind == .quickCram ? "bolt.fill" : "graduationcap.fill").foregroundStyle(course.kind == .quickCram ? Theme.attention : Theme.accent)
                        .frame(width: 32, height: 32).background((course.kind == .quickCram ? Theme.attention : Theme.accent).opacity(0.12), in: RoundedRectangle(cornerRadius: Theme.Radius.control)).accessibilityHidden(true)
                    Text(course.name).font(Theme.cardTitle).lineLimit(1)
                    Spacer(minLength: 0)
                }
                if let n = next, let d = n.deadline {
                    let days = Calendar.current.dateComponents([.day], from: Calendar.current.startOfDay(for: Date()), to: Calendar.current.startOfDay(for: d)).day ?? 0
                    VStack(alignment: .leading, spacing: 2) {
                        Text(n.name).font(.system(.callout, design: .rounded, weight: .medium)).lineLimit(1)
                        Text(days == 0 ? "Today" : days == 1 ? "Tomorrow" : "In \(days) days · " + d.formatted(date: .abbreviated, time: .omitted)).font(Theme.meta).foregroundStyle(days <= 3 ? Theme.attention : Theme.textSecondary)
                    }
                } else { Text("No upcoming assessment").font(.callout).foregroundStyle(Theme.textSecondary) }
                Divider()
                HStack(spacing: Theme.Space.lg) {
                    stat(questions, "questions"); stat(materials, "materials")
                    Spacer(minLength: 0)
                }
            }
            .padding(Theme.Space.lg).frame(maxWidth: .infinity, alignment: .leading)
            .background(hover ? Theme.elevated.opacity(0.5) : Theme.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.card))
            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.card).strokeBorder(hover ? Theme.accent.opacity(0.5) : Theme.border))
            .contentShape(RoundedRectangle(cornerRadius: Theme.Radius.card))
        }
        .buttonStyle(.plain).onHover { hover = $0 }.motion(value: hover)
        .accessibilityLabel("\(course.name), \(questions.map { "\($0) questions" } ?? ""), \(materials.map { "\($0) materials" } ?? "")")
        .task(id: model.revision) {
            var f = QuestionFilter(); f.courseId = course.id
            questions = (try? model.questions?.list(f))?.count
            materials = (try? model.documents?.documents(courseId: course.id))?.count
            let now = Calendar.current.startOfDay(for: Date())
            next = ((try? model.courses?.assessments(courseId: course.id)) ?? []).filter { ($0.deadline ?? .distantPast) >= now }.min { ($0.deadline ?? .distantFuture) < ($1.deadline ?? .distantFuture) }
        }
    }
    private func stat(_ n: Int?, _ label: String) -> some View {
        HStack(spacing: 4) { Text(n.map(String.init) ?? "–").font(.system(.callout, design: .rounded, weight: .semibold)).monospacedDigit(); Text(label).font(Theme.meta).foregroundStyle(Theme.textSecondary) }
    }
}

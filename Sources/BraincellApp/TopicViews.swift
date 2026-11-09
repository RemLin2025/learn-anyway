import SwiftUI
import BraincellCore

/// Create a topic-analysis task: pick a course, the documents whose text may be shared, and optional guidance.
struct TopicTaskSheet: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    var onCreate: (UUID) -> Void
    @State private var courseId: UUID?
    @State private var docs: [Document] = []
    @State private var docIds: Set<UUID> = []
    @State private var notes = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("New topic analysis").font(.headline)
            Text("ChatGPT proposes skills, hierarchy, prerequisites and assessment coverage. Nothing changes until you review and accept the proposal.")
                .font(.caption).foregroundStyle(Theme.textSecondary)
            Form {
                Picker("Course", selection: $courseId) {
                    Text("Choose…").tag(UUID?.none)
                    ForEach(model.courseList) { Text($0.name).tag(UUID?.some($0.id)) }
                }
                Section("Include text from documents (only checked ones are shared)") {
                    if docs.isEmpty { Text("No documents imported for this course. The request will use only the course name, skills and assessments.").foregroundStyle(Theme.textSecondary) }
                    ForEach(docs) { d in Toggle(d.title, isOn: Binding(get: { docIds.contains(d.id) }, set: { if $0 { docIds.insert(d.id) } else { docIds.remove(d.id) } })) }
                }
                TextField("Extra guidance (optional)", text: $notes)
            }.formStyle(.grouped).scrollContentBackground(.hidden)
            HStack { Spacer(); Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Create Task", action: create).keyboardShortcut(.defaultAction).disabled(courseId == nil) }
        }
        .padding(Theme.Space.xl).frame(width: 520, height: 520).background(Theme.background)
        .onAppear { courseId = model.selectedCourseID ?? model.courseList.first?.id; load() }
        .onChange(of: courseId) { _, _ in docIds = []; load() }
    }

    private func load() { docs = courseId.flatMap { try? model.documents?.documents(courseId: $0) } ?? [] }

    private func create() {
        guard let c = courseId else { return }
        model.perform { if let t = try model.ai?.createTopicAnalysisTask(courseId: c, documentIds: Array(docIds), notes: notes) { onCreate(t.id) } }
        dismiss()
    }
}

/// Review of a staged topic proposal. Every row says what will happen; declined or undecided rows change nothing.
struct TopicReviewView: View {
    @EnvironmentObject var model: AppModel
    let batchId: UUID
    var onClose: () -> Void

    enum Choice: Hashable { case accept, skip, merge(UUID) }
    @State private var proposal: TopicProposal?
    @State private var choices: [String: Choice] = [:]
    @State private var names: [String: String] = [:]
    @State private var report: TopicApplyReport?
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Review proposed skills").font(.headline)
            if let report { results(report) }
            else if let p = proposal { review(p) }
            else if let error { Text(error).foregroundStyle(.red) }
            else { ProgressView() }
        }
        .task { load() }
    }

    private func load() {
        guard let p = try? model.ai?.topicProposal(batchId: batchId) else { error = "This proposal is no longer available."; return }
        proposal = p
        for i in p.items {
            names[i.id] = i.name
            switch i.match { case .ambiguous: choices[i.id] = .skip; default: choices[i.id] = .accept }
        }
    }

    private func review(_ p: TopicProposal) -> some View {
        let n = p.items.filter { if case .new = $0.match { true } else { false } }.count
        let e = p.items.filter { if case .existing = $0.match { true } else { false } }.count
        let a = p.items.count - n - e
        return VStack(alignment: .leading, spacing: 8) {
            Text("\(n) new · \(e) match existing skills · \(a) need your decision").font(.callout).foregroundStyle(Theme.textSecondary)
            if p.alreadyApplied { Label("This proposal was already applied. Applying again adds nothing that exists.", systemImage: "checkmark.circle").foregroundStyle(Theme.accent).font(.callout) }
            if !p.unknownAssessments.isEmpty { Label("Not in this course, ignored: " + p.unknownAssessments.joined(separator: ", "), systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(Theme.attention) }
            if !p.problems.isEmpty {
                DisclosureGroup("\(p.problems.count) entr\(p.problems.count == 1 ? "y" : "ies") in the reply couldn’t be used") {
                    ForEach(p.problems, id: \.self) { Text("• " + $0).font(.caption) }
                }
            }
            List(p.items) { row($0) }.frame(minHeight: 280)
            HStack {
                Text("Existing mastery, XP and answers are never changed.").font(.caption).foregroundStyle(Theme.textSecondary)
                Spacer()
                Button("Close", action: onClose).keyboardShortcut(.cancelAction)
                Button("Apply \(acceptedCount(p)) Skill\(acceptedCount(p) == 1 ? "" : "s")") { apply() }.keyboardShortcut(.defaultAction)
            }
        }
    }

    private func acceptedCount(_ p: TopicProposal) -> Int { p.items.filter { choices[$0.id] != .skip }.count }

    @ViewBuilder private func row(_ i: TopicItem) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                switch i.match {
                case .new:
                    Toggle("", isOn: Binding(get: { choices[i.id] != .skip }, set: { choices[i.id] = $0 ? .accept : .skip })).labelsHidden().accessibilityLabel("Accept \(i.name)")
                    TextField("Name", text: Binding(get: { names[i.id] ?? i.name }, set: { names[i.id] = $0 })).textFieldStyle(AppFieldStyle())
                    Badge(text: "New", color: Theme.accent)
                case .existing(let s):
                    Image(systemName: "checkmark.circle").foregroundStyle(Theme.mastery).accessibilityHidden(true)
                    Text(i.name); Spacer()
                    Badge(text: "Already have “\(s.name)”", color: Theme.textSecondary)
                case .ambiguous(let c):
                    TextField("Name", text: Binding(get: { names[i.id] ?? i.name }, set: { names[i.id] = $0 })).textFieldStyle(AppFieldStyle())
                    Picker("", selection: Binding(get: { choices[i.id] ?? .skip }, set: { choices[i.id] = $0 })) {
                        Text("Skip for now").tag(Choice.skip)
                        Text("Add as a new skill").tag(Choice.accept)
                        ForEach(c) { s in Text("Same as “\(s.name)”").tag(Choice.merge(s.id)) }
                    }.labelsHidden().frame(width: 230).accessibilityLabel("Decision for \(i.name)")
                }
            }
            if !i.summary.isEmpty { Text(i.summary).font(.caption).foregroundStyle(Theme.textSecondary) }
            let links = [i.parentRef.map { "Under: \(label($0))" }, i.prerequisiteRefs.isEmpty ? nil : "Needs first: " + i.prerequisiteRefs.map(label).joined(separator: ", "),
                         i.assessments.isEmpty ? nil : "Covered by: " + i.assessments.joined(separator: ", ")].compactMap { $0 }
            if !links.isEmpty { Text(links.joined(separator: "  ·  ")).font(.caption).foregroundStyle(Theme.textSecondary) }
        }.padding(.vertical, 2).accessibilityElement(children: .contain)
    }

    private func label(_ ref: String) -> String { proposal?.items.first { $0.id == ref }?.name ?? ref }

    private func apply() {
        guard let p = proposal else { return }
        var d: [String: TopicDecision] = [:]
        for i in p.items {
            let name = (names[i.id] ?? i.name).trimmingCharacters(in: .whitespaces)
            let renamed = name != i.name && !name.isEmpty ? name : nil
            switch choices[i.id] ?? .accept {
            case .skip: d[i.id] = TopicDecision(accept: false)
            case .accept: d[i.id] = TopicDecision(accept: true, name: renamed)
            case .merge(let id): d[i.id] = TopicDecision(accept: true, mergeInto: id)
            }
        }
        do { report = try model.ai?.applyTopics(batchId: batchId, decisions: d); model.reload() }
        catch { self.error = error.localizedDescription }
    }

    private func results(_ r: TopicApplyReport) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                Label("\(r.created.count) skill(s) added, \(r.reused.count) matched to existing", systemImage: "checkmark.circle.fill").foregroundStyle(Theme.mastery)
                Text("\(r.relationsAdded) link(s) added · \(r.coverageAdded) assessment coverage link(s)").font(.callout)
                if !r.skipped.isEmpty {
                    Label("Left out", systemImage: "info.circle").foregroundStyle(Theme.attention)
                    ForEach(r.skipped, id: \.self) { Text("• " + $0).font(.caption) }
                }
                HStack { Spacer(); Button("Done", action: onClose).keyboardShortcut(.defaultAction) }
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

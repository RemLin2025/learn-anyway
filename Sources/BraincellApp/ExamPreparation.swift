import SwiftUI
import AppKit
import BraincellCore

@MainActor
final class ExamPreparationModel: ObservableObject {
    let context: AgentContext
    @Published var courseId: UUID?
    @Published var assessmentId: UUID?
    @Published var assessments: [Assessment] = []
    @Published var name = ""
    @Published var hasDate = false
    @Published var date = Date()
    @Published var instructions = ""
    @Published var workspace: ExamWorkspace?
    @Published var documents: [Document] = []
    @Published var step = 0
    @Published var busy = false
    @Published var operation = ""
    @Published var milestones: [String] = []
    @Published var error: String?
    @Published var notice: String?
    @Published var result: String?
    @Published var newTopic = ""
    private var task: Task<Void, Never>?
    private var token = UUID()

    init(context: AgentContext, courseId: UUID?, assessmentId: UUID?) {
        self.context = context; self.courseId = courseId
        loadCourse()
        self.assessmentId = assessmentId ?? assessments.first?.id
        loadAssessment()
    }
    func loadCourse() {
        perform { assessments = try courseId.map { try context.courses.assessments(courseId: $0) } ?? [] }
        assessmentId = assessments.first?.id; loadAssessment()
    }
    func loadAssessment() {
        workspace = nil; instructions = ""; name = ""; step = 0; hasDate = false; result = nil
        guard let a = assessments.first(where: { $0.id == assessmentId }) else { return }
        name = a.name; hasDate = a.deadline != nil; date = a.deadline ?? Date()
        perform {
            let saved = try ExamWorkspace.load(assessmentId: a.id, context.db)
            workspace = saved; instructions = saved.instructions
        }
    }
    func setup() {
        perform {
            guard let courseId else { throw NSError(domain: "Exam", code: 1, userInfo: [NSLocalizedDescriptionKey: "Choose a course."]) }
            let title = name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty else { return }
            let normalized: (String) -> String = { $0.lowercased().filter { $0.isLetter || $0.isNumber } }
            var a: Assessment
            if let existing = assessments.first(where: { $0.id == assessmentId || normalized($0.name) == normalized(title) }) {
                if assessmentId == nil { assessmentId = existing.id; loadAssessment(); notice = "That assessment already exists. Its saved details are loaded."; return }
                a = existing
            }
            else { a = try context.courses.addAssessment(courseId: courseId, name: title) }
            a.deadline = hasDate ? date : nil; try context.courses.updateAssessment(a)
            assessmentId = a.id
            var w: ExamWorkspace
            if let saved = workspace, saved.assessmentId == a.id { w = saved }
            else { w = try ExamWorkspace.load(assessmentId: a.id, context.db) }
            if w.instructions != instructions { w.invalidate(); w.instructions = instructions }
            workspace = w
            documents = try StudyPrep.availableDocuments(context)
            step = w.proposal == nil ? 1 : w.approved ? 3 : 2
            try persist()
        }
    }
    func persist() throws {
        guard var w = workspace else { return }; w.step = step; workspace = w; try w.save(context.db)
    }
    func save() { perform { try persist() } }
    func perform(_ f: () throws -> Void) { do { error = nil; try f() } catch { self.error = error.localizedDescription } }
    func toggle(_ document: Document, include: Bool) {
        guard var w = workspace else { return }
        w.invalidate()
        if include { if !w.materials.contains(where: { $0.id == document.id }) { w.materials.append(ExamMaterial(id: document.id)) } }
        else { w.materials.removeAll { $0.id == document.id } }
        workspace = w; result = nil; save()
    }
    func classify(_ id: UUID, relevance: ExamMaterial.Relevance? = nil, kind: ExamMaterial.Kind? = nil) {
        guard var w = workspace, let i = w.materials.firstIndex(where: { $0.id == id }) else { return }
        w.invalidate(); if let relevance { w.materials[i].relevance = relevance }; if let kind { w.materials[i].kind = kind }
        workspace = w; save()
    }
    func pickFiles() {
        let panel = NSOpenPanel(); panel.allowsMultipleSelection = true; panel.canChooseDirectories = false
        if panel.runModal() == .OK { importFiles(panel.urls) }
    }
    func importFiles(_ urls: [URL]) {
        guard !busy, let courseId else { return }
        busy = true; operation = "Importing and extracting materials"; error = nil
        let c = context, op = UUID(); token = op
        task = Task.detached { [weak self] in
            var added: [Document] = [], failures: [String] = []
            // Use the Library's document import, deduplication, managed storage and extraction.
            for url in urls {
                if Task.isCancelled { break }
                let access = url.startAccessingSecurityScopedResource()
                do { added.append(try c.docs.importAnyFile(at: url, courseId: courseId, folderId: nil).document) }
                catch { failures.append("\(url.lastPathComponent): \(error.localizedDescription)") }
                if access { url.stopAccessingSecurityScopedResource() }
            }
            let all = try? StudyPrep.availableDocuments(c)
            await self?.imported(added, all: all, failures: failures, token: op)
        }
    }
    private func imported(_ added: [Document], all: [Document]?, failures: [String], token: UUID) {
        guard self.token == token else { return }
        busy = false; task = nil; operation = ""
        if let all { documents = all }
        for d in added { toggle(d, include: true) }
        notice = "\(added.count) material(s) added."; if !failures.isEmpty { error = failures.joined(separator: "\n") }
    }
    func run(generate: Bool) {
        guard !busy, let w = workspace, let courseId, let course = try? context.courses.courses().first(where: { $0.id == courseId }), let a = assessments.first(where: { $0.id == w.assessmentId }) ?? (try? context.courses.assessments(courseId: courseId))?.first(where: { $0.id == w.assessmentId }) else { return }
        guard !generate || w.approved else { error = "Review and approve the study map first."; return }
        save(); guard error == nil else { return }
        busy = true; error = nil; milestones = []; operation = "Checking selected materials"
        let c = context, op = UUID(); token = op
        task = Task.detached { [weak self] in
            do {
                _ = try await StudyPrep.run(course: course, assessmentName: a.name, documentIds: w.materials.map(\.id), instructions: w.analysisInstructions, reviewOnly: !generate, questionCount: w.count, conversationId: w.conversationId, c, stage: { message in
                    Task { @MainActor [weak self] in self?.progress(message, token: op) }
                })
                try Task.checkCancellation()
                let job = try StudyPrep.jobs(courseId: courseId, c.db).first { $0.conversationId == w.conversationId }
                let map = try job?.state.mapId.flatMap { try c.store.map($0)?.document }
                await self?.finished(job, map: map, generate: generate, token: op)
            } catch { await self?.failed(error.localizedDescription, token: op) }
        }
    }
    private func progress(_ message: String, token: UUID) {
        guard self.token == token, busy else { return }
        if !operation.isEmpty { milestones.append(operation) }; operation = message
    }
    private func finished(_ job: StudyPrepJob?, map: StudyMapDocument?, generate: Bool, token: UUID) {
        guard self.token == token else { return }
        busy = false; task = nil
        guard let job, job.error == nil, generate ? job.status == .completed : map != nil else {
            error = job?.error ?? "No usable study map was saved. Review materials and retry."; return
        }
        if !operation.isEmpty { milestones.append(operation) }; operation = ""
        if generate { result = "Saved \(job.state.accepted) practice questions · \(job.state.duplicates) duplicates skipped · \(job.state.rejected) rejected. Questions are structurally validated and marked Unverified." }
        else { workspace?.proposal = map; workspace?.approved = false; workspace?.excluded = []; step = 2 }
        save()
    }
    private func failed(_ message: String, token: UUID) { guard self.token == token else { return }; busy = false; task = nil; error = message }
    func pause() {
        task?.cancel(); task = nil; token = UUID(); busy = false
        notice = "Paused. Imported files and completed checkpoints are saved."; save()
    }
    func approve() { perform { guard var w = workspace, let courseId else { return }; try w.approve(context, courseId: courseId); workspace = w; step = 3; result = nil; try persist() } }
    func editTopic(_ index: Int, _ edit: (inout StudyMapDocument.Topic) -> Void) {
        guard var w = workspace, var p = w.proposal else { return }; edit(&p.topics[index]); w.proposal = p; w.approved = false; workspace = w; result = nil; save()
    }
    func addTopic() {
        let n = newTopic.trimmingCharacters(in: .whitespacesAndNewlines); guard !n.isEmpty else { return }
        workspace?.proposal?.topics.append(ExamWorkspace.missingTopic(n)); workspace?.approved = false; newTopic = ""; save()
    }
}

struct ExamPreparationSheet: View {
    @StateObject private var m: ExamPreparationModel
    @EnvironmentObject private var app: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var showLibrary = false
    @State private var search = ""
    init(context: AgentContext, courseId: UUID?, assessmentId: UUID?) { _m = StateObject(wrappedValue: ExamPreparationModel(context: context, courseId: courseId, assessmentId: assessmentId)) }
    private let stages = ["Setup", "Materials", "Review", "Generate"]
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack { VStack(alignment: .leading, spacing: 4) { Text("Prepare for an exam").font(.title2.bold()); Text("Choose your sources, review the findings, then create practice.").foregroundStyle(.secondary) }; Spacer(); Button { m.pause(); dismiss() } label: { Image(systemName: "xmark") }.accessibilityLabel("Save and close") }
            HStack { ForEach(stages.indices, id: \.self) { i in
                HStack { Image(systemName: i < m.step ? "checkmark.circle.fill" : "\(i + 1).circle"); Text(stages[i]).fontWeight(i == m.step ? .semibold : .regular) }.foregroundStyle(i == m.step ? Theme.accent : Theme.textSecondary)
                if i < 3 { Divider().frame(height: 14); Spacer(minLength: 4) }
            } }.accessibilityLabel("Step \(m.step + 1) of 4: \(stages[m.step])")
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if m.busy { progress }
                    else { switch m.step { case 0: setup; case 1: materials; case 2: review; default: generate } }
                    if let e = m.error {
                        Label("\(m.operation.isEmpty ? "Preparation" : m.operation) failed", systemImage: "exclamationmark.triangle").foregroundStyle(Theme.error)
                        Text(e).textSelection(.enabled)
                        HStack { if m.step != 0 { Button("Review materials") { m.step = 1 }; Button("Retry") { m.run(generate: m.step == 3) } }; Button("AI configuration") { m.pause(); dismiss(); app.openWorkflow(task: m.step == 3 ? "quizGeneration" : "topicGeneration") } }
                    }
                    if let n = m.notice { Text(n).font(.caption).foregroundStyle(.secondary) }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }.frame(maxHeight: 420)
            Divider()
            HStack {
                if m.busy { Button("Pause") { m.pause() } }
                else if m.step > 0 { Button("Back") { m.step -= 1; m.save() } }
                Spacer()
                Text("Closing pauses active work and keeps completed checkpoints.").font(.caption).foregroundStyle(.secondary).frame(maxWidth: 280)
                if !m.busy { action }
            }
        }.padding(24).frame(width: 700).background(Theme.background)
        .onDisappear { m.pause() }
    }
    private var setup: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("Course", selection: Binding(get: { m.courseId }, set: { m.courseId = $0; m.loadCourse() })) { Text("Choose a course").tag(UUID?.none); ForEach(app.courseList) { Text($0.name).tag(UUID?.some($0.id)) } }
            Picker("Assessment", selection: Binding(get: { m.assessmentId }, set: { m.assessmentId = $0; m.loadAssessment() })) { Text("Create new assessment").tag(UUID?.none); ForEach(m.assessments) { Text($0.name).tag(UUID?.some($0.id)) } }
            if m.assessmentId == nil { TextField("Assessment name", text: $m.name) }
            Toggle("Set exam date (optional)", isOn: $m.hasDate)
            if m.hasDate { DatePicker("Exam date", selection: $m.date, displayedComponents: .date) }
            Text("Instructions or exam coverage (optional)").font(.headline)
            TextEditor(text: $m.instructions).frame(height: 70).fieldSurface()
        }
    }
    private var materials: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button { m.pickFiles() } label: { Label("Drop materials here or choose files…", systemImage: "square.and.arrow.down").frame(maxWidth: .infinity).padding(20).background(Theme.accent.opacity(0.06), in: RoundedRectangle(cornerRadius: 10)) }
                .dropDestination(for: URL.self) { urls, _ in m.importFiles(urls); return true }
            Toggle("Browse all Library documents", isOn: $showLibrary)
            TextField("Find materials", text: $search)
            Text("Select course materials or Library documents. Labels are yours to set; scope is never expanded automatically.").font(.caption).foregroundStyle(.secondary)
            ForEach(m.documents.filter { d in (showLibrary || d.courseId == m.courseId || m.workspace?.materials.contains(where: { $0.id == d.id }) == true) && (search.isEmpty || d.name.localizedCaseInsensitiveContains(search)) }) { d in material(d) }
            ForEach((m.workspace?.materials ?? []).filter { material in !m.documents.contains(where: { $0.id == material.id }) }) { missing in
                HStack { Label("Unavailable document", systemImage: "exclamationmark.triangle"); Spacer(); Button("Remove reference") { m.workspace?.materials.removeAll { $0.id == missing.id }; m.workspace?.invalidate(); m.save() } }
            }
            if m.documents.isEmpty { Text("Add notes, a practice exam, or an exam announcement to begin.").foregroundStyle(.secondary) }
        }
    }
    private func material(_ d: Document) -> some View {
        let selected = m.workspace?.materials.first { $0.id == d.id }
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Toggle(d.name, isOn: Binding(get: { selected != nil }, set: { m.toggle(d, include: $0) }))
                Spacer(); Text("\(d.kind.rawValue.uppercased()) · \(d.extractionStatus.rawValue)").font(.caption).foregroundStyle(.secondary)
                Button("Preview") { NSWorkspace.shared.open(m.context.storage.url(forStoredPath: d.storedPath)) }
            }
            if let selected {
                HStack {
                    Picker("Type", selection: Binding(get: { selected.kind }, set: { m.classify(d.id, kind: $0) })) { ForEach(ExamMaterial.Kind.allCases, id: \.self) { Text($0.rawValue).tag($0) } }
                    Picker("Relevance", selection: Binding(get: { selected.relevance }, set: { m.classify(d.id, relevance: $0) })) { ForEach(ExamMaterial.Relevance.allCases, id: \.self) { Text($0.rawValue).tag($0) } }
                }.controlSize(.small)
                if d.extractionStatus == .failed || d.extractionStatus == .notApplicable { Text("Text unavailable. This file cannot contribute to AI analysis.").font(.caption).foregroundStyle(Theme.attention) }
                if mismatch(d.name) { Text("This document mentions a different assessment. Review it or label it supplementary.").font(.caption).foregroundStyle(Theme.attention) }
            }
        }.padding(12).background(Theme.surface, in: RoundedRectangle(cornerRadius: 10))
    }
    private func mismatch(_ name: String) -> Bool {
        let pattern = #"(?i)(midterm|exam|quiz)\s*\d+"#
        guard let range = name.range(of: pattern, options: .regularExpression), let target = m.name.range(of: pattern, options: .regularExpression) else { return false }
        return name[range].lowercased().filter { !$0.isWhitespace } != m.name[target].lowercased().filter { !$0.isWhitespace }
    }
    private var review: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Review your study map").font(.headline)
            Text("Source references were checked against imported documents. AI estimates are uncertain; they do not establish exam coverage.").font(.caption).foregroundStyle(.secondary)
            if let p = m.workspace?.proposal {
                ForEach(p.warnings, id: \.self) { Text($0).font(.caption).foregroundStyle(Theme.attention) }
                ForEach(p.topics.indices, id: \.self) { i in topic(p.topics[i], index: i) }
                if !p.structures.isEmpty { DisclosureGroup("Instructor problem patterns (\(p.structures.count))") { ForEach(p.structures) { s in VStack(alignment: .leading) { Text(s.family).bold(); Text(s.method); Text("Distinguishing step: \(s.extraStep)"); Text("Source: \(s.source.documentName)\(s.source.page.map { " · p.\($0)" } ?? "")").font(.caption) } } } }
            }
            HStack { TextField("Add a missing topic", text: $m.newTopic); Button("Add") { m.addTopic() } }
        }
    }
    private func topic(_ t: StudyMapDocument.Topic, index i: Int) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Toggle("Include", isOn: Binding(get: { !(m.workspace?.excluded.contains(i) ?? false) }, set: { include in if include { m.workspace?.excluded.remove(i) } else { m.workspace?.excluded.insert(i) }; m.workspace?.approved = false; m.result = nil; m.save() }))
                TextField("Topic name", text: Binding(get: { t.name }, set: { value in m.editTopic(i) { $0.name = value } }))
            }
            TextField("Subtopics / objectives (separate with semicolons)", text: Binding(get: { t.objectives.joined(separator: "; ") }, set: { value in m.editTopic(i) { $0.objectives = value.split(separator: ";").map { $0.trimmingCharacters(in: .whitespaces) } } }))
            Picker("Study priority", selection: Binding(get: { t.importance.level }, set: { value in m.editTopic(i) { $0.importance.level = value; $0.importance.source = .estimated; $0.importance.weightPercent = nil; $0.importance.evidence = "Priority set by learner." } })) { ForEach(["high", "medium", "low", "unknown"], id: \.self) { Text($0.capitalized).tag($0) } }
            Text(t.importance.source == .instructor ? "Instructor-supported weighting\(t.importance.weightPercent.map { ": \($0)%" } ?? "")" : t.importance.source == .estimated ? "Estimated priority · uncertainty not quantified" : "Unknown weighting").font(.caption).foregroundStyle(.secondary)
            if !t.importance.evidence.isEmpty { Text(t.importance.evidence).font(.caption).textSelection(.enabled) }
            ForEach(t.sources, id: \.self) { ref in Button("\(ref.documentName)\(ref.page.map { " · p.\($0)" } ?? "")") { if let d = m.documents.first(where: { $0.id == ref.documentId }) { NSWorkspace.shared.open(m.context.storage.url(forStoredPath: d.storedPath)) } }.font(.caption) }
            if t.sources.isEmpty { Text("No verified source reference. Review this topic carefully.").font(.caption).foregroundStyle(Theme.attention) }
        }.padding(12).background(Theme.surface, in: RoundedRectangle(cornerRadius: 10))
    }
    private var generate: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Original exam-style practice questions", systemImage: "checkmark.square.fill").font(.headline)
            Text("Uses approved topics, available problem patterns and worked solutions. Saved to the existing question bank after structural validation.")
            Stepper("Questions: \(m.workspace?.count ?? 10)", value: Binding(get: { m.workspace?.count ?? 10 }, set: { m.workspace?.count = $0; m.save() }), in: 1...30).disabled(m.result != nil)
            Text("Mixed difficulty and suitable question types. Generated content remains Unverified until checked.").font(.caption).foregroundStyle(.secondary)
            if let result = m.result { Label(result, systemImage: "checkmark.circle.fill").foregroundStyle(Theme.mastery); Button("Open question bank") { dismiss(); app.questionBankCourse = m.courseId; app.selection = .questionBank } }
        }
    }
    private var progress: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(Array(m.milestones.enumerated()), id: \.offset) { _, title in Label(title, systemImage: "checkmark.circle.fill").foregroundStyle(Theme.mastery) }
            HStack { ProgressView().controlSize(.small); Text(m.operation) }
            Text("Waiting for the current operation to finish. Completed work is saved; you can pause and retry.").font(.caption).foregroundStyle(.secondary)
        }
    }
    @ViewBuilder private var action: some View {
        switch m.step {
        case 0: Button("Continue") { m.setup() }.disabled(m.courseId == nil || m.name.trimmingCharacters(in: .whitespaces).isEmpty)
        case 1: Button("Analyze materials") { m.run(generate: false) }.disabled(m.workspace?.materials.isEmpty != false)
        case 2: Button("Approve study map") { m.approve() }
        default: Button(m.result == nil ? "Generate practice" : "Done") { if m.result == nil { m.run(generate: true) } else { dismiss() } }
        }
    }
}

import SwiftUI
import AppKit
import UniformTypeIdentifiers
import BraincellCore

struct AITaskCenterView: View {
    @EnvironmentObject var model: AppModel
    @State private var tasks: [AITask] = []
    @State private var selected: UUID?
    @State private var showNew = false
    @State private var showTopics = false
    @State private var importTarget: ImportTarget?

    var body: some View {
        HSplitView {
            VStack(spacing: 0) {
                if tasks.isEmpty {
                    EmptyStateView(symbol: "tray.and.arrow.up", title: "No AI tasks",
                                   message: "Prepare a request, copy it into your own ChatGPT chat, then bring the JSON reply back. Learn Anyway never contacts ChatGPT for you.",
                                   actionTitle: "New Generation Task") { showNew = true }
                } else {
                    List(tasks, selection: $selected) { t in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(t.title).font(.headline)
                            let st = (try? model.ai?.status(taskId: t.id)) ?? .draft
                            Badge(text: label(st), color: color(st))
                        }.tag(t.id).accessibilityElement(children: .combine)
                    }
                }
            }
            .sidePanel().frame(minWidth: 220, idealWidth: 260, maxWidth: 320)

            Group {
                if let id = selected, let task = tasks.first(where: { $0.id == id }) { TaskDetailView(task: task, importTarget: $importTarget).id(id) }
                else { EmptyStateView(symbol: "list.bullet.rectangle", title: "Select a task", message: "Each task is split into batches that you send to ChatGPT one at a time.") }
            }.frame(minWidth: 460)
        }
        .toolbar {
            Button { importTarget = ImportTarget(batch: nil) } label: { Label("Import Response", systemImage: "square.and.arrow.down") }
                .help("Import a ChatGPT reply; it is matched to its request by requestId")
            Button { model.showGradingSheet = true } label: { Label("Grade Pending…", systemImage: "checkmark.bubble") }
                .help("Ask ChatGPT (manually) to grade written or code answers")
            Menu {
                Button("Question Generation…") { showNew = true }
                Button("Topic Analysis…") { showTopics = true }
            } label: { Label("New Task", systemImage: "plus") }
        }
        .task(id: model.revision) {
            tasks = (try? model.ai?.tasks()) ?? []
            if SnapshotRunner.isActive, selected == nil { selected = tasks.first?.id } // screenshot aid
        }
        .sheet(isPresented: $showNew) { NewTaskSheet(request: nil) { selected = $0 } }
        .sheet(isPresented: $showTopics) { TopicTaskSheet { selected = $0 } }
        .sheet(item: $model.generateRequest) { NewTaskSheet(request: $0) { selected = $0; model.selection = .aiTasks } }
        .sheet(item: $importTarget) { ImportSheet(target: $0) }
        .sheet(isPresented: $model.showGradingSheet) { GradeTaskSheet { selected = $0 } }
    }

    private func label(_ s: TaskStatus) -> String {
        switch s { case .draft: "Not exported"; case .awaitingImport: "Awaiting import"; case .needsAttention: "Needs attention"; case .completed: "Completed" }
    }
    private func color(_ s: TaskStatus) -> Color {
        switch s { case .draft: .secondary; case .awaitingImport: Theme.accent; case .needsAttention: Theme.attention; case .completed: Theme.mastery }
    }
}

struct ImportTarget: Identifiable { let id = UUID(); var batch: AITaskBatch? }

// MARK: Task detail

struct TaskDetailView: View {
    @EnvironmentObject var model: AppModel
    let task: AITask
    @Binding var importTarget: ImportTarget?
    @State private var batches: [AITaskBatch] = []
    @State private var requestBatch: AITaskBatch?
    @State private var reviewBatch: AITaskBatch?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text(task.title).font(Theme.sectionTitle)
                Text("Copy the request, run it in your own ChatGPT chat, then import the JSON reply.").foregroundStyle(Theme.textSecondary)
                ForEach(batches) { b in
                    Card {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Text(title(b)).font(.headline)
                                Badge(text: statusLabel(b.status), color: statusColor(b.status))
                                Spacer()
                                Text(b.kind == .topics ? "skill proposal" : "\(b.expectedCount) question\(b.expectedCount == 1 ? "" : "s")").foregroundStyle(Theme.textSecondary)
                            }
                            if b.status == .awaitingImport, let at = b.exportedAt {
                                Text("Exported \(at.formatted(date: .abbreviated, time: .shortened)) via \(b.transferMethod?.rawValue ?? "—"). Request ID: \(b.requestId)")
                                    .font(.caption).foregroundStyle(Theme.textSecondary).textSelection(.enabled)
                            }
                            HStack {
                                Button(b.status == .draft ? "Review & Export…" : "View Request…") { requestBatch = b }
                                Button("Import Response…") { importTarget = ImportTarget(batch: b) }
                                    .disabled(b.status == .draft)
                                    .help(b.status == .draft ? "Export the request first" : "")
                                if b.kind == .topics, (try? model.ai?.topicProposal(batchId: b.id)) != nil {
                                    Button(b.status == .imported ? "View Proposal…" : "Review Proposal…") { reviewBatch = b }
                                }
                                if b.status == .needsRepair, b.kind != .grade, b.kind != .topics { Button("Create Repair Request") { make { try model.ai?.createRepairBatch(from: b.id) } } }
                                if b.status == .incomplete, b.kind != .grade, b.kind != .topics { Button("Create Continuation Request") { make { try model.ai?.createContinuationBatch(from: b.id) } } }
                            }
                            if b.kind == .grade, b.status == .needsRepair || b.status == .incomplete {
                                Text("Some answers weren’t graded. They stay pending (not wrong). Create a new grading task for them from Grade Pending….").font(.caption).foregroundStyle(Theme.textSecondary)
                            }
                            if let last = (try? model.ai?.imports(batchId: b.id))?.first(where: { $0.outcome == .imported }) {
                                Text("Last import: \(last.acceptedCount) added, \(last.duplicateCount) duplicate, \(last.rejectedCount) rejected of \(last.returnedCount)")
                                    .font(.caption).foregroundStyle(Theme.textSecondary)
                            }
                        }
                    }
                }
            }.padding(20)
        }
        .task(id: model.revision) { batches = (try? model.ai?.batches(taskId: task.id)) ?? [] }
        .sheet(item: $requestBatch) { RequestSheet(batch: $0) }
        .sheet(item: $reviewBatch) { b in TopicReviewView(batchId: b.id) { reviewBatch = nil }.padding(Theme.Space.xl).frame(width: 720, height: 580).background(Theme.background) }
    }

    private func make(_ f: () throws -> AITaskBatch?) { model.perform { _ = try f() } }
    private func title(_ b: AITaskBatch) -> String {
        switch b.kind { case .generate: "Batch \(b.ordinal + 1)"; case .repair: "Repair request"; case .continue: "Continuation request"; case .grade: "Grading batch \(b.ordinal + 1)"; case .topics: "Topic analysis" }
    }
    private func statusLabel(_ s: BatchStatus) -> String {
        switch s { case .draft: "Not exported"; case .awaitingImport: "Awaiting import"; case .imported: "Imported"; case .needsRepair: "Needs repair"; case .incomplete: "Incomplete" }
    }
    private func statusColor(_ s: BatchStatus) -> Color {
        switch s { case .draft: .secondary; case .awaitingImport: Theme.accent; case .imported: Theme.mastery; case .needsRepair, .incomplete: Theme.attention }
    }
}


// MARK: Request review / export

struct RequestSheet: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let batch: AITaskBatch
    @State private var pkg: RequestPackage?
    @State private var method: TransferMethod = .clipboard
    @State private var message: String?
    @State private var confirmSend = false
    @State private var confirmGateway = false
    @State private var sending = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Review request").font(.headline)
            if let pkg {
                let m = pkg.manifest
                Card {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("This will be shared with ChatGPT").font(.subheadline.weight(.semibold))
                        Text("• Course: \(m.course)\(m.assessment.map { " · \($0)" } ?? "")")
                        if let n = m.includedResponses { Text("• \(n) of your written/code answer(s), with the question, rubric and reference solution") }
                        if !m.skills.isEmpty { Text("• \(m.skills.count) skill name(s): \(m.skills.prefix(6).joined(separator: ", "))\(m.skills.count > 6 ? "…" : "")") }
                        ForEach(m.documents, id: \.title) { Text("• Document text: \($0.title) (\($0.characters) characters\($0.truncated ? ", truncated" : ""))") }
                        if m.documents.isEmpty, m.kind != .grade { Text("• No document text") }
                        if m.kind != .grade, m.kind != .topics { Text("• \(m.existingQuestionTitles) existing question title(s) (to avoid duplicates)") }
                        if m.repairEntries > 0 { Text("• \(m.repairEntries) question(s) to repair") }
                        if m.includesUserNotes { Text("• Your extra guidance note") }
                        ForEach(m.excluded, id: \.self) { Text("✕ " + $0).foregroundStyle(Theme.textSecondary) }
                    }.font(.callout)
                }
                Picker("Transfer", selection: $method) {
                    ForEach(TransferMethod.allCases.filter { $0 != .api }, id: \.self) { t in
                        Text(t == .clipboard ? "Copy to clipboard" : "Export files").tag(t)
                    }
                }.pickerStyle(.segmented)
                Text("Recommended: \(m.recommendedTransfer == .clipboard ? "clipboard" : "files") (\(m.characterCount) characters). \(method == .clipboard && m.recommendedTransfer == .file ? "This is long for one message; ChatGPT may truncate it." : "")")
                    .font(.caption).foregroundStyle(Theme.textSecondary)
                TextEditor(text: .constant(method == .clipboard ? pkg.singlePrompt : pkg.coverPrompt + "\n\nFiles: " + pkg.files.map(\.name).joined(separator: ", ")))
                    .font(.system(.caption, design: .monospaced)).frame(minHeight: 160).fieldSurface()
                if let message { Text(message).font(.callout) }
                HStack {
                    Spacer()
                    Button("Close") { dismiss() }.keyboardShortcut(.cancelAction)
                    if let t = gatewayTarget {
                        Button(sending ? "Sending…" : "Send via \(t.model.displayName)…") { confirmGateway = true }.disabled(sending)
                            .help("Routed by your AI Workflow settings. Usage is tracked in Settings → Usage & Analytics.")
                    } else if model.directAPIEnabled {
                        Button(sending ? "Sending…" : "Send to Anthropic API…") { confirmSend = true }.disabled(sending || !model.hasAPIKey)
                            .help(model.hasAPIKey ? "Sends this request to the Anthropic API" : "Add an API key in Settings first")
                    }
                    if method == .clipboard { Button("Copy to Clipboard") { copy(pkg) }.keyboardShortcut(.defaultAction) }
                    else { Button("Export Files…") { export(pkg) }.keyboardShortcut(.defaultAction) }
                }
                Text("Learn Anyway does not open ChatGPT for you. Paste or attach this yourself, then use Import Response.").font(.caption).foregroundStyle(Theme.textSecondary)
            } else { ProgressView() }
        }
        .padding(Theme.Space.xl).frame(width: 640, height: 640).background(Theme.background)
        .confirmationDialog("Send this request to \(gatewayTarget?.connection.name ?? "the provider")?", isPresented: $confirmGateway, titleVisibility: .visible) {
            Button("Send \(pkg?.manifest.characterCount ?? 0) characters") { sendDirect(viaGateway: true) }
            Button("Cancel", role: .cancel) {}
        } message: { Text(gatewayTarget?.connection.spec?.isLocal == true ? "This stays on this Mac. The reply is checked like a pasted one before anything is saved." : "Everything listed under “This will be shared” leaves your device and may be billed by the provider. The reply is checked like a pasted one before anything is saved.") }
        .confirmationDialog("Send this request to Anthropic?", isPresented: $confirmSend, titleVisibility: .visible) {
            Button("Send \(pkg?.manifest.characterCount ?? 0) characters to \(model.directAPIModel)") { sendDirect() }
            Button("Cancel", role: .cancel) {}
        } message: { Text("Everything listed under “This will be shared” leaves your device and is billed to your API account. The reply is checked like a pasted one before anything is saved.") }
        .task {
            model.perform { pkg = try model.ai?.prepare(batchId: batch.id) }
            method = batch.transferMethod ?? pkg?.recommended ?? .clipboard
        }
    }

    private var gatewayTarget: Target? {
        guard let svc = model.directAI, let gw = model.gateway else { return nil }
        return svc.gatewayTarget(batchId: batch.id, via: gw)
    }

    private func sendDirect(viaGateway: Bool = false) {
        guard let svc = model.directAI else { return }
        sending = true; message = nil
        Task {
            defer { sending = false }
            do {
                let r: AnyImportReport
                if viaGateway, let gw = model.gateway { r = try await svc.send(batchId: batch.id, via: gw) } else { r = try await svc.send(batchId: batch.id) }
                model.reload()
                switch r {
                case .questions(let q): message = q.alreadyImported ? "This reply had already been imported." : "Imported \(q.accepted.count) question(s); \(q.rejected.count) rejected. See the task for details."
                case .grades(let g): message = "\(g.graded.count) answer(s) graded; \(g.rejected.count) not imported."
                case .topics(let t): message = "\(t.items.count) skill(s) proposed. Open the task and choose Review Proposal… before anything changes."
                }
            } catch { message = error.localizedDescription; model.reload() }
        }
    }

    private func copy(_ p: RequestPackage) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(p.singlePrompt, forType: .string)
        model.perform { try model.ai?.markExported(batchId: batch.id, method: .clipboard) }
        message = "Copied. Paste it into ChatGPT, then import the reply."
    }

    private func export(_ p: RequestPackage) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.canCreateDirectories = true
        panel.prompt = "Export Here"; panel.message = "Choose where to create the request folder"
        guard panel.runModal() == .OK, let base = panel.url else { return }
        let folder = base.appendingPathComponent("Braincell-\(batch.requestId.prefix(12))", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try AITaskService.write(p.files, to: folder)
            model.perform { try model.ai?.markExported(batchId: batch.id, method: .file) }
            NSWorkspace.shared.activateFileViewerSelecting([folder])
            message = "Exported \(p.files.count) files. Attach them to your ChatGPT message yourself."
        } catch { model.alertMessage = error.localizedDescription }
    }
}

// MARK: Import

struct ImportSheet: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let target: ImportTarget
    @State private var text = ""
    @State private var report: ImportReport?
    @State private var gradeReport: GradeImportReport?
    @State private var topicBatch: UUID?
    @State private var error: String?
    @State private var picking = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(target.batch.map { "Import response for batch \($0.ordinal + 1)" } ?? "Import response").font(.headline)
            if let topicBatch { TopicReviewView(batchId: topicBatch) { dismiss() } } else if let gradeReport { gradeResults(gradeReport) } else if let report { results(report) } else {
                Text("Paste ChatGPT’s JSON reply (a ```json fence is fine). The requestId inside decides which request it answers.")
                    .font(.caption).foregroundStyle(Theme.textSecondary)
                TextEditor(text: $text).font(.system(.caption, design: .monospaced)).frame(minHeight: 240).fieldSurface()
                if let error { Text(error).foregroundStyle(.red).font(.callout) }
                HStack {
                    Button("Paste from Clipboard") { text = NSPasteboard.general.string(forType: .string) ?? "" }
                    Button("Choose File…") { picking = true }
                    Spacer()
                    Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                    Button("Import", action: run).keyboardShortcut(.defaultAction).disabled(text.trimmed.isEmpty)
                }
            }
        }
        .padding(Theme.Space.xl).frame(width: topicBatch == nil ? 600 : 720, height: topicBatch == nil ? 460 : 580).background(Theme.background)
        .fileImporter(isPresented: $picking, allowedContentTypes: [.json, .plainText]) { r in
            guard case .success(let url) = r else { return }
            let scoped = url.startAccessingSecurityScopedResource(); defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            if let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size > AITaskService.maxResponseBytes { error = "That file is too large."; return }
            text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
            if text.isEmpty { error = "The file couldn’t be read as text." }
        }
    }

    private func run() {
        do {
            switch try model.ai?.importAny(text, targetBatchId: target.batch?.id) {
            case .grades(let g): gradeReport = g
            case .topics(let t): topicBatch = t.batchId
            case .questions(let q): report = q
            case nil: break
            }
            error = nil; model.reload()
        }
        catch { self.error = error.localizedDescription; model.reload() }
    }

    @ViewBuilder private func gradeResults(_ r: GradeImportReport) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                if r.alreadyImported { Label("These grades were already imported — nothing changed.", systemImage: "checkmark.circle").foregroundStyle(Theme.accent) }
                else {
                    Label("\(r.graded.count) answer(s) graded", systemImage: "checkmark.circle.fill").foregroundStyle(Theme.mastery)
                    Text("Grades from ChatGPT are stored as a separate evaluation of each original attempt. You can dispute or replace any of them later.").font(.callout)
                }
                if !r.rejected.isEmpty {
                    Label("\(r.rejected.count) not imported — those answers stay pending (not wrong)", systemImage: "xmark.octagon").foregroundStyle(Theme.attention)
                    ForEach(Array(r.rejected.enumerated()), id: \.offset) { _, e in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(e.attemptId ?? "(no attemptId)").font(.caption.monospaced())
                            ForEach(e.issues, id: \.self) { Text("• " + $0).font(.caption) }
                        }
                    }
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
        HStack { Spacer(); Button("Done") { dismiss() }.keyboardShortcut(.defaultAction) }
    }

    @ViewBuilder private func results(_ r: ImportReport) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                if r.alreadyImported {
                    Label("This response was already imported — nothing changed.", systemImage: "checkmark.circle").foregroundStyle(Theme.accent)
                } else {
                    Label("\(r.accepted.count) question(s) added", systemImage: "checkmark.circle.fill").foregroundStyle(Theme.mastery)
                    let review = r.accepted.filter { $0.readiness == .needsReview }.count
                    if review > 0 { Label("\(review) need review", systemImage: "exclamationmark.triangle").foregroundStyle(Theme.attention) }
                    if !r.duplicates.isEmpty { Text("\(r.duplicates.count) skipped as exact duplicates: " + r.duplicates.joined(separator: ", ")).font(.callout) }
                }
                if !r.rejected.isEmpty {
                    Label("\(r.rejected.count) rejected — create a repair request from the task page", systemImage: "xmark.octagon").foregroundStyle(Theme.attention)
                    ForEach(r.rejected, id: \.index) { e in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(e.title ?? e.importId).font(.headline)
                            ForEach(e.issues, id: \.self) { Text("• " + $0.description).font(.caption) }
                        }
                    }
                }
                switch r.batchStatus {
                case .incomplete: Text("Fewer questions than requested came back. You can create a continuation request.").font(.callout)
                case .imported: EmptyView()
                default: EmptyView()
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
        HStack { Spacer(); Button("Done") { dismiss() }.keyboardShortcut(.defaultAction) }
    }
}

// MARK: New task

struct NewTaskSheet: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let request: GenerateRequest?
    var onCreate: (UUID) -> Void

    @State private var courseId: UUID?
    @State private var assessmentId: UUID?
    @State private var count = 10
    @State private var types: Set<QuestionType> = []
    @State private var minD = 1
    @State private var maxD = 5
    @State private var allSkills: [Skill] = []
    @State private var skillIds: Set<UUID> = []
    @State private var docs: [Document] = []
    @State private var docIds: Set<UUID> = []
    @State private var assessments: [Assessment] = []
    @State private var notes = ""
    @State private var includeExisting = true

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("New generation task").font(.headline)
            ScrollView {
                Form {
                    Picker("Course", selection: $courseId) {
                        Text("Choose…").tag(UUID?.none)
                        ForEach(model.courseList) { Text($0.name).tag(UUID?.some($0.id)) }
                    }
                    Picker("Assessment", selection: $assessmentId) {
                        Text("None").tag(UUID?.none)
                        ForEach(assessments) { Text($0.name).tag(UUID?.some($0.id)) }
                    }
                    Stepper("Questions: \(count)  (sent in batches of \(AITaskService.maxQuestionsPerBatch))", value: $count, in: 1...100)
                    Stepper("Min difficulty \(minD)", value: $minD, in: 1...maxD)
                    Stepper("Max difficulty \(maxD)", value: $maxD, in: minD...5)
                    Section("Question types (none = any mix)") {
                        ForEach(QuestionType.allCases, id: \.self) { t in
                            Toggle(t.label, isOn: Binding(get: { types.contains(t) }, set: { if $0 { types.insert(t) } else { types.remove(t) } }))
                        }
                    }
                    Section("Skills (none selected = assessment scope, else whole course)") {
                        ForEach(allSkills) { s in Toggle(s.name, isOn: Binding(get: { skillIds.contains(s.id) }, set: { if $0 { skillIds.insert(s.id) } else { skillIds.remove(s.id) } })) }
                    }
                    Section("Include text from documents (only checked ones are shared)") {
                        if docs.isEmpty { Text("No documents imported for this course").foregroundStyle(Theme.textSecondary) }
                        ForEach(docs) { d in Toggle(d.title, isOn: Binding(get: { docIds.contains(d.id) }, set: { if $0 { docIds.insert(d.id) } else { docIds.remove(d.id) } })) }
                    }
                    Toggle("Include existing question titles (avoids duplicates)", isOn: $includeExisting)
                    TextField("Extra guidance (optional)", text: $notes)
                }.formStyle(.grouped).scrollContentBackground(.hidden)
            }
            HStack { Spacer(); Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Create Task", action: create).keyboardShortcut(.defaultAction).disabled(courseId == nil) }
        }
        .padding(Theme.Space.xl).frame(width: 520, height: 640).background(Theme.background)
        .onAppear {
            courseId = request?.courseId ?? model.selectedCourseID ?? model.courseList.first?.id
            skillIds = Set(request?.skillIds ?? []); notes = request?.notes ?? ""
            if request != nil { count = 5 }
            loadCourse()
        }
        .onChange(of: courseId) { _, _ in assessmentId = nil; if request == nil { skillIds = [] }; docIds = []; loadCourse() }
    }

    private func loadCourse() {
        guard let c = courseId else { return }
        allSkills = (try? model.courses?.skills(courseId: c)) ?? []
        assessments = (try? model.courses?.assessments(courseId: c)) ?? []
        docs = (try? model.documents?.documents(courseId: c)) ?? []
    }

    private func create() {
        guard let c = courseId else { return }
        let p = GenerationParams(count: count, types: QuestionType.allCases.filter(types.contains), minDifficulty: minD, maxDifficulty: maxD,
                                 skillIds: Array(skillIds), documentIds: Array(docIds), includeExistingTitles: includeExisting, notes: notes)
        model.perform { if let t = try model.ai?.createGenerationTask(courseId: c, assessmentId: assessmentId, params: p) { onCreate(t.id) } }
        dismiss()
    }
}

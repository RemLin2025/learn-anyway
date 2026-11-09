import SwiftUI
import BraincellCore

private let defaultNodeId = VisualNode.defaultId

/// AI Workflow page: compact toolbar, a cached canvas that owns most of the space, and an inspector beside it.
struct AIWorkflowView: View {
    @ObservedObject var cfg: AIConfig
    @StateObject private var state: WorkflowState
    @State private var vp = Viewport()      // @State, not @StateObject: the page must NOT re-render on every pan/zoom tick
    @State private var confirmResetAll = false
    @State private var showLegend = false

    init(cfg: AIConfig) { self.cfg = cfg; _state = StateObject(wrappedValue: WorkflowState(cfg: cfg)) }

    var body: some View {
        AIPage(title: "AI Workflow", compact: true) {
            HStack(spacing: 0) {
                VStack(spacing: 0) {
                    ViewThatFits(in: .horizontal) { fullBar; compactBar }
                        .padding(.horizontal, Theme.Space.lg).frame(height: 48).controlSize(.small)
                    Divider()
                    WorkflowCanvas(state: state, vp: vp)
                }
                if let s = state.selected {
                    Divider()
                    ScrollView {
                        inspector(s).padding(Theme.Space.lg).frame(maxWidth: .infinity, alignment: .leading)
                    }.frame(width: 340).background(Theme.surface)
                }
            }
        }
        // Wait a beat so the inspector has resized the canvas before deciding whether the node is on screen.
        .task(id: "\(state.selected ?? "")-\(state.layout.nodeIndex.count)") {
            try? await Task.sleep(nanoseconds: 80_000_000)
            if let s = state.selected, let n = state.layout.node(s) { vp.reveal(n.rect) }
        }
        .confirmationDialog("Reset every task to follow the default?", isPresented: $confirmResetAll, titleVisibility: .visible) {
            Button("Reset all tasks", role: .destructive) { try? cfg.gw.store.resetAllRoutes(); cfg.reload() }
            Button("Cancel", role: .cancel) {}
        } message: { Text("Custom models, fallbacks, prompts and manual-bridge choices for every task are removed. Provider connections and defaults are kept.") }
    }

    // MARK: Toolbar

    private var picker: some View {
        Picker("Task", selection: Binding(get: { state.selected ?? "" }, set: { state.select($0.isEmpty ? nil : $0) })) {
            Text("Select a task…").tag("")
            Text("Default Model").tag(defaultNodeId)
            ForEach(TaskGroup.allCases, id: \.self) { g in
                Section(g.rawValue) {
                    Text(g.rawValue).tag(VisualNode.groupId(g))
                    ForEach(state.tasks(in: g)) { Text($0.title).tag($0.id) }
                }
            }
        }.labelsHidden().frame(width: 230).accessibilityLabel("Select a task")
    }

    private var fullBar: some View {
        HStack(spacing: 10) {
            picker
            Button("Expand all") { state.setAll(true) }.lineLimit(1).fixedSize()
            Button("Collapse all") { state.setAll(false) }.lineLimit(1).fixedSize()
            Spacer(minLength: 12)
            Toggle("Dependencies", isOn: $state.showDeps).toggleStyle(.checkbox).lineLimit(1).fixedSize()
            Button { showLegend.toggle() } label: { Image(systemName: "info.circle") }.help("Connection legend").accessibilityLabel("Connection legend")
                .popover(isPresented: $showLegend, arrowEdge: .bottom) { legend }
            Button("Reset layout") { state.resetLayout(); vp.fit(state.fitRect(viewport: vp.size)) }.lineLimit(1).fixedSize()
            Menu { Button("Reset all tasks…", role: .destructive) { confirmResetAll = true } } label: { Image(systemName: "ellipsis.circle") }
                .menuStyle(.borderlessButton).fixedSize().accessibilityLabel("More")
        }
    }

    private var compactBar: some View {
        HStack(spacing: 10) {
            picker
            Spacer(minLength: 8)
            Menu {
                Button("Expand all") { state.setAll(true) }
                Button("Collapse all") { state.setAll(false) }
                Toggle("Show dependencies", isOn: $state.showDeps)
                Button("Reset layout") { state.resetLayout(); vp.fit(state.fitRect(viewport: vp.size)) }
                Button("Connection legend") { showLegend = true }
                Divider()
                Button("Reset all tasks…", role: .destructive) { confirmResetAll = true }
            } label: { Label("Options", systemImage: "ellipsis.circle") }.menuStyle(.borderlessButton).fixedSize()
                .popover(isPresented: $showLegend, arrowEdge: .bottom) { legend }
        }
    }

    private var legend: some View {
        VStack(alignment: .leading, spacing: Theme.Space.md) {
            legendRow("Model inheritance", "The task uses the default model.", dash: false, color: Theme.accent)
            legendRow("Workflow dependency", "The task needs another task’s output.", dash: true, color: Theme.textSecondary)
            legendRow("Selected task", "Its direct connections; the rest fade.", dash: false, color: Theme.accent, thick: true)
            Text("Tasks with their own model setting don’t follow the default, so they have no purple line.").font(Theme.meta).foregroundStyle(Theme.textSecondary).frame(width: 260, alignment: .leading)
        }.padding(Theme.Space.lg)
    }
    private func legendRow(_ t: String, _ d: String, dash: Bool, color: Color, thick: Bool = false) -> some View {
        HStack(alignment: .top, spacing: Theme.Space.md) {
            Path { p in p.move(to: CGPoint(x: 0, y: 6)); p.addLine(to: CGPoint(x: 34, y: 6)) }.stroke(color, style: StrokeStyle(lineWidth: thick ? 2.4 : 1.6, dash: dash ? [5, 4] : [])).frame(width: 34, height: 12)
            VStack(alignment: .leading, spacing: 1) { Text(t).font(.system(.callout, design: .rounded, weight: .semibold)); Text(d).font(Theme.meta).foregroundStyle(Theme.textSecondary) }
        }
    }

    // MARK: Inspector

    @ViewBuilder private func inspector(_ s: String) -> some View {
        HStack { Spacer(); Button { state.select(nil) } label: { Image(systemName: "xmark") }.buttonStyle(.plain).foregroundStyle(Theme.textSecondary).accessibilityLabel("Close inspector") }
        if s == defaultNodeId { DefaultInspector(cfg: cfg).id(s) }
        else if let g = TaskGroup.allCases.first(where: { VisualNode.groupId($0) == s }) { GroupInspector(cfg: cfg, state: state, group: g).id(s) }
        else if let t = WorkflowTask.find(s) { TaskInspector(cfg: cfg, state: state, task: t).id(s) }
    }
}

private struct GroupInspector: View {
    @ObservedObject var cfg: AIConfig
    @ObservedObject var state: WorkflowState
    let group: TaskGroup
    var body: some View {
        let ts = state.tasks(in: group)
        let ready = ts.filter { cfg.resolution($0).isReady }.count
        VStack(alignment: .leading, spacing: Theme.Space.md) {
            Label(group.rawValue, systemImage: WorkflowState.symbol(group)).font(Theme.sectionTitle)
            Text("\(ts.count) tasks · \(ready) configured").foregroundStyle(Theme.textSecondary)
            MeterBar(value: Double(ready) / Double(max(1, ts.count)), tint: ready == ts.count ? Theme.mastery : Theme.accent)
            Button(state.expanded.contains(group) ? "Collapse category" : "Expand category") { state.toggle(group) }
            Text("Collapsing only hides the tasks on the canvas. Their settings and how requests are routed don’t change.").font(Theme.meta).foregroundStyle(Theme.textSecondary)
            Divider()
            ForEach(ts) { t in
                let r = cfg.resolution(t)
                Button { state.select(t.id) } label: {
                    HStack(spacing: Theme.Space.sm) {
                        Image(systemName: t.capability.symbol).frame(width: 20).foregroundStyle(Theme.accent)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(t.title).font(.system(.callout, design: .rounded, weight: .medium))
                            Text(r.manual ? "Manual ChatGPT Bridge" : r.primary.map { $0.model.displayName } ?? (ProviderRegistry.all.contains { $0.supports(t.capability) } ? "Not configured" : "No adapter yet")).font(Theme.meta).foregroundStyle(Theme.textSecondary).lineLimit(1)
                        }
                        Spacer()
                        Circle().fill(r.isReady ? Theme.mastery : Theme.textSecondary.opacity(0.5)).frame(width: 8, height: 8)
                    }.contentShape(Rectangle())
                }.buttonStyle(.plain)
            }
        }
    }
}

// MARK: Inspectors

private struct DefaultInspector: View {
    @ObservedObject var cfg: AIConfig
    @State private var preset: Preset?
    @State private var changes: [PlannedChange] = []

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.md) {
            Label("Default Model", systemImage: "sparkles").font(Theme.sectionTitle)
            Text("Every text task without its own setting uses this model.").foregroundStyle(Theme.textSecondary)
            let ms = cfg.connections.filter { $0.enabled && $0.spec?.supports(.llm) == true }
            if ms.isEmpty { Notice(text: "No LLM provider is connected. Open AI Provider Plans or Model Services to add one.", tint: Theme.attention, symbol: "exclamationmark.triangle") }
            ModelPicker(cfg: cfg, cap: .llm, connection: Binding(get: { cfg.defaults[.llm]?.connectionId }, set: { c in if let c, let m = cfg.models(cfg.connection(c)!, .llm).first { cfg.setDefault(.llm, cfg.connection(c)!, m.modelId) } }),
                        model: Binding(get: { cfg.defaults[.llm]?.modelId }, set: { m in if let m, let c = cfg.defaults[.llm].flatMap({ cfg.connection($0.connectionId) }) { cfg.setDefault(.llm, c, m) } }), allowNone: false)
            Divider()
            Text("Presets").font(Theme.cardTitle)
            ForEach(Preset.allCases) { p in
                Button { preset = p; changes = (try? PresetPlanner(store: cfg.gw.store).plan(p)) ?? [] } label: {
                    VStack(alignment: .leading, spacing: 2) { Text(p.rawValue).font(.system(.body, design: .rounded, weight: .semibold)); Text(p.summary).font(Theme.meta).foregroundStyle(Theme.textSecondary) }.frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            Text("Presets rank only models that exist now, by price you or the provider have recorded. Nothing changes until you confirm.").font(Theme.meta).foregroundStyle(Theme.textSecondary)
        }
        .sheet(item: $preset) { p in
            VStack(alignment: .leading, spacing: Theme.Space.md) {
                Text("Apply “\(p.rawValue)”?").font(Theme.sectionTitle)
                if changes.isEmpty { Text("Nothing would change. Either it’s already applied, or no usable model has a recorded price yet. Add prices in Model Services.").foregroundStyle(Theme.textSecondary) }
                ForEach(changes) { c in VStack(alignment: .leading, spacing: 2) { Text(c.title).font(Theme.cardTitle); Text("\(c.from)  →  \(c.to)").font(.callout).foregroundStyle(Theme.textSecondary) } }
                HStack { Spacer(); Button("Cancel") { preset = nil }.keyboardShortcut(.cancelAction)
                    Button("Apply") { try? PresetPlanner(store: cfg.gw.store).apply(changes); cfg.reload(); preset = nil }.buttonStyle(.primary).disabled(changes.isEmpty).keyboardShortcut(.defaultAction) }
            }.dialogSurface(width: 480)
        }
    }
}

struct ModelPicker: View {
    @ObservedObject var cfg: AIConfig
    let cap: Capability
    @Binding var connection: UUID?
    @Binding var model: String?
    var allowNone = true
    var body: some View {
        let conns = cfg.connections.filter { $0.enabled && $0.spec?.supports(cap) == true && !cfg.models($0, cap).isEmpty }
        if conns.isEmpty { Text("No \(cap.label) models are available. \(ProviderRegistry.all.contains { $0.supports(cap) } ? "Connect a provider in Model Services." : "No adapter for \(cap.label) exists in this build yet.")").font(.callout).foregroundStyle(Theme.textSecondary) }
        else {
            Picker("Provider", selection: $connection) {
                if allowNone { Text("None").tag(UUID?.none) }
                ForEach(conns) { Text($0.name).tag(UUID?.some($0.id)) }
            }
            if let c = cfg.connection(connection) {
                Picker("Model", selection: $model) { ForEach(cfg.models(c, cap)) { Text($0.displayName).tag(String?.some($0.modelId)) } }
            }
        }
    }
}

private struct TaskInspector: View {
    @ObservedObject var cfg: AIConfig
    let state: WorkflowState
    let task: WorkflowTask
    @State private var route: TaskRoute
    @State private var confirmReset = false

    init(cfg: AIConfig, state: WorkflowState, task: WorkflowTask) {
        self.cfg = cfg; self.state = state; self.task = task; _route = State(initialValue: cfg.route(task))
    }
    private func commit() { cfg.save(route) }

    /// Plain-language reading of this node's lines on the canvas.
    private var connections: some View {
        let res = cfg.resolution(task)
        let feeds = WorkflowTask.all.filter { $0.dependsOn.contains(task.id) }
        return VStack(alignment: .leading, spacing: 4) {
            Text("Connections").font(Theme.cardTitle)
            if task.capability == .llm {
                Label(route.manualBridge ? "Not connected to the default: uses the manual ChatGPT Bridge." : (res.inherited ? "Purple line: follows the Default Model." : "No purple line: this task has its own model setting."), systemImage: "line.diagonal").font(Theme.meta).foregroundStyle(Theme.textSecondary)
            } else { Label("Uses the \(task.capability.label) default, not the LLM default.", systemImage: "line.diagonal").font(Theme.meta).foregroundStyle(Theme.textSecondary) }
            if !task.dependsOn.isEmpty { Label("Dashed line: needs output of \(task.dependsOn.compactMap { WorkflowTask.find($0)?.title }.joined(separator: ", ")).", systemImage: "arrow.down.right").font(Theme.meta).foregroundStyle(Theme.textSecondary) }
            if !feeds.isEmpty { Label("Dashed line: feeds \(feeds.map(\.title).joined(separator: ", ")).", systemImage: "arrow.up.right").font(Theme.meta).foregroundStyle(Theme.textSecondary) }
            if task.dependsOn.isEmpty && feeds.isEmpty { Text("No workflow dependencies.").font(Theme.meta).foregroundStyle(Theme.textSecondary) }
        }
    }

    var body: some View {
        let res = cfg.resolution(task)
        let llm = task.capability == .llm
        VStack(alignment: .leading, spacing: Theme.Space.md) {
            Label(task.title, systemImage: task.capability.symbol).font(Theme.sectionTitle)
            Text(task.summary).foregroundStyle(Theme.textSecondary)
            HStack { Badge(text: task.capability.label); if task.optional { Badge(text: "Optional stage", color: Theme.textSecondary) } }
            connections

            if llm {
                Toggle("Use the manual ChatGPT Bridge", isOn: Binding(get: { route.manualBridge }, set: { route.manualBridge = $0; commit() }))
                Text(route.manualBridge ? "Requests for this task pause until you copy them into ChatGPT yourself and import the reply. Nothing is sent automatically and nothing is counted as API usage." : "Optional. Keeps this task on your ChatGPT subscription, manually.").font(Theme.meta).foregroundStyle(Theme.textSecondary)
            }
            if !route.manualBridge {
                Toggle("Follow the \(task.capability.label) default", isOn: Binding(get: { route.inherit }, set: { on in
                    route.inherit = on
                    if !on, route.connectionId == nil, let c = cfg.connections.first(where: { $0.enabled && $0.spec?.supports(task.capability) == true && !cfg.models($0, task.capability).isEmpty }) {
                        route.connectionId = c.id; route.modelId = cfg.models(c, task.capability).first?.modelId
                    }
                    commit()
                }))
                if !route.inherit {
                    ModelPicker(cfg: cfg, cap: task.capability, connection: Binding(get: { route.connectionId }, set: { route.connectionId = $0; route.modelId = $0.flatMap { cfg.connection($0) }.flatMap { cfg.models($0, task.capability).first?.modelId }; commit() }),
                                model: Binding(get: { route.modelId }, set: { route.modelId = $0; commit() }))
                }
                Text("Fallback (optional)").font(Theme.cardTitle)
                ModelPicker(cfg: cfg, cap: task.capability, connection: Binding(get: { route.fallbackConnectionId }, set: { route.fallbackConnectionId = $0; route.fallbackModelId = $0.flatMap { cfg.connection($0) }.flatMap { cfg.models($0, task.capability).first?.modelId }; commit() }),
                            model: Binding(get: { route.fallbackModelId }, set: { route.fallbackModelId = $0; commit() }))
                Stepper("Retries on temporary errors: \(route.maxRetries)", value: Binding(get: { route.maxRetries }, set: { route.maxRetries = $0; commit() }), in: 0...3)
                Stepper("Timeout: \(route.timeoutSeconds) s", value: Binding(get: { route.timeoutSeconds }, set: { route.timeoutSeconds = $0; commit() }), in: 10...600, step: 10)
                Text("Retries only cover rate limits, timeouts and server errors, never bad keys or budget blocks. The ceiling is 3.").font(Theme.meta).foregroundStyle(Theme.textSecondary)
            }
            if llm && !route.manualBridge {
                Toggle("Custom temperature", isOn: Binding(get: { route.temperature != nil }, set: { route.temperature = $0 ? 0.7 : nil; commit() }))
                if let t = route.temperature { Slider(value: Binding(get: { t }, set: { route.temperature = $0 }), in: 0...2, onEditingChanged: { if !$0 { commit() } }); Text(String(format: "%.1f", t)).font(Theme.meta) }
                Toggle("Limit output tokens", isOn: Binding(get: { route.maxTokens != nil }, set: { route.maxTokens = $0 ? 4096 : nil; commit() }))
                if let m = route.maxTokens { Stepper("\(m) tokens", value: Binding(get: { m }, set: { route.maxTokens = $0; commit() }), in: 256...32768, step: 256) }
                Text("Instruction (added as a system prompt)").font(Theme.cardTitle)
                TextEditor(text: Binding(get: { route.instruction ?? "" }, set: { route.instruction = $0.isEmpty ? nil : $0 })).font(.callout).frame(height: 80).fieldSurface().onSubmit(commit)
                Button("Save instruction") { commit() }
            }
            if !llm { Notice(text: "\(task.capability.label) has no working adapter in this build, so this task can’t run yet. Its status stays “Not available yet”.", tint: Theme.attention, symbol: "exclamationmark.triangle") }
            Divider()
            Text("Why this model").font(Theme.cardTitle)
            ForEach(Array(res.trace.enumerated()), id: \.offset) { Text("• " + $0.element).font(Theme.meta).foregroundStyle(Theme.textSecondary) }
            if let p = res.problem { Text(p).font(.callout).foregroundStyle(Theme.attention) }
            if let e = cfg.error { Text(e).font(Theme.meta).foregroundStyle(Theme.error) } else if let m = cfg.message { Text(m).font(Theme.meta).foregroundStyle(Theme.mastery) }
            HStack {
                Button("Test node") { if let p = res.primary { cfg.test(p) } }.disabled(res.primary == nil || !llm || cfg.busy.contains("test-\(res.primary?.model.id.uuidString ?? "")"))
                    .help(llm ? "Sends one tiny request to the resolved model" : "No adapter for this capability yet")
                Button("Reset to default…") { confirmReset = true }
            }
        }
        .confirmationDialog("Reset \(task.title)?", isPresented: $confirmReset, titleVisibility: .visible) {
            Button("Reset", role: .destructive) { cfg.reset(task.id); route = TaskRoute(task: task.id) }
            Button("Cancel", role: .cancel) {}
        } message: { Text("Its own model, fallback, prompt and manual-bridge setting are removed; it follows the default again.") }
    }
}

import SwiftUI
import BraincellCore

private let defaultNodeId = "default.llm"
private let nodeSize = CGSize(width: 184, height: 76)

/// What a node shows, computed from the real router so the canvas can never disagree with what requests actually use.
struct NodeInfo: Equatable {
    var model: String; var provider: String; var mode: String; var ready: Bool; var manual: Bool; var unavailable: Bool
}

struct AIWorkflowView: View {
    @ObservedObject var cfg: AIConfig
    @State private var positions: [String: CGPoint] = [:]
    @State private var infos: [String: NodeInfo] = [:]
    @State private var scale: CGFloat = 0.75
    @State private var pan: CGSize = .zero
    @State private var panStart: CGSize?
    @State private var magBase: CGFloat?
    @State private var selected: String?
    @State private var showDeps = false
    @State private var viewport: CGSize = .zero
    @State private var dragStart: [String: CGPoint] = [:]
    @State private var confirmResetAll = false

    private static func defaultLayout() -> [String: CGPoint] {
        var out: [String: CGPoint] = [defaultNodeId: CGPoint(x: 560, y: 60)]
        var y: CGFloat = 220
        for g in TaskGroup.allCases {
            let tasks = WorkflowTask.all.filter { $0.group == g }
            for (i, t) in tasks.enumerated() { out[t.id] = CGPoint(x: 120 + CGFloat(i % 6) * 214, y: y + CGFloat(i / 6) * 110) }
            y += CGFloat((tasks.count + 5) / 6) * 110 + 50
        }
        return out
    }
    private var canvasSize: CGSize {
        let xs = positions.values.map(\.x), ys = positions.values.map(\.y)
        return CGSize(width: (xs.max() ?? 800) + 200, height: (ys.max() ?? 600) + 120)
    }
    private func pos(_ id: String) -> CGPoint { positions[id] ?? Self.defaultLayout()[id] ?? .zero }

    var body: some View {
        AIPage(title: "AI Workflow", subtitle: "Choose which model handles each learning task. Tasks that follow the default change when you change it.") {
            HStack(spacing: 0) {
                VStack(spacing: 0) {
                    toolbar
                    canvas
                }
                if let s = selected {
                    Divider()
                    ScrollView {
                        Group {
                            if s == defaultNodeId { DefaultInspector(cfg: cfg).id(s) }
                            else if let t = WorkflowTask.find(s) { TaskInspector(cfg: cfg, task: t, onReset: refresh).id(s) }
                        }.padding(Theme.Space.lg)
                    }.frame(width: 340).background(Theme.surface)
                }
            }
        }
        .task(id: cfg.rev) { refresh() }
        .onAppear { positions = Self.defaultLayout().merging(((try? cfg.gw.store.layout()) ?? [:]).mapValues { CGPoint(x: $0.x, y: $0.y) }) { $1 } }
        .confirmationDialog("Reset every task to follow the default?", isPresented: $confirmResetAll, titleVisibility: .visible) {
            Button("Reset all tasks", role: .destructive) { try? cfg.gw.store.resetAllRoutes(); cfg.reload() }
            Button("Cancel", role: .cancel) {}
        } message: { Text("Custom models, fallbacks, prompts and manual-bridge choices for every task are removed. Provider connections and defaults are kept.") }
    }

    // MARK: Info

    private func refresh() {
        var out: [String: NodeInfo] = [:]
        let d = cfg.defaults[.llm]
        let dc = d.flatMap { cfg.connection($0.connectionId) }
        out[defaultNodeId] = NodeInfo(model: d?.modelId ?? "Not set", provider: dc?.name ?? "No LLM provider connected", mode: "Parts following it: \(WorkflowTask.all.filter { $0.capability == .llm && (cfg.routes[$0.id]?.inherit ?? true) && cfg.routes[$0.id]?.manualBridge != true }.count)", ready: d != nil, manual: false, unavailable: false)
        for t in WorkflowTask.all {
            let r = cfg.resolution(t); let route = cfg.routes[t.id]
            let supported = ProviderRegistry.all.contains { $0.supports(t.capability) }
            if r.manual { out[t.id] = NodeInfo(model: "Manual ChatGPT Bridge", provider: "You copy and import", mode: "Own setting", ready: true, manual: true, unavailable: false) }
            else if let p = r.primary { out[t.id] = NodeInfo(model: p.model.displayName, provider: p.connection.name, mode: r.inherited ? "Follows default" : "Own setting", ready: true, manual: false, unavailable: false) }
            else { out[t.id] = NodeInfo(model: supported ? "Not set" : "Not available yet", provider: supported ? "" : "No \(t.capability.label) adapter", mode: route?.inherit == false ? "Own setting" : "Follows default", ready: false, manual: false, unavailable: !supported) }
        }
        infos = out
    }

    // MARK: Toolbar

    private var toolbar: some View {
        HStack(spacing: Theme.Space.md) {
            Picker("Task", selection: Binding(get: { selected ?? "" }, set: { selected = $0.isEmpty ? nil : $0 })) {
                Text("Select a task…").tag("")
                Text("Default Model").tag(defaultNodeId)
                ForEach(TaskGroup.allCases, id: \.self) { g in Section(g.rawValue) { ForEach(WorkflowTask.all.filter { $0.group == g }) { Text($0.title).tag($0.id) } } }
            }.frame(width: 240).accessibilityLabel("Select a task")
            Toggle("Show dependencies", isOn: $showDeps).toggleStyle(.checkbox)
            Spacer()
            legend
            Button("Reset layout") { try? cfg.gw.store.resetLayout(); positions = Self.defaultLayout(); fit() }
            Button("Reset all tasks…", role: .destructive) { confirmResetAll = true }
        }.padding(.horizontal, Theme.Space.lg).padding(.vertical, Theme.Space.sm)
    }

    private var legend: some View {
        HStack(spacing: Theme.Space.md) {
            HStack(spacing: 5) { Rectangle().fill(Theme.accent).frame(width: 22, height: 2); Text("Follows default") }
            HStack(spacing: 5) { Line().stroke(Theme.textSecondary, style: StrokeStyle(lineWidth: 1.5, dash: [4, 3])).frame(width: 22, height: 2); Text("Own setting") }
            HStack(spacing: 5) { Image(systemName: "arrow.right").font(.caption2); Text("Needs output of") }
        }.font(Theme.meta).foregroundStyle(Theme.textSecondary)
    }

    // MARK: Canvas

    private var canvas: some View {
        GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                DotGrid(scale: scale, offset: pan).accessibilityHidden(true)
                ZStack(alignment: .topLeading) {
                    Canvas { ctx, _ in drawEdges(ctx) }.frame(width: canvasSize.width, height: canvasSize.height).allowsHitTesting(false)
                    ForEach(TaskGroup.allCases, id: \.self) { g in
                        let pts = WorkflowTask.all.filter { $0.group == g }.map { pos($0.id) }
                        if let minY = pts.map(\.y).min(), let minX = pts.map(\.x).min() {
                            Text(g.rawValue.uppercased()).font(.system(size: 11, weight: .semibold, design: .rounded)).tracking(0.8).foregroundStyle(Theme.textSecondary)
                                .frame(width: 300, alignment: .leading).position(x: minX - nodeSize.width / 2 + 150, y: minY - nodeSize.height / 2 - 14)
                        }
                    }
                    nodeLayer(defaultNodeId, title: "Default Model", symbol: "sparkles", sub: nil)
                    ForEach(WorkflowTask.all) { t in nodeLayer(t.id, title: t.title, symbol: t.capability.symbol, sub: t.capability == .llm ? nil : t.capability.label) }
                }
                .frame(width: canvasSize.width, height: canvasSize.height, alignment: .topLeading)
                .scaleEffect(scale, anchor: .topLeading).offset(pan)
                controls.padding(Theme.Space.md).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
            }
            .contentShape(Rectangle())
            .gesture(DragGesture().onChanged { v in let s = panStart ?? pan; panStart = s; pan = CGSize(width: s.width + v.translation.width, height: s.height + v.translation.height) }.onEnded { _ in panStart = nil })
            .onTapGesture(count: 2) { fit() }
            .onTapGesture { selected = nil }
            .gesture(MagnifyGesture().onChanged { v in let b = magBase ?? scale; magBase = b; scale = min(2, max(0.25, b * v.magnification)) }.onEnded { _ in magBase = nil })
            .onAppear { viewport = geo.size; DispatchQueue.main.async { fit() } }
            .onChange(of: geo.size) { _, s in viewport = s }
            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card))
            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.card).strokeBorder(Theme.border))
            .padding(Theme.Space.lg)
        }
    }

    private var controls: some View {
        HStack(spacing: Theme.Space.sm) {
            Button { zoom(0.85) } label: { Image(systemName: "minus") }.accessibilityLabel("Zoom out")
            Text("\(Int(scale * 100))%").font(.system(.callout, design: .rounded)).monospacedDigit().frame(width: 44)
            Button { zoom(1.18) } label: { Image(systemName: "plus") }.accessibilityLabel("Zoom in")
            Button { fit() } label: { Image(systemName: "arrow.up.left.and.down.right.magnifyingglass") }.accessibilityLabel("Fit to view").help("Fit to view (or double-click empty space)")
            Text("Drag to pan · drag nodes to rearrange").font(Theme.meta).foregroundStyle(Theme.textSecondary).padding(.leading, Theme.Space.sm)
        }.padding(Theme.Space.sm).background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.control)).overlay(RoundedRectangle(cornerRadius: Theme.Radius.control).strokeBorder(Theme.border))
    }

    private func zoom(_ f: CGFloat) { scale = min(2, max(0.25, scale * f)) }
    private func fit() {
        guard viewport.width > 0 else { return }
        let s = min(viewport.width / canvasSize.width, viewport.height / canvasSize.height, 1.2) * 0.95
        scale = max(0.25, s); pan = CGSize(width: (viewport.width - canvasSize.width * scale) / 2, height: 8)
    }

    private func nodeLayer(_ id: String, title: String, symbol: String, sub: String?) -> some View {
        let info = infos[id]
        return NodeCard(title: title, symbol: symbol, info: info, selected: selected == id, isDefault: id == defaultNodeId)
            .frame(width: nodeSize.width, height: nodeSize.height)
            .position(pos(id))
            .gesture(DragGesture(minimumDistance: 3).onChanged { v in
                let s = dragStart[id] ?? pos(id); dragStart[id] = s
                positions[id] = CGPoint(x: s.x + v.translation.width / scale, y: s.y + v.translation.height / scale)
            }.onEnded { _ in
                dragStart[id] = nil; let p = pos(id); try? cfg.gw.store.save(LayoutPoint(task: id, x: p.x, y: p.y))
            })
            .onTapGesture { selected = id }
            .accessibilityElement(children: .combine).accessibilityAddTraits(.isButton).accessibilityAction { selected = id }
            .accessibilityLabel("\(title). \(info?.model ?? "") \(info?.provider ?? ""). \(info?.mode ?? "")")
    }

    private func drawEdges(_ ctx: GraphicsContext) {
        func edge(_ a: CGPoint, _ b: CGPoint, _ color: Color, width: CGFloat, dash: [CGFloat] = [], arrow: Bool = false) {
            var p = Path(); let s = CGPoint(x: a.x, y: a.y + nodeSize.height / 2), e = CGPoint(x: b.x, y: b.y - nodeSize.height / 2)
            let dy = max(30, abs(e.y - s.y) / 2)
            p.move(to: s); p.addCurve(to: e, control1: CGPoint(x: s.x, y: s.y + dy), control2: CGPoint(x: e.x, y: e.y - dy))
            ctx.stroke(p, with: .color(color), style: StrokeStyle(lineWidth: width, lineCap: .round, dash: dash))
            if arrow { var h = Path(); h.move(to: CGPoint(x: e.x - 4, y: e.y - 7)); h.addLine(to: e); h.addLine(to: CGPoint(x: e.x + 4, y: e.y - 7)); ctx.stroke(h, with: .color(color), lineWidth: width) }
        }
        let d = pos(defaultNodeId)
        for t in WorkflowTask.all where t.capability == .llm {
            let own = !(cfg.routes[t.id]?.inherit ?? true) || cfg.routes[t.id]?.manualBridge == true
            edge(d, pos(t.id), own ? Theme.textSecondary.opacity(0.7) : Theme.accent.opacity(selected == t.id ? 1 : 0.3), width: own ? 1.4 : 1.2, dash: own ? [5, 4] : [])
        }
        if showDeps {
            for t in WorkflowTask.all { for dep in t.dependsOn where WorkflowTask.find(dep) != nil {
                let hot = selected == t.id || selected == dep
                edge(pos(dep), pos(t.id), Theme.textSecondary.opacity(hot ? 0.9 : 0.28), width: hot ? 1.6 : 1, arrow: true)
            } }
        }
    }
}

private struct Line: Shape { func path(in r: CGRect) -> Path { var p = Path(); p.move(to: CGPoint(x: 0, y: r.midY)); p.addLine(to: CGPoint(x: r.maxX, y: r.midY)); return p } }

private struct DotGrid: View {
    let scale: CGFloat; let offset: CGSize
    var body: some View {
        Canvas { ctx, size in
            let step = max(10, 24 * scale)
            let ox = offset.width.truncatingRemainder(dividingBy: step), oy = offset.height.truncatingRemainder(dividingBy: step)
            var y = oy
            while y < size.height { var x = ox; while x < size.width { ctx.fill(Path(ellipseIn: CGRect(x: x, y: y, width: 1.6, height: 1.6)), with: .color(Theme.textSecondary.opacity(0.28))); x += step }; y += step }
        }.background(Theme.elevated.opacity(0.5))
    }
}

private struct NodeCard: View {
    let title: String; let symbol: String; let info: NodeInfo?; let selected: Bool; let isDefault: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Image(systemName: symbol).font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.accent).frame(width: 20, height: 20).background(Theme.accent.opacity(0.14), in: RoundedRectangle(cornerRadius: 6))
                Text(title).font(.system(size: 12, weight: .semibold, design: .rounded)).lineLimit(1)
                Spacer(minLength: 0)
                if info?.manual == true { Image(systemName: "hand.raised").font(.caption2).foregroundStyle(Theme.accent) }
            }
            Text(info?.model ?? "…").font(.system(size: 11, weight: .medium)).foregroundStyle(info?.ready == true ? Theme.textPrimary : (info?.unavailable == true ? Theme.textSecondary : Theme.attention)).lineLimit(1)
            Text([info?.provider, info?.mode].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")).font(.system(size: 9.5)).foregroundStyle(Theme.textSecondary).lineLimit(1)
        }
        .padding(8).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(selected ? Theme.accent : (isDefault ? Theme.accent.opacity(0.5) : Theme.border), lineWidth: selected ? 2 : 1))
        .shadow(color: .black.opacity(0.06), radius: 3, y: 1)
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
    let task: WorkflowTask
    let onReset: () -> Void
    @State private var route: TaskRoute
    @State private var confirmReset = false

    init(cfg: AIConfig, task: WorkflowTask, onReset: @escaping () -> Void) {
        self.cfg = cfg; self.task = task; self.onReset = onReset; _route = State(initialValue: cfg.route(task))
    }
    private func commit() { cfg.save(route) }

    var body: some View {
        let res = cfg.resolution(task)
        let llm = task.capability == .llm
        VStack(alignment: .leading, spacing: Theme.Space.md) {
            Label(task.title, systemImage: task.capability.symbol).font(Theme.sectionTitle)
            Text(task.summary).foregroundStyle(Theme.textSecondary)
            HStack { Badge(text: task.capability.label); if task.optional { Badge(text: "Optional stage", color: Theme.textSecondary) } }
            if !task.dependsOn.isEmpty { Text("Uses output of: \(task.dependsOn.compactMap { WorkflowTask.find($0)?.title }.joined(separator: ", "))").font(Theme.meta).foregroundStyle(Theme.textSecondary) }

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
            Button("Reset", role: .destructive) { cfg.reset(task.id); route = TaskRoute(task: task.id); onReset() }
            Button("Cancel", role: .cancel) {}
        } message: { Text("Its own model, fallback, prompt and manual-bridge setting are removed; it follows the default again.") }
    }
}

import SwiftUI
import AppKit
import Combine
import BraincellCore

// Architecture (why this is cheap):
//  • WorkflowState owns graph data + selection and rebuilds layout/edges only when expansion, offsets, selection or config change.
//  • Viewport (pan/zoom) is a separate object read ONLY by TransformHost, so panning never re-evaluates the page, toolbar, inspector or node views.
//  • CanvasContent is Equatable on a version counter; its edges are one Canvas, its nodes lightweight stable views, its dots a GPU-tiled image.
//  • Node drags are local to one node; the layout (and its edges) is recomputed once on drop, and only then persisted.

enum NodeStatus: Equatable {
    case configured, inherited, notConfigured, unavailable, error, manual
    var label: String { switch self { case .configured: "Configured"; case .inherited: "Inherited"; case .notConfigured: "Not configured"; case .unavailable: "Unavailable"; case .error: "Error"; case .manual: "Manual bridge" } }
    var color: Color { switch self { case .configured: Theme.mastery; case .inherited: Theme.accent; case .notConfigured: Theme.attention; case .unavailable: Theme.textSecondary; case .error: Theme.error; case .manual: Theme.accent } }
}
enum Emphasis: Equatable { case normal, selected, related, dim }

struct NodeVM: Equatable, Identifiable {
    var id: String
    var title: String
    var symbol: String
    var line2: String          // model name (or summary for categories)
    var line3: String          // provider / counts
    var status: NodeStatus
    var statusText: String
    var emphasis: Emphasis = .normal
    var isGroup = false, isDefault = false, expanded = false
    var progress: Double = 0
    var rect: CGRect
}

struct EdgeItem: Identifiable, Equatable {
    var id: String; var path: Path; var kind: EdgeKind; var emphasis: Emphasis
}

@MainActor
final class WorkflowState: ObservableObject {
    let cfg: AIConfig
    @Published private(set) var selected: String?
    @Published private(set) var expanded: Set<TaskGroup>
    @Published var showDeps: Bool { didSet { UserDefaults.standard.set(showDeps, forKey: "wf.deps"); rebuildContent() } }
    @Published private(set) var layout: WorkflowCanvasLayout
    @Published private(set) var nodes: [NodeVM] = []
    @Published private(set) var edges: [EdgeItem] = []
    @Published private(set) var version = 0
    private var offsets: [String: CGSize] = [:]
    private var paths: [String: Path] = [:]
    private var bag = Set<AnyCancellable>()

    init(cfg: AIConfig) {
        self.cfg = cfg
        let saved = (UserDefaults.standard.array(forKey: "wf.expanded") as? [String]) ?? []
        expanded = Set(saved.compactMap { raw in TaskGroup.allCases.first { $0.rawValue == raw } })
        showDeps = UserDefaults.standard.bool(forKey: "wf.deps")
        layout = .make(expanded: [])
        try? cfg.gw.store.pruneLegacyLayout()
        for (k, p) in (try? cfg.gw.store.layout()) ?? [:] where k.hasPrefix("o:") { offsets[String(k.dropFirst(2))] = CGSize(width: p.x, height: p.y) }
        rebuildLayout()
        if SnapshotRunner.isActive, let sel = ProcessInfo.processInfo.environment["BRAINCELL_WF_SELECT"] { select(sel) }   // screenshot aid
        cfg.$rev.dropFirst().sink { [weak self] _ in self?.rebuildContent() }.store(in: &bag)
    }

    // MARK: Intents

    func select(_ id: String?) {
        guard id != selected else { return }
        if let id, let t = WorkflowTask.find(id), !expanded.contains(t.group) { expanded.insert(t.group); saveExpanded(); selected = id; rebuildLayout(); return }
        selected = id; rebuildContent()
    }
    func toggle(_ g: TaskGroup) { if expanded.contains(g) { expanded.remove(g) } else { expanded.insert(g) }; saveExpanded(); rebuildLayout() }
    func setAll(_ open: Bool) { expanded = open ? Set(TaskGroup.allCases) : []; saveExpanded(); rebuildLayout() }
    func commitDrag(_ id: String, by d: CGSize) {
        let n = (offsets[id] ?? .zero); offsets[id] = CGSize(width: n.width + d.width, height: n.height + d.height)
        try? cfg.gw.store.save(LayoutPoint(task: "o:" + id, x: offsets[id]!.width, y: offsets[id]!.height))
        rebuildLayout()
    }
    func resetLayout() { offsets = [:]; try? cfg.gw.store.resetLayout(); rebuildLayout() }

    private func saveExpanded() { UserDefaults.standard.set(expanded.map(\.rawValue), forKey: "wf.expanded") }

    // MARK: Rebuild

    private func rebuildLayout() {
        layout = .make(expanded: expanded, offsets: offsets)
        paths = Dictionary(uniqueKeysWithValues: layout.edges.map { ($0.id, Self.rounded($0.points, radius: 9)) })
        rebuildContent()
    }

    static func rounded(_ pts: [CGPoint], radius r: CGFloat) -> Path {
        var p = Path(); guard let f = pts.first else { return p }
        p.move(to: f)
        for i in 1..<pts.count {
            let cur = pts[i]
            guard i < pts.count - 1 else { p.addLine(to: cur); break }
            let prev = pts[i - 1], next = pts[i + 1]
            let d1 = hypot(cur.x - prev.x, cur.y - prev.y), d2 = hypot(next.x - cur.x, next.y - cur.y)
            let rr = min(r, d1 / 2, d2 / 2)
            let a = CGPoint(x: cur.x - (cur.x - prev.x) / d1 * rr, y: cur.y - (cur.y - prev.y) / d1 * rr)
            let b = CGPoint(x: cur.x + (next.x - cur.x) / d2 * rr, y: cur.y + (next.y - cur.y) / d2 * rr)
            p.addLine(to: a); p.addQuadCurve(to: b, control: cur)
        }
        return p
    }

    func rebuildContent() {
        let res = cfg.resolutions, routes = cfg.routes
        var vms: [NodeVM] = []
        func llmFollowers() -> Int { WorkflowTask.all.filter { $0.capability == .llm && (routes[$0.id]?.inherit ?? true) && routes[$0.id]?.manualBridge != true && res[$0.id]?.primary != nil }.count }
        func info(_ t: WorkflowTask) -> (String, String, NodeStatus) {
            guard let r = res[t.id] else { return ("—", "", .notConfigured) }
            if r.manual { return ("Manual ChatGPT Bridge", "You copy and import", .manual) }
            if let p = r.primary { return (p.model.displayName, p.connection.name, p.model.health == .failed ? .error : (r.inherited ? .inherited : .configured)) }
            let supported = ProviderRegistry.all.contains { $0.supports(t.capability) }
            return (supported ? "Choose a model" : "No adapter yet", supported ? "" : t.capability.label, supported ? .notConfigured : .unavailable)
        }
        for n in layout.nodes {
            switch n.kind {
            case .defaultModel:
                let d = cfg.defaults[.llm]; let c = d.flatMap { cfg.connection($0.connectionId) }
                vms.append(NodeVM(id: n.id, title: "Default Model", symbol: "sparkles", line2: d?.modelId ?? "Not set", line3: c.map { "\($0.name) · \(llmFollowers()) tasks follow" } ?? "Connect a provider",
                                  status: d == nil ? .notConfigured : .configured, statusText: d == nil ? "Not configured" : "Configured", isDefault: true, rect: n.rect))
            case .group(let g):
                let ts = WorkflowTask.all.filter { $0.group == g }
                let ok = ts.filter { res[$0.id]?.isReady == true }.count
                let supported = ts.contains { t in ProviderRegistry.all.contains { $0.supports(t.capability) } }
                let st: NodeStatus = !supported ? .unavailable : ok == ts.count ? .configured : ok == 0 ? .notConfigured : .inherited
                let text = !supported ? "No adapters yet" : ok == ts.count ? "All configured" : ok == 0 ? "Not configured" : "Partly configured"
                vms.append(NodeVM(id: n.id, title: g.rawValue, symbol: Self.symbol(g), line2: "\(ts.count) tasks · \(ok) configured", line3: "", status: st, statusText: text,
                                  isGroup: true, expanded: expanded.contains(g), progress: Double(ok) / Double(max(1, ts.count)), rect: n.rect))
            case .task(let id):
                guard let t = WorkflowTask.find(id) else { continue }
                let (m, p, s) = info(t)
                let own = !(routes[id]?.inherit ?? true) && !(res[id]?.manual ?? false)
                vms.append(NodeVM(id: id, title: t.title, symbol: t.capability.symbol, line2: m, line3: p, status: s, statusText: s == .configured && own ? "Own setting" : s.label, rect: n.rect))
            }
        }
        // Selection emphasis: the selected node, its immediate neighbours, and everything else faded.
        var touching = Set<String>(); var related = Set<String>()
        if let s = selected {
            for e in layout.edges where e.from == s || e.to == s { touching.insert(e.id); related.insert(e.from); related.insert(e.to) }
            for i in vms.indices { vms[i].emphasis = vms[i].id == s ? .selected : related.contains(vms[i].id) ? .related : .dim }
        }
        let inherits = Set(WorkflowTask.all.filter { $0.capability == .llm && (routes[$0.id]?.inherit ?? true) && routes[$0.id]?.manualBridge != true }.map(\.id))
        edges = layout.edges.compactMap { e in
            if e.kind == .inheritance, !e.to.hasPrefix("group:"), !inherits.contains(e.to) { return nil }      // own-setting and manual tasks don't follow the default
            let hot = touching.contains(e.id)
            if e.kind == .dependency, !showDeps, !hot { return nil }
            return EdgeItem(id: e.id, path: paths[e.id] ?? Path(), kind: e.kind, emphasis: selected == nil ? .normal : hot ? .selected : .dim)
        }
        nodes = vms
        version += 1
    }

    static func symbol(_ g: TaskGroup) -> String {
        switch g { case .core: "square.stack.3d.up"; case .study: "rectangle.on.rectangle"; case .research: "doc.text.magnifyingglass"; case .media: "photo.on.rectangle"; case .experience: "graduationcap" }
    }
    /// "Fit" always frames the whole graph (nodes and edge runs); the camera math clamps the zoom, it never drops nodes from view.
    func fitRect(viewport v: CGSize) -> CGRect { layout.bounds }
    func tasks(in g: TaskGroup) -> [WorkflowTask] { WorkflowTask.all.filter { $0.group == g } }
}

// MARK: Viewport

@MainActor
final class Viewport: ObservableObject {
    @Published var pan: CGSize = .zero
    @Published var scale: CGFloat = 1
    var size: CGSize = .zero            // deliberately not @Published: resizing the window must not re-render the canvas
    var panStart: CGSize?
    var magnifyBase: CGFloat?
    var hasCamera = false
    /// True until the learner moves or zooms the camera: while true, window resizes re-frame the overview.
    var autoFit = false
    private var saveItem: DispatchWorkItem?
    static let minScale: CGFloat = 0.2, maxScale: CGFloat = 1.8

    init() {
        if let a = UserDefaults.standard.array(forKey: "wf.cam") as? [Double], a.count == 3 { pan = CGSize(width: a[0], height: a[1]); scale = a[2]; hasCamera = true }
    }

    func zoom(by f: CGFloat, at c: CGPoint? = nil) {
        let c = c ?? CGPoint(x: size.width / 2, y: size.height / 2)
        autoFit = false
        let s2 = min(Self.maxScale, max(Self.minScale, scale * f))
        pan = CGSize(width: c.x - (c.x - pan.width) * (s2 / scale), height: c.y - (c.y - pan.height) * (s2 / scale))
        scale = s2; persistSoon()
    }
    func pan(by d: CGSize) { autoFit = false; pan = CGSize(width: pan.width + d.width, height: pan.height + d.height); persistSoon() }

    /// Fits the whole graph in the current viewport, centred on both axes (see `CanvasFit`).
    func fit(_ b: CGRect) {
        guard size.width > 0, b.width > 0 else { return }
        var b = b; b.size.height += 64 / max(scale, 0.2)      // keep the last row clear of the zoom controls
        let t = CanvasFit.transform(bounds: b, viewport: size, minScale: Self.minScale, maxScale: 1)
        scale = t.scale; pan = t.pan
        hasCamera = true; persistSoon()
    }
    func reveal(_ r: CGRect) {
        let sr = CGRect(x: r.minX * scale + pan.width, y: r.minY * scale + pan.height, width: r.width * scale, height: r.height * scale)
        guard !CGRect(origin: .zero, size: size).insetBy(dx: 24, dy: 24).contains(sr) else { return }
        pan = CGSize(width: size.width / 2 - r.midX * scale, height: size.height / 2 - r.midY * scale); persistSoon()
    }
    func persistSoon() {
        saveItem?.cancel()
        let w = DispatchWorkItem { [weak self] in guard let self else { return }; UserDefaults.standard.set([Double(pan.width), Double(pan.height), Double(scale)], forKey: "wf.cam") }
        saveItem = w; DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: w)
    }
}

/// The only view that reads pan/scale. Its `content` is a value that doesn't change while the camera moves.
struct TransformHost<Content: View>: View {
    @ObservedObject var vp: Viewport
    let content: Content
    var body: some View { content.scaleEffect(vp.scale, anchor: .topLeading).offset(vp.pan) }
}

// MARK: Canvas

struct WorkflowCanvas: View {
    @ObservedObject var state: WorkflowState
    let vp: Viewport          // not observed here on purpose
    @State private var placedInitialCamera = false

    var body: some View {
        let b = state.layout.bounds
        // The base view alone defines this view's size; the (much larger) graph is an overlay, so it can never widen the page.
        DotGrid(vp: vp).accessibilityHidden(true)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 3).onChanged { v in
                vp.autoFit = false
                let s = vp.panStart ?? vp.pan; vp.panStart = s
                vp.pan = CGSize(width: s.width + v.translation.width, height: s.height + v.translation.height)
            }.onEnded { _ in vp.panStart = nil; vp.persistSoon() })
            .simultaneousGesture(MagnifyGesture().onChanged { v in
                let base = vp.magnifyBase ?? vp.scale; vp.magnifyBase = base
                vp.zoom(by: (base * v.magnification) / vp.scale, at: v.startLocation)
            }.onEnded { _ in vp.magnifyBase = nil })
            .onTapGesture(count: 2) { vp.fit(state.fitRect(viewport: vp.size)) }
            .onTapGesture { state.select(nil) }
            .overlay(alignment: .topLeading) {
                TransformHost(vp: vp, content: CanvasContent(version: state.version, nodes: state.nodes, edges: state.edges, size: CGSize(width: b.maxX + 40, height: b.maxY + 40),
                                                             scale: { vp.scale }, select: { state.select($0) }, toggle: { state.toggle($0) }, drop: { state.commitDrag($0, by: $1) }).equatable())
            }
        .background(Theme.elevated.opacity(0.35))
        .background(ScrollInput(vp: vp))
        .onGeometryChange(for: CGSize.self) { $0.size } action: { size in
            vp.size = size
            guard size.width > 300, size.height > 200 else { return }
            if !placedInitialCamera { placedInitialCamera = true; vp.autoFit = !vp.hasCamera }
            if vp.autoFit { vp.fit(state.fitRect(viewport: size)); vp.autoFit = true }
        }
        .clipped()
        .overlay(alignment: .bottomLeading) { ZoomControls(vp: vp) { vp.fit(state.fitRect(viewport: vp.size)) }.padding(Theme.Space.md) }
        .accessibilityElement(children: .contain).accessibilityLabel("Workflow canvas")
    }
}

struct CanvasContent: View, Equatable {
    let version: Int
    let nodes: [NodeVM]
    let edges: [EdgeItem]
    let size: CGSize
    let scale: () -> CGFloat
    let select: (String?) -> Void
    let toggle: (TaskGroup) -> Void
    let drop: (String, CGSize) -> Void
    static func == (a: CanvasContent, b: CanvasContent) -> Bool { a.version == b.version && a.size == b.size }

    var body: some View {
        ZStack(alignment: .topLeading) {
            Canvas { ctx, _ in
                for e in edges {
                    let hot = e.emphasis == .selected
                    let color: Color, width: CGFloat, dash: [CGFloat]
                    if e.kind == .inheritance { color = Theme.accent.opacity(e.emphasis == .dim ? 0.16 : hot ? 1 : 0.7); width = hot ? 2.4 : 1.7; dash = [] }
                    else { color = hot ? Theme.accent : Theme.textSecondary.opacity(e.emphasis == .dim ? 0.15 : 0.55); width = hot ? 2 : 1.2; dash = [5, 4] }
                    ctx.stroke(e.path, with: .color(color), style: StrokeStyle(lineWidth: width, lineCap: .round, lineJoin: .round, dash: dash))
                }
            }.frame(width: size.width, height: size.height).allowsHitTesting(false).accessibilityHidden(true)
            ForEach(nodes) { n in NodeCell(vm: n, scale: scale, select: select, toggle: toggle, drop: drop) }
        }.frame(width: size.width, height: size.height, alignment: .topLeading)
         .drawingGroup()      // rendered once into a GPU texture; panning then only moves that texture instead of re-drawing every node and edge
    }
}

/// One node. Its drag offset is local state, so moving a node re-renders only this view; the layout updates once on drop.
struct NodeCell: View, Equatable {
    let vm: NodeVM
    let scale: () -> CGFloat
    let select: (String?) -> Void
    let toggle: (TaskGroup) -> Void
    let drop: (String, CGSize) -> Void
    @State private var drag: CGSize = .zero
    static func == (a: NodeCell, b: NodeCell) -> Bool { a.vm == b.vm }

    var body: some View {
        NodeCard(vm: vm, toggle: { if let g = TaskGroup.allCases.first(where: { VisualNode.groupId($0) == vm.id }) { toggle(g) } })
            .frame(width: vm.rect.width, height: vm.rect.height)
            .offset(x: vm.rect.minX + drag.width, y: vm.rect.minY + drag.height)
            .gesture(DragGesture(minimumDistance: 5, coordinateSpace: .global)
                .onChanged { v in let s = max(0.01, scale()); drag = CGSize(width: v.translation.width / s, height: v.translation.height / s) }
                .onEnded { _ in let d = drag; drop(vm.id, d); drag = .zero })
            .onTapGesture { select(vm.id) }
            .accessibilityElement(children: .combine).accessibilityAddTraits(vm.emphasis == .selected ? [.isButton, .isSelected] : .isButton)
            .accessibilityLabel("\(vm.title). \(vm.line2). \(vm.line3). \(vm.statusText)")
            .accessibilityAction { select(vm.id) }
            .accessibilityAction(named: vm.expanded ? "Collapse" : "Expand") { if vm.isGroup, let g = TaskGroup.allCases.first(where: { VisualNode.groupId($0) == vm.id }) { toggle(g) } }
            .help(vm.isGroup || vm.isDefault ? vm.title : "\(vm.title)\n\(vm.line2)\(vm.line3.isEmpty ? "" : " · " + vm.line3)")
    }
}

struct NodeCard: View {
    let vm: NodeVM
    let toggle: () -> Void
    var body: some View {
        let sel = vm.emphasis == .selected
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 7) {
                Image(systemName: vm.symbol).font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.accent).frame(width: 24, height: 24)
                    .background(Theme.accent.opacity(0.14), in: RoundedRectangle(cornerRadius: 7))
                Text(vm.title).font(.system(size: vm.isGroup || vm.isDefault ? 14 : 13, weight: .semibold, design: .rounded)).lineLimit(1)
                Spacer(minLength: 0)
                if vm.isGroup { Button(action: toggle) { Image(systemName: vm.expanded ? "chevron.up" : "chevron.down").font(.system(size: 11, weight: .bold)).frame(width: 22, height: 22).contentShape(Rectangle()) }
                    .buttonStyle(.plain).foregroundStyle(Theme.textSecondary).accessibilityHidden(true) }
            }
            Text(vm.line2).font(.system(size: 12, weight: .medium)).foregroundStyle(vm.status == .notConfigured ? Theme.attention : Theme.textPrimary).lineLimit(1).truncationMode(.middle)
            if vm.isGroup { MeterBar(value: vm.progress, tint: vm.status.color, height: 4) }
            else if !vm.line3.isEmpty { Text(vm.line3).font(.system(size: 11)).foregroundStyle(Theme.textSecondary).lineLimit(1) }
            Spacer(minLength: 0)
            HStack(spacing: 5) { Circle().fill(vm.status.color).frame(width: 7, height: 7); Text(vm.statusText).font(.system(size: 11, weight: .medium)).foregroundStyle(vm.status.color).lineLimit(1) }
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(sel ? Theme.accent.opacity(0.10) : Theme.surface, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(sel ? Theme.accent : (vm.isDefault ? Theme.accent.opacity(0.5) : Theme.border), lineWidth: sel ? 2 : 1))
        .opacity(vm.emphasis == .dim ? 0.5 : 1)
    }
}

struct ZoomControls: View {
    @ObservedObject var vp: Viewport
    let fit: () -> Void
    var body: some View {
        HStack(spacing: 4) {
            Button { vp.zoom(by: 1 / 1.2) } label: { Image(systemName: "minus") }.keyboardShortcut("-", modifiers: .command).accessibilityLabel("Zoom out")
            Text("\(Int((vp.scale * 100).rounded()))%").font(.system(.callout, design: .rounded)).monospacedDigit().frame(width: 46)
            Button { vp.zoom(by: 1.2) } label: { Image(systemName: "plus") }.keyboardShortcut("=", modifiers: .command).accessibilityLabel("Zoom in")
            Button(action: fit) { Image(systemName: "arrow.up.left.and.down.right.magnifyingglass") }.keyboardShortcut("0", modifiers: .command).accessibilityLabel("Fit to view").help("Fit to view (⌘0, or double-click empty space)")
        }.padding(6).background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.control)).overlay(RoundedRectangle(cornerRadius: Theme.Radius.control).strokeBorder(Theme.border))
    }
}

// MARK: Trackpad and wheel input

/// Two-finger scroll pans; ⌘/⌥/⌃ + scroll zooms about the cursor. Pinch is handled by a SwiftUI gesture. Only events over the canvas are consumed.
struct ScrollInput: NSViewRepresentable {
    let vp: Viewport
    func makeNSView(context: Context) -> TrackView { let v = TrackView(); v.vp = vp; return v }
    func updateNSView(_ v: TrackView, context: Context) { v.vp = vp }

    final class TrackView: NSView {
        var vp: Viewport?
        private var monitor: Any?
        override var isFlipped: Bool { true }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let m = monitor { NSEvent.removeMonitor(m); monitor = nil }
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] e in
                guard let self, e.window === self.window, let vp = self.vp else { return e }
                let p = self.convert(e.locationInWindow, from: nil)
                guard self.bounds.contains(p) else { return e }
                let k: CGFloat = e.hasPreciseScrollingDeltas ? 1 : 8
                MainActor.assumeIsolated {
                    if !e.modifierFlags.intersection([.command, .option, .control]).isEmpty { vp.zoom(by: exp(e.scrollingDeltaY * k * 0.004), at: p) }
                    else { vp.pan(by: CGSize(width: e.scrollingDeltaX * k, height: e.scrollingDeltaY * k)) }
                }
                return nil
            }
        }
        deinit { if let m = monitor { NSEvent.removeMonitor(m) } }
    }
}

// MARK: Dot grid

/// Dotted background. A layer-backed view holds one tiled pattern slightly larger than the viewport and is only *moved* when the camera pans
/// (a compositor translation, no SwiftUI work and no redraw); the pattern is rebuilt only when the zoom changes.
struct DotGrid: NSViewRepresentable {
    let vp: Viewport
    func makeNSView(context: Context) -> DotsView { DotsView(vp: vp) }
    func updateNSView(_ v: DotsView, context: Context) {}

    final class DotsView: NSView {
        private let pattern = CALayer()
        private var bag = Set<AnyCancellable>()
        private var step: CGFloat = 0
        private let vp: Viewport
        override var isFlipped: Bool { true }

        init(vp: Viewport) {
            self.vp = vp
            super.init(frame: .zero)
            wantsLayer = true; layer?.masksToBounds = true
            pattern.actions = ["position": NSNull(), "bounds": NSNull(), "backgroundColor": NSNull()]
            layer?.addSublayer(pattern)
            vp.$pan.combineLatest(vp.$scale).sink { [weak self] _, _ in DispatchQueue.main.async { self?.sync() } }.store(in: &bag)
        }
        required init?(coder: NSCoder) { fatalError() }
        override func layout() { super.layout(); step = 0; sync() }
        override func viewDidChangeEffectiveAppearance() { step = 0; sync() }

        @MainActor private func sync() {
            let s = max(12, 24 * vp.scale)
            if abs(s - step) > 0.01 {
                step = s
                let tile = NSImage(size: NSSize(width: s, height: s), flipped: false) { r in
                    NSColor.secondaryLabelColor.withAlphaComponent(0.33).setFill()
                    NSBezierPath(ovalIn: NSRect(x: r.midX - 1, y: r.midY - 1, width: 2, height: 2)).fill(); return true
                }
                effectiveAppearance.performAsCurrentDrawingAppearance { pattern.backgroundColor = NSColor(patternImage: tile).cgColor }
            }
            let ox = vp.pan.width.truncatingRemainder(dividingBy: s), oy = vp.pan.height.truncatingRemainder(dividingBy: s)
            CATransaction.begin(); CATransaction.setDisableActions(true)
            pattern.frame = CGRect(x: ox - s, y: oy - s, width: bounds.width + 2 * s, height: bounds.height + 2 * s)
            CATransaction.commit()
        }
    }
}

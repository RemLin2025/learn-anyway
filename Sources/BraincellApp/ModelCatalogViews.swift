import SwiftUI
import BraincellCore

enum LoadState: Equatable { case idle, loading, succeeded, failed(String), cancelled }

/// Builds the visible model rows off the main actor, debounced and cancellable. The view only ever renders `rows`.
@MainActor
final class ModelListModel: ObservableObject {
    @Published private(set) var rows: [ModelRow] = []
    @Published private(set) var total = 0
    @Published private(set) var state = LoadState.idle
    private var work: Task<Void, Never>?

    func update(cfg: AIConfig, connection: AIConnection, cap: Capability, query: ModelQuery, debounce: Bool) {
        work?.cancel()
        let models = cfg.models(connection, cap)
        let provider = connection.name
        let fav = cfg.favorites
        let assigned = cfg.assignments.mapValues(\.count)
        let d = cfg.defaults[cap]
        let defaultModel = d?.connectionId == connection.id ? d?.modelId : nil
        let local = connection.spec?.isLocal == true
        state = .loading
        work = Task { [weak self] in
            if debounce { try? await Task.sleep(nanoseconds: 180_000_000) }
            if Task.isCancelled { return }
            let out = await Task.detached(priority: .userInitiated) { () -> ([ModelRow], Int) in
                let rows = models.map { m in
                    ModelRow(id: m.id, name: m.displayName, modelId: m.modelId, provider: provider, capability: m.capability, health: m.health,
                             input: local ? 0 : m.effectiveInputPricePerM, output: local ? 0 : m.effectiveOutputPricePerM, custom: m.hasCustomPrice,
                             assignments: assigned[m.id] ?? 0, isDefault: defaultModel == m.modelId, favorite: fav.contains(m.id.uuidString))
                }
                return (ModelCatalog.filter(rows, query), rows.count)
            }.value
            if Task.isCancelled { return }
            self?.rows = out.0; self?.total = out.1; self?.state = .succeeded
        }
    }
    func cancel() { work?.cancel(); work = nil; if state == .loading { state = .cancelled } }
}

/// Compact, lazy model table for one connection. Rows are plain values with fixed height; nothing here scales with the catalog size at render time.
struct ModelTable: View {
    @ObservedObject var cfg: AIConfig
    let connection: AIConnection
    let cap: Capability
    @Binding var selected: UUID?
    @StateObject private var list = ModelListModel()
    @State private var query = ModelQuery()
    @State private var width: CGFloat = 700
    private var compact: Bool { width < 420 }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.sm) {
            HStack(spacing: Theme.Space.sm) {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").foregroundStyle(Theme.textSecondary)
                    TextField("Search \(list.total) models", text: $query.text).textFieldStyle(.plain).accessibilityLabel("Search models")
                }.padding(.horizontal, 10).frame(height: 30).background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.control)).overlay(RoundedRectangle(cornerRadius: Theme.Radius.control).strokeBorder(Theme.border))
                Picker("Show", selection: $query.scope) { ForEach(ModelQuery.Scope.allCases, id: \.self) { Text($0.rawValue).tag($0) } }
                    .labelsHidden().fixedSize().accessibilityLabel("Filter models")
            }
            VStack(spacing: 0) {
                header
                Divider()
                if list.rows.isEmpty {
                    Text(list.state == .loading ? "Loading models…" : list.total == 0 ? "No \(cap.label) models yet. Refresh the catalog or add one by id." : "No models match.")
                        .foregroundStyle(Theme.textSecondary).frame(maxWidth: .infinity, minHeight: 80)
                } else {
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(list.rows) { r in
                                ModelRowView(row: r, compact: compact, selected: selected == r.id) { selected = selected == r.id ? nil : r.id }
                                Divider().opacity(0.5)
                            }
                        }
                    }.frame(height: min(CGFloat(list.rows.count) * 45 + 4, 360))
                }
            }.background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.control)).overlay(RoundedRectangle(cornerRadius: Theme.Radius.control).strokeBorder(Theme.border))
            Text("\(list.rows.count) of \(list.total) shown · prices are USD per 1M tokens").font(Theme.meta).foregroundStyle(Theme.textSecondary)
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        .onAppear { refresh(debounce: false) }
        .onDisappear { list.cancel() }
        .onChange(of: query) { _, _ in refresh(debounce: true) }
        .onChange(of: cfg.rev) { _, _ in refresh(debounce: false) }
        .onChange(of: cap) { _, _ in refresh(debounce: false) }
    }

    private func refresh(debounce: Bool) { list.update(cfg: cfg, connection: connection, cap: cap, query: query, debounce: debounce) }

    private var header: some View {
        HStack(spacing: 8) {
            sortButton("Model", .name).frame(maxWidth: .infinity, alignment: .leading)
            if !compact { Text("Status").frame(width: 70, alignment: .leading); sortButton("Input", .input).frame(width: 78, alignment: .trailing); sortButton("Output", .output).frame(width: 78, alignment: .trailing) }
            Text("Tasks").frame(width: 44, alignment: .trailing)
        }.font(Theme.meta).foregroundStyle(Theme.textSecondary).padding(.horizontal, 12).frame(height: 28)
    }

    private func sortButton(_ t: String, _ s: ModelQuery.Sort) -> some View {
        Button { if query.sort == s { query.ascending.toggle() } else { query.sort = s; query.ascending = true } } label: {
            HStack(spacing: 2) { Text(t); if query.sort == s { Image(systemName: query.ascending ? "chevron.up" : "chevron.down").font(.system(size: 8, weight: .bold)) } }.contentShape(Rectangle())
        }.buttonStyle(.plain).accessibilityLabel("Sort by \(t)")
    }
}

private struct ModelRowView: View {
    let row: ModelRow; let compact: Bool; let selected: Bool; let tap: () -> Void
    @State private var hover = false
    var body: some View {
        Button(action: tap) {
            HStack(spacing: 8) {
                Image(systemName: row.favorite ? "star.fill" : (row.isDefault ? "checkmark.circle.fill" : "circle.dashed")).font(.caption)
                    .foregroundStyle(row.favorite ? Theme.attention : (row.isDefault ? Theme.accent : Theme.textSecondary.opacity(0.5))).frame(width: 14)
                VStack(alignment: .leading, spacing: 1) {
                    Text(row.name).font(.system(.callout, design: .rounded, weight: .medium)).lineLimit(1).truncationMode(.tail)
                    Text(row.modelId).font(.system(.caption2, design: .monospaced)).foregroundStyle(Theme.textSecondary).lineLimit(1).truncationMode(.middle)
                }.frame(maxWidth: .infinity, alignment: .leading)
                if !compact {
                    let (t, c) = ModelBadge.label(row.health)
                    Text(t).font(Theme.meta).foregroundStyle(c).frame(width: 70, alignment: .leading)
                    Text(PriceInput.format(row.input) + (row.custom ? "*" : "")).font(.callout.monospacedDigit()).frame(width: 78, alignment: .trailing)
                    Text(PriceInput.format(row.output) + (row.custom ? "*" : "")).font(.callout.monospacedDigit()).frame(width: 78, alignment: .trailing)
                }
                Text(row.assignments == 0 ? "–" : "\(row.assignments)").font(.callout.monospacedDigit()).foregroundStyle(row.assignments == 0 ? Theme.textSecondary : Theme.accent).frame(width: 44, alignment: .trailing)
            }
            .padding(.horizontal, 12).frame(height: 44).contentShape(Rectangle())
            .background(selected ? Theme.accent.opacity(0.12) : (hover ? Theme.elevated.opacity(0.6) : .clear))
        }
        .buttonStyle(.plain).onHover { hover = $0 }
        .help("\(row.name)\n\(row.modelId)")
        .accessibilityLabel("\(row.name), \(PriceInput.format(row.input)) in, \(PriceInput.format(row.output)) out, \(row.assignments) task assignments")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// Everything about one model in a readable panel. Secondary controls (custom price) are collapsed by default.
struct ModelInspector: View {
    @ObservedObject var cfg: AIConfig
    @EnvironmentObject var app: AppModel
    let model: AIModelRecord
    let connection: AIConnection
    let close: () -> Void

    var body: some View {
        let asg = cfg.assignments(of: model)
        let isDefault = cfg.defaults[model.capability].map { $0.connectionId == connection.id && $0.modelId == model.modelId } ?? false
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.md) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(model.displayName).font(Theme.cardTitle).textSelection(.enabled)
                        Text(model.modelId).font(.system(.caption, design: .monospaced)).foregroundStyle(Theme.textSecondary).textSelection(.enabled)
                    }
                    Spacer()
                    Button { close() } label: { Image(systemName: "xmark").frame(width: 24, height: 24).contentShape(Rectangle()) }.buttonStyle(.plain).accessibilityLabel("Close details")
                }
                fact("Provider", connection.name)
                fact("Capability", model.capability.label)
                fact("Adapter", connection.spec?.supports(model.capability) == true ? "Available in this build" : "Not available in this build")
                let (st, sc) = ModelBadge.label(model.health)
                HStack { Text("Status").foregroundStyle(Theme.textSecondary); Spacer(); Text(st).foregroundStyle(sc) }.font(.callout)
                fact("Context window", "Not reported")
                Divider()
                Text("Pricing").font(.system(.subheadline, design: .rounded, weight: .semibold))
                fact("Input", PriceInput.format(model.inputPricePerM) + " / 1M tokens")
                fact("Output", PriceInput.format(model.outputPricePerM) + " / 1M tokens")
                Text(priceSource).font(Theme.meta).foregroundStyle(Theme.textSecondary)
                if model.hasCustomPrice { Notice(text: "Your estimate (\(PriceInput.format(model.effectiveInputPricePerM)) in / \(PriceInput.format(model.effectiveOutputPricePerM)) out) is used for local cost estimates only. It doesn’t change what the provider bills.", tint: Theme.attention, symbol: "pencil") }
                DisclosureGroup("Advanced pricing") { PriceEditor(cfg: cfg, model: model).id(model.id).padding(.top, 6) }
                Divider()
                Text("Assignments").font(.system(.subheadline, design: .rounded, weight: .semibold))
                if asg.isEmpty && !isDefault { Text("Not used by any task right now.").font(.callout).foregroundStyle(Theme.textSecondary) }
                if isDefault { Text("Default \(model.capability.label) model").font(.callout) }
                ForEach(asg.sorted { $0.task.title < $1.task.title }, id: \.task.id) { a in
                    Button { app.openWorkflow(task: a.task.id) } label: {
                        HStack { Text(a.task.title); Spacer(); Text(a.inherited ? "inherits default" : "custom").font(Theme.meta).foregroundStyle(Theme.textSecondary); Image(systemName: "chevron.right").font(.caption2).foregroundStyle(Theme.textSecondary) }
                            .font(.callout).contentShape(Rectangle())
                    }.buttonStyle(.plain).help("Open in AI Workflow")
                }
                Divider()
                HStack {
                    if model.capability == .llm { Button("Use as default") { cfg.setDefault(.llm, connection, model.modelId) }.disabled(isDefault)
                        Button(cfg.busy.contains("test-\(model.id)") ? "Testing…" : "Test") { cfg.test(Target(connection: connection, model: model)) }.disabled(cfg.busy.contains("test-\(model.id)")) }
                    Button(cfg.favorites.contains(model.id.uuidString) ? "Unfavorite" : "Favorite") { cfg.toggleFavorite(model) }
                }
                Button("Remove from list", role: .destructive) { cfg.remove(model); close() }.buttonStyle(.plain).foregroundStyle(Theme.error).font(.callout)
            }.padding(Theme.Space.lg)
        }
        .frame(width: 340).background(Theme.surface)
        .overlay(alignment: .leading) { Rectangle().fill(Theme.border).frame(width: 1) }
    }

    private var priceSource: String {
        if model.inputPricePerM == nil && model.outputPricePerM == nil { return "No provider price is known for this model. Cost shows as Unknown, never zero." }
        if model.source == "manual" { return "Entered manually when the model was added." }
        if let d = model.pricedAt { return "Reported by \(connection.name)’s catalog on \(d.formatted(date: .abbreviated, time: .omitted))." }
        return "From \(connection.name)’s catalog (read before dates were recorded)."
    }
    private func fact(_ k: String, _ v: String) -> some View { HStack(alignment: .top) { Text(k).foregroundStyle(Theme.textSecondary); Spacer(); Text(v).multilineTextAlignment(.trailing) }.font(.callout) }
}

/// Custom price estimate with explicit validation and a definite save result. Local text state means typing never writes anything.
struct PriceEditor: View {
    @ObservedObject var cfg: AIConfig
    let model: AIModelRecord
    @State private var inText: String
    @State private var outText: String
    @State private var phase: Phase = .idle
    enum Phase: Equatable { case idle, saved, failed(String) }

    init(cfg: AIConfig, model: AIModelRecord) {
        self.cfg = cfg; self.model = model
        _inText = State(initialValue: model.customInputPricePerM.map { String($0) } ?? "")
        _outText = State(initialValue: model.customOutputPricePerM.map { String($0) } ?? "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.sm) {
            Text("Optional. Used only for Learn Anyway’s cost estimates, in USD per 1M tokens. Leave blank to use the provider price.").font(Theme.meta).foregroundStyle(Theme.textSecondary)
            field("Input price", $inText); field("Output price", $outText)
            HStack {
                Button("Save estimate") { save() }.buttonStyle(.primary)
                Button("Clear") { inText = ""; outText = ""; save() }.disabled(!model.hasCustomPrice && inText.isEmpty && outText.isEmpty)
            }
            switch phase {
            case .idle: EmptyView()
            case .saved: Label("Saved", systemImage: "checkmark.circle").font(Theme.meta).foregroundStyle(Theme.mastery)
            case .failed(let m): Label(m, systemImage: "exclamationmark.triangle").font(Theme.meta).foregroundStyle(Theme.error).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
    private func field(_ l: String, _ t: Binding<String>) -> some View {
        HStack { Text(l).font(.callout); Spacer(); TextField("$ / 1M", text: t).multilineTextAlignment(.trailing).frame(width: 110).onSubmit { save() }.onChange(of: t.wrappedValue) { _, _ in phase = .idle }.accessibilityLabel("\(l) per million tokens") }
    }
    private func save() {
        switch (PriceInput.parse(inText), PriceInput.parse(outText)) {
        case (.failure(let e), _), (_, .failure(let e)): phase = .failed(PriceInput.message(e))
        case (.success(let i), .success(let o)):
            do { try cfg.setCustomPrices(model, input: i, output: o); phase = .saved } catch { phase = .failed("Couldn’t save: \(error.localizedDescription). Your previous value is unchanged.") }
        }
    }
}

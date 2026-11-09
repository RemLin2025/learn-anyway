import SwiftUI
import UniformTypeIdentifiers
import BraincellCore

/// Per-capability provider and model management. Providers whose adapter doesn't exist are listed but clearly marked, never shown as working.
struct ModelServicesView: View {
    @ObservedObject var cfg: AIConfig
    @Binding var tab: Capability
    @State private var providerId = "openai"
    @State private var key = ""
    @State private var baseURL = ""
    @State private var connName = ""
    @State private var newModel = ""
    @State private var confirmRemove: AIConnection?
    @State private var confirmTest = false
    @State private var importMissing: [String]?

    private var providers: [ProviderSpec] { ProviderRegistry.providers(for: tab) }
    private var spec: ProviderSpec { providers.first { $0.id == providerId } ?? providers.first ?? ProviderRegistry.all[0] }

    var body: some View {
        AIPage(title: "Model Services", subtitle: "Credentials, endpoints and model catalogs for every capability.") {
            VStack(spacing: 0) {
                readiness
                tabBar
                Divider()
                HStack(alignment: .top, spacing: 0) {
                    List(providers, selection: Binding(get: { spec.id }, set: { if let v = $0 { providerId = v; key = ""; baseURL = ""; connName = "" } })) { p in
                        HStack(spacing: Theme.Space.md) {
                            ProviderIcon(symbol: p.symbol, size: 30)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(p.name).font(.system(.body, design: .rounded, weight: .medium))
                                let c = cfg.connections(for: p.id).first
                                StatusDot(color: p.supports(tab) ? (c?.status.color ?? Theme.textSecondary) : Theme.attention,
                                          text: !p.supports(tab) ? "Not supported yet" : (c?.status.label ?? "Not configured"))
                            }
                        }.padding(.vertical, 2).tag(p.id).accessibilityElement(children: .combine)
                    }.sidePanel().frame(width: 270)
                    ScrollView { detail.padding(Theme.Space.xl).frame(maxWidth: 720, alignment: .leading).frame(maxWidth: .infinity, alignment: .leading) }
                }
            }
        }
        .confirmationDialog("Remove \(confirmRemove?.name ?? "")?", isPresented: Binding(get: { confirmRemove != nil }, set: { if !$0 { confirmRemove = nil } }), titleVisibility: .visible) {
            Button("Remove and delete key", role: .destructive) { if let c = confirmRemove { cfg.disconnect(c) }; confirmRemove = nil }
            Button("Cancel", role: .cancel) { confirmRemove = nil }
        } message: { if let c = confirmRemove { Text(cfg.usedByRoutes(c) > 0 ? "\(cfg.usedByRoutes(c)) default or task assignment(s) use it and will revert to inheriting." : "Its models and stored key are deleted.") } }
        .confirmationDialog("Test the LLM default?", isPresented: $confirmTest, titleVisibility: .visible) {
            Button("Send one tiny request") { testDefault() }
            Button("Cancel", role: .cancel) {}
        } message: { Text("This sends a one-line prompt (a few tokens) to your default LLM. Image, video and other media models are never tested automatically.") }
        .alert("Imported", isPresented: Binding(get: { importMissing != nil }, set: { if !$0 { importMissing = nil } })) {
            Button("OK") { importMissing = nil }
        } message: { Text((importMissing ?? []).isEmpty ? "Settings imported." : "Settings imported. Add API keys for: \((importMissing ?? []).joined(separator: ", ")).") }
    }

    // MARK: Header

    private var readiness: some View {
        VStack(alignment: .leading, spacing: Theme.Space.sm) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: Theme.Space.sm) {
                    ForEach(Capability.allCases) { c in
                        let r = cfg.readiness(c)
                        Button { tab = c } label: {
                            HStack(spacing: 5) { Circle().fill(r.ok ? Theme.mastery : Theme.textSecondary.opacity(0.5)).frame(width: 7, height: 7); Text("\(c.label): \(r.label)").font(Theme.meta) }
                                .padding(.horizontal, 10).padding(.vertical, 5).background(Theme.surface, in: Capsule()).overlay(Capsule().strokeBorder(Theme.border))
                        }.buttonStyle(.plain).accessibilityLabel("\(c.label): \(r.label)").accessibilityHint("Opens \(c.label) settings")
                    }
                }.padding(.horizontal, Theme.Space.xl)
            }
            HStack {
                Button("Test LLM default…") { confirmTest = true }.disabled(cfg.defaults[.llm] == nil || cfg.busy.contains("testdefault"))
                Button("Export Settings…") { exportConfig() }
                Button("Import Settings…") { importConfig() }
                Spacer()
                if let e = cfg.error { Text(e).font(Theme.meta).foregroundStyle(Theme.error).lineLimit(2) } else if let m = cfg.message { Text(m).font(Theme.meta).foregroundStyle(Theme.mastery).lineLimit(2) }
            }.padding(.horizontal, Theme.Space.xl)
        }.padding(.vertical, Theme.Space.md)
    }

    private var tabBar: some View {
        ScrollView(.horizontal, showsIndicators: true) {
            HStack(spacing: Theme.Space.xs) {
                ForEach(Capability.allCases) { c in
                    Button { tab = c; providerId = ProviderRegistry.providers(for: c).first?.id ?? "" } label: {
                        Label(c.label, systemImage: c.symbol).font(.system(.callout, design: .rounded, weight: tab == c ? .semibold : .regular))
                            .foregroundStyle(tab == c ? Theme.accent : Theme.textSecondary)
                            .padding(.horizontal, 12).padding(.vertical, 7)
                            .background(tab == c ? Theme.accent.opacity(0.12) : .clear, in: Capsule())
                    }.buttonStyle(.plain).accessibilityAddTraits(tab == c ? .isSelected : [])
                }
            }.padding(.horizontal, Theme.Space.xl).padding(.bottom, Theme.Space.sm)
        }
    }

    // MARK: Detail

    @ViewBuilder private var detail: some View {
        let s = spec
        VStack(alignment: .leading, spacing: Theme.Space.lg) {
            HStack(spacing: Theme.Space.md) {
                ProviderIcon(symbol: s.symbol, size: 42)
                VStack(alignment: .leading, spacing: 2) { Text(s.name).font(Theme.sectionTitle); Text(s.summary).foregroundStyle(Theme.textSecondary) }
                Spacer()
                if s.isLocal { Badge(text: "Local", color: Theme.accent) }
            }
            if !s.isImplemented {
                Notice(text: "\(s.name) isn’t supported yet. Learn Anyway has no adapter or verified endpoint for it.", tint: Theme.attention, symbol: "exclamationmark.triangle")
            } else if !s.supports(tab) {
                Notice(text: "\(s.name) can offer \(tab.label), but Learn Anyway can’t call it yet — only LLM requests have working adapters in this build. Nothing is configured or sent for \(tab.label).", tint: Theme.attention, symbol: "exclamationmark.triangle")
            } else {
                let conns = cfg.connections(for: s.id)
                ForEach(conns) { connectionCard($0) }
                if conns.isEmpty || s.allowsCustomBaseURL { addConnection(s, first: conns.isEmpty) }
            }
            if tab != .llm { futureOptions }
            Notice(text: "Every provider here is configured by you; keys stay in your Keychain. Learn Anyway has no server, so there are no server-managed providers.", symbol: "lock")
        }
    }

    private func addConnection(_ s: ProviderSpec, first: Bool) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.sm) {
            Text(first ? "Connect" : "Add another connection").font(Theme.cardTitle)
            if s.allowsCustomBaseURL {
                TextField("Name (optional)", text: $connName).accessibilityLabel("Connection name")
                TextField(s.baseURL.count > 8 ? s.baseURL : "https://api.example.com/v1", text: $baseURL).accessibilityLabel("Base URL")
                if !s.endpointVerified && s.id != "custom" { Text("This default endpoint hasn’t been verified by Learn Anyway.").font(Theme.meta).foregroundStyle(Theme.attention) }
                if baseURL.hasPrefix("http://"), !baseURL.contains("localhost"), !baseURL.contains("127.0.0.1") { Text("Plain http:// is refused except for localhost.").font(Theme.meta).foregroundStyle(Theme.error) }
            }
            if s.needsKey { SecretField(prompt: "API key", text: $key) }
            HStack {
                Button(cfg.busy.contains("connect-\(s.id)") ? "Checking…" : (s.needsKey ? "Save & enable" : "Connect")) {
                    cfg.connect(provider: s.id, name: connName.isEmpty ? nil : connName, baseURL: baseURL.isEmpty ? nil : baseURL, key: key) { key = ""; baseURL = ""; connName = "" }
                }.buttonStyle(.primary).disabled((s.needsKey && key.trimmed.isEmpty) || cfg.busy.contains("connect-\(s.id)"))
                if let u = s.accountURL, let url = URL(string: u) { Link("Get an API key", destination: url).font(.callout) }
            }
            if s.needsKey { Label("Verified with a free model-list request, then stored in the Keychain.", systemImage: "lock").font(Theme.meta).foregroundStyle(Theme.textSecondary) }
            if s.isLocal { Text("Needs Ollama running on this Mac. Local models cost nothing and never leave the device.").font(Theme.meta).foregroundStyle(Theme.textSecondary) }
        }
    }

    private func connectionCard(_ c: AIConnection) -> some View {
        let ms = cfg.models(c, tab)
        let def = cfg.defaults[tab]
        return Card {
            VStack(alignment: .leading, spacing: Theme.Space.md) {
                HStack {
                    Text(c.name).font(Theme.cardTitle)
                    StatusDot(color: c.status.color, text: c.status.label)
                    if def?.connectionId == c.id { Badge(text: "In use", color: Theme.accent) }
                    Spacer()
                    Button("Refresh") { cfg.refresh(c) }.disabled(cfg.busy.contains("refresh-\(c.id)"))
                    Button(c.enabled ? "Disable" : "Enable") { cfg.setEnabled(c, !c.enabled) }
                    Button("Remove…", role: .destructive) { confirmRemove = c }
                }
                Text(c.effectiveBaseURL).font(.system(.caption, design: .monospaced)).foregroundStyle(Theme.textSecondary).textSelection(.enabled)
                Text("Models").font(Theme.cardTitle)
                if ms.isEmpty { Text("No \(tab.label) models yet. Refresh the catalog or add one by id.").foregroundStyle(Theme.textSecondary) }
                ForEach(ms) { modelRow($0, c, isDefault: def?.connectionId == c.id && def?.modelId == $0.modelId) }
                HStack {
                    TextField("Add a model by id", text: $newModel).accessibilityLabel("Model id").onSubmit { add(c) }
                    Button("Add") { add(c) }.disabled(newModel.trimmed.isEmpty)
                }
                Text("Prices (USD per million tokens) are optional. OpenRouter fills them in; otherwise cost shows as Unknown, never zero.").font(Theme.meta).foregroundStyle(Theme.textSecondary)
            }
        }
    }

    private func add(_ c: AIConnection) { cfg.addModel(c, id: newModel.trimmed, cap: tab, inPrice: nil, outPrice: nil); newModel = "" }

    private func modelRow(_ m: AIModelRecord, _ c: AIConnection, isDefault: Bool) -> some View {
        let (bt, bc) = ModelBadge.text(m, local: c.spec?.isLocal == true)
        return HStack(spacing: Theme.Space.sm) {
            Button { cfg.setDefault(tab, c, m.modelId) } label: { Image(systemName: isDefault ? "largecircle.fill.circle" : "circle").foregroundStyle(isDefault ? Theme.accent : Theme.textSecondary) }
                .buttonStyle(.plain).help("Use as the \(tab.label) default").accessibilityLabel("Default \(tab.label) model").accessibilityValue(isDefault ? "Selected" : "Not selected")
            Text(m.modelId).font(.system(.callout, design: .monospaced)).lineLimit(1).truncationMode(.middle)
            Badge(text: bt, color: bc)
            Spacer()
            if c.spec?.isLocal != true {
                priceField("in", m.inputPricePerM) { var x = m; x.inputPricePerM = $0; cfg.update(x) }
                priceField("out", m.outputPricePerM) { var x = m; x.outputPricePerM = $0; cfg.update(x) }
            }
            if tab == .llm, let t = Optional(Target(connection: c, model: m)) {
                Button(cfg.busy.contains("test-\(m.id)") ? "…" : "Test") { cfg.test(t) }.disabled(cfg.busy.contains("test-\(m.id)"))
            }
            Button { cfg.remove(m) } label: { Image(systemName: "trash") }.buttonStyle(.plain).foregroundStyle(Theme.textSecondary).accessibilityLabel("Remove \(m.modelId)")
        }
    }

    private func priceField(_ label: String, _ v: Double?, _ set: @escaping (Double?) -> Void) -> some View {
        HStack(spacing: 3) {
            Text(label).font(Theme.meta).foregroundStyle(Theme.textSecondary)
            TextField("$", text: Binding(get: { v.map { String($0) } ?? "" }, set: { set(Double($0)) })).frame(width: 58).multilineTextAlignment(.trailing)
                .accessibilityLabel("\(label) price per million tokens")
        }
    }

    private var futureOptions: some View {
        let lines: [Capability: String] = [
            .imageGeneration: "image size, aspect ratio, quality, output format, count, reference images",
            .videoGeneration: "resolution, aspect ratio, duration, reference image, asynchronous job polling, local download",
            .tts: "voice, language, speed, audio format", .stt: "language, audio source, timestamps",
            .documentParsing: "formats, OCR, layout, page range, tables, output format", .webSearch: "result limit, depth, freshness, source URLs",
            .webFetch: "main-content extraction, timeout, size limit, redirect rules (with local-network and cloud-metadata blocking)",
            .embeddings: "dimensions, batch size, index", .vision: "image size and resolution limits, analysis prompt"]
        return VStack(alignment: .leading, spacing: 4) {
            Text("\(tab.label) options").font(Theme.cardTitle)
            Text("Not available yet. When an adapter exists, this tab will configure: \(lines[tab] ?? "").").font(.callout).foregroundStyle(Theme.textSecondary)
        }
    }

    // MARK: Actions

    private func testDefault() {
        guard let d = cfg.defaults[.llm], let c = cfg.connection(d.connectionId), let m = cfg.models.first(where: { $0.connectionId == c.id && $0.modelId == d.modelId && $0.capability == .llm }) else { return }
        cfg.test(Target(connection: c, model: m))
    }

    private func exportConfig() {
        let p = NSSavePanel(); p.nameFieldStringValue = "learn-anyway-ai-settings.json"; p.allowedContentTypes = [.json]
        p.message = "Exports providers, models, defaults and task routes. API keys are never included."
        guard p.runModal() == .OK, let url = p.url else { return }
        do { let e = JSONEncoder(); e.outputFormatting = [.prettyPrinted, .sortedKeys]; try e.encode(try GatewayConfigExport.make(cfg.gw.store)).write(to: url, options: .atomic) } catch { cfg.error = error.localizedDescription }
    }

    private func importConfig() {
        let p = NSOpenPanel(); p.allowedContentTypes = [.json]; p.message = "Imports provider references, models, defaults and routes. You’ll be asked to add API keys afterwards."
        guard p.runModal() == .OK, let url = p.url else { return }
        do {
            let c = try JSONDecoder().decode(GatewayConfigExport.self, from: Data(contentsOf: url))
            importMissing = try cfg.gw.importConfig(c); cfg.reload()
        } catch { cfg.error = "That file isn’t a valid settings export." }
    }
}

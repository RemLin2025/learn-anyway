import SwiftUI
import UniformTypeIdentifiers
import BraincellCore

/// Per-capability provider and model management. Providers whose adapter doesn't exist are listed but clearly marked, never shown as working.
struct ModelServicesView: View {
    @ObservedObject var cfg: AIConfig
    @Binding var tab: Capability
    @State private var providerId = ""
    @State private var key = ""
    @State private var baseURL = ""
    @State private var connName = ""
    @State private var newModel = ""
    @State private var confirmRemove: AIConnection?
    @State private var confirmTest = false
    @State private var importMissing: [String]?
    @State private var selectedModel: UUID?
    @State private var showHelp = false
    @State private var pendingImport: (export: GatewayConfigExport, summary: [String])?
    @EnvironmentObject private var app: AppModel

    private var providers: [ProviderSpec] { ProviderRegistry.providers(for: tab) }
    /// Defaults to the first provider that is already connected, so the catalog is what you see first.
    private var spec: ProviderSpec { providers.first { $0.id == providerId } ?? providers.first { p in cfg.connections.contains { $0.providerId == p.id } } ?? providers.first ?? ProviderRegistry.all[0] }

    var body: some View {
        AIPage(title: "Model Services", subtitle: "Credentials, endpoints and model catalogs for every capability.") {
            VStack(spacing: 0) {
                toolbar
                tabBar
                Divider()
                HStack(alignment: .top, spacing: 0) {
                    List(providers, selection: Binding(get: { spec.id }, set: { if let v = $0 { providerId = v; key = ""; baseURL = ""; connName = ""; selectedModel = nil } })) { p in
                        HStack(spacing: Theme.Space.md) {
                            ProviderIcon(symbol: p.symbol, size: 30)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(p.name).font(.system(.body, design: .rounded, weight: .medium))
                                let c = cfg.connections(for: p.id).first
                                StatusDot(color: p.supports(tab) ? (c?.status.color ?? Theme.textSecondary) : Theme.attention,
                                          text: !p.supports(tab) ? "Not supported yet" : (c?.status.label ?? "Not configured"))
                            }
                        }.padding(.vertical, 2).tag(p.id).accessibilityElement(children: .combine)
                    }.sidePanel().frame(width: 220)
                    ScrollView { detail.padding(Theme.Space.xl).frame(maxWidth: 860, alignment: .leading).frame(maxWidth: .infinity, alignment: .leading) }
                        .overlay(alignment: .trailing) {
                            if let id = selectedModel, let m = cfg.models.first(where: { $0.id == id }), let c = cfg.connection(m.connectionId) {
                                ModelInspector(cfg: cfg, model: m, connection: c) { selectedModel = nil }.shadow(color: .black.opacity(0.15), radius: 8, x: -2).transition(.move(edge: .trailing))
                            }
                        }
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
        .confirmationDialog("Import these settings?", isPresented: Binding(get: { pendingImport != nil }, set: { if !$0 { pendingImport = nil } }), titleVisibility: .visible) {
            Button("Merge into current settings") { applyImport() }
            Button("Cancel", role: .cancel) { pendingImport = nil }
        } message: { Text((pendingImport?.summary ?? []).joined(separator: "\n")) }
        .alert("Imported", isPresented: Binding(get: { importMissing != nil }, set: { if !$0 { importMissing = nil } })) {
            Button("OK") { importMissing = nil }
        } message: { Text((importMissing ?? []).isEmpty ? "Settings imported." : "Settings imported. Add API keys for: \((importMissing ?? []).joined(separator: ", ")).") }
    }

    // MARK: Header

    private var toolbar: some View {
        HStack(spacing: Theme.Space.sm) {
            Button("Test LLM default…") { confirmTest = true }.disabled(cfg.defaults[.llm] == nil || cfg.busy.contains("testdefault"))
            Button("Export Settings…") { exportConfig() }
            Button("Import Settings…") { importConfig() }
            Button { showHelp.toggle() } label: { Image(systemName: "info.circle").frame(width: 24, height: 24).contentShape(Rectangle()) }.buttonStyle(.plain)
                .accessibilityLabel("What do Export and Import do?").popover(isPresented: $showHelp, arrowEdge: .bottom) { helpText }
            Spacer()
            if let e = cfg.error { Text(e).font(Theme.meta).foregroundStyle(Theme.error).lineLimit(2) } else if let m = cfg.message { Text(m).font(Theme.meta).foregroundStyle(Theme.mastery).lineLimit(2) }
        }.padding(.horizontal, Theme.Space.xl).padding(.vertical, Theme.Space.md)
    }

    private var helpText: some View {
        VStack(alignment: .leading, spacing: Theme.Space.sm) {
            Text("Export & Import Settings").font(Theme.cardTitle)
            Text("**Included:** providers (name, endpoint, enabled), model lists with provider prices and your custom price estimates, default models, and every task’s model, fallback, prompt override and limits.").font(.callout)
            Text("**Never included:** API keys or any credential. Keys stay in your Keychain, so after importing on another Mac you add them again. Usage history, courses and documents aren’t part of it either.").font(.callout)
            Text("**Importing merges.** Providers and models that don’t exist yet are added; existing ones are kept (provider prices are refreshed). Defaults and task settings that appear in the file overwrite your current ones; tasks not in the file are untouched. You’ll see a summary and confirm before anything changes.").font(.callout)
        }.padding(Theme.Space.lg).frame(width: 360)
    }

    private var tabBar: some View {
        VStack(alignment: .leading) {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: Theme.Space.xs, alignment: .leading)], alignment: .leading, spacing: Theme.Space.xs) {
                ForEach(Capability.allCases) { c in
                    Button { tab = c; providerId = ProviderRegistry.providers(for: c).first?.id ?? "" } label: {
                        Label(c.label, systemImage: c.symbol).font(.system(.callout, design: .rounded, weight: tab == c ? .semibold : .regular))
                            .foregroundStyle(tab == c ? Theme.accent : Theme.textSecondary)
                            .padding(.horizontal, 12).padding(.vertical, 7)
                            .background(tab == c ? Theme.accent.opacity(0.12) : .clear, in: Capsule()).contentShape(Capsule())
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
        let def = cfg.defaults[tab]
        return Card {
            VStack(alignment: .leading, spacing: Theme.Space.md) {
                HStack {
                    Text(c.name).font(Theme.cardTitle)
                    StatusDot(color: c.status.color, text: c.status.label)
                    if def?.connectionId == c.id { Badge(text: "In use", color: Theme.accent) }
                    Spacer()
                    Menu {
                        Button("Refresh catalog") { cfg.refresh(c) }.disabled(cfg.busy.contains("refresh-\(c.id)"))
                        Button(c.enabled ? "Disable" : "Enable") { cfg.setEnabled(c, !c.enabled) }
                        Divider()
                        Button("Remove…", role: .destructive) { confirmRemove = c }
                    } label: { Label("Manage", systemImage: "ellipsis.circle") }.menuStyle(.borderlessButton).fixedSize()
                    Button(cfg.busy.contains("refresh-\(c.id)") ? "Refreshing…" : "Refresh") { cfg.refresh(c) }.disabled(cfg.busy.contains("refresh-\(c.id)"))
                }
                Text(c.effectiveBaseURL).font(.system(.caption, design: .monospaced)).foregroundStyle(Theme.textSecondary).textSelection(.enabled).lineLimit(1).truncationMode(.middle)
                ModelTable(cfg: cfg, connection: c, cap: tab, selected: $selectedModel)
                DisclosureGroup("Add a model by id") {
                    HStack {
                        TextField("Model id", text: $newModel).accessibilityLabel("Model id").onSubmit { add(c) }
                        Button("Add") { add(c) }.disabled(newModel.trimmed.isEmpty)
                    }.padding(.top, 4)
                }
            }
        }
    }

    private func add(_ c: AIConnection) { cfg.addModel(c, id: newModel.trimmed, cap: tab, inPrice: nil, outPrice: nil); newModel = "" }

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
        let p = NSOpenPanel(); p.allowedContentTypes = [.json]; p.message = "Choose a settings export. Nothing changes until you confirm."
        guard p.runModal() == .OK, let url = p.url else { return }
        do {
            let c = try JSONDecoder().decode(GatewayConfigExport.self, from: Data(contentsOf: url))
            let existingRoutes = (try? cfg.gw.store.routes()) ?? [:]
            let overwritten = c.routes.filter { r in existingRoutes[r.task].map { !$0.inherit } ?? false }.count
            let known = Set(cfg.connections.map { "\($0.providerId)/\($0.name)" })
            let newConns = c.connections.filter { !known.contains("\($0.providerId)/\($0.name)") }.count
            pendingImport = (c, ["\(c.connections.count) provider(s), \(newConns) new", "\(c.models.count) model(s)", "\(c.defaults.count) default model(s)", "\(c.routes.count) task setting(s), \(overwritten) would overwrite a custom setting you have now", "API keys: none — you’ll add them afterwards"])
        } catch { cfg.error = "That file isn’t a valid settings export." }
    }
    private func applyImport() {
        guard let c = pendingImport?.export else { return }
        pendingImport = nil
        do { importMissing = try cfg.gw.importConfig(c); cfg.reload() } catch { cfg.error = "Import failed: \(error.localizedDescription). Nothing was partially applied that you can’t fix by re-importing." }
    }
}

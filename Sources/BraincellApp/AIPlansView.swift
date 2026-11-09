import SwiftUI
import BraincellCore

/// Quick setup for multi-model gateways. Connecting here creates the same connection Model Services shows; there is no second credential store.
struct AIPlansView: View {
    @ObservedObject var cfg: AIConfig
    let openServices: (Capability) -> Void
    @State private var selected = ProviderRegistry.planProviders.first?.id ?? "openrouter"
    @State private var key = ""
    @State private var baseURL = ""
    @State private var showPlan = true
    @State private var dismissed: Set<UUID> = []
    @State private var confirmRemove: AIConnection?

    private var spec: ProviderSpec { ProviderRegistry.spec(selected) ?? ProviderRegistry.planProviders[0] }
    private var conn: AIConnection? { cfg.connections(for: selected).first }

    var body: some View {
        AIPage(title: "AI Provider Plans", subtitle: "Pick a provider and enter one key. Connected providers appear in Model Services automatically.") {
            HStack(alignment: .top, spacing: 0) {
                List(ProviderRegistry.planProviders, selection: Binding(get: { selected }, set: { if let v = $0 { selected = v; key = ""; baseURL = "" } })) { p in
                    HStack(spacing: Theme.Space.md) {
                        ProviderIcon(symbol: p.symbol)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(p.name).font(.system(.body, design: .rounded, weight: .medium))
                            let c = cfg.connections(for: p.id).first
                            Text(!p.isImplemented ? "Not supported yet" : (c?.status.label ?? "Not connected")).font(Theme.meta).foregroundStyle(c?.status.color ?? Theme.textSecondary)
                        }
                    }.padding(.vertical, 3).tag(p.id).accessibilityElement(children: .combine)
                }.sidePanel().frame(width: 270)
                ScrollView { detail.padding(Theme.Space.xl).frame(maxWidth: 680, alignment: .leading).frame(maxWidth: .infinity, alignment: .leading) }
            }
        }
        .confirmationDialog("Remove \(confirmRemove?.name ?? "")?", isPresented: Binding(get: { confirmRemove != nil }, set: { if !$0 { confirmRemove = nil } }), titleVisibility: .visible) {
            Button("Remove and delete key", role: .destructive) { if let c = confirmRemove { cfg.disconnect(c) }; confirmRemove = nil }
            Button("Cancel", role: .cancel) { confirmRemove = nil }
        } message: {
            if let c = confirmRemove { Text(cfg.usedByRoutes(c) > 0 ? "\(cfg.usedByRoutes(c)) default or task assignment(s) use this provider; they will revert to inheriting. The stored key is deleted from your Keychain." : "The stored key is deleted from your Keychain.") }
        }
    }

    @ViewBuilder private var detail: some View {
        VStack(alignment: .leading, spacing: Theme.Space.lg) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(spec.name).font(Theme.sectionTitle)
                    Text(spec.summary).foregroundStyle(Theme.textSecondary)
                    if let c = conn { StatusDot(color: c.status.color, text: c.status.label + (c.lastCheckedAt.map { " · checked \($0.formatted(date: .omitted, time: .shortened))" } ?? "")) }
                }
                Spacer()
                if let u = spec.accountURL, let url = URL(string: u) { Link(destination: url) { Label("Manage account", systemImage: "arrow.up.right.square") }.font(.callout) }
            }
            if !spec.isImplemented {
                Notice(text: "Learn Anyway can’t connect to \(spec.name) yet. No adapter exists in this build, and its endpoint hasn’t been verified, so it can’t be configured here.", tint: Theme.attention, symbol: "exclamationmark.triangle")
            } else if let c = conn {
                connected(c)
            } else { connectForm }
            planPreview
        }
    }

    private var connectForm: some View {
        VStack(alignment: .leading, spacing: Theme.Space.md) {
            HStack(spacing: Theme.Space.sm) {
                SecretField(prompt: "API key", text: $key)
                Button(cfg.busy.contains("connect-\(spec.id)") ? "Checking…" : "Save & enable") {
                    cfg.connect(provider: spec.id, name: nil, baseURL: baseURL.isEmpty ? nil : baseURL, key: key) { key = "" }
                }.buttonStyle(.primary).disabled(key.trimmed.isEmpty || cfg.busy.contains("connect-\(spec.id)"))
            }
            if spec.allowsCustomBaseURL {
                DisclosureGroup("Base URL (optional)") {
                    TextField(spec.baseURL, text: $baseURL).accessibilityLabel("Base URL")
                    if !spec.endpointVerified { Text("This default endpoint hasn’t been verified by Learn Anyway. Check it against \(spec.name)’s documentation.").font(Theme.meta).foregroundStyle(Theme.attention) }
                }
            }
            Label("The key is verified with a free model-list request, then stored in your Mac’s Keychain. It is never written to the database, backups or exports.", systemImage: "lock").font(Theme.meta).foregroundStyle(Theme.textSecondary)
            feedback
        }
    }

    @ViewBuilder private func connected(_ c: AIConnection) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.md) {
            Notice(text: "Connected. \(cfg.models(c).count) model(s) are available in Model Services → LLM. Connecting never changes your existing assignments on its own.", tint: Theme.mastery, symbol: "checkmark.circle")
            if !dismissed.contains(c.id), let s = try? cfg.gw.store.suggestedDefault(for: c) {
                Card {
                    VStack(alignment: .leading, spacing: Theme.Space.sm) {
                        Text("Use \(s.model.displayName) as your LLM default?").font(Theme.cardTitle)
                        Text("Before: \(s.replaces.map { "\($0.modelId) · \(cfg.connection($0.connectionId)?.name ?? "?")" } ?? "No default set")").font(.callout).foregroundStyle(Theme.textSecondary)
                        Text("After: \(s.model.displayName) · \(c.name)").font(.callout)
                        Text("Tasks that follow the default will use it. Tasks with their own setting are unchanged.").font(Theme.meta).foregroundStyle(Theme.textSecondary)
                        HStack { Button("Apply") { cfg.setDefault(.llm, c, s.model.modelId) }.buttonStyle(.primary); Button("Not now") { dismissed.insert(c.id) } }
                    }
                }
            }
            HStack(spacing: Theme.Space.sm) {
                SecretField(prompt: "Replace API key", text: $key)
                Button("Update key") { cfg.run("key-\(c.id)") { [gw = cfg.gw, k = key] in try await gw.replaceKey(c, apiKey: k); return "Key updated and verified." }; key = "" }.disabled(key.trimmed.isEmpty)
            }
            HStack {
                Button("Refresh models") { cfg.refresh(c) }.disabled(cfg.busy.contains("refresh-\(c.id)"))
                Button(c.enabled ? "Disable" : "Enable") { cfg.setEnabled(c, !c.enabled) }
                Button("Remove credentials…", role: .destructive) { confirmRemove = c }
                Spacer()
                Button("Open Model Services") { openServices(.llm) }
            }
            feedback
        }
    }

    @ViewBuilder private var feedback: some View {
        if let e = cfg.error { Text(e).font(.callout).foregroundStyle(Theme.error) }
        else if let m = cfg.message { Text(m).font(.callout).foregroundStyle(Theme.mastery) }
    }

    private var planPreview: some View {
        DisclosureGroup("View model plan", isExpanded: $showPlan) {
            VStack(alignment: .leading, spacing: Theme.Space.md) {
                Text("Capabilities offered").font(Theme.cardTitle)
                ForEach(Capability.allCases) { cap in
                    HStack(spacing: Theme.Space.sm) {
                        Image(systemName: cap.symbol).frame(width: 20).foregroundStyle(Theme.textSecondary)
                        Text(cap.label)
                        Spacer()
                        let (t, col): (String, Color) = spec.supports(cap) ? ((conn?.status == .ready) ? ("Available", Theme.mastery) : ("Supported", Theme.accent))
                            : spec.declared.contains(cap) ? ("Offered by provider · not supported here yet", Theme.attention) : ("Not offered", Theme.textSecondary)
                        Text(t).font(Theme.meta).foregroundStyle(col)
                    }.font(.callout).accessibilityElement(children: .combine)
                }
                if let c = conn {
                    let ms = cfg.models(c, .llm)
                    Text("LLM models (\(ms.count))").font(Theme.cardTitle).padding(.top, Theme.Space.sm)
                    ForEach(ms.prefix(12)) { Text($0.modelId).font(.system(.callout, design: .monospaced)) }
                    if ms.count > 12 { Text("…and \(ms.count - 12) more in Model Services").font(Theme.meta).foregroundStyle(Theme.textSecondary) }
                } else if spec.isImplemented { Text("Connect to load this provider’s real model catalog. Learn Anyway doesn’t ship a model list that could go stale.").font(Theme.meta).foregroundStyle(Theme.textSecondary) }
            }.padding(.top, Theme.Space.sm)
        }.font(.system(.body, design: .rounded, weight: .semibold))
    }
}

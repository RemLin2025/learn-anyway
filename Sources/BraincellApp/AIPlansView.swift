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

    private func planRow(_ p: ProviderSpec) -> some View {
        HStack(spacing: Theme.Space.md) {
            ProviderIcon(symbol: p.symbol)
            VStack(alignment: .leading, spacing: 2) {
                Text(p.name).font(.system(.body, design: .rounded, weight: .medium))
                let c = cfg.connections(for: p.id).first
                Text(!p.isImplemented ? "Not supported yet" : (c?.status.label ?? "Not connected")).font(Theme.meta).foregroundStyle(c?.status.color ?? Theme.textSecondary)
            }
        }.padding(.vertical, 3).tag(p.id).accessibilityElement(children: .combine)
    }

    var body: some View {
        AIPage(title: "AI Provider Plans", subtitle: "Pick a provider and enter one key. Connected providers appear in Model Services automatically.") {
            HStack(alignment: .top, spacing: 0) {
                List(selection: Binding(get: { selected }, set: { if let v = $0 { selected = v; key = ""; baseURL = "" } })) {
                    Section { ForEach(ProviderRegistry.planProviders.filter { $0.isImplemented }) { planRow($0) } }
                    let unsupported = ProviderRegistry.planProviders.filter { !$0.isImplemented }
                    if !unsupported.isEmpty { Section("Not supported yet") { ForEach(unsupported) { planRow($0) } } }
                }.sidePanel().frame(width: 220)
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
                Button("Open Model Services") { openServices(.llm) }.fixedSize()
            }
            feedback
        }
    }

    @ViewBuilder private var feedback: some View {
        if let e = cfg.error { Text(e).font(.callout).foregroundStyle(Theme.error) }
        else if let m = cfg.message { Text(m).font(.callout).foregroundStyle(Theme.mastery) }
    }

    @State private var openCaps: Set<Capability> = [.llm]
    @EnvironmentObject private var app: AppModel

    private var planPreview: some View {
        VStack(alignment: .leading, spacing: Theme.Space.lg) {
            if let c = conn { inUse(c) }
            VStack(alignment: .leading, spacing: Theme.Space.xs) {
                Text("Capabilities").font(Theme.cardTitle)
                Text("Offered by the provider, compatible models found, and whether Learn Anyway can call them are different things, so each is shown separately.").font(Theme.meta).foregroundStyle(Theme.textSecondary)
                ForEach(Capability.allCases) { cap in capRow(cap) }
            }
        }
    }

    private func capRow(_ cap: Capability) -> some View {
        let offered = spec.offers(cap), adapter = spec.supports(cap)
        let ms = conn.map { cfg.models($0, cap) } ?? []
        let open = openCaps.contains(cap)
        return VStack(alignment: .leading, spacing: 0) {
            Button { if open { openCaps.remove(cap) } else { openCaps.insert(cap) } } label: {
                HStack(spacing: Theme.Space.sm) {
                    Image(systemName: open ? "chevron.down" : "chevron.right").font(.caption2).frame(width: 12).foregroundStyle(Theme.textSecondary)
                    Image(systemName: cap.symbol).frame(width: 20).foregroundStyle(Theme.textSecondary)
                    Text(cap.label).font(.system(.callout, design: .rounded, weight: .medium))
                    Spacer()
                    Text(!offered ? "Not offered" : adapter ? (ms.isEmpty ? "Supported · no models yet" : "Supported · \(ms.count) model\(ms.count == 1 ? "" : "s")") : "Offered · no adapter yet")
                        .font(Theme.meta).foregroundStyle(adapter && !ms.isEmpty ? Theme.mastery : (offered ? Theme.attention : Theme.textSecondary))
                }.padding(.vertical, 8).padding(.horizontal, 4).contentShape(Rectangle())
            }.buttonStyle(.plain).accessibilityLabel("\(cap.label), \(open ? "expanded" : "collapsed")")
            if open {
                VStack(alignment: .leading, spacing: 6) {
                    step("Provider offers this capability", offered)
                    step("Compatible models found", !ms.isEmpty)
                    step("Learn Anyway has an adapter", adapter)
                    step("Configured and available", adapter && conn?.status == .ready && !ms.isEmpty)
                    step("Assigned to a task", ms.contains { !cfg.assignments(of: $0).isEmpty })
                    if !offered { Text("\(spec.name) doesn’t advertise \(cap.label). There are no verified compatible models.").font(Theme.meta).foregroundStyle(Theme.textSecondary) }
                    else if !adapter { Text("\(spec.name) can offer this, but its model list isn’t read and nothing is sent for \(cap.label) in this build, so no model is claimed usable.").font(Theme.meta).foregroundStyle(Theme.attention) }
                    else if conn == nil { Text("Connect to load this provider’s real model catalog; no list is bundled that could go stale.").font(Theme.meta).foregroundStyle(Theme.textSecondary) }
                    ForEach(ms.prefix(15)) { m in
                        let n = cfg.assignments(of: m).count
                        HStack { Text(m.displayName).lineLimit(1); Spacer(); Text(n == 0 ? "not assigned" : "\(n) task\(n == 1 ? "" : "s")").font(Theme.meta).foregroundStyle(n == 0 ? Theme.textSecondary : Theme.accent) }.font(.callout)
                    }
                    if ms.count > 15 { Button("Show all \(ms.count) in Model Services") { openServices(cap) }.buttonStyle(.plain).foregroundStyle(Theme.accent).font(.callout) }
                }.padding(.leading, 40).padding(.bottom, 8)
            }
            Divider().opacity(0.5)
        }
    }

    private func step(_ t: String, _ ok: Bool) -> some View {
        HStack(spacing: 6) { Image(systemName: ok ? "checkmark.circle.fill" : "circle").foregroundStyle(ok ? Theme.mastery : Theme.textSecondary.opacity(0.6)); Text(t).foregroundStyle(ok ? Theme.textPrimary : Theme.textSecondary) }.font(Theme.meta)
    }

    /// Models from this provider that tasks actually resolve to, with the tasks they serve (from the router, so inheritance is explicit).
    private func inUse(_ c: AIConnection) -> some View {
        let used = cfg.models(c).filter { !cfg.assignments(of: $0).isEmpty }
        return VStack(alignment: .leading, spacing: Theme.Space.sm) {
            Text("In use").font(Theme.cardTitle)
            if used.isEmpty { Text("No task currently resolves to a \(c.name) model.").font(.callout).foregroundStyle(Theme.textSecondary) }
            ForEach(used) { m in
                Card {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(m.displayName).font(.system(.callout, design: .rounded, weight: .semibold))
                        ForEach(cfg.assignments(of: m).sorted { $0.task.title < $1.task.title }, id: \.task.id) { a in
                            Button { app.openWorkflow(task: a.task.id) } label: {
                                HStack { Text(a.task.title); Spacer(); Text(a.inherited ? "inherits default" : "custom").font(Theme.meta).foregroundStyle(Theme.textSecondary); Image(systemName: "chevron.right").font(.caption2).foregroundStyle(Theme.textSecondary) }.font(.callout).contentShape(Rectangle())
                            }.buttonStyle(.plain).help("Open in AI Workflow")
                        }
                    }
                }
            }
        }
    }
}

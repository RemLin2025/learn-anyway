import SwiftUI
import BraincellCore

enum SettingsSection: String, CaseIterable, Identifiable {
    case general = "General", plans = "AI Provider Plans", services = "Model Services", workflow = "AI Workflow", usage = "Usage & Analytics"
    var id: String { rawValue }
    var symbol: String {
        switch self { case .general: "gearshape"; case .plans: "creditcard"; case .services: "cpu"; case .workflow: "point.3.connected.trianglepath.dotted"; case .usage: "chart.bar.xaxis" }
    }
}

/// App-wide settings: a persistent left navigation and one content pane. AI sections share one gateway (AIConfig).
struct SettingsView: View {
    @EnvironmentObject var model: AppModel
    @AppStorage("settingsSection") private var raw = SettingsSection.general.rawValue
    @State private var servicesTab: Capability = .llm
    private var section: SettingsSection { SettingsSection(rawValue: raw) ?? .general }

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: Theme.Space.xs) {
                ForEach(SettingsSection.allCases) { s in
                    Button { raw = s.rawValue } label: {
                        Label(s.rawValue, systemImage: s.symbol).font(.system(.body, design: .rounded, weight: section == s ? .semibold : .regular))
                            .foregroundStyle(section == s ? Theme.accent : Theme.textPrimary)
                            .padding(.horizontal, Theme.Space.md).padding(.vertical, 9).frame(maxWidth: .infinity, alignment: .leading)
                            .background(section == s ? Theme.accent.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: Theme.Radius.control))
                            .contentShape(Rectangle())
                    }.buttonStyle(.plain).accessibilityAddTraits(section == s ? .isSelected : [])
                }
                Spacer()
            }
            .padding(Theme.Space.md).frame(width: 184).background(Theme.surface)
            .overlay(alignment: .trailing) { Rectangle().fill(Theme.border).frame(width: 1) }
            Group {
                switch section {
                case .general: GeneralSettings()
                default:
                    if let cfg = model.aiConfig {
                        switch section {
                        case .plans: AIPlansView(cfg: cfg, openServices: { cap in servicesTab = cap; raw = SettingsSection.services.rawValue })
                        case .services: ModelServicesView(cfg: cfg, tab: $servicesTab)
                        case .workflow: AIWorkflowView(cfg: cfg)
                        default: UsageView(cfg: cfg)
                        }
                    } else { EmptyStateView(symbol: "exclamationmark.triangle", title: "Unavailable", message: "The database couldn’t be opened, so AI settings can’t load.") }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity).background(Theme.background)
        }
        .buttonStyle(.secondary).textFieldStyle(AppFieldStyle()).tint(Theme.accent)
    }
}

private struct GeneralSettings: View {
    @EnvironmentObject var model: AppModel
    @State private var apiKey = ""

    var body: some View {
        ScrollView { VStack(alignment: .leading, spacing: Theme.Space.lg) {
            PageHeader(title: "Settings")
            SettingsCard("General") {
            Picker("Appearance", selection: Binding(get: { model.appearance }, set: { model.setAppearance($0) })) {
                ForEach(AppearanceSetting.allCases, id: \.self) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            Stepper("Code font size: \(model.codeFontSize) pt", value: Binding(get: { model.codeFontSize }, set: { model.setCodeFontSize($0) }), in: 10...24)
            Toggle("Show coach suggestions while practising", isOn: Binding(get: { model.coachEnabled }, set: { model.setCoachEnabled($0) }))
            Picker("Confidence check", selection: Binding(get: { model.confidencePrompts }, set: { model.setConfidencePrompts($0) })) {
                Text("Only when it matters (default)").tag("minimal"); Text("Never").tag("off")
            }
            }
            SettingsCard("Code execution") {
                Toggle("Allow Learn Anyway to run my code in a sandbox", isOn: Binding(get: { model.codeExecutionEnabled }, set: { model.setCodeExecution($0) }))
                let langs = model.sandboxLanguages.map { $0.rawValue.capitalized }.sorted()
                Text(langs.isEmpty ? (model.sandboxProblem ?? "No toolchain found.") : "Available here: \(langs.joined(separator: ", ")). " + (model.sandboxProblem ?? ""))
                    .font(.caption).foregroundStyle(Theme.textSecondary)
                Text("Code runs in a separate, locked-down process: no network, no access to your files, one temporary folder, strict time, memory and output limits. Off by default; nothing runs unless you switch this on.")
                    .font(.caption).foregroundStyle(Theme.textSecondary)
            }
            SettingsCard("Direct Anthropic requests (legacy, optional)") {
                Notice(text: "Superseded: connect Anthropic under Model Services and the gateway handles routing, usage and budgets. This older switch is kept so existing setups keep working.", symbol: "arrow.triangle.branch")
                Toggle("Allow sending requests straight to the Anthropic API", isOn: Binding(get: { model.directAPIEnabled }, set: { model.setDirectAPI($0) }))
                if model.directAPIEnabled {
                    HStack {
                        SecureField(model.hasAPIKey ? "Key saved in your Keychain" : "Anthropic API key", text: $apiKey).textContentType(.password)
                        Button("Save") { model.saveAPIKey(apiKey); apiKey = "" }.disabled(apiKey.trimmingCharacters(in: .whitespaces).isEmpty)
                        Button("Remove") { model.saveAPIKey("") }.disabled(!model.hasAPIKey)
                    }
                    TextField("Model", text: Binding(get: { model.directAPIModel }, set: { model.setDirectAPIModel($0) }))
                }
                Text("Off by default. When on, you can send a prepared request to Anthropic instead of copying it to ChatGPT. The full request text, including any document excerpts and answers it lists, leaves your device and is billed to your API account. Learn Anyway asks before every send and checks the reply exactly like a pasted one. The key is kept only in the macOS Keychain, never in backups.")
                    .font(.caption).foregroundStyle(Theme.textSecondary)
            }
            UpdatesCard()
            SettingsCard("Backup & restore") {
                HStack { Button("Create Backup…") { model.createBackup() }; Button("Restore from Backup…") { model.restoreBackup() } }
                Text("A backup is a folder with your database and imported files. Learn Anyway stores no passwords or keys, so none are included. Restoring replaces current data after saving a safety copy.")
                    .font(.caption).foregroundStyle(Theme.textSecondary)
            }
            SettingsCard("About your data") {
            LabeledContent("Data location") {
                Text(ManagedStorage.defaultRoot().path).textSelection(.enabled).font(.caption).foregroundStyle(Theme.textSecondary)
            }
            LabeledContent("ChatGPT") { Text("Manual workflow only: Learn Anyway never signs in to or automates ChatGPT.").font(.caption).foregroundStyle(Theme.textSecondary) }
            }
        }.padding(Theme.Space.xl).frame(maxWidth: 640, alignment: .leading).frame(maxWidth: .infinity) }
        .background(Theme.background)
    }
}

private struct SettingsCard<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content
    init(_ title: String, @ViewBuilder content: () -> Content) { self.title = title; self.content = content() }
    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: Theme.Space.md) {
                Text(title).font(Theme.cardTitle).accessibilityAddTraits(.isHeader)
                content
            }
        }
    }
}

private struct UpdatesCard: View {
    @EnvironmentObject var model: AppModel
    @AppStorage("updateCheckOnLaunch") private var onLaunch = true
    var body: some View { Inner(u: model.updater, onLaunch: $onLaunch) }
    struct Inner: View {
        @ObservedObject var u: UpdateModel
        @Binding var onLaunch: Bool
        var body: some View {
            SettingsCard("Updates") {
                if u.isAvailable {
                    Toggle("Check for updates when Learn Anyway opens", isOn: $onLaunch)
                    HStack {
                        Button(u.state == .checking ? "Checking…" : "Check for updates") { u.check() }.disabled(u.state == .checking)
                        if case .available = u.state { Button("Update now") { u.update() }.buttonStyle(.primary) }
                        Text(status).font(.callout).foregroundStyle(Theme.textSecondary)
                    }
                    Text("Compares this app with the source folder it was installed from (\(u.root ?? "")), and with its upstream branch if it has one. Updating rebuilds and reinstalls from that folder, then restarts. Your data is untouched.")
                        .font(.caption).foregroundStyle(Theme.textSecondary)
                } else {
                    Text("In-app updates aren’t set up for this copy. Run scripts/install-macos.sh once from the project folder; after that the app can update itself.").font(.callout).foregroundStyle(Theme.textSecondary)
                }
            }
        }
        private var status: String {
            switch u.state { case .upToDate: "You’re up to date."; case .available(let w): "Update available: \(w)."; case .failed(let m): "Check failed: \(m)"; case .updating: "Updating…"; default: "" }
        }
    }
}

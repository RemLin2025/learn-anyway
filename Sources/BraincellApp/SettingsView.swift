import SwiftUI
import BraincellCore

struct SettingsView: View {
    @EnvironmentObject var model: AppModel
    @State private var apiKey = ""

    var body: some View {
        Form {
            Picker("Appearance", selection: Binding(get: { model.appearance }, set: { model.setAppearance($0) })) {
                ForEach(AppearanceSetting.allCases, id: \.self) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            Stepper("Code font size: \(model.codeFontSize) pt", value: Binding(get: { model.codeFontSize }, set: { model.setCodeFontSize($0) }), in: 10...24)
            Toggle("Show coach suggestions while practising", isOn: Binding(get: { model.coachEnabled }, set: { model.setCoachEnabled($0) }))
            Picker("Confidence check", selection: Binding(get: { model.confidencePrompts }, set: { model.setConfidencePrompts($0) })) {
                Text("Only when it matters (default)").tag("minimal"); Text("Never").tag("off")
            }
            Section("Code execution") {
                Toggle("Allow Braincell to run my code in a sandbox", isOn: Binding(get: { model.codeExecutionEnabled }, set: { model.setCodeExecution($0) }))
                let langs = model.sandboxLanguages.map { $0.rawValue.capitalized }.sorted()
                Text(langs.isEmpty ? (model.sandboxProblem ?? "No toolchain found.") : "Available here: \(langs.joined(separator: ", ")). " + (model.sandboxProblem ?? ""))
                    .font(.caption).foregroundStyle(.secondary)
                Text("Code runs in a separate, locked-down process: no network, no access to your files, one temporary folder, strict time, memory and output limits. Off by default; nothing runs unless you switch this on.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Direct AI requests (optional)") {
                Toggle("Allow sending requests straight to the Anthropic API", isOn: Binding(get: { model.directAPIEnabled }, set: { model.setDirectAPI($0) }))
                if model.directAPIEnabled {
                    HStack {
                        SecureField(model.hasAPIKey ? "Key saved in your Keychain" : "Anthropic API key", text: $apiKey).textContentType(.password)
                        Button("Save") { model.saveAPIKey(apiKey); apiKey = "" }.disabled(apiKey.trimmingCharacters(in: .whitespaces).isEmpty)
                        Button("Remove") { model.saveAPIKey("") }.disabled(!model.hasAPIKey)
                    }
                    TextField("Model", text: Binding(get: { model.directAPIModel }, set: { model.setDirectAPIModel($0) }))
                }
                Text("Off by default. When on, you can send a prepared request to Anthropic instead of copying it to ChatGPT. The full request text, including any document excerpts and answers it lists, leaves your device and is billed to your API account. Braincell asks before every send and checks the reply exactly like a pasted one. The key is kept only in the macOS Keychain, never in backups.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Backup & restore") {
                HStack { Button("Create Backup…") { model.createBackup() }; Button("Restore from Backup…") { model.restoreBackup() } }
                Text("A backup is a folder with your database and imported files. Braincell stores no passwords or keys, so none are included. Restoring replaces current data after saving a safety copy.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            LabeledContent("Data location") {
                Text(ManagedStorage.defaultRoot().path).textSelection(.enabled).font(.caption).foregroundStyle(.secondary)
            }
            LabeledContent("ChatGPT") { Text("Manual workflow only: Braincell never signs in to or automates ChatGPT.").font(.caption).foregroundStyle(.secondary) }
        }
        .formStyle(.grouped)
        .frame(width: 560, height: 740)
    }
}

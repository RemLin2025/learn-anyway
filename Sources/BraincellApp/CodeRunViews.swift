import SwiftUI
import BraincellCore

/// "Run Tests" and "Try it" for coding questions. Everything runs in a sandboxed child process, only after the
/// learner has switched code execution on in Settings.
struct CodeRunPanel: View {
    @ObservedObject var pm: PracticeModel
    let spec: QuestionSpec
    @State private var showTry = false
    @State private var stdin = ""

    var body: some View {
        let lang = CodeLanguage(name: spec.answer.language ?? "python") ?? .python
        let runner = pm.app.codeRunner
        let available = runner.languages.contains(lang)
        let tests = spec.answer.tests ?? []
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Button { Task { await pm.runTests() } } label: { Label("Run Tests", systemImage: "play") }
                    .disabled(!available || tests.isEmpty || pm.running).help(tests.isEmpty ? "This question has no automated tests" : "Run your code against the tests in a sandbox")
                Button { showTry.toggle() } label: { Label("Try it…", systemImage: "terminal") }.disabled(!available || pm.running)
                if pm.running { ProgressView().controlSize(.small) }
                Spacer()
            }
            if !available {
                HStack(alignment: .top) {
                    Text(runner.unavailableReason.map { pm.app.codeExecutionEnabled ? $0 : "Running code is switched off. " + $0 } ?? "\(lang.rawValue.capitalized) can’t be run on this Mac.")
                        .font(.caption).foregroundStyle(Theme.textSecondary)
                    if !pm.app.codeExecutionEnabled { SettingsLink { Text("Turn on in Settings") }.font(.caption) }
                }
            } else if !tests.isEmpty {
                Text("Runs in a sandbox: no network, no files outside a temporary folder, \(Int(SandboxLimits.run.wallSeconds)) s per test.").font(.caption).foregroundStyle(Theme.textSecondary)
            }
            if let report = pm.testReport { TestReportView(report: report) }
            if showTry {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Input (stdin)").font(.caption).foregroundStyle(Theme.textSecondary)
                    TextEditor(text: $stdin).font(.system(.caption, design: .monospaced)).frame(height: 60).fieldSurface().accessibilityLabel("Program input")
                    Button("Run") { Task { await pm.tryRun(stdin: stdin) } }.disabled(pm.running)
                    if let m = pm.tryMessage { Text(m).font(.caption).foregroundStyle(Theme.attention) }
                    if let o = pm.tryOutput { OutputView(output: o) }
                }
            }
        }
    }
}

struct OutputView: View {
    let output: CodeRunOutput
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(statusText).font(.caption.weight(.semibold)).foregroundStyle(ok ? Theme.mastery : Theme.attention)
            if let c = output.compileOutput, output.termination == .compileFailed { Text(c).font(.system(.caption, design: .monospaced)).textSelection(.enabled) }
            if !output.stdout.isEmpty { Text(output.stdout).font(.system(.caption, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(6).background(Theme.elevated, in: RoundedRectangle(cornerRadius: 6)) }
            if !output.stderr.isEmpty, output.termination != .compileFailed { Text(output.stderr).font(.system(.caption, design: .monospaced)).foregroundStyle(Theme.attention).textSelection(.enabled) }
        }
    }
    private var ok: Bool { if case .exited(0) = output.termination { true } else { false } }
    private var statusText: String {
        switch output.termination {
        case .exited(let c): "Finished (exit code \(c)) in \(String(format: "%.2f", output.wallSeconds)) s"
        case .signaled(let s): "Crashed (signal \(s))"
        case .timedOut: "Stopped: took too long"
        case .outputLimit: "Stopped: too much output"
        case .memoryLimit: "Stopped: used too much memory"
        case .compileFailed: "Didn’t compile"
        case .internalError(let m): "Couldn’t run: \(m)"
        }
    }
}

struct TestReportView: View {
    let report: CodeTestReport
    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 6) {
                switch report {
                case .unavailable(let r): Label(r, systemImage: "nosign").font(.callout).foregroundStyle(Theme.textSecondary)
                case .internalError(let m): Label("The test runner failed: \(m)", systemImage: "exclamationmark.triangle").foregroundStyle(Theme.attention)
                case .compileError(let m):
                    Label("It didn’t compile", systemImage: "xmark.octagon").foregroundStyle(Theme.attention).font(.headline)
                    Text(m).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                case .ran(let outcomes):
                    let passed = outcomes.filter { $0.status == .passed }.count
                    Label("\(passed) of \(outcomes.count) tests passed", systemImage: passed == outcomes.count ? "checkmark.circle.fill" : "circle.dotted")
                        .font(.headline).foregroundStyle(passed == outcomes.count ? Theme.mastery : Theme.attention)
                    ForEach(outcomes) { o in
                        VStack(alignment: .leading, spacing: 2) {
                            HStack {
                                Image(systemName: o.status == .passed ? "checkmark" : "xmark").foregroundStyle(o.status == .passed ? Theme.mastery : Theme.attention)
                                Text(o.name + (o.hidden ? " (hidden)" : ""))
                                Spacer()
                                Text(label(o.status)).font(.caption).foregroundStyle(Theme.textSecondary)
                            }
                            if o.status != .passed, !o.hidden {
                                if let i = o.input, !i.isEmpty { Text("input: \(i)").font(.system(.caption2, design: .monospaced)).foregroundStyle(Theme.textSecondary) }
                                if let e = o.expected { Text("expected: \(e)").font(.system(.caption2, design: .monospaced)).foregroundStyle(Theme.textSecondary) }
                                if o.status == .failed { Text("got: \(o.actual)").font(.system(.caption2, design: .monospaced)).foregroundStyle(Theme.attention) }
                                if !o.stderr.isEmpty { Text(o.stderr).font(.system(.caption2, design: .monospaced)).foregroundStyle(Theme.attention).lineLimit(4) }
                            }
                        }.accessibilityElement(children: .combine)
                    }
                }
            }
        }
    }
    private func label(_ s: TestStatus) -> String {
        switch s { case .passed: "passed"; case .failed: "wrong output"; case .timedOut: "took too long"; case .crashed: "crashed"; case .outputLimit: "too much output"; case .memoryLimit: "too much memory" }
    }
}

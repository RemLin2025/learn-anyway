import SwiftUI
import AppKit

/// Checks whether the source folder this app was installed from has changed (local edits or new upstream commits) and
/// can rebuild and reinstall from it. It only works for an app installed with scripts/install-macos.sh, which stamps
/// the source folder and a content fingerprint into Info.plist; otherwise the feature stays hidden.
@MainActor
final class UpdateModel: ObservableObject {
    enum State: Equatable { case idle, checking, upToDate, available(String), updating(Progress), failed(String) }
    @Published private(set) var state = State.idle
    @Published var dismissed = false

    /// What the banner shows while updating. `fraction` is an estimate from how long each step took last time.
    struct Progress: Equatable {
        var step = 0, steps = Steps.names.count
        var label = "Getting ready"
        var fraction = 0.0
        var elapsed = 0, remaining: Int?
    }
    enum Steps {
        static let names = ["Fetching changes", "Building the core", "Building the app", "Packaging", "Installing"]
        static let defaults: [Double] = [3, 45, 15, 8, 4]                                    // first-run guesses, replaced by measured times
        static func expected() -> [Double] {
            let saved = UserDefaults.standard.array(forKey: "updateStepSeconds") as? [Double]
            return saved?.count == names.count ? saved! : defaults
        }
        /// Which step a log line belongs to (nil = no change).
        static func index(of line: String) -> Int? {
            if line.contains("Packaging") { return 3 }
            if line.contains("Installing") || line.contains("Quitting") { return 4 }
            if line.contains("Braincell.app") { return 2 }
            if line.contains("BraincellCore") || line.contains("GRDB") { return 1 }
            return nil
        }
    }
    private var cancelled = false

    let root: String?
    private let installed: String?
    private var behind = 0
    private var poll: Task<Void, Never>?

    init(bundle: Bundle = .main) {
        let r = bundle.object(forInfoDictionaryKey: "SourceRoot") as? String
        root = r.flatMap { FileManager.default.fileExists(atPath: $0 + "/scripts/install-macos.sh") ? $0 : nil }
        installed = (bundle.object(forInfoDictionaryKey: "SourceFingerprint") as? String).flatMap { $0.isEmpty ? nil : $0 }
    }

    var isAvailable: Bool { root != nil && installed != nil }
    var checkOnLaunch: Bool { UserDefaults.standard.object(forKey: "updateCheckOnLaunch") as? Bool ?? true }

    func check() {
        guard let root, let installed, state != .checking, !isUpdating else { return }
        state = .checking; dismissed = false
        Task {
            let r = await Task.detached { Self.compute(root: root, installed: installed) }.value
            behind = r.behind; state = r.state
        }
    }
    func markIdle() { state = .idle }
    private var isUpdating: Bool { if case .updating = state { true } else { false } }

    nonisolated static func compute(root: String, installed: String) -> (state: State, behind: Int) {
        let fp = sh("scripts/source-fingerprint.sh", in: root)
        guard fp.code == 0 else { return (.failed("Couldn’t read the source folder: \(fp.out.suffix(200))"), 0) }
        var reasons: [String] = []
        if fp.out.trimmingCharacters(in: .whitespacesAndNewlines) != installed { reasons.append("the source has changed since this build") }
        var behind = 0
        if sh("git rev-parse --abbrev-ref --symbolic-full-name @{u}", in: root).code == 0 {       // only when the branch tracks a remote
            _ = sh("git fetch --quiet", in: root, timeout: 20)                                       // offline is fine: we just skip the remote check
            behind = Int(sh("git rev-list --count HEAD..@{u}", in: root).out.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
            if behind > 0 { reasons.append("\(behind) new commit\(behind == 1 ? "" : "s") upstream") }
        }
        return (reasons.isEmpty ? .upToDate : .available(reasons.joined(separator: " and ")), behind)
    }

    func update() {
        guard let root, !isUpdating else { return }
        cancelled = false
        state = .updating(Progress(label: Steps.names[0]))
        let ready = root + "/.build-manual/update-ready", log = root + "/.build-manual/update.log", pull = behind > 0
        try? FileManager.default.removeItem(atPath: log)
        let expected = Steps.expected()
        let total = expected.reduce(0, +), began = Date()
        poll = Task { [weak self] in
            var step = pull ? 0 : 1, stepStart = Date(), measured = expected
            while !Task.isCancelled {
                if FileManager.default.fileExists(atPath: ready) { NSApp.terminate(nil); return }      // build finished: quit so the script can swap the app and relaunch
                if let t = try? String(contentsOfFile: log, encoding: .utf8) {
                    for line in t.split(separator: "\n") where line.hasPrefix("»") { if let k = Steps.index(of: String(line)), k > step {
                        measured[step] = Date().timeIntervalSince(stepStart)          // remember how long the finished step really took
                        UserDefaults.standard.set(measured, forKey: "updateStepSeconds")
                        step = k; stepStart = Date()
                    } }
                }
                let inStep = Date().timeIntervalSince(stepStart)
                let done = expected[..<step].reduce(0, +) + min(inStep, expected[step] * 0.95)
                let el = Int(Date().timeIntervalSince(began))
                self?.setProgress(Progress(step: step, label: Steps.names[step], fraction: min(0.98, done / total), elapsed: el, remaining: max(1, Int(total - done))))
                try? await Task.sleep(nanoseconds: 500_000_000)
            }
        }
        Task {
            let r = await Task.detached { () -> (Int32, String) in
                if pull { let p = Self.sh("git pull --ff-only", in: root, timeout: 120); if p.code != 0 { return (p.code, "Couldn’t pull the new commits: " + p.out) } }
                return Self.sh("mkdir -p .build-manual && LEARN_ANYWAY_SELF_UPDATE=1 scripts/install-macos.sh > .build-manual/update.log 2>&1; c=$?; [ $c -ne 0 ] && tail -n 12 .build-manual/update.log; exit $c", in: root, timeout: 1800)
            }.value
            poll?.cancel()
            if cancelled { state = .idle; return }
            if r.0 != 0 { state = .failed(r.1.trimmingCharacters(in: .whitespacesAndNewlines).suffix(600).description) }
        }
    }

    /// Stops a running update. The installed app is only replaced in the last second, so cancelling never leaves a half-installed app.
    func cancelUpdate() {
        guard let root, isUpdating else { return }
        cancelled = true; poll?.cancel()
        state = .idle
        Task.detached { _ = Self.sh("pkill -f scripts/install-macos.sh; pkill -f 'swiftc.*out-release'; rm -f .build-manual/update-ready", in: root, timeout: 10) }
    }
    private func setProgress(_ p: Progress) { if isUpdating { state = .updating(p) } }

    final class Handle: @unchecked Sendable { let p: Process; init(_ p: Process) { self.p = p } }

    nonisolated static func sh(_ cmd: String, in dir: String, timeout: TimeInterval = 60) -> (code: Int32, out: String) {
        let p = Process(); p.executableURL = URL(fileURLWithPath: "/bin/bash"); p.arguments = ["-c", cmd]; p.currentDirectoryURL = URL(fileURLWithPath: dir)
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin:/usr/local/bin"; env["GIT_TERMINAL_PROMPT"] = "0"
        p.environment = env
        let pipe = Pipe(); p.standardOutput = pipe; p.standardError = pipe
        do { try p.run() } catch { return (127, error.localizedDescription) }
        let h = Handle(p)
        let killer = DispatchWorkItem { if h.p.isRunning { h.p.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: killer)
        let data = pipe.fileHandleForReading.readDataToEndOfFile(); p.waitUntilExit(); killer.cancel()
        return (p.terminationStatus, String(decoding: data, as: UTF8.self))
    }
}

struct UpdateBanner: View {
    @ObservedObject var u: UpdateModel
    private func clock(_ s: Int) -> String { String(format: "%d:%02d", s / 60, s % 60) }
    var body: some View {
        switch u.state {
        case .available(let why) where !u.dismissed:
            row(symbol: "arrow.down.circle.fill", tint: Theme.accent, text: "Update available: \(why).") {
                Button("Update now") { u.update() }.buttonStyle(.primary)
                Button("Later") { u.dismissed = true }
            }
        case .updating(let p):
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Updating · step \(p.step + 1) of \(p.steps): \(p.label)").font(.callout.weight(.semibold))
                    Spacer()
                    Text("\(clock(p.elapsed)) elapsed" + (p.remaining.map { " · about \(clock($0)) left" } ?? "")).font(.callout).foregroundStyle(Theme.textSecondary).monospacedDigit()
                    Button("Cancel") { u.cancelUpdate() }
                }
                ProgressView(value: p.fraction)
                Text("You can keep working. Learn Anyway restarts by itself when the build is ready.").font(Theme.meta).foregroundStyle(Theme.textSecondary)
            }.padding(.horizontal, Theme.Space.lg).padding(.vertical, Theme.Space.sm).background(Theme.accent.opacity(0.12)).overlay(alignment: .top) { Rectangle().fill(Theme.accent.opacity(0.35)).frame(height: 1) }
        case .failed(let m):
            row(symbol: "exclamationmark.triangle.fill", tint: Theme.error, text: "Update failed. Your current version is untouched. \(m)") {
                Button("Try again") { u.check() }
                Button("Dismiss") { u.dismissAll() }
            }
        default: EmptyView()
        }
    }
    private func row<A: View>(symbol: String, tint: Color, text: String, @ViewBuilder actions: () -> A) -> some View {
        HStack(spacing: Theme.Space.md) {
            Image(systemName: symbol).foregroundStyle(tint)
            Text(text).font(.callout).lineLimit(3).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: Theme.Space.md)
            actions()
        }.padding(.horizontal, Theme.Space.lg).padding(.vertical, Theme.Space.sm).background(tint.opacity(0.12)).overlay(alignment: .top) { Rectangle().fill(tint.opacity(0.35)).frame(height: 1) }
    }
}

extension UpdateModel { func dismissAll() { dismissed = true; if case .failed = state { markIdle() } } }

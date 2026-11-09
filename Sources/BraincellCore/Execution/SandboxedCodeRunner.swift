import Foundation
import Darwin

/// Runs learner code in a separate, sandboxed process. Defence in depth:
///  1. a macOS Seatbelt profile (deny by default): no network, no process creation (the run step), no exec of anything
///     but the one target, writes only inside a fresh per-run directory, no reading of the home folder, /etc, volumes…;
///  2. rlimits (CPU time, file size, open files, core dumps) set by a trusted launcher script before the sandbox starts;
///  3. a supervisor that enforces wall-clock, output and resident-memory limits from outside and kills the whole group;
///  4. a minimal environment (no inherited variables, HOME and TMPDIR inside the run directory);
///  5. validated file names and a throw-away run directory that is always deleted.
/// `sandbox-exec` is deprecated by Apple but still the supported command-line front end to Seatbelt on macOS 15.
public struct SandboxedCodeRunner: CodeRunner {

    public struct Tool: Sendable { var executable: String; var readRoots: [String]; var extra: [String] = [] }
    public struct Toolchain: Sendable {
        public var python: Tool?
        public var clang: Tool?       // extra[0] = SDK path
        public var javac: Tool?
        public var java: Tool?

        public static func discover() -> Toolchain {
            let fm = FileManager.default
            var t = Toolchain()
            // Python: Apple's framework build (the /usr/bin shim spawns it, which the sandbox forbids), else python.org.
            for dev in ["/Library/Developer/CommandLineTools", "/Applications/Xcode.app/Contents/Developer"] where t.python == nil {
                let fw = dev + "/Library/Frameworks/Python3.framework"
                if let vs = try? fm.contentsOfDirectory(atPath: fw + "/Versions").sorted().reversed() {
                    for v in vs {
                        let p = "\(fw)/Versions/\(v)/Resources/Python.app/Contents/MacOS/Python"
                        if fm.isExecutableFile(atPath: p) { t.python = Tool(executable: Self.real(p), readRoots: [Self.real(fw)]); break }
                    }
                }
            }
            if t.python == nil {
                let fw = "/Library/Frameworks/Python.framework"
                let p = fw + "/Versions/Current/bin/python3"
                if fm.isExecutableFile(atPath: p) { t.python = Tool(executable: Self.real(p), readRoots: [Self.real(fw)]) }
            }
            // C: the Command Line Tools or Xcode clang with an explicit SDK (no xcrun, which would need more access).
            for (dev, sdk) in [("/Library/Developer/CommandLineTools", "/Library/Developer/CommandLineTools/SDKs/MacOSX.sdk"),
                               ("/Applications/Xcode.app/Contents/Developer", "/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk")] where t.clang == nil {
                let c = dev + "/usr/bin/clang"
                if fm.isExecutableFile(atPath: c), fm.fileExists(atPath: sdk) { t.clang = Tool(executable: Self.real(c), readRoots: [Self.real(dev)], extra: [Self.real(sdk)]) }
            }
            // Java: whatever /usr/libexec/java_home reports (a trusted tool, run outside the sandbox).
            if let home = javaHome(), fm.isExecutableFile(atPath: home + "/bin/java"), fm.isExecutableFile(atPath: home + "/bin/javac") {
                let root = SandboxedCodeRunner.realpath(URL(fileURLWithPath: home).deletingLastPathComponent().deletingLastPathComponent().path)
                let readRoot = root.hasSuffix(".jdk") || root.hasSuffix(".jre") ? root : home
                t.java = Tool(executable: home + "/bin/java", readRoots: [readRoot]); t.javac = Tool(executable: home + "/bin/javac", readRoots: [readRoot])
            }
            return t
        }

        /// Seatbelt matches real paths, so every path handed to a profile must have its symlinks resolved.
        static func real(_ p: String) -> String { SandboxedCodeRunner.realpath(p) }

        static func javaHome() -> String? {
            let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/libexec/java_home")
            let out = Pipe(); p.standardOutput = out; p.standardError = Pipe()
            guard (try? p.run()) != nil else { return nil }
            p.waitUntilExit()
            guard p.terminationStatus == 0 else { return nil }
            let s = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
            return s.flatMap { $0.isEmpty ? nil : SandboxedCodeRunner.realpath($0) }
        }
    }

    static let sandboxExec = "/usr/bin/sandbox-exec"

    /// realpath(3). (Foundation's resolvingSymlinksInPath rewrites /private/var back to /var, which Seatbelt would not match.)
    static func realpath(_ p: String) -> String {
        guard let r = Darwin.realpath(p, nil) else { return p }
        defer { free(r) }
        return String(cString: r)
    }
    public let tools: Toolchain
    let workRoot: String

    public init(toolchain: Toolchain = .discover(), workRoot: URL = FileManager.default.temporaryDirectory) {
        tools = toolchain
        self.workRoot = Self.realpath(workRoot.path)
    }

    // MARK: CodeRunner

    public var languages: Set<CodeLanguage> {
        guard FileManager.default.isExecutableFile(atPath: Self.sandboxExec) else { return [] }
        var s = Set<CodeLanguage>()
        if tools.python != nil { s.insert(.python) }
        if tools.clang != nil { s.insert(.c) }
        if tools.java != nil, tools.javac != nil { s.insert(.java) }
        return s
    }
    public var isAvailable: Bool { !languages.isEmpty }
    public var unavailableReason: String? {
        if !FileManager.default.isExecutableFile(atPath: Self.sandboxExec) { return "macOS’s sandbox tool wasn’t found, so Learn Anyway won’t run code." }
        let missing = CodeLanguage.allCases.filter { !languages.contains($0) }
        return missing.isEmpty ? nil : "No toolchain found for: \(missing.map { $0.rawValue }.joined(separator: ", ")). Install the Xcode Command Line Tools (Python, C) or a JDK (Java)."
    }

    public func run(_ r: CodeRunRequest) async -> CodeRunResult {
        await onWorkerThread { self.runSync(r) }
    }

    public func runTests(_ r: CodeRunRequest, tests: [CodeTest]) async -> CodeTestReport {
        await onWorkerThread { self.runTestsSync(r, tests: tests) }
    }

    private func onWorkerThread<T: Sendable>(_ f: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { c in DispatchQueue.global(qos: .userInitiated).async { c.resume(returning: f()) } }
    }

    // MARK: Synchronous implementation

    struct Prepared { var workspace: Workspace; var compiled: Bool; var compileOutput: String? }

    func runSync(_ r: CodeRunRequest) -> CodeRunResult {
        guard let lang = CodeLanguage(name: r.language), languages.contains(lang) else {
            return .unavailable(reason: unavailableReason ?? "Running \(r.language) code isn’t supported.")
        }
        let ws: Workspace
        do { ws = try Workspace(root: workRoot, files: r.files, language: lang) } catch { return .finished(Self.internal(error)) }
        defer { ws.destroy() }
        switch prepare(ws, lang, r) {
        case .failure(let out): return .finished(out)
        case .success(let compileOutput):
            let res = execute(ws, lang, r, stdin: r.stdin, limits: .run)
            var out = Self.output(res)
            out.compileOutput = compileOutput
            return .finished(out)
        }
    }

    func runTestsSync(_ r: CodeRunRequest, tests: [CodeTest]) -> CodeTestReport {
        guard let lang = CodeLanguage(name: r.language), languages.contains(lang) else {
            return .unavailable(reason: unavailableReason ?? "Running \(r.language) code isn’t supported.")
        }
        guard !tests.isEmpty, tests.count <= 20 else { return .internalError("A question needs between 1 and 20 tests.") }
        let ws: Workspace
        do { ws = try Workspace(root: workRoot, files: r.files, language: lang) } catch { return .internalError("\(error)") }
        defer { ws.destroy() }
        if case .failure(let out) = prepare(ws, lang, r) {
            if case .internalError(let m) = out.termination { return .internalError(m) }
            return .compileError(out.compileOutput ?? out.stderr)
        }
        var limits = SandboxLimits.run; limits.wallSeconds = 3; limits.cpuSeconds = 3
        var outcomes: [TestOutcome] = []
        for t in tests {
            let res = execute(ws, lang, r, stdin: t.input, limits: limits)
            let actual = String(decoding: res.stdout, as: UTF8.self), err = String(decoding: res.stderr, as: UTF8.self)
            let status: TestStatus
            switch res.termination {
            case .failedToStart(let m): return .internalError(m)
            case .timedOut: status = .timedOut
            case .outputLimit: status = .outputLimit
            case .memoryLimit: status = .memoryLimit
            case .signaled: status = .crashed
            case .exited(let code): status = code != 0 ? .crashed : (OutputComparison.equal(actual, t.expectedOutput) ? .passed : .failed)
            }
            let hidden = t.hidden ?? false
            outcomes.append(TestOutcome(name: t.name, hidden: hidden, status: status, input: hidden ? nil : t.input, expected: hidden ? nil : t.expectedOutput,
                                        actual: hidden ? "" : String(actual.prefix(2_000)), stderr: hidden ? "" : String(err.prefix(2_000))))
        }
        return .ran(outcomes)
    }

    /// Compile if the language needs it. `.failure` carries a ready-to-return output (compile error or internal error).
    func prepare(_ ws: Workspace, _ lang: CodeLanguage, _ r: CodeRunRequest) -> Result<String?, CodeRunOutput> {
        switch lang {
        case .python: return .success(nil)
        case .c:
            guard let clang = tools.clang else { return .failure(Self.internal("no C toolchain")) }
            let args = ["-isysroot", clang.extra[0], "-std=c11", "-O1", "-o", "prog"] + ws.sourceFiles + ["-lm"]
            return compile(ws, tool: clang, args: args)
        case .java:
            guard let javac = tools.javac else { return .failure(Self.internal("no Java toolchain")) }
            return compile(ws, tool: javac, args: ["-J-Xmx256m", "-J-XX:-UsePerfData", "-encoding", "UTF-8", "-d", "."] + ws.sourceFiles)
        }
    }

    func compile(_ ws: Workspace, tool: Tool, args: [String]) -> Result<String?, CodeRunOutput> {
        let profile = Profile.make(workDir: ws.path, executables: [.subpath(tool.readRoots[0])], readRoots: tool.readRoots, allowFork: true)
        let res = launch(ws, profile: profile, executable: tool.executable, args: args, stdin: Data(), limits: .compile)
        let text = String(decoding: res.stderr + res.stdout, as: UTF8.self)
        switch res.termination {
        case .exited(0): return .success(text.isEmpty ? nil : text)
        case .failedToStart(let m): return .failure(Self.internal(m))
        case .exited, .signaled: return .failure(CodeRunOutput(stdout: "", stderr: text, termination: .compileFailed, compileOutput: text, wallSeconds: res.wallSeconds, truncated: res.outputTruncated))
        case .timedOut: return .failure(CodeRunOutput(stdout: "", stderr: "Compilation timed out.", termination: .compileFailed, compileOutput: "Compilation timed out.", wallSeconds: res.wallSeconds, truncated: false))
        case .outputLimit, .memoryLimit: return .failure(CodeRunOutput(stdout: "", stderr: "Compilation used too many resources.", termination: .compileFailed, compileOutput: "Compilation used too many resources.", wallSeconds: res.wallSeconds, truncated: false))
        }
    }

    func execute(_ ws: Workspace, _ lang: CodeLanguage, _ r: CodeRunRequest, stdin: String, limits: SandboxLimits) -> SpawnResult {
        let data = Data(stdin.utf8.prefix(64 * 1024))
        switch lang {
        case .python:
            guard let py = tools.python else { return Self.failed("no Python") }
            let profile = Profile.make(workDir: ws.path, executables: [.literal(py.executable)], readRoots: py.readRoots, allowFork: false)
            return launch(ws, profile: profile, executable: py.executable, args: ["-I", "-B", "-X", "utf8", ws.mainFile], stdin: data, limits: limits)
        case .c:
            let prog = ws.path + "/prog"
            let profile = Profile.make(workDir: ws.path, executables: [.literal(prog)], readRoots: [], allowFork: false)
            return launch(ws, profile: profile, executable: prog, args: [], stdin: data, limits: limits)
        case .java:
            guard let java = tools.java else { return Self.failed("no Java") }
            let profile = Profile.make(workDir: ws.path, executables: [.literal(java.executable)], readRoots: java.readRoots, allowFork: false)
            let cls = r.mainClass ?? ws.javaMainClass
            return launch(ws, profile: profile, executable: java.executable,
                          args: ["-Xmx128m", "-Xss512k", "-XX:+UseSerialGC", "-XX:TieredStopAtLevel=1", "-XX:-UsePerfData", "-Xshare:auto", "-XX:+ExitOnOutOfMemoryError", "-cp", ".", cls],
                          stdin: data, limits: limits)
        }
    }

    /// Writes the profile, then starts `/bin/sh` (trusted, outside the sandbox) which sets rlimits and execs
    /// `sandbox-exec -f profile target args…`. Limits are inherited by the target.
    func launch(_ ws: Workspace, profile: String, executable: String, args: [String], stdin: Data, limits: SandboxLimits) -> SpawnResult {
        let profilePath = ws.profilePath
        do { try profile.write(toFile: profilePath, atomically: true, encoding: .utf8) } catch { return Self.failed("couldn't write sandbox profile") }
        let script = "ulimit -t \(limits.cpuSeconds); ulimit -f \(max(1, limits.maxFileBytes / 512)); ulimit -c 0; ulimit -n \(limits.openFiles); profile=\"$1\"; shift; exec \(Self.sandboxExec) -f \"$profile\" \"$@\""
        let env = ["PATH": "/usr/bin:/bin", "LANG": "en_US.UTF-8", "HOME": ws.path, "TMPDIR": ws.path + "/tmp", "PYTHONDONTWRITEBYTECODE": "1", "PYTHONIOENCODING": "utf-8"]
        return ProcessSupervisor.run(executable: "/bin/sh", arguments: ["-c", script, "sh", profilePath, executable] + args, environment: env,
                                     workingDirectory: ws.path, stdin: stdin, limits: limits)
    }

    // MARK: Mapping

    static func failed(_ m: String) -> SpawnResult { SpawnResult(stdout: Data(), stderr: Data(), termination: .failedToStart(m), wallSeconds: 0, outputTruncated: false) }
    static func `internal`(_ e: Error) -> CodeRunOutput { `internal`("\(e)") }
    static func `internal`(_ m: String) -> CodeRunOutput { CodeRunOutput(stdout: "", stderr: "", termination: .internalError(m), compileOutput: nil, wallSeconds: 0, truncated: false) }

    static func output(_ r: SpawnResult) -> CodeRunOutput {
        let t: RunTermination
        switch r.termination {
        case .exited(let c): t = .exited(c)
        case .signaled(let s): t = .signaled(s)
        case .timedOut: t = .timedOut
        case .outputLimit: t = .outputLimit
        case .memoryLimit: t = .memoryLimit
        case .failedToStart(let m): t = .internalError(m)
        }
        return CodeRunOutput(stdout: String(decoding: r.stdout, as: UTF8.self), stderr: String(decoding: r.stderr, as: UTF8.self), termination: t,
                             compileOutput: nil, wallSeconds: r.wallSeconds, truncated: r.outputTruncated)
    }
}

// MARK: Seatbelt profile

enum Profile {
    enum Exec { case literal(String), subpath(String) }

    /// Deny by default. Later rules win in SBPL, so the sensitive-path denials precede the run-directory allowance.
    static func make(workDir: String, executables: [Exec], readRoots: [String], allowFork: Bool) -> String {
        func q(_ s: String) -> String { "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\"" }
        var p = ["(version 1)", "(deny default)", "(import \"/System/Library/Sandbox/Profiles/bsd.sb\")"]
        if allowFork { p.append("(allow process-fork)") }
        for e in executables {
            switch e { case .literal(let s): p.append("(allow process-exec* (literal \(q(s))))"); case .subpath(let s): p.append("(allow process-exec* (subpath \(q(s))))") }
        }
        for r in readRoots { p.append("(allow file-read* (subpath \(q(r))))") }
        p += ["(allow sysctl-read)", "(deny network*)",
              "(deny file-read* (subpath \"/etc\") (subpath \"/private/etc\") (subpath \"/Users\") (subpath \"/private/var/db\") (subpath \"/Volumes\") (subpath \"/Applications\"))",
              "(allow file-read* (subpath \(q(workDir))))", "(allow file-write* (subpath \(q(workDir))))"]
        // Xcode's toolchain lives under /Applications; re-allow just the roots we were given.
        for r in readRoots where r.hasPrefix("/Applications/") { p.append("(allow file-read* (subpath \(q(r))))") }
        return p.joined(separator: "\n") + "\n"
    }
}

// MARK: Run directory

enum RunnerError: Error, CustomStringConvertible {
    case invalidFile(String), tooManyFiles, tooLarge(String), io(String)
    var description: String {
        switch self {
        case .invalidFile(let n): "File name “\(n)” isn’t allowed."
        case .tooManyFiles: "Too many files (limit 10)."
        case .tooLarge(let n): "“\(n)” is too large (limit 200 KB)."
        case .io(let m): m
        }
    }
}

/// A fresh 0700 directory holding validated files for exactly one run.
final class Workspace: @unchecked Sendable {
    let path: String
    let sourceFiles: [String]
    let mainFile: String
    let javaMainClass: String
    let profilePath: String

    init(root: String, files: [CodeFile], language: CodeLanguage) throws {
        guard !files.isEmpty, files.count <= 10 else { throw RunnerError.tooManyFiles }
        let allowed: [String] = switch language { case .python: [".py"]; case .c: [".c", ".h"]; case .java: [".java"] }
        var seen = Set<String>()
        for f in files {
            guard f.name.range(of: #"^[A-Za-z0-9_][A-Za-z0-9_.\-]{0,63}$"#, options: .regularExpression) != nil, !f.name.contains(".."),
                  allowed.contains(where: { f.name.hasSuffix($0) }), seen.insert(f.name).inserted else { throw RunnerError.invalidFile(f.name) }
            guard f.content.utf8.count <= 200_000 else { throw RunnerError.tooLarge(f.name) }
        }
        let dir = root + "/braincell-run-" + UUID().uuidString
        do {
            try FileManager.default.createDirectory(atPath: dir + "/tmp", withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            for f in files { try Data(f.content.utf8).write(to: URL(fileURLWithPath: dir + "/" + f.name), options: .atomic) }
        } catch { try? FileManager.default.removeItem(atPath: dir); throw RunnerError.io("Couldn't prepare the run directory.") }
        path = dir
        profilePath = dir + "/.profile.sb"
        sourceFiles = files.map(\.name).filter { !$0.hasSuffix(".h") }
        mainFile = files.first { $0.name == "main.py" }?.name ?? files[0].name
        javaMainClass = files.first { $0.content.contains("static void main") }.map { String($0.name.dropLast(5)) } ?? "Main"
    }

    func destroy() { try? FileManager.default.removeItem(atPath: path) }
}

extension CodeRunOutput: Error {}

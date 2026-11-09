import Foundation

public struct CodeRunRequest: Sendable {
    public var files: [CodeFile]
    public var language: String
    public var stdin: String
    /// Java only: the class to run (defaults to the class containing `main`, else "Main").
    public var mainClass: String?
    public init(files: [CodeFile], language: String, stdin: String = "", mainClass: String? = nil) {
        self.files = files; self.language = language; self.stdin = stdin; self.mainClass = mainClass
    }
}

public enum RunTermination: Sendable, Equatable {
    case exited(Int32)
    case signaled(Int32)
    case timedOut
    case outputLimit
    case memoryLimit
    case compileFailed
    /// The runner itself failed (bad file names, toolchain problem). Never the learner's fault.
    case internalError(String)
}

public struct CodeRunOutput: Sendable, Equatable {
    public var stdout: String
    public var stderr: String
    public var termination: RunTermination
    public var compileOutput: String?
    public var wallSeconds: Double
    public var truncated: Bool
}

public enum CodeRunResult: Sendable, Equatable {
    case unavailable(reason: String)
    case finished(CodeRunOutput)
}

/// A stdin → stdout test. `hidden` tests don't reveal their input or expected output to the learner.
public struct CodeTest: Codable, Hashable, Sendable {
    public var name: String
    public var input: String
    public var expectedOutput: String
    public var hidden: Bool?
    public init(name: String, input: String, expectedOutput: String, hidden: Bool? = nil) {
        self.name = name; self.input = input; self.expectedOutput = expectedOutput; self.hidden = hidden
    }
}

public enum TestStatus: String, Sendable, Equatable { case passed, failed, timedOut, crashed, outputLimit, memoryLimit }

public struct TestOutcome: Sendable, Equatable, Identifiable {
    public var name: String
    public var hidden: Bool
    public var status: TestStatus
    /// nil for hidden tests.
    public var input: String?
    public var expected: String?
    public var actual: String
    public var stderr: String
    public var id: String { name }
}

public enum CodeTestReport: Sendable, Equatable {
    case unavailable(reason: String)
    case compileError(String)
    /// The runner failed; nothing can be concluded about the learner's code.
    case internalError(String)
    case ran([TestOutcome])

    public var passedCount: Int { if case .ran(let o) = self { o.filter { $0.status == .passed }.count } else { 0 } }
    public var totalCount: Int { if case .ran(let o) = self { o.count } else { 0 } }
}

public enum OutputComparison {
    /// Whitespace-tolerant at line ends and the end of output; case- and inner-space-sensitive.
    public static func normalize(_ s: String) -> String {
        var lines = s.replacingOccurrences(of: "\r\n", with: "\n").split(separator: "\n", omittingEmptySubsequences: false)
            .map { String($0).replacingOccurrences(of: "\\s+$", with: "", options: .regularExpression) }
        while lines.last == "" { lines.removeLast() }
        return lines.joined(separator: "\n")
    }
    public static func equal(_ a: String, _ b: String) -> Bool { normalize(a) == normalize(b) }
}

/// Seam for running learner code. The only real implementation is `SandboxedCodeRunner`; nothing in the app ever
/// executes user code in-process.
public protocol CodeRunner: Sendable {
    var isAvailable: Bool { get }
    var languages: Set<CodeLanguage> { get }
    /// Why code can't be run (shown to the learner), or nil when it can.
    var unavailableReason: String? { get }
    func run(_ request: CodeRunRequest) async -> CodeRunResult
    func runTests(_ request: CodeRunRequest, tests: [CodeTest]) async -> CodeTestReport
}

/// Used when running code is switched off or unsupported. It never fabricates output or test results.
public struct UnavailableCodeRunner: CodeRunner {
    public static let reason = "Running code is switched off. You can enable sandboxed execution in Settings. Until then, compare your solution with the reference or export it for grading."
    public let reasonText: String
    public init(reason: String = Self.reason) { reasonText = reason }
    public var isAvailable: Bool { false }
    public var languages: Set<CodeLanguage> { [] }
    public var unavailableReason: String? { reasonText }
    public func run(_ request: CodeRunRequest) async -> CodeRunResult { .unavailable(reason: reasonText) }
    public func runTests(_ request: CodeRunRequest, tests: [CodeTest]) async -> CodeTestReport { .unavailable(reason: reasonText) }
}

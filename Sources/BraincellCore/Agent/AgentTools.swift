import Foundation
import GRDB

public enum ToolPermission: String, Sendable { case read, write, destructive }

public struct ToolParam: Sendable { public let name: String, type: String, required: Bool, doc: String
    public init(_ n: String, _ t: String, _ doc: String, required: Bool = false) { name = n; type = t; self.doc = doc; self.required = required } }

public struct ToolSpec: Sendable {
    public let name: String
    public let summary: String
    public let params: [ToolParam]
    public let permission: ToolPermission
    public var requiresApproval: Bool { permission != .read && approval }
    let approval: Bool
    /// Plain-language description shown on the approval card.
    let describe: @Sendable (ToolArgs, AgentContext) -> String
    let run: @Sendable (ToolArgs, AgentContext, ToolRunInfo) async throws -> ToolOutput
}

public struct ToolRunInfo: Sendable {
    public let conversationId: UUID; public let actionId: UUID
    /// Reports a real workflow stage ("Validating results") to the UI while the tool runs.
    public var stage: @Sendable (String) -> Void
    public init(conversationId: UUID, actionId: UUID, stage: @escaping @Sendable (String) -> Void = { _ in }) { self.conversationId = conversationId; self.actionId = actionId; self.stage = stage }
}

/// A navigation or follow-up button. Every one maps to a real app operation the UI performs.
public struct ActionChip: Codable, Sendable, Equatable, Hashable {
    public var label: String
    public var action: String               // openCourse | openLibrary | openQuestionBank | openSkills | addFiles | startPractice | openPlan | startReviews | resumeSession
    public var courseId: UUID?
    public var assessmentId: UUID?
    public var setId: UUID?
    public var planId: UUID?
    public var dayIndex: Int?
    public static let allowed: Set<String> = ["openCourse", "openLibrary", "openQuestionBank", "openSkills", "addFiles", "startPractice", "openPlan", "startReviews", "resumeSession", "prepareExam", "openPracticeSet"]
}

public struct ToolOutput: Sendable {
    public var text: String                  // what the model is shown
    public var summary: String               // one line for the progress row
    public var untrusted = false             // contains document text: wrapped before the model sees it
    public var planId: UUID?
    public var generationId: UUID?
    public var mapId: UUID?
    public var chips: [ActionChip] = []
    public init(text: String, summary: String, untrusted: Bool = false, planId: UUID? = nil, generationId: UUID? = nil, mapId: UUID? = nil, chips: [ActionChip] = []) {
        self.text = text; self.summary = summary; self.untrusted = untrusted; self.planId = planId; self.generationId = generationId; self.mapId = mapId; self.chips = chips
    }
}

public enum ToolError: Error, LocalizedError, Equatable {
    case invalid(String), notFound(String), ambiguous(String), unavailable(String)
    public var errorDescription: String? { switch self { case .invalid(let m), .notFound(let m), .ambiguous(let m), .unavailable(let m): m } }
}

/// Typed access to model-supplied arguments. Everything is validated here; the model never touches a service directly.
public struct ToolArgs: @unchecked Sendable {
    public let raw: [String: Any]
    public init(_ raw: [String: Any]) { self.raw = raw }
    public func string(_ k: String) -> String? { (raw[k] as? String).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.flatMap { $0.isEmpty ? nil : $0 } }
    public func require(_ k: String) throws -> String { guard let s = string(k) else { throw ToolError.invalid("Missing required argument “\(k)”.") }; return s }
    public func int(_ k: String) -> Int? { (raw[k] as? Int) ?? (raw[k] as? Double).map(Int.init) ?? (raw[k] as? String).flatMap(Int.init) }
    public func bool(_ k: String) -> Bool? { raw[k] as? Bool }
    public func strings(_ k: String) -> [String] { (raw[k] as? [String]) ?? (raw[k] as? [Any])?.compactMap { $0 as? String } ?? [] }
    public func objects(_ k: String) -> [[String: Any]] { (raw[k] as? [[String: Any]]) ?? [] }
    public func uuid(_ k: String) -> UUID? { string(k).flatMap(UUID.init) }
    /// yyyy-MM-dd in the learner's calendar.
    public func date(_ k: String, calendar: Calendar) throws -> Date? {
        guard let s = string(k) else { return nil }
        let f = DateFormatter(); f.calendar = calendar; f.timeZone = calendar.timeZone; f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyy-MM-dd"
        guard let d = f.date(from: String(s.prefix(10))) else { throw ToolError.invalid("“\(k)” must be a date like 2026-11-20.") }
        return d
    }
    /// Stable text for idempotency keys.
    public var canonical: String { (try? JSONSerialization.data(withJSONObject: raw, options: [.sortedKeys])).flatMap { String(data: $0, encoding: .utf8) } ?? "{}" }
}

/// Everything a tool may use: the app's existing services. Tools add no parallel data model.
public struct AgentContext: Sendable {
    public let db: AppDatabase
    public let storage: ManagedStorage
    public let gateway: AIGateway
    public let now: @Sendable () -> Date
    public var calendar: Calendar = .current
    public let courses: CourseService, docs: DocumentService, library: LibraryService, questions: QuestionService
    public let ai: AITaskService, planner: PlannerService, progression: ProgressionService, store: AgentStore
    public let practiceSets: PracticeSetService, templates: TemplateService

    public init(db: AppDatabase, storage: ManagedStorage, gateway: AIGateway, now: @escaping @Sendable () -> Date = { Date() }, calendar: Calendar = .current) {
        self.db = db; self.storage = storage; self.gateway = gateway; self.now = now; self.calendar = calendar
        courses = CourseService(db: db); docs = DocumentService(db: db, storage: storage); library = LibraryService(db: db, storage: storage, now: now)
        questions = QuestionService(db: db); ai = AITaskService(db: db); planner = PlannerService(db: db); progression = ProgressionService(db: db); store = AgentStore(db: db, now: now)
        practiceSets = PracticeSetService(db: db, ai: ai); templates = TemplateService(db: db)
    }

    static func norm(_ s: String) -> String { s.lowercased().filter { $0.isLetter || $0.isNumber } }

    /// By id, exact name, or a unique fuzzy match ("COMP301" finds "COMP301 Midterm 2"). Several matches → ambiguous, so the model must ask.
    func course(_ ref: String) throws -> Course {
        let all = try courses.courses()
        if let id = UUID(uuidString: ref), let c = all.first(where: { $0.id == id }) { return c }
        let n = Self.norm(ref)
        guard !n.isEmpty else { throw ToolError.invalid("Course name is empty.") }
        let exact = all.filter { Self.norm($0.name) == n }
        if exact.count == 1 { return exact[0] }
        let near = all.filter { Self.norm($0.name).contains(n) || n.contains(Self.norm($0.name)) }
        if near.count == 1 { return near[0] }
        if near.isEmpty && exact.isEmpty { throw ToolError.notFound("No course matches “\(ref)”.") }
        throw ToolError.ambiguous("Several courses match “\(ref)”: " + (exact + near).map { "“\($0.name)” (\($0.id.uuidString))" }.joined(separator: ", ") + ". Ask the user which one.")
    }

    func assessment(_ ref: String?, in course: Course) throws -> Assessment? {
        guard let ref else { return nil }
        let all = try courses.assessments(courseId: course.id)
        if let id = UUID(uuidString: ref), let a = all.first(where: { $0.id == id }) { return a }
        let n = Self.norm(ref)
        let m = all.filter { Self.norm($0.name) == n } + all.filter { Self.norm($0.name).contains(n) && Self.norm($0.name) != n }
        if m.count >= 1 { return m[0] }
        throw ToolError.notFound("No assessment matches “\(ref)” in \(course.name). Existing: " + (all.isEmpty ? "none" : all.map(\.name).joined(separator: ", ")) + ".")
    }

    func fmt(_ d: Date) -> String { let f = DateFormatter(); f.calendar = calendar; f.timeZone = calendar.timeZone; f.dateFormat = "yyyy-MM-dd (EEE)"; return f.string(from: d) }
}

import Foundation

/// A learning template describes HOW a saved practice set is presented, interacted with, scored and exported. It never contains questions, and it is
/// pure data: nothing in it is executed. Anything an AI proposes is parsed by `TemplateParser`, which rejects unknown fields and out-of-range values.
public struct LearningTemplate: Codable, Equatable, Sendable, Identifiable {
    public static let schemaVersion = 1
    public enum Kind: String, Codable, CaseIterable, Sendable { case examWorksheet, interactive, guided, flashcards
        public var title: String { switch self { case .examWorksheet: "Exam worksheet"; case .interactive: "Interactive"; case .guided: "Guided"; case .flashcards: "Flashcards" } } }
    public enum PageSize: String, Codable, CaseIterable, Sendable { case letter, a4
        public var points: (w: Double, h: Double) { self == .letter ? (612, 792) : (595, 842) } }
    public enum AnswerSpace: String, Codable, CaseIterable, Sendable { case none, small, medium, large
        public var height: Double { switch self { case .none: 0; case .small: 40; case .medium: 96; case .large: 180 } } }
    public enum Order: String, Codable, CaseIterable, Sendable { case planned, easyFirst, hardFirst, byTopic, shuffled }
    public enum TimingMode: String, Codable, CaseIterable, Sendable { case none, perQuestion, total }
    public enum FeedbackMode: String, Codable, CaseIterable, Sendable { case none, immediate, afterSubmit, atEnd }
    public enum SolutionVisibility: String, Codable, CaseIterable, Sendable { case never, afterAttempt, atEnd }
    public enum InputType: String, Codable, CaseIterable, Sendable { case text, choice, numeric, math, handwriting, flip }
    public enum ScoringMode: String, Codable, CaseIterable, Sendable { case none, points, percentage }
    public enum Export: String, Codable, CaseIterable, Sendable { case pdf, solutionsPdf, print }

    public struct Layout: Codable, Equatable, Sendable {
        public var pageSize: PageSize = .letter
        public var fontSize: Double = 11                    // 8…16
        public var answerSpace: AnswerSpace = .medium
        public var showPoints = true, showSourceRefs = false, showTopics = false
        public var header = "", instructions = ""           // ≤ 120 / ≤ 600 characters, plain text
    }
    public struct Sequencing: Codable, Equatable, Sendable { public var order: Order = .planned; public var seed: Int = 1; public var maxQuestions: Int = 0 }   // 0 = all (≤ 200)
    public struct Difficulty: Codable, Equatable, Sendable { public var min = 1, max = 5 }
    public struct Timing: Codable, Equatable, Sendable { public var mode: TimingMode = .none; public var seconds = 0 }          // ≤ 14 400
    public struct Hints: Codable, Equatable, Sendable { public var allowed = true; public var maxLevels = 3 }                    // 0…5
    public struct Feedback: Codable, Equatable, Sendable { public var mode: FeedbackMode = .afterSubmit; public var solution: SolutionVisibility = .afterAttempt }
    public struct Scoring: Codable, Equatable, Sendable { public var mode: ScoringMode = .none; public var pointsPerQuestion = 1.0; public var partialCredit = false }   // 0.5…100

    public var id: String
    public var schemaVersion: Int = Self.schemaVersion
    public var name: String
    public var description: String
    public var kind: Kind
    public var supportedFormats: [String]               // QuestionType raw values
    public var layout = Layout()
    public var sequencing = Sequencing()
    public var difficulty = Difficulty()
    public var timing = Timing()
    public var hints = Hints()
    public var feedback = Feedback()
    public var inputs: [InputType]
    public var scoring = Scoring()
    public var exports: [Export]
    public var baseId: String? = nil                    // the built-in this was customized from
    public var isBuiltIn: Bool { id.hasPrefix("builtin.") }

    public func supports(_ t: QuestionType) -> Bool { supportedFormats.contains(t.rawValue) }

    /// Strict semantic validation. Empty = valid. Every bound is checked here, whatever produced the template.
    public func validate() -> [String] {
        var e: [String] = []
        func range<T: Comparable>(_ v: T, _ lo: T, _ hi: T, _ what: String) { if v < lo || v > hi { e.append("\(what) must be between \(lo) and \(hi).") } }
        if name.trimmingCharacters(in: .whitespaces).isEmpty || name.count > 60 { e.append("Name must be 1–60 characters.") }
        if description.count > 400 { e.append("Description must be at most 400 characters.") }
        if id.isEmpty || id.count > 64 { e.append("Id must be 1–64 characters.") }
        if schemaVersion != Self.schemaVersion { e.append("Unsupported schema version \(schemaVersion) (this app reads version \(Self.schemaVersion)).") }
        if supportedFormats.isEmpty { e.append("At least one supported question format is required.") }
        for f in supportedFormats where QuestionType(rawValue: f) == nil { e.append("Unknown question format “\(f)”.") }
        if Set(supportedFormats).count != supportedFormats.count { e.append("Supported formats contain duplicates.") }
        if inputs.isEmpty { e.append("At least one answer input type is required.") }
        range(layout.fontSize, 8, 16, "Font size"); if layout.header.count > 120 { e.append("Header must be at most 120 characters.") }; if layout.instructions.count > 600 { e.append("Instructions must be at most 600 characters.") }
        range(sequencing.maxQuestions, 0, 200, "Maximum questions"); range(sequencing.seed, 0, 1_000_000, "Shuffle seed")
        range(difficulty.min, 1, 5, "Minimum difficulty"); range(difficulty.max, 1, 5, "Maximum difficulty"); if difficulty.min > difficulty.max { e.append("Minimum difficulty exceeds maximum.") }
        range(timing.seconds, 0, 14_400, "Time limit (seconds)"); if timing.mode != .none && timing.seconds < 10 { e.append("A timed template needs at least 10 seconds.") }
        range(hints.maxLevels, 0, 5, "Hint levels"); range(scoring.pointsPerQuestion, 0.5, 100, "Points per question")
        if Set(exports).count != exports.count { e.append("Exports contain duplicates.") }
        switch kind {
        case .examWorksheet:
            if !exports.contains(.pdf) { e.append("An exam worksheet must be able to export a PDF.") }
            if feedback.mode == .immediate || feedback.mode == .afterSubmit { e.append("A printed worksheet cannot give immediate feedback; use “atEnd” or “none”.") }
            if hints.allowed { e.append("A printed worksheet cannot offer interactive hints; turn hints off.") }
        case .flashcards:
            if !inputs.allSatisfy({ [.flip, .text, .numeric].contains($0) }) { e.append("Flashcards support flip, text and numeric inputs only.") }
            if !supportedFormats.allSatisfy({ ["flashcard", "short_answer", "numeric", "single_choice"].contains($0) }) { e.append("Flashcards support flashcard, short-answer, numeric and single-choice questions only.") }
        case .guided: if !hints.allowed { e.append("A guided template needs hints enabled.") }
        case .interactive: break
        }
        if kind != .examWorksheet && exports.contains(.solutionsPdf) && !exports.contains(.pdf) { e.append("A solutions PDF needs the PDF export.") }
        return e
    }
}

// MARK: Built-ins

public extension LearningTemplate {
    private static let all = QuestionType.allCases.map(\.rawValue)
    static let examWorksheet = LearningTemplate(id: "builtin.exam-worksheet", name: "Exam Worksheet", description: "A traditional printable exam: numbered questions, points, blank answer space and an optional solutions file.", kind: .examWorksheet,
        supportedFormats: all, layout: Layout(answerSpace: .medium, showPoints: true, header: "", instructions: "Answer every question. Show your work in the space provided."), hints: Hints(allowed: false, maxLevels: 0), feedback: Feedback(mode: .atEnd, solution: .atEnd),
        inputs: [.text, .choice, .numeric, .math, .handwriting], scoring: Scoring(mode: .points, pointsPerQuestion: 2), exports: [.pdf, .solutionsPdf, .print])
    static let interactive = LearningTemplate(id: "builtin.interactive", name: "Interactive Questions", description: "The standard question-by-question practice: answer, submit, get checked, review the solution.", kind: .interactive,
        supportedFormats: all, hints: Hints(allowed: true, maxLevels: 3), inputs: [.text, .choice, .numeric, .math], exports: [.pdf])
    static let guided = LearningTemplate(id: "builtin.guided", name: "Guided Learning", description: "Shorter questions, easier ones first, hints on request and immediate feedback after every answer.", kind: .guided,
        supportedFormats: ["single_choice", "multiple_select", "short_answer", "numeric", "flashcard"], sequencing: Sequencing(order: .easyFirst), difficulty: Difficulty(min: 1, max: 4), hints: Hints(allowed: true, maxLevels: 4),
        feedback: Feedback(mode: .immediate, solution: .afterAttempt), inputs: [.choice, .text, .numeric], exports: [.pdf])
    static let flashcards = LearningTemplate(id: "builtin.flashcards", name: "Flashcards", description: "Recall practice for definitions, formulas and short answers: see the prompt, answer from memory, flip.", kind: .flashcards,
        supportedFormats: ["flashcard", "short_answer", "numeric", "single_choice"], sequencing: Sequencing(order: .shuffled), hints: Hints(allowed: false, maxLevels: 0), feedback: Feedback(mode: .afterSubmit, solution: .afterAttempt), inputs: [.flip, .text], exports: [.pdf])
    static let builtIns: [LearningTemplate] = [examWorksheet, interactive, guided, flashcards]
}

// MARK: Strict parser for AI- or user-supplied JSON

public struct TemplateParseResult: Sendable {
    public var template: LearningTemplate?
    public var issues: [String]                 // reasons it was rejected (empty when accepted)
    public var limitations: [String]            // requested capabilities this app does not have; the template works without them
    public var isValid: Bool { template != nil && issues.isEmpty }
}

public enum TemplateParser {
    static let sections: [String: Set<String>] = [
        "layout": ["pageSize", "fontSize", "answerSpace", "showPoints", "showSourceRefs", "showTopics", "header", "instructions"],
        "sequencing": ["order", "seed", "maxQuestions"], "difficulty": ["min", "max"], "timing": ["mode", "seconds"], "hints": ["allowed", "maxLevels"],
        "feedback": ["mode", "solution"], "scoring": ["mode", "pointsPerQuestion", "partialCredit"]]
    static let top: Set<String> = ["id", "schemaVersion", "name", "description", "kind", "supportedFormats", "layout", "sequencing", "difficulty", "timing", "hints", "feedback", "inputs", "scoring", "exports", "baseId", "unsupported"]
    /// Words that mean "run something" or "needs a capability we don't have". Seeing one never makes a template executable; it becomes a limitation.
    static let capabilityWords = ["script", "code", "javascript", "html", "css", "url", "link", "audio", "video", "image", "gamification", "leaderboard", "points_system", "ai_tutor", "voice", "network", "webhook"]

    public static func parse(_ raw: String, dropIdentity: Bool = false) -> TemplateParseResult {
        guard raw.utf8.count <= 20_000 else { return .init(template: nil, issues: ["Template is too large (limit 20 000 characters)."], limitations: []) }
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("```") { text = text.split(separator: "\n").dropFirst().joined(separator: "\n"); if let r = text.range(of: "```", options: .backwards) { text = String(text[..<r.lowerBound]) } }
        guard let data = text.data(using: .utf8), var obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return .init(template: nil, issues: ["The reply is not a JSON object."], limitations: []) }
        if dropIdentity { obj["id"] = nil; obj["baseId"] = nil }
        var issues: [String] = [], limits: [String] = []
        for k in obj.keys where !top.contains(k) {
            if capabilityWords.contains(where: { k.lowercased().contains($0) }) { limits.append("“\(k)” is not supported: templates are declarative settings and cannot run code, load media or add features this app does not have.") }
            else { issues.append("Unknown field “\(k)”.") }
        }
        if let u = obj["unsupported"] as? [String] { limits += u.prefix(10).map { "Not available in this app: \(String($0.prefix(120)))." } }
        for (sec, allowed) in sections {
            guard let d = obj[sec] else { continue }
            guard let dict = d as? [String: Any] else { issues.append("“\(sec)” must be an object."); continue }
            for k in dict.keys where !allowed.contains(k) { issues.append("Unknown field “\(sec).\(k)”.") }
        }
        guard issues.isEmpty else { return .init(template: nil, issues: issues, limitations: limits) }
        var clean = obj; clean["unsupported"] = nil
        // Missing optional sections get safe defaults; required scalars must be present.
        clean["schemaVersion"] = clean["schemaVersion"] ?? LearningTemplate.schemaVersion
        for k in ["id", "name", "kind", "supportedFormats", "inputs", "exports"] where clean[k] == nil && k != "id" { issues.append("Missing required field “\(k)”.") }
        if clean["description"] == nil { clean["description"] = "" }
        if clean["id"] == nil { clean["id"] = UUID().uuidString }
        if let id = clean["id"] as? String, id.hasPrefix("builtin.") { issues.append("Ids starting with “builtin.” are reserved.") }
        // Safe defaults: omitted sections and omitted settings inside a section come from the built-in template of the same kind.
        if let kind = (clean["kind"] as? String).flatMap(LearningTemplate.Kind.init(rawValue:)), let base = LearningTemplate.builtIns.first(where: { $0.kind == kind }),
           let bd = try? JSONSerialization.jsonObject(with: JSONEncoder().encode(base)) as? [String: Any] {
            for sec in sections.keys {
                var merged = (bd[sec] as? [String: Any]) ?? [:]
                for (k, v) in (clean[sec] as? [String: Any]) ?? [:] { merged[k] = v }
                clean[sec] = merged
            }
        } else if clean["kind"] != nil { issues.append("Unknown template kind.") }
        guard issues.isEmpty, let d2 = try? JSONSerialization.data(withJSONObject: clean) else { return .init(template: nil, issues: issues, limitations: limits) }
        do {
            let t = try JSONDecoder().decode(LearningTemplate.self, from: d2)
            let v = t.validate()
            return .init(template: v.isEmpty ? t : nil, issues: v, limitations: limits)
        } catch { return .init(template: nil, issues: ["A field has the wrong type or an unknown option: \(Self.describe(error))"], limitations: limits) }
    }

    static func describe(_ e: Error) -> String {
        guard let d = e as? DecodingError else { return "invalid value." }
        switch d {
        case .dataCorrupted(let c), .typeMismatch(_, let c), .valueNotFound(_, let c): return c.codingPath.map(\.stringValue).joined(separator: ".") + " — " + String(c.debugDescription.prefix(100))
        case .keyNotFound(let k, _): return "missing “\(k.stringValue)”."
        @unknown default: return "invalid value."
        }
    }
}

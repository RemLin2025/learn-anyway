import Foundation

// Reasoning-aware extensions of the question model. Everything here is additive and optional so existing v1 payloads decode unchanged.
// Topic (content) = `Skill`; Reasoning skill = what the learner must do; Archetype = how the problem is built; Difficulty = reasoning complexity.

public enum Archetype: String, CaseIterable, Codable, Sendable {
    case directComputation, modelRecognition, conditionalReasoning, multistepCalculation, formulaDerivation, tableInterpretation
    case indicatorReasoning, assumptionAnalysis, errorIdentification, conceptualComparison, proofJustification, appliedModeling
    public var title: String {
        switch self {
        case .directComputation: "Direct computation"; case .modelRecognition: "Model recognition"; case .conditionalReasoning: "Conditional reasoning"
        case .multistepCalculation: "Multistep calculation"; case .formulaDerivation: "Formula derivation"; case .tableInterpretation: "Table/data interpretation"
        case .indicatorReasoning: "Indicator-based reasoning"; case .assumptionAnalysis: "Assumption analysis"; case .errorIdentification: "Error identification"
        case .conceptualComparison: "Conceptual comparison"; case .proofJustification: "Proof/justification"; case .appliedModeling: "Applied modeling"
        }
    }
}

public enum GenerationMode: String, CaseIterable, Codable, Sendable, Identifiable {
    case matchInstructorStyle, similarReasoning, broaderTopics, weakSkills
    public var id: String { rawValue }
    public var title: String {
        switch self { case .matchInstructorStyle: "Match instructor style"; case .similarReasoning: "Similar reasoning, new scenarios"; case .broaderTopics: "Broader topic practice"; case .weakSkills: "Focus on weak skills" }
    }
}

/// One explicit, checkable educational step. Stored with the question but not shown to the learner before the reveal point.
public struct SolutionStep: Codable, Hashable, Sendable {
    public var description: String
    public var skill: String?
    public var intermediateResult: String?
    public var commonError: String?
    public init(description: String, skill: String? = nil, intermediateResult: String? = nil, commonError: String? = nil) {
        self.description = description; self.skill = skill; self.intermediateResult = intermediateResult; self.commonError = commonError
    }
}

public struct SolutionPlan: Codable, Hashable, Sendable {
    public var interpretation: String
    public var assumptions: [String]
    public var method: String
    public var formulas: [String]
    public var steps: [SolutionStep]
    public var finalResult: String
    public var pitfalls: [String]
    public init(interpretation: String = "", assumptions: [String] = [], method: String = "", formulas: [String] = [], steps: [SolutionStep] = [], finalResult: String = "", pitfalls: [String] = []) {
        self.interpretation = interpretation; self.assumptions = assumptions; self.method = method; self.formulas = formulas; self.steps = steps; self.finalResult = finalResult; self.pitfalls = pitfalls
    }
    enum CodingKeys: String, CodingKey { case interpretation, assumptions, method, formulas, steps, finalResult, pitfalls }
    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        interpretation = try c.decodeIfPresent(String.self, forKey: .interpretation) ?? ""; assumptions = try c.decodeIfPresent([String].self, forKey: .assumptions) ?? []
        method = try c.decodeIfPresent(String.self, forKey: .method) ?? ""; formulas = try c.decodeIfPresent([String].self, forKey: .formulas) ?? []
        steps = try c.decodeIfPresent([SolutionStep].self, forKey: .steps) ?? []; finalResult = try c.decodeIfPresent(String.self, forKey: .finalResult) ?? ""; pitfalls = try c.decodeIfPresent([String].self, forKey: .pitfalls) ?? []
    }
    /// Complete enough to be checked: a method, at least two steps and a final result.
    public var isComplete: Bool { !method.isEmpty && steps.count >= 2 && !finalResult.isEmpty && !interpretation.isEmpty }
}

/// Documented difficulty factors (each 0–3). Difficulty is an estimate; wording length and ugly arithmetic alone don't raise it.
public struct DifficultyFactors: Codable, Hashable, Sendable {
    public var steps = 0, concepts = 0, methodSelection = 0, assumptions = 0, algebra = 0, conditioning = 0, generalization = 0, misconceptions = 0
    public var rationale = ""
    enum CodingKeys: String, CodingKey { case steps, concepts, methodSelection, assumptions, algebra, conditioning, generalization, misconceptions, rationale }
    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        func i(_ k: CodingKeys) -> Int { min(3, max(0, (try? c.decodeIfPresent(Int.self, forKey: k)) ?? 0)) }
        steps = i(.steps); concepts = i(.concepts); methodSelection = i(.methodSelection); assumptions = i(.assumptions); algebra = i(.algebra); conditioning = i(.conditioning); generalization = i(.generalization); misconceptions = i(.misconceptions)
        rationale = try c.decodeIfPresent(String.self, forKey: .rationale) ?? ""
    }
    public init() {}
    public var total: Int { steps + concepts + methodSelection + assumptions + algebra + conditioning + generalization + misconceptions }
    /// 0–24 → 1–5.
    public var suggestedDifficulty: Int { min(5, max(1, 1 + Int((Double(total) / 24.0 * 4.0).rounded()))) }
    public var values: [Int] { [steps, concepts, methodSelection, assumptions, algebra, conditioning, generalization, misconceptions] }
}

/// A numeric answer interval for one choice. `nil` bound = unbounded (never encoded as an infinite number).
public struct IntervalChoice: Codable, Hashable, Sendable {
    public var choiceId: String
    public var lower: Double?
    public var upper: Double?
    public var lowerClosed: Bool
    public var upperClosed: Bool
    public init(choiceId: String, lower: Double?, upper: Double?, lowerClosed: Bool = true, upperClosed: Bool = false) {
        self.choiceId = choiceId; self.lower = lower; self.upper = upper; self.lowerClosed = lowerClosed; self.upperClosed = upperClosed
    }
    enum CodingKeys: String, CodingKey { case choiceId, lower, upper, lowerClosed, upperClosed }
    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        choiceId = try c.decode(String.self, forKey: .choiceId); lower = try c.decodeIfPresent(Double.self, forKey: .lower); upper = try c.decodeIfPresent(Double.self, forKey: .upper)
        lowerClosed = try c.decodeIfPresent(Bool.self, forKey: .lowerClosed) ?? true; upperClosed = try c.decodeIfPresent(Bool.self, forKey: .upperClosed) ?? false
    }
    public func contains(_ x: Double) -> Bool {
        if let l = lower, lowerClosed ? x < l : x <= l { return false }
        if let u = upper, upperClosed ? x > u : x >= u { return false }
        return true
    }
}

public struct SourceQuestionRef: Codable, Hashable, Sendable {
    public var sourceQuestionId: String?
    public var document: String?
    public var page: Int?
    public var locator: String?
    public init(sourceQuestionId: String? = nil, document: String? = nil, page: Int? = nil, locator: String? = nil) {
        self.sourceQuestionId = sourceQuestionId; self.document = document; self.page = page; self.locator = locator
    }
}

/// Where a question came from and what it exercises. Generated variants are labelled as such and never presented as instructor questions.
public struct QuestionProvenance: Codable, Hashable, Sendable {
    public var mode: GenerationMode?
    public var planId: String?
    public var slotId: String?
    public var topic: String?
    public var reasoningSkills: [String]
    public var primaryArchetype: String?
    public var secondaryArchetypes: [String]
    public var sourceRefs: [SourceQuestionRef]
    public var difficultyFactors: DifficultyFactors?
    public var origin: String           // "generated_variant" | "generated_general" | "instructor_source"
    enum CodingKeys: String, CodingKey { case mode, planId, slotId, topic, reasoningSkills, primaryArchetype, secondaryArchetypes, sourceRefs, difficultyFactors, origin }
    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        mode = try? c.decodeIfPresent(GenerationMode.self, forKey: .mode); planId = try c.decodeIfPresent(String.self, forKey: .planId); slotId = try c.decodeIfPresent(String.self, forKey: .slotId)
        topic = try c.decodeIfPresent(String.self, forKey: .topic); reasoningSkills = try c.decodeIfPresent([String].self, forKey: .reasoningSkills) ?? []
        primaryArchetype = try c.decodeIfPresent(String.self, forKey: .primaryArchetype); secondaryArchetypes = try c.decodeIfPresent([String].self, forKey: .secondaryArchetypes) ?? []
        sourceRefs = try c.decodeIfPresent([SourceQuestionRef].self, forKey: .sourceRefs) ?? []; difficultyFactors = try? c.decodeIfPresent(DifficultyFactors.self, forKey: .difficultyFactors)
        origin = try c.decodeIfPresent(String.self, forKey: .origin) ?? "generated_variant"
    }
    public init(mode: GenerationMode? = nil, planId: String? = nil, slotId: String? = nil, topic: String? = nil, reasoningSkills: [String] = [], primaryArchetype: String? = nil,
                secondaryArchetypes: [String] = [], sourceRefs: [SourceQuestionRef] = [], difficultyFactors: DifficultyFactors? = nil, origin: String = "generated_general") {
        self.mode = mode; self.planId = planId; self.slotId = slotId; self.topic = topic; self.reasoningSkills = reasoningSkills; self.primaryArchetype = primaryArchetype
        self.secondaryArchetypes = secondaryArchetypes; self.sourceRefs = sourceRefs; self.difficultyFactors = difficultyFactors; self.origin = origin
    }
}

public enum EvidenceKind: String, Codable, Sendable { case schema, consistency, deterministic, modelReview, human, unresolved }
public enum EvidenceResult: String, Codable, Sendable { case passed, failed, unsupported, skipped }

/// What was checked, with which inputs, and what happened. Overall verification is never promoted by one successful expression.
public struct ValidationEvidence: Codable, Hashable, Sendable {
    public var kind: EvidenceKind
    public var check: String
    public var inputs: String
    public var result: EvidenceResult
    public var detail: String
    public init(kind: EvidenceKind, check: String, inputs: String = "", result: EvidenceResult, detail: String = "") {
        self.kind = kind; self.check = check; self.inputs = inputs; self.result = result; self.detail = detail
    }
}

public enum ConfigBasis: String, Codable, Sendable { case confirmed, userProvided, inferred }

/// Per-assessment settings. STOR435's Midterm 3 values are *user-provided* until confirmed against the announcement.
public struct AssessmentConfig: Codable, Equatable, Sendable {
    public var examQuestionCount: Int?
    public var durationMinutes: Int?
    public var pointsPerQuestion: Double?
    public var format: String?                    // e.g. "single_choice"
    public var closedBook: Bool?
    public var roundingDecimals: Int?
    public var scopeIncludes: [String] = []       // topic names/prefixes this assessment covers
    public var scopeExcludes: [String] = []       // explicit exclusions, enforced even when sources mention them
    public var basis: [String: ConfigBasis] = [:] // field name → where it came from
    public init() {}
    public var hasExplicitScope: Bool { !scopeIncludes.isEmpty || !scopeExcludes.isEmpty }
}

import Foundation
import GRDB

/// Provider-independent question schema, version 1. Stored as the immutable payload of a question revision.
public enum QuestionSchema {
    /// v2 = v1 plus optional reasoning metadata, solution plans, intervals and structured checks. v1 responses and payloads stay valid.
    public static let version = "cramlab.questions.v2"
    public static let accepted: Set<String> = ["cramlab.questions.v1", "cramlab.questions.v2"]
}

public enum QuestionType: String, Codable, Sendable, CaseIterable, DatabaseValueConvertible {
    case flashcard
    case singleChoice = "single_choice"
    case multipleSelect = "multiple_select"
    case shortAnswer = "short_answer"
    case numeric
    case codeTracing = "code_tracing"
    case coding
    case longForm = "long_form"
    case derivationProof = "derivation_proof"

    public var label: String {
        switch self {
        case .flashcard: "Flashcard"
        case .singleChoice: "Single choice"
        case .multipleSelect: "Multiple select"
        case .shortAnswer: "Short answer"
        case .numeric: "Numeric"
        case .codeTracing: "Code tracing"
        case .coding: "Coding"
        case .longForm: "Long-form"
        case .derivationProof: "Derivation / proof"
        }
    }

    /// Evaluation methods that make sense for this type. `exact`/`choice`/`numeric` are deterministic.
    public var allowedMethods: [EvaluationMethod] {
        switch self {
        case .flashcard: [.selfReview]
        case .singleChoice, .multipleSelect: [.choice]
        case .shortAnswer: [.exact, .symbolic, .selfReview, .aiRubric]
        case .numeric: [.numeric]
        case .codeTracing: [.exact, .selfReview]
        case .coding: [.codeTests, .selfReview, .aiRubric]
        case .longForm, .derivationProof: [.selfReview, .aiRubric]
        }
    }
}

public enum EvaluationMethod: String, Codable, Sendable, DatabaseValueConvertible {
    case exact, choice, numeric
    /// Algebraic equivalence of polynomial / rational expressions (`SymbolicMath`), e.g. "(x+1)^2" = "x^2+2x+1".
    case symbolic
    /// Run the learner's program against stdin→stdout tests in the sandbox (needs the code runner).
    case codeTests = "code_tests"
    case selfReview = "self_review"
    case aiRubric = "ai_rubric"
}

public enum BlockKind: String, Codable, Sendable {
    case markdown, code, math, table, image
}

public struct ContentBlock: Codable, Hashable, Sendable {
    public var kind: BlockKind
    public var text: String?        // markdown, code
    public var language: String?    // code
    public var latex: String?       // math
    public var headers: [String]?   // table
    public var rows: [[String]]?    // table
    public var description: String? // image alt text (required)
    public var ref: String?         // image attachment reference

    public init(kind: BlockKind, text: String? = nil, language: String? = nil, latex: String? = nil,
                headers: [String]? = nil, rows: [[String]]? = nil, description: String? = nil, ref: String? = nil) {
        self.kind = kind; self.text = text; self.language = language; self.latex = latex
        self.headers = headers; self.rows = rows; self.description = description; self.ref = ref
    }

    public static func markdown(_ s: String) -> ContentBlock { ContentBlock(kind: .markdown, text: s) }

    /// Plain text used for hashing, search and previews.
    public var plainText: String {
        switch kind {
        case .markdown, .code: text ?? ""
        case .math: latex ?? ""
        case .table: ((headers ?? []) + (rows ?? []).flatMap { $0 }).joined(separator: " ")
        case .image: description ?? ""
        }
    }
}

public struct Choice: Codable, Hashable, Sendable {
    public var id: String
    public var text: String
    /// Why this option is right or wrong. Optional: questions saved before this existed have none, and are never given invented ones.
    public var why: String?
    public init(id: String, text: String, why: String? = nil) { self.id = id; self.text = text; self.why = why }
}

public struct RubricItem: Codable, Hashable, Sendable {
    public var criterion: String
    public var points: Double
    public init(criterion: String, points: Double) { self.criterion = criterion; self.points = points }
}

/// Type-specific answer data. Which fields are required depends on `QuestionType` (see `QuestionValidator`).
public struct AnswerSpec: Codable, Hashable, Sendable {
    public var back: [ContentBlock]?            // flashcard
    public var choices: [Choice]?               // single_choice, multiple_select
    public var correctIds: [String]?            // single_choice (exactly 1), multiple_select (≥1)
    public var accepted: [String]?              // short_answer, code_tracing (exact)
    public var caseSensitive: Bool?
    public var expression: String?              // short_answer + symbolic: the key expression
    public var value: Double?                   // numeric
    public var tolerance: Double?
    public var unit: String?
    /// Optional arithmetic expression (numbers, + - * / ^, parentheses, pi) that independently re-derives `value`.
    public var verificationExpression: String?
    public var expectedOutput: String?          // code_tracing
    public var language: String?                // coding: python | c | java
    public var starterCode: String?
    public var referenceSolution: String?
    /// coding + `code_tests`: the program reads stdin and writes stdout.
    public var tests: [CodeTest]?
    /// Choice questions with numeric intervals: structured bounds per choice (the displayed text is not parsed for math).
    public var intervals: [IntervalChoice]?
    /// The underlying numeric result the intervals are checked against, and the rounding the question requires.
    public var exactResult: Double?
    public var roundingDecimals: Int?
    /// A structured problem the app can recompute deterministically (see `MathChecks`).
    public var check: StructuredCheck?

    public init(back: [ContentBlock]? = nil, choices: [Choice]? = nil, correctIds: [String]? = nil,
                accepted: [String]? = nil, caseSensitive: Bool? = nil, expression: String? = nil, value: Double? = nil, tolerance: Double? = nil,
                unit: String? = nil, verificationExpression: String? = nil, expectedOutput: String? = nil,
                language: String? = nil, starterCode: String? = nil, referenceSolution: String? = nil, tests: [CodeTest]? = nil,
                intervals: [IntervalChoice]? = nil, exactResult: Double? = nil, roundingDecimals: Int? = nil, check: StructuredCheck? = nil) {
        self.intervals = intervals; self.exactResult = exactResult; self.roundingDecimals = roundingDecimals; self.check = check
        self.back = back; self.choices = choices; self.correctIds = correctIds; self.accepted = accepted
        self.caseSensitive = caseSensitive; self.expression = expression; self.value = value; self.tolerance = tolerance; self.unit = unit
        self.verificationExpression = verificationExpression; self.expectedOutput = expectedOutput
        self.language = language; self.starterCode = starterCode; self.referenceSolution = referenceSolution; self.tests = tests
    }
}

public struct EvaluationSpec: Codable, Hashable, Sendable {
    public var method: EvaluationMethod
    public var rubric: [RubricItem]?
    public init(method: EvaluationMethod, rubric: [RubricItem]? = nil) { self.method = method; self.rubric = rubric }
}

public struct SourceRef: Codable, Hashable, Sendable {
    public var document: String?
    public var page: Int?
    public var note: String?
    public init(document: String? = nil, page: Int? = nil, note: String? = nil) { self.document = document; self.page = page; self.note = note }
}

public struct GenerationMetadata: Codable, Hashable, Sendable {
    public var generator: String?
    public var model: String?
    public var requestId: String?
    public var provenance: QuestionProvenance?
    public init(generator: String? = nil, model: String? = nil, requestId: String? = nil, provenance: QuestionProvenance? = nil) {
        self.generator = generator; self.model = model; self.requestId = requestId; self.provenance = provenance
    }
}

/// The immutable content of a question revision.
public struct QuestionSpec: Codable, Hashable, Sendable {
    public var type: QuestionType
    public var title: String
    public var difficulty: Int                 // 1 (easy) … 5 (hard)
    public var learningObjective: String
    public var content: [ContentBlock]
    public var answer: AnswerSpec
    public var evaluation: EvaluationSpec
    public var hints: [String]
    public var solution: [ContentBlock]
    public var sources: [SourceRef]
    public var metadata: GenerationMetadata?
    /// Structured educational solution (interpretation, method, steps…); separate from the student-visible question.
    public var solutionPlan: SolutionPlan?

    public init(type: QuestionType, title: String, difficulty: Int, learningObjective: String, content: [ContentBlock],
                answer: AnswerSpec, evaluation: EvaluationSpec, hints: [String] = [], solution: [ContentBlock] = [],
                sources: [SourceRef] = [], metadata: GenerationMetadata? = nil, solutionPlan: SolutionPlan? = nil) {
        self.solutionPlan = solutionPlan
        self.type = type; self.title = title; self.difficulty = difficulty; self.learningObjective = learningObjective
        self.content = content; self.answer = answer; self.evaluation = evaluation; self.hints = hints
        self.solution = solution; self.sources = sources; self.metadata = metadata
    }

    /// Statement text normalised for duplicate detection.
    public var statementText: String { content.map(\.plainText).joined(separator: " ") }
}

/// A question as it appears in an import: the spec plus names to be resolved against the course.
public struct ImportedQuestion: Sendable {
    public var importId: String
    public var spec: QuestionSpec
    public var skillNames: [String]
    public var assessmentNames: [String]
}

public enum Readiness: String, Codable, Sendable, CaseIterable, DatabaseValueConvertible {
    /// Answer independently confirmed (computed check passed, or the user verified it).
    case verified
    /// Structurally valid and complete, but correctness is not independently confirmed.
    case unverified
    /// Saved, but something needs a human decision (ambiguity, probable duplicate, missing solution…).
    case needsReview
    /// Failed blocking validation; never saved as a question.
    case invalid

    public var label: String {
        switch self { case .verified: "Verified"; case .unverified: "Unverified"; case .needsReview: "Needs review"; case .invalid: "Invalid" }
    }
    /// Only verified answers may drive trusted automated grading (see Evaluation).
    public var allowsTrustedAutoGrading: Bool { self == .verified }
}

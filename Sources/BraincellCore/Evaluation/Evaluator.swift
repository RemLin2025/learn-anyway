import Foundation

public struct EvaluationOutcome: Sendable, Equatable {
    public var method: EvaluationMethod
    public var state: EvaluationState
    public var score: Double?
    public var trust: GradeTrust
    public var feedback: String
}

/// Grading independent of rendering and persistence. Deterministic methods only; anything subjective returns
/// `.pending`, which is never treated as incorrect.
public enum Evaluator {

    public static func evaluate(spec: QuestionSpec, response: PracticeResponse, answerKeyVerified: Bool) -> EvaluationOutcome {
        let trust: GradeTrust = answerKeyVerified ? .trusted : .provisional
        let method = spec.evaluation.method
        switch method {
        case .choice: return choice(spec, response, trust)
        case .exact: return exact(spec, response, trust)
        case .numeric: return numeric(spec, response, trust)
        case .symbolic: return symbolic(spec, response, trust)
        case .codeTests:
            return EvaluationOutcome(method: method, state: .pending, score: nil, trust: .provisional,
                                     feedback: "Waiting for the tests to run in the sandbox. If running code is switched off, review it yourself against the reference.")
        case .selfReview, .aiRubric:
            return EvaluationOutcome(method: method, state: .pending, score: nil, trust: .provisional,
                                     feedback: method == .aiRubric ? "Waiting for a grade: review yourself against the rubric, or export a grading batch for ChatGPT."
                                                                     : "Waiting for your self-review.")
        }
    }

    // MARK: Choice

    static func choice(_ spec: QuestionSpec, _ r: PracticeResponse, _ trust: GradeTrust) -> EvaluationOutcome {
        let correct = Set(spec.answer.correctIds ?? []), chosen = Set(r.selected)
        if chosen == correct { return EvaluationOutcome(method: .choice, state: .graded, score: 1, trust: trust, feedback: "All correct options selected.") }
        guard spec.type == .multipleSelect else {
            return EvaluationOutcome(method: .choice, state: .graded, score: 0, trust: trust, feedback: "Not the keyed answer.")
        }
        // Partial credit for multiple select: right picks minus wrong picks, never below 0.
        let tp = Double(chosen.intersection(correct).count), fp = Double(chosen.subtracting(correct).count)
        let s = max(0, (tp - fp) / Double(max(1, correct.count)))
        return EvaluationOutcome(method: .choice, state: .graded, score: s, trust: trust,
                                 feedback: "\(Int(tp)) of \(correct.count) correct options selected\(fp > 0 ? ", \(Int(fp)) wrong" : "").")
    }

    // MARK: Exact

    static func normalize(_ s: String, caseSensitive: Bool, multiline: Bool) -> String {
        var t = s.replacingOccurrences(of: "\r\n", with: "\n")
        if multiline { t = t.split(separator: "\n", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }.joined(separator: "\n") }
        else { t = t.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ") }
        t = t.trimmingCharacters(in: .whitespacesAndNewlines)
        if !multiline { while let l = t.last, ".;!".contains(l) { t.removeLast() } }
        return caseSensitive ? t : t.lowercased()
    }

    static func exact(_ spec: QuestionSpec, _ r: PracticeResponse, _ trust: GradeTrust) -> EvaluationOutcome {
        let cs = spec.answer.caseSensitive ?? (spec.type == .codeTracing)
        let multi = spec.type == .codeTracing
        let accepted = (spec.answer.accepted ?? []) + (spec.answer.expectedOutput.map { [$0] } ?? [])
        let given = normalize(r.text, caseSensitive: cs, multiline: multi)
        guard !given.isEmpty else { return EvaluationOutcome(method: .exact, state: .graded, score: 0, trust: trust, feedback: "No answer entered.") }
        let ok = accepted.contains { normalize($0, caseSensitive: cs, multiline: multi) == given }
        return EvaluationOutcome(method: .exact, state: .graded, score: ok ? 1 : 0, trust: trust,
                                 feedback: ok ? "Matches an accepted answer." : "Doesn’t match an accepted answer. Close variants may need your own review.")
    }

    // MARK: Symbolic

    static func symbolic(_ spec: QuestionSpec, _ r: PracticeResponse, _ trust: GradeTrust) -> EvaluationOutcome {
        guard let key = spec.answer.expression, !key.isEmpty else {
            return EvaluationOutcome(method: .symbolic, state: .evaluatorUnavailable, score: nil, trust: trust, feedback: "This question has no key expression.")
        }
        guard !r.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return EvaluationOutcome(method: .symbolic, state: .graded, score: 0, trust: trust, feedback: "No answer entered.")
        }
        // Unreadable or unsupported input is a checker limit, not a wrong answer: leave it for the learner to review.
        switch SymbolicMath.compare(key: key, answer: r.text) {
        case .equal: return EvaluationOutcome(method: .symbolic, state: .graded, score: 1, trust: trust, feedback: "Algebraically equivalent to the key.")
        case .notEqual: return EvaluationOutcome(method: .symbolic, state: .graded, score: 0, trust: trust, feedback: "Not equivalent to the key. Check by expanding both sides.")
        case .unsupported(let why), .unreadable(let why): return EvaluationOutcome(method: .symbolic, state: .needsReview, score: nil, trust: trust, feedback: why + " Compare it with the key yourself.")
        }
    }

    // MARK: Numeric

    /// Accepts integers, decimals, scientific notation and simple fractions ("7/2"), with optional thousands spaces.
    /// A comma is rejected rather than guessed (is "1,5" one-and-a-half or fifteen hundred?).
    public static func parseNumber(_ raw: String) -> Double? {
        let t = raw.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "−", with: "-")
        guard !t.isEmpty, !t.contains(",") else { return nil }
        let parts = t.split(separator: "/", omittingEmptySubsequences: false)
        func num(_ s: Substring) -> Double? {
            let x = s.trimmingCharacters(in: .whitespaces)
            guard !x.isEmpty, x.range(of: #"^[+-]?(\d+\.?\d*|\.\d+)([eE][+-]?\d+)?$"#, options: .regularExpression) != nil else { return nil }
            return Double(x)
        }
        if parts.count == 1 { return num(parts[0]).flatMap { $0.isFinite ? $0 : nil } }
        if parts.count == 2, let a = num(parts[0]), let b = num(parts[1]), b != 0 { return a / b }
        return nil
    }

    static func numeric(_ spec: QuestionSpec, _ r: PracticeResponse, _ trust: GradeTrust) -> EvaluationOutcome {
        guard let key = spec.answer.value else {
            return EvaluationOutcome(method: .numeric, state: .evaluatorUnavailable, score: nil, trust: trust, feedback: "This question has no numeric key.")
        }
        guard let x = parseNumber(r.text) else {
            // A formatting problem isn't a wrong answer: leave it for the learner to review.
            return EvaluationOutcome(method: .numeric, state: .needsReview, score: nil, trust: trust,
                                     feedback: "Couldn’t read “\(r.text.trimmingCharacters(in: .whitespacesAndNewlines))” as a number (use 3.5, 7/2 or 1e3).")
        }
        let tol = max(spec.answer.tolerance ?? 0, 1e-9 * max(1, abs(key)))
        let ok = abs(x - key) <= tol
        return EvaluationOutcome(method: .numeric, state: .graded, score: ok ? 1 : 0, trust: trust,
                                 feedback: ok ? "Within tolerance." : "Outside the accepted range.")
    }
}

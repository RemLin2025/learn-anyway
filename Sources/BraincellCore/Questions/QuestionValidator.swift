import Foundation

public struct ValidationIssue: Codable, Hashable, Sendable {
    public enum Severity: String, Codable, Sendable {
        /// Question cannot be saved.
        case blocking
        /// Question is saved but flagged "needs review".
        case review
    }
    public var path: String
    public var message: String
    public var severity: Severity
    public var description: String { "\(path): \(message)" }
}

public struct ValidationResult: Sendable {
    public var question: ImportedQuestion?
    public var issues: [ValidationIssue]
    /// True when a deterministic, independent check confirmed the answer.
    public var computedVerification: Bool
    /// What was checked and how it came out (schema, consistency, deterministic, unresolved…).
    public var evidence: [ValidationEvidence] = []
    public var hasBlocking: Bool { issues.contains { $0.severity == .blocking } }
    public var readiness: Readiness {
        if hasBlocking || question == nil { return .invalid }
        if issues.contains(where: { $0.severity == .review }) { return .needsReview }
        return computedVerification ? .verified : .unverified
    }
}

public enum QuestionLimits {
    public static let title = 200
    public static let textField = 20_000
    public static let blocks = 30
    public static let choices = 10
    public static let hints = 10
    public static let hintLength = 2_000
    public static let skills = 10
}

/// Layers 1 (structural) and 2 (consistency) of validation, plus the deterministic part of layer 3.
/// Works on untyped JSON so every problem is reported with an exact path (used to build repair requests).
public enum QuestionValidator {

    public static func validate(entry: Any, index: Int) -> ValidationResult {
        var c = Collector()
        let root = "questions[\(index)]"
        guard let d = entry as? [String: Any] else {
            c.block(root, "must be a JSON object")
            return ValidationResult(question: nil, issues: c.issues, computedVerification: false)
        }
        let importId = c.string(d, "importId", root, required: false, max: 100) ?? "q\(index + 1)"
        guard let typeRaw = c.string(d, "type", root, required: true, max: 50) else {
            return ValidationResult(question: nil, issues: c.issues, computedVerification: false)
        }
        guard let type = QuestionType(rawValue: typeRaw) else {
            c.block("\(root).type", "unsupported question type “\(typeRaw)”. Allowed: \(QuestionType.allCases.map(\.rawValue).joined(separator: ", "))")
            return ValidationResult(question: nil, issues: c.issues, computedVerification: false)
        }
        let title = c.string(d, "title", root, required: true, max: QuestionLimits.title) ?? ""
        let difficulty = c.int(d, "difficulty", root, range: 1...5)
        let objective = c.string(d, "learningObjective", root, required: true, max: 1_000) ?? ""
        let content = c.blocks(d["content"], "\(root).content", required: true)
        let solution = c.blocks(d["solution"], "\(root).solution", required: false)
        if d["solution"] == nil || solution.isEmpty { c.review("\(root).solution", "missing reference solution") }

        let ev = c.evaluation(d["evaluation"], "\(root).evaluation", type: type)
        let (answer, computed) = c.answer(d["answer"], "\(root).answer", type: type, method: ev?.method)

        var hints: [String] = []
        if let raw = d["hints"] {
            if let arr = raw as? [Any], arr.count <= QuestionLimits.hints {
                for (i, h) in arr.enumerated() {
                    if let s = h as? String, s.count <= QuestionLimits.hintLength { hints.append(s) }
                    else { c.block("\(root).hints[\(i)]", "must be a string of at most \(QuestionLimits.hintLength) characters") }
                }
            } else { c.block("\(root).hints", "must be an array of at most \(QuestionLimits.hints) strings") }
        }
        let skills = c.stringList(d["skills"], "\(root).skills", max: QuestionLimits.skills)
        let assessments = c.stringList(d["assessments"], "\(root).assessments", max: 20)

        var sources: [SourceRef] = []
        if let raw = d["sources"] {
            if let arr = raw as? [[String: Any]], arr.count <= 20 {
                sources = arr.map { SourceRef(document: $0["document"] as? String, page: $0["page"] as? Int, note: $0["note"] as? String) }
            } else { c.block("\(root).sources", "must be an array of up to 20 objects") }
        }
        var meta: GenerationMetadata?
        if let m = d["metadata"] as? [String: Any] {
            var prov: QuestionProvenance?
            if let pr = m["provenance"], let data = try? JSONSerialization.data(withJSONObject: pr) { prov = try? JSONDecoder().decode(QuestionProvenance.self, from: data) }
            meta = GenerationMetadata(generator: m["generator"] as? String, model: m["model"] as? String, requestId: m["requestId"] as? String, provenance: prov)
        }
        var plan: SolutionPlan?
        if let sp = d["solutionPlan"] {
            if let data = try? JSONSerialization.data(withJSONObject: sp), let decoded = try? JSONDecoder().decode(SolutionPlan.self, from: data) {
                plan = decoded
                if !decoded.isComplete { c.review("\(root).solutionPlan", "solution plan is incomplete (needs interpretation, method, at least two steps and a final result)") }
            } else { c.review("\(root).solutionPlan", "solution plan could not be read and was dropped") }
        }

        guard !c.issues.contains(where: { $0.severity == .blocking }), let difficulty, let ev, let answer else {
            return ValidationResult(question: nil, issues: c.issues, computedVerification: false)
        }
        let spec = QuestionSpec(type: type, title: title, difficulty: difficulty, learningObjective: objective, content: content,
                                answer: answer, evaluation: ev, hints: hints, solution: solution, sources: sources, metadata: meta, solutionPlan: plan)
        c.evidence.insert(ValidationEvidence(kind: .schema, check: "question structure", result: .passed), at: 0)
        if c.evidence.allSatisfy({ $0.kind != .deterministic }) { c.evidence.append(ValidationEvidence(kind: .unresolved, check: "mathematical correctness", result: .unsupported, detail: "no deterministic check applies; correctness is not independently confirmed")) }
        return ValidationResult(question: ImportedQuestion(importId: importId, spec: spec, skillNames: skills, assessmentNames: assessments),
                                issues: c.issues, computedVerification: computed, evidence: c.evidence)
    }

    /// Re-validates an already-typed spec (used when a question is edited by hand).
    public static func validate(spec: QuestionSpec) -> ValidationResult {
        guard let data = try? JSONEncoder().encode(spec), let obj = try? JSONSerialization.jsonObject(with: data) else {
            return ValidationResult(question: nil, issues: [ValidationIssue(path: "spec", message: "could not be encoded", severity: .blocking)], computedVerification: false)
        }
        return validate(entry: obj, index: 0)
    }

    // MARK: Collector

    struct Collector {
        var issues: [ValidationIssue] = []
        var evidence: [ValidationEvidence] = []
        /// `(1 as NSNumber) is Bool` is true in Swift, so check the underlying CF type instead.
        static func isBool(_ n: NSNumber) -> Bool { CFGetTypeID(n) == CFBooleanGetTypeID() }
        mutating func block(_ p: String, _ m: String) { issues.append(ValidationIssue(path: p, message: m, severity: .blocking)) }
        mutating func review(_ p: String, _ m: String) { issues.append(ValidationIssue(path: p, message: m, severity: .review)) }

        mutating func string(_ d: [String: Any], _ key: String, _ base: String, required: Bool, max: Int) -> String? {
            guard let raw = d[key] else { if required { block("\(base).\(key)", "is required") }; return nil }
            guard let s = raw as? String else { block("\(base).\(key)", "must be a string"); return nil }
            let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
            if t.isEmpty && required { block("\(base).\(key)", "must not be empty"); return nil }
            if s.count > max { block("\(base).\(key)", "is longer than \(max) characters"); return nil }
            return s
        }

        mutating func int(_ d: [String: Any], _ key: String, _ base: String, range: ClosedRange<Int>) -> Int? {
            guard let raw = d[key] else { block("\(base).\(key)", "is required"); return nil }
            guard let n = raw as? NSNumber, !Self.isBool(n), n.doubleValue == n.doubleValue.rounded(), range.contains(n.intValue) else {
                block("\(base).\(key)", "must be an integer from \(range.lowerBound) to \(range.upperBound)"); return nil
            }
            return n.intValue
        }

        mutating func stringList(_ raw: Any?, _ path: String, max: Int) -> [String] {
            guard let raw else { return [] }
            guard let arr = raw as? [Any], arr.count <= max, arr.allSatisfy({ ($0 as? String)?.count ?? 1_000 <= 200 }) else {
                block(path, "must be an array of up to \(max) short strings"); return []
            }
            return arr.compactMap { ($0 as? String)?.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        }

        mutating func blocks(_ raw: Any?, _ path: String, required: Bool) -> [ContentBlock] {
            guard let raw else { if required { block(path, "is required") }; return [] }
            guard let arr = raw as? [Any] else { block(path, "must be an array of content blocks"); return [] }
            if arr.isEmpty && required { block(path, "must contain at least one block") }
            if arr.count > QuestionLimits.blocks { block(path, "has more than \(QuestionLimits.blocks) blocks"); return [] }
            var out: [ContentBlock] = []
            for (i, item) in arr.enumerated() {
                let p = "\(path)[\(i)]"
                guard let d = item as? [String: Any] else { block(p, "must be an object"); continue }
                guard let kindRaw = d["kind"] as? String, let kind = BlockKind(rawValue: kindRaw) else {
                    block("\(p).kind", "must be one of markdown, code, math, table, image"); continue
                }
                var b = ContentBlock(kind: kind)
                switch kind {
                case .markdown:
                    b.text = string(d, "text", p, required: true, max: QuestionLimits.textField)
                    if let t = b.text {
                        for issue in MathMarkdown.issues(t) { review("\(p).text", issue) }     // flagged, never silently repaired
                        b.text = MathMarkdown.normalize(t)                                    // $…$ → \(…\), $$…$$ → \[…\]; formulas copied verbatim
                    }
                case .code:
                    b.text = string(d, "text", p, required: true, max: QuestionLimits.textField)
                    b.language = string(d, "language", p, required: false, max: 30)
                case .math: b.latex = string(d, "latex", p, required: true, max: QuestionLimits.textField)
                case .table:
                    if let h = d["headers"] as? [String], let r = d["rows"] as? [[String]], !h.isEmpty, r.count <= 100,
                       r.allSatisfy({ $0.count == h.count }) { b.headers = h; b.rows = r }
                    else { block(p, "table needs non-empty headers and rows (≤100) with the same column count") }
                case .image:
                    b.ref = string(d, "ref", p, required: true, max: 500)
                    b.description = string(d, "description", p, required: true, max: 1_000) // accessibility
                }
                out.append(b)
            }
            return out
        }

        mutating func evaluation(_ raw: Any?, _ path: String, type: QuestionType) -> EvaluationSpec? {
            guard let d = raw as? [String: Any] else { block(path, "is required and must be an object"); return nil }
            guard let m = d["method"] as? String, let method = EvaluationMethod(rawValue: m) else {
                block("\(path).method", "must be one of exact, choice, numeric, self_review, ai_rubric"); return nil
            }
            guard type.allowedMethods.contains(method) else {
                block("\(path).method", "“\(m)” is not valid for \(type.rawValue). Allowed: \(type.allowedMethods.map(\.rawValue).joined(separator: ", "))"); return nil
            }
            var rubric: [RubricItem]?
            if let r = d["rubric"] {
                if let arr = r as? [[String: Any]], arr.count <= 20,
                   let items = Optional(arr.compactMap { i -> RubricItem? in
                       guard let c = i["criterion"] as? String, let p = (i["points"] as? NSNumber)?.doubleValue, p >= 0 else { return nil }
                       return RubricItem(criterion: c, points: p) }), items.count == arr.count { rubric = items }
                else { block("\(path).rubric", "must be an array of {criterion, points ≥ 0}") }
            }
            if method == .aiRubric, rubric?.isEmpty ?? true { review("\(path).rubric", "ai_rubric grading needs a rubric") }
            return EvaluationSpec(method: method, rubric: rubric)
        }

        /// Returns the answer and whether a deterministic independent check confirmed it.
        /// Interval choices and structured checks. Returns true only when a deterministic recomputation agrees with the marked-correct interval.
        mutating func verifiedChoice(_ a: inout AnswerSpec, _ d: [String: Any], _ path: String, type: QuestionType) -> Bool {
            func decode<T: Decodable>(_ key: String, _ t: T.Type) -> T? {
                guard let raw = d[key], let data = try? JSONSerialization.data(withJSONObject: raw) else { return nil }
                return try? JSONDecoder().decode(t, from: data)
            }
            if d["intervals"] != nil, decode("intervals", [IntervalChoice].self) == nil { block("\(path).intervals", "must be an array of {choiceId, lower, upper, lowerClosed, upperClosed} with null for unbounded"); return false }
            if d["check"] != nil, decode("check", StructuredCheck.self) == nil { block("\(path).check", "is not a valid structured check"); return false }
            let intervals = decode("intervals", [IntervalChoice].self), check = decode("check", StructuredCheck.self)
            a.roundingDecimals = (d["roundingDecimals"] as? NSNumber).map { $0.intValue }
            a.exactResult = (d["exactResult"] as? NSNumber).map { $0.doubleValue }
            a.check = check
            var computed: Double?
            if let check {
                let r = MathChecks.run(check); evidence.append(r.evidence); computed = r.computed
                if r.evidence.result == .failed { block("\(path).check", r.evidence.detail) }
                if let c = computed, let e = a.exactResult, abs(c - e) > 1e-9 * max(1, abs(c)) { block("\(path).exactResult", "states \(e) but the structured check computes \(c)") }
                if a.exactResult == nil { a.exactResult = computed }
            }
            guard let intervals, type == .singleChoice else { return false }
            a.intervals = intervals
            let r = IntervalChecks.validate(choiceIds: (a.choices ?? []).map(\.id), correctId: a.correctIds?.first, intervals: intervals, exactResult: a.exactResult, decimals: a.roundingDecimals, resultIsComputed: computed != nil)
            for p in r.problems { block("\(path).intervals", p) }
            evidence += r.evidence
            // Promote only when the number came from a deterministic recomputation and the correct interval contains it.
            return r.problems.isEmpty && computed != nil && r.evidence.contains { $0.check == "interval membership" && $0.result == .passed }
        }

        mutating func answer(_ raw: Any?, _ path: String, type: QuestionType, method: EvaluationMethod?) -> (AnswerSpec?, Bool) {
            guard let d = raw as? [String: Any] else { block(path, "is required and must be an object"); return (nil, false) }
            var a = AnswerSpec()
            var verified = false
            switch type {
            case .flashcard:
                a.back = blocks(d["back"], "\(path).back", required: true)
            case .singleChoice, .multipleSelect:
                guard let arr = d["choices"] as? [[String: Any]], (2...QuestionLimits.choices).contains(arr.count) else {
                    block("\(path).choices", "must be 2–\(QuestionLimits.choices) objects with id and text"); return (nil, false)
                }
                let choices = arr.compactMap { c -> Choice? in
                    guard let id = c["id"] as? String, !id.isEmpty, let t = c["text"] as? String, !t.isEmpty, t.count <= 2_000 else { return nil }
                    return Choice(id: id, text: t) }
                guard choices.count == arr.count else { block("\(path).choices", "each choice needs a non-empty id and text"); return (nil, false) }
                guard Set(choices.map(\.id)).count == choices.count else { block("\(path).choices", "choice ids must be unique"); return (nil, false) }
                guard let ids = d["correctIds"] as? [String], !ids.isEmpty, Set(ids).count == ids.count else {
                    block("\(path).correctIds", "must list at least one distinct correct choice id"); return (nil, false)
                }
                if let bad = ids.first(where: { id in !choices.contains { $0.id == id } }) {
                    block("\(path).correctIds", "“\(bad)” is not one of the choice ids"); return (nil, false)
                }
                if type == .singleChoice, ids.count != 1 { block("\(path).correctIds", "single_choice needs exactly one correct id"); return (nil, false) }
                if type == .multipleSelect, ids.count == choices.count { review("\(path).correctIds", "every option is marked correct; check this is intended") }
                a.choices = choices; a.correctIds = ids
                if verifiedChoice(&a, d, path, type: type) { verified = true }
            case .shortAnswer, .codeTracing:
                if method == .symbolic {
                    guard let expr = d["expression"] as? String, !expr.isEmpty, expr.count <= 600 else { block("\(path).expression", "symbolic evaluation needs an expression (≤ 600 characters)"); return (nil, false) }
                    switch SymbolicMath.parse(expr) {
                    case .success: a.expression = expr
                    case .failure(.unsupported(let m)): block("\(path).expression", "uses \(m), which the symbolic checker can’t handle; use exact or self_review"); return (nil, false)
                    case .failure(.unreadable(let m)): block("\(path).expression", "isn’t a readable expression: \(m)"); return (nil, false)
                    }
                }
                let accepted = stringList(d["accepted"], "\(path).accepted", max: 20)
                if type == .codeTracing { a.expectedOutput = string(d, "expectedOutput", path, required: method == .exact, max: QuestionLimits.textField) }
                if method == .exact {
                    let pool = accepted + (a.expectedOutput.map { [$0] } ?? [])
                    if pool.isEmpty { block("\(path).accepted", "exact evaluation needs at least one accepted answer") }
                }
                a.accepted = accepted; a.caseSensitive = d["caseSensitive"] as? Bool
            case .numeric:
                guard let v = (d["value"] as? NSNumber), !Collector.isBool(v), v.doubleValue.isFinite else {
                    block("\(path).value", "must be a finite number"); return (nil, false)
                }
                let tol = (d["tolerance"] as? NSNumber)?.doubleValue ?? 0
                guard tol >= 0, tol.isFinite else { block("\(path).tolerance", "must be ≥ 0"); return (nil, false) }
                a.value = v.doubleValue; a.tolerance = tol; a.unit = d["unit"] as? String
                if let expr = d["verificationExpression"] as? String {
                    a.verificationExpression = expr
                    switch Result(catching: { try ArithmeticEvaluator.evaluate(expr) }) {
                    case .success(let computed):
                        if abs(computed - v.doubleValue) <= max(tol, 1e-9 * max(1, abs(computed))) { verified = true }
                        else { review("\(path).verificationExpression", "evaluates to \(computed) but the stated value is \(v.doubleValue)") }
                    case .failure: review("\(path).verificationExpression", "could not be evaluated; answer left unverified")
                    }
                }
            case .coding:
                let lang = (d["language"] as? String)?.lowercased()
                guard let lang, ["python", "c", "java"].contains(lang) else {
                    block("\(path).language", "must be python, c or java"); return (nil, false)
                }
                a.language = lang
                a.starterCode = string(d, "starterCode", path, required: false, max: QuestionLimits.textField)
                a.referenceSolution = string(d, "referenceSolution", path, required: false, max: QuestionLimits.textField)
                if (a.referenceSolution ?? "").isEmpty { review("\(path).referenceSolution", method == .codeTests ? "code_tests needs a reference solution so the tests can be checked" : "no reference solution") }
                if method == .codeTests {
                    guard let raw = d["tests"] as? [[String: Any]], (1...20).contains(raw.count) else { block("\(path).tests", "code_tests needs 1–20 tests, each {name, input, expectedOutput}"); return (nil, false) }
                    var tests: [CodeTest] = [], names = Set<String>()
                    for (i, t) in raw.enumerated() {
                        guard let n = t["name"] as? String, !n.isEmpty, n.count <= 80, names.insert(n).inserted else { block("\(path).tests[\(i)].name", "must be a unique non-empty string (≤ 80 characters)"); continue }
                        guard let inp = t["input"] as? String, inp.count <= 4_000 else { block("\(path).tests[\(i)].input", "must be a string of at most 4000 characters (stdin)"); continue }
                        guard let out = t["expectedOutput"] as? String, out.count <= 4_000 else { block("\(path).tests[\(i)].expectedOutput", "must be a string of at most 4000 characters (stdout)"); continue }
                        tests.append(CodeTest(name: n, input: inp, expectedOutput: out, hidden: t["hidden"] as? Bool))
                    }
                    a.tests = tests
                }
            case .longForm, .derivationProof:
                break // graded by rubric/self-review; solution carries the model answer
            }
            return (a, verified)
        }
    }
}

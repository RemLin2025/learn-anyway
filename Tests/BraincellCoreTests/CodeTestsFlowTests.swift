import Testing
import Foundation
import GRDB
@testable import BraincellCore

@Suite struct CodeTestsFlowTests {
    let runner = SandboxedCodeRunner()

    func spec(language: String = "python", reference: String, method: EvaluationMethod = .codeTests, difficulty: Int = 3, tests: [CodeTest]? = nil) -> QuestionSpec {
        let t = tests ?? [CodeTest(name: "small", input: "3", expectedOutput: "0\n1\n4"), CodeTest(name: "one", input: "1", expectedOutput: "0"),
                          CodeTest(name: "hidden big", input: "5", expectedOutput: "0\n1\n4\n9\n16", hidden: true)]
        return QuestionSpec(type: .coding, title: "Print squares \(UUID().uuidString.prefix(4))", difficulty: difficulty, learningObjective: "Loops",
                            content: [.markdown("Read n; print the first n squares, one per line.")],
                            answer: AnswerSpec(language: language, starterCode: "n = int(input())\n", referenceSolution: reference, tests: t),
                            evaluation: EvaluationSpec(method: method), hints: ["Use range(n)"], solution: [.markdown("Loop and print i*i")])
    }
    static let goodPy = "n = int(input())\nfor i in range(n):\n    print(i * i)"

    func attempt(_ rig: Rig, _ q: Question, code: String, lang: String = "python", hints: Int = 0) throws -> Attempt {
        let s = try rig.practice.start(questionIds: [q.id], title: "t", courseId: rig.course.id)
        let item = try rig.practice.items(sessionId: s.id)[0]
        if hints > 0 { try rig.practice.revealHint(itemId: item.id, level: hints) }
        var r = PracticeResponse(); r.files = [CodeFile(name: PracticeService.defaultFileName(lang), language: lang, content: code)]
        return try rig.practice.submit(itemId: item.id, response: r)
    }

    // MARK: Validation and plain evaluator

    @Test func validatorRequiresWellFormedTests() throws {
        func validate(_ mutate: (inout [String: Any]) -> Void) -> ValidationResult {
            var answer: [String: Any] = ["language": "python", "starterCode": "", "referenceSolution": "print(1)",
                                         "tests": [["name": "a", "input": "1", "expectedOutput": "1"], ["name": "b", "input": "2", "expectedOutput": "2", "hidden": true]]]
            mutate(&answer)
            return QuestionValidator.validate(entry: Fx.base("coding", title: "T", answer: answer, method: "code_tests"), index: 0)
        }
        let ok = validate { _ in }
        #expect(!ok.hasBlocking && ok.question?.spec.answer.tests?.count == 2 && ok.question?.spec.answer.tests?[1].hidden == true)
        #expect(validate { $0["tests"] = nil }.hasBlocking)
        #expect(validate { $0["tests"] = [] }.hasBlocking)
        #expect(validate { $0["tests"] = [["name": "a", "input": "1"]] }.issues.contains { $0.path.hasSuffix("tests[0].expectedOutput") })
        #expect(validate { $0["tests"] = [["name": "a", "input": "", "expectedOutput": ""], ["name": "a", "input": "", "expectedOutput": ""]] }.issues.contains { $0.path.hasSuffix("tests[1].name") })
        #expect(validate { $0["tests"] = (0..<21).map { ["name": "t\($0)", "input": "", "expectedOutput": ""] } }.hasBlocking)
        #expect(validate { $0["tests"] = [["name": "a", "input": String(repeating: "x", count: 5_000), "expectedOutput": ""]] }.hasBlocking)
        let noRef = validate { $0["referenceSolution"] = nil }
        #expect(!noRef.hasBlocking && noRef.readiness == .needsReview)                    // can't be verified without a reference
        // code_tests belongs to coding only.
        #expect(QuestionValidator.validate(entry: Fx.base("numeric", title: "N", answer: ["value": 1], method: "code_tests"), index: 0).hasBlocking)
    }

    @Test func plainEvaluatorNeverGradesCodeTestsItself() {
        let r = Evaluator.evaluate(spec: spec(reference: Self.goodPy), response: PracticeResponse(), answerKeyVerified: true)
        #expect(r.state == .pending && r.score == nil && r.method == .codeTests)
    }

    // MARK: With the real sandbox

    @Test func referenceSolutionVerifiesTheQuestion() async throws {
        let rig = try Rig()
        let q = try rig.qs.create(courseId: rig.course.id, spec: spec(reference: Self.goodPy), skillIds: [rig.skillA.id])
        #expect(try rig.qs.detail(q.id).question.readiness == .unverified)
        let v = CodeVerificationService(db: rig.db)
        #expect(try await v.verify(questionId: q.id, runner: runner) == .verified)
        let d = try rig.qs.detail(q.id).question
        #expect(d.readiness == .verified && d.verificationSource == .computed)

        // A reference that contradicts its tests is flagged, not trusted.
        let bad = try rig.qs.create(courseId: rig.course.id, spec: spec(reference: "n = int(input())\nfor i in range(n):\n    print(i + i)"), skillIds: [rig.skillA.id])
        if case .failed(let f) = try await v.verify(questionId: bad.id, runner: runner) { #expect(f.count >= 2 && f[0].contains("small")) } else { Issue.record("expected failure") }
        let b = try rig.qs.detail(bad.id).question
        #expect(b.readiness == .needsReview && b.notes.contains { $0.hasPrefix("Reference solution fails") })
        // A non-compiling C reference.
        let c = try rig.qs.create(courseId: rig.course.id, spec: spec(language: "c", reference: "int main( {"), skillIds: [rig.skillA.id])
        if case .compileError = try await v.verify(questionId: c.id, runner: runner) {} else { Issue.record("expected compile error") }
        #expect(try rig.qs.detail(c.id).question.readiness == .needsReview)
        // Unavailable runner changes nothing.
        let before = try rig.qs.detail(q.id).question
        await #expect(throws: EvaluationError.self) { try await v.verify(questionId: q.id, runner: UnavailableCodeRunner()) }
        #expect(try rig.qs.detail(q.id).question == before)
        // Not a test-graded question.
        let sa = try rig.shortAnswer("plain", skill: rig.skillA)
        await #expect(throws: EvaluationError.notCodeTests) { try await v.verify(questionId: sa.id, runner: runner) }
    }

    @Test func attemptsAreGradedByRunningTests() async throws {
        let rig = try Rig()
        let q = try rig.qs.create(courseId: rig.course.id, spec: spec(reference: Self.goodPy), skillIds: [rig.skillA.id])
        try await CodeVerificationService(db: rig.db).verify(questionId: q.id, runner: runner)

        let right = try attempt(rig, q, code: Self.goodPy)
        let pending = try rig.eval.evaluate(attemptId: right.id)
        #expect(pending.evaluation.state == .pending)                                      // the sync path leaves it for the runner
        let r = try await rig.eval.evaluateCode(attemptId: right.id, runner: runner)
        #expect(r.evaluation.state == .graded && r.evaluation.score == 1 && r.evaluation.trust == .trusted && r.evaluation.feedback == "3 of 3 tests passed.")
        #expect(r.xp == XPRules.participation(difficulty: 3, attemptNumber: 1) + XPRules.correctness(difficulty: 3))
        #expect(r.evaluation.detail.contains("hidden big") && !r.evaluation.detail.contains("16"))   // stored detail never leaks hidden expectations
        // Idempotent: a second call returns the same grade.
        #expect(try await rig.eval.evaluateCode(attemptId: right.id, runner: runner).evaluation.id == r.evaluation.id)
        #expect(try rig.eval.history(attemptId: right.id).map(\.state) == [.pending, .graded])
        let ev = try rig.prog.evidence(skillId: rig.skillA.id)
        #expect(ev.count == 1 && ev[0].dimension == .application && ev[0].score == 1)

        let half = try attempt(rig, q, code: "n = int(input())\nfor i in range(n):\n    print(i * i if i < 2 else 0)")
        let h = try await rig.eval.evaluateCode(attemptId: half.id, runner: runner)
        let third: Double = 1.0 / 3.0
        #expect(abs((h.evaluation.score ?? 0) - third) < 1e-9, Comment(rawValue: h.evaluation.feedback))     // only the n=1 test passes
        #expect(h.evaluation.state == .graded && !h.evaluation.isCorrect)

        let broken = try attempt(rig, q, code: "print(")
        let b = try await rig.eval.evaluateCode(attemptId: broken.id, runner: runner)
        #expect(b.evaluation.score == 0 && b.evaluation.state == .graded)                    // a Python syntax error fails every test

        let cq = try rig.qs.create(courseId: rig.course.id, spec: spec(language: "c", reference: "#include <stdio.h>\nint main(void){int n; scanf(\"%d\",&n); for(int i=0;i<n;i++) printf(\"%d\\n\", i*i); return 0;}"), skillIds: [rig.skillA.id])
        let nc = try attempt(rig, cq, code: "int main( {", lang: "c")
        let c = try await rig.eval.evaluateCode(attemptId: nc.id, runner: runner)
        #expect(c.evaluation.score == 0 && c.evaluation.feedback.hasPrefix("It didn’t compile"))

        // Regrading never replaces a test grade with "pending".
        _ = try rig.eval.regrade(attemptId: right.id)
        #expect(try rig.eval.result(attemptId: right.id)?.evaluation.state == .graded)
        #expect(try rig.eval.regradeQuestion(questionId: q.id) >= 0 && (try rig.eval.result(attemptId: right.id))?.evaluation.score == 1)
        await #expect(throws: EvaluationError.notCodeTests) { try await rig.eval.evaluateCode(attemptId: try rig.attempt(try rig.shortAnswer("x", skill: rig.skillA), text: "hasNext").id, runner: runner) }
    }

    @Test func aToolingProblemIsNeverAWrongAnswer() async throws {
        let rig = try Rig()
        let q = try rig.qs.create(courseId: rig.course.id, spec: spec(reference: Self.goodPy), skillIds: [rig.skillA.id])
        let a = try attempt(rig, q, code: Self.goodPy)
        _ = try rig.eval.evaluate(attemptId: a.id)
        await #expect(throws: EvaluationError.self) { try await rig.eval.evaluateCode(attemptId: a.id, runner: UnavailableCodeRunner()) }
        let after = try #require(try rig.eval.result(attemptId: a.id))
        #expect(after.evaluation.state == .pending && after.evaluation.score == nil)          // still pending, not 0
        #expect(try rig.prog.evidence(skillId: rig.skillA.id).isEmpty && (try rig.prog.mastery(skillId: rig.skillA.id)).isUnknown)
        // Unverified question → provisional grade and no correctness bonus.
        let r = try await rig.eval.evaluateCode(attemptId: a.id, runner: runner)
        #expect(r.evaluation.trust == .provisional && r.evaluation.score == 1)
        #expect(r.xp == XPRules.participation(difficulty: 3, attemptNumber: 1))
    }

    @Test func javaQuestionsWorkEndToEnd() async throws {
        let rig = try Rig()
        let ref = "import java.util.*; public class Main { public static void main(String[] a){ Scanner s=new Scanner(System.in); int n=s.nextInt(); for(int i=0;i<n;i++) System.out.println(i*i); } }"
        let q = try rig.qs.create(courseId: rig.course.id, spec: spec(language: "java", reference: ref), skillIds: [rig.skillA.id])
        #expect(try await CodeVerificationService(db: rig.db).verify(questionId: q.id, runner: runner) == .verified)
        let a = try attempt(rig, q, code: ref, lang: "java")
        #expect(try await rig.eval.evaluateCode(attemptId: a.id, runner: runner).evaluation.score == 1)
    }
}

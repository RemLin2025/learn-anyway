import Testing
import Foundation
@testable import BraincellCore

@Suite struct SymbolicMathTests {
    func same(_ a: String, _ b: String) -> Bool { SymbolicMath.compare(key: a, answer: b) == .equal }
    func differs(_ a: String, _ b: String) -> Bool { SymbolicMath.compare(key: a, answer: b) == .notEqual }

    @Test func expansionAndFactoring() {
        #expect(same("(x+1)^2", "x^2+2x+1"))
        #expect(same("x^2-1", "(x-1)(x+1)"))
        #expect(same("(a+b)^3", "a^3+3a^2b+3ab^2+b^3"))
        #expect(same("2(x+3)", "2x+6"))
        #expect(same("x(x+1)", "x*x + x"))
        #expect(same("-(x-y)", "y-x"))
        #expect(same("x**2", "x^2"))
    }

    @Test func notEqualDetected() {
        #expect(differs("(x+1)^2", "x^2+1"))
        #expect(differs("x^2-1", "(x-1)^2"))
        #expect(differs("x+y", "x+z"))
        #expect(differs("2x", "x^2"))
        #expect(differs("1/3", "0.33"))
    }

    @Test func rationalFunctionsAndNumbers() {
        #expect(same("(x^2-1)/(x-1)", "x+1"))
        #expect(same("1/2 + 1/3", "5/6"))
        #expect(same("0.5x", "x/2"))
        #expect(same("1/(x+1) + 1/(x-1)", "2x/(x^2-1)"))
        #expect(same("x^-1", "1/x"))
        #expect(same("(x+1)^-2", "1/(x^2+2x+1)"))
        #expect(differs("1/x", "1/(x+1)"))
    }

    @Test func notationVariants() {
        #expect(same("2x", "2·x"))
        #expect(same("xy", "x*y"))
        #expect(same("3−x", "3-x"))
        #expect(same("x ^ 2", "x^2"))
        #expect(same("(x)(x)", "x^2"))
        #expect(same("x^2", "$\\frac{x^{3}}{x}$"))
        #expect(same("\\frac{1}{2}x", "x/2"))
    }

    @Test func unsupportedIsNotWrong() {
        for bad in ["sin(x)", "sqrt(x)", "pi*x", "x^0.5", "x^(1/2)", "|x|", "x!", "x=1"] {
            let r = SymbolicMath.compare(key: "x", answer: bad)
            #expect(r != .equal && r != .notEqual, "\(bad) should be unsupported/unreadable, got \(r)")
        }
    }

    @Test func malformedIsUnreadable() {
        for bad in ["", "(", "x+", "2x)", "x^", "*3", "1/0", "3..4", String(repeating: "(", count: 100)] {
            let r = SymbolicMath.compare(key: "x", answer: bad)
            #expect(r != .equal && r != .notEqual, "\(bad.prefix(10)) should not be graded, got \(r)")
        }
    }

    @Test func hugeInputsAreBoundedNotCrashing() {
        #expect(SymbolicMath.compare(key: "x", answer: "(x+1)^24*(x+2)^24*(x+3)^24") != .equal)
        _ = SymbolicMath.compare(key: "x", answer: "(a+b+c+d+e+f)^24")          // must return, not trap
        _ = SymbolicMath.compare(key: "x", answer: "99999999999999*99999999999999*x")
        _ = SymbolicMath.compare(key: "x", answer: String(repeating: "x+", count: 250) + "1")
        #expect(SymbolicMath.compare(key: "x", answer: String(repeating: "x", count: 700)) != .equal)
    }

    @Test func zeroPolynomialsCompareEqual() {
        #expect(same("0", "x-x"))
        #expect(same("(x+1)^2-(x-1)^2", "4x"))
    }

    // MARK: Through the validator and evaluator

    func question(_ expr: String) -> QuestionSpec? {
        QuestionValidator.validate(entry: Fx.base("short_answer", title: "Expand", answer: ["expression": expr], method: "symbolic"), index: 0).question?.spec
    }
    func grade(_ spec: QuestionSpec, _ text: String) -> EvaluationOutcome {
        var r = PracticeResponse(); r.text = text
        return Evaluator.evaluate(spec: spec, response: r, answerKeyVerified: false)
    }

    @Test func validatorAcceptsAndRejectsKeys() {
        #expect(question("x^2+2x+1") != nil)
        #expect(question("sin(x)") == nil)
        #expect(question("x+") == nil)
        let missing = QuestionValidator.validate(entry: Fx.base("short_answer", title: "T", answer: ["accepted": ["x"]], method: "symbolic"), index: 0)
        #expect(missing.hasBlocking)
        // symbolic is not offered for other question types
        #expect(QuestionValidator.validate(entry: Fx.base("numeric", title: "N", answer: ["value": 1.0], method: "symbolic"), index: 0).hasBlocking)
    }

    @Test func gradingOutcomes() throws {
        let s = try #require(question("(x+1)^2"))
        let ok = grade(s, "x^2 + 2x + 1")
        #expect(ok.state == .graded && ok.score == 1 && ok.trust == .provisional)
        let bad = grade(s, "x^2 + 1")
        #expect(bad.state == .graded && bad.score == 0)
        #expect(grade(s, "").score == 0)
        // checker limits go to review, with no score
        let unsupported = grade(s, "sqrt(x)")
        #expect(unsupported.state == .needsReview && unsupported.score == nil)
        let garbage = grade(s, "x +* 2")
        #expect(garbage.state == .needsReview && garbage.score == nil)
    }
}

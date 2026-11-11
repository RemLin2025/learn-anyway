import Testing
import Foundation
@testable import BraincellCore

@Suite struct CalculatorTests {
    func v(_ s: String, deg: Bool = false, ans: Double = 0) -> Double? { if case .success(let x) = Calculator.evaluate(s, degrees: deg, ans: ans) { x } else { nil } }

    @Test func arithmeticPrecedenceAndAssociativity() {
        #expect(v("2+3*4") == 14 && v("(2+3)*4") == 20 && v("2^3^2") == 512 && v("-2^2") == -4 && v("10/4") == 2.5)
        #expect(v("0.3*(1-0.3)^3") .map { abs($0 - 0.1029) < 1e-12 } == true)                 // P(T=4) for p = 0.3, the geometric example
        #expect(v("2×3÷4−1") == 0.5 && v("50%") == 0.5)
    }
    @Test func scientificFunctionsConstantsAndAngleMode() {
        #expect(abs(v("sin(30)", deg: true)! - 0.5) < 1e-12 && abs(v("sin(pi/6)")! - 0.5) < 1e-12)
        #expect(abs(v("ln(e)")! - 1) < 1e-12 && v("log(1000)") == 3 && v("sqrt(16)") == 4 && v("5!") == 120 && v("0!") == 1)
        #expect(abs(v("acos(0)", deg: true)! - 90) < 1e-9 && v("2*ans", ans: 21) == 42 && abs(v("exp(1)")! - M_E) < 1e-12)
        #expect(abs(v("1.5e-3*2")! - 0.003) < 1e-15)
    }
    @Test func errorsAreReportedNeverGuessed() {
        for bad in ["1/0", "sqrt(-1)", "ln(0)", "(-1)!", "2.5!", "2+", "(1+2", "foo(1)", "2 3", "1+*2", "tan(90)"] {
            if bad == "tan(90)" { if case .success = Calculator.evaluate(bad, degrees: true) { Issue.record("tan(90°) must fail") }; continue }
            if case .success(let x) = Calculator.evaluate(bad) { Issue.record("\(bad) should fail, got \(x)") }
        }
        if case .success = Calculator.evaluate(String(repeating: "(", count: 500) + "1" + String(repeating: ")", count: 500)) { Issue.record("deep nesting must be refused, not overflow") }
        #expect(Calculator.format(0.1029) == "0.1029" && Calculator.format(1e12) == "1.000000e+12" && Calculator.format(100) == "100" && Calculator.format(1.0 / 3.0) == "0.3333333333")
    }
    @Test func probabilityOperatorRendersAsP() throws {
        #expect(Latex.unicode("\\Pr(T=4)") == "P(T=4)")
        guard case .row = try Latex.parse("\\Pr(T=4)") else { Issue.record("expected a row"); return }
    }
}

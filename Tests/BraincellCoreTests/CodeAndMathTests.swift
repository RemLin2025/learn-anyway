import Testing
import Foundation
@testable import BraincellCore

@Suite struct CodeToolsTests {
    func kinds(_ s: String, _ l: CodeLanguage) -> [(String, TokenKind)] {
        let u = Array(s.utf16)
        return SyntaxHighlighter.tokens(s, language: l).map { (String(utf16CodeUnits: Array(u[$0.location..<$0.location + $0.length]), count: $0.length), $0.kind) }
    }

    @Test func pythonTokens() {
        let t = kinds("def f(x):  # note\n    s = \"if\"\n    return \"\"\"multi\nline\"\"\" + 42", .python)
        #expect(t.contains { $0 == ("def", .keyword) } && t.contains { $0 == ("return", .keyword) })
        #expect(t.contains { $0 == ("# note", .comment) })
        #expect(t.contains { $0 == ("\"if\"", .string) })
        #expect(t.contains { $0 == ("\"\"\"multi\nline\"\"\"", .string) })
        #expect(t.contains { $0 == ("42", .number) })
        #expect(!t.contains { $0 == ("if", .keyword) }) // keyword inside a string is not highlighted
    }

    @Test func cTokens() {
        let t = kinds("#include <stdio.h>\nint main() { /* c */ char *s = \"a\\\"b\"; // end\n return 0x1F; }", .c)
        #expect(t.contains { $0 == ("#include <stdio.h>", .preprocessor) })
        #expect(t.contains { $0 == ("int", .keyword) } && t.contains { $0 == ("char", .keyword) })
        #expect(t.contains { $0 == ("/* c */", .comment) } && t.contains { $0 == ("// end", .comment) })
        #expect(t.contains { $0 == ("\"a\\\"b\"", .string) })
        #expect(t.contains { $0 == ("0x1F", .number) })
    }

    @Test func javaTokensAndUnterminated() {
        let t = kinds("public class A { char c = 'x'; String s = \"oops\n int y; }", .java)
        #expect(t.contains { $0 == ("public", .keyword) } && t.contains { $0 == ("class", .keyword) })
        #expect(t.contains { $0 == ("'x'", .string) })
        #expect(t.contains { $0 == ("\"oops", .string) }) // stops at end of line
        #expect(t.contains { $0 == ("int", .keyword) })   // ...so later code still highlights
        #expect(SyntaxHighlighter.tokens("/* never closed", language: .c).count == 1)
        #expect(SyntaxHighlighter.tokens("", language: .python).isEmpty)
    }

    @Test func autoIndent() {
        let py = "def f(x):"
        #expect(AutoIndent.newline(in: py, caret: py.utf16.count, language: .python).insert == "\n    ")
        let nested = "if x:\n    y = 1"
        #expect(AutoIndent.newline(in: nested, caret: nested.utf16.count, language: .python).insert == "\n    ")
        let c = "int main() {"
        #expect(AutoIndent.newline(in: c, caret: c.utf16.count, language: .c).insert == "\n    ")
        let braces = "void f() {}"
        let r = AutoIndent.newline(in: braces, caret: braces.utf16.count - 1, language: .java)
        #expect(r.insert == "\n    \n" && r.caretOffset == 5)              // caret on the indented middle line
        let indented = "    int x = 1;"
        #expect(AutoIndent.newline(in: indented, caret: indented.utf16.count, language: .c).insert == "\n    ")
        #expect(AutoIndent.newline(in: "", caret: 0, language: .python).insert == "\n")
    }

    @Test func bracketMatching() {
        let s = "f(a[1], {b})"
        #expect(BracketMatcher.match(in: s, caret: 2, language: .python).map { [$0.0, $0.1] } == [1, 11])  // after "("
        #expect(BracketMatcher.match(in: s, caret: 12, language: .python).map { [$0.0, $0.1] } == [1, 11]) // after ")"
        let str = "f(\")\", x)"
        #expect(BracketMatcher.match(in: str, caret: 2, language: .python).map { [$0.0, $0.1] } == [1, 8]) // ")" in string ignored
        #expect(BracketMatcher.match(in: "(()", caret: 1, language: .c).map { [$0.0, $0.1] } == [1, 2]) // pair at the caret wins
        #expect(BracketMatcher.match(in: "(", caret: 1, language: .c) == nil)                       // unmatched
        #expect(BracketMatcher.match(in: "abc", caret: 1, language: .c) == nil)
    }
}

@Suite struct MathTests {
    @Test func parsesCommonStructures() throws {
        #expect(try Latex.parse("x^2") == .sup(.symbol("x"), .symbol("2")))
        #expect(try Latex.parse("\\frac{a}{b}") == .frac(.symbol("a"), .symbol("b")))
        #expect(try Latex.parse("\\sqrt[3]{x}") == .sqrt(.symbol("x"), index: .symbol("3")))
        #expect(try Latex.parse("\\sum_{k=1}^{n} k") == .row([.bigOp("∑", lower: .row([.symbol("k"), .symbol("="), .symbol("1")]), upper: .symbol("n")), .space, .symbol("k")]))
        #expect(try Latex.parse("a_i^2") == .supsub(.symbol("a"), sub: .symbol("i"), sup: .symbol("2")))
        #expect(try Latex.parse("\\left( x \\right)") == .delimited("(", .row([.space, .symbol("x"), .space]), ")"))
    }

    @Test func unicodeApproximation() {
        #expect(Latex.unicode("\\sum_{k=1}^{n}(2k-1)=n^2") == "∑ₖ₌₁ⁿ(2k−1)=n²")
        #expect(Latex.unicode("\\frac{a+b}{2}") == "(a+b)/2")
        #expect(Latex.unicode("\\frac{1}{2}") == "1/2")
        #expect(Latex.unicode("\\sqrt{x+1}") == "√(x+1)")
        #expect(Latex.unicode("\\alpha \\le \\beta") == "α ≤ β")
        #expect(Latex.unicode("x^{n+1}") == "xⁿ⁺¹")                       // every char has a superscript form
        #expect(Latex.unicode("x^{a+b+z}") == "x^(a+b+z)")                  // 'z' doesn't → explicit form
        #expect(Latex.unicode("e^{i\\pi}+1=0") == "e^(iπ)+1=0")
        #expect(Latex.unicode("\\int_0^1 x\\,dx") == "∫₀¹ x dx")
        #expect(Latex.unicode("\\text{if } x \\ne 0") == "if  x ≠ 0")
    }

    @Test func unsupportedOrBrokenFallsBack() {
        #expect(Latex.unicode("\\begin{array} a \\end{array}") == nil)
        #expect(Latex.unicode("\\unknowncmd{x}") == nil)
        #expect(Latex.unicode("{x") == nil)
        #expect(Latex.unicode("x}") == nil)
        #expect(Latex.unicode(String(repeating: "a", count: 6_000)) == nil)
        #expect(Latex.unicode(String(repeating: "{", count: 60) + "x" + String(repeating: "}", count: 60)) == nil)
    }

    @Test func inlineMathInRunningText() {
        #expect(Latex.inlineConverted("Let $x^2$ be positive and $\\alpha \\ge 0$.") == "Let x² be positive and α ≥ 0.")
        #expect(Latex.inlineConverted("It costs $5 and then $6.") == "It costs $5 and then $6.")       // currency untouched
        #expect(Latex.inlineConverted("Escaped \\$ stays") == "Escaped $ stays")
        #expect(Latex.inlineConverted("Odd $\\weird$ span") == "Odd $\\weird$ span")                      // unsupported stays as written
        #expect(Latex.inlineConverted("no math here") == "no math here")
    }
}

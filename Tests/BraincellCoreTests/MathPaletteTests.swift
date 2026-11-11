import Testing
import Foundation
@testable import BraincellCore

@Suite struct MathPaletteTests {
    func item(_ name: String) -> MathPalette.Item { MathPalette.search(name).first! }

    @Test func insertsAtTheCaretNotTheEnd() {
        let e = MathPalette.insert("\\alpha ", into: "x + y", selection: NSRange(location: 2, length: 0))
        #expect(e.text == "x \\alpha + y" && e.selection == NSRange(location: 9, length: 0))
    }
    @Test func selectionIsReplacedAndFillsTheFirstSlot() {
        let r = MathPalette.insert("\\pm ", into: "a b c", selection: NSRange(location: 2, length: 1))
        #expect(r.text == "a \\pm  c")
        let f = MathPalette.insert("\\frac{▢}{▢}", into: "x/y", selection: NSRange(location: 0, length: 1))
        #expect(f.text == "\\frac{x}{▢}/y" && (f.text as NSString).substring(with: f.selection) == "▢")       // selected text became the numerator
    }
    @Test func templatesSelectTheFirstPlaceholderAndTabWalksThem() throws {
        var e = MathPalette.insert(item("definite integral").latex, into: "", selection: NSRange(location: 0, length: 0))
        #expect((e.text as NSString).substring(with: e.selection) == "▢" && e.selection.location == (e.text as NSString).range(of: "▢").location)
        var seen = 0, from = 0
        while let r = MathPalette.nextPlaceholder(in: e.text, after: from), seen < 4 { seen += 1; from = NSMaxRange(r); e.text = (e.text as NSString).replacingCharacters(in: r, with: seen == 1 ? "0" : seen == 2 ? "1" : seen == 3 ? "x^2" : "x"); from = r.location + 1 }
        #expect(seen == 4 && !MathPalette.hasPlaceholders(e.text) && e.text.contains("\\int_{0}^{1} x^2 \\, dx"))
    }
    @Test func wrapAddsDollarsForProseAnswers() {
        #expect(MathPalette.insert("\\sigma ", into: "so ", selection: NSRange(location: 3, length: 0), wrap: true).text == "so $\\sigma $")
    }
    @Test func requiredTemplatesExistAndAreRenderable() throws {
        for n in ["fraction", "exponent", "subscript", "square root", "nth root", "definite integral", "integral", "summation", "limit", "matrix 2x2", "piecewise", "parentheses"] {
            let it = try #require(MathPalette.search(n).first, "missing \(n)")
            #expect(it.isTemplate)
            #expect((try? Latex.parse(it.latex)) != nil, "\(n) must render: \(it.latex)")
        }
        let titles = MathPalette.categories.map(\.title)
        #expect(["Greek", "Calculus", "Linear algebra", "Sets & logic", "Probability"].allSatisfy(titles.contains))
        #expect(MathPalette.search("sigma").contains { $0.label == "σ" } && MathPalette.search("zzzz").isEmpty)
    }
    @Test func everyCatalogItemParses() {
        for it in MathPalette.categories.flatMap(\.items) { #expect((try? Latex.parse(it.latex)) != nil, "\(it.label): \(it.latex)") }
    }
    @Test func matricesAndAccentsParseAndStayEditableAsSource() throws {
        let src = "\\begin{pmatrix} a & b \\\\ c & d \\end{pmatrix}"
        guard case .matrix(let rows, let l, let r) = try Latex.parse(src) else { Issue.record("not a matrix"); return }
        #expect(rows.count == 2 && rows[0].count == 2 && l == "(" && r == ")")
        #expect(Latex.unicode("\\bar{x}") != nil && Latex.unicode("\\begin{bogus} a \\end{bogus}") == nil)
        #expect(Latex.unicode("\\begin{cases} 1 & x>0 \\\\ 0 & x\\le 0 \\end{cases}") != nil)
    }
    @Test func unfilledPlaceholdersAreNeverGradedAsAnAnswer() {
        #expect(SymbolicMath.fromLatex("\\frac{▢}{2}").map { SymbolicMath.compare(key: "1/2", answer: $0) } != .equal)
        #expect(SymbolicMath.compare(key: "(x+1)^2", answer: SymbolicMath.fromLatex("x^{2}+2x+1")!) == .equal)           // equivalent notation is accepted
    }
}

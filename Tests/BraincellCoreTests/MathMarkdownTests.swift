import Testing
import Foundation
@testable import BraincellCore

@Suite struct MathMarkdownTests {
    func text(_ i: [MathInline]) -> String { i.map { if case .text(let s) = $0 { s } else if case .math(let m) = $0 { "⟦\(m)⟧" } else { "" } }.joined() }

    @Test func inlineAndDisplayDelimitersAreAllRecognised() {
        let b = MathMarkdown.parse("Suppose \\(X\\) and $Y$ have finite variances.\n\\[U=\\frac{X-\\mathbb{E}[X]}{\\sigma_X}\\]\nThen $$V=1$$ holds.")
        #expect(b.count == 5)
        if case .paragraph(let p) = b[0] { #expect(text(p) == "Suppose ⟦X⟧ and ⟦Y⟧ have finite variances.") } else { Issue.record("para") }
        #expect(b[1] == .display("U=\\frac{X-\\mathbb{E}[X]}{\\sigma_X}", boxed: true))
        #expect(b[2] == .paragraph([.text("Then ")]) && b[3] == .display("V=1", boxed: false) && b[4] == .paragraph([.text(" holds.")]))
    }
    @Test func currencyAndEscapedDollarsAreNotMath() {
        let b = MathMarkdown.parse("It costs $5 and $6, or \\$x\\$ literally, but $x$ is math.")
        guard case .paragraph(let p) = b[0] else { Issue.record("para"); return }
        #expect(text(p) == "It costs $5 and $6, or $x$ literally, but ⟦x⟧ is math.")
    }
    @Test func partsListsHeadingsAndCodeAreStructured() {
        let src = "# Setup\nLet \\(X\\) be a variable.\n\n**Part A.** Show that \\(a=b\\).\n(b) Find the limit.\n\n- one\n- two\n1. first\n\n```python\nprint(1)\n```"
        let b = MathMarkdown.parse(src)
        #expect(b.contains { if case .heading = $0 { true } else { false } })
        let labels = b.compactMap { if case .part(let l, _) = $0 { l } else { nil } }
        #expect(labels == ["Part A", "(b)"])
        #expect(b.contains(.list(ordered: false, items: [[.text("one")], [.text("two")]])))
        #expect(b.contains(.list(ordered: true, items: [[.text("first")]])))
        #expect(b.last == .code(language: "python", text: "print(1)"))
    }
    @Test func equationEnvironmentsAndMultilineDisplayAreDisplayBlocks() {
        let b = MathMarkdown.parse("Derive:\n\\begin{aligned} a &= b \\\\ c &= d \\end{aligned}\n\\[\nx^2\n\\]")
        #expect(b.contains { if case .display(let l, _) = $0 { l.hasPrefix("\\begin{aligned}") } else { false } })
        #expect(b.contains(.display("x^2", boxed: false)))
        #expect((try? Latex.parse("\\begin{aligned} a &= b \\\\ c &= d \\end{aligned}")) != nil)
    }
    @Test func malformedMathDegradesToLiteralTextWithoutCrashing() {
        for s in ["\\(x", "\\[ never closed", "$$ open", "a $ b", "\\begin{aligned} no end", "}{ \\frac", "\\(\\)", "```\nunterminated", "\\(\\unknown{x}\\)", String(repeating: "\\(", count: 500)] {
            _ = MathMarkdown.parse(s); _ = MathMarkdown.normalize(s); _ = MathMarkdown.issues(s); _ = MathMarkdown.legacyUpgrade(s)
        }
        #expect(MathMarkdown.issues("\\(x").contains { $0.contains("Unbalanced") })
        #expect(MathMarkdown.parse("\\[ never closed") == [.paragraph([.text("\\[ never closed")])])
    }
    @Test func normalizeConvertsDelimitersWithoutTouchingFormulasOrCode() {
        let src = "Let $X_1$ and $$\\frac{a}{b}$$.\n```\n$keep$ \\(this\\)\n```\nCost $5."
        let n = MathMarkdown.normalize(src)
        #expect(n == "Let \\(X_1\\) and \\[\\frac{a}{b}\\].\n```\n$keep$ \\(this\\)\n```\nCost \\$5.")
        #expect(MathMarkdown.normalize(n) == n)                                                       // idempotent
        #expect(MathMarkdown.parse(n) == MathMarkdown.parse(src).map { $0 })                          // same structure either way
    }
    @Test func untrustedMarkupIsFlaggedAndNeverInterpreted() {
        #expect(MathMarkdown.issues("<script>alert(1)</script>").contains { $0.contains("HTML") })
        #expect(MathMarkdown.issues("[x](javascript:alert(1))").contains { $0.contains("HTML") })
        #expect(MathMarkdown.issues("Fine \\(x\\) and \\[y\\]").isEmpty)
    }
    @Test func legacyPlainTextFormulasAreWrappedOnlyWhenUnambiguous() {
        #expect(MathMarkdown.legacyUpgrade("Suppose X and Y have finite variances.\nU=(X-E[X])/σ_X") == "Suppose X and Y have finite variances.\n\\[U=(X-E[X])/\\sigma_X\\]")
        #expect(MathMarkdown.legacyUpgrade("Let x = 3 apples") == nil)                                  // prose with an equals sign
        #expect(MathMarkdown.legacyUpgrade("Already \\(x=1\\)") == nil && MathMarkdown.legacyUpgrade("price is $5 = five") == nil)
        #expect(MathMarkdown.legacyUpgrade("No formulas here.") == nil)
    }
    @Test func displayBoxesAreSelective() {
        #expect(!MathMarkdown.shouldBox("x^2") && !MathMarkdown.shouldBox("a=b"))
        #expect(MathMarkdown.shouldBox("\\begin{pmatrix}1&2\\\\3&4\\end{pmatrix}") && MathMarkdown.shouldBox("E[X]=\\sum_{k}k\\,p(k)"))
    }
    @Test func requiredNotationRenders() {
        for l in ["\\frac{a}{b}", "\\sum_{i=1}^{n} x_i^2", "\\int_0^1 f(x)\\,dx", "x^{2}_{i}", "\\alpha+\\beta", "\\begin{pmatrix}1&2\\\\3&4\\end{pmatrix}", "\\mathbb{E}[X]", "\\binom{n}{k}", "\\sum\\limits_{k=0}^{n}k", "\\bigl(x\\bigr)", "\\operatorname{Var}(X)", "\\sqrt[3]{x}"] {
            #expect((try? Latex.parse(l)) != nil, "\(l)")
        }
    }
}

extension AgentTests {
    @Test func jsonWithSingleBackslashLatexIsRepairedNotMangled() throws {
        let raw = #"{"schemaVersion":"x","t":"Let \(X\) and \[\frac{a}{b}\] with \beta, \theta, \rho"}"#
        let o = try #require(AITaskService.parse(raw) as? [String: Any])
        #expect(o["t"] as? String == #"Let \(X\) and \[\frac{a}{b}\] with \beta, \theta, \rho"#)
        let good = #"{"t":"line1\nline2 \\frac{a}{b} \"q\""}"#
        #expect((AITaskService.parse(good) as? [String: Any])?["t"] as? String == "line1\nline2 \\frac{a}{b} \"q\"")   // valid JSON is untouched
    }
    @Test func importedQuestionsGetNormalizedMathAndAReviewNoteWhenMalformed() throws {
        func q(_ text: String) -> [String: Any] { Fx.base("short_answer", title: "T", answer: ["accepted": ["x"], "caseSensitive": false], method: "exact", extra: ["content": [Fx.md(text)]]) }
        let ok = QuestionValidator.validate(entry: q("Let $X$ and $$\\frac{a}{b}$$."), index: 0)
        #expect(ok.question?.spec.content.first?.text == "Let \\(X\\) and \\[\\frac{a}{b}\\].")
        let bad = QuestionValidator.validate(entry: q("Broken \\(x"), index: 0)
        #expect(bad.issues.contains { $0.severity == .review && $0.message.contains("Unbalanced") } && bad.question?.spec.content.first?.text == "Broken \\(x")   // kept as written
    }
    @Test func promptAsksForStructuredMathMarkdown() throws {
        let db = try AppDatabase.inMemory(); let c = try CourseService(db: db).createCourse(name: "S"); let ai = AITaskService(db: db)
        let t = try ai.createGenerationTask(courseId: c.id, params: GenerationParams(count: 1))
        let p = try ai.prepare(batchId: try ai.batches(taskId: t.id)[0].id).singlePrompt
        #expect(p.contains("\\[ ... \\]") && p.contains("**Part A.**") && p.contains("fenced code") && p.contains("backslash must be written twice"))
        #expect(ResponseSchema.json.contains("**Part A.**"))
    }
}

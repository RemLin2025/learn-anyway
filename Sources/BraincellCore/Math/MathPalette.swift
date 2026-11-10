import Foundation

/// The symbol/template catalog behind the Insert Math palette, and the pure text logic for inserting into an answer.
/// Answers are stored as LaTeX source (editable later, not images). A template contains ▢ placeholders; inserting selects the first one
/// and Tab moves to the next, so the learner fills the structure in place.
public enum MathPalette {
    public static let placeholder = "▢"

    public struct Item: Sendable, Equatable, Identifiable {
        public let label: String        // what the button shows
        public let latex: String        // what is inserted
        public let name: String         // searchable words
        public var id: String { latex }
        public var isTemplate: Bool { latex.contains(MathPalette.placeholder) }
    }
    public struct Category: Sendable, Equatable, Identifiable { public let title: String; public let items: [Item]; public var id: String { title } }

    static func i(_ label: String, _ latex: String, _ name: String = "") -> Item { Item(label: label, latex: latex, name: name.isEmpty ? label : name) }
    static func p(_ n: Int) -> String { String(repeating: placeholder, count: n) }

    public static let categories: [Category] = [
        Category(title: "Templates", items: [
            i("a⁄b", "\\frac{▢}{▢}", "fraction"), i("xⁿ", "▢^{▢}", "exponent power superscript"), i("xₙ", "▢_{▢}", "subscript index"), i("√x", "\\sqrt{▢}", "square root"),
            i("ⁿ√x", "\\sqrt[▢]{▢}", "nth root"), i("(▢)", "\\left(▢\\right)", "parentheses brackets"), i("∫", "\\int ▢ \\, d▢", "integral"), i("∫ₐᵇ", "\\int_{▢}^{▢} ▢ \\, d▢", "definite integral bounds"),
            i("∑", "\\sum_{▢=▢}^{▢} ▢", "summation sum index"), i("∏", "\\prod_{▢=▢}^{▢} ▢", "product"), i("lim", "\\lim_{▢ \\to ▢} ▢", "limit"),
            i("2×2", "\\begin{pmatrix} ▢ & ▢ \\\\ ▢ & ▢ \\end{pmatrix}", "matrix 2x2"), i("3×3", "\\begin{pmatrix} ▢ & ▢ & ▢ \\\\ ▢ & ▢ & ▢ \\\\ ▢ & ▢ & ▢ \\end{pmatrix}", "matrix 3x3"),
            i("|A|", "\\begin{vmatrix} ▢ & ▢ \\\\ ▢ & ▢ \\end{vmatrix}", "determinant"), i("{ cases", "\\begin{cases} ▢ & ▢ \\\\ ▢ & ▢ \\end{cases}", "piecewise cases"),
        ]),
        Category(title: "Basic", items: ["+", "−", "×", "÷", "±", "=", "≠", "≈", "·"].map { i($0, $0 == "−" ? "-" : $0 == "×" ? "\\times " : $0 == "÷" ? "\\div " : $0 == "±" ? "\\pm " : $0 == "≠" ? "\\neq " : $0 == "≈" ? "\\approx " : $0 == "·" ? "\\cdot " : $0, $0 == "−" ? "minus" : $0) }),
        Category(title: "Compare", items: [i("<", "<"), i(">", ">"), i("≤", "\\le ", "less equal"), i("≥", "\\ge ", "greater equal"), i("≪", "\\ll "), i("≫", "\\gg "), i("∼", "\\sim ", "distributed as tilde"), i("∝", "\\propto ")]),
        Category(title: "Greek", items: [("α", "alpha"), ("β", "beta"), ("γ", "gamma"), ("δ", "delta"), ("ε", "epsilon"), ("θ", "theta"), ("λ", "lambda"), ("μ", "mu"), ("π", "pi"), ("ρ", "rho"), ("σ", "sigma"), ("τ", "tau"), ("φ", "phi"), ("χ", "chi"), ("ψ", "psi"), ("ω", "omega"), ("Δ", "Delta"), ("Σ", "Sigma"), ("Φ", "Phi"), ("Ω", "Omega")].map { i($0.0, "\\\($0.1) ", $0.1) }),
        Category(title: "Calculus", items: [i("∫", "\\int ", "integral"), i("∮", "\\oint "), i("∂", "\\partial ", "partial derivative"), i("∇", "\\nabla ", "gradient nabla"), i("∞", "\\infty ", "infinity"), i("lim", "\\lim "), i("d/dx", "\\frac{d▢}{d▢}", "derivative"), i("∂/∂x", "\\frac{\\partial ▢}{\\partial ▢}", "partial derivative")]),
        Category(title: "Sums", items: [i("∑", "\\sum ", "sum"), i("∏", "\\prod ", "product"), i("⋃", "\\bigcup "), i("⋂", "\\bigcap ")]),
        Category(title: "Powers & roots", items: [i("x²", "▢^{2}", "square"), i("x³", "▢^{3}", "cube"), i("xⁿ", "▢^{▢}", "power"), i("x⁻¹", "▢^{-1}", "inverse"), i("√", "\\sqrt{▢}", "root"), i("ⁿ√", "\\sqrt[▢]{▢}", "nth root"), i("eˣ", "e^{▢}", "exponential"), i("ln", "\\ln "), i("log", "\\log ")]),
        Category(title: "Linear algebra", items: [i("v⃗", "\\vec{▢}", "vector"), i("Aᵀ", "▢^{T}", "transpose"), i("A⁻¹", "▢^{-1}", "inverse matrix"), i("det", "\\det "), i("u·v", "▢ \\cdot ▢", "dot product"), i("‖v‖", "\\left\\|▢\\right\\|", "norm"), i("2×2", "\\begin{pmatrix} ▢ & ▢ \\\\ ▢ & ▢ \\end{pmatrix}", "matrix"), i("⟨u,v⟩", "\\langle ▢, ▢ \\rangle", "inner product")]),
        Category(title: "Sets & logic", items: [i("∈", "\\in "), i("∉", "\\notin "), i("⊂", "\\subset "), i("⊆", "\\subseteq "), i("∪", "\\cup ", "union"), i("∩", "\\cap ", "intersection"), i("∅", "\\emptyset "), i("∀", "\\forall "), i("∃", "\\exists "), i("⇒", "\\Rightarrow ", "implies"), i("⇔", "\\Leftrightarrow ", "iff equivalent"), i("¬", "\\neg ", "not"), i("∧", "\\land ", "and"), i("∨", "\\lor ", "or")]),
        Category(title: "Probability", items: [i("P(A)", "P(▢)", "probability"), i("E[X]", "E[▢]", "expectation expected value"), i("Var(X)", "\\mathrm{Var}(▢)", "variance"), i("Cov", "\\mathrm{Cov}(▢, ▢)", "covariance"), i("μ", "\\mu "), i("σ", "\\sigma "), i("σ²", "\\sigma^{2}", "variance sigma squared"), i("x̄", "\\bar{x}", "sample mean xbar"), i("ȳ", "\\bar{y}", "ybar"), i("ρ", "\\rho ", "correlation"), i("P(A|B)", "P(▢ \\mid ▢)", "conditional probability"), i("∼", "\\sim ", "distributed")]),
    ]

    /// Items matching every word of the query across all categories (empty query = nothing, so the UI shows categories).
    public static func search(_ q: String) -> [Item] {
        let words = q.lowercased().split(separator: " ").map(String.init)
        guard !words.isEmpty else { return [] }
        var seen = Set<String>(), out: [Item] = []
        for it in categories.flatMap(\.items) where seen.insert(it.latex).inserted {
            let hay = (it.label + " " + it.name + " " + it.latex).lowercased()
            if words.allSatisfy({ hay.contains($0) }) { out.append(it) }
        }
        return out
    }

    // MARK: Cursor-aware insertion (UTF-16 ranges, as NSTextView uses)

    public struct Edit: Equatable, Sendable { public var text: String; public var selection: NSRange }

    /// Inserts `latex` replacing the selection. A template's first ▢ is selected afterwards (and filled with the previously selected text,
    /// so selecting `x` then choosing a fraction gives x over ▢). `wrap` surrounds the insertion with `$` for prose answers.
    public static func insert(_ latex: String, into text: String, selection: NSRange, wrap: Bool = false) -> Edit {
        let ns = text as NSString
        let sel = NSRange(location: min(max(0, selection.location), ns.length), length: 0).union(selection, in: ns.length)
        let selected = ns.substring(with: sel)
        var piece = latex
        let ph = placeholder as NSString
        if !selected.isEmpty, let r = Optional((piece as NSString).range(of: placeholder)), r.location != NSNotFound { piece = (piece as NSString).replacingCharacters(in: r, with: selected) }
        if wrap { piece = "$" + piece + "$" }
        let out = ns.replacingCharacters(in: sel, with: piece)
        let pr = (piece as NSString).range(of: placeholder)
        let caret = pr.location != NSNotFound ? NSRange(location: sel.location + pr.location, length: ph.length) : NSRange(location: sel.location + (piece as NSString).length, length: 0)
        return Edit(text: out, selection: caret)
    }

    /// The next ▢ after `from` (wrapping to the first), or nil when none is left. Tab uses this to walk a template.
    public static func nextPlaceholder(in text: String, after from: Int) -> NSRange? {
        let ns = text as NSString
        let start = min(max(0, from), ns.length)
        let r = ns.range(of: placeholder, range: NSRange(location: start, length: ns.length - start))
        if r.location != NSNotFound { return r }
        let w = ns.range(of: placeholder)
        return w.location == NSNotFound ? nil : w
    }
    public static func hasPlaceholders(_ text: String) -> Bool { text.contains(placeholder) }
}

extension NSRange {
    fileprivate func union(_ other: NSRange, in length: Int) -> NSRange {
        let loc = min(max(0, other.location), length)
        return NSRange(location: loc, length: min(max(0, other.length), length - loc))
    }
}

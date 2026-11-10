import Foundation

/// Parsed LaTeX subset. Anything outside the subset throws, and callers fall back to showing the source,
/// so we never silently mis-render a formula.
public indirect enum MathNode: Equatable, Sendable {
    case symbol(String)
    case text(String)
    case row([MathNode])
    case frac(MathNode, MathNode)
    case sqrt(MathNode, index: MathNode?)
    case sup(MathNode, MathNode)
    case sub(MathNode, MathNode)
    case supsub(MathNode, sub: MathNode, sup: MathNode)
    case bigOp(String, lower: MathNode?, upper: MathNode?)
    case delimited(String, MathNode, String)
    /// Rows of cells; `left`/`right` are the fences (pmatrix `(` `)`, cases `{` and none).
    case matrix([[MathNode]], left: String, right: String)
    /// \bar, \vec, \hat, \tilde drawn over the content.
    case accent(String, MathNode)
    /// aligned / align / gather: rows of cells split at `&` (column 1 right-aligned, the rest left-aligned).
    case aligned([[MathNode]])
    case space
}

public enum LatexError: Error, Equatable { case unsupported(String), unbalanced, tooLarge }

public enum Latex {
    public static let maxLength = 5_000

    public static func parse(_ source: String) throws -> MathNode {
        guard source.count <= maxLength else { throw LatexError.tooLarge }
        var p = Parser(chars: Array(source))
        let n = try p.row(depth: 0)
        guard p.i >= p.chars.count else { throw LatexError.unbalanced }
        return n
    }

    // MARK: Unicode approximation (used for inline math in running text)

    /// One-line approximation using Unicode symbols; nil if the formula uses unsupported syntax.
    public static func unicode(_ source: String) -> String? {
        (try? parse(source)).map { flatten($0) }
    }

    /// Replaces `$...$` spans in a string with their Unicode approximation; unsupported spans stay as written.
    /// `$$` and a lone `$` followed by a digit-space currency pattern are left alone.
    public static func inlineConverted(_ text: String) -> String {
        guard text.contains("$") else { return text }
        var out = "", i = text.startIndex
        while i < text.endIndex {
            if text[i] == "\\", text.index(after: i) < text.endIndex, text[text.index(after: i)] == "$" { out.append("$"); i = text.index(i, offsetBy: 2); continue }
            if text[i] == "$", let close = text[text.index(after: i)...].firstIndex(of: "$"), close > text.index(after: i) {
                let inner = String(text[text.index(after: i)..<close])
                if !inner.hasPrefix(" "), !inner.hasSuffix(" "), let u = unicode(inner) { out += u; i = text.index(after: close); continue }
            }
            out.append(text[i]); i = text.index(after: i)
        }
        return out
    }

    // MARK: Tables

    static let symbols: [String: String] = [
        "alpha": "α", "beta": "β", "gamma": "γ", "delta": "δ", "epsilon": "ε", "varepsilon": "ε", "zeta": "ζ", "eta": "η",
        "theta": "θ", "iota": "ι", "kappa": "κ", "lambda": "λ", "mu": "μ", "nu": "ν", "xi": "ξ", "pi": "π", "rho": "ρ",
        "sigma": "σ", "tau": "τ", "upsilon": "υ", "phi": "φ", "varphi": "φ", "chi": "χ", "psi": "ψ", "omega": "ω",
        "Gamma": "Γ", "Delta": "Δ", "Theta": "Θ", "Lambda": "Λ", "Xi": "Ξ", "Pi": "Π", "Sigma": "Σ", "Phi": "Φ", "Psi": "Ψ", "Omega": "Ω",
        "le": "≤", "leq": "≤", "ge": "≥", "geq": "≥", "ne": "≠", "neq": "≠", "approx": "≈", "equiv": "≡", "sim": "∼",
        "infty": "∞", "cdot": "·", "times": "×", "div": "÷", "pm": "±", "mp": "∓", "to": "→", "rightarrow": "→", "leftarrow": "←",
        "Rightarrow": "⇒", "Leftarrow": "⇐", "Leftrightarrow": "⇔", "iff": "⟺", "in": "∈", "notin": "∉", "subset": "⊂",
        "subseteq": "⊆", "cup": "∪", "cap": "∩", "forall": "∀", "exists": "∃", "partial": "∂", "nabla": "∇", "ldots": "…",
        "dots": "…", "cdots": "⋯", "emptyset": "∅", "neg": "¬", "land": "∧", "lor": "∨", "oplus": "⊕", "propto": "∝",
        "angle": "∠", "langle": "⟨", "rangle": "⟩", "degree": "°", "prime": "′", "mid": "∣", "ll": "≪", "gg": "≫", "mapsto": "↦", "circ": "∘",
        "{": "{", "}": "}", "%": "%", "$": "$", "&": "&", "#": "#", "_": "_", "|": "‖",
    ]
    static let blackboard: [Character: String] = ["R": "ℝ", "E": "𝔼", "P": "ℙ", "N": "ℕ", "Z": "ℤ", "Q": "ℚ", "C": "ℂ", "1": "𝟙"]
    static let bigOps: [String: String] = ["sum": "∑", "prod": "∏", "int": "∫", "oint": "∮", "bigcup": "⋃", "bigcap": "⋂", "lim": "lim"]
    static let functions: Set<String> = ["sin", "cos", "tan", "cot", "sec", "csc", "log", "ln", "exp", "max", "min", "det", "gcd", "arcsin", "arccos", "arctan", "sinh", "cosh", "tanh"]
    static let textCommands: Set<String> = ["text", "mathrm", "mathbf", "mathit", "textbf", "textit", "operatorname", "mathbb", "mathcal", "mathsf", "mathtt"]
    static let spaces: Set<String> = [",", ";", ":", " ", "!", "quad", "qquad"]

    static let sup: [Character: Character] = [
        "0": "⁰", "1": "¹", "2": "²", "3": "³", "4": "⁴", "5": "⁵", "6": "⁶", "7": "⁷", "8": "⁸", "9": "⁹", "+": "⁺", "−": "⁻", "-": "⁻",
        "=": "⁼", "(": "⁽", ")": "⁾", "n": "ⁿ", "i": "ⁱ", "x": "ˣ", "y": "ʸ", "a": "ᵃ", "b": "ᵇ", "c": "ᶜ", "d": "ᵈ", "e": "ᵉ",
        "k": "ᵏ", "m": "ᵐ", "p": "ᵖ", "t": "ᵗ", "T": "ᵀ", "θ": "ᶿ",
    ]
    static let sub: [Character: Character] = [
        "0": "₀", "1": "₁", "2": "₂", "3": "₃", "4": "₄", "5": "₅", "6": "₆", "7": "₇", "8": "₈", "9": "₉", "+": "₊", "−": "₋", "-": "₋",
        "=": "₌", "(": "₍", ")": "₎", "a": "ₐ", "e": "ₑ", "i": "ᵢ", "j": "ⱼ", "k": "ₖ", "n": "ₙ", "m": "ₘ", "o": "ₒ", "x": "ₓ",
        "r": "ᵣ", "p": "ₚ", "t": "ₜ", "s": "ₛ", "h": "ₕ", "l": "ₗ",
    ]

    static func script(_ s: String, table: [Character: Character], marker: String) -> String {
        if !s.isEmpty, s.allSatisfy({ table[$0] != nil }) { return String(s.map { table[$0]! }) }
        return s.count == 1 ? "\(marker)\(s)" : "\(marker)(\(s))"
    }

    static func flatten(_ n: MathNode) -> String {
        func simple(_ s: String) -> Bool { s.count <= 1 || s.allSatisfy { $0.isLetter || $0.isNumber } }
        func wrap(_ s: String) -> String { simple(s) ? s : "(\(s))" }
        switch n {
        case .symbol(let s), .text(let s): return s
        case .row(let xs): return xs.map(flatten).joined()
        case .frac(let a, let b): return "\(wrap(flatten(a)))/\(wrap(flatten(b)))"
        case .sqrt(let x, let idx):
            let body = flatten(x)
            let root = idx.map { script(flatten($0), table: sup, marker: "^") + "√" } ?? "√"
            return root + wrap(body)
        case .sup(let b, let e): return flatten(b) + script(flatten(e), table: sup, marker: "^")
        case .sub(let b, let e): return flatten(b) + script(flatten(e), table: sub, marker: "_")
        case .supsub(let b, let lo, let hi): return flatten(b) + script(flatten(lo), table: sub, marker: "_") + script(flatten(hi), table: sup, marker: "^")
        case .bigOp(let s, let lo, let hi):
            return s + (lo.map { script(flatten($0), table: sub, marker: "_") } ?? "") + (hi.map { script(flatten($0), table: sup, marker: "^") } ?? "")
        case .delimited(let l, let x, let r): return l + flatten(x) + r
        case .matrix(let rows, let l, let r): return l + rows.map { $0.map(flatten).joined(separator: ", ") }.joined(separator: "; ") + r
        case .accent(let a, let x): return flatten(x) + a
        case .aligned(let rows): return rows.map { $0.map(flatten).joined(separator: " ") }.joined(separator: "; ")
        case .space: return " "
        }
    }

    // MARK: Parser

    struct Parser {
        let chars: [Character]
        var i = 0
        init(chars: [Character]) { self.chars = chars }
        var peek: Character? { i < chars.count ? chars[i] : nil }

        mutating func row(depth: Int, stopAtRight: Bool = false) throws -> MathNode {
            guard depth < 40 else { throw LatexError.tooLarge }
            var items: [MathNode] = []
            while let c = peek {
                if c == "}" { if depth == 0 { throw LatexError.unbalanced }; break }
                if stopAtRight, startsWith("\\right") { break }
                if c == "&" { throw LatexError.unsupported("&") }
                items.append(try postfix(depth: depth))
            }
            return items.count == 1 ? items[0] : .row(items)
        }

        func startsWith(_ s: String) -> Bool {
            let w = Array(s); return i + w.count <= chars.count && Array(chars[i..<i + w.count]) == w
        }

        mutating func postfix(depth: Int) throws -> MathNode {
            let atom = try self.atom(depth: depth)
            while startsWith("\\limits") || startsWith("\\nolimits") { i += startsWith("\\limits") ? 7 : 9 }
            var lo: MathNode?, hi: MathNode?
            while let c = peek, c == "^" || c == "_" {
                i += 1
                let arg = try self.atom(depth: depth + 1)
                if c == "^" { guard hi == nil else { throw LatexError.unsupported("double superscript") }; hi = arg }
                else { guard lo == nil else { throw LatexError.unsupported("double subscript") }; lo = arg }
            }
            if case .bigOp(let s, nil, nil) = atom, lo != nil || hi != nil { return .bigOp(s, lower: lo, upper: hi) }
            switch (lo, hi) {
            case (nil, nil): return atom
            case (let l?, nil): return .sub(atom, l)
            case (nil, let h?): return .sup(atom, h)
            case (let l?, let h?): return .supsub(atom, sub: l, sup: h)
            }
        }

        mutating func atom(depth: Int) throws -> MathNode {
            guard depth < 40 else { throw LatexError.tooLarge }
            guard let c = peek else { throw LatexError.unbalanced }
            if c == "{" {
                i += 1
                let r = try row(depth: depth + 1)
                guard peek == "}" else { throw LatexError.unbalanced }
                i += 1
                return r
            }
            if c == "\\" { return try command(depth: depth) }
            if c == "^" || c == "_" || c == "}" { throw LatexError.unbalanced }
            i += 1
            switch c {
            case "-": return .symbol("−")
            case "*": return .symbol("∗")
            case "~": return .space
            case "\n", "\t", " ": return .space
            default: return .symbol(String(c))
            }
        }

        mutating func readName() -> String {
            i += 1 // backslash
            guard let c = peek else { return "" }
            if c.isLetter {
                var n = ""; while let d = peek, d.isLetter { n.append(d); i += 1 }
                return n
            }
            i += 1; return String(c)
        }

        mutating func rawGroup() throws -> String {
            while peek == " " { i += 1 }
            guard peek == "{" else { throw LatexError.unbalanced }
            i += 1
            var depth = 1, s = ""
            while let c = peek {
                i += 1
                if c == "{" { depth += 1 } else if c == "}" { depth -= 1; if depth == 0 { return s } }
                s.append(c)
            }
            throw LatexError.unbalanced
        }

        mutating func command(depth: Int) throws -> MathNode {
            let name = readName()
            switch name {
            case "frac", "dfrac", "tfrac":
                return .frac(try atom(depth: depth + 1), try atom(depth: depth + 1))
            case "sqrt":
                var idx: MathNode?
                if peek == "[" {
                    i += 1
                    var s = ""; while let c = peek, c != "]" { s.append(c); i += 1 }
                    guard peek == "]" else { throw LatexError.unbalanced }
                    i += 1; idx = try Latex.parse(s)
                }
                return .sqrt(try atom(depth: depth + 1), index: idx)
            case "left":
                let open = try delimiter()
                let inner = try row(depth: depth + 1, stopAtRight: true)
                guard startsWith("\\right") else { throw LatexError.unbalanced }
                _ = readName()
                return .delimited(open, inner, try delimiter())
            case "begin": return try environment()
            case "displaystyle", "textstyle", "limits", "nolimits": return .space
            case "big", "Big", "bigg", "Bigg", "bigl", "bigr", "Bigl", "Bigr", "biggl", "biggr", "Biggl", "Biggr", "middle":
                let d = try delimiter(); return d.isEmpty ? .space : .symbol(d)
            case "boldsymbol", "bm", "boldmath": return try atom(depth: depth + 1)
            case "binom", "dbinom", "tbinom":
                let top = try atom(depth: depth + 1), bottom = try atom(depth: depth + 1)
                return .delimited("(", .matrix([[top], [bottom]], left: "", right: ""), ")")
            case "bar", "overline": return .accent("\u{0304}", try atom(depth: depth + 1))
            case "vec": return .accent("\u{20D7}", try atom(depth: depth + 1))
            case "hat": return .accent("\u{0302}", try atom(depth: depth + 1))
            case "tilde": return .accent("\u{0303}", try atom(depth: depth + 1))
            case "end", "\\", "right": throw LatexError.unsupported(name)
            default: break
            }
            if let s = bigOps[name] { return .bigOp(s, lower: nil, upper: nil) }
            if functions.contains(name) { return .text(name) }
            if textCommands.contains(name) {
                let raw = try rawGroup()
                if name == "mathbb", raw.count == 1, let g = Latex.blackboard[raw.first!] { return .symbol(g) }
                return .text(raw)
            }
            if spaces.contains(name) { return .space }
            if let s = symbols[name] { return .symbol(s) }
            throw LatexError.unsupported(name)
        }

        /// \begin{pmatrix} a & b \\ c & d \end{pmatrix} and friends; cells are parsed as ordinary math.
        mutating func environment() throws -> MathNode {
            let env = try rawGroup()
            let fences: [String: (String, String)] = ["matrix": ("", ""), "pmatrix": ("(", ")"), "bmatrix": ("[", "]"), "vmatrix": ("|", "|"), "Vmatrix": ("‖", "‖"), "cases": ("{", "")]
            let alignedEnvs: Set<String> = ["aligned", "align", "align*", "gather", "gather*", "split"]
            guard fences[env] != nil || alignedEnvs.contains(env) else { throw LatexError.unsupported(env) }
            let f = fences[env] ?? ("", "")
            let end = Array("\\end{\(env)}")
            var j = i
            while j + end.count <= chars.count, Array(chars[j..<j + end.count]) != end { j += 1 }
            guard j + end.count <= chars.count else { throw LatexError.unbalanced }
            let body = String(chars[i..<j]); i = j + end.count
            let rows = try body.components(separatedBy: "\\\\").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
                .map { try $0.components(separatedBy: "&").map { try Latex.parse($0.trimmingCharacters(in: .whitespaces)) } }
            guard !rows.isEmpty, rows.count <= 12, rows.allSatisfy({ $0.count <= 12 }) else { throw LatexError.tooLarge }
            return alignedEnvs.contains(env) ? .aligned(rows) : .matrix(rows, left: f.0, right: f.1)
        }

        mutating func delimiter() throws -> String {
            guard let c = peek else { throw LatexError.unbalanced }
            if c == "." { i += 1; return "" }
            if c == "\\" {
                let n = readName()
                switch n { case "{": return "{"; case "}": return "}"; case "|": return "‖"; case "langle": return "⟨"; case "rangle": return "⟩"
                case "lfloor": return "⌊"; case "rfloor": return "⌋"; case "lceil": return "⌈"; case "rceil": return "⌉"
                default: throw LatexError.unsupported(n) }
            }
            i += 1; return String(c)
        }
    }
}

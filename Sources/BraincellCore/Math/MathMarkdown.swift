import Foundation

/// Hybrid Markdown + LaTeX content: the one deterministic parser behind every math-aware view (questions, solutions, chat, previews).
/// Storage format: Markdown with `\( … \)` inline math, `\[ … \]` display math, `\begin{aligned|align|gather|equation}` blocks and
/// fenced code. `$…$` and `$$…$$` are accepted and normalized. Formula text is never rewritten; malformed spans stay literal text.
public enum MathInline: Equatable, Sendable { case text(String), math(String) }

public enum MathBlock: Equatable, Sendable {
    case paragraph([MathInline])
    case heading([MathInline])
    case display(String, boxed: Bool)
    case code(language: String?, text: String)
    case list(ordered: Bool, items: [[MathInline]])
    /// "Part A", "(b)", "c)" at the start of a line, with the rest of that paragraph.
    case part(label: String, [MathInline])
}

public enum MathMarkdown {
    static let displayEnvs = ["equation", "equation*", "align", "align*", "aligned", "gather", "gather*", "multline", "multline*"]

    // MARK: Parse

    public static func parse(_ source: String) -> [MathBlock] {
        var out: [MathBlock] = []
        // 1. Fenced code first: nothing inside a fence is math or structure.
        var prose: [String] = [], code: [String]? = nil, lang: String?
        func flushProse() { if !prose.isEmpty { out += blocks(prose.joined(separator: "\n")); prose = [] } }
        for line in source.components(separatedBy: "\n") {
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                if let c = code { out.append(.code(language: lang, text: c.joined(separator: "\n"))); code = nil }
                else { flushProse(); code = []; let l = line.trimmingCharacters(in: .whitespaces).dropFirst(3).trimmingCharacters(in: .whitespaces); lang = l.isEmpty ? nil : l }
                continue
            }
            if code != nil { code!.append(line) } else { prose.append(line) }
        }
        if let c = code { out.append(.code(language: lang, text: c.joined(separator: "\n"))) }     // unterminated fence: keep as code
        flushProse()
        return out
    }

    enum Piece: Equatable { case prose(String), display(String) }

    /// Splits at display math. Unterminated delimiters stay in the prose untouched.
    static func splitDisplay(_ s: String) -> [Piece] {
        let c = Array(s); var pieces: [Piece] = [], cur = "", i = 0
        func starts(_ t: String, at j: Int) -> Bool { let a = Array(t); return j + a.count <= c.count && Array(c[j..<j + a.count]) == a }
        func find(_ t: String, from j: Int) -> Int? { var k = j; while k + t.count <= c.count { if starts(t, at: k) { return k }; k += 1 }; return nil }
        while i < c.count {
            if c[i] == "\\", i + 1 < c.count, c[i + 1] == "$" { cur += "\\$"; i += 2; continue }
            if starts("$$", at: i), let e = find("$$", from: i + 2) {
                if !cur.isEmpty { pieces.append(.prose(cur)); cur = "" }
                pieces.append(.display(String(c[(i + 2)..<e]))); i = e + 2; continue
            }
            if starts("\\[", at: i), let e = find("\\]", from: i + 2) {
                if !cur.isEmpty { pieces.append(.prose(cur)); cur = "" }
                pieces.append(.display(String(c[(i + 2)..<e]))); i = e + 2; continue
            }
            if starts("\\begin{", at: i), let close = find("}", from: i + 7), case let env = String(c[(i + 7)..<close]), displayEnvs.contains(env), let e = find("\\end{\(env)}", from: close) {
                if !cur.isEmpty { pieces.append(.prose(cur)); cur = "" }
                let whole = String(c[i..<(e + "\\end{\(env)}".count)])
                pieces.append(.display(env.hasPrefix("equation") ? String(c[(close + 1)..<e]) : whole)); i = e + "\\end{\(env)}".count; continue
            }
            cur.append(c[i]); i += 1
        }
        if !cur.isEmpty { pieces.append(.prose(cur)) }
        return pieces
    }

    /// Inline spans: `\(…\)` and `$…$` (not currency: the span may not start or end with a space). Escaped `\$` is a literal dollar.
    public static func inline(_ s: String) -> [MathInline] {
        let c = Array(s); var out: [MathInline] = [], cur = "", i = 0
        func flush() { if !cur.isEmpty { out.append(.text(cur)); cur = "" } }
        while i < c.count {
            if c[i] == "\\", i + 1 < c.count, c[i + 1] == "$" { cur += "$"; i += 2; continue }
            if c[i] == "\\", i + 1 < c.count, c[i + 1] == "(" {
                var k = i + 2, found: Int?
                while k + 1 < c.count { if c[k] == "\\", c[k + 1] == ")" { found = k; break }; k += 1 }
                if let e = found, e > i + 2 { flush(); out.append(.math(String(c[(i + 2)..<e]).trimmingCharacters(in: .whitespaces))); i = e + 2; continue }
            }
            if c[i] == "$" {
                var k = i + 1, found: Int?
                while k < c.count { if c[k] == "\\" { k += 2; continue }; if c[k] == "$" { found = k; break }; if c[k] == "\n" { break }; k += 1 }
                if let e = found, e > i + 1 {
                    let inner = String(c[(i + 1)..<e])
                    if !inner.hasPrefix(" "), !inner.hasSuffix(" ") { flush(); out.append(.math(inner)); i = e + 1; continue }
                }
            }
            cur.append(c[i]); i += 1
        }
        flush()
        return out
    }

    static let partRegex = try! NSRegularExpression(pattern: #"^(?:\*\*)?(Part\s+[A-Za-z0-9]+|\([A-Za-z0-9]\)|[A-Za-z]\))(?:\*\*)?\s*[:.]?\s*(?:\*\*)?\s*(.*)$"#)
    static let bulletRegex = try! NSRegularExpression(pattern: #"^\s*(?:[-*•]|(\d+)[.)])\s+(.*)$"#)
    static let headingRegex = try! NSRegularExpression(pattern: #"^#{1,4}\s+(.*)$"#)

    static func blocks(_ prose: String) -> [MathBlock] {
        var out: [MathBlock] = []
        for piece in splitDisplay(prose) {
            switch piece {
            case .display(let l):
                let t = l.trimmingCharacters(in: .whitespacesAndNewlines)
                if !t.isEmpty { out.append(.display(t, boxed: shouldBox(t))) }
            case .prose(let p): out += lines(p)
            }
        }
        return out
    }

    static func lines(_ p: String) -> [MathBlock] {
        var out: [MathBlock] = [], para: [String] = [], part: String?, items: [[String]] = [], ordered = false
        func flushPara() {
            guard !para.isEmpty else { return }
            let text = para.joined(separator: "\n")
            out.append(part.map { .part(label: $0, inline(text)) } ?? .paragraph(inline(text))); para = []; part = nil
        }
        func flushList() { if !items.isEmpty { out.append(.list(ordered: ordered, items: items.map { inline($0.joined(separator: " ")) })); items = [] } }
        for raw in p.components(separatedBy: "\n") {
            let t = raw.trimmingCharacters(in: .whitespaces); let ns = t as NSString, full = NSRange(location: 0, length: ns.length)
            if t.isEmpty { flushPara(); flushList(); continue }
            if let m = headingRegex.firstMatch(in: t, range: full) { flushPara(); flushList(); out.append(.heading(inline(ns.substring(with: m.range(at: 1))))); continue }
            if let m = partRegex.firstMatch(in: t, range: full) {
                flushPara(); flushList()
                part = ns.substring(with: m.range(at: 1)).trimmingCharacters(in: CharacterSet(charactersIn: "*")); para = [ns.substring(with: m.range(at: 2))]; continue
            }
            if let m = bulletRegex.firstMatch(in: t, range: full) {
                flushPara()
                let isOrdered = m.range(at: 1).location != NSNotFound
                if !items.isEmpty, isOrdered != ordered { flushList() }
                ordered = isOrdered; items.append([ns.substring(with: m.range(at: 2))]); continue
            }
            if !items.isEmpty, raw.hasPrefix(" ") || raw.hasPrefix("\t") { items[items.count - 1].append(t); continue }
            flushList(); para.append(raw)
        }
        flushPara(); flushList()
        return out
    }

    /// Dedicated boxes are for substantial expressions only (definitions, long or structured formulas), not every symbol.
    public static func shouldBox(_ latex: String) -> Bool {
        latex.count >= 36 || latex.contains("\\begin") || (latex.contains("=") && (latex.contains("\\frac") || latex.contains("\\sum") || latex.contains("\\int")))
    }

    // MARK: Normalize

    /// `$…$` → `\(…\)` and `$$…$$` → `\[…\]`, only for well-formed pairs. Formula text is copied verbatim; the result parses to the same blocks.
    public static func normalize(_ s: String) -> String {
        var segments: [(fence: Bool, lines: [String])] = [], inFence = false
        for line in s.components(separatedBy: "\n") {
            let isFence = line.trimmingCharacters(in: .whitespaces).hasPrefix("```")
            if isFence && !inFence { segments.append((true, [line])); inFence = true; continue }
            if inFence { segments[segments.count - 1].lines.append(line); if isFence { inFence = false }; continue }
            if segments.last?.fence == false { segments[segments.count - 1].lines.append(line) } else { segments.append((false, [line])) }
        }
        return segments.map { $0.fence ? $0.lines.joined(separator: "\n") : normalizeProse($0.lines.joined(separator: "\n")) }.joined(separator: "\n")
    }

    static func normalizeProse(_ p: String) -> String {
        var out = ""
        for piece in splitDisplay(p) {
            switch piece {
            case .display(let l): out += "\\[" + l + "\\]"
            case .prose(let t): for i in inline(t) { switch i { case .text(let x): out += x.replacingOccurrences(of: "$", with: "\\$"); case .math(let m): out += "\\(" + m + "\\)" } }
            }
        }
        return out
    }

    // MARK: Validate

    /// Human-readable problems. Nothing is repaired here: the learner sees the content and the note.
    public static func issues(_ s: String) -> [String] {
        let body = s.components(separatedBy: "```").enumerated().filter { $0.offset % 2 == 0 }.map(\.element).joined(separator: "\n")
        var out: [String] = []
        func count(_ t: String) -> Int { body.components(separatedBy: t).count - 1 }
        if count("\\(") != count("\\)") { out.append("Unbalanced \\( … \\) math delimiters.") }
        if count("\\[") != count("\\]") { out.append("Unbalanced \\[ … \\] math delimiters.") }
        if count("$$") % 2 == 1 { out.append("Unbalanced $$ math delimiters.") }
        if body.range(of: #"<\s*(script|iframe|object|embed|style|img|a)\b|javascript:"#, options: [.regularExpression, .caseInsensitive]) != nil { out.append("Contains HTML or script markup, which is never rendered.") }
        return out
    }

    // MARK: Legacy plain-text math

    static let greek: [Character: String] = ["α": "\\alpha", "β": "\\beta", "γ": "\\gamma", "δ": "\\delta", "ε": "\\epsilon", "θ": "\\theta", "λ": "\\lambda", "μ": "\\mu", "π": "\\pi", "ρ": "\\rho", "σ": "\\sigma", "τ": "\\tau", "φ": "\\phi", "ω": "\\omega", "Σ": "\\Sigma", "Δ": "\\Delta", "Ω": "\\Omega"]
    static let knownWords: Set<String> = ["Var", "Cov", "Corr", "exp", "log", "sin", "cos", "tan", "ln", "max", "min", "sqrt"]

    /// Conservative upgrade for old plain-text formulas such as `U=(X-E[X])/σ_X`: a line that is clearly just a formula (an `=`, no words) is
    /// shown as a display equation with Greek letters spelled as commands. Operators, slashes and brackets are never reinterpreted.
    /// Returns nil when nothing qualifies, or when the text already uses math delimiters.
    public static func legacyUpgrade(_ s: String) -> String? {
        guard !s.contains("\\(") && !s.contains("\\[") && !s.contains("$") && !s.contains("```") else { return nil }
        var changed = false
        let lines = s.components(separatedBy: "\n").map { line -> String in
            let t = line.trimmingCharacters(in: .whitespaces)
            guard t.contains("="), t.count <= 90, !t.contains("\\"), !t.contains(". ") else { return line }
            let words = t.split { !$0.isLetter }.map(String.init).filter { $0.count >= 3 && $0.allSatisfy { $0.isASCII } }
            guard words.allSatisfy({ knownWords.contains($0) }) else { return line }
            guard t.range(of: #"^[A-Za-z0-9σμπρτφωαβγδελΣΔΩ_^+\-*/=()\[\]{}., |<>≤≥≠≈·×]+$"#, options: .regularExpression) != nil else { return line }
            changed = true
            var latex = ""
            let chars = Array(t)
            for (k, ch) in chars.enumerated() {
                if let g = greek[ch] { latex += g; if k + 1 < chars.count, chars[k + 1].isASCII, chars[k + 1].isLetter { latex += " " } } else { latex.append(ch) }   // a space only where the command would run into a letter
            }
            return "\\[" + latex + "\\]"
        }
        return changed ? lines.joined(separator: "\n") : nil
    }
}

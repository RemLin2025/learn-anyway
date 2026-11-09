import Foundation

/// Auto-indent for the Return key.
public enum AutoIndent {
    public static let unit = "    "

    /// Text to insert for a newline at `caret` (UTF-16 offset), and where the caret should land inside it.
    /// Keeps the current line's indentation; indents one more level after `:` (Python) or `{` (C/Java);
    /// between `{` and `}` it also places the closing brace on its own line.
    public static func newline(in text: String, caret: Int, language: CodeLanguage) -> (insert: String, caretOffset: Int) {
        let u = Array(text.utf16)
        let c = min(max(0, caret), u.count)
        var ls = c; while ls > 0, u[ls - 1] != 10 { ls -= 1 }
        let before = String(utf16CodeUnits: Array(u[ls..<c]), count: c - ls)
        let indent = String(before.prefix { $0 == " " || $0 == "\t" })
        let trimmed = before.trimmingCharacters(in: .whitespaces)
        let opens = language == .python ? trimmed.hasSuffix(":") : trimmed.hasSuffix("{")
        let next: UInt16 = c < u.count ? u[c] : 0
        if language != .python, opens, next == 125 /* } */ {
            let inner = "\n" + indent + unit
            return (inner + "\n" + indent, inner.utf16.count)
        }
        let s = "\n" + indent + (opens ? unit : "")
        return (s, s.utf16.count)
    }
}

/// Finds the bracket matching the one next to the caret, ignoring brackets inside strings and comments.
public enum BracketMatcher {
    static let pairs: [(open: UInt16, close: UInt16)] = [(40, 41), (91, 93), (123, 125)] // () [] {}

    /// Returns the two UTF-16 offsets of the pair, if the character before or at `caret` is a bracket with a partner.
    public static func match(in text: String, caret: Int, language: CodeLanguage) -> (Int, Int)? {
        let u = Array(text.utf16)
        var skip = [Bool](repeating: false, count: u.count)
        for t in SyntaxHighlighter.tokens(text, language: language) where t.kind == .string || t.kind == .comment {
            for k in t.location..<min(u.count, t.location + t.length) { skip[k] = true }
        }
        for pos in [caret - 1, caret] where pos >= 0 && pos < u.count && !skip[pos] {
            if let p = pairs.first(where: { $0.open == u[pos] }) {
                var depth = 0, k = pos
                while k < u.count {
                    if !skip[k] { if u[k] == p.open { depth += 1 } else if u[k] == p.close { depth -= 1; if depth == 0 { return (pos, k) } } }
                    k += 1
                }
            } else if let p = pairs.first(where: { $0.close == u[pos] }) {
                var depth = 0, k = pos
                while k >= 0 {
                    if !skip[k] { if u[k] == p.close { depth += 1 } else if u[k] == p.open { depth -= 1; if depth == 0 { return (k, pos) } } }
                    k -= 1
                }
            }
        }
        return nil
    }
}

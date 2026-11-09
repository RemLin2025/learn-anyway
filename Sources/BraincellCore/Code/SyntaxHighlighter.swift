import Foundation

public enum CodeLanguage: String, Sendable, CaseIterable {
    case python, c, java

    public init?(name: String) { self.init(rawValue: name.lowercased()) }

    var keywords: Set<String> {
        switch self {
        case .python:
            ["False", "None", "True", "and", "as", "assert", "async", "await", "break", "class", "continue", "def", "del", "elif", "else",
             "except", "finally", "for", "from", "global", "if", "import", "in", "is", "lambda", "nonlocal", "not", "or", "pass", "raise",
             "return", "try", "while", "with", "yield", "self", "print", "range", "len"]
        case .c:
            ["auto", "break", "case", "char", "const", "continue", "default", "do", "double", "else", "enum", "extern", "float", "for",
             "goto", "if", "inline", "int", "long", "register", "return", "short", "signed", "sizeof", "static", "struct", "switch",
             "typedef", "union", "unsigned", "void", "volatile", "while", "NULL", "bool", "true", "false"]
        case .java:
            ["abstract", "assert", "boolean", "break", "byte", "case", "catch", "char", "class", "const", "continue", "default", "do",
             "double", "else", "enum", "extends", "final", "finally", "float", "for", "if", "implements", "import", "instanceof", "int",
             "interface", "long", "new", "null", "package", "private", "protected", "public", "return", "short", "static", "super",
             "switch", "this", "throw", "throws", "try", "void", "while", "true", "false", "var", "record"]
        }
    }
}

public enum TokenKind: Sendable { case keyword, string, comment, number, preprocessor }

public struct Token: Equatable, Sendable {
    public var location: Int   // UTF-16 offset, directly usable in NSRange
    public var length: Int
    public var kind: TokenKind
}

/// Small hand-written lexer; enough for readable highlighting, not a parser. Lexes UTF-16 units so results
/// map straight onto NSTextView ranges.
public enum SyntaxHighlighter {
    public static func tokens(_ text: String, language: CodeLanguage) -> [Token] {
        let u = Array(text.utf16), n = u.count
        var out: [Token] = []
        var i = 0
        let keywords = language.keywords

        func at(_ k: Int) -> UInt16 { k < n ? u[k] : 0 }
        func ch(_ s: Character) -> UInt16 { s.utf16.first! }
        func starts(_ s: String, _ k: Int) -> Bool {
            let w = Array(s.utf16); guard k + w.count <= n else { return false }
            return (0..<w.count).allSatisfy { u[k + $0] == w[$0] }
        }
        func isIdentStart(_ c: UInt16) -> Bool { (c >= 65 && c <= 90) || (c >= 97 && c <= 122) || c == 95 }
        func isDigit(_ c: UInt16) -> Bool { c >= 48 && c <= 57 }
        func isIdent(_ c: UInt16) -> Bool { isIdentStart(c) || isDigit(c) }
        func lineStartsWithOnlySpace(before k: Int) -> Bool {
            var j = k - 1
            while j >= 0, u[j] != 10 { if u[j] != 32 && u[j] != 9 { return false }; j -= 1 }
            return true
        }

        while i < n {
            let c = u[i]
            if language == .python ? c == ch("#") : starts("//", i) {
                let s = i; while i < n, u[i] != 10 { i += 1 }
                out.append(Token(location: s, length: i - s, kind: .comment)); continue
            }
            if language != .python, starts("/*", i) {
                let s = i; i += 2
                while i < n, !starts("*/", i) { i += 1 }
                i = min(n, i + 2)
                out.append(Token(location: s, length: i - s, kind: .comment)); continue
            }
            if language == .c, c == ch("#"), lineStartsWithOnlySpace(before: i) {
                let s = i; while i < n, u[i] != 10 { i += 1 }
                out.append(Token(location: s, length: i - s, kind: .preprocessor)); continue
            }
            if language == .python, starts("\"\"\"", i) || starts("'''", i) {
                let q = String(Character(UnicodeScalar(c)!)) * 3
                let s = i; i += 3
                while i < n, !starts(q, i) { i += u[i] == 92 ? 2 : 1 }
                i = min(n, i + 3)
                out.append(Token(location: s, length: i - s, kind: .string)); continue
            }
            if c == ch("\"") || c == ch("'") {
                let s = i; i += 1
                while i < n, u[i] != c, u[i] != 10 { i += u[i] == 92 ? 2 : 1 }
                i = min(n, i + (i < n && u[i] == c ? 1 : 0))
                out.append(Token(location: s, length: i - s, kind: .string)); continue
            }
            if isDigit(c) {
                let s = i; while i < n, isIdent(u[i]) || u[i] == ch(".") { i += 1 }
                out.append(Token(location: s, length: i - s, kind: .number)); continue
            }
            if isIdentStart(c) {
                let s = i; while i < n, isIdent(u[i]) { i += 1 }
                let word = String(utf16CodeUnits: Array(u[s..<i]), count: i - s)
                if keywords.contains(word) { out.append(Token(location: s, length: i - s, kind: .keyword)) }
                continue
            }
            i += 1
        }
        return out
    }
}

private func * (s: String, n: Int) -> String { String(repeating: s, count: n) }

import Foundation

/// Tiny safe evaluator for `verificationExpression`: numbers, + - * / ^, parentheses, unary minus, `pi`.
/// Deliberately not NSExpression (which can raise exceptions or call arbitrary selectors on untrusted input).
public enum ArithmeticEvaluator {
    public enum EvalError: Error, Equatable { case syntax, tooLong, divideByZero, notFinite }

    public static func evaluate(_ s: String) throws -> Double {
        guard s.count <= 200 else { throw EvalError.tooLong }
        var p = Parser(chars: Array(s.lowercased().filter { !$0.isWhitespace }))
        let v = try p.expr(depth: 0)
        guard p.i == p.chars.count else { throw EvalError.syntax }
        guard v.isFinite else { throw EvalError.notFinite }
        return v
    }

    private struct Parser {
        let chars: [Character]
        var i = 0
        init(chars: [Character]) { self.chars = chars }

        mutating func expr(depth: Int) throws -> Double {
            guard depth < 50 else { throw EvalError.tooLong }
            var v = try term(depth: depth)
            while let c = peek, c == "+" || c == "-" {
                i += 1
                let r = try term(depth: depth)
                v = c == "+" ? v + r : v - r
            }
            return v
        }
        mutating func term(depth: Int) throws -> Double {
            var v = try unary(depth: depth)
            while let c = peek, c == "*" || c == "/" {
                i += 1
                let r = try unary(depth: depth)
                if c == "/" { guard r != 0 else { throw EvalError.divideByZero }; v /= r } else { v *= r }
            }
            return v
        }
        mutating func unary(depth: Int) throws -> Double {
            if peek == "-" { i += 1; return -(try unary(depth: depth + 1)) }
            if peek == "+" { i += 1; return try unary(depth: depth + 1) }
            return try power(depth: depth)
        }
        mutating func power(depth: Int) throws -> Double {
            let base = try atom(depth: depth)
            if peek == "^" { i += 1; return pow(base, try unary(depth: depth + 1)) } // right-assoc
            return base
        }
        mutating func atom(depth: Int) throws -> Double {
            if peek == "(" {
                i += 1
                let v = try expr(depth: depth + 1)
                guard peek == ")" else { throw EvalError.syntax }
                i += 1; return v
            }
            if chars[i...].starts(with: "pi") { i += 2; return .pi }
            let start = i
            while let c = peek, c.isNumber || c == "." { i += 1 }
            guard start < i, let v = Double(String(chars[start..<i])) else { throw EvalError.syntax }
            return v
        }
        var peek: Character? { i < chars.count ? chars[i] : nil }
    }
}

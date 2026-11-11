import Foundation

/// Scientific-calculator expression engine: + − × ÷ ^ ( ), unary minus, postfix !, constants (pi, e, ans), functions
/// (sin cos tan asin acos atan ln log sqrt exp abs). Pure and deterministic; no implicit multiplication, so nothing is guessed.
public enum Calculator {
    public enum CalcError: Error, Equatable { case syntax(String), domain(String) }

    public static func evaluate(_ input: String, degrees: Bool = false, ans: Double = 0) -> Result<Double, CalcError> {
        var p = Parser(chars: Array(input.replacingOccurrences(of: "×", with: "*").replacingOccurrences(of: "÷", with: "/").replacingOccurrences(of: "−", with: "-").replacingOccurrences(of: "π", with: "pi").replacingOccurrences(of: "√", with: "sqrt").lowercased()), degrees: degrees, ans: ans)
        do {
            let v = try p.expr(0)
            p.skip(); guard p.i >= p.chars.count else { throw CalcError.syntax("unexpected “\(p.chars[p.i])”") }
            guard v.isFinite else { throw CalcError.domain("result is not a finite number") }
            return .success(v)
        } catch let e as CalcError { return .failure(e) } catch { return .failure(.syntax("invalid")) }
    }

    /// Up to 10 significant digits, no trailing zeros; very large/small values in scientific notation.
    public static func format(_ v: Double) -> String {
        if v == 0 { return "0" }
        let a = abs(v)
        if a >= 1e10 || a < 1e-6 { return String(format: "%.6e", v) }
        var s = String(format: "%.10g", v)
        if s.contains("e") { s = String(format: "%.6e", v) }
        return s
    }

    struct Parser {
        let chars: [Character]; var i = 0; let degrees: Bool; let ans: Double
        init(chars: [Character], degrees: Bool, ans: Double) { self.chars = chars; self.degrees = degrees; self.ans = ans }
        mutating func skip() { while i < chars.count, chars[i] == " " { i += 1 } }
        var peek: Character? { i < chars.count ? chars[i] : nil }

        mutating func expr(_ depth: Int) throws -> Double {
            guard depth < 60 else { throw CalcError.syntax("too deeply nested") }
            var v = try term(depth)
            while true { skip(); if peek == "+" { i += 1; v += try term(depth) } else if peek == "-" { i += 1; v -= try term(depth) } else { return v } }
        }
        mutating func term(_ depth: Int) throws -> Double {
            var v = try unary(depth)
            while true {
                skip()
                if peek == "*" { i += 1; v *= try unary(depth) }
                else if peek == "/" { i += 1; let d = try unary(depth); guard d != 0 else { throw CalcError.domain("division by zero") }; v /= d }
                else { return v }
            }
        }
        mutating func power(_ depth: Int) throws -> Double {
            let base = try postfix(depth); skip()
            if peek == "^" { i += 1; let e = try unary(depth + 1); return try pow2(base, e) }      // right-associative; −2^2 = −4
            return base
        }
        func pow2(_ b: Double, _ e: Double) throws -> Double { let r = pow(b, e); guard r.isFinite else { throw CalcError.domain("undefined power") }; return r }
        mutating func unary(_ depth: Int) throws -> Double {
            guard depth < 60 else { throw CalcError.syntax("too deeply nested") }
            skip()
            if peek == "-" { i += 1; return -(try unary(depth + 1)) }
            if peek == "+" { i += 1; return try unary(depth + 1) }
            return try power(depth)
        }
        mutating func postfix(_ depth: Int) throws -> Double {
            var v = try atom(depth)
            while true {
                skip()
                if peek == "!" {
                    i += 1
                    guard v >= 0, v == v.rounded(), v <= 170 else { throw CalcError.domain("factorial needs an integer from 0 to 170") }
                    v = (0...Int(v)).dropFirst().reduce(1.0) { $0 * Double($1) }
                } else if peek == "%" { i += 1; v /= 100 } else { return v }
            }
        }
        mutating func atom(_ depth: Int) throws -> Double {
            skip()
            guard let c = peek else { throw CalcError.syntax("incomplete expression") }
            if c == "(" {
                i += 1; let v = try expr(depth + 1); skip()
                guard peek == ")" else { throw CalcError.syntax("missing )") }
                i += 1; return v
            }
            if c.isNumber || c == "." {
                var s = ""
                while let d = peek, d.isNumber || d == "." { s.append(d); i += 1 }
                if let e = peek, e == "e", i + 1 < chars.count, chars[i + 1].isNumber || chars[i + 1] == "-" || chars[i + 1] == "+" {
                    var j = i + 1; var exp = "e"; if chars[j] == "-" || chars[j] == "+" { exp.append(chars[j]); j += 1 }
                    if j < chars.count, chars[j].isNumber { while j < chars.count, chars[j].isNumber { exp.append(chars[j]); j += 1 }; s += exp; i = j }
                }
                guard let v = Double(s) else { throw CalcError.syntax("bad number “\(s)”") }
                return v
            }
            if c.isLetter {
                var name = ""
                while let d = peek, d.isLetter { name.append(d); i += 1 }
                switch name {
                case "pi": return .pi
                case "e": return M_E
                case "ans": return ans
                default: break
                }
                skip()
                guard peek == "(" else { throw CalcError.syntax("unknown name “\(name)”") }
                i += 1; let x = try expr(depth + 1); skip()
                guard peek == ")" else { throw CalcError.syntax("missing )") }
                i += 1
                let r = degrees ? Double.pi / 180 : 1
                switch name {
                case "sin": return sin(x * r)
                case "cos": return cos(x * r)
                case "tan": let c = cos(x * r); guard abs(c) > 1e-12 else { throw CalcError.domain("tan is undefined here") }; return tan(x * r)
                case "asin": guard (-1...1).contains(x) else { throw CalcError.domain("asin needs −1…1") }; return asin(x) / r
                case "acos": guard (-1...1).contains(x) else { throw CalcError.domain("acos needs −1…1") }; return acos(x) / r
                case "atan": return atan(x) / r
                case "ln": guard x > 0 else { throw CalcError.domain("ln needs a positive number") }; return log(x)
                case "log": guard x > 0 else { throw CalcError.domain("log needs a positive number") }; return log10(x)
                case "sqrt": guard x >= 0 else { throw CalcError.domain("square root of a negative number") }; return x.squareRoot()
                case "exp": return exp(x)
                case "abs": return abs(x)
                default: throw CalcError.syntax("unknown function “\(name)”")
                }
            }
            throw CalcError.syntax("unexpected “\(c)”")
        }
    }
}

import Foundation

/// Exact algebraic equivalence for polynomial and rational expressions (+ − × ÷, integer powers, variables a–z/A–Z,
/// rational constants). Anything outside that (functions, constants like π, non-integer powers…) is reported as
/// `unsupported`, never guessed, so the caller can send it to review instead of marking it wrong.
///
/// Expressions are expanded to exact rational-coefficient polynomials and compared by cross-multiplication
/// (a/b = c/d ⇔ a·d = c·b), so `(x+1)^2` equals `x^2+2x+1` and `(x^2-1)/(x-1)` equals `x+1` (as rational functions:
/// points where the original is undefined are ignored).
public enum SymbolicMath {

    public enum Result: Equatable, Sendable {
        case equal, notEqual
        /// Valid but beyond this checker (e.g. sin(x), √x, π).
        case unsupported(String)
        /// Couldn't be read as an expression.
        case unreadable(String)
    }

    // MARK: Public API

    public static func compare(key: String, answer: String) -> Result {
        let k: RFun, a: RFun
        switch parse(key) { case .success(let f): k = f; case .failure(let e): return e.asResult(prefix: "The answer key") }
        switch parse(answer) { case .success(let f): a = f; case .failure(let e): return e.asResult(prefix: "Your answer") }
        do { return try k.equals(a) ? .equal : .notEqual } catch { return .unsupported("The expressions got too large to compare.") }
    }

    /// Plain-text form of simple LaTeX (`\frac{a}{b}`, `x^{2}`, `\cdot`, `\times`), or nil if it uses anything else.
    public static func fromLatex(_ s: String) -> String? {
        guard let node = try? Latex.parse(s) else { return nil }
        func conv(_ n: MathNode) -> String? {
            switch n {
            case .symbol(let t):
                switch t { case "−": return "-"; case "·", "×", "∗": return "*"; case "÷": return "/"; default: return t }
            case .space: return " "
            case .text: return nil
            case .row(let xs): let parts = xs.map(conv); return parts.contains { $0 == nil } ? nil : parts.map { $0! }.joined()
            case .frac(let a, let b): guard let x = conv(a), let y = conv(b) else { return nil }; return "((\(x))/(\(y)))"
            case .sup(let b, let e): guard let x = conv(b), let y = conv(e) else { return nil }; return "((\(x))^(\(y)))"
            case .delimited(let l, let x, let r): guard (l == "(" || l.isEmpty), (r == ")" || r.isEmpty), let y = conv(x) else { return nil }; return "(\(y))"
            default: return nil
            }
        }
        return conv(node)
    }

    // MARK: Numbers

    struct Rat: Equatable, Hashable {
        var n: Int, d: Int   // d > 0, gcd(n, d) = 1
        static let zero = Rat(n: 0, d: 1), one = Rat(n: 1, d: 1)
        init(n: Int, d: Int) { self.n = n; self.d = d }

        static func make(_ n: Int, _ d: Int) throws -> Rat {
            guard d != 0 else { throw MathError.divideByZero }
            var n = n, d = d
            if d < 0 { guard let nn = Optional(n.multipliedReportingOverflow(by: -1)), !nn.overflow, let dd = Optional(d.multipliedReportingOverflow(by: -1)), !dd.overflow else { throw MathError.tooLarge }; n = nn.partialValue; d = dd.partialValue }
            let g = gcd(abs(n), d); return Rat(n: n / g, d: d / g)
        }
        static func gcd(_ a: Int, _ b: Int) -> Int { var (a, b) = (a, b); while b != 0 { (a, b) = (b, a % b) }; return max(a, 1) }
        var isZero: Bool { n == 0 }
        static func + (a: Rat, b: Rat) throws -> Rat {
            let l = a.n.multipliedReportingOverflow(by: b.d), r = b.n.multipliedReportingOverflow(by: a.d), dd = a.d.multipliedReportingOverflow(by: b.d)
            let s = l.partialValue.addingReportingOverflow(r.partialValue)
            guard !l.overflow, !r.overflow, !dd.overflow, !s.overflow else { throw MathError.tooLarge }
            return try make(s.partialValue, dd.partialValue)
        }
        static func * (a: Rat, b: Rat) throws -> Rat {
            let nn = a.n.multipliedReportingOverflow(by: b.n), dd = a.d.multipliedReportingOverflow(by: b.d)
            guard !nn.overflow, !dd.overflow else { throw MathError.tooLarge }
            return try make(nn.partialValue, dd.partialValue)
        }
        func negated() throws -> Rat { try Rat.make(-n, d) }
        func inverted() throws -> Rat { try Rat.make(d, n) }
    }

    enum MathError: Error { case divideByZero, tooLarge }

    // MARK: Polynomials

    struct Monomial: Hashable { var powers: [String: Int]
        func hash(into h: inout Hasher) { for k in powers.keys.sorted() { h.combine(k); h.combine(powers[k]) } }
        static func * (a: Monomial, b: Monomial) -> Monomial { Monomial(powers: a.powers.merging(b.powers, uniquingKeysWith: +)) }
    }

    struct Poly: Equatable {
        var terms: [Monomial: Rat] = [:]
        static let maxTerms = 3_000
        static func const(_ r: Rat) -> Poly { r.isZero ? Poly() : Poly(terms: [Monomial(powers: [:]): r]) }
        static func variable(_ v: String) -> Poly { Poly(terms: [Monomial(powers: [v: 1]): .one]) }
        var isZero: Bool { terms.isEmpty }
        var constantValue: Rat? { terms.isEmpty ? .zero : (terms.count == 1 && terms.keys.first!.powers.isEmpty ? terms.values.first! : nil) }

        func adding(_ o: Poly) throws -> Poly {
            var t = terms
            for (m, c) in o.terms { let s = try (t[m] ?? .zero) + c; if s.isZero { t[m] = nil } else { t[m] = s } }
            guard t.count <= Self.maxTerms else { throw MathError.tooLarge }
            return Poly(terms: t)
        }
        func negated() throws -> Poly { Poly(terms: try terms.mapValues { try $0.negated() }) }
        func multiplied(_ o: Poly) throws -> Poly {
            var t: [Monomial: Rat] = [:]
            for (m1, c1) in terms { for (m2, c2) in o.terms {
                let m = m1 * m2, c = try c1 * c2, s = try (t[m] ?? .zero) + c
                if s.isZero { t[m] = nil } else { t[m] = s }
            }
            if t.count > Self.maxTerms { throw MathError.tooLarge } }
            return Poly(terms: t)
        }
        func power(_ n: Int) throws -> Poly {
            var result = Poly.const(.one), base = self, e = n
            while e > 0 { if e & 1 == 1 { result = try result.multiplied(base) }; e >>= 1; if e > 0 { base = try base.multiplied(base) } }
            return result
        }
    }

    struct RFun {
        var num: Poly, den: Poly
        static func poly(_ p: Poly) -> RFun { RFun(num: p, den: .const(.one)) }
        func adding(_ o: RFun) throws -> RFun { RFun(num: try num.multiplied(o.den).adding(try o.num.multiplied(den)), den: try den.multiplied(o.den)) }
        func negated() throws -> RFun { RFun(num: try num.negated(), den: den) }
        func multiplied(_ o: RFun) throws -> RFun { RFun(num: try num.multiplied(o.num), den: try den.multiplied(o.den)) }
        func divided(_ o: RFun) throws -> RFun { guard !o.num.isZero else { throw MathError.divideByZero }; return RFun(num: try num.multiplied(o.den), den: try den.multiplied(o.num)) }
        func power(_ n: Int) throws -> RFun {
            if n >= 0 { return RFun(num: try num.power(n), den: try den.power(n)) }
            guard !num.isZero else { throw MathError.divideByZero }
            return RFun(num: try den.power(-n), den: try num.power(-n))
        }
        func equals(_ o: RFun) throws -> Bool { try num.multiplied(o.den) == o.num.multiplied(den) }
    }

    // MARK: Parser

    enum ParseFailure: Error {
        case unsupported(String), unreadable(String)
        func asResult(prefix: String) -> Result {
            switch self { case .unsupported(let m): .unsupported("\(prefix) uses \(m), which Braincell can’t check symbolically."); case .unreadable(let m): .unreadable("\(prefix) couldn’t be read: \(m).") }
        }
    }

    static func parse(_ raw: String) -> Swift.Result<RFun, ParseFailure> {
        guard raw.count <= 600 else { return .failure(.unreadable("it is too long")) }
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.contains("\\"), let plain = fromLatex(s.replacingOccurrences(of: "$", with: "")) { s = plain }
        s = s.replacingOccurrences(of: "**", with: "^").replacingOccurrences(of: "−", with: "-").replacingOccurrences(of: "×", with: "*").replacingOccurrences(of: "·", with: "*").replacingOccurrences(of: "÷", with: "/")
        guard !s.isEmpty else { return .failure(.unreadable("it is empty")) }
        var p = Parser(chars: Array(s))
        do {
            let f = try p.expression(depth: 0)
            p.skipSpaces()
            guard p.i == p.chars.count else { throw ParseFailure.unreadable("unexpected “\(p.chars[p.i])”") }
            return .success(f)
        } catch let e as ParseFailure { return .failure(e) }
        catch MathError.divideByZero { return .failure(.unreadable("it divides by zero")) }
        catch { return .failure(.unsupported("numbers or expressions that are too large")) }
    }

    static let functionNames: Set<String> = ["sin", "cos", "tan", "cot", "sec", "csc", "ln", "log", "exp", "sqrt", "abs", "arcsin", "arccos", "arctan", "sinh", "cosh", "tanh", "pi", "e", "floor", "ceil", "max", "min"]

    struct Parser {
        let chars: [Character]
        var i = 0
        init(chars: [Character]) { self.chars = chars }
        mutating func skipSpaces() { while i < chars.count, chars[i].isWhitespace { i += 1 } }
        var peek: Character? { mutating get { skipSpaces(); return i < chars.count ? chars[i] : nil } }

        mutating func expression(depth: Int) throws -> RFun {
            guard depth < 40 else { throw ParseFailure.unreadable("it is nested too deeply") }
            var v = try term(depth: depth)
            while let c = peek, c == "+" || c == "-" {
                i += 1
                let r = try term(depth: depth)
                v = try v.adding(c == "+" ? r : try r.negated())
            }
            return v
        }

        mutating func term(depth: Int) throws -> RFun {
            var v = try unary(depth: depth)
            while let c = peek {
                if c == "*" { i += 1; v = try v.multiplied(try unary(depth: depth)) }
                else if c == "/" { i += 1; v = try v.divided(try unary(depth: depth)) }
                else if c.isLetter || c == "(" { v = try v.multiplied(try unary(depth: depth)) }      // implicit multiplication: 2x, x(y+1), (a)(b)
                else { break }
            }
            return v
        }

        mutating func unary(depth: Int) throws -> RFun {
            if let c = peek, c == "-" || c == "+" { i += 1; let v = try unary(depth: depth + 1); return c == "-" ? try v.negated() : v }
            return try power(depth: depth)
        }

        mutating func power(depth: Int) throws -> RFun {
            let base = try atom(depth: depth)
            if let c = peek, c == "^" {
                i += 1
                let e = try unary(depth: depth + 1)
                guard e.den.constantValue == .one || (e.den.constantValue?.n ?? 0) != 0, let en = e.num.constantValue, let ed = e.den.constantValue,
                      let q = try? Rat.make(en.n * ed.d, en.d * ed.n), q.d == 1 else { throw ParseFailure.unsupported("a non-integer exponent") }
                guard abs(q.n) <= 24 else { throw ParseFailure.unsupported("a very large exponent") }
                return try base.power(q.n)
            }
            return base
        }

        mutating func atom(depth: Int) throws -> RFun {
            guard let c = peek else { throw ParseFailure.unreadable("the expression ends early") }
            if c == "(" {
                i += 1
                let v = try expression(depth: depth + 1)
                guard peek == ")" else { throw ParseFailure.unreadable("a bracket isn’t closed") }
                i += 1; return v
            }
            if c.isNumber || c == "." { return .poly(.const(try number())) }
            if c.isLetter {
                var word = ""; var j = i; while j < chars.count, chars[j].isLetter { word.append(chars[j]); j += 1 }
                if SymbolicMath.functionNames.contains(word.lowercased()) || word.lowercased() == "e" { throw ParseFailure.unsupported("“\(word)”") }
                guard word.allSatisfy({ $0.isASCII }) else { throw ParseFailure.unsupported("the symbol “\(word)”") }
                // One variable per atom, so "ab^2" is a·b² and letters in a row multiply (implicitly, in `term`).
                i += 1
                return .poly(.variable(String(c)))
            }
            if "|!=<>,{}[]".contains(c) { throw ParseFailure.unsupported("“\(c)”") }
            throw ParseFailure.unreadable("unexpected “\(c)”")
        }

        mutating func number() throws -> Rat {
            var intPart = "", frac = ""
            while i < chars.count, chars[i].isNumber { intPart.append(chars[i]); i += 1 }
            if i < chars.count, chars[i] == "." { i += 1; while i < chars.count, chars[i].isNumber { frac.append(chars[i]); i += 1 } }
            guard !(intPart.isEmpty && frac.isEmpty), intPart.count + frac.count <= 15, let n = Int(intPart + frac) else { throw ParseFailure.unreadable("a number is malformed or too large") }
            var d = 1; for _ in 0..<frac.count { d *= 10 }
            return try Rat.make(n, d)
        }
    }
}

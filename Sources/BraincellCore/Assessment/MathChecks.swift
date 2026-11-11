import Foundation

/// A structured problem the app can recompute without a model. Unsupported kinds stay unverified: nothing here parses prose.
public struct StructuredCheck: Codable, Hashable, Sendable {
    public var kind: String            // finitePMF | jointPMF | geometricMGF
    public var op: String?             // jointPMF: marginalX|marginalY|conditionalYgivenX|conditionalXgivenY|expectationX|expectationY|expectationXY|covariance|correlation|jointCDF|independent
                                       // geometricMGF: mgf|domainUpper|mean|variance
    public var probs: [Double]?
    public var xs: [Double]?
    public var ys: [Double]?
    public var table: [[Double]]?      // table[i][j] = P(X = xs[i], Y = ys[j])
    public var x: Double?, y: Double?
    public var p: Double?, t: Double?
    public var expected: Double?
    public var tolerance: Double?
    public init(kind: String, op: String? = nil, probs: [Double]? = nil, xs: [Double]? = nil, ys: [Double]? = nil, table: [[Double]]? = nil, x: Double? = nil, y: Double? = nil, p: Double? = nil, t: Double? = nil, expected: Double? = nil, tolerance: Double? = nil) {
        self.kind = kind; self.op = op; self.probs = probs; self.xs = xs; self.ys = ys; self.table = table; self.x = x; self.y = y; self.p = p; self.t = t; self.expected = expected; self.tolerance = tolerance
    }
}

public struct CheckOutcome: Sendable { public var evidence: ValidationEvidence; public var computed: Double? }

public enum MathChecks {
    static let sumTolerance = 1e-9

    public static func run(_ c: StructuredCheck) -> CheckOutcome {
        func out(_ r: EvidenceResult, _ detail: String, _ v: Double? = nil, inputs: String = "") -> CheckOutcome {
            CheckOutcome(evidence: ValidationEvidence(kind: .deterministic, check: "\(c.kind)\(c.op.map { ":\($0)" } ?? "")", inputs: inputs, result: r, detail: detail), computed: v)
        }
        func compare(_ v: Double, inputs: String) -> CheckOutcome {
            if let e = c.expected {
                let tol = c.tolerance ?? 1e-9
                return abs(v - e) <= max(tol, 1e-12) ? out(.passed, "computed \(v), stated \(e)", v, inputs: inputs) : out(.failed, "computed \(v) but the stated result is \(e)", v, inputs: inputs)
            }
            return out(.passed, "computed \(v)", v, inputs: inputs)
        }
        switch c.kind {
        case "finitePMF":
            guard let p = c.probs, !p.isEmpty else { return out(.failed, "needs probs") }
            guard p.allSatisfy({ $0.isFinite && $0 >= 0 }) else { return out(.failed, "probabilities must be finite and non-negative", inputs: "\(p)") }
            let s = p.reduce(0, +)
            return abs(s - 1) <= sumTolerance ? out(.passed, "sums to 1", s, inputs: "\(p)") : out(.failed, "sums to \(s), not 1", s, inputs: "\(p)")
        case "jointPMF": return joint(c, out, compare)
        case "geometricMGF":
            guard let p = c.p, p > 0, p < 1 else { return out(.failed, "p must be in (0,1)") }
            let q = 1 - p, domain = -log(q)
            switch c.op {
            case "domainUpper": return compare(domain, inputs: "p=\(p)")
            case "mean": return compare(1 / p, inputs: "p=\(p)")
            case "variance": return compare(q / (p * p), inputs: "p=\(p)")
            case "mgf":                       // support k = 1, 2, … (number of trials)
                guard let t = c.t else { return out(.failed, "needs t") }
                guard t < domain else { return out(.failed, "t = \(t) is outside the MGF domain t < \(domain)", inputs: "p=\(p), t=\(t)") }
                return compare(p * exp(t) / (1 - q * exp(t)), inputs: "p=\(p), t=\(t)")
            default: return out(.unsupported, "unsupported geometric operation")
            }
        default: return out(.unsupported, "no deterministic checker for “\(c.kind)”")
        }
    }

    private static func joint(_ c: StructuredCheck, _ out: (EvidenceResult, String, Double?, String) -> CheckOutcome, _ compare: (Double, String) -> CheckOutcome) -> CheckOutcome {
        func o(_ r: EvidenceResult, _ d: String, _ v: Double? = nil) -> CheckOutcome { out(r, d, v, "") }
        guard let xs = c.xs, let ys = c.ys, let t = c.table, t.count == xs.count, t.allSatisfy({ $0.count == ys.count }), !xs.isEmpty, !ys.isEmpty else { return o(.failed, "table shape must match xs × ys") }
        guard t.joined().allSatisfy({ $0.isFinite && $0 >= 0 }) else { return o(.failed, "probabilities must be finite and non-negative") }
        let total = t.joined().reduce(0, +)
        guard abs(total - 1) <= sumTolerance else { return o(.failed, "joint table sums to \(total), not 1", total) }
        func px(_ i: Int) -> Double { t[i].reduce(0, +) }
        func py(_ j: Int) -> Double { t.reduce(0) { $0 + $1[j] } }
        func ix(_ v: Double?) -> Int? { v.flatMap { v in xs.firstIndex { abs($0 - v) < 1e-12 } } }
        func iy(_ v: Double?) -> Int? { v.flatMap { v in ys.firstIndex { abs($0 - v) < 1e-12 } } }
        let ex = xs.enumerated().reduce(0.0) { $0 + $1.element * px($1.offset) }
        let ey = ys.enumerated().reduce(0.0) { $0 + $1.element * py($1.offset) }
        var exy = 0.0
        for (i, xv) in xs.enumerated() { for (j, yv) in ys.enumerated() { exy += xv * yv * t[i][j] } }
        let cov = exy - ex * ey
        let varX = xs.enumerated().reduce(0.0) { $0 + $1.element * $1.element * px($1.offset) } - ex * ex
        let varY = ys.enumerated().reduce(0.0) { $0 + $1.element * $1.element * py($1.offset) } - ey * ey
        switch c.op {
        case "marginalX": guard let i = ix(c.x) else { return o(.failed, "x is not in the support") }; return compare(px(i), "x=\(c.x!)")
        case "marginalY": guard let j = iy(c.y) else { return o(.failed, "y is not in the support") }; return compare(py(j), "y=\(c.y!)")
        case "conditionalYgivenX":
            guard let i = ix(c.x), let j = iy(c.y) else { return o(.failed, "(x, y) is not in the support") }
            guard px(i) > 0 else { return o(.failed, "conditioning event has probability 0") }
            return compare(t[i][j] / px(i), "y=\(c.y!)|x=\(c.x!)")
        case "conditionalXgivenY":
            guard let i = ix(c.x), let j = iy(c.y) else { return o(.failed, "(x, y) is not in the support") }
            guard py(j) > 0 else { return o(.failed, "conditioning event has probability 0") }
            return compare(t[i][j] / py(j), "x=\(c.x!)|y=\(c.y!)")
        case "expectationX": return compare(ex, "")
        case "expectationY": return compare(ey, "")
        case "expectationXY": return compare(exy, "")
        case "covariance": return compare(cov, "")
        case "correlation":
            guard varX > 1e-15, varY > 1e-15 else { return o(.failed, "correlation undefined: a variance is zero") }
            return compare(cov / (varX * varY).squareRoot(), "")
        case "jointCDF":
            guard let x = c.x, let y = c.y else { return o(.failed, "needs x and y") }
            var s = 0.0
            for (i, xv) in xs.enumerated() where xv <= x { for (j, yv) in ys.enumerated() where yv <= y { s += t[i][j] } }
            return compare(s, "x=\(x), y=\(y)")
        case "independent":
            var ok = true
            for i in 0..<xs.count { for j in 0..<ys.count where abs(t[i][j] - px(i) * py(j)) > 1e-9 { ok = false } }
            return compare(ok ? 1 : 0, "")
        default: return o(.unsupported, "unsupported joint operation")
        }
    }
}

public enum IntervalChecks {
    public static func round(_ x: Double, decimals: Int?) -> Double {
        guard let d = decimals, (0...12).contains(d) else { return x }
        let f = pow(10.0, Double(d)); return (x * f).rounded(.toNearestOrAwayFromZero) / f
    }

    static func overlap(_ a: IntervalChoice, _ b: IntervalChoice) -> Bool {
        // Intersection of [a] and [b] is non-empty?
        let lo: (Double, Bool)? = { switch (a.lower, b.lower) { case (nil, nil): nil; case (let x?, nil): (x, a.lowerClosed); case (nil, let y?): (y, b.lowerClosed)
            case (let x?, let y?): x > y ? (x, a.lowerClosed) : y > x ? (y, b.lowerClosed) : (x, a.lowerClosed && b.lowerClosed) } }()
        let hi: (Double, Bool)? = { switch (a.upper, b.upper) { case (nil, nil): nil; case (let x?, nil): (x, a.upperClosed); case (nil, let y?): (y, b.upperClosed)
            case (let x?, let y?): x < y ? (x, a.upperClosed) : y < x ? (y, b.upperClosed) : (x, a.upperClosed && b.upperClosed) } }()
        guard let l = lo, let h = hi else { return true }
        return l.0 < h.0 || (l.0 == h.0 && l.1 && h.1)
    }

    /// Structural and numerical checks of interval choices. Returns blocking problems and evidence; never parses the displayed choice text.
    public static func validate(choiceIds: [String], correctId: String?, intervals: [IntervalChoice], exactResult: Double?, decimals: Int?, resultIsComputed: Bool = false) -> (problems: [String], evidence: [ValidationEvidence]) {
        var problems: [String] = [], ev: [ValidationEvidence] = []
        let ids = Set(choiceIds)
        for iv in intervals {
            if !ids.contains(iv.choiceId) { problems.append("interval refers to unknown choice “\(iv.choiceId)”") }
            if let l = iv.lower, !l.isFinite { problems.append("interval bounds must be finite or null") }
            if let u = iv.upper, !u.isFinite { problems.append("interval bounds must be finite or null") }
            if let l = iv.lower, let u = iv.upper, l > u || (l == u && !(iv.lowerClosed && iv.upperClosed)) { problems.append("interval for “\(iv.choiceId)” is empty or reversed") }
        }
        if Set(intervals.map(\.choiceId)).count != intervals.count { problems.append("a choice has more than one interval") }
        if Set(intervals.map(\.choiceId)) != ids { problems.append("every choice needs exactly one interval when intervals are used") }
        for i in 0..<intervals.count { for j in (i + 1)..<max(i + 1, intervals.count) where overlap(intervals[i], intervals[j]) { problems.append("intervals for “\(intervals[i].choiceId)” and “\(intervals[j].choiceId)” overlap") } }
        ev.append(ValidationEvidence(kind: .consistency, check: "interval structure", inputs: "\(intervals.count) intervals", result: problems.isEmpty ? .passed : .failed, detail: problems.joined(separator: "; ")))
        guard problems.isEmpty else { return (problems, ev) }
        guard let r = exactResult else {
            ev.append(ValidationEvidence(kind: .unresolved, check: "interval membership", result: .skipped, detail: "no numeric result supplied, so which interval is correct is not independently confirmed")); return (problems, ev)
        }
        let v = round(r, decimals: decimals)
        let hits = intervals.filter { $0.contains(v) }
        if hits.count != 1 { problems.append(hits.isEmpty ? "the result \(v) lies in no interval" : "the result \(v) lies in \(hits.count) intervals") }
        else if let c = correctId, hits[0].choiceId != c { problems.append("the result \(v) lies in “\(hits[0].choiceId)”, but “\(c)” is marked correct") }
        ev.append(ValidationEvidence(kind: resultIsComputed ? .deterministic : .consistency, check: "interval membership", inputs: "result=\(r), rounded=\(v), decimals=\(decimals.map(String.init) ?? "none")", result: problems.isEmpty ? .passed : .failed, detail: problems.joined(separator: "; ")))
        return (problems, ev)
    }
}

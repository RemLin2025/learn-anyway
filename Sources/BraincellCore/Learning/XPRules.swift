import Foundation

/// XP is motivation, not mastery: nothing here reads or writes mastery estimates.
public enum XPRules {
    /// Meaningful completed work. Repeats of the same question pay less and stop after the third try.
    public static func participation(difficulty d: Int, attemptNumber n: Int) -> Int {
        let base = 5 + 2 * min(5, max(1, d))
        let mult: Double = n <= 1 ? 1 : (n == 2 ? 0.5 : (n == 3 ? 0.25 : 0))
        return Int((Double(base) * mult).rounded())
    }

    /// Bonus for the first correct, unassisted, *trusted* answer to a question (once per question, ever).
    public static func correctness(difficulty d: Int) -> Int { 4 + 3 * min(5, max(1, d)) }

    public static func level(forXP xp: Int) -> Int { 1 + Int((Double(max(0, xp)) / 25).squareRoot()) }
    public static func xpForLevel(_ l: Int) -> Int { max(0, (l - 1) * (l - 1) * 25) }

    /// Splits `amount` across `n` recipients; the remainder goes to the first ones so the parts always sum to `amount`.
    public static func split(_ amount: Int, among n: Int) -> [Int] {
        guard n > 0 else { return [] }
        let q = amount / n, r = amount - q * n
        return (0..<n).map { q + ($0 < abs(r) ? (r > 0 ? 1 : -1) : 0) }
    }

    /// Splits `amount` (negative allowed) in proportion to `weights`, summing exactly to `amount`.
    public static func proportional(_ amount: Int, weights: [Int]) -> [Int] {
        let total = weights.reduce(0, +)
        guard total > 0 else { return split(amount, among: weights.count) }
        var parts = weights.map { Int((Double(amount) * Double($0) / Double(total)).rounded(.towardZero)) }
        var rest = amount - parts.reduce(0, +)
        var i = 0
        while rest != 0, !parts.isEmpty { parts[i % parts.count] += rest > 0 ? 1 : -1; rest += rest > 0 ? -1 : 1; i += 1 }
        return parts
    }
}

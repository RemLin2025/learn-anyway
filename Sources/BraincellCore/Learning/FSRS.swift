import Foundation

// FSRS-6 spaced-repetition scheduler.
//
// Ported from py-fsrs (https://github.com/open-spaced-repetition/py-fsrs, MIT License,
// Copyright (c) 2022 Open Spaced Repetition), commit 9446cb06, `fsrs/scheduler.py`.
// Default parameters and every formula below follow that source. Differences, all deliberate:
//  * fuzzing is not implemented, so scheduling is deterministic and testable;
//  * dates are `Date`; elapsed days use whole days (floor), as `timedelta.days` does;
//  * `round` is banker's rounding, matching Python 3.
// See docs/SPACED_REPETITION.md for how this was verified (and what was not).

public enum FSRSRating: Int, Codable, Sendable, CaseIterable {
    case again = 1, hard, good, easy

    public var label: String { ["Again", "Hard", "Good", "Easy"][rawValue - 1] }

    public init?(label: String) {
        guard let r = Self.allCases.first(where: { $0.label.lowercased() == label.lowercased() }) else { return nil }
        self = r
    }
}

public enum FSRSState: Int, Codable, Sendable { case learning = 1, review, relearning }

public struct FSRSCard: Codable, Sendable, Equatable {
    public var state: FSRSState
    public var step: Int?
    public var stability: Double?
    public var difficulty: Double?
    public var due: Date
    public var lastReview: Date?

    /// A brand-new card, due immediately.
    public static func new(now: Date) -> FSRSCard { FSRSCard(state: .learning, step: 0, stability: nil, difficulty: nil, due: now, lastReview: nil) }
}

public struct FSRSScheduler: Sendable {
    public static let version = "fsrs-6 (py-fsrs 9446cb06, no fuzzing)"
    public static let defaultDecay = 0.1542
    public static let defaultParameters: [Double] = [
        0.212, 1.2931, 2.3065, 8.2956, 6.4133, 0.8334, 3.0194, 0.001, 1.8722, 0.1666, 0.796, 1.4835,
        0.0614, 0.2629, 1.6483, 0.6014, 1.8729, 0.5425, 0.0912, 0.0658, defaultDecay,
    ]
    static let stabilityMin = 0.001
    static let lower: [Double] = [stabilityMin, stabilityMin, stabilityMin, stabilityMin, 1.0, 0.001, 0.001, 0.001, 0.0, 0.0, 0.001, 0.001, 0.001, 0.001, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 0.1]
    static let upper: [Double] = [100, 100, 100, 100, 10, 4, 4, 0.75, 4.5, 0.8, 3.5, 5, 0.25, 0.9, 4, 1, 6, 2, 2, 0.8, 0.8]

    public let parameters: [Double]
    public let desiredRetention: Double
    public let learningSteps: [TimeInterval]
    public let relearningSteps: [TimeInterval]
    public let maximumInterval: Int
    let decay: Double
    let factor: Double

    public init?(parameters: [Double] = defaultParameters, desiredRetention: Double = 0.9,
                 learningSteps: [TimeInterval] = [60, 600], relearningSteps: [TimeInterval] = [600], maximumInterval: Int = 36_500) {
        guard parameters.count == Self.lower.count,
              zip(parameters, zip(Self.lower, Self.upper)).allSatisfy({ $0 >= $1.0 && $0 <= $1.1 }),
              (0.5...0.99).contains(desiredRetention) else { return nil }
        self.parameters = parameters; self.desiredRetention = desiredRetention
        self.learningSteps = learningSteps; self.relearningSteps = relearningSteps; self.maximumInterval = maximumInterval
        decay = -parameters[20]
        factor = pow(0.9, 1 / decay) - 1
    }

    // MARK: Public API

    /// Predicted probability of recalling the card at `now`.
    public func retrievability(_ c: FSRSCard, at now: Date) -> Double {
        guard let last = c.lastReview, let s = c.stability else { return 0 }
        return pow(1 + factor * elapsedDays(from: last, to: now) / s, decay)
    }

    public func review(_ card: FSRSCard, rating: FSRSRating, at now: Date) -> FSRSCard {
        var c = card
        let daysSince = c.lastReview.map { elapsedDays(from: $0, to: now) }
        var interval: TimeInterval

        switch c.state {
        case .learning:
            if c.stability == nil || c.difficulty == nil {
                c.stability = initialStability(rating); c.difficulty = initialDifficulty(rating, clamp: true)
            } else if let d = daysSince, d < 1 {
                c.stability = shortTermStability(c.stability!, rating); c.difficulty = nextDifficulty(c.difficulty!, rating)
            } else {
                c.stability = nextStability(c.difficulty!, c.stability!, retrievability(c, at: now), rating)
                c.difficulty = nextDifficulty(c.difficulty!, rating)
            }
            (c, interval) = advanceSteps(c, rating, steps: learningSteps)
        case .review:
            if let d = daysSince, d < 1 { c.stability = shortTermStability(c.stability!, rating) }
            else { c.stability = nextStability(c.difficulty!, c.stability!, retrievability(c, at: now), rating) }
            c.difficulty = nextDifficulty(c.difficulty!, rating)
            if rating == .again, !relearningSteps.isEmpty {
                c.state = .relearning; c.step = 0; interval = relearningSteps[0]
            } else { interval = nextIntervalDays(c.stability!) * 86_400 }
        case .relearning:
            if let d = daysSince, d < 1 {
                c.stability = shortTermStability(c.stability!, rating); c.difficulty = nextDifficulty(c.difficulty!, rating)
            } else {
                c.stability = nextStability(c.difficulty!, c.stability!, retrievability(c, at: now), rating)
                c.difficulty = nextDifficulty(c.difficulty!, rating)
            }
            (c, interval) = advanceSteps(c, rating, steps: relearningSteps)
        }
        c.due = now.addingTimeInterval(interval)
        c.lastReview = now
        return c
    }

    // MARK: Steps

    /// Learning / relearning step logic shared by both states (identical in the reference).
    private func advanceSteps(_ card: FSRSCard, _ rating: FSRSRating, steps: [TimeInterval]) -> (FSRSCard, TimeInterval) {
        var c = card
        func graduate() -> TimeInterval { c.state = .review; c.step = nil; return nextIntervalDays(c.stability!) * 86_400 }
        let step = c.step ?? 0
        if steps.isEmpty || (step >= steps.count && rating != .again) { let i = graduate(); return (c, i) }
        switch rating {
        case .again: c.step = 0; return (c, steps[0])
        case .hard:
            if step == 0 && steps.count == 1 { return (c, steps[0] * 1.5) }
            if step == 0 && steps.count >= 2 { return (c, (steps[0] + steps[1]) / 2) }
            return (c, steps[step])
        case .good:
            if step + 1 == steps.count { let i = graduate(); return (c, i) }
            c.step = step + 1; return (c, steps[step + 1])
        case .easy: let i = graduate(); return (c, i)
        }
    }

    // MARK: Formulas (py-fsrs `_…` methods)

    private func elapsedDays(from: Date, to: Date) -> Double { max(0, (to.timeIntervalSince(from) / 86_400).rounded(.down)) }
    private func clampD(_ d: Double) -> Double { min(max(d, 1), 10) }
    private func clampS(_ s: Double) -> Double { max(s, Self.stabilityMin) }

    private func initialStability(_ r: FSRSRating) -> Double { clampS(parameters[r.rawValue - 1]) }
    private func initialDifficulty(_ r: FSRSRating, clamp: Bool) -> Double {
        let d = parameters[4] - exp(parameters[5] * Double(r.rawValue - 1)) + 1
        return clamp ? clampD(d) : d
    }

    private func nextIntervalDays(_ stability: Double) -> Double {
        let raw = (stability / factor) * (pow(desiredRetention, 1 / decay) - 1)
        return Double(min(max(Int(raw.rounded(.toNearestOrEven)), 1), maximumInterval))
    }

    private func shortTermStability(_ s: Double, _ r: FSRSRating) -> Double {
        var inc = exp(parameters[17] * (Double(r.rawValue) - 3 + parameters[18])) * pow(s, -parameters[19])
        if r != .again { inc = max(inc, 1) }
        return clampS(s * inc)
    }

    private func nextDifficulty(_ d: Double, _ r: FSRSRating) -> Double {
        let arg1 = initialDifficulty(.easy, clamp: false)
        let delta = -(parameters[6] * Double(r.rawValue - 3))
        let arg2 = d + (10 - d) * delta / 9
        return clampD(parameters[7] * arg1 + (1 - parameters[7]) * arg2)
    }

    private func nextStability(_ d: Double, _ s: Double, _ retr: Double, _ r: FSRSRating) -> Double {
        clampS(r == .again ? forgetStability(d, s, retr) : recallStability(d, s, retr, r))
    }

    private func forgetStability(_ d: Double, _ s: Double, _ retr: Double) -> Double {
        let long = parameters[11] * pow(d, -parameters[12]) * (pow(s + 1, parameters[13]) - 1) * exp((1 - retr) * parameters[14])
        let short = s / exp(parameters[17] * parameters[18])
        return min(long, short)
    }

    private func recallStability(_ d: Double, _ s: Double, _ retr: Double, _ r: FSRSRating) -> Double {
        let hard = r == .hard ? parameters[15] : 1, easy = r == .easy ? parameters[16] : 1
        return s * (1 + exp(parameters[8]) * (11 - d) * pow(s, -parameters[9]) * (exp((1 - retr) * parameters[10]) - 1) * hard * easy)
    }
}

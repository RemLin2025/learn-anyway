import Foundation

public struct EvidenceInput: Sendable, Equatable {
    public var dimension: MasteryDimension
    public var score: Double
    public var difficulty: Int
    public var hintsUsed: Int
    public var attemptNumber: Int
    public var trust: GradeTrust
    public var occurredAt: Date
    public init(dimension: MasteryDimension, score: Double, difficulty: Int, hintsUsed: Int, attemptNumber: Int, trust: GradeTrust, occurredAt: Date) {
        self.dimension = dimension; self.score = score; self.difficulty = difficulty; self.hintsUsed = hintsUsed
        self.attemptNumber = attemptNumber; self.trust = trust; self.occurredAt = occurredAt
    }
}

public enum ConfidenceLevel: String, Codable, Sendable, Comparable {
    case unknown, preliminary, moderate, strong
    public static func < (a: Self, b: Self) -> Bool { order(a) < order(b) }
    private static func order(_ c: Self) -> Int { switch c { case .unknown: 0; case .preliminary: 1; case .moderate: 2; case .strong: 3 } }
    public var label: String { rawValue.capitalized }
}

public struct DimensionEstimate: Codable, Sendable, Equatable {
    public var dimension: MasteryDimension
    /// nil = no evidence. Never 0 for "unassessed".
    public var estimate: Double?
    public var weight: Double
    public var evidenceCount: Int
    public var confidence: ConfidenceLevel
}

public struct SkillMastery: Sendable, Equatable {
    public var skillId: UUID
    public var dimensions: [DimensionEstimate]
    public var overall: Double?
    public var overallWeight: Double
    public var confidence: ConfidenceLevel
    public var evidenceCount: Int
    /// Share of evidence weight that came from trusted machine grading or AI grading (vs provisional / self-reported).
    public var evidenceQuality: Double?
    public var estimatorVersion: String

    public var isUnknown: Bool { confidence == .unknown }
}

/// Replaceable: anything that turns evidence into a `SkillMastery`. The stored snapshots carry the version.
public protocol MasteryEstimator: Sendable {
    var version: String { get }
    func estimate(skillId: UUID, evidence: [EvidenceInput], now: Date) -> SkillMastery
}

/// heuristic-v1 — deterministic, documented in docs/MASTERY.md.
///
/// Each piece of evidence gets a weight  w = difficulty × independence × novelty × reliability × recency.
/// A dimension's estimate is the weight-averaged score; its confidence comes from the *total weight*, not the
/// number of questions, so a single easy, provisional answer stays "Preliminary" however it went.
public struct HeuristicMasteryEstimator: MasteryEstimator {
    public let version = "heuristic-v1"
    public static let halfLifeDays = 60.0
    /// What-if knobs for `CalibrationService`; the app always uses the defaults.
    public var halfLife: Double
    public var weighsTrust: Bool
    public init(halfLife: Double = HeuristicMasteryEstimator.halfLifeDays, weighsTrust: Bool = true) { self.halfLife = halfLife; self.weighsTrust = weighsTrust }

    static func difficultyWeight(_ d: Int) -> Double { 0.6 + 0.2 * Double(min(5, max(1, d)) - 1) }          // 0.6 … 1.4
    static func independence(hints: Int) -> Double { switch hints { case 0: 1.0; case 1: 0.7; case 2: 0.5; default: 0.35 } }
    static func novelty(attemptNumber n: Int) -> Double { max(0.15, pow(0.5, Double(max(1, n) - 1))) }        // repeats prove less
    static func reliability(_ t: GradeTrust) -> Double { switch t { case .trusted: 1.0; case .aiGraded: 0.85; case .selfReported: 0.6; case .provisional: 0.5 } }
    static func recency(from: Date, now: Date, halfLife: Double = halfLifeDays) -> Double {
        let days = max(0, now.timeIntervalSince(from) / 86_400)
        return max(0.2, pow(0.5, days / halfLife))
    }

    public static func weight(_ e: EvidenceInput, now: Date) -> Double { HeuristicMasteryEstimator().weight(e, now: now) }

    func weight(_ e: EvidenceInput, now: Date) -> Double {
        Self.difficultyWeight(e.difficulty) * Self.independence(hints: e.hintsUsed) * Self.novelty(attemptNumber: e.attemptNumber)
            * (weighsTrust ? Self.reliability(e.trust) : 1) * Self.recency(from: e.occurredAt, now: now, halfLife: halfLife)
    }

    /// Total weight → level. One verified medium question ≈ 1.0 (still Preliminary).
    public static func confidence(weight w: Double) -> ConfidenceLevel {
        switch w { case ..<0.0001: .unknown; case ..<1.5: .preliminary; case ..<4: .moderate; default: .strong }
    }

    public func estimate(skillId: UUID, evidence: [EvidenceInput], now: Date) -> SkillMastery {
        var dims: [DimensionEstimate] = []
        var totalW = 0.0, totalS = 0.0, qualityW = 0.0
        for d in MasteryDimension.allCases {
            let items = evidence.filter { $0.dimension == d }
            let ws = items.map { weight($0, now: now) }
            let w = ws.reduce(0, +)
            let est = w > 0 ? zip(items, ws).reduce(0.0) { $0 + $1.0.score * $1.1 } / w : nil
            dims.append(DimensionEstimate(dimension: d, estimate: est, weight: w, evidenceCount: items.count, confidence: Self.confidence(weight: w)))
            totalW += w; totalS += (est ?? 0) * w
            qualityW += zip(items, ws).filter { $0.0.trust == .trusted || $0.0.trust == .aiGraded }.reduce(0) { $0 + $1.1 }
        }
        return SkillMastery(skillId: skillId, dimensions: dims, overall: totalW > 0 ? totalS / totalW : nil, overallWeight: totalW,
                            confidence: Self.confidence(weight: totalW), evidenceCount: evidence.count,
                            evidenceQuality: totalW > 0 ? qualityW / totalW : nil, estimatorVersion: version)
    }
}

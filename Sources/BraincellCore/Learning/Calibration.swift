import Foundation
import GRDB

/// One walk-forward check of the mastery estimator: before each answer, what did the evidence *so far* predict?
public struct CalibrationBin: Sendable, Equatable {
    public var lower: Double, upper: Double
    public var count: Int
    public var meanPredicted: Double, meanActual: Double
}

public struct CalibrationScore: Sendable, Equatable {
    public var name: String
    /// Mean squared error between predicted and actual score (0 = perfect, lower is better).
    public var brier: Double
}

public struct CalibrationReport: Sendable, Equatable {
    public static let minimumPredictions = 30
    public var predictions: Int
    public var skills: Int
    public var current: CalibrationScore?
    /// Predicting each answer from the plain average of earlier answers on the skill.
    public var baseline: CalibrationScore?
    public var bins: [CalibrationBin]
    /// Mean(predicted − actual): positive = the estimator is too optimistic.
    public var bias: Double?
    public var variants: [CalibrationScore]
    /// Only set when there is enough data and a variant beats the current estimator by a clear margin. Never applied automatically.
    public var suggestion: String?
    public var enoughData: Bool { predictions >= Self.minimumPredictions }
}

public enum Calibration {
    struct Pair { var predicted: Double, actual: Double, baseline: Double }

    /// Walk forward through each skill's evidence in time order; each answer is predicted only from earlier answers.
    static func pairs(series: [[EvidenceInput]], estimator: HeuristicMasteryEstimator, maxPerSkill: Int = 200) -> [Pair] {
        var out: [Pair] = []
        for raw in series {
            let ev = Array(raw.sorted { $0.occurredAt < $1.occurredAt }.suffix(maxPerSkill))
            guard ev.count >= 2 else { continue }
            for k in 1..<ev.count {
                let prior = Array(ev[..<k]), target = ev[k]
                let m = estimator.estimate(skillId: UUID(), evidence: prior, now: target.occurredAt)
                let dim = m.dimensions.first { $0.dimension == target.dimension }?.estimate
                guard let p = dim ?? m.overall else { continue }
                out.append(Pair(predicted: p, actual: target.score, baseline: prior.map(\.score).reduce(0, +) / Double(prior.count)))
            }
        }
        return out
    }

    static func brier(_ ps: [Double], _ actual: [Double]) -> Double { zip(ps, actual).reduce(0) { $0 + ($1.0 - $1.1) * ($1.0 - $1.1) } / Double(max(1, ps.count)) }

    public static func report(series: [[EvidenceInput]]) -> CalibrationReport {
        let base = pairs(series: series, estimator: HeuristicMasteryEstimator())
        guard !base.isEmpty else {
            return CalibrationReport(predictions: 0, skills: series.filter { $0.count >= 2 }.count, current: nil, baseline: nil, bins: [], bias: nil, variants: [], suggestion: nil)
        }
        let actual = base.map(\.actual)
        let current = CalibrationScore(name: "heuristic-v1 (in use)", brier: brier(base.map(\.predicted), actual))
        var bins: [CalibrationBin] = []
        for i in 0..<5 {
            let lo = Double(i) / 5, hi = Double(i + 1) / 5
            let inBin = base.filter { $0.predicted >= lo && ($0.predicted < hi || (i == 4 && $0.predicted <= 1)) }
            guard !inBin.isEmpty else { continue }
            bins.append(CalibrationBin(lower: lo, upper: hi, count: inBin.count, meanPredicted: inBin.map(\.predicted).reduce(0, +) / Double(inBin.count),
                                       meanActual: inBin.map(\.actual).reduce(0, +) / Double(inBin.count)))
        }
        let candidates: [(String, HeuristicMasteryEstimator)] = [
            ("Faster forgetting (30-day half-life)", HeuristicMasteryEstimator(halfLife: 30)),
            ("Slower forgetting (120-day half-life)", HeuristicMasteryEstimator(halfLife: 120)),
            ("Ignore how the grade was obtained", HeuristicMasteryEstimator(weighsTrust: false)),
        ]
        let variants = candidates.compactMap { name, est -> CalibrationScore? in
            let p = pairs(series: series, estimator: est)
            return p.isEmpty ? nil : CalibrationScore(name: name, brier: brier(p.map(\.predicted), p.map(\.actual)))
        }
        var suggestion: String?
        if base.count >= CalibrationReport.minimumPredictions, let best = variants.min(by: { $0.brier < $1.brier }), current.brier - best.brier >= 0.01 {
            suggestion = "“\(best.name)” predicted your answers better (error \(String(format: "%.3f", best.brier)) vs \(String(format: "%.3f", current.brier))). Nothing was changed."
        }
        return CalibrationReport(predictions: base.count, skills: series.filter { $0.count >= 2 }.count, current: current,
                                 baseline: CalibrationScore(name: "Plain average", brier: brier(base.map(\.baseline), actual)), bins: bins,
                                 bias: zip(base.map(\.predicted), actual).reduce(0) { $0 + $1.0 - $1.1 } / Double(base.count),
                                 variants: variants, suggestion: suggestion)
    }
}

extension InsightsService {
    /// Walk-forward calibration of the mastery estimator over the current (non-superseded) evidence.
    public func calibration(courseId: UUID? = nil) throws -> CalibrationReport {
        let rows = try db.read { d in
            try LearningEvidence.filter(Column("supersededAt") == nil && (courseId == nil || Column("courseId") == courseId)).fetchAll(d)
        }
        let series = Dictionary(grouping: rows, by: \.skillId).values.map { group in
            group.map { EvidenceInput(dimension: $0.dimension, score: $0.score, difficulty: $0.difficulty, hintsUsed: $0.hintsUsed,
                                      attemptNumber: $0.attemptNumber, trust: $0.trust, occurredAt: $0.occurredAt) }
        }
        return Calibration.report(series: Array(series))
    }
}

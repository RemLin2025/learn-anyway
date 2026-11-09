import Testing
import Foundation
@testable import BraincellCore

@Suite struct CalibrationTests {
    let t0 = Date(timeIntervalSince1970: 1_700_000_000)
    func ev(_ score: Double, day: Double, dim: MasteryDimension = .recall) -> EvidenceInput {
        EvidenceInput(dimension: dim, score: score, difficulty: 3, hintsUsed: 0, attemptNumber: 1, trust: .trusted, occurredAt: t0.addingTimeInterval(day * 86_400))
    }
    func series(_ scores: [Double]) -> [EvidenceInput] { scores.enumerated().map { ev($1, day: Double($0)) } }

    @Test func emptyAndSingleAnswerGiveNoNumbers() {
        #expect(Calibration.report(series: []).current == nil)
        let one = Calibration.report(series: [series([1])])
        #expect(one.predictions == 0 && one.current == nil && !one.enoughData && one.suggestion == nil)
    }

    @Test func steadyLearnerIsPredictedWell() {
        let r = Calibration.report(series: [series(Array(repeating: 1, count: 20)), series(Array(repeating: 0, count: 20))])
        #expect(r.predictions == 38)
        #expect((r.current?.brier ?? 1) < 0.001)
        #expect(abs(r.bias ?? 1) < 0.001)
        #expect(r.bins.reduce(0) { $0 + $1.count } == r.predictions)
    }

    @Test func fewPredictionsNeverProduceASuggestion() {
        let r = Calibration.report(series: [series([1, 0, 1, 0, 1, 0, 1, 0])])
        #expect(r.predictions == 7 && !r.enoughData && r.suggestion == nil)
    }

    @Test func eachAnswerIsPredictedOnlyFromEarlierOnes() {
        // Changing the final answer changes only the final prediction's error, never the earlier pairs.
        let a = Calibration.pairs(series: [series([1, 1, 0, 1, 0])], estimator: HeuristicMasteryEstimator())
        let b = Calibration.pairs(series: [series([1, 1, 0, 1, 1])], estimator: HeuristicMasteryEstimator())
        #expect(a.count == 4 && b.count == 4)
        #expect(zip(a, b).map { $0.0.predicted == $0.1.predicted }.allSatisfy { $0 })
        #expect(a.last?.actual == 0 && b.last?.actual == 1)
    }

    @Test func orderingIsByTimeNotByArrayPosition() {
        let s = series([1, 0, 1, 0, 1, 1])
        #expect(Calibration.report(series: [s]) == Calibration.report(series: [s.reversed()]))
    }

    @Test func variantsAreReportedAndSuggestionRequiresAClearWin() {
        // A learner who forgets: perfect early, then a long gap and failure. Faster forgetting should score better.
        var s: [EvidenceInput] = []
        for rep in 0..<12 {
            let base = Double(rep) * 200
            s += (0..<3).map { ev(1, day: base + Double($0)) }
            s.append(ev(0, day: base + 150))
        }
        let r = Calibration.report(series: [s])
        #expect(r.enoughData && r.variants.count == 3)
        if let sug = r.suggestion { #expect(sug.contains("Nothing was changed")) }
        // Applying a suggestion is never automatic: the production estimator keeps its defaults.
        #expect(HeuristicMasteryEstimator().halfLife == 60 && HeuristicMasteryEstimator().weighsTrust)
    }

    @Test func defaultEstimatorBehaviourIsUnchangedByTheKnobs() {
        let e = ev(1, day: 0)
        #expect(HeuristicMasteryEstimator.weight(e, now: t0.addingTimeInterval(60 * 86_400)) == HeuristicMasteryEstimator().weight(e, now: t0.addingTimeInterval(60 * 86_400)))
    }
}

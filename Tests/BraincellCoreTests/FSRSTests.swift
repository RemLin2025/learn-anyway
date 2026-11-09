import Testing
import Foundation
@testable import BraincellCore

@Suite struct FSRSTests {
    static let fixtureDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Fixtures")
    static let iso = ISO8601DateFormatter()
    static let t0 = iso.date(from: "2026-01-01T00:00:00+00:00")!

    func scheduler() -> FSRSScheduler { FSRSScheduler()! }

    /// Replays every scenario from a fixture file and compares each step with the stored values.
    func replay(_ file: String) throws -> Int {
        let url = Self.fixtureDir.appendingPathComponent(file)
        let json = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
        let s = scheduler()
        var compared = 0
        for sc in json["scenarios"] as! [[String: Any]] {
            var card = FSRSCard.new(now: Self.t0)
            let name = sc["name"] as! String
            for (i, step) in (sc["steps"] as! [[String: Any]]).enumerated() {
                let at = Self.iso.date(from: step["at"] as! String)!
                if let r = step["retrievability_before"] as? Double {
                    #expect(abs(s.retrievability(card, at: at) - r) < 1e-9, "\(file) \(name)[\(i)] retrievability")
                }
                card = s.review(card, rating: FSRSRating(rawValue: step["rating"] as! Int)!, at: at)
                #expect(card.state.rawValue == step["state"] as! Int, "\(file) \(name)[\(i)] state")
                #expect(card.step == step["step"] as? Int, "\(file) \(name)[\(i)] step")
                let st = step["stability"] as! Double, df = step["difficulty"] as! Double
                #expect(abs(card.stability! - st) <= 1e-9 * max(1, st), "\(file) \(name)[\(i)] stability \(card.stability!) vs \(st)")
                #expect(abs(card.difficulty! - df) <= 1e-9 * max(1, df), "\(file) \(name)[\(i)] difficulty")
                let due = Self.iso.date(from: step["due"] as! String)!
                #expect(abs(card.due.timeIntervalSince(due)) < 1, "\(file) \(name)[\(i)] due \(card.due) vs \(due)")
                compared += 1
            }
        }
        return compared
    }

    @Test func matchesIndependentTranscriptionVectors() throws {
        #expect(try replay("fsrs_transcription.json") == 12 + 5 + 10 + 6 + 7)
    }

    /// Authoritative check: only runs when vectors from the real py-fsrs library were generated
    /// (`pip install fsrs && scripts/fsrs_vectors.py reference > Tests/Fixtures/fsrs_reference.json`).
    @Test(.enabled(if: FileManager.default.fileExists(atPath: FSRSTests.fixtureDir.appendingPathComponent("fsrs_reference.json").path)))
    func matchesPyFSRSReferenceVectors() throws {
        #expect(try replay("fsrs_reference.json") > 0)
    }

    @Test func defaultParametersMatchPublishedValues() {
        #expect(FSRSScheduler.defaultParameters.count == 21)
        #expect(FSRSScheduler.defaultParameters[0] == 0.212 && FSRSScheduler.defaultParameters[20] == 0.1542)
        #expect(FSRSScheduler(parameters: Array(FSRSScheduler.defaultParameters.dropLast())) == nil)       // wrong length
        var bad = FSRSScheduler.defaultParameters; bad[4] = 99
        #expect(FSRSScheduler(parameters: bad) == nil)                                                   // out of bounds
        #expect(FSRSScheduler(desiredRetention: 0.2) == nil)
    }

    @Test func behavesSensibly() {
        let s = scheduler()
        var c = FSRSCard.new(now: Self.t0)
        c = s.review(c, rating: .easy, at: Self.t0)
        #expect(c.state == .review && c.step == nil)                         // Easy graduates immediately
        let good = s.review(c, rating: .good, at: c.due), easy = s.review(c, rating: .easy, at: c.due)
        let hard = s.review(c, rating: .hard, at: c.due), again = s.review(c, rating: .again, at: c.due)
        #expect(easy.stability! > good.stability! && good.stability! > hard.stability! && hard.stability! > again.stability!)
        #expect(easy.due > good.due && good.due > hard.due && hard.due > again.due)
        #expect(again.state == .relearning && again.due.timeIntervalSince(c.due) == 600)
        #expect(s.retrievability(c, at: c.lastReview!) == 1)
        #expect(s.retrievability(c, at: c.due) < 1 && s.retrievability(c, at: c.due.addingTimeInterval(86_400 * 30)) < s.retrievability(c, at: c.due))
        #expect(s.retrievability(.new(now: Self.t0), at: Self.t0) == 0)
        // Higher desired retention → shorter intervals.
        let strict = FSRSScheduler(desiredRetention: 0.97)!
        #expect(strict.review(.new(now: Self.t0), rating: .easy, at: Self.t0).due < s.review(.new(now: Self.t0), rating: .easy, at: Self.t0).due)
    }

    @Test func determinismAndNoFuzz() {
        let s = scheduler()
        let a = s.review(.new(now: Self.t0), rating: .good, at: Self.t0), b = s.review(.new(now: Self.t0), rating: .good, at: Self.t0)
        #expect(a == b)
        #expect(FSRSRating(label: "good") == .good && FSRSRating(label: "Nope") == nil && FSRSRating.allCases.map(\.label) == ["Again", "Hard", "Good", "Easy"])
    }
}

/// Expectations hard-coded by the authors of py-fsrs in their own test suite (tests/test_basic.py at commit 9446cb06).
/// The library's code was NOT executed to produce these: the numbers were read from its tests, so they are an
/// independent check on the Swift port that does not rest on my reading of the equations.
@Suite struct FSRSLibraryExpectationTests {
    let start = ISO8601DateFormatter().date(from: "2022-11-29T12:30:00Z")!
    var s: FSRSScheduler { FSRSScheduler()! }
    func days(_ a: Date, _ b: Date) -> Int { Int((b.timeIntervalSince(a) / 86_400).rounded(.down)) }

    @Test func intervalHistoryMatchesLibraryTest() {
        let ratings: [FSRSRating] = [.good, .good, .good, .good, .good, .good, .again, .again, .good, .good, .good, .good, .good]
        var card = FSRSCard.new(now: start), at = start, history: [Int] = []
        for r in ratings {
            card = s.review(card, rating: r, at: at)
            history.append(days(card.lastReview!, card.due))
            at = card.due
        }
        #expect(history == [0, 2, 11, 46, 163, 498, 0, 0, 2, 4, 7, 12, 21])   // test_review_card
    }

    @Test func memoryStateMatchesLibraryTest() {
        let ratings: [FSRSRating] = [.again, .good, .good, .good, .good, .good]
        let gaps = [0, 0, 1, 3, 8, 21]
        var card = FSRSCard.new(now: start), at = start
        for (r, g) in zip(ratings, gaps) { at = at.addingTimeInterval(Double(g) * 86_400); card = s.review(card, rating: r, at: at) }
        #expect(abs(card.stability! - 53.62691) < 1e-4)                           // test_memo_state
        #expect(abs(card.difficulty! - 6.3574867) < 1e-4)
    }

    @Test func repeatedEasyBottomsOutDifficultyAtOne() {
        var card = FSRSCard.new(now: start)
        for i in 0..<10 { card = s.review(card, rating: .easy, at: start.addingTimeInterval(Double(i) * 1e-6)) }
        #expect(card.difficulty == 1.0)                                           // test_repeated_correct_reviews
    }

    @Test func learningStepBehaviourMatchesLibraryTests() {
        let t0 = start
        var c = s.review(.new(now: t0), rating: .good, at: t0)                    // test_good_learning_steps
        #expect(c.state == .learning && c.step == 1 && c.due.timeIntervalSince(t0) == 600)
        c = s.review(c, rating: .good, at: c.due)
        #expect(c.state == .review && c.step == nil && c.due.timeIntervalSince(t0) >= 86_400)

        c = s.review(.new(now: t0), rating: .again, at: t0)                       // test_again_learning_steps
        #expect(c.state == .learning && c.step == 0 && c.due.timeIntervalSince(t0) == 60)
        c = s.review(.new(now: t0), rating: .hard, at: t0)                        // test_hard_learning_steps
        #expect(c.state == .learning && c.step == 0 && c.due.timeIntervalSince(t0) == 330)
        c = s.review(.new(now: t0), rating: .easy, at: t0)                        // test_easy_learning_steps
        #expect(c.state == .review && c.step == nil && c.due.timeIntervalSince(t0) >= 86_400)
    }

    @Test func reviewAndRelearningStatesMatchLibraryTests() {
        var c = FSRSCard.new(now: start)
        c = s.review(c, rating: .good, at: c.due); c = s.review(c, rating: .good, at: c.due)
        #expect(c.state == .review && c.step == nil)                              // test_review_state
        var prev = c.due
        c = s.review(c, rating: .good, at: c.due)
        #expect(c.state == .review && c.due.timeIntervalSince(prev) >= 86_400)
        prev = c.due
        c = s.review(c, rating: .again, at: c.due)
        #expect(c.state == .relearning && c.step == 0 && c.due.timeIntervalSince(prev) == 600)
        prev = c.due                                                              // test_relearning: Again again stays on step 0
        c = s.review(c, rating: .again, at: c.due)
        #expect(c.state == .relearning && c.step == 0 && c.due.timeIntervalSince(prev) == 600)
        prev = c.due
        c = s.review(c, rating: .good, at: c.due)
        #expect(c.state == .review && c.step == nil && c.due.timeIntervalSince(prev) >= 86_400)
    }

    @Test func noLearningOrRelearningStepsGoStraightToReview() {
        let none = FSRSScheduler(learningSteps: [])!                              // test_no_learning_steps
        let c = none.review(.new(now: start), rating: .again, at: start)
        #expect(c.state == .review && c.due.timeIntervalSince(start) >= 86_400)
        let noRelearn = FSRSScheduler(relearningSteps: [])!                       // test_no_relearning_steps
        var d = noRelearn.review(.new(now: start), rating: .good, at: start)
        d = noRelearn.review(d, rating: .good, at: d.due)
        #expect(d.state == .review)
        let before = d.due
        d = noRelearn.review(d, rating: .again, at: d.due)
        #expect(d.state == .review && d.due.timeIntervalSince(before) >= 86_400)
    }
}

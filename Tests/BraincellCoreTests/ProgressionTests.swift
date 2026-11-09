import Testing
import Foundation
import GRDB
@testable import BraincellCore

/// Shared setup: a course with two skills and helpers to create questions and submit attempts through the real services.
struct Rig {
    let db: AppDatabase, courses: CourseService, qs: QuestionService, practice: PracticeService
    let eval: EvaluationService, prog: ProgressionService, ai: AITaskService
    let course: Course, skillA: Skill, skillB: Skill

    init(db: AppDatabase? = nil) throws {
        let db = try db ?? AppDatabase.inMemory()
        self.db = db; courses = CourseService(db: db); qs = QuestionService(db: db); practice = PracticeService(db: db)
        eval = EvaluationService(db: db); prog = ProgressionService(db: db); ai = AITaskService(db: db)
        course = try courses.createCourse(name: "COMP 211")
        skillA = try courses.addSkill(courseId: course.id, name: "Java iterators").skill
        skillB = try courses.addSkill(courseId: course.id, name: "Recursion").skill
    }

    @discardableResult
    func question(_ i: Int, skills: [Skill]? = nil, title: String? = nil, tweak: (inout QuestionSpec) -> Void = { _ in }) throws -> Question {
        var spec = QuestionValidator.validate(entry: Fx.all[i], index: 0).question!.spec
        if let title { spec.title = title }
        tweak(&spec)
        return try qs.create(courseId: course.id, spec: spec, skillIds: (skills ?? [skillA]).map(\.id))
    }

    func attempt(_ q: Question, text: String = "", selected: [String] = [], hints: Int = 0, revealed: Bool = false) throws -> Attempt {
        let s = try practice.start(questionIds: [q.id], title: "t", courseId: course.id)
        let item = try practice.items(sessionId: s.id)[0]
        if hints > 0 { try practice.revealHint(itemId: item.id, level: hints) }
        var r = PracticeResponse(); r.text = text; r.selected = selected; r.revealed = revealed
        return try practice.submit(itemId: item.id, response: r)
    }
}

@Suite struct EvaluatorTests {
    func spec(_ i: Int) -> QuestionSpec { QuestionValidator.validate(entry: Fx.all[i], index: 0).question!.spec }
    func r(text: String = "", selected: [String] = []) -> PracticeResponse { var x = PracticeResponse(); x.text = text; x.selected = selected; return x }

    @Test func choiceSingleAndMultiple() {
        #expect(Evaluator.evaluate(spec: spec(1), response: r(selected: ["a"]), answerKeyVerified: true).score == 1)
        #expect(Evaluator.evaluate(spec: spec(1), response: r(selected: ["b"]), answerKeyVerified: true).score == 0)
        let ms = spec(2)   // correct: a, c of a,b,c
        #expect(Evaluator.evaluate(spec: ms, response: r(selected: ["c", "a"]), answerKeyVerified: true).score == 1)
        #expect(Evaluator.evaluate(spec: ms, response: r(selected: ["a"]), answerKeyVerified: true).score == 0.5)
        #expect(Evaluator.evaluate(spec: ms, response: r(selected: ["a", "b"]), answerKeyVerified: true).score == 0) // (1-1)/2
        #expect(Evaluator.evaluate(spec: ms, response: r(selected: []), answerKeyVerified: true).score == 0)
    }

    @Test func exactNormalisation() {
        let sa = spec(3)   // accepted ["hasNext"], case-insensitive
        for ok in ["hasNext", "  HASNEXT  ", "hasnext.", "has\u{00A0}next".replacingOccurrences(of: "has\u{00A0}next", with: "hasNext!")] {
            #expect(Evaluator.evaluate(spec: sa, response: r(text: ok), answerKeyVerified: true).score == 1, "\(ok)")
        }
        #expect(Evaluator.evaluate(spec: sa, response: r(text: "next"), answerKeyVerified: true).score == 0)
        #expect(Evaluator.evaluate(spec: sa, response: r(text: "  "), answerKeyVerified: true).score == 0)
        let ct = spec(5)   // code tracing, expected "3": case-sensitive, multi-line
        #expect(Evaluator.evaluate(spec: ct, response: r(text: "3\n"), answerKeyVerified: false).score == 1)
        #expect(Evaluator.evaluate(spec: ct, response: r(text: " 3 "), answerKeyVerified: false).score == 1)
        var multi = ct; multi.answer.expectedOutput = "a\nB"
        #expect(Evaluator.evaluate(spec: multi, response: r(text: "a  \nB\n"), answerKeyVerified: false).score == 1)
        #expect(Evaluator.evaluate(spec: multi, response: r(text: "a\nb"), answerKeyVerified: false).score == 0) // code output is case-sensitive
    }

    @Test func numericToleranceAndParsing() {
        let n = spec(4)   // 14 ± 0.01
        for ok in ["14", "14.005", "13.995", "28/2", "1.4e1", " 14 ", "+14", "14.0"] {
            #expect(Evaluator.evaluate(spec: n, response: r(text: ok), answerKeyVerified: true).score == 1, "\(ok)")
        }
        for bad in ["14.02", "13", "-14", "7/2"] { #expect(Evaluator.evaluate(spec: n, response: r(text: bad), answerKeyVerified: true).score == 0, "\(bad)") }
        // Unreadable input is a formatting problem, never a wrong answer.
        for junk in ["abc", "1,5", "", "1/0", "1/2/3", "14 apples"] {
            let o = Evaluator.evaluate(spec: n, response: r(text: junk), answerKeyVerified: true)
            #expect(o.state == .needsReview && o.score == nil, "\(junk)")
        }
        #expect(Evaluator.parseNumber("−3.5") == -3.5)
        #expect(Evaluator.parseNumber("7/2") == 3.5)
        #expect(Evaluator.parseNumber("inf") == nil && Evaluator.parseNumber("nan") == nil)
        var exact = n; exact.answer.tolerance = 0
        #expect(Evaluator.evaluate(spec: exact, response: r(text: "14.0000001"), answerKeyVerified: true).score == 0)
    }

    @Test func subjectiveStaysPendingNeverIncorrect() {
        for i in [0, 6, 7, 8] {   // flashcard, coding, long-form, proof
            let o = Evaluator.evaluate(spec: spec(i), response: r(text: "anything"), answerKeyVerified: true)
            #expect(o.state == .pending && o.score == nil, "type \(spec(i).type)")
        }
    }

    @Test func trustFollowsVerification() {
        #expect(Evaluator.evaluate(spec: spec(1), response: r(selected: ["a"]), answerKeyVerified: true).trust == .trusted)
        #expect(Evaluator.evaluate(spec: spec(1), response: r(selected: ["a"]), answerKeyVerified: false).trust == .provisional)
    }
}

@Suite struct EstimatorTests {
    let est = HeuristicMasteryEstimator()
    let now = Date()
    func ev(_ dim: MasteryDimension = .application, score: Double = 1, d: Int = 3, hints: Int = 0, n: Int = 1, trust: GradeTrust = .trusted, daysAgo: Double = 0) -> EvidenceInput {
        EvidenceInput(dimension: dim, score: score, difficulty: d, hintsUsed: hints, attemptNumber: n, trust: trust, occurredAt: now.addingTimeInterval(-daysAgo * 86_400))
    }

    @Test func noEvidenceIsUnknownNotZero() {
        let m = est.estimate(skillId: UUID(), evidence: [], now: now)
        #expect(m.isUnknown && m.overall == nil && m.evidenceQuality == nil && m.evidenceCount == 0)
        #expect(m.dimensions.count == 4 && m.dimensions.allSatisfy { $0.estimate == nil && $0.confidence == .unknown })
    }

    @Test func oneEasyAnswerIsNeverConfident() {
        let m = est.estimate(skillId: UUID(), evidence: [ev(.recognition, d: 1, trust: .provisional)], now: now)
        #expect(m.overall == 1 && m.confidence == .preliminary && m.overallWeight < 0.5)
        let strong = est.estimate(skillId: UUID(), evidence: (1...4).map { ev(.application, d: 4, n: $0 * 0 + 1) }, now: now)
        #expect(strong.confidence == .strong)
    }

    @Test func weightsReflectHintsRepetitionTrustDifficultyAndAge() {
        let base = HeuristicMasteryEstimator.weight(ev(), now: now)
        #expect(HeuristicMasteryEstimator.weight(ev(hints: 2), now: now) < base)
        #expect(HeuristicMasteryEstimator.weight(ev(n: 3), now: now) == base * 0.25)
        #expect(HeuristicMasteryEstimator.weight(ev(trust: .selfReported), now: now) == base * 0.6)
        #expect(HeuristicMasteryEstimator.weight(ev(trust: .provisional), now: now) == base * 0.5)
        #expect(HeuristicMasteryEstimator.weight(ev(d: 5), now: now) > base)
        #expect(abs(HeuristicMasteryEstimator.weight(ev(daysAgo: 60), now: now) - base * 0.5) < 1e-9)
        #expect(HeuristicMasteryEstimator.weight(ev(daysAgo: 100_000), now: now) == base * 0.2)  // floor: old evidence never vanishes
    }

    @Test func dimensionsAreIndependentAndQualityIsReported() {
        let m = est.estimate(skillId: UUID(), evidence: [ev(.recognition, score: 1), ev(.transfer, score: 0, trust: .selfReported)], now: now)
        func d(_ x: MasteryDimension) -> DimensionEstimate { m.dimensions.first { $0.dimension == x }! }
        #expect(d(.recognition).estimate == 1 && d(.transfer).estimate == 0)
        #expect(d(.recall).estimate == nil && d(.application).estimate == nil)   // untouched dimensions stay unknown
        #expect(m.evidenceQuality! > 0 && m.evidenceQuality! < 1)               // mixed trusted / self-reported
    }

    @Test func recentWorkCountsMoreThanOldWork() {
        let m = est.estimate(skillId: UUID(), evidence: [ev(score: 0, daysAgo: 300), ev(score: 1, daysAgo: 0)], now: now)
        #expect(m.overall! > 0.7)
    }

    @Test func dimensionMapping() {
        #expect(MasteryDimension.for(.singleChoice, difficulty: 1) == .recognition)
        #expect(MasteryDimension.for(.flashcard, difficulty: 1) == .recall && MasteryDimension.for(.longForm, difficulty: 3) == .recall)
        #expect(MasteryDimension.for(.numeric, difficulty: 3) == .application && MasteryDimension.for(.codeTracing, difficulty: 2) == .application)
        #expect(MasteryDimension.for(.coding, difficulty: 3) == .application && MasteryDimension.for(.coding, difficulty: 5) == .transfer)
        #expect(MasteryDimension.for(.derivationProof, difficulty: 2) == .transfer)
    }

    @Test func xpRulesAndSplits() {
        #expect(XPRules.participation(difficulty: 3, attemptNumber: 1) == 11)
        #expect([1, 2, 3, 4, 9].map { XPRules.participation(difficulty: 3, attemptNumber: $0) } == [11, 6, 3, 0, 0])
        #expect(XPRules.level(forXP: 0) == 1 && XPRules.level(forXP: 24) == 1 && XPRules.level(forXP: 25) == 2 && XPRules.level(forXP: 100) == 3)
        #expect(XPRules.split(10, among: 3) == [4, 3, 3] && XPRules.split(-10, among: 3) == [-4, -3, -3] && XPRules.split(5, among: 0) == [])
        #expect(XPRules.proportional(-10, weights: [3, 1]).reduce(0, +) == -10)
        #expect(XPRules.proportional(7, weights: [1, 1, 1]).reduce(0, +) == 7)
    }
}

@Suite struct GradingFlowTests {
    @Test func trustedCorrectAnswerGivesEvidenceAndBothXPKinds() throws {
        let rig = try Rig()
        let q = try rig.question(4)                                 // numeric, verified by expression
        let a = try rig.attempt(q, text: "14")
        let r = try rig.eval.evaluate(attemptId: a.id)
        #expect(r.evaluation.state == .graded && r.evaluation.score == 1 && r.evaluation.trust == .trusted)
        #expect(r.xp == XPRules.participation(difficulty: 2, attemptNumber: 1) + XPRules.correctness(difficulty: 2))
        let ev = try rig.prog.evidence(skillId: rig.skillA.id)
        #expect(ev.count == 1)
        // Evidence is attributable to the evaluation, question revision and skill mapping that produced it.
        #expect(ev[0].evaluationId == r.evaluation.id && ev[0].revisionId == a.revisionId && ev[0].attemptId == a.id && ev[0].dimension == .application)
        let m = try rig.prog.mastery(skillId: rig.skillA.id)
        #expect(!m.isUnknown && m.overall == 1 && m.confidence == .preliminary)
        #expect(try rig.prog.mastery(skillId: rig.skillB.id).isUnknown)       // untouched skill remains Unknown
        #expect(try rig.prog.history(skillId: rig.skillA.id).count == 1)
    }

    @Test func provisionalGradeEarnsParticipationButNoCorrectnessBonus() throws {
        let rig = try Rig()
        let q = try rig.question(1)                                  // single choice, unverified
        let r = try rig.eval.evaluate(attemptId: try rig.attempt(q, selected: ["a"]).id)
        #expect(r.evaluation.trust == .provisional && r.evaluation.score == 1)
        #expect(r.xp == XPRules.participation(difficulty: 2, attemptNumber: 1))
        #expect(try rig.prog.mastery(skillId: rig.skillA.id).evidenceQuality == 0)  // all provisional
        // Once the user verifies the key and the grade is refreshed, the bonus is awarded exactly once.
        try rig.qs.markVerified(q.id)
        #expect(try rig.eval.regradeQuestion(questionId: q.id) == 1)
        let again = try #require(try rig.eval.result(attemptId: r.attempt.id))
        #expect(again.evaluation.trust == .trusted && again.xp == XPRules.participation(difficulty: 2, attemptNumber: 1) + XPRules.correctness(difficulty: 2))
        _ = try rig.eval.regradeQuestion(questionId: q.id)
        #expect(try rig.prog.courseXP(rig.course.id).xp == again.xp)             // no double award on repeat
    }

    @Test func pendingIsNeverIncorrectAndEarnsNoCorrectnessXP() throws {
        let rig = try Rig()
        let q = try rig.question(7)                                  // long-form
        let a = try rig.attempt(q, text: "My explanation")
        let r = try rig.eval.evaluate(attemptId: a.id)
        #expect(r.evaluation.state == .pending && r.evaluation.score == nil && !r.evaluation.isCorrect)
        #expect(r.xp == XPRules.participation(difficulty: 2, attemptNumber: 1))
        #expect(try rig.prog.evidence(skillId: rig.skillA.id).isEmpty && (try rig.prog.mastery(skillId: rig.skillA.id)).isUnknown)
        #expect(try rig.eval.pendingAttempts().map(\.id) == [a.id])
        let sessionId = try rig.db.read { try SessionItem.fetchOne($0, key: a.sessionItemId)!.sessionId }
        let sum = try rig.prog.sessionResults(sessionId: sessionId)
        #expect(sum.pending == 1 && sum.incorrect == 0 && sum.correct == 0)
    }

    @Test func evaluatingTwiceAndRepeatsNeverFarmXP() throws {
        let rig = try Rig()
        let q = try rig.question(4)
        var seen: [Int] = []
        for _ in 1...5 {
            let a = try rig.attempt(q, text: "14")
            _ = try rig.eval.evaluate(attemptId: a.id)
            _ = try rig.eval.evaluate(attemptId: a.id)               // retry / double call
            seen.append(try rig.prog.courseXP(rig.course.id).xp)
        }
        let first = XPRules.participation(difficulty: 2, attemptNumber: 1) + XPRules.correctness(difficulty: 2)
        #expect(seen[0] == first)
        #expect(seen[1] == first + XPRules.participation(difficulty: 2, attemptNumber: 2))
        #expect(seen[2] == seen[1] + XPRules.participation(difficulty: 2, attemptNumber: 3))
        #expect(seen[3] == seen[2] && seen[4] == seen[3])                                // pays nothing after the 3rd try
        let keys = try rig.db.read { try String.fetchAll($0, sql: "SELECT eventKey FROM xp_events") }
        #expect(Set(keys).count == keys.count)
        #expect(try rig.db.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM xp_events WHERE subject LIKE 'correct:%'") } == 1) // bonus once per question
    }

    @Test func hintedCorrectAnswerEarnsNoBonusAndWeighsLess() throws {
        let rig = try Rig()
        let q = try rig.question(4)
        let a = try rig.attempt(q, text: "14", hints: 1)
        let r = try rig.eval.evaluate(attemptId: a.id)
        #expect(r.evaluation.score == 1 && r.xp == XPRules.participation(difficulty: 2, attemptNumber: 1))
        let hinted = try rig.prog.mastery(skillId: rig.skillA.id).overallWeight
        let rig2 = try Rig(), q2 = try rig2.question(4)
        _ = try rig2.eval.evaluate(attemptId: try rig2.attempt(q2, text: "14").id)
        #expect(hinted < (try rig2.prog.mastery(skillId: rig2.skillA.id).overallWeight))
        // An unassisted correct answer later still earns the first-correct bonus.
        let b = try rig.attempt(q, text: "14"); let rb = try rig.eval.evaluate(attemptId: b.id)
        #expect(rb.xp == XPRules.participation(difficulty: 2, attemptNumber: 2) + XPRules.correctness(difficulty: 2))
    }

    @Test func selfReviewSupersedesPendingWithLowerConfidenceAndKeepsHistory() throws {
        let rig = try Rig()
        let q = try rig.question(7)
        let a = try rig.attempt(q, text: "text")
        _ = try rig.eval.evaluate(attemptId: a.id)
        let r = try rig.eval.selfReview(attemptId: a.id, score: 0.75, rubricPoints: ["clear": 1.5], note: "ok")
        #expect(r.evaluation.trust == .selfReported && r.evaluation.source == .selfReview && r.evaluation.score == 0.75)
        let hist = try rig.eval.history(attemptId: a.id)
        #expect(hist.count == 2 && hist[0].state == .pending && hist[0].supersededAt != nil && hist[1].supersedesId == hist[0].id)
        #expect(hist[1].detail.contains("rubricPoints"))
        #expect(r.xp == XPRules.participation(difficulty: 2, attemptNumber: 1))      // self-report earns no correctness XP
        let ev = try rig.prog.evidence(skillId: rig.skillA.id)
        #expect(ev.count == 1 && ev[0].trust == .selfReported)
        #expect(try rig.prog.mastery(skillId: rig.skillA.id).evidenceQuality == 0)
        #expect(throws: EvaluationError.invalidScore) { try rig.eval.selfReview(attemptId: a.id, score: 1.5) }
        #expect(try rig.eval.pendingAttempts().isEmpty)
    }
}

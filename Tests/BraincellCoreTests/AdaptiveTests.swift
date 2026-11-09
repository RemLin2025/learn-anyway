import Testing
import Foundation
import GRDB
@testable import BraincellCore

extension Rig {
    var planner: PlannerService { PlannerService(db: db) }
    var reviews: ReviewService { ReviewService(db: db) }
    var history: LearningHistoryService { LearningHistoryService(db: db) }
    var coach: CoachService { CoachService(db: db) }

    /// A numeric question (deterministic grading) tagged to `skill`, with a distinct title and difficulty.
    @discardableResult
    func numeric(_ title: String, skill: Skill, difficulty: Int = 2, verified: Bool = true) throws -> Question {
        let q = try question(4, skills: [skill], title: title) { $0.difficulty = difficulty }
        if verified { try qs.markVerified(q.id) }
        return q
    }

    @discardableResult
    func flashcard(_ title: String, skill: Skill) throws -> Question { try question(0, skills: [skill], title: title) }

    @discardableResult
    func shortAnswer(_ title: String, skill: Skill) throws -> Question { try question(3, skills: [skill], title: title) }

    /// Answers a numeric question right or wrong (graded immediately) in its own session; returns the attempt.
    @discardableResult
    func answerNumeric(_ q: Question, correct: Bool, hints: Int = 0) throws -> Attempt {
        let a = try attempt(q, text: correct ? "14" : "99", hints: hints)
        try eval.evaluate(attemptId: a.id); return a
    }
}

@Suite struct ReviewSchedulingTests {
    @Test func flashcardRatingSchedulesWithFSRSAndIsRecorded() throws {
        let rig = try Rig()
        let fc = try rig.flashcard("Card", skill: rig.skillA)
        let a = try rig.attempt(fc, revealed: true)
        _ = try rig.eval.evaluate(attemptId: a.id)
        #expect(try rig.reviews.state(questionId: fc.id) == nil)                      // pending: nothing scheduled yet
        _ = try rig.eval.selfReview(attemptId: a.id, score: 0.8, rating: "good")
        let st = try #require(try rig.reviews.state(questionId: fc.id))
        #expect(st.schedulerVersion == FSRSScheduler.version && st.reps == 1 && st.lapses == 0 && st.parameters.contains("0.212"))
        let logs = try rig.reviews.logs(questionId: fc.id)
        #expect(logs.count == 1 && logs[0].rating == FSRSRating.good.rawValue && logs[0].stateBefore == nil && logs[0].attemptId == a.id)
        // First Good: still in the 1m/10m learning steps, so it comes due within minutes, then days.
        #expect(st.state == FSRSState.learning.rawValue && st.due.timeIntervalSince(logs[0].reviewedAt) == 600)
        #expect(try rig.reviews.due(now: st.due.addingTimeInterval(-1)).isEmpty)
        #expect(try rig.reviews.due(now: st.due).map(\.questionId) == [fc.id])
        // A later override of the same attempt can't schedule a second review.
        _ = try rig.eval.overrideGrade(attemptId: a.id, correct: false)
        #expect(try rig.reviews.logs(questionId: fc.id).count == 1 && (try rig.reviews.state(questionId: fc.id))?.reps == 1)
    }

    @Test func shortAnswerRatingsFollowScoreAndHints() throws {
        let rig = try Rig()
        func review(_ text: String, hints: Int = 0) throws -> Int {
            let q = try rig.shortAnswer("SA \(UUID().uuidString.prefix(4))", skill: rig.skillA)
            let a = try rig.attempt(q, text: text, hints: hints)
            _ = try rig.eval.evaluate(attemptId: a.id)
            return try rig.reviews.logs(questionId: q.id)[0].rating
        }
        #expect(try review("hasNext") == FSRSRating.good.rawValue)
        #expect(try review("hasNext", hints: 1) == FSRSRating.hard.rawValue)
        #expect(try review("wrong") == FSRSRating.again.rawValue)
    }

    @Test func onlyRecallTypesAreScheduledAndPendingNeverIs() throws {
        let rig = try Rig()
        _ = try rig.eval.evaluate(attemptId: try rig.attempt(try rig.question(1), selected: ["a"]).id)           // single choice
        _ = try rig.eval.evaluate(attemptId: try rig.attempt(try rig.numeric("N", skill: rig.skillA), text: "14").id)
        _ = try rig.eval.evaluate(attemptId: try rig.attempt(try rig.question(7), text: "essay").id)           // pending long-form
        #expect(try rig.db.read { try ReviewState.fetchCount($0) } == 0)
    }

    @Test func lapseAndRelearning() throws {
        let rig = try Rig()
        let q = try rig.shortAnswer("S", skill: rig.skillA)
        _ = try rig.eval.evaluate(attemptId: try rig.attempt(q, text: "hasNext").id)
        for _ in 0..<2 { _ = try rig.eval.evaluate(attemptId: try rig.attempt(q, text: "nope").id) }
        let st = try #require(try rig.reviews.state(questionId: q.id))
        #expect(st.reps == 3 && st.lapses == 2 && st.stability != nil && st.difficulty != nil)
        #expect(try rig.reviews.logs(questionId: q.id).map(\.rating) == [3, 1, 1])
    }

    @Test func reviewStateSurvivesRestartAndArchivedNeverDue() throws {
        let dir = try tempDir(); let path = dir.appendingPathComponent("r.sqlite")
        let rig = try Rig(db: try AppDatabase.open(at: path))
        let q = try rig.shortAnswer("S", skill: rig.skillA)
        _ = try rig.eval.evaluate(attemptId: try rig.attempt(q, text: "hasNext").id)
        let due = try #require(try rig.reviews.state(questionId: q.id)).due
        let reopened = ReviewService(db: try AppDatabase.open(at: path))
        #expect(try reopened.state(questionId: q.id)?.due == due)
        #expect(try reopened.due(now: due.addingTimeInterval(60)).count == 1)
        try rig.qs.setArchived([q.id], archived: true)
        #expect(try reopened.due(now: due.addingTimeInterval(60)).isEmpty)
    }
}

@Suite struct PlannerTests {
    let now = Date()

    func cram(_ rig: Rig, _ a: Assessment, minutes: Int = 30, tweak: (inout PlanRequest) -> Void = { _ in }) throws -> StudyPlan {
        var r = PlanRequest(courseId: rig.course.id, assessmentId: a.id, mode: .cram, budgetMinutes: minutes); r.now = now
        tweak(&r)
        return try rig.planner.plan(r)
    }

    @Test func cramStaysInsideExamScope() throws {
        let rig = try Rig()
        let m2 = try rig.courses.addAssessment(courseId: rig.course.id, name: "Midterm 2")
        try rig.courses.addToScope(assessmentId: m2.id, skillId: rig.skillA.id)
        let inScope = try (0..<3).map { try rig.numeric("A\($0)", skill: rig.skillA) }
        let outScope = try (0..<3).map { try rig.numeric("B\($0)", skill: rig.skillB) }
        // A due review of an out-of-scope card must not leak in either.
        let fc = try rig.flashcard("B card", skill: rig.skillB)
        _ = try rig.eval.selfReview(attemptId: try rig.attempt(fc, revealed: true).id, score: 0.8, rating: "good")
        let plan = try cram(rig, m2, minutes: 120)
        let ids = Set(plan.items.map(\.questionId))
        #expect(ids == Set(inScope.map(\.id)))
        #expect(ids.isDisjoint(with: outScope.map(\.id) + [fc.id]))
        // The cumulative final covers everything.
        let fin = try rig.courses.addAssessment(courseId: rig.course.id, name: "Final", kind: .final, isCumulative: true)
        let all = Set(try cram(rig, fin, minutes: 120).items.map(\.questionId))
        #expect(all.isSuperset(of: Set(inScope.map(\.id) + outScope.map(\.id))))
    }

    @Test func userConstraintsAreAlwaysRespected() throws {
        let rig = try Rig()
        let m = try rig.courses.addAssessment(courseId: rig.course.id, name: "M", isCumulative: true)
        let easyA = try rig.numeric("easyA", skill: rig.skillA, difficulty: 1)
        let hardA = try rig.numeric("hardA", skill: rig.skillA, difficulty: 5)
        let b = try rig.numeric("b", skill: rig.skillB, difficulty: 2)
        let sa = try rig.shortAnswer("sa", skill: rig.skillA)
        func ids(_ t: (inout PlanRequest) -> Void) throws -> Set<UUID> { Set(try cram(rig, m, minutes: 120, tweak: t).items.map(\.questionId)) }
        #expect(try ids { $0.focusSkillIds = [rig.skillB.id] } == [b.id])
        #expect(try ids { $0.excludedSkillIds = [rig.skillB.id] }.isDisjoint(with: [b.id]))
        #expect(try ids { $0.excludedQuestionIds = [hardA.id] }.contains(hardA.id) == false)
        #expect(try ids { $0.maxDifficulty = 2 }.isDisjoint(with: [hardA.id]))
        #expect(try ids { $0.allowedTypes = [.shortAnswer] } == [sa.id])
        #expect(try ids { _ in }.isSuperset(of: [easyA.id, hardA.id, b.id, sa.id]))
        // Time budget: total estimate never exceeds it (a 1-minute budget still yields one short item).
        let tiny = try cram(rig, m, minutes: 3)
        #expect(tiny.totalMinutes <= 3 && !tiny.items.isEmpty)
        let two = try cram(rig, m, minutes: 5)
        #expect(two.totalMinutes <= 5)
        #expect(throws: PlannerError.noBudget) { try rig.planner.plan(PlanRequest(courseId: rig.course.id, mode: .mastery, budgetMinutes: 0)) }
        #expect(throws: PlannerError.assessmentRequired) { try rig.planner.plan(PlanRequest(courseId: rig.course.id, mode: .cram, budgetMinutes: 10)) }
    }

    @Test func weakSkillsComeFirstAndEveryItemExplainsItself() throws {
        let rig = try Rig()
        let m = try rig.courses.addAssessment(courseId: rig.course.id, name: "Midterm 2", isCumulative: true)
        let strong = try (0..<4).map { try rig.numeric("S\($0)", skill: rig.skillA) }
        let weak = try (0..<4).map { try rig.numeric("W\($0)", skill: rig.skillB) }
        for q in strong.prefix(2) { try rig.answerNumeric(q, correct: true) }
        for q in weak.prefix(2) { try rig.answerNumeric(q, correct: false) }
        let plan = try cram(rig, m, minutes: 60)
        #expect(plan.skills.first?.skill.id == rig.skillB.id)                          // biggest demonstrated gap
        let firstBItem = try #require(plan.items.firstIndex { $0.skillId == rig.skillB.id })
        let firstAItem = try #require(plan.items.firstIndex { $0.skillId == rig.skillA.id })
        #expect(firstBItem < firstAItem)
        #expect(plan.items.allSatisfy { !$0.reason.isEmpty })
        #expect(plan.items[firstBItem].reason.contains("Recursion") && plan.items[firstBItem].reason.contains("%"))
        // Questions that were just missed come back as repairs; untouched ones are advances.
        let missedFirst = try #require(plan.items.first { $0.skillId == rig.skillB.id && $0.kind == .repair }, "a repair item")
        #expect(missedFirst.reason.contains("missed"))
    }

    @Test func unknownSkillsAreSampledAndSaySo() throws {
        let rig = try Rig()
        let m = try rig.courses.addAssessment(courseId: rig.course.id, name: "M", isCumulative: true)
        try rig.numeric("one", skill: rig.skillA)
        let plan = try cram(rig, m)
        #expect(plan.items[0].reason.contains("nothing is assessed yet"))
        #expect(plan.skills.allSatisfy { $0.mastery.isUnknown })
        #expect(plan.notes.contains { $0.contains("No questions yet for") && $0.contains("Recursion") })
    }

    @Test func importanceDeadlineAndAIEstimatesAreLabelled() throws {
        let rig = try Rig()
        let m = try rig.courses.addAssessment(courseId: rig.course.id, name: "Midterm 2", deadline: Date().addingTimeInterval(3 * 86_400 + 3_600))
        try rig.courses.addToScope(assessmentId: m.id, skillId: rig.skillA.id, importance: 0.9, source: .instructorConfirmed)
        try rig.courses.addToScope(assessmentId: m.id, skillId: rig.skillB.id, importance: 0.9, source: .aiEstimate)
        try rig.numeric("a", skill: rig.skillA); try rig.numeric("b", skill: rig.skillB)
        let plan = try cram(rig, m)
        #expect(plan.skills[0].skill.id == rig.skillA.id)                              // confirmed outweighs an AI guess
        let a = try #require(plan.items.first { $0.skillId == rig.skillA.id }), b = try #require(plan.items.first { $0.skillId == rig.skillB.id })
        #expect(a.reason.contains("confirmed important by your instructor") && a.reason.contains("in 4 days"))
        #expect(b.reason.contains("estimated important by AI (unconfirmed)"))
        #expect(plan.notes.contains { $0.contains("AI estimates") })
        // No deadline → says so; a passed deadline is flagged.
        let nodl = try rig.courses.addAssessment(courseId: rig.course.id, name: "Quiz", isCumulative: true)
        #expect(try cram(rig, nodl).notes.contains { $0.contains("no deadline") })
        let past = try rig.courses.addAssessment(courseId: rig.course.id, name: "Old", deadline: Date().addingTimeInterval(-86_400), isCumulative: true)
        #expect(try cram(rig, past).notes.contains { $0.contains("has passed") })
    }

    @Test func closerDeadlinesRaisePriority() throws {
        let rig = try Rig()
        let soon = try rig.courses.addAssessment(courseId: rig.course.id, name: "Soon", deadline: Date().addingTimeInterval(2 * 86_400), isCumulative: true)
        let later = try rig.courses.addAssessment(courseId: rig.course.id, name: "Later", deadline: Date().addingTimeInterval(60 * 86_400), isCumulative: true)
        try rig.numeric("a", skill: rig.skillA)
        #expect(try cram(rig, soon).skills[0].priority > (try cram(rig, later).skills[0].priority))
    }

    @Test func weakPrerequisiteIsWorkedFirstAndDependentWaits() throws {
        let rig = try Rig()
        let m = try rig.courses.addAssessment(courseId: rig.course.id, name: "M", isCumulative: true)
        try rig.courses.addRelation(from: rig.skillB.id, to: rig.skillA.id, kind: .prerequisite)   // Recursion → Java iterators
        let a = try (0..<3).map { try rig.numeric("A\($0)", skill: rig.skillA) }
        let b = try (0..<3).map { try rig.numeric("B\($0)", skill: rig.skillB) }
        try rig.answerNumeric(a[0], correct: false)
        try rig.answerNumeric(b[0], correct: false)
        let plan = try cram(rig, m, minutes: 60)
        #expect(plan.items[0].skillId == rig.skillB.id)
        let pri = Dictionary(uniqueKeysWithValues: plan.skills.map { ($0.skill.id, $0) })
        #expect(pri[rig.skillB.id]!.note.contains("prerequisite for “Java iterators”"))
        #expect(pri[rig.skillA.id]!.note.contains("waiting until “Recursion” improves"))
        #expect(plan.items.contains { $0.skillId == rig.skillA.id })                    // deferred, not excluded
        // A prerequisite outside the exam's scope is mentioned, not silently added.
        let narrow = try rig.courses.addAssessment(courseId: rig.course.id, name: "Narrow")
        try rig.courses.addToScope(assessmentId: narrow.id, skillId: rig.skillA.id)
        let p2 = try cram(rig, narrow)
        #expect(p2.notes.contains { $0.contains("isn’t part of this plan’s scope") } && p2.items.allSatisfy { $0.skillId == rig.skillA.id })
    }

    @Test func plansAreBalancedAndNeverRepeatTheSameWeakTopicBackToBack() throws {
        let rig = try Rig()
        let c = try rig.courses.addSkill(courseId: rig.course.id, name: "Generics").skill
        let m = try rig.courses.addAssessment(courseId: rig.course.id, name: "M", isCumulative: true)
        for s in [rig.skillA, rig.skillB, c] { for i in 0..<6 { try rig.numeric("\(s.name)\(i)", skill: s) } }
        try rig.answerNumeric(try rig.numeric("weak0", skill: rig.skillA), correct: false)       // A is clearly weakest
        let plan = try cram(rig, m, minutes: 60)
        let skillSeq = plan.items.compactMap(\.skillId)
        #expect(skillSeq.count >= 8)
        for pair in zip(skillSeq, skillSeq.dropFirst()) { #expect(pair.0 != pair.1) }
        let counts = Dictionary(grouping: skillSeq, by: { $0 }).mapValues(\.count)
        #expect(counts.count == 3 && counts.values.max()! <= Int((0.4 * Double(max(3, 60 / 3))).rounded(.up)))
        #expect(counts[rig.skillA.id]! >= counts[c.id]!)                                            // weakest still gets the most
    }

    @Test func dueReviewsComeFirstAndRecentQuestionsWait() throws {
        let rig = try Rig()
        let m = try rig.courses.addAssessment(courseId: rig.course.id, name: "M", isCumulative: true)
        let fc = try rig.flashcard("Card", skill: rig.skillA)
        _ = try rig.eval.selfReview(attemptId: try rig.attempt(fc, revealed: true).id, score: 0.8, rating: "good")
        let fresh = try rig.numeric("fresh", skill: rig.skillA), justDone = try rig.numeric("justDone", skill: rig.skillA)
        try rig.answerNumeric(justDone, correct: true)
        let later = now.addingTimeInterval(3 * 86_400)
        let plan = try cram(rig, m, minutes: 30) { $0.now = later }
        #expect(plan.items[0].questionId == fc.id && plan.items[0].kind == .review && plan.items[0].reason.contains("Due for review"))
        #expect(plan.items.contains { $0.questionId == fresh.id })
        // Not yet due → not offered. Just-attempted (within a day) → deprioritised in favour of alternatives.
        let early = try cram(rig, m, minutes: 30)
        #expect(!early.items.contains { $0.questionId == fc.id })
        let order = early.items.map(\.questionId)
        if let jd = order.firstIndex(of: justDone.id), let fr = order.firstIndex(of: fresh.id) { #expect(fr < jd) }
    }

    @Test func masteryModeWorksWithoutADeadlineOrAnyAI() throws {
        let rig = try Rig()
        for i in 0..<3 { try rig.numeric("A\(i)", skill: rig.skillA); try rig.numeric("B\(i)", skill: rig.skillB) }
        try rig.answerNumeric(try rig.numeric("done", skill: rig.skillA), correct: true)
        var r = PlanRequest(courseId: rig.course.id, mode: .mastery, budgetMinutes: 20); r.now = now
        let plan = try rig.planner.plan(r)
        #expect(plan.mode == .mastery && plan.assessmentName == nil && !plan.items.isEmpty)
        #expect(plan.skills.first?.skill.id == rig.skillB.id)                           // untouched skill outranks a strong one
        #expect(plan.notes.contains { $0.contains("no deadline") })
        #expect(plan.items.allSatisfy { !$0.reason.isEmpty })
    }

    @Test func planStartsASessionThatKeepsReasonsKindsAndMode() throws {
        let rig = try Rig()
        let m = try rig.courses.addAssessment(courseId: rig.course.id, name: "M", isCumulative: true)
        for i in 0..<3 { try rig.numeric("A\(i)", skill: rig.skillA) }
        let plan = try cram(rig, m)
        let chosen = Array(plan.items.prefix(2))                                         // the learner removed the rest
        let s = try rig.practice.start(planned: chosen.map { .init(questionId: $0.questionId, kind: $0.kind, reason: $0.reason) },
                                       title: "Cram", courseId: rig.course.id, assessmentId: m.id, mode: .cram)
        let items = try rig.practice.items(sessionId: s.id)
        #expect(items.count == 2 && s.mode == .cram && !s.timed)
        #expect(items.map(\.reason) == chosen.map(\.reason) && items.map(\.kind) == chosen.map(\.kind))
        #expect(try rig.practice.session(s.id).mode == .cram)
    }

    @Test func diagnosticSamplesUnknownSkillsWithQuickQuestionsOnly() throws {
        let rig = try Rig()
        let c = try rig.courses.addSkill(courseId: rig.course.id, name: "Generics").skill
        try rig.question(7, skills: [rig.skillA], title: "long essay")                         // too long for a quick check
        let short = try rig.shortAnswer("quick A", skill: rig.skillA)
        let numB = try rig.numeric("quick B", skill: rig.skillB)
        try rig.numeric("known", skill: c)
        try rig.answerNumeric(try rig.numeric("evidence", skill: c), correct: true)            // skill C already has evidence
        let plan = try rig.planner.diagnostic(courseId: rig.course.id, now: now)
        #expect(Set(plan.items.map(\.questionId)) == [short.id, numB.id])
        #expect(plan.items.allSatisfy { $0.kind == .diagnostic && $0.reason.contains("nothing has been assessed") })
        #expect(plan.notes[0].contains("early signals") && plan.notes[0].contains("Preliminary"))
        #expect(plan.items.map(\.skillId).count == Set(plan.items.map(\.skillId)).count)       // one per skill
        // After answering, the skills are Preliminary at best — never confident.
        _ = try rig.eval.evaluate(attemptId: try rig.attempt(numB, text: "14").id)
        #expect(try rig.prog.mastery(skillId: rig.skillB.id).confidence == .preliminary)
        let again = try rig.planner.diagnostic(courseId: rig.course.id, now: now)
        #expect(!again.items.contains { $0.skillId == rig.skillB.id })
    }

    @Test func recommendationAimsAtTheNearestExamElseKeepsLearning() throws {
        let rig = try Rig()
        #expect(try rig.planner.recommendation(now: now) == nil)                       // nothing to practise yet
        try rig.numeric("a", skill: rig.skillA)
        let rec = try #require(try rig.planner.recommendation(now: now))
        #expect(rec.assessment == nil && rec.plan.mode == .mastery && rec.headline.contains("COMP 211"))
        let far = try rig.courses.addAssessment(courseId: rig.course.id, name: "Final", deadline: now.addingTimeInterval(30 * 86_400), isCumulative: true)
        let near = try rig.courses.addAssessment(courseId: rig.course.id, name: "Midterm", deadline: now.addingTimeInterval(5 * 86_400 - 60), isCumulative: true)
        let rec2 = try #require(try rig.planner.recommendation(now: now))
        #expect(rec2.assessment?.id == near.id && rec2.plan.mode == .cram && rec2.headline.contains("5 days") && far.id != near.id)
    }
}

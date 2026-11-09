import Testing
import Foundation
import GRDB
@testable import BraincellCore

@Suite struct CoachTests {
    /// Starts a session over `qs`, returning its id and items.
    func session(_ rig: Rig, _ qs: [Question], timed: Bool = false) throws -> (UUID, [SessionItem]) {
        let s = try rig.practice.start(planned: qs.map { .init(questionId: $0.id, kind: .practice, reason: "") }, title: "S", courseId: rig.course.id, mode: .free, timed: timed)
        return (s.id, try rig.practice.items(sessionId: s.id))
    }
    func submit(_ rig: Rig, _ item: SessionItem, text: String, hints: Int = 0) throws -> Attempt {
        if hints > 0 { try rig.practice.revealHint(itemId: item.id, level: hints) }
        var r = PracticeResponse(); r.text = text
        let a = try rig.practice.submit(itemId: item.id, response: r)
        _ = try rig.eval.evaluate(attemptId: a.id); return a
    }

    @Test func twoMissesInARowSuggestPrerequisitesOnceAndRespectCooldown() throws {
        let rig = try Rig()
        try rig.courses.addRelation(from: rig.skillB.id, to: rig.skillA.id, kind: .prerequisite)
        let qs = try (0..<4).map { try rig.numeric("A\($0)", skill: rig.skillA) }
        let (sid, items) = try session(rig, qs)
        let a1 = try submit(rig, items[0], text: "99")
        #expect(try rig.coach.suggestion(sessionId: sid, attemptId: a1.id) == nil)                    // one miss is not a pattern
        let a2 = try submit(rig, items[1], text: "99")
        let s = try #require(try rig.coach.suggestion(sessionId: sid, attemptId: a2.id))
        #expect(s.trigger == .repeatedMistakes && s.skillName == "Java iterators" && s.prerequisiteNames == ["Recursion"] && !s.offersReflection)
        #expect(s.message.contains("not a verdict"))
        // Cooldown: even a third miss right away stays quiet.
        let a3 = try submit(rig, items[2], text: "99")
        #expect(try rig.coach.suggestion(sessionId: sid, attemptId: a3.id) == nil)
        #expect(try rig.coach.suggestion(sessionId: sid, attemptId: a3.id, now: Date().addingTimeInterval(CoachService.cooldown + 5)) == nil) // same skill already offered
        try rig.coach.dismiss(eventId: s.id, accepted: false)
        let ev = try rig.coach.events(sessionId: sid)
        #expect(ev.count == 1 && ev[0].dismissedAt != nil && ev[0].accepted == false)
        // The question list itself is untouched.
        #expect(try rig.practice.items(sessionId: sid).map(\.questionId) == qs.map(\.id))
    }

    @Test func respectsSettingTimedExamsAndCompletedSessions() throws {
        let rig = try Rig()
        let qs = try (0..<3).map { try rig.numeric("A\($0)", skill: rig.skillA) }
        let (sid, items) = try session(rig, qs, timed: true)
        _ = try submit(rig, items[0], text: "99"); let a = try submit(rig, items[1], text: "99")
        #expect(try rig.coach.suggestion(sessionId: sid, attemptId: a.id) == nil)                      // mock exam: never unsolicited
        let (sid2, items2) = try session(rig, qs)
        _ = try submit(rig, items2[0], text: "99"); let b = try submit(rig, items2[1], text: "99")
        #expect(try rig.coach.suggestion(sessionId: sid2, attemptId: b.id, enabled: false) == nil)     // user turned the coach off
        #expect(try rig.coach.events(sessionId: sid2).isEmpty)
        try rig.practice.setStatus(sid2, .completed)
        #expect(try rig.coach.suggestion(sessionId: sid2, attemptId: b.id) == nil)
        #expect(try rig.coach.suggestion(sessionId: sid, attemptId: UUID()) == nil)
    }

    @Test func manyHintsTrigger() throws {
        let rig = try Rig()
        let qs = try (0..<3).map { i in try rig.question(4, skills: [rig.skillA], title: "H\(i)") { $0.hints = ["a", "b", "c"] } }
        let (sid, items) = try session(rig, qs)
        _ = try submit(rig, items[0], text: "14", hints: 2)
        #expect(try rig.coach.suggestion(sessionId: sid, attemptId: try rig.practice.attempt(itemId: items[0].id)!.id) == nil)
        let a = try submit(rig, items[1], text: "14", hints: 1)
        let s = try #require(try rig.coach.suggestion(sessionId: sid, attemptId: a.id))
        #expect(s.trigger == .manyHints && s.message.contains("it’s your call"))
    }

    @Test func breakthroughOnANewVariationAfterEarlierTrouble() throws {
        let rig = try Rig()
        let q1 = try rig.numeric("First try", skill: rig.skillA), q2 = try rig.numeric("Variation", skill: rig.skillA)
        let (s1, i1) = try session(rig, [q1])
        _ = try submit(rig, i1[0], text: "99", hints: 1)                                               // missed earlier
        _ = s1
        let (s2, i2) = try session(rig, [q2])
        let a = try submit(rig, i2[0], text: "14")
        let s = try #require(try rig.coach.suggestion(sessionId: s2, attemptId: a.id))
        #expect(s.trigger == .breakthrough && s.offersReflection && s.message.contains("Variation"))
        #expect(try rig.history.breakthroughs(courseId: rig.course.id).map(\.attemptId) == [a.id])
        // The same question again isn't a "new variation".
        let (s3, i3) = try session(rig, [q1])
        let again = try submit(rig, i3[0], text: "14")
        #expect(try rig.coach.suggestion(sessionId: s3, attemptId: again.id, now: Date().addingTimeInterval(1_000)) == nil)
    }

    @Test func confidentMissOffersReflection() throws {
        let rig = try Rig()
        let q = try rig.numeric("Hard one", skill: rig.skillA, difficulty: 4)
        let (sid, items) = try session(rig, [q])
        #expect(try rig.history.shouldAskConfidence(itemId: items[0].id))
        let a = try submit(rig, items[0], text: "99")
        try rig.history.recordConfidence(attemptId: a.id, level: 3)
        let s = try #require(try rig.coach.suggestion(sessionId: sid, attemptId: a.id))
        #expect(s.trigger == .highConfidenceMiss && s.offersReflection)
        let m = try #require(try rig.history.mistakes(courseId: rig.course.id).first)
        #expect(m.wasHighConfidence && m.confidence == 3 && History.label(3) == "Sure")
    }
}

private enum History { static func label(_ l: Int) -> String { LearningHistoryService.confidenceLabel(l) } }

@Suite struct HistoryAndStuckTests {
    func item(_ rig: Rig, _ q: Question) throws -> SessionItem {
        let s = try rig.practice.start(questionIds: [q.id], title: "t", courseId: rig.course.id)
        return try rig.practice.items(sessionId: s.id)[0]
    }

    @Test func confidenceIsOnlyAskedWhereItMatters() throws {
        let rig = try Rig()
        let easy = try rig.numeric("easy", skill: rig.skillA, difficulty: 2), hard = try rig.numeric("hard", skill: rig.skillA, difficulty: 4)
        #expect(try rig.history.shouldAskConfidence(itemId: try item(rig, easy).id) == false)           // routine: don't interrupt
        #expect(try rig.history.shouldAskConfidence(itemId: try item(rig, hard).id) == true)            // difficult
        #expect(try rig.history.shouldAskConfidence(itemId: try item(rig, hard).id, setting: "off") == false)
        try rig.answerNumeric(easy, correct: false)
        #expect(try rig.history.shouldAskConfidence(itemId: try item(rig, easy).id) == true)            // missed before
        // Two recent misses on a skill also trigger it, even for a brand-new question.
        let other = try rig.numeric("other", skill: rig.skillA, difficulty: 2)
        try rig.answerNumeric(try rig.numeric("m2", skill: rig.skillA), correct: false)
        #expect(try rig.history.shouldAskConfidence(itemId: try item(rig, other).id) == true)
        #expect(try rig.history.shouldAskConfidence(itemId: try item(rig, try rig.numeric("fresh B", skill: rig.skillB)).id) == false)
    }

    @Test func mistakesWeakSpotsAndReflections() throws {
        let rig = try Rig()
        let q = try rig.numeric("Slippery", skill: rig.skillA)
        let a1 = try rig.answerNumeric(q, correct: false), a2 = try rig.answerNumeric(q, correct: false)
        try rig.answerNumeric(try rig.numeric("Fine", skill: rig.skillB), correct: true)
        let ms = try rig.history.mistakes(courseId: rig.course.id)
        #expect(ms.map(\.attemptId) == [a2.id, a1.id] && ms.map(\.timesMissed) == [2, 1])
        #expect(ms[0].skillNames == ["Java iterators"] && ms[0].responseSnippet == "99" && ms[0].score == 0)
        let weak = try rig.history.weakSpots(courseId: rig.course.id)
        #expect(weak.map(\.skill.id) == [rig.skillA.id] && weak[0].recentMisses == 2)
        try rig.history.addReflection(courseId: rig.course.id, text: "  I mixed up the units  ", attemptId: a2.id)
        try rig.history.addReflection(courseId: rig.course.id, text: "   ")                                 // empty: ignored
        #expect(try rig.history.reflections(courseId: rig.course.id).map(\.text) == ["I mixed up the units"])
        try rig.history.recordConfidence(attemptId: a1.id, level: 9)                                         // invalid: ignored
        #expect(try rig.history.confidence(attemptId: a1.id) == nil)
    }

    @Test func stuckGuidanceUsesPreparedHintsAndPrerequisites() throws {
        let rig = try Rig()
        try rig.courses.addRelation(from: rig.skillB.id, to: rig.skillA.id, kind: .prerequisite)
        let q = try rig.question(4, skills: [rig.skillA], title: "Needs help") { $0.hints = ["one", "two"] }
        let it = try item(rig, q)
        let stuck = StuckService(db: rig.db)
        let g = try stuck.guidance(itemId: it.id, kind: .dontUnderstandConcept)
        #expect(g.prerequisites.map(\.skill.id) == [rig.skillB.id] && g.prerequisites[0].mastery.isUnknown && g.hasNextHint)
        #expect(g.message.contains("builds on other skills") && g.objective.contains("Understand"))
        #expect(try stuck.guidance(itemId: it.id, kind: .dontKnowWhereToStart).message.contains("what is given"))
        try rig.practice.revealHint(itemId: it.id, level: 2)
        let spent = try stuck.guidance(itemId: it.id, kind: .stuckOnNextStep)
        #expect(!spent.hasNextHint && spent.message.contains("used all prepared hints"))
        #expect(StuckKind.allCases.count == 4 && StuckKind.allCases.allSatisfy { !$0.label.isEmpty })
        let coding = try rig.question(6, skills: [rig.skillA], title: "Code")
        #expect(try stuck.guidance(itemId: try item(rig, coding).id, kind: .solutionNotWorking).message.contains("can’t run code"))
    }

    @Test func tutorRequestDisclosesAndOmitsTheSolution() throws {
        let spec = QuestionValidator.validate(entry: Fx.all[6], index: 0).question!.spec          // coding
        var r = PracticeResponse(); r.files = [CodeFile(name: "Main.java", language: "java", content: "class Mine { int secretAttempt; }")]
        let withAttempt = TutorPrompt.build(spec: spec, response: r, kind: .stuckOnNextStep, revealedHints: 1, skillNames: ["Java iterators"], includeResponse: true)
        #expect(withAttempt.text.contains("Statement for CO") && withAttempt.text.contains("Where I'm stuck: I’m stuck on the next step."))
        #expect(withAttempt.text.contains("secretAttempt") && withAttempt.text.contains("Think about hasNext()"))
        #expect(!withAttempt.text.contains("class A { }"))                                           // reference solution never included
        #expect(withAttempt.disclosure.contains { $0.contains("current attempt") } && withAttempt.disclosure.last!.contains("Not included"))
        let without = TutorPrompt.build(spec: spec, response: r, kind: .dontUnderstandConcept, revealedHints: 0, skillNames: [], includeResponse: false)
        #expect(!without.text.contains("secretAttempt") && !without.disclosure.contains { $0.contains("attempt") && !$0.contains("Not included") })
    }
}

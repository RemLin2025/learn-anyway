import Testing
import Foundation
import GRDB
@testable import BraincellCore

/// Reuse must never trade educational fit for a better-looking reuse count. Each rule here has a test that would catch it being loosened.
extension AgentTests {
    /// A prepared course (topics Estimation / Maximum likelihood / Confidence intervals) with one finished one-shot preparation, so saved generated questions exist.
    func reuseEnv() async throws -> (E, Course, ExamPrepCoordinator, StudyPrepJob) {
        let (e, c) = try await guidedEnv()
        let co = ExamPrepCoordinator(e.ctx)
        _ = try await co.runAll(course: c, assessmentName: "Midterm 3", conversationId: e.conv)
        let other = try co.start(course: c, assessmentName: "Midterm 4")
        _ = try await co.analyze(other.id)
        return (e, c, co, other)
    }

    @Test func topicLevelReuseIsOptInLabelledAndStillRespectsTopicFormatAndDifficulty() async throws {
        let (e, _, co, j) = try await reuseEnv()
        let n = 10
        let strict = try co.plan(j.id, count: n, topicReuse: false)
        let loose = try co.plan(j.id, count: n, topicReuse: true)
        #expect(loose.reused > strict.reused && loose.topicOnly == loose.reused - strict.reused)             // the extra reuse is exactly the labelled topic-only part
        // every reused question really is on the slot's topic, in format and in range
        let svc = e.ctx.practiceSets
        let items = try svc.items(setId: loose.set.id)
        let qs = Dictionary(uniqueKeysWithValues: try svc.questions(setId: loose.set.id).map { ($0.id, $0.spec) })
        for i in items where i.isReused {
            let qid = try #require(i.questionId)
            let spec = try #require(qs[qid])
            let topic = try e.db.read { try String.fetchOne($0, sql: "SELECT topicKey FROM question_archetype_links WHERE questionId = ?", arguments: [qid]) }
            #expect(topic == i.slot.topic.skillKey)
            #expect(abs(spec.difficulty - i.slot.difficulty) <= 1)
            #expect(i.slot.format == "any" || spec.type.rawValue == i.slot.format)
        }
        // the learner's difficulty range and format constraints are never overridden
        let hard = try co.plan(j.id, count: n, minDifficulty: 5, maxDifficulty: 5, topicReuse: true)
        #expect(hard.reused == 0 && hard.missing == n)
        let numeric = try co.plan(j.id, count: n, types: [.numeric], topicReuse: true)
        #expect(numeric.reused == 0)                                                                         // saved questions are single-choice: not a numeric question
    }

    @Test func aQuestionOnAnotherTopicIsNeverReused() async throws {
        let (e, c, co, j) = try await reuseEnv()
        // Keep only a topic that has no saved question: nothing may be substituted from the other topics.
        let skill = try e.ctx.courses.addSkill(courseId: c.id, name: "Bootstrap resampling").skill
        let all = try e.ctx.courses.skills(courseId: c.id)
        var p = GenerationParams(count: 4); p.skillIds = [skill.id]
        let prepared = try e.ctx.practiceSets.prepare(courseId: c.id, params: p, requestKey: "other-topic", topicReuse: true)
        #expect(prepared.reused == 0 && prepared.missing == 4 && all.count >= 4)
    }

    @Test func savedQuestionsFromAnotherCourseAreNeverReused() async throws {
        let (e, _, _, _) = try await reuseEnv()
        let c2 = try e.ctx.courses.createCourse(name: "OTHER101")
        for n in ["Estimation", "Maximum likelihood", "Confidence intervals"] { _ = try e.ctx.courses.addSkill(courseId: c2.id, name: n) }
        let prepared = try e.ctx.practiceSets.prepare(courseId: c2.id, params: GenerationParams(count: 6), requestKey: "x", topicReuse: true)
        #expect(prepared.reused == 0 && prepared.missing == 6)
    }

    @Test func topicOnlyReuseSkipsQuestionsFlaggedForReviewButExactMatchesKeepWorking() async throws {
        let (e, c, co, j) = try await reuseEnv()
        let strictBefore = try co.plan(j.id, count: 10, topicReuse: false)
        let before = try co.plan(j.id, count: 10, topicReuse: true)
        #expect(before.topicOnly > 0)
        try e.db.write { try $0.execute(sql: "UPDATE questions SET readiness = 'needsReview' WHERE courseId = ?", arguments: [c.id]) }
        let after = try co.plan(j.id, count: 10, requestKey: "after-flag", topicReuse: true)           // a new request, not the earlier identical one
        #expect(after.topicOnly == 0)                                                                         // a flagged question is never substituted by topic alone
        let strictAfter = try co.plan(j.id, count: 10, requestKey: "strict-after", topicReuse: false)
        #expect(strictAfter.reused == strictBefore.reused)                                                    // exact slot matches behave exactly as before
    }

    @Test func instructorPatternSlotsAreNeverFilledByTopicOnlyReuse() async throws {
        // With analysed instructor practice problems the planner gives slots exemplars / a learned archetype; those must be generated or exactly matched.
        let (e, c, _, _, svc) = try await setEnv()
        let p = try svc.prepare(courseId: c.id, params: gparams(2)); _ = try await svc.generateMissing(setId: p.set.id, gateway: e.ctx.gateway)
        try e.db.write { try $0.execute(sql: "UPDATE question_archetype_links SET kind = 'someOtherPattern', archetypeKey = 'course|other|pattern'") }     // saved questions follow a different pattern
        let q = try svc.prepare(courseId: c.id, params: gparams(2), requestKey: "pattern", topicReuse: true)
        #expect(q.reused == 0 && q.topicOnly == 0 && q.missing == 2)
    }
}

import Testing
import Foundation
import GRDB
@testable import BraincellCore

extension AgentTests {
    func guidedEnv() async throws -> (E, Course) {
        let m = SetModel()
        let e = try await env { _, user, _ in user.contains("You analyze course material") ? Self.topicsJSON : m.reply(user, analysis: "{}") }
        let c = try e.ctx.courses.createCourse(name: "STOR435")
        let d = try insertDoc(e, c, name: "outline.pdf", status: .ok, pages: 5)
        try insertChunk(e, d, 0, page: 1, "Midterm 3 covers Chapter 2. Chapter 2 is worth 40% of the exam grade.")
        try insertChunk(e, d, 1, page: 2, "Worked example: maximum likelihood estimate of the rate.")
        return (e, c)
    }

    @Test func guidedPrepAnalyzesOnceStopsForReviewAndPlansBeforeAnyGenerationCost() async throws {
        let (e, c) = try await guidedEnv()
        let co = ExamPrepCoordinator(e.ctx)
        let job = try co.start(course: c, assessmentName: "Midterm 3")
        #expect(try co.start(course: c, assessmentName: "midterm 3").id == job.id)                   // same job, same assessment: nothing duplicated
        #expect(try e.ctx.courses.assessments(courseId: c.id).count == 1)
        let m = try co.materials(courseId: c.id, job: job)
        #expect(m.readable.count == 1 && m.gaps.isEmpty && !m.analysisStale)
        #expect(e.script.count == 0)                                                                    // stages 1–2 are local only

        let analyzed = try await co.analyze(job.id)
        #expect(analyzed.status == .awaitingReview && analyzed.state.topicCount == 3 && e.script.count == 1)
        #expect(try questionCount(e) == 0)                                                              // nothing is generated before the learner reviews the map
        let again = try await co.analyze(job.id)
        #expect(again.state.mapId == analyzed.state.mapId && e.script.count == 1)                       // unchanged sources: no second model call

        try co.setExcluded(job.id, topics: ["Hypothesis tests"])
        try co.setTemplate(job.id, templateId: "builtin.guided")
        #expect(e.script.count == 1)                                                                    // editing the map and choosing a template cost nothing
        let plan = try co.plan(job.id, count: 3)
        #expect(plan.reused == 0 && plan.missing == 3 && e.script.count == 1)                           // the breakdown is known before any generation
        let planned = try #require(try co.job(job.id))
        #expect(planned.state.setId == plan.set.id && planned.state.templateId == "builtin.guided")
        #expect(try e.ctx.practiceSets.practiceSet(plan.set.id)?.templateId == "builtin.guided")
        let kept = try co.includedSkillIds(planned)
        let skillNames = try e.ctx.courses.skills(courseId: c.id).filter { kept.contains($0.id) }.map(\.name)
        #expect(!skillNames.contains("Hypothesis tests") && skillNames.contains("Estimation"))

        let replanned = try co.plan(job.id, count: 2)                                                   // changing the plan replaces the unused set
        #expect(replanned.set.id != plan.set.id)
        #expect(try e.ctx.practiceSets.sets(courseId: c.id).map(\.id) == [replanned.set.id])
        #expect(try e.ctx.practiceSets.deletedSets(courseId: c.id).isEmpty)                              // a superseded plan is discarded, not parked in Recently Deleted

        let r = try await co.generate(job.id)
        let qn = try questionCount(e)
        #expect(r.filled > 0 && qn > 0 && e.script.count > 1)
        let final = try #require(try co.job(job.id))
        #expect(final.stage == .completed)
    }

    @Test func changedSourcesMarkTheSavedAnalysisStale() async throws {
        let (e, c) = try await prepEnv()
        let co = ExamPrepCoordinator(e.ctx)
        let job = try co.start(course: c, assessmentName: "Midterm 3")
        let analyzed = try await co.analyze(job.id)
        _ = try insertDoc(e, c, name: "new-notes.pdf", status: .ok, pages: 1)
        #expect(try co.materials(courseId: c.id, job: analyzed).analysisStale)
    }
}

extension AgentTests {
    @Test func chatLaunchesTheSameWorkflowWithoutAnyModelCallOrDuplicateJob() async throws {
        let (e, c) = try await guidedEnv()
        let out1 = try await self.run("exam.workflow", ["course": "STOR435", "assessment": "Midterm 3"], e)
        #expect(out1.chips.contains { $0.action == "prepareExam" && $0.courseId == c.id } && e.script.count == 0)
        let out2 = try await self.run("exam.workflow", ["course": "STOR435", "assessment": "midterm 3"], e)
        #expect(out2.summary == "Opened preparation")
        #expect(try ExamPrepCoordinator(e.ctx).jobs(courseId: c.id).count == 1)                         // the app wizard and chat share one job
        let co = ExamPrepCoordinator(e.ctx)
        #expect(co.existingJob(courseId: c.id, assessmentName: "Midterm 3") != nil)
        let j = try await co.analyze(try #require(try co.jobs(courseId: c.id).first).id)                 // the wizard continues the job chat opened
        #expect(j.state.topicCount == 3)
    }
}

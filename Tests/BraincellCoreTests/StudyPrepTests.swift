import Testing
import Foundation
import GRDB
@testable import BraincellCore

/// The staged exam-preparation job. The model is scripted; sources, validation, dedupe and persistence are the real code.
extension AgentTests {
    static let topicsJSON = """
    {"topics":[
     {"name":"Estimation","objectives":["Derive MLEs"],"sources":[{"document":"outline.pdf","page":1}],"importance":{"level":"high","source":"instructor","weightPercent":40,"evidence":"Chapter 2 is worth 40% of the exam grade"}},
     {"name":"Maximum likelihood","parent":"Estimation","sources":[{"document":"outline.pdf","page":2}],"importance":{"level":"medium","source":"estimated","evidence":"appears in the worked example"}},
     {"name":"Hypothesis tests","sources":[{"document":"outline.pdf","page":99}],"importance":{"level":"low","source":"unknown","evidence":""}}],
     "structures":[]}
    """

    func prepEnv(modelFailsOnQuestions: Bool = false) async throws -> (E, Course) {
        let box = LockedBox<Int>(0)
        let e = try await env { _, user, _ in
            if user.contains("You analyze course material") { return Self.topicsJSON }
            if user.contains("req-") {
                if modelFailsOnQuestions && box.withLock({ $0 += 1; return $0 }) == 1 { return "" }
                return Fx.envelope(self.requestId(user), Array(Fx.all.prefix(3)))
            }
            return "ok"
        }
        let c = try e.ctx.courses.createCourse(name: "STOR435")
        let d = try insertDoc(e, c, name: "outline.pdf", status: .ok, pages: 5)
        try insertChunk(e, d, 0, page: 1, "Midterm 3 covers Chapter 2. Chapter 2 is worth 40% of the exam grade.")
        try insertChunk(e, d, 1, page: 2, "Worked example: maximum likelihood estimate of the rate.")
        return (e, c)
    }
    func prep(_ e: E, _ c: Course, regenerate: Bool = false) async throws -> ToolOutput {
        try await StudyPrep.run(course: c, assessmentName: "Midterm 3", regenerate: regenerate, conversationId: e.conv, e.ctx, stage: { _ in })
    }
    func questionCount(_ e: E) throws -> Int { try e.db.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM questions") ?? 0 } }

    @Test func prepRunsAllStagesFromOneToolCallAndSavesRealResults() async throws {
        let (e, c) = try await prepEnv()
        let out = try await prep(e, c)
        let job = try #require(try StudyPrep.jobs(courseId: c.id, e.db).first)
        #expect(job.status == .completed && job.stage == .completed)
        #expect(job.state.topicCount == 3 && job.state.topicsWithSources == 2)                      // page 99 doesn't exist: reference dropped, not invented
        #expect(try questionCount(e) == job.state.accepted && job.state.accepted > 0)
        let skills = try e.ctx.courses.skills(courseId: c.id).map(\.name)
        #expect(["Estimation", "Maximum likelihood", "Hypothesis tests"].allSatisfy(skills.contains))
        let asms = try e.ctx.courses.assessments(courseId: c.id)
        #expect(asms.count == 1 && asms[0].name == "Midterm 3" && asms[0].deadline == nil)          // created once, no invented date
        #expect(try e.ctx.courses.scopedSkills(assessmentId: asms[0].id).count == 3)
        #expect(out.text.contains("\(job.state.accepted) practice question") && ["openSkills", "openQuestionBank", "startPractice", "openCourse", "prepareExam"].allSatisfy { a in out.chips.contains { $0.action == a } })
        #expect(e.script.count == 1 + (try e.ctx.ai.batches(taskId: job.state.taskId!).count))     // one topic call + one per question batch, nothing repeated
    }

    @Test func rerunWithUnchangedSourcesReusesSavedWorkAndNeverDuplicatesAssessments() async throws {
        let (e, c) = try await prepEnv()
        _ = try await prep(e, c)
        let calls = e.script.count, qs = try questionCount(e)
        let again = try await prep(e, c)
        #expect(try e.script.count == calls && questionCount(e) == qs && again.text.contains("Already prepared"))
        #expect(try e.ctx.courses.assessments(courseId: c.id).count == 1 && (try StudyPrep.jobs(courseId: c.id, e.db).count) == 1)
    }

    @Test func changedSourceIsDetectedAndOnlyThenReanalyzed() async throws {
        let (e, c) = try await prepEnv()
        _ = try await prep(e, c)
        let before = e.script.count
        let d2 = try insertDoc(e, c, name: "extra.pdf", status: .ok, pages: 1); try insertChunk(e, d2, 0, page: 1, "More about confidence intervals.")
        _ = try await prep(e, c)
        #expect(e.script.count > before)                                                            // sources changed → analyzed again
        #expect(try e.ctx.courses.skills(courseId: c.id).filter { $0.name == "Estimation" }.count == 1)   // topics matched by name, not duplicated
    }

    @Test func providerFailureKeepsTopicsAndResumesAtTheFailedStageWithoutDuplicates() async throws {
        let (e, c) = try await prepEnv(modelFailsOnQuestions: true)
        let first = try await prep(e, c)
        var job = try #require(try StudyPrep.jobs(courseId: c.id, e.db).first)
        #expect(job.status != .completed && job.state.mapId != nil && job.state.topicCount == 3)
        #expect(first.chips.contains { $0.action == "prepareExam" })
        let topicCalls = e.script.prompts.filter { $0.user.contains("You analyze course material") }.count
        _ = try await prep(e, c)                                                                    // resume
        job = try #require(try StudyPrep.jobs(courseId: c.id, e.db).first)
        #expect(job.status == .completed && job.state.accepted > 0)
        #expect(e.script.prompts.filter { $0.user.contains("You analyze course material") }.count == topicCalls)    // topic analysis was not repeated
        #expect(try e.ctx.courses.skills(courseId: c.id).filter { $0.name == "Estimation" }.count == 1 && StudyPrep.jobs(courseId: c.id, e.db).count == 1)
    }

    @Test func noReadableMaterialsProducesNoFabricatedTopicsOrQuestions() async throws {
        let e = try await env { _, _, _ in "ok" }
        let c = try e.ctx.courses.createCourse(name: "EMPTY1")
        let out = try await prep(e, c)
        #expect(try out.text.contains("no readable materials") && e.script.count == 0 && questionCount(e) == 0)
    }

    @Test func sharesKeepInstructorWeightsAndNormalizeOnlyEstimates() {
        func t(_ n: String, _ lvl: String, _ s: StudyMapDocument.Importance.Source, _ w: Double? = nil) -> StudyMapDocument.Topic {
            .init(name: n, objectives: [], prerequisites: [], sources: [], importance: .init(level: lvl, source: s, weightPercent: w, evidence: "e"))
        }
        let sh = StudyPrep.shares([t("A", "high", .instructor, 40), t("B", "high", .estimated), t("C", "low", .estimated), t("D", "unknown", .unknown)])
        #expect(sh["A"] == 40 && sh["D"] == nil)                                                    // official kept; unknown not invented
        #expect(abs((sh["B"]! + sh["C"]!) - 60) < 0.2 && sh["B"]! > sh["C"]!)                       // estimates share only the unclaimed 60%
        let only = StudyPrep.shares([t("X", "high", .estimated), t("Y", "medium", .estimated)])
        #expect(abs(only.values.reduce(0, +) - 100) < 0.2)
    }

    @Test func rewordedIdenticalSearchesAreTreatedAsRepeatsAndDoNotConsumeTheBudget() async throws {
        let (e, _) = try await prepEnv()
        let q = ["maximum likelihood", "likelihood maximum", "Maximum  Likelihood!"]
        let e2 = try await env { _, _, n in n <= 3 ? self.call("sources.search", ["course": "STOR435", "query": q[n - 1]]) : "done" }
        let c = try e2.ctx.courses.createCourse(name: "STOR435")
        let d = try insertDoc(e2, c, name: "o.pdf", status: .ok, pages: 2); try insertChunk(e2, d, 0, page: 1, "maximum likelihood estimation")
        await e2.runner.send(e2.conv, text: "go")
        #expect(try e2.db.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM agent_actions WHERE tool = 'sources.search'") } == 1)
        _ = e
    }

    @Test func chatCallsExamPrepareOnceAndStopsWithoutRepeatedSearches() async throws {
        let box = LockedBox<Int>(0)
        let e = try await env { _, user, _ in
            if user.contains("You analyze course material") { return Self.topicsJSON }
            if user.contains("req-") { return Fx.envelope(self.requestId(user), Array(Fx.all.prefix(3))) }
            return box.withLock { $0 += 1; return $0 } == 1 ? self.call("exam.prepare", ["course": "STOR435", "assessment": "Midterm 3"]) : "Your Midterm 3 preparation is ready."
        }
        let c = try e.ctx.courses.createCourse(name: "STOR435")
        let d = try insertDoc(e, c, name: "outline.pdf", status: .ok, pages: 5)
        try insertChunk(e, d, 0, page: 1, "Chapter 2 is worth 40% of the exam grade."); try insertChunk(e, d, 1, page: 2, "Maximum likelihood example.")
        await ask(e, "Help me prepare for Midterm 3 in STOR435")
        let tools = try toolMessages(e)
        #expect(tools.count == 1 && tools[0].content.contains("practice question"))
        #expect(try msgs(e).last?.content == "Your Midterm 3 preparation is ready." && (try msgs(e).contains { $0.kind == .actions && ($0.payload ?? "").contains("startPractice") }))
    }
}

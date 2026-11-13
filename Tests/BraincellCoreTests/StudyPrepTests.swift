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
        #expect(try StudyPrep.jobs(courseId: c.id, e.db).first?.status == .completed)
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

    @Test func chatOffersPreparationWorkspaceWithoutBypassingReview() async throws {
        let box = LockedBox<Int>(0)
        let e = try await env { _, user, _ in
            if user.contains("You analyze course material") { return Self.topicsJSON }
            if user.contains("req-") { return Fx.envelope(self.requestId(user), Array(Fx.all.prefix(3))) }
            return box.withLock { $0 += 1; return $0 } == 1 ? self.call("exam.prepare", ["course": "STOR435", "assessment": "Midterm 3"]) : "Open Prepare for an exam to review your materials."
        }
        let c = try e.ctx.courses.createCourse(name: "STOR435")
        let d = try insertDoc(e, c, name: "outline.pdf", status: .ok, pages: 5)
        try insertChunk(e, d, 0, page: 1, "Chapter 2 is worth 40% of the exam grade."); try insertChunk(e, d, 1, page: 2, "Maximum likelihood example.")
        await ask(e, "Help me prepare for Midterm 3 in STOR435")
        let tools = try toolMessages(e)
        #expect(tools.count == 1 && tools[0].content.contains("No questions have been generated"))
        #expect(try questionCount(e) == 0)
        #expect(try msgs(e).last?.content == "Open Prepare for an exam to review your materials." && (try msgs(e).contains { $0.kind == .actions && ($0.payload ?? "").contains("prepareExam") }))
    }
}

extension AgentTests {
    @Test func reviewOnlySavesFindingsWithoutGeneratingOrApplyingTopics() async throws {
        let (e, c) = try await prepEnv()
        let docs = try e.ctx.docs.documents(courseId: c.id)
        let a = try e.ctx.courses.addAssessment(courseId: c.id, name: "Midterm 3")
        var w = ExamWorkspace(assessmentId: a.id)
        w.materials = docs.map { ExamMaterial(id: $0.id) }; try w.save(e.db)
        _ = try await StudyPrep.run(course: c, assessmentName: a.name, documentIds: docs.map(\.id), instructions: w.analysisInstructions, reviewOnly: true, conversationId: w.conversationId, e.ctx, stage: { _ in })
        let job = try #require(try StudyPrep.jobs(courseId: c.id, e.db).first)
        #expect(job.status == .paused && job.state.mapId != nil)
        #expect(job.state.taskId == nil && e.script.count == 1)
        #expect(try e.ctx.store.map(try #require(job.state.mapId))?.conversationId == nil)
        #expect(try questionCount(e) == 0 && e.ctx.courses.skills(courseId: c.id).isEmpty)
        w.proposal = try e.ctx.store.map(try #require(job.state.mapId))?.document
        w.excluded = [2]
        w.proposal?.topics[0].name = "Learner-edited estimation"
        try w.approve(e.ctx, courseId: c.id)
        let saved = try #require(try e.ctx.store.map(try #require(job.state.mapId))?.document)
        #expect(saved.topics.count == 2 && saved.topics[0].name == "Learner-edited estimation")
        #expect(try ExamWorkspace.load(assessmentId: a.id, e.db).approved)
        _ = try await StudyPrep.run(course: c, assessmentName: a.name, documentIds: docs.map(\.id), instructions: w.analysisInstructions, questionCount: 3, conversationId: w.conversationId, e.ctx, stage: { _ in })
        #expect(try StudyPrep.jobs(courseId: c.id, e.db).first?.status == .completed)
        #expect(e.script.prompts.filter { $0.user.contains("You analyze course material") }.count == 1)
    }

    @Test func explicitSelectionCannotGenerateWithoutApproval() async throws {
        let (e, c) = try await prepEnv()
        let docs = try e.ctx.docs.documents(courseId: c.id)
        let out = try await StudyPrep.run(course: c, assessmentName: "Midterm 3", documentIds: docs.map(\.id), conversationId: e.conv, e.ctx, stage: { _ in })
        #expect(out.text.contains("approve") && e.script.count == 0)
        #expect(try questionCount(e) == 0)
    }

    @Test func materialAssociationsAreSharedAndAssessmentSpecific() async throws {
        let (e, c) = try await prepEnv()
        let doc = try #require(try e.ctx.docs.documents(courseId: c.id).first)
        let a = try e.ctx.courses.addAssessment(courseId: c.id, name: "Midterm 2")
        let b = try e.ctx.courses.addAssessment(courseId: c.id, name: "Final")
        var first = ExamWorkspace(assessmentId: a.id), second = ExamWorkspace(assessmentId: b.id)
        first.materials = [ExamMaterial(id: doc.id)]; second.materials = first.materials
        first.materials[0].relevance = .confirmed; first.materials[0].kind = .notes
        try first.save(e.db); try second.save(e.db)
        #expect(try e.ctx.docs.assessmentIds(documentId: doc.id) == [a.id, b.id])
        #expect(try ExamWorkspace.load(assessmentId: a.id, e.db).materials[0].relevance == .confirmed)
        first.materials = []; try first.save(e.db)
        #expect(try e.ctx.docs.assessmentIds(documentId: doc.id) == [b.id])
        #expect(try e.ctx.docs.documents(courseId: c.id).count == 1)
    }

    @Test func exhaustedTopicBudgetCanBeRetriedExplicitly() async throws {
        let valid = LockedBox<Bool>(false)
        let e = try await env { _, _, _ in valid.withLock { $0 } ? Self.topicsJSON : "invalid JSON" }
        let c = try e.ctx.courses.createCourse(name: "STOR435")
        let d = try insertDoc(e, c, name: "outline.pdf", status: .ok, pages: 1)
        try insertChunk(e, d, 0, page: 1, "Chapter 2 is worth 40% of the exam grade.")
        _ = try await StudyPrep.run(course: c, assessmentName: "Midterm 3", reviewOnly: true, conversationId: e.conv, e.ctx, stage: { _ in })
        #expect(e.script.count == StudyPrep.maxRetriesPerStage + 1)
        valid.withLock { $0 = true }
        _ = try await StudyPrep.run(course: c, assessmentName: "Midterm 3", reviewOnly: true, conversationId: e.conv, e.ctx, stage: { _ in })
        #expect(try StudyPrep.jobs(courseId: c.id, e.db).first?.state.mapId != nil)
        #expect(e.script.count == StudyPrep.maxRetriesPerStage + 2)
    }

    @Test func missingSelectedDocumentPausesRatherThanLeavingRunningJob() async throws {
        let (e, c) = try await prepEnv()
        _ = try await StudyPrep.run(course: c, assessmentName: "Midterm 3", documentIds: [UUID()], reviewOnly: true, conversationId: e.conv, e.ctx, stage: { _ in })
        let job = try #require(try StudyPrep.jobs(courseId: c.id, e.db).first)
        #expect(job.status == .paused && job.error != nil && e.script.count == 0)
    }
}


extension AgentTests {
    @Test func ambiguousSourceNamesAreRejectedInsteadOfCitingTheWrongFile() async throws {
        let (e, c) = try await prepEnv()
        let other = try e.ctx.courses.createCourse(name: "OTHER")
        _ = try insertDoc(e, other, name: "outline.pdf", status: .ok, pages: 5)
        let docs = try StudyPrep.availableDocuments(e.ctx)
        let (ref, warning) = AgentRegistry.resolveRef(["document": "outline.pdf", "page": 1], docs: docs, chunks: { (try? e.ctx.docs.chunks(documentId: $0)) ?? [] })
        #expect(ref == nil && warning != nil)
        let exact = try #require(try e.ctx.docs.documents(courseId: c.id).first)
        let (idRef, _) = AgentRegistry.resolveRef(["document": exact.id.uuidString, "page": 1], docs: docs, chunks: { (try? e.ctx.docs.chunks(documentId: $0)) ?? [] })
        #expect(idRef?.documentId == exact.id)
    }
}

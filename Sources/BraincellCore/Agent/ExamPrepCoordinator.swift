import Foundation
import GRDB

/// The shared exam-preparation workflow. Application code owns the stages and their order; the model is only called for topic analysis (once per
/// unchanged set of sources) and for generating questions that saved ones can't cover. The UI wizard and the chat launcher both go through this
/// class and the same persisted `StudyPrepJob`, so leaving and returning, or starting in chat and finishing in the app, continue the same work.
public final class ExamPrepCoordinator: @unchecked Sendable {
    let c: AgentContext
    public init(_ ctx: AgentContext) { c = ctx }
    /// The chip the launcher tool returns. The app opens the workflow automatically for it; other "prepareExam" chips (e.g. Regenerate) only open it on click.
    public static let openChipLabel = "Open preparation"

    public struct Materials: Sendable {
        public var readable: [Document]
        public var gaps: [String]
        public var fingerprint: String
        /// The saved analysis was made from different files than are in the course now.
        public var analysisStale: Bool
    }

    /// The given conversation if it still exists, otherwise a new one (study maps are saved against a conversation).
    func liveConversation(_ id: UUID?, course: Course) throws -> UUID {
        if let id, (try? c.store.conversation(id)) != nil { return id }
        return try c.store.createConversation(courseId: course.id).id
    }

    public func jobs(courseId: UUID) throws -> [StudyPrepJob] { try StudyPrep.jobs(courseId: courseId, c.db) }
    public func job(_ id: UUID) throws -> StudyPrepJob? { try c.db.read { try StudyPrepJob.fetchOne($0, key: id) } }

    /// Finds or creates the assessment by name and the job for it. No model call; nothing is invented (no date, no scope).
    @discardableResult
    public func start(course: Course, assessmentName: String, conversationId: UUID? = nil) throws -> StudyPrepJob {
        let n = assessmentName.trimmingCharacters(in: .whitespacesAndNewlines)
        var asm: Assessment?
        if !n.isEmpty {
            asm = try c.courses.assessments(courseId: course.id).first { AgentContext.norm($0.name) == AgentContext.norm(n) }
            if asm == nil {
                let l = n.lowercased()
                asm = try c.courses.addAssessment(courseId: course.id, name: n, kind: l.contains("final") ? .final : l.contains("quiz") ? .quiz : l.contains("midterm") || l.contains("exam") ? .midterm : .other)
            }
        }
        if let e = try jobs(courseId: course.id).first(where: { $0.assessmentId == asm?.id && $0.status != .cancelled }) { return e }
        let conv = try liveConversation(conversationId, course: course)      // study maps are saved against a conversation, so the work also appears in chat history
        var j = StudyPrepJob(id: UUID(), conversationId: conv, courseId: course.id, assessmentId: asm?.id, stage: .created, status: .paused, stateJSON: "{}", error: nil, createdAt: c.now(), updatedAt: c.now())
        try StudyPrep.save(&j, PrepState(), c)
        return j
    }

    /// Stage 2: what the course has and what can't be used. Local only.
    public func materials(courseId: UUID, job: StudyPrepJob? = nil) throws -> Materials {
        let docs = try c.docs.documents(courseId: courseId)
        let readable = docs.filter { ($0.kind == .pdf || $0.kind == .text || $0.kind == .pasted) && $0.extractionStatus != .failed && $0.extractionStatus != .notApplicable }
        let gaps = docs.filter { !readable.contains($0) }.map(\.name) + docs.filter { $0.extractionStatus == .partial }.map { "\($0.name) (partly readable)" }
        let fp = StudyPrep.fingerprint(readable), saved = job?.state.fingerprint ?? ""
        return Materials(readable: readable, gaps: gaps, fingerprint: fp, analysisStale: !saved.isEmpty && saved != fp)
    }

    /// Stage 3: analysis. Reuses the saved study map while the sources are unchanged (no model call); resumes after a failure.
    @discardableResult
    public func analyze(_ jobId: UUID, stage: @escaping @Sendable (String) -> Void = { _ in }) async throws -> StudyPrepJob {
        guard let j = try job(jobId), let course = try c.courses.courses(includeArchived: true).first(where: { $0.id == j.courseId }) else { throw ToolError.unavailable("That preparation no longer exists.") }
        let name = try j.assessmentId.flatMap { id in try c.courses.assessments(courseId: course.id).first { $0.id == id }?.name }
        _ = try await StudyPrep.run(course: course, assessmentName: name, conversationId: try liveConversation(j.conversationId, course: course), c, stage: stage)
        return try job(jobId) ?? j
    }

    public func studyMap(_ j: StudyPrepJob) throws -> StudyMapDocument? { try j.state.mapId.flatMap { try c.store.map($0) }?.document }

    private func mutate(_ id: UUID, _ f: (inout PrepState) -> Void) throws -> StudyPrepJob {
        guard var j = try job(id) else { throw ToolError.unavailable("That preparation no longer exists.") }
        var s = j.state; f(&s); try StudyPrep.save(&j, s, c); return j
    }
    public func setStep(_ id: UUID, _ step: String) throws { _ = try mutate(id) { $0.wizardStep = step } }
    public func setExcluded(_ id: UUID, topics: [String]) throws { _ = try mutate(id) { $0.excludedTopics = topics } }
    public func setTemplate(_ id: UUID, templateId: String) throws { _ = try mutate(id) { $0.templateId = templateId } }       // presentation only: nothing is invalidated
    public func setParams(_ id: UUID, _ p: GenerationParams) throws { _ = try mutate(id) { $0.params = p } }

    /// Skills of the topics the learner kept (names match the skills created from the study map).
    func includedSkillIds(_ j: StudyPrepJob) throws -> [UUID] {
        let excluded = Set((j.state.excludedTopics ?? []).map(AgentContext.norm))
        let skills = try c.courses.skills(courseId: j.courseId)
        let topics = try studyMap(j)?.topics.map(\.name) ?? []
        let keep = Set(topics.filter { !excluded.contains(AgentContext.norm($0)) }.map(AgentContext.norm))
        return skills.filter { keep.contains(AgentContext.norm($0.name)) }.map(\.id)
    }

    public struct Plan: Sendable, Equatable {
        public var set: PracticeSet; public var reused: Int; public var missing: Int
        /// Of `reused`, how many were chosen by topic alone (different reasoning pattern from the slot). Shown to the learner, never hidden.
        public var topicOnly: Int
        public init(set: PracticeSet, reused: Int, missing: Int, topicOnly: Int = 0) { self.set = set; self.reused = reused; self.missing = missing; self.topicOnly = topicOnly }
    }

    /// The plan already saved on the job (after a restart), recomputed from the set's real items.
    public func currentPlan(_ id: UUID) -> Plan? {
        guard let j = try? job(id), let sid = j.state.setId, let set = try? c.practiceSets.practiceSet(sid), set.deletedAt == nil, let items = try? c.practiceSets.items(setId: sid) else { return nil }
        return Plan(set: set, reused: items.filter(\.isReused).count, missing: items.filter { $0.questionId == nil }.count, topicOnly: items.filter(\.isTopicOnlyReuse).count)
    }

    /// The saved job for a course + assessment name, if there is one.
    public func existingJob(courseId: UUID, assessmentName: String) -> StudyPrepJob? {
        guard let asm = try? c.courses.assessments(courseId: courseId).first(where: { AgentContext.norm($0.name) == AgentContext.norm(assessmentName) }) else { return nil }
        return (try? jobs(courseId: courseId))?.first { $0.assessmentId == asm.id && $0.status != .cancelled }
    }

    /// Stage 6: how many saved questions fit and how many would be generated. Creates (or replaces) the planned set but calls no model.
    @discardableResult
    public func plan(_ id: UUID, count: Int, minDifficulty: Int = 1, maxDifficulty: Int = 5, types: [QuestionType] = [], fresh: Bool = false, generateMissing: Bool = true, requestKey: String? = nil, topicReuse: Bool = true) throws -> Plan {
        guard let j = try job(id) else { throw ToolError.unavailable("That preparation no longer exists.") }
        let skills = try includedSkillIds(j)
        var params = GenerationParams(count: max(1, min(count, 60)), types: types, minDifficulty: minDifficulty, maxDifficulty: maxDifficulty, skillIds: skills, documentIds: [], mode: .matchInstructorStyle)
        params.notes = "Exam preparation questions for \(j.assessmentId.map { _ in "the assessment" } ?? "the course"). Generated practice, not the real exam."
        // A changed plan replaces the unused set from the previous plan; a set that already has attempts is never touched.
        if let old = j.state.setId, (try c.practiceSets.progress(setId: old)).state == .notStarted { try c.practiceSets.delete(setId: old) }
        let p = try c.practiceSets.prepare(courseId: j.courseId, assessmentId: j.assessmentId, params: params, fresh: fresh, requestKey: requestKey, topicReuse: topicReuse)
        if let t = j.state.templateId { try c.practiceSets.update(setId: p.set.id, templateId: t) }
        // Name the set after the exam so it can be found in the Library and on the Practice tab ("Midterm 3 practice · 10 questions").
        var named = p.set
        if let aid = j.assessmentId, let an = try c.courses.assessments(courseId: j.courseId).first(where: { $0.id == aid })?.name {
            let title = "\(an) practice · \(params.count) questions"
            try c.practiceSets.update(setId: p.set.id, title: title); named.title = title
        }
        _ = try mutate(id) { $0.params = params; $0.setId = p.set.id; $0.wizardStep = "create" }
        return Plan(set: named, reused: p.reused, missing: generateMissing ? p.missing : 0, topicOnly: p.topicOnly)
    }

    /// Stage 7: generate only what the plan found missing, validate and save, then mark the job complete. Failed batches can simply be run again.
    public func generate(_ id: UUID) async throws -> SetGenerationReport {
        guard let j = try job(id), let setId = j.state.setId else { throw ToolError.unavailable("Make a plan first.") }
        let r = try await c.practiceSets.generateMissing(setId: setId, gateway: c.gateway)
        var j2 = j
        var s = j.state; s.modelCalls += r.modelCalls; s.accepted += r.filled
        try StudyPrep.save(&j2, s, c, stage: .completed, status: r.missing == 0 ? .completed : .partial, error: r.missing == 0 ? nil : "\(r.missing) question(s) could not be generated; run it again to retry only those.")
        return r
    }

    // MARK: One-shot path (chat's `exam.prepare` and any older caller)

    /// Runs every stage without stopping for review, through exactly the same job, analysis cache, study map, plan and generation as the wizard.
    /// A second call with unchanged sources reuses everything and makes no model call; `regenerate` plans a fresh set (saved questions are still reused where they fit).
    public func runAll(course: Course, assessmentName: String, regenerate: Bool = false, conversationId: UUID, stage: @escaping @Sendable (String) -> Void = { _ in }) async throws -> ToolOutput {
        let job = try start(course: course, assessmentName: assessmentName, conversationId: conversationId)
        let mat = try materials(courseId: course.id, job: job)
        guard !mat.readable.isEmpty else {
            return ToolOutput(text: "\(course.name) has no readable materials, so nothing could be organized or generated. Ask the learner to add text-based notes, slides or a syllabus (PDF, Markdown, TXT or pasted text). Do not infer the content from the course name.", summary: "No readable materials",
                              chips: [ActionChip(label: "Add materials", action: "addFiles", courseId: course.id)])
        }
        let before = currentPlan(job.id)
        let analyzed = try await analyze(job.id, stage: stage)
        guard analyzed.state.mapId != nil else {
            return ToolOutput(text: "Stopped at “\(analyzed.stage.label)”: \(analyzed.error ?? "the analysis did not finish"). Progress is saved. Tell the learner they can resume and it continues without repeating finished work.", summary: "Paused at \(analyzed.stage.label)",
                              chips: [ActionChip(label: "Resume preparation", action: "prepareExam", courseId: course.id, assessmentId: analyzed.assessmentId)])
        }
        let cached = !regenerate && analyzed.status == .completed && before != nil && before?.missing == 0 && !mat.analysisStale
        var plan: Plan
        if cached, let b = before { plan = b } else {
            let n = min(30, max(10, analyzed.state.topicCount * 2))
            plan = try self.plan(job.id, count: n, fresh: regenerate, requestKey: regenerate ? "regen-" + UUID().uuidString : nil, topicReuse: false)   // one-shot, unreviewed: exact-pattern reuse only
        }
        do {
            if plan.missing > 0 { stage("Generating \(plan.missing) new question(s)"); _ = try await generate(job.id) }
        } catch is CancellationError { throw CancellationError() }
        catch {
            let why = (error as? GatewayError).map { AgentRunner.hint(for: $0) } ?? error.localizedDescription
            var j = try job2(job.id); try? StudyPrep.save(&j, j.state, c, status: .paused, error: why)
            return ToolOutput(text: "Stopped while generating questions: \(why)\nThe study map (\(analyzed.state.topicCount) topic(s)) and the planned practice set are saved. Tell the learner they can resume and only the missing questions are generated.", summary: "Paused at question generation",
                              chips: [ActionChip(label: "Resume preparation", action: "prepareExam", courseId: course.id, assessmentId: analyzed.assessmentId)])
        }
        var j = try job2(job.id)
        if j.status != .completed, let cp = currentPlan(job.id), cp.missing == 0 { try StudyPrep.save(&j, j.state, c, stage: .completed, status: .completed) }
        return try summary(job.id, cached: cached)
    }

    private func job2(_ id: UUID) throws -> StudyPrepJob { guard let j = try job(id) else { throw ToolError.unavailable("That preparation no longer exists.") }; return j }

    func summary(_ id: UUID, cached: Bool) throws -> ToolOutput {
        let j = try job2(id), s = j.state
        guard let p = currentPlan(id), let course = try c.courses.courses(includeArchived: true).first(where: { $0.id == j.courseId }) else { return ToolOutput(text: "Preparation saved.", summary: "Saved") }
        let have = try c.practiceSets.items(setId: p.set.id).filter { $0.questionId != nil }
        let asmName = try j.assessmentId.flatMap { a in try c.courses.assessments(courseId: course.id).first { $0.id == a }?.name } ?? "the course"
        var t = "\(cached ? "Already prepared (sources unchanged). " : "")Preparation for \(asmName) in \(course.name) is saved: \(s.topicCount) topic(s) (\(s.topicsWithSources) with verified source references) and the practice set “\(p.set.title)” with \(have.count) question(s) (\(p.reused) reused from saved questions)"
        t += p.missing > 0 ? ", \(p.missing) still to generate." : "."
        t += " New questions are structurally validated and marked Unverified, not independently checked. Priorities are study estimates unless a topic says instructor-stated."
        if !s.gaps.isEmpty { t += " Not fully readable: " + s.gaps.joined(separator: ", ") + "." }
        t += " Tell the learner in a few sentences, using exactly these numbers. Do not call more tools."
        let cid = course.id
        return ToolOutput(text: t, summary: "\(s.topicCount) topics, \(have.count) questions", mapId: s.mapId, chips: [
            ActionChip(label: "Open practice set", action: "openPracticeSet", courseId: cid, assessmentId: j.assessmentId, setId: p.set.id),
            ActionChip(label: "Start Practice", action: "startPractice", courseId: cid, assessmentId: j.assessmentId), ActionChip(label: "View Topics", action: "openSkills", courseId: cid),
            ActionChip(label: "View Questions", action: "openQuestionBank", courseId: cid), ActionChip(label: "Review Sources", action: "openCourse", courseId: cid), ActionChip(label: "Regenerate Questions", action: "prepareExam", courseId: cid, assessmentId: j.assessmentId)])
    }
}

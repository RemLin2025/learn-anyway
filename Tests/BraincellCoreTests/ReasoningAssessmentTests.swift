import Testing
import Foundation
import GRDB
@testable import BraincellCore

/// All fixtures here are SYNTHETIC (STOR435-like requirements supplied by the user, not recovered from the real PDFs). Models are scripted.
extension AgentTests {
    static func srcQ(_ locator: String, prompt: String = "A fair die…", solution: String? = "Use P(A|B)=P(A∩B)/P(B).", choices: Bool = true, arch: String = "conditionalReasoning", topic: String = "Joint discrete models", skills: [String] = ["Restrict joint support before conditioning"], diff: Int = 3, missing: [String] = []) -> [String: Any] {
        var q: [String: Any] = ["locator": locator, "pages": [1], "prompt": prompt, "topics": [topic], "format": "single_choice", "primaryArchetype": arch, "reasoningSkills": skills, "difficulty": diff,
                                "steps": [["description": "Restrict the support", "skill": skills[0]], ["description": "Divide by the marginal"]], "missing": missing, "requested": "a conditional probability", "roundingDecimals": 4]
        if choices { q["choices"] = [["id": "a", "text": "0.1"], ["id": "b", "text": "0.2"]] }
        if let s = solution { q["solution"] = s }
        return q
    }
    func analysisJSON(_ qs: [[String: Any]]) -> String { String(data: try! JSONSerialization.data(withJSONObject: ["questions": qs]), encoding: .utf8)! }

    func bankEnv(chunks: [String] = ["Q1 text and solution.", "Q2 starts here and continues", "on the next chunk with solution."], _ handler: @escaping @Sendable (String, Int) -> String) async throws -> (E, Course, Document) {
        let e = try await env { _, user, n in handler(user, n) }
        let c = try e.ctx.courses.createCourse(name: "STOR435")
        let d = try insertDoc(e, c, name: "practice_bank_SYNTHETIC.pdf", status: .ok, pages: 3)
        for (i, t) in chunks.enumerated() { try insertChunk(e, d, i, page: i + 1, t) }
        return (e, c, d)
    }

    // MARK: Source analysis

    @Test func windowsOverlapSoBoundarySpanningQuestionsAppearWhole() {
        let w = SourceAnalysisService.windows([4000, 4000, 4000, 4000], maxChars: 6000)
        #expect(w.count == 3 && w[0].to == w[1].from && w[1].to == w[2].from)    // consecutive windows share a chunk, even when chunks are large
        #expect(w.last!.to == 3)                                            // everything is covered
        #expect(SourceAnalysisService.windows([], maxChars: 100).isEmpty)
        #expect(SourceAnalysisService.windows([9999], maxChars: 100).count == 1)
    }

    @Test func analysisKeepsMissingPartsMissingMergesOverlapsAndCachesByContent() async throws {
        let calls = LockedBox<Int>(0)
        let (e, _, d) = try await bankEnv(chunks: [String(repeating: "a", count: 5000), String(repeating: "b", count: 5000), "c"]) { user, _ in
            calls.withLock { $0 += 1 }
            return self.analysisJSON([Self.srcQ("Q2", prompt: "Truncated stem", solution: nil, choices: false, missing: ["prompt tail"]), Self.srcQ("Q1")])
        }
        let svc = SourceAnalysisService(db: e.db, gateway: e.ctx.gateway)
        let out = try await svc.analyze(d)
        guard case .analyzed(let id) = out else { Issue.record("expected analyzed, got \(out)"); return }
        let n = calls.value
        #expect(n >= 2)                                                     // several windows, each sent once
        let s = try #require(try svc.summary(documentId: d.id))
        #expect(s.status == "complete" && s.windowsDone == s.windowsTotal && s.questions == 2)
        let rows = try svc.sourceQuestions(courseId: d.courseId!)
        let q2 = try #require(rows.first { $0.payload.locator == "Q2" })
        #expect(!q2.payload.isComplete && q2.payload.choices == nil && q2.payload.missing.contains("choices") && q2.payload.missing.contains("solution"))   // never invented
        #expect(rows.first { $0.payload.locator == "Q1" }?.payload.isComplete == true)
        let again = try await svc.analyze(d)
        #expect(again == .cached(id) && calls.value == n)                   // unchanged content: no model call
        // reasoning skills are queryable records, not just tags
        #expect(try e.db.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM source_question_reasoning") } ?? 0 >= 1)
        // changed content: new analysis, old one becomes stale
        var changed = d; changed.sha256 = "changed-sha"
        try e.db.write { try changed.update($0) }
        _ = try await svc.analyze(changed)
        #expect(try e.db.read { try String.fetchOne($0, sql: "SELECT status FROM source_analyses WHERE id = ?", arguments: [id]) } == "stale")
    }

    @Test func partialExtractionAndFailedWindowsAreReportedNotHidden() async throws {
        let fail = LockedBox<Bool>(true)
        let (e, _, d0) = try await bankEnv(chunks: [String(repeating: "x", count: 5000), String(repeating: "y", count: 5000)]) { _, _ in
            fail.value ? "not json" : self.analysisJSON([Self.srcQ("Q1")])
        }
        var d = d0; d.lowContentPageCount = 4; d.extractionStatus = .partial; try e.db.write { try d.update($0) }
        let svc = SourceAnalysisService(db: e.db, gateway: e.ctx.gateway)
        guard case .partial(_, let failed) = try await svc.analyze(d) else { Issue.record("expected partial"); return }
        #expect(failed >= 1)
        var s = try #require(try svc.summary(documentId: d.id))
        #expect(!s.isComplete && s.limitations.contains("4 page(s)"))
        fail.withLock { $0 = false }
        _ = try await svc.analyze(d)                                         // resumes only the failed windows
        s = try #require(try svc.summary(documentId: d.id))
        #expect(s.status == "complete" && !s.isComplete)                     // all windows done, but scans remain a limitation → not a *complete* bank
    }

    @Test func manualBridgeAnalysisPausesForPasteThenResumes() async throws {
        let calls = LockedBox<Int>(0)
        let (e, _, d) = try await bankEnv { _, _ in calls.withLock { $0 += 1 }; return "" }
        var r = TaskRoute(task: "sourceSummarization"); r.manualBridge = true; try e.ctx.gateway.store.save(r)
        let svc = SourceAnalysisService(db: e.db, gateway: e.ctx.gateway)
        guard case .awaitingImport(_, let wins) = try await svc.analyze(d) else { Issue.record("expected awaitingImport"); return }
        #expect(calls.value == 0 && !wins.isEmpty)                           // nothing was sent to a hosted model
        let req = try e.db.read { try String.fetchOne($0, sql: "SELECT requestText FROM source_analysis_windows WHERE id = ?", arguments: [wins[0]]) } ?? ""
        #expect(req.contains("untrusted_document_content") && req.contains("req-"))
        for w in wins { try svc.importWindow(w, raw: analysisJSON([Self.srcQ("Q1")])) }
        #expect(try svc.summary(documentId: d.id)?.status == "complete")
    }

    // MARK: Style profile

    @Test func profileSeparatesInferredFromConfiguredAndAdmitsInsufficientEvidence() async throws {
        let (e, c, d) = try await bankEnv { _, _ in self.analysisJSON([Self.srcQ("Q1")]) }
        let asm = try e.ctx.courses.addAssessment(courseId: c.id, name: "Midterm 3")
        var cfg = AssessmentConfig(); cfg.examQuestionCount = 19; cfg.durationMinutes = 75; cfg.format = "single_choice"; cfg.basis = ["examQuestionCount": .userProvided]
        let a = AssessmentService(db: e.db); try a.setConfig(cfg, assessmentId: asm.id)
        _ = try await SourceAnalysisService(db: e.db, gateway: e.ctx.gateway).analyze(d)
        let p = try a.profile(courseId: c.id, assessmentId: asm.id)
        #expect(p.archetypes.basis == .inferred && p.archetypes.confidence < 1 && p.config.examQuestionCount == 19 && p.config.basis["examQuestionCount"] == .userProvided)
        #expect(!p.sufficientForStyleMatching && p.limitations.contains { $0.contains("too few") })
        #expect(p.limitations.contains { $0.contains("not exam topic weights") })
        #expect(try a.profile(courseId: c.id, assessmentId: asm.id) == p)                                  // cached by fingerprint
        #expect(try e.db.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM style_profiles") } == 1)
    }

    // MARK: Scope

    @Test func explicitExclusionsBeatEmptyListsCumulativeFallbacksAndRequestedSkills() async throws {
        let e = try await env { _, _, _ in "ok" }
        let c = try e.ctx.courses.createCourse(name: "STOR435"); let asm = try e.ctx.courses.addAssessment(courseId: c.id, name: "Midterm 3", isCumulative: true)
        let geo = try e.ctx.courses.addSkill(courseId: c.id, name: "Geometric distributions").skill
        let normal = try e.ctx.courses.addSkill(courseId: c.id, name: "Normal distributions").skill
        let child = try e.ctx.courses.addSkill(courseId: c.id, name: "Normal approximation", parentId: normal.id).skill
        var cfg = AssessmentConfig(); cfg.scopeExcludes = ["Normal distributions"]; cfg.basis["scopeExcludes"] = .userProvided
        try AssessmentService(db: e.db).setConfig(cfg, assessmentId: asm.id)
        let t = try e.ctx.ai.createGenerationTask(courseId: c.id, assessmentId: asm.id, params: GenerationParams(count: 4, skillIds: [geo.id, normal.id, child.id]))
        #expect(e.ctx.ai.params(of: t).skillIds == [geo.id])                                               // requested excluded topics and children removed
        let t2 = try e.ctx.ai.createGenerationTask(courseId: c.id, assessmentId: asm.id, params: GenerationParams(count: 4))
        #expect(e.ctx.ai.params(of: t2).skillIds == [geo.id])                                              // cumulative fallback respects the exclusion
        cfg.scopeIncludes = ["Normal distributions"]; try AssessmentService(db: e.db).setConfig(cfg, assessmentId: asm.id)
        #expect(throws: AITaskError.self) { _ = try e.ctx.ai.createGenerationTask(courseId: c.id, assessmentId: asm.id, params: GenerationParams(count: 2)) }   // include ∩ exclude = ∅ → error, no silent widening
    }

    @Test func importRejectsQuestionsOnExcludedTopicsEvenIfTheModelTagsThem() async throws {
        let e = try await env { _, _, _ in "ok" }
        let c = try e.ctx.courses.createCourse(name: "STOR435"); let asm = try e.ctx.courses.addAssessment(courseId: c.id, name: "Midterm 3")
        _ = try e.ctx.courses.addSkill(courseId: c.id, name: "Geometric distributions"); _ = try e.ctx.courses.addSkill(courseId: c.id, name: "Normal distributions")
        var cfg = AssessmentConfig(); cfg.scopeExcludes = ["Normal distributions"]; try AssessmentService(db: e.db).setConfig(cfg, assessmentId: asm.id)
        let t = try e.ctx.ai.createGenerationTask(courseId: c.id, assessmentId: asm.id, params: GenerationParams(count: 2))
        let b = try e.ctx.ai.batches(taskId: t.id)[0]
        let ok = Fx.base("short_answer", title: "Geo ok", answer: ["accepted": ["x"], "caseSensitive": false], method: "exact", skills: ["Geometric distributions"])
        let bad = Fx.base("short_answer", title: "Normal bad", answer: ["accepted": ["x"], "caseSensitive": false], method: "exact", skills: ["Normal distributions"])
        let r = try e.ctx.ai.importResponse(Fx.envelope(b.requestId, [ok, bad]), targetBatchId: b.id)
        #expect(r.accepted.count == 1 && r.rejected.count == 1 && r.rejected[0].issues.contains { $0.message.contains("excluded topic") })
    }

    // MARK: Planner and prompt

    func srcRow(_ loc: String, _ arch: String, _ topic: String, diff: Int = 3, doc: String = "bank") -> SourceQuestionRow {
        var p = SourceQuestionPayload(locator: loc); p.prompt = "p"; p.solution = "s"; p.primaryArchetype = arch; p.topics = [topic]; p.difficulty = diff; p.reasoningSkills = ["skill \(arch)"]; p.steps = [SolutionStep(description: "step")]; p.format = "single_choice"
        return SourceQuestionRow(id: UUID(), analysisId: UUID(), documentId: UUID(), documentTitle: doc, payload: p)
    }

    @Test func plannerSupportsAllFourModesAndBalancesAcrossTheWholeTask() {
        let topics = ["Geometric", "Joint", "Indicators", "Covariance"].map { GenerationPlanner.TopicInput(name: $0, existingCount: $0 == "Covariance" ? 5 : 0, weak: $0 == "Joint") }
        let src = (0..<8).map { srcRow("Q\($0)", ["conditionalReasoning", "formulaDerivation", "indicatorReasoning"][$0 % 3], topics[$0 % 4].name, diff: 2 + $0 % 3) }
        var prof = StyleProfile(formats: .init(["single_choice": 8], basis: .inferred, confidence: 0.8), archetypes: .init(["conditionalReasoning": 3, "formulaDerivation": 3, "indicatorReasoning": 2], basis: .inferred, confidence: 0.8),
                                difficulty: .init(["2": 3, "3": 3, "4": 2], basis: .inferred, confidence: 0.5), averageSteps: .init(3, basis: .inferred, confidence: 0.5), reasoningSkills: .init([:], basis: .inferred, confidence: 0.5),
                                roundingDecimals: .init([:], basis: .inferred, confidence: 0.5), choicePatterns: [], distractorPatterns: [], coverage: .init(documents: 1, documentsAnalyzed: 1, questionsRecovered: 8, completeQuestions: 8, windowsDone: 1, windowsTotal: 1),
                                config: AssessmentConfig(), limitations: [], sufficientForStyleMatching: true)
        prof.sufficientForStyleMatching = true
        for m in GenerationMode.allCases {
            let p = GenerationPlanner.plan(mode: m, count: 24, topics: topics, sources: src, profile: prof, config: AssessmentConfig(), excluded: ["Normal"])
            #expect(p.slots.count == 24 && Set(p.slots.map(\.id)).count == 24 && p.excludedTopics == ["Normal"])
            #expect(p.slots.allSatisfy { !$0.topic.isEmpty && (1...5).contains($0.difficulty) })
        }
        let broad = GenerationPlanner.plan(mode: .broaderTopics, count: 24, topics: topics, sources: src, profile: nil, config: AssessmentConfig(), excluded: [])
        let perTopic = Dictionary(grouping: broad.slots, by: \.topic).mapValues(\.count)
        #expect(perTopic.values.max()! - perTopic.values.min()! <= 1)                                    // balanced over the whole task
        #expect(Set(broad.slots.map(\.archetype)).count >= 8)                                            // varied reasoning demands
        let weak = GenerationPlanner.plan(mode: .weakSkills, count: 6, topics: topics, sources: src, profile: nil, config: AssessmentConfig(), excluded: [])
        #expect(Set(weak.slots.map(\.topic)) == ["Joint"] && weak.weakTargets == ["Joint"])
        let style = GenerationPlanner.plan(mode: .matchInstructorStyle, count: 8, topics: topics, sources: src, profile: prof, config: AssessmentConfig(), excluded: [])
        #expect(style.styleUsed && style.slots.contains { !$0.exemplars.isEmpty })
        let none = GenerationPlanner.plan(mode: .matchInstructorStyle, count: 4, topics: topics, sources: [], profile: nil, config: AssessmentConfig(), excluded: [])
        #expect(none.mode == .broaderTopics && none.limitations.contains { $0.contains("general practice") })   // honest degradation
    }

    @Test func planIsPersistedSlicedPerBatchAndTrackedAcrossImportAndContinuation() async throws {
        let (e, c, d) = try await bankEnv { _, _ in self.analysisJSON([]) }
        _ = d
        for n in ["Geometric distributions", "Joint models", "Indicators"] { _ = try e.ctx.courses.addSkill(courseId: c.id, name: n) }
        let t = try e.ctx.ai.createGenerationTask(courseId: c.id, params: GenerationParams(count: 14, mode: .broaderTopics))
        let batches = try e.ctx.ai.batches(taskId: t.id)
        #expect(batches.count == 2)
        let store = GenerationPlanStore(db: e.db)
        let plan = try #require(try store.load(taskId: t.id)); #expect(plan.slots.count == 14)
        let p1 = try e.ctx.ai.prepare(batchId: batches[0].id).singlePrompt, p2 = try e.ctx.ai.prepare(batchId: batches[1].id).singlePrompt
        #expect(p1.contains("## Blueprint") && p1.contains("Slot s1:") && p1.contains("Slot s10:") && !p1.contains("Slot s11:"))
        #expect(p2.contains("Slot s11:") && p2.contains("Slot s14:") && !p2.contains("Slot s1:"))
        #expect(p1.contains("Swapping numbers or names is not enough"))
        // import two questions that claim slots s1 and s2 → only the rest stay unmet; unknown slot ids are ignored
        func q(_ title: String, slot: String) -> [String: Any] {
            Fx.base("short_answer", title: title, answer: ["accepted": ["x"], "caseSensitive": false], method: "exact", skills: ["Joint models"],
                    extra: ["metadata": ["provenance": ["slotId": slot, "topic": "Joint models", "reasoningSkills": ["Restrict joint support before conditioning"], "primaryArchetype": "conditionalReasoning", "origin": "generated_variant"]],
                            "content": [Fx.md("Unique statement about \(title)")]])
        }
        let r0 = try e.ctx.ai.importResponse(Fx.envelope(batches[0].requestId, [q("one", slot: "s1"), q("two", slot: "s2"), q("three", slot: "nonsense")]), targetBatchId: batches[0].id)
        let unmet = try store.unmetSlots(taskId: t.id)
        #expect(r0.rejected.isEmpty, "\(r0.rejected.map(\.issues))")
        #expect(unmet.count == 12 && !unmet.contains { $0.id == "s1" || $0.id == "s2" })
        #expect(try e.db.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM question_reasoning_skills") } == 3)    // same reasoning skill → one record linked to three questions
        #expect(try e.db.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM reasoning_skills") } == 1)
        #expect(try e.db.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM question_evidence WHERE kind = 'schema'") } == 3)
        let cont = try e.ctx.ai.createContinuationBatch(from: batches[0].id)
        #expect(try e.ctx.ai.prepare(batchId: cont.id).singlePrompt.contains("Slot s3:"))                           // continuation targets what is still unmet
    }

    @Test func extractionIsSourceAwareInsteadOfFirstDocumentFirst() async throws {
        let e = try await env { _, _, _ in "ok" }
        let c = try e.ctx.courses.createCourse(name: "STOR435")
        let big = try insertDoc(e, c, name: "big_textbook.pdf", status: .ok, pages: 200)
        for i in 0..<60 { try insertChunk(e, big, i, page: i + 1, String(repeating: "Filler text about history. ", count: 60)) }
        let small = try insertDoc(e, c, name: "exam_info.pdf", status: .ok, pages: 1)
        try insertChunk(e, small, 0, page: 1, "Midterm 3 exam: closed book, 75 minutes, multiple choice, answers rounded to four decimal places. Covers geometric distributions.")
        _ = try e.ctx.courses.addSkill(courseId: c.id, name: "Geometric distributions")
        let t = try e.ctx.ai.createGenerationTask(courseId: c.id, params: GenerationParams(count: 3, documentIds: [big.id, small.id]))
        let pkg = try e.ctx.ai.prepare(batchId: try e.ctx.ai.batches(taskId: t.id)[0].id)
        #expect(pkg.singlePrompt.contains("closed book, 75 minutes"))                                              // exam instructions are not crowded out by the first document
        #expect(pkg.manifest.documents.contains { $0.title == "big_textbook.pdf" && $0.truncated } && pkg.manifest.blueprintSlots == 3)
    }

    @Test func weakSkillModeDisclosesTopicNamesAndNothingElse() async throws {
        let e = try await env { _, _, _ in "ok" }
        let c = try e.ctx.courses.createCourse(name: "STOR435")
        _ = try e.ctx.courses.addSkill(courseId: c.id, name: "Covariance")
        let t = try e.ctx.ai.createGenerationTask(courseId: c.id, params: GenerationParams(count: 2, mode: .weakSkills))
        let pkg = try e.ctx.ai.prepare(batchId: try e.ctx.ai.batches(taskId: t.id)[0].id)
        #expect(pkg.manifest.excluded.first?.contains("No attempt history") == true)
        #expect(!pkg.singlePrompt.lowercased().contains("score:"))
        let general = try e.ctx.ai.createGenerationTask(courseId: c.id, params: GenerationParams(count: 2))
        #expect(try e.ctx.ai.prepare(batchId: try e.ctx.ai.batches(taskId: general.id)[0].id).manifest.excluded == RequestManifest.excludedStatements)
    }

    // MARK: Schema compatibility and metadata path

    @Test func v1ResponsesAndOldPayloadsStillWorkAndNewMetadataSurvivesEdit() async throws {
        let e = try await env { _, _, _ in "ok" }
        let c = try e.ctx.courses.createCourse(name: "X")
        let t = try e.ctx.ai.createGenerationTask(courseId: c.id, params: GenerationParams(count: 1))
        let b = try e.ctx.ai.batches(taskId: t.id)[0]
        let q = Fx.base("short_answer", title: "Old style", answer: ["accepted": ["x"], "caseSensitive": false], method: "exact")
        let r = try e.ctx.ai.importResponse(Fx.envelope(b.requestId, [q], version: "cramlab.questions.v1"), targetBatchId: b.id)
        #expect(r.accepted.count == 1)
        // an old payload (no new keys) decodes
        let old = #"{"type":"short_answer","title":"T","difficulty":2,"learningObjective":"o","content":[{"kind":"markdown","text":"hi"}],"answer":{"accepted":["x"]},"evaluation":{"method":"exact"},"hints":[],"solution":[],"sources":[]}"#
        let spec = try JSONDecoder().decode(QuestionSpec.self, from: Data(old.utf8))
        #expect(spec.solutionPlan == nil && spec.metadata == nil && spec.answer.intervals == nil)
        // new fields round-trip through edit (re-validation reconstructs typed objects)
        var s2 = try e.ctx.questions.detail(r.accepted[0].questionId).spec
        s2.solutionPlan = SolutionPlan(interpretation: "i", assumptions: ["a"], method: "m", formulas: ["f"], steps: [SolutionStep(description: "s1", skill: "k"), SolutionStep(description: "s2", commonError: "err")], finalResult: "x", pitfalls: ["p"])
        s2.metadata = GenerationMetadata(generator: "test", provenance: QuestionProvenance(topic: "T", reasoningSkills: ["r"], primaryArchetype: "proofJustification", origin: "generated_variant"))
        _ = try e.ctx.questions.edit(questionId: r.accepted[0].questionId, spec: s2)
        let back = try e.ctx.questions.detail(r.accepted[0].questionId).spec
        #expect(back.solutionPlan == s2.solutionPlan && back.metadata?.provenance?.primaryArchetype == "proofJustification")
        #expect(throws: AITaskError.self) { _ = try e.ctx.ai.importResponse(Fx.envelope(b.requestId, [], version: "cramlab.questions.v9"), targetBatchId: b.id) }   // unknown versions are still refused
    }

    @Test func nearDuplicatesAreFlaggedButSharedSkillsAreNot() async throws {
        let e = try await env { _, _, _ in "ok" }
        let c = try e.ctx.courses.createCourse(name: "X")
        let t = try e.ctx.ai.createGenerationTask(courseId: c.id, params: GenerationParams(count: 3))
        let b = try e.ctx.ai.batches(taskId: t.id)[0]
        func q(_ title: String, _ text: String) -> [String: Any] { Fx.base("short_answer", title: title, answer: ["accepted": [title]], method: "exact", extra: ["content": [Fx.md(text)]]) }
        let base = "A fair die is rolled twice and X is the larger of the two values. Find the probability that X equals 4 given that the sum is at most 7."
        let swap = "A fair die is rolled twice and X is the larger of the two values. Find the probability that X equals 5 given that the sum is at most 8."
        let transfer = "Two components fail independently with rates 2 and 3. Using indicator variables, find the expected number of components that survive past time 1."
        let r = try e.ctx.ai.importResponse(Fx.envelope(b.requestId, [q("base", base), q("swap", swap), q("transfer", transfer)]), targetBatchId: b.id)
        #expect(r.accepted.count == 3)
        let readiness = Dictionary(uniqueKeysWithValues: r.accepted.map { ($0.title, $0.readiness) })
        #expect(readiness["swap"] == .needsReview && readiness["transfer"] != .needsReview && readiness["base"] != .needsReview)
    }

    // MARK: Math checks and intervals

    func choiceQ(_ intervals: [[String: Any]], correct: String, result: Double?, decimals: Int? = 4, check: [String: Any]? = nil) -> [String: Any] {
        var ans: [String: Any] = ["choices": [["id": "a", "text": "A"], ["id": "b", "text": "B"], ["id": "c", "text": "C"]], "correctIds": [correct], "intervals": intervals]
        if let r = result { ans["exactResult"] = r }; if let d = decimals { ans["roundingDecimals"] = d }; if let c = check { ans["check"] = c }
        return Fx.base("single_choice", title: "Interval", answer: ans, method: "choice")
    }
    func iv(_ id: String, _ lo: Double?, _ hi: Double?, lc: Bool = true, uc: Bool = false) -> [String: Any] { var d: [String: Any] = ["choiceId": id, "lowerClosed": lc, "upperClosed": uc]; d["lower"] = lo ?? NSNull(); d["upper"] = hi ?? NSNull(); return d }

    @Test func intervalChoicesCheckBoundsEndpointsOverlapRoundingAndUnboundedEnds() {
        let good = [iv("a", nil, 0.2), iv("b", 0.2, 0.5), iv("c", 0.5, nil)]                         // null = unbounded, valid JSON
        #expect(QuestionValidator.validate(entry: choiceQ(good, correct: "b", result: 0.3), index: 0).question != nil)
        func blocked(_ q: [String: Any]) -> String? { QuestionValidator.validate(entry: q, index: 0).issues.first { $0.severity == .blocking }?.message }
        #expect(blocked(choiceQ(good, correct: "a", result: 0.3))?.contains("lies in “b”") == true)                          // wrong key
        #expect(blocked(choiceQ([iv("a", nil, 0.3), iv("b", 0.2, 0.5), iv("c", 0.5, nil)], correct: "b", result: 0.25))?.contains("overlap") == true)
        #expect(blocked(choiceQ([iv("a", nil, 0.2), iv("b", 0.5, 0.2), iv("c", 0.5, nil)], correct: "b", result: 0.3))?.contains("reversed") == true)
        // endpoint inclusion: 0.2 belongs to b (closed lower), not a (open upper)
        #expect(QuestionValidator.validate(entry: choiceQ(good, correct: "b", result: 0.2), index: 0).hasBlocking == false)
        #expect(blocked(choiceQ(good, correct: "a", result: 0.2)) != nil)
        // rounding: 0.19996 rounds to 0.2000 at 4 decimals → falls in b, not a
        #expect(QuestionValidator.validate(entry: choiceQ(good, correct: "b", result: 0.19996), index: 0).hasBlocking == false)
        #expect(blocked(choiceQ(good, correct: "a", result: 0.19996)) != nil)
        #expect(blocked(choiceQ([iv("a", nil, 0.2), iv("b", 0.2, 0.5)], correct: "b", result: 0.3))?.contains("every choice") == true)    // c has no interval
        #expect(IntervalChoice(choiceId: "x", lower: nil, upper: nil).contains(1e300))
        #expect(IntervalChecks.round(2.5, decimals: 0) == 3 && IntervalChecks.round(-2.5, decimals: 0) == -3)
    }

    @Test func deterministicChecksRecomputeAndVerificationRequiresAgreement() {
        let joint: [String: Any] = ["kind": "jointPMF", "op": "conditionalYgivenX", "xs": [0, 1], "ys": [0, 1], "table": [[0.1, 0.3], [0.2, 0.4]], "x": 1, "y": 1]      // P(Y=1|X=1) = 0.4/0.6
        let ok = QuestionValidator.validate(entry: choiceQ([iv("a", nil, 0.6), iv("b", 0.6, 0.7), iv("c", 0.7, nil)], correct: "b", result: nil, check: joint), index: 0)
        #expect(!ok.hasBlocking && ok.computedVerification && ok.question?.spec.answer.exactResult.map { abs($0 - 2.0 / 3.0) < 1e-12 } == true)
        #expect(ok.evidence.contains { $0.kind == .deterministic && $0.result == .passed })
        let wrongKey = QuestionValidator.validate(entry: choiceQ([iv("a", nil, 0.6), iv("b", 0.6, 0.7), iv("c", 0.7, nil)], correct: "a", result: nil, check: joint), index: 0)
        #expect(wrongKey.hasBlocking && !wrongKey.computedVerification)                                       // known-invalid → quarantined, not saved
        let lie = QuestionValidator.validate(entry: choiceQ([iv("a", nil, 0.6), iv("b", 0.6, 0.7), iv("c", 0.7, nil)], correct: "b", result: 0.9, check: joint), index: 0)
        #expect(lie.hasBlocking)                                                                              // stated result contradicts the recomputation
        let noCheck = QuestionValidator.validate(entry: choiceQ([iv("a", nil, 0.6), iv("b", 0.6, 0.7), iv("c", 0.7, nil)], correct: "b", result: 0.666), index: 0)
        #expect(!noCheck.hasBlocking && !noCheck.computedVerification)                                        // generator-supplied number alone never promotes
        #expect(noCheck.evidence.contains { $0.kind == .unresolved })
    }

    @Test func mathChecksCoverPMFsCovarianceIndependenceAndGeometricDomain() {
        let t = [[0.1, 0.2], [0.3, 0.4]]
        func run(_ c: StructuredCheck) -> CheckOutcome { MathChecks.run(c) }
        #expect(run(StructuredCheck(kind: "finitePMF", probs: [0.2, 0.3, 0.5])).evidence.result == .passed)
        #expect(run(StructuredCheck(kind: "finitePMF", probs: [0.2, 0.3, 0.6])).evidence.result == .failed)
        #expect(run(StructuredCheck(kind: "jointPMF", op: "marginalX", xs: [0, 1], ys: [0, 1], table: t, x: 1)).computed.map { abs($0 - 0.7) < 1e-12 } == true)
        let cov = run(StructuredCheck(kind: "jointPMF", op: "covariance", xs: [0, 1], ys: [0, 1], table: t)).computed!      // E[XY]=.4, E[X]=.7, E[Y]=.6 → -0.02
        #expect(abs(cov - (0.4 - 0.7 * 0.6)) < 1e-12)
        #expect(run(StructuredCheck(kind: "jointPMF", op: "independent", xs: [0, 1], ys: [0, 1], table: [[0.06, 0.14], [0.24, 0.56]])).computed == 1)
        #expect(run(StructuredCheck(kind: "jointPMF", op: "independent", xs: [0, 1], ys: [0, 1], table: t)).computed == 0)
        #expect(run(StructuredCheck(kind: "jointPMF", op: "conditionalYgivenX", xs: [0, 1], ys: [0, 1], table: [[0, 0], [0.5, 0.5]], x: 0, y: 0)).evidence.result == .failed)   // conditioning on a null event
        let g = run(StructuredCheck(kind: "geometricMGF", op: "domainUpper", p: 0.3)).computed!
        #expect(abs(g - (-log(0.7))) < 1e-12)
        #expect(run(StructuredCheck(kind: "geometricMGF", op: "mgf", p: 0.3, t: 0.5)).evidence.result == .failed)               // 0.5 > -ln(0.7) ≈ 0.357: outside the domain
        #expect(run(StructuredCheck(kind: "geometricMGF", op: "mgf", p: 0.3, t: 0.1)).evidence.result == .passed)
        #expect(run(StructuredCheck(kind: "normalMGF")).evidence.result == .unsupported)
    }

    @Test func solutionPlansAndDifficultyFactorsAreStructuredAndReviewedWhenIncomplete() {
        var f = DifficultyFactors(); f.steps = 3; f.concepts = 2; f.conditioning = 2
        #expect((1...5).contains(f.suggestedDifficulty) && DifficultyFactors().suggestedDifficulty == 1)
        func q(_ plan: [String: Any]) -> ValidationResult { QuestionValidator.validate(entry: Fx.base("short_answer", title: "T", answer: ["accepted": ["x"]], method: "exact", extra: ["solutionPlan": plan]), index: 0) }
        let full: [String: Any] = ["interpretation": "i", "assumptions": ["a"], "method": "m", "formulas": ["f"], "steps": [["description": "s1"], ["description": "s2", "commonError": "e"]], "finalResult": "r", "pitfalls": ["p"]]
        #expect(q(full).question?.spec.solutionPlan?.isComplete == true && !q(full).issues.contains { $0.path.contains("solutionPlan") })
        #expect(q(["method": "m"]).issues.contains { $0.severity == .review && $0.path.contains("solutionPlan") })
    }

    // MARK: Migration and archetypes

    @Test func migrationFromAnOlderPopulatedDatabaseKeepsEverythingAndSeedsArchetypes() throws {
        let q = try DatabaseQueue()
        try AppDatabase.migrator.migrate(q, upTo: "v16_study_prep_jobs")
        let cid = UUID()
        try q.write { try $0.execute(sql: "INSERT INTO courses (id, name, kind, createdAt) VALUES (?, 'Old', 'structured', ?)", arguments: [cid, Date()]) }
        try AppDatabase.migrator.migrate(q)
        #expect(try q.read { try String.fetchOne($0, sql: "SELECT name FROM courses WHERE id = ?", arguments: [cid]) } == "Old")
        #expect(try q.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM archetypes WHERE builtin = 1") } == Archetype.allCases.count)
        for t in ["source_analyses", "source_questions", "style_profiles", "generation_plans", "question_provenance", "question_evidence", "exam_attempts", "reasoning_skills", "assessment_config"] {
            #expect(try q.read { try Bool.fetchOne($0, sql: "SELECT EXISTS(SELECT 1 FROM sqlite_master WHERE name = ?)", arguments: [t]) } == true, "\(t)")
        }
    }
}

extension AgentTests {
    @Test func reasoningDataSurvivesBackupAndRestore() async throws {
        let (e, c, d) = try await bankEnv { _, _ in self.analysisJSON([Self.srcQ("Q1")]) }
        _ = try await SourceAnalysisService(db: e.db, gateway: e.ctx.gateway).analyze(d)
        let asm = try e.ctx.courses.addAssessment(courseId: c.id, name: "Midterm 3")
        var cfg = AssessmentConfig(); cfg.examQuestionCount = 19; cfg.scopeExcludes = ["Normal distributions"]; try AssessmentService(db: e.db).setConfig(cfg, assessmentId: asm.id)
        let storage = ManagedStorage(root: e.dir.appendingPathComponent("store"))
        try FileManager.default.createDirectory(at: storage.root.appendingPathComponent("Documents/x"), withIntermediateDirectories: true)
        try "synthetic".write(to: storage.root.appendingPathComponent("Documents/x/a.txt"), atomically: true, encoding: .utf8)
        try e.db.write { try $0.execute(sql: "UPDATE documents SET storedPath = 'Documents/x/a.txt' WHERE id = ?", arguments: [d.id]) }
        let backup = try BackupService(db: e.db, storage: storage).create(in: e.dir.appendingPathComponent("backups"))
        let freshDir = e.dir.appendingPathComponent("fresh"); let fs = ManagedStorage(root: freshDir.appendingPathComponent("storage"))
        try FileManager.default.createDirectory(at: fs.root, withIntermediateDirectories: true)
        let restored = try AppDatabase.open(at: freshDir.appendingPathComponent("b.sqlite"))
        try BackupService(db: restored, storage: fs).restore(from: backup.url, safetyBackupIn: nil)
        #expect(try SourceAnalysisService(db: restored, gateway: nil).sourceQuestions(courseId: c.id).count == 1)
        #expect(try AssessmentService(db: restored).config(assessmentId: asm.id).scopeExcludes == ["Normal distributions"])
    }
}

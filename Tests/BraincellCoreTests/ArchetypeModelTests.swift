import Testing
import Foundation
import GRDB
@testable import BraincellCore

/// Phase 2: the reusable course-level archetype model. Synthetic fixtures, scripted models.
extension AgentTests {
    func richQ(_ loc: String, arch: String = "conditionalReasoning", topic: String = "Joint discrete models", skill: String = "Restrict joint support before conditioning", doc: Int = 0, diff: Int = 3, formulas: [String] = ["P(A|B)=P(A∩B)/P(B)"]) -> [String: Any] {
        var q = Self.srcQ(loc, arch: arch, topic: topic, skills: [skill], diff: diff)
        q["formulas"] = formulas; q["concepts"] = ["conditional probability"]; q["mistakes"] = ["dividing by the wrong marginal"]; q["distractorRationale"] = ["forgot to restrict support"]
        q["assumptions"] = ["pairs are equally likely"]; q["variationConstraints"] = ["keep the joint table summing to 1"]; q["intervalChoices"] = true
        return q
    }

    @Test func equivalentQuestionsAcrossDocumentsMergeIntoOneArchetypeWithFullDetail() async throws {
        let (e, c, d1) = try await bankEnv { _, _ in self.analysisJSON([self.richQ("Q1", diff: 2), self.richQ("Q2", diff: 4)]) }
        let d2 = try insertDoc(e, c, name: "second.pdf", status: .ok, pages: 2); try insertChunk(e, d2, 0, page: 1, "Another practice set."); try insertChunk(e, d2, 1, page: 2, "More.")
        let svc = SourceAnalysisService(db: e.db, gateway: e.ctx.gateway)
        _ = try await svc.analyze(d1); _ = try await svc.analyze(d2)
        let lib = ArchetypeLibrary(db: e.db)
        let ms = try lib.archetypes(courseId: c.id)
        let m = try #require(ms.first)
        #expect(ms.count == 1 && m.sourceCount == 4 && Set(m.sources.compactMap(\.document)).count == 2)       // d1 and d2 both feed one archetype
        #expect(m.steps.count == 2 && m.formulas == ["P(A|B)=P(A∩B)/P(B)"] && m.concepts == ["conditional probability"])
        #expect(m.difficultyMin == 2 && m.difficultyMax == 4 && m.answerFormat == "single_choice" && m.intervalChoices && m.roundingDecimals == 4)
        #expect(m.mistakes.contains("dividing by the wrong marginal") && m.distractors.count == 1 && m.assumptions == ["pairs are equally likely"])
        #expect(m.constraints.contains { $0.contains("non-overlapping numeric intervals") } && m.constraints.contains("keep the joint table summing to 1"))
        #expect(m.verification == "source-extracted" && m.confidence > 0 && m.confidence < 1)
        #expect(try e.db.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM course_archetype_sources") } == 4)
        #expect(try lib.archetypes(courseId: c.id, topics: ["Joint discrete models"]).count == 1)
        #expect(try lib.archetypes(courseId: c.id, topics: ["Unrelated"]).isEmpty)
        #expect(try lib.archetypes(courseId: c.id, excluding: ["Joint discrete models"]).isEmpty)               // excluded topics never come back
    }

    @Test func aggregateRebuildsOnlyWhenUnderlyingAnalysisChanges() async throws {
        let calls = LockedBox<Int>(0)
        let (e, c, d) = try await bankEnv { _, _ in calls.withLock { $0 += 1 }; return self.analysisJSON([self.richQ("Q1"), self.richQ("Q2", arch: "multistepCalculation", topic: "Geometric distributions", skill: "Use the MGF domain")]) }
        let svc = SourceAnalysisService(db: e.db, gateway: e.ctx.gateway), lib = ArchetypeLibrary(db: e.db)
        _ = try await svc.analyze(d)
        let first = try lib.rebuildIfNeeded(courseId: c.id)
        #expect(first.rebuilt && first.upserted >= 2)
        let stamp = try e.db.read { try String.fetchAll($0, sql: "SELECT updatedAt FROM course_archetypes ORDER BY key") }
        let again = try lib.rebuildIfNeeded(courseId: c.id)
        #expect(!again.rebuilt && again.upserted == 0)                                                         // unchanged analysis: nothing recomputed
        #expect(try e.db.read { try String.fetchAll($0, sql: "SELECT updatedAt FROM course_archetypes ORDER BY key") } == stamp)
        _ = try await svc.analyze(d); #expect(!(try lib.rebuildIfNeeded(courseId: c.id).rebuilt))
        // content change → the old analysis goes stale → its archetypes disappear and the new ones appear
        var changed = d; changed.sha256 = "new-content"; try e.db.write { try changed.update($0) }
        try e.db.write { try $0.execute(sql: "DELETE FROM document_chunks WHERE documentId = ? AND ordinal = 2", arguments: [d.id]) }
        _ = try await svc.analyze(changed)
        let ids = try e.db.read { try String.fetchAll($0, sql: "SELECT id FROM course_archetypes") }
        let after = try lib.rebuildIfNeeded(courseId: c.id)
        #expect(after.rebuilt && after.upserted == 2 && after.removed == 0)                                     // same patterns, new sources: updated in place
        #expect(try e.db.read { try String.fetchAll($0, sql: "SELECT id FROM course_archetypes") } == ids)     // ids stay stable for anything that references them
        #expect(try lib.archetypes(courseId: c.id).count == 2)
    }

    @Test func plannerAndChatToolUseTheAggregateWithoutAnotherModelCall() async throws {
        let calls = LockedBox<Int>(0)
        let (e, c, d) = try await bankEnv { _, _ in calls.withLock { $0 += 1 }; return self.analysisJSON([self.richQ("Q1"), self.richQ("Q2")]) }
        _ = try await SourceAnalysisService(db: e.db, gateway: e.ctx.gateway).analyze(d)
        let used = calls.value
        _ = try e.ctx.courses.addSkill(courseId: c.id, name: "Joint discrete models")
        let t = try e.ctx.ai.createGenerationTask(courseId: c.id, params: GenerationParams(count: 2, mode: .similarReasoning))
        let plan = try #require(try GenerationPlanStore(db: e.db).load(taskId: t.id))
        let key = try #require(plan.slots.first?.archetypeKey)
        #expect(plan.slots.allSatisfy { $0.archetypeKey == key } && plan.slots[0].exemplarSummary?.contains("uses: P(A|B)") == true && plan.slots[0].exemplarSummary?.contains("typical errors") == true)
        #expect(calls.value == used)                                                                            // planning reused the stored model; no extraction call
        let out = try await AgentRegistry.listArchetypesForTests(e.ctx, course: c.name)
        #expect(out.contains("Conditional reasoning") && out.contains("source-extracted") && out.contains("not exam weights"))
        // old plans without archetypeKey still decode
        let old = #"{"id":"s1","topic":"T","archetype":"directComputation","difficulty":3,"format":"any","exemplars":[],"rationale":"r"}"#
        #expect((try? JSONDecoder().decode(PlanSlot.self, from: Data(old.utf8)))?.archetypeKey == nil)
    }
}

extension AgentRegistry {
    static func listArchetypesForTests(_ ctx: AgentContext, course: String) async throws -> String {
        try await listArchetypes(ToolArgs(["course": course]), ctx, ToolRunInfo(conversationId: UUID(), actionId: UUID())).text
    }
}

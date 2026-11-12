import Testing
import Foundation
import GRDB
@testable import BraincellCore

/// Phase 3: persistent, reusable practice sets. The model is scripted; model-call counts are real counts of scripted-gateway requests.
extension AgentTests {
    final class SetModel: @unchecked Sendable {
        let l = NSLock(); var calls = 0, counter = 0, prompts: [String] = [], failNext = false
        func reply(_ user: String, analysis: String) -> String {
            l.lock(); defer { l.unlock() }
            calls += 1; prompts.append(user)
            if user.contains("<untrusted_document_content>") { calls -= 1; return analysis }           // source analysis is not a generation call
            if failNext { failNext = false; return "sorry, I can't produce JSON right now" }
            let rid = user.range(of: "req-[0-9a-f-]+", options: .regularExpression).map { String(user[$0]) } ?? ""
            var qs: [[String: Any]] = []
            let re = try! NSRegularExpression(pattern: "Slot (s\\d+): topic “([^”]*)”; archetype (\\w+); difficulty (\\d); format (\\w+)")
            for m in re.matches(in: user, range: NSRange(user.startIndex..., in: user)) {
                func g(_ i: Int) -> String { String(user[Range(m.range(at: i), in: user)!]) }
                counter += 1
                qs.append(Fx.base("single_choice", title: "Generated \(counter)", answer: ["choices": [["id": "a", "text": "\(counter)"], ["id": "b", "text": "\(counter + 100)"]], "correctIds": ["a"]], method: "choice", skills: [g(2)],
                                  extra: ["difficulty": Int(g(4))!, "content": [Fx.md("Scenario number \(counter): urn \(counter) holds \(counter + 3) red balls and \(counter * 2) blue balls; find a conditional probability.")],
                                          "metadata": ["provenance": ["slotId": g(1), "topic": g(2), "reasoningSkills": ["Restrict joint support before conditioning"], "primaryArchetype": g(3), "origin": "generated_variant"]]]))
            }
            return Fx.envelope(rid, qs)
        }
    }

    func setEnv() async throws -> (E, Course, Document, SetModel, PracticeSetService) {
        let m = SetModel()
        let analysis = analysisJSON([Self.srcQ("Q1"), Self.srcQ("Q2", diff: 3)])
        let (e, c, d) = try await bankEnv { user, _ in m.reply(user, analysis: analysis) }
        _ = try e.ctx.courses.addSkill(courseId: c.id, name: "Joint discrete models")
        _ = try await SourceAnalysisService(db: e.db, gateway: e.ctx.gateway).analyze(d)
        return (e, c, d, m, PracticeSetService(db: e.db, ai: e.ctx.ai))
    }
    func gparams(_ n: Int) -> GenerationParams { GenerationParams(count: n, mode: .similarReasoning) }

    @Test func firstPreparationGeneratesRepeatReusesAndFreshRequestsStayNovel() async throws {
        let (e, c, _, m, svc) = try await setEnv()
        let gw = e.ctx.gateway
        // first preparation: everything is missing, one model call fills it
        let p1 = try svc.prepare(courseId: c.id, params: gparams(3))
        #expect(p1.reused == 0 && p1.missing == 3 && p1.set.taskId != nil)
        let r1 = try await svc.generateMissing(setId: p1.set.id, gateway: gw)
        #expect(r1.modelCalls == 1 && r1.missing == 0 && m.calls == 1)
        let items1 = try svc.items(setId: p1.set.id); #expect(items1.allSatisfy { $0.questionId != nil && $0.origin == "generated" })
        // identical retry: same set, no new task, no model call
        let again = try svc.prepare(courseId: c.id, params: gparams(3))
        #expect(again.alreadyExisted && again.set.id == p1.set.id && again.missing == 0)
        let r1b = try await svc.generateMissing(setId: p1.set.id, gateway: gw)
        #expect(r1b.modelCalls == 0 && m.calls == 1)
        // another set from the same archetypes: filled entirely from stored questions, zero model calls
        let p2 = try svc.prepare(courseId: c.id, params: gparams(3), requestKey: "second set")
        #expect(p2.set.id != p1.set.id && p2.reused == 3 && p2.missing == 0 && p2.set.taskId == nil)
        let r2 = try await svc.generateMissing(setId: p2.set.id, gateway: gw)
        #expect(r2.modelCalls == 0 && m.calls == 1)
        // explicit fresh request: never returns questions already served; one new call
        let p3 = try svc.prepare(courseId: c.id, params: gparams(3), fresh: true)
        #expect(p3.reused == 0 && p3.missing == 3)
        _ = try await svc.generateMissing(setId: p3.set.id, gateway: gw)
        #expect(m.calls == 2)
        let used1 = Set(try svc.items(setId: p1.set.id).compactMap(\.questionId)), used3 = Set(try svc.items(setId: p3.set.id).compactMap(\.questionId))
        #expect(used3.count == 3 && used1.isDisjoint(with: used3))
        // a larger set reuses what exists and sends only the missing slots
        let before = m.calls
        let p4 = try svc.prepare(courseId: c.id, params: gparams(8), requestKey: "bigger")
        #expect(p4.reused == 6 && p4.missing == 2)
        _ = try await svc.generateMissing(setId: p4.set.id, gateway: gw)
        #expect(m.calls == before + 1 && m.prompts.last!.components(separatedBy: "- Slot s").count - 1 == 2)
        #expect(try svc.items(setId: p4.set.id).allSatisfy { $0.questionId != nil })
        // persisted: a reopened database still has the sets and links
        #expect(try e.db.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM question_archetype_links") } == 8)
        let ids4 = Set(try svc.items(setId: p4.set.id).compactMap(\.questionId))
        #expect(ids4.count == 8)                 // no duplicate question inside the set
        // source questions stay separate from generated variants
        #expect(try e.db.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM source_questions") } == 2)
        #expect(try e.db.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM question_provenance WHERE origin = 'generated_variant'") } == 8)
    }

    @Test func failedReplyIsRetriedWithoutDuplicatingBatchesOrQuestions() async throws {
        let (e, c, _, m, svc) = try await setEnv()
        let p = try svc.prepare(courseId: c.id, params: gparams(2))
        m.failNext = true
        await #expect(throws: Error.self) { _ = try await svc.generateMissing(setId: p.set.id, gateway: e.ctx.gateway) }
        #expect(try svc.refresh(setId: p.set.id).missing == 2)
        let r = try await svc.generateMissing(setId: p.set.id, gateway: e.ctx.gateway)
        #expect(r.missing == 0)
        #expect(try e.ctx.ai.batches(taskId: p.set.taskId!).count == 1)                                          // the same batch was retried
        #expect(try e.db.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM question_archetype_links") } == 2)
    }

    @Test func concurrentPreparationAndGenerationShareOneSetAndOneModelCall() async throws {
        let (e, c, _, m, svc) = try await setEnv()
        async let a = svc.prepare(courseId: c.id, params: gparams(2)), b = svc.prepare(courseId: c.id, params: gparams(2))
        let (pa, pb) = try await (a, b)
        let nsets = try e.db.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM practice_sets") }
        #expect(pa.set.id == pb.set.id && nsets == 1)
        let before = m.calls
        async let x = svc.generateMissing(setId: pa.set.id, gateway: e.ctx.gateway), y = svc.generateMissing(setId: pa.set.id, gateway: e.ctx.gateway)
        _ = try await (x, y)
        #expect(m.calls == before + 1)
    }

    @Test func questionsBuiltFromAnOutdatedArchetypeAreNotReusedAndLabelsAreHonest() async throws {
        let (e, c, _, _, svc) = try await setEnv()
        let p = try svc.prepare(courseId: c.id, params: gparams(2)); _ = try await svc.generateMissing(setId: p.set.id, gateway: e.ctx.gateway)
        let q = try #require(try svc.items(setId: p.set.id).first?.questionId)
        #expect(try svc.verification(questionId: q).level == .structuralOnly)                                    // only the schema was checked: said so
        try e.db.write { try $0.execute(sql: "INSERT INTO question_evidence (id, questionId, revisionId, kind, checkName, inputs, result, detail, createdAt) SELECT ?, id, currentRevisionId, 'deterministic', 'finitePMF', '', 'passed', '', ? FROM questions WHERE id = ?", arguments: [UUID(), Date(), q]) }
        #expect(try svc.verification(questionId: q).level == .recomputed)
        try e.db.write { try $0.execute(sql: "INSERT INTO question_evidence (id, questionId, revisionId, kind, checkName, inputs, result, detail, createdAt) SELECT ?, id, currentRevisionId, 'deterministic', 'jointPMF', '', 'failed', '', ? FROM questions WHERE id = ?", arguments: [UUID(), Date(), q]) }
        #expect(try svc.verification(questionId: q).level == .failed)
        // a flagged question is never reused; an outdated archetype invalidates the rest
        let reuse = try svc.prepare(courseId: c.id, params: gparams(2), requestKey: "r")
        #expect(reuse.reused == 1)
        try e.db.write { try $0.execute(sql: "UPDATE course_archetypes SET fingerprint = 'changed'") }
        let stale = try svc.prepare(courseId: c.id, params: gparams(2), requestKey: "r2")
        #expect(stale.reused == 0 && stale.missing == 2)
    }
}

import Testing
import Foundation
import GRDB
@testable import BraincellCore

/// Chat tools over the real PracticeSetService. Scripted model; counts are real scripted-gateway requests.
extension AgentTests {
    func run(_ name: String, _ args: [String: Any], _ e: E) async throws -> ToolOutput {
        let spec = try #require(AgentRegistry.all().first { $0.name == name })
        return try await spec.run(ToolArgs(args), e.ctx, ToolRunInfo(conversationId: UUID(), actionId: UUID()))
    }

    @Test func practiceSetToolsAreRegisteredWithApprovalOnWritesAndGoThroughTheService() async throws {
        let tools = Dictionary(uniqueKeysWithValues: AgentRegistry.all().map { ($0.name, $0) })
        for n in ["practiceSets.list", "practiceSets.create", "practiceSets.resume", "practiceSets.open", "templates.list"] { #expect(tools[n] != nil, "\(n)") }
        #expect(tools["practiceSets.create"]!.requiresApproval && tools["practiceSets.resume"]!.requiresApproval)
        #expect(!tools["practiceSets.list"]!.requiresApproval && !tools["practiceSets.open"]!.requiresApproval)
        #expect(ActionChip.allowed.contains("openPracticeSet"))
    }

    @Test func creatingListingOpeningAndResumingSetsViaChatReusesAndAvoidsDuplicateCalls() async throws {
        let (e, c, _, m, _) = try await setEnv()
        let args: [String: Any] = ["course": c.name, "count": 3, "mode": "similarReasoning"]
        let created = try await run("practiceSets.create", args, e)
        #expect(created.text.contains("3/3 questions ready") && created.text.contains("do not call them verified") && m.calls == 1)
        let setId = try #require(created.chips.first?.setId)
        #expect(created.chips.first?.action == "openPracticeSet")
        // the same request again: reopened, no new model call
        let again = try await run("practiceSets.create", args, e)
        #expect(again.text.contains("already had a set") && again.chips.first?.setId == setId && m.calls == 1)
        // listing and opening are reads: no model call
        let listed = try await run("practiceSets.list", ["course": c.name], e), opened = try await run("practiceSets.open", ["set": setId.uuidString], e)
        #expect(listed.text.contains(setId.uuidString) && opened.text.contains("Exam Worksheet") && opened.text.contains("never regenerates") && m.calls == 1)
        // a fresh request makes new questions; a reused one does not call the model
        let fresh = try await run("practiceSets.create", args.merging(["fresh": true]) { $1 }, e)
        #expect(fresh.text.contains("3/3") && m.calls == 2 && fresh.chips.first?.setId != setId)
        let reused = try await run("practiceSets.create", ["course": c.name, "count": 3, "mode": "similarReasoning", "maxDifficulty": 4], e)
        #expect(reused.text.contains("3 reused") && m.calls == 2)
        // resuming a complete set is free
        let r = try await run("practiceSets.resume", ["set": setId.uuidString], e)
        #expect(r.text.contains("already complete") && m.calls == 2)
        // bad input is explained, not guessed
        await #expect(throws: ToolError.self) { _ = try await self.run("practiceSets.create", ["course": c.name, "format": "essay"], e) }
        await #expect(throws: ToolError.self) { _ = try await self.run("practiceSets.create", ["course": c.name, "topics": ["Nonexistent topic"]], e) }
        await #expect(throws: ToolError.self) { _ = try await self.run("practiceSets.open", ["set": "nope"], e) }
    }

    @Test func cancellingGenerationKeepsTheSetAndALaterResumeFinishesIt() async throws {
        let (e, c, _, m, svc) = try await setEnv()
        let p = try svc.prepare(courseId: c.id, params: gparams(12))                                            // two batches: 10 + 2
        let calls = m.calls
        let t = Task { try await svc.generateMissing(setId: p.set.id, gateway: e.ctx.gateway) }
        t.cancel()
        _ = try? await t.value
        let mid = try svc.refresh(setId: p.set.id)
        #expect(mid.set.id == p.set.id && mid.missing <= 12)
        let done = try await svc.generateMissing(setId: p.set.id, gateway: e.ctx.gateway)
        #expect(done.missing == 0 && m.calls - calls <= 2 + 1)                                                  // at most the two batches (plus one in-flight when cancelled)
        let again = try await svc.generateMissing(setId: p.set.id, gateway: e.ctx.gateway)
        #expect(again.modelCalls == 0)
    }
}

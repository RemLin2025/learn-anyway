import Testing
import Foundation
@testable import BraincellCore

/// Records what would be sent and replies with a canned response. No test here touches the network.
final class MockTransport: HTTPTransport, @unchecked Sendable {
    private let lock = NSLock()
    private(set) var requests: [URLRequest] = []
    var reply: @Sendable (URLRequest) throws -> (Data, Int)
    init(_ reply: @escaping @Sendable (URLRequest) throws -> (Data, Int)) { self.reply = reply }
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        lock.withLock { requests.append(request) }
        let (d, code) = try reply(request)
        return (d, HTTPURLResponse(url: request.url!, statusCode: code, httpVersion: nil, headerFields: nil)!)
    }
    var count: Int { lock.withLock { requests.count } }
}

@Suite struct DirectAITests {
    func messages(_ text: String, stop: String = "end_turn") -> Data {
        try! JSONSerialization.data(withJSONObject: ["type": "message", "role": "assistant", "stop_reason": stop, "content": [["type": "text", "text": text]]])
    }

    struct Setup { let rig: Rig; let batch: AITaskBatch; let settings: SettingsStore; let secrets: InMemorySecretStore }
    func setup(enabled: Bool = true, key: String? = "sk-test-123") throws -> Setup {
        let rig = try Rig()
        let t = try rig.ai.createGenerationTask(courseId: rig.course.id, params: GenerationParams(count: 3))
        let b = try rig.ai.batches(taskId: t.id)[0]
        let settings = SettingsStore(db: rig.db)
        if enabled { try settings.set(.directAPIEnabled, true) }
        let secrets = InMemorySecretStore()
        if let key { try secrets.write(DirectAIService.keyAccount, value: key) }
        return Setup(rig: rig, batch: b, settings: settings, secrets: secrets)
    }
    func service(_ s: Setup, _ t: MockTransport) -> DirectAIService { DirectAIService(ai: s.rig.ai, settings: s.settings, secrets: s.secrets, transport: t) }

    @Test func offByDefaultAndWithoutKeyNothingIsSent() async throws {
        let t = MockTransport { _ in (Data(), 200) }
        let off = try setup(enabled: false)
        await #expect(throws: DirectAIError.disabled) { try await service(off, t).send(batchId: off.batch.id) }
        let nokey = try setup(key: nil)
        await #expect(throws: DirectAIError.noKey) { try await service(nokey, t).send(batchId: nokey.batch.id) }
        #expect(t.count == 0)
        #expect(try off.rig.ai.batches(taskId: off.batch.taskId)[0].exportedAt == nil)
    }

    @Test func requestIsWellFormedAndReplyGoesThroughTheNormalImport() async throws {
        let s = try setup()
        let reply = Fx.envelope(s.batch.requestId, Array(Fx.all.prefix(3)))
        let t = MockTransport { _ in (self.messages(reply), 200) }
        guard case .questions(let report) = try await service(s, t).send(batchId: s.batch.id) else { Issue.record("expected a question import"); return }
        #expect(report.accepted.count == 3 && report.batchStatus == .imported)

        let req = try #require(t.requests.first)
        #expect(req.url == DirectAIService.endpoint && req.httpMethod == "POST")
        #expect(req.value(forHTTPHeaderField: "x-api-key") == "sk-test-123")
        #expect(req.value(forHTTPHeaderField: "anthropic-version") == "2023-06-01")
        let body = try #require(try JSONSerialization.jsonObject(with: req.httpBody ?? Data()) as? [String: Any])
        #expect(body["model"] as? String == DirectAIService.defaultModel && body["max_tokens"] as? Int == DirectAIService.maxOutputTokens)
        let content = ((body["messages"] as? [[String: Any]])?.first?["content"] as? String) ?? ""
        #expect(content.contains(s.batch.requestId))
        #expect(!(String(data: req.httpBody ?? Data(), encoding: .utf8) ?? "").contains("sk-test-123"), "the key must only be in the header")
        let batch = try s.rig.ai.batches(taskId: s.batch.taskId)[0]
        #expect(batch.transferMethod == .api && batch.exportedAt != nil)
    }

    @Test func badRepliesAreRejectedByTheSamePipelineAndKeepEverything() async throws {
        let s = try setup()
        let t = MockTransport { _ in (self.messages("I can't help with that."), 200) }
        await #expect(throws: AITaskError.self) { try await service(s, t).send(batchId: s.batch.id) }
        #expect(try s.rig.qs.list().isEmpty)
        // the raw reply is preserved like a bad paste, and a retry/manual route remains possible
        #expect(try s.rig.ai.imports(batchId: s.batch.id).count == 1)
        // replay of a good reply for a different request id is rejected too
        let wrong = Fx.envelope("req_does_not_match", Array(Fx.all.prefix(1)))
        let t2 = MockTransport { _ in (self.messages(wrong), 200) }
        await #expect(throws: (any Error).self) { try await service(s, t2).send(batchId: s.batch.id) }
        #expect(try s.rig.qs.list().isEmpty)
    }

    @Test func httpFailuresMapToClearErrorsAndImportNothing() async throws {
        let s = try setup()
        func err(_ code: Int, _ msg: String) -> Data { try! JSONSerialization.data(withJSONObject: ["type": "error", "error": ["type": "x", "message": msg]]) }
        for (code, expect) in [(401, "rejected the key"), (429, "rate limiting"), (500, "problem"), (400, "refused")] {
            let t = MockTransport { _ in (err(code, "boom"), code) }
            do { _ = try await service(s, t).send(batchId: s.batch.id); Issue.record("should have thrown for \(code)") }
            catch { #expect((error as? DirectAIError)?.errorDescription?.contains(expect) == true, "\(code): \(error)") }
        }
        #expect(try s.rig.qs.list().isEmpty)
        #expect(try s.rig.ai.batches(taskId: s.batch.taskId)[0].exportedAt == nil, "a failed call must not mark the batch as sent")
    }

    @Test func networkAndShapeFailures() async throws {
        let s = try setup()
        let down = MockTransport { _ in throw URLError(.notConnectedToInternet) }
        await #expect(throws: DirectAIError.self) { try await service(s, down).send(batchId: s.batch.id) }
        for bad in [Data("not json".utf8), try JSONSerialization.data(withJSONObject: ["content": []]), try JSONSerialization.data(withJSONObject: ["x": 1])] {
            let t = MockTransport { _ in (bad, 200) }
            await #expect(throws: DirectAIError.malformedResponse) { try await service(s, t).send(batchId: s.batch.id) }
        }
        let refusal = MockTransport { _ in (try! JSONSerialization.data(withJSONObject: ["stop_reason": "refusal", "content": [["type": "text", "text": "no"]]]), 200) }
        await #expect(throws: DirectAIError.self) { try await service(s, refusal).send(batchId: s.batch.id) }
        #expect(try s.rig.qs.list().isEmpty && s.rig.ai.batches(taskId: s.batch.taskId)[0].exportedAt == nil)
    }

    @Test func modelIsConfigurableAndPreviewMatchesWhatIsSent() async throws {
        let s = try setup()
        try s.settings.set(.directAPIModel, "claude-opus-5-5")
        let t = MockTransport { _ in (self.messages("x"), 200) }
        let svc = service(s, t)
        let p = try svc.preview(batchId: s.batch.id)
        #expect(p.model == "claude-opus-5-5")
        _ = try? await svc.send(batchId: s.batch.id)
        let body = try #require(try JSONSerialization.jsonObject(with: t.requests.first?.httpBody ?? Data()) as? [String: Any])
        #expect(body["model"] as? String == "claude-opus-5-5")
        #expect((body["messages"] as? [[String: Any]])?.first?["content"] as? String == p.text)
    }

    @Test func secretsStayOutOfTheDatabaseAndBackups() throws {
        let s = try setup()
        try s.settings.set(.directAPIModel, "claude-sonnet-5-5")
        let rows = try s.rig.db.read { try String.fetchAll($0, sql: "SELECT value FROM settings") }
        #expect(rows.contains("true"))
        #expect(!rows.contains { $0.contains("sk-test-123") })
    }

    @Test func keychainRoundTrip() throws {
        let store = KeychainSecretStore(service: "com.braincell.tests.\(UUID().uuidString)")
        defer { try? store.delete("a") }
        do {
            #expect(try store.read("a") == nil)
            try store.write("a", value: "secret-1"); #expect(try store.read("a") == "secret-1")
            try store.write("a", value: "secret-2"); #expect(try store.read("a") == "secret-2")
            try store.delete("a"); #expect(try store.read("a") == nil)
        } catch DirectAIError.keychain(let status) {
            Issue.record("Keychain unavailable in this environment (status \(status)); untested here")
        }
    }

    @Test func keychainCopiesLegacyKeyOnFirstRead() throws {
        let id = UUID().uuidString
        let old = KeychainSecretStore(service: "com.braincell.tests.old.\(id)")
        let store = KeychainSecretStore(service: "com.braincell.tests.new.\(id)", legacyService: "com.braincell.tests.old.\(id)")
        defer { try? store.delete("a") }
        do {
            try old.write("a", value: "legacy-key")
            #expect(try store.read("a") == "legacy-key")
            try old.delete("a")
            #expect(try store.read("a") == "legacy-key") // already copied into the new service
            try store.delete("a"); #expect(try store.read("a") == nil)
        } catch DirectAIError.keychain(let status) {
            Issue.record("Keychain unavailable in this environment (status \(status)); untested here")
        }
    }
}

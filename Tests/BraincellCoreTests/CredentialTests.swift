import Testing
import Foundation
@testable import BraincellCore

/// Mock Keychain: counts every secret read and can simulate a macOS denial or a slow authorization dialog. No real keys or Keychain involved.
final class CountingStore: SecretStore, @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String: String]
    private(set) var reads = 0, containsCalls = 0
    var denyReads = false
    var readDelay: TimeInterval = 0
    init(_ items: [String: String] = [:]) { self.items = items }
    func read(_ account: String) throws -> String? {
        lock.withLock { reads += 1 }
        if readDelay > 0 { Thread.sleep(forTimeInterval: readDelay) }
        if denyReads { throw DirectAIError.keychain(-25293) }
        return lock.withLock { items[account] }
    }
    func write(_ account: String, value: String) throws { lock.withLock { items[account] = value } }
    func delete(_ account: String) throws { lock.withLock { items[account] = nil } }
    func contains(_ account: String) -> Bool { lock.withLock { containsCalls += 1; return items[account] != nil } }
    var readCount: Int { lock.withLock { reads } }
}

@Suite struct CredentialTests {
    func chat(_ text: String = "ok") -> Data {
        try! JSONSerialization.data(withJSONObject: ["choices": [["message": ["role": "assistant", "content": text]]], "usage": ["prompt_tokens": 10, "completion_tokens": 5]])
    }
    let modelList = try! JSONSerialization.data(withJSONObject: ["data": [["id": "m-1"]]])
    let quiz = WorkflowTask.find("chatAssistant")!

    /// A gateway whose keys live in `store` (wrapped by the same manager the app uses). Returns the connection and the headers each request carried.
    func setup(_ store: CountingStore, providers: [String] = ["openai"]) async throws -> (AIGateway, CredentialManager, [AIConnection], Box) {
        let seen = Box()
        let mgr = CredentialManager(store)
        let t = MockTransport { req in
            seen.add(req.value(forHTTPHeaderField: "authorization") ?? req.value(forHTTPHeaderField: "x-api-key") ?? "")
            return req.url!.path.hasSuffix("/models") ? (self.modelList, 200) : (self.chat(), 200)
        }
        let gw = AIGateway(db: try AppDatabase.inMemory(), secrets: mgr, transport: t)
        gw.setClock(sleep: { _ in }, now: { Date() })
        var conns: [AIConnection] = []
        for p in providers {
            let (c, _) = try await gw.connect(providerId: p, apiKey: "key-for-\(p)")
            conns.append(c)
        }
        try gw.store.setDefault(.llm, connection: conns[0].id, model: try gw.store.models(connection: conns[0].id).first!.modelId)
        return (gw, mgr, conns, seen)
    }
    final class Box: @unchecked Sendable { private let l = NSLock(); private var a: [String] = []; func add(_ s: String) { l.withLock { a.append(s) } }; var all: [String] { l.withLock { a } } }

    // MARK: Reuse

    @Test func manyRequestsAndToolStepsReadTheKeychainOnce() async throws {
        let store = CountingStore()
        let (gw, _, _, _) = try await setup(store)
        let before = store.readCount
        for _ in 0..<8 { try await gw.complete(task: quiz, prompt: "step") }          // a chat turn: model call, tool, model call, …
        #expect(store.readCount - before <= 1, "reads during eight requests: \(store.readCount - before)")
    }

    @Test func savedKeyIsServedFromMemoryAfterFirstRead() throws {
        let store = CountingStore(["ai-conn-1": "secret"])
        let m = CredentialManager(store)
        for _ in 0..<20 { #expect(try m.read("ai-conn-1") == "secret") }
        #expect(store.readCount == 1)
        #expect(try m.read("missing") == nil && (try m.read("missing")) == nil)       // absence is cached too
        #expect(store.readCount == 2)
    }

    @Test func existenceChecksNeverReadTheSecret() throws {
        let store = CountingStore(["a": "x"])
        let m = CredentialManager(store)
        #expect(m.contains("a") && !m.contains("b"))
        #expect(store.readCount == 0)
        _ = try m.read("a"); #expect(m.contains("a")); #expect(store.readCount == 1)
    }

    // MARK: Concurrency

    @Test func concurrentRequestsShareOneKeychainRead() async throws {
        let store = CountingStore(["a": "secret"]); store.readDelay = 0.2            // a slow authorization dialog
        let m = CredentialManager(store)
        let results = await withTaskGroup(of: String?.self) { g in
            for _ in 0..<12 { g.addTask { try? m.read("a") } }
            var out: [String?] = []; for await r in g { out.append(r) }; return out
        }
        #expect(results.allSatisfy { $0 == "secret" })
        #expect(store.readCount == 1)
    }

    // MARK: Invalidation

    @Test func replacingAKeyIsUsedImmediately() async throws {
        let store = CountingStore()
        let (gw, mgr, conns, seen) = try await setup(store)
        try await gw.complete(task: quiz, prompt: "a")
        try mgr.write(conns[0].keyAccount, value: "replacement-key")
        try await gw.complete(task: quiz, prompt: "b")
        #expect(seen.all.last?.contains("replacement-key") == true)
    }

    @Test func deletedKeyIsNeverServedFromTheCache() async throws {
        let store = CountingStore()
        let (gw, mgr, conns, _) = try await setup(store)
        try await gw.complete(task: quiz, prompt: "a")
        try mgr.delete(conns[0].keyAccount)
        await #expect(throws: GatewayError.noKey) { try await gw.complete(task: self.quiz, prompt: "b") }
        #expect(!gw.hasKey(conns[0]))
    }

    @Test func eachProviderGetsItsOwnKey() async throws {
        let store = CountingStore()
        let (gw, _, conns, seen) = try await setup(store, providers: ["openai", "deepseek"])
        try await gw.complete(task: quiz, prompt: "a")
        let second = conns[1]
        let m = try #require(try gw.store.models(connection: second.id).first)
        try gw.store.setDefault(.llm, connection: second.id, model: m.modelId)
        try await gw.complete(task: quiz, prompt: "b")
        try await gw.complete(task: quiz, prompt: "c")
        #expect(seen.all.suffix(3).first?.contains("key-for-openai") == true)
        #expect(seen.all.suffix(2).allSatisfy { $0.contains("key-for-deepseek") })
    }

    // MARK: Denial

    @Test func deniedAccessIsNotRetriedAndIsNotAModelError() async throws {
        let store = CountingStore()
        let (gw, _, _, _) = try await setup(store)
        let base = store.readCount
        store.denyReads = true
        // a fresh manager simulates a new session where nothing is cached yet
        let denied = CredentialManager(store)
        let gw2 = AIGateway(db: gw.store.db, secrets: denied, transport: MockTransport { _ in (self.chat(), 200) })
        gw2.setClock(sleep: { _ in }, now: { Date() })
        for _ in 0..<5 {
            do { try await gw2.complete(task: quiz, prompt: "x"); Issue.record("should have failed") }
            catch let e as GatewayError {
                guard case .keychain(let msg) = e else { Issue.record("wrong error \(e)"); continue }
                #expect(msg.contains("OpenAI") && !e.isRetryable && e.category == "keychain")
            }
        }
        #expect(store.readCount - base == 1, "a denial must be remembered, not re-asked")
        // explicit Retry re-asks exactly once, and succeeds once access is granted
        store.denyReads = false
        gw2.retryCredentialAccess()
        try await gw2.complete(task: quiz, prompt: "x")
        #expect(store.readCount - base == 2)
    }

    @Test func failuresNeverContainTheKey() async throws {
        let store = CountingStore()
        let (gw, _, conns, _) = try await setup(store)
        store.denyReads = true
        let g2 = AIGateway(db: gw.store.db, secrets: CredentialManager(store), transport: MockTransport { _ in (Data(), 401) })
        do { try await g2.complete(task: quiz, prompt: "x") } catch { #expect(!"\(error)".contains("key-for-openai") && !(error.localizedDescription).contains("key-for-openai")) }
        #expect(!DirectAIError.keychain(-25293).localizedDescription.contains("key-for"))
        _ = conns
    }

    @Test func keychainStatusCodesAreClassified() {
        for s in [-128, -25293, -25308, -25243] as [Int32] { #expect(DirectAIError.keychain(s).isDenied) }
        #expect(!DirectAIError.keychain(-25300).isDenied && !DirectAIError.noKey.isDenied)
    }

    // MARK: Compatibility

    @Test func existingSavedKeysStayReadable() throws {
        // A key saved by an earlier build sits under the same account name; the manager changes nothing about names or values.
        let id = UUID()
        let c = AIConnection(id: id, providerId: "openai", name: "OpenAI", baseURL: nil, enabled: true, status: .ready, lastCheckedAt: nil, createdAt: Date())
        let store = CountingStore([c.keyAccount: "saved-earlier"])
        let m = CredentialManager(store)
        #expect(try m.read(c.keyAccount) == "saved-earlier")
        #expect(c.keyAccount == "ai-conn-\(id.uuidString)")
    }
}

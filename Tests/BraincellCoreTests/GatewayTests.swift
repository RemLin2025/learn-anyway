import Testing
import Foundation
@testable import BraincellCore

/// No test here touches the network: every call goes through MockTransport.
@Suite struct GatewayTests {
    func json(_ o: Any) -> Data { try! JSONSerialization.data(withJSONObject: o) }
    func chat(_ text: String = "hello", inTok: Int = 100, outTok: Int = 50) -> Data {
        json(["choices": [["message": ["role": "assistant", "content": text]]], "usage": ["prompt_tokens": inTok, "completion_tokens": outTok]])
    }
    let modelList: Data = try! JSONSerialization.data(withJSONObject: ["data": [["id": "m-small"], ["id": "m-big"], ["id": "text-embedding-3-large"]]])

    struct GRig {
        let db: AppDatabase; let gw: AIGateway; let secrets: InMemorySecretStore; let t: MockTransport
    }
    func rig(_ reply: @escaping @Sendable (URLRequest) throws -> (Data, Int)) throws -> GRig {
        let db = try AppDatabase.inMemory(); let s = InMemorySecretStore(); let t = MockTransport(reply)
        let gw = AIGateway(db: db, secrets: s, transport: t)
        gw.setClock(sleep: { _ in }, now: { Date() })
        return GRig(db: db, gw: gw, secrets: s, t: t)
    }
    func connected(_ r: GRig, provider: String = "openai", price: (Double, Double)? = (1, 2)) async throws -> (AIConnection, [AIModelRecord]) {
        let (c, _) = try await r.gw.connect(providerId: provider, apiKey: "sk-secret-123")
        var ms = try r.gw.store.models(connection: c.id)
        if let price { for i in ms.indices { ms[i].inputPricePerM = price.0; ms[i].outputPricePerM = price.1; try r.gw.store.save(ms[i]) } }
        return (c, ms)
    }
    let quiz = WorkflowTask.find("quizGeneration")!

    // MARK: Credentials and connections

    @Test func badKeyStoresNothing() async throws {
        let r = try rig { _ in (Data(), 401) }
        await #expect(throws: GatewayError.invalidCredentials) { try await r.gw.connect(providerId: "openai", apiKey: "sk-bad") }
        #expect(try r.gw.store.connections().isEmpty)
        #expect(try r.secrets.read("anything") == nil)
    }

    @Test func keyGoesToSecretStoreNeverTheDatabase() async throws {
        let r = try rig { _ in (self.modelList, 200) }
        let (c, n) = try await r.gw.connect(providerId: "openai", apiKey: "  sk-secret-123 ")
        #expect(n == 2)                                                    // embedding model filtered out of the LLM list
        #expect(try r.secrets.read(c.keyAccount) == "sk-secret-123" && r.gw.hasKey(c) && c.status == .ready)
        let dump = try r.db.read { try String.fetchAll($0, sql: "SELECT providerId || name || COALESCE(baseURL,'') FROM ai_connections").joined() }
        #expect(!dump.contains("sk-secret"))
        let req = try #require(r.t.requests.first)
        #expect(req.value(forHTTPHeaderField: "Authorization") == "Bearer sk-secret-123")
        try r.gw.disconnect(c)
        let gone = try r.secrets.read(c.keyAccount), conns = try r.gw.store.connections(), models = try r.gw.store.models()
        #expect(gone == nil && conns.isEmpty && models.isEmpty)
    }

    @Test func plainHTTPAndUnsupportedProvidersAreRefused() async throws {
        let r = try rig { _ in (self.modelList, 200) }
        await #expect(throws: GatewayError.self) { try await r.gw.connect(providerId: "custom", baseURL: "http://example.com/v1", apiKey: "k") }
        await #expect(throws: GatewayError.self) { try await r.gw.connect(providerId: "minimax", apiKey: "k") }
        #expect(ProviderRegistry.validateBaseURL("http://localhost:11434") == nil && ProviderRegistry.validateBaseURL("https://api.x.com") == nil)
        #expect(r.t.count == 0)
    }

    @Test func openRouterPricingIsParsedAndKept() async throws {
        let body = json(["data": [["id": "a/b", "name": "AB", "pricing": ["prompt": "0.000001", "completion": "0.000004"]]]])
        let r = try rig { _ in (body, 200) }
        let (c, _) = try await r.gw.connect(providerId: "openrouter", apiKey: "k")
        let m = try #require(try r.gw.store.models(connection: c.id).first)
        #expect(m.inputPricePerM == 1 && m.outputPricePerM == 4)
    }

    @Test func ollamaNeedsNoKeyAndListsTags() async throws {
        let r = try rig { req in req.url!.path == "/api/tags" ? (self.json(["models": [["name": "llama3"]]]), 200) : (Data(), 404) }
        let (c, n) = try await r.gw.connect(providerId: "ollama", apiKey: "")
        #expect(n == 1 && !r.gw.hasKey(c))
    }

    // MARK: Capability matching and precedence

    @Test func noDefaultMeansAnActionableProblem() throws {
        let r = try rig { _ in (Data(), 200) }
        let res = try r.gw.resolve(quiz)
        #expect(res.primary == nil && res.problem?.contains("No AI provider is connected") == true)
    }

    @Test func llmDefaultNeverServesOtherCapabilities() async throws {
        let r = try rig { _ in (self.modelList, 200) }
        let (c, ms) = try await connected(r)
        try r.gw.store.setDefault(.llm, connection: c.id, model: ms[0].modelId)
        let img = try r.gw.resolve(WorkflowTask.find("imageGeneration")!)
        #expect(img.primary == nil && img.problem != nil)
        // Even a hand-built image default can't route: no adapter exists for it.
        try r.gw.store.save(AIModelRecord(id: UUID(), connectionId: c.id, modelId: "img-1", displayName: "img", capability: .imageGeneration, source: "manual", inputPricePerM: nil, outputPricePerM: nil, health: .untested, createdAt: Date()))
        try r.gw.store.setDefault(.imageGeneration, connection: c.id, model: "img-1")
        #expect(try r.gw.resolve(WorkflowTask.find("imageGeneration")!).primary == nil)
        await #expect(throws: GatewayError.self) { try await r.gw.complete(task: WorkflowTask.find("narration")!, prompt: "x") }
    }

    @Test func overrideBeatsDefaultAndInheritanceFollowsChanges() async throws {
        let r = try rig { _ in (self.modelList, 200) }
        let (c, ms) = try await connected(r)
        let small = ms.first { $0.modelId == "m-small" }!, big = ms.first { $0.modelId == "m-big" }!
        try r.gw.store.setDefault(.llm, connection: c.id, model: small.modelId)
        #expect(try r.gw.resolve(quiz).primary?.model.modelId == "m-small" && r.gw.resolve(quiz).inherited)
        var route = TaskRoute(task: quiz.id); route.inherit = false; route.connectionId = c.id; route.modelId = "m-big"; try r.gw.store.save(route)
        #expect(try r.gw.resolve(quiz).primary?.model.modelId == "m-big" && !r.gw.resolve(quiz).inherited)
        try r.gw.store.setDefault(.llm, connection: c.id, model: big.modelId)               // changing the default…
        let other = WorkflowTask.find("summaries")!
        #expect(try r.gw.resolve(other).primary?.model.modelId == "m-big")                  // …moves inheriting tasks
        try r.gw.store.setDefault(.llm, connection: c.id, model: small.modelId)
        #expect(try r.gw.resolve(other).primary?.model.modelId == "m-small")
        #expect(try r.gw.resolve(quiz).primary?.model.modelId == "m-big")                   // …but not explicit overrides
        try r.gw.store.resetRoute(quiz.id)
        #expect(try r.gw.resolve(quiz).primary?.model.modelId == "m-small")
    }

    @Test func brokenOverrideFallsBackToDefaultWithATrace() async throws {
        let r = try rig { _ in (self.modelList, 200) }
        let (c, _) = try await connected(r)
        try r.gw.store.setDefault(.llm, connection: c.id, model: "m-small")
        var route = TaskRoute(task: quiz.id); route.inherit = false; route.connectionId = c.id; route.modelId = "gone"; try r.gw.store.save(route)
        let res = try r.gw.resolve(quiz)
        #expect(res.primary?.model.modelId == "m-small" && res.trace.contains { $0.contains("isn’t registered") })
        try r.gw.setEnabled(c, false)
        #expect(try r.gw.resolve(quiz).primary == nil)
    }

    @Test func manualBridgeRouteNeverCallsTheNetworkOrCountsAsUsage() async throws {
        let r = try rig { _ in (self.chat(), 200) }
        var route = TaskRoute(task: quiz.id); route.manualBridge = true; try r.gw.store.save(route)
        await #expect { try await r.gw.complete(task: quiz, prompt: "p") } throws: { ($0 as? GatewayError)?.category == "manual" }
        let used = try r.gw.usage.requests(); #expect(r.t.count == 0 && used.isEmpty)
    }

    // MARK: Execution: retries, fallback, usage

    func setupTwo(_ r: GRig) async throws -> (AIConnection, AIConnection) {
        let (a, _) = try await connected(r)
        let (b, _) = try await r.gw.connect(providerId: "custom", name: "Backup", baseURL: "https://backup.example.com/v1", apiKey: "k2")
        try r.gw.store.setDefault(.llm, connection: a.id, model: "m-small")
        return (a, b)
    }

    @Test func serverErrorsAreRetriedBoundedlyThenFallBack() async throws {
        let r = try rig { req in
            if req.url!.path.hasSuffix("/models") { return (self.modelList, 200) }
            return req.url!.host == "api.openai.com" ? (Data(), 503) : (self.chat("from backup"), 200)
        }
        let (a, b) = try await setupTwo(r)
        _ = a
        var route = TaskRoute(task: quiz.id); route.maxRetries = 2; route.fallbackConnectionId = b.id; route.fallbackModelId = "m-small"; try r.gw.store.save(route)
        let before = r.t.count
        let out = try await r.gw.complete(task: quiz, prompt: "p")
        #expect(out.text == "from backup")
        #expect(r.t.count - before == 3 + 1)                       // 1 + 2 retries on the primary, then exactly one fallback call
        let rows = try r.gw.usage.requests()
        #expect(rows.filter { $0.status == "failed" }.count == 3 && rows.filter { $0.status == "success" }.count == 1)
    }

    @Test func authErrorsAreNotRetriedAndRateLimitsAre() async throws {
        let calls = Counter()
        let r = try rig { req in
            if req.url!.path.hasSuffix("/models") { return (self.modelList, 200) }
            let n = calls.next()
            return n == 1 ? (Data(), 429) : (self.chat(), 200)
        }
        let (c, _) = try await connected(r)
        try r.gw.store.setDefault(.llm, connection: c.id, model: "m-small")
        _ = try await r.gw.complete(task: quiz, prompt: "p")
        #expect(calls.value == 2)                                   // 429 once, then success

        let r2 = try rig { req in req.url!.path.hasSuffix("/models") ? (self.modelList, 200) : (Data(), 401) }
        let (c2, _) = try await connected(r2)
        try r2.gw.store.setDefault(.llm, connection: c2.id, model: "m-small")
        let before = r2.t.count
        await #expect(throws: GatewayError.invalidCredentials) { try await r2.gw.complete(task: quiz, prompt: "p") }
        #expect(r2.t.count - before == 1)
    }

    @Test func retryCeilingHoldsEvenIfConfiguredHigher() async throws {
        let r = try rig { req in req.url!.path.hasSuffix("/models") ? (self.modelList, 200) : (Data(), 500) }
        let (c, _) = try await connected(r)
        try r.gw.store.setDefault(.llm, connection: c.id, model: "m-small")
        var route = TaskRoute(task: quiz.id); route.maxRetries = 99; try r.gw.store.save(route)
        let before = r.t.count
        await #expect(throws: GatewayError.self) { try await r.gw.complete(task: quiz, prompt: "p") }
        #expect(r.t.count - before == 4)
    }

    @Test func cancellationStopsBeforeSending() async throws {
        let r = try rig { _ in (self.modelList, 200) }
        let (c, _) = try await connected(r)
        try r.gw.store.setDefault(.llm, connection: c.id, model: "m-small")
        let before = r.t.count
        let t = Task { try await r.gw.complete(task: quiz, prompt: "p") }
        t.cancel()
        await #expect(throws: GatewayError.cancelled) { try await t.value }
        #expect(r.t.count == before)
    }

    @Test func usageIsRecordedWithHonestCosts() async throws {
        let r = try rig { req in req.url!.path.hasSuffix("/models") ? (self.modelList, 200) : (self.chat(inTok: 1000, outTok: 500), 200) }
        let (c, _) = try await connected(r, price: (2, 10))          // $2 / $10 per million tokens
        try r.gw.store.setDefault(.llm, connection: c.id, model: "m-small")
        _ = try await r.gw.complete(task: quiz, prompt: "secret prompt text")
        let row = try #require(try r.gw.usage.requests().first)
        #expect(row.inputTokens == 1000 && row.outputTokens == 500 && row.costMicros == 7000 && row.costBasis == "estimated")  // $0.007
        #expect(row.errorCategory == nil && row.task == "quizGeneration")
        let t = r.gw.usage.totals(try r.gw.usage.requests())
        #expect(t.requests == 1 && t.totalTokens == 1500 && t.costIsComplete)
        let csv = r.gw.usage.historyCSV(try r.gw.usage.requests()) + r.gw.usage.summaryCSV(try r.gw.usage.requests())
        #expect(!csv.contains("sk-secret") && !csv.contains("secret prompt") && csv.contains("0.007000"))

        // Unknown pricing is "unknown", never zero.
        for var m in try r.gw.store.models(connection: c.id) { m.inputPricePerM = nil; m.outputPricePerM = nil; try r.gw.store.save(m) }
        _ = try await r.gw.complete(task: quiz, prompt: "p")
        let rows = try r.gw.usage.requests()
        #expect(rows.first!.costMicros == nil && rows.first!.costBasis == "unknown")
        #expect(!r.gw.usage.totals(rows).costIsComplete)
        #expect(r.gw.usage.historyCSV(rows).contains("unknown"))
    }

    @Test func localModelsAreFreeButStillTracked() async throws {
        let r = try rig { req in req.url!.path == "/api/tags" ? (self.json(["models": [["name": "llama3"]]]), 200) : (self.chat(), 200) }
        let (c, _) = try await r.gw.connect(providerId: "ollama", apiKey: "")
        try r.gw.store.setDefault(.llm, connection: c.id, model: "llama3")
        _ = try await r.gw.complete(task: quiz, prompt: "p")
        let row = try #require(try r.gw.usage.requests().first)
        #expect(row.costMicros == 0 && row.costBasis == "local" && row.providerId == "ollama")
        #expect(r.t.requests.last?.url?.path == "/v1/chat/completions")
    }

    @Test func gatewayGroupingByDayModelProvider() async throws {
        let r = try rig { req in req.url!.path.hasSuffix("/models") ? (self.modelList, 200) : (self.chat(), 200) }
        let (c, _) = try await connected(r)
        try r.gw.store.setDefault(.llm, connection: c.id, model: "m-small")
        for _ in 0..<3 { _ = try await r.gw.complete(task: quiz, prompt: "p") }
        let rows = try r.gw.usage.requests()
        #expect(r.gw.usage.byDay(rows).count == 1 && r.gw.usage.byDay(rows)[0].requests == 3)
        #expect(r.gw.usage.grouped(rows, by: .model)[0].requests == 3 && r.gw.usage.grouped(rows, by: .provider)[0].provider == "openai")
        #expect(try r.gw.usage.requests(.lastDays(1)).count == 3 && (try r.gw.usage.requests(UsageRange(from: Date().addingTimeInterval(3600)))).isEmpty)
    }

    // MARK: Budget

    @Test func budgetIsEnforcedByTheGatewayNotTheUI() async throws {
        let r = try rig { req in req.url!.path.hasSuffix("/models") ? (self.modelList, 200) : (self.chat(inTok: 1_000_000, outTok: 0), 200) }
        let (c, _) = try await connected(r, price: (5, 5))                // one call = $5
        try r.gw.store.setDefault(.llm, connection: c.id, model: "m-small")
        var b = BudgetSettings(); b.daily = 5; b.enforce = true; try b.save(r.gw.settings)
        _ = try await r.gw.complete(task: quiz, prompt: "p")
        let sent = r.t.count
        await #expect { try await r.gw.complete(task: quiz, prompt: "p") } throws: { ($0 as? GatewayError)?.category == "budget" }
        #expect(r.t.count == sent)
        b.enforce = false; try b.save(r.gw.settings)
        _ = try await r.gw.complete(task: quiz, prompt: "p")              // warnings-only mode doesn't block
        b.enforce = false; b.maxRequestsPerDay = 2; try b.save(r.gw.settings)
        await #expect { try await r.gw.complete(task: quiz, prompt: "p") } throws: { ($0 as? GatewayError)?.category == "budget" }
        #expect(BudgetSettings.load(r.gw.settings).maxRequestsPerDay == 2)
    }

    @Test func costPreviewOnlyWhenPricesAreKnown() async throws {
        let r = try rig { _ in (self.modelList, 200) }
        let (c, ms) = try await connected(r, price: (2, 10))
        var t = Target(connection: c, model: ms[0])
        #expect(r.gw.estimatedCost(t, promptCharacters: 4000, maxOutputTokens: 1000) == Double(1000 * 2 + 1000 * 10) / 1_000_000)
        t = Target(connection: c, model: { var m = ms[0]; m.inputPricePerM = nil; return m }())
        #expect(r.gw.estimatedCost(t, promptCharacters: 4000) == nil)
    }

    // MARK: Workflow

    @Test func dependencyGraphIsValidAndOrdered() {
        #expect(WorkflowGraph.validate().isEmpty)
        let order = try! #require(WorkflowGraph.executionOrder())
        for t in WorkflowTask.all { for d in t.dependsOn { #expect(order.firstIndex(of: d)! < order.firstIndex(of: t.id)!) } }
        let cyc = [WorkflowTask(id: "a", title: "a", capability: .llm, group: .core, summary: "", dependsOn: ["b"], optional: false),
                   WorkflowTask(id: "b", title: "b", capability: .llm, group: .core, summary: "", dependsOn: ["a"], optional: false)]
        #expect(WorkflowGraph.hasCycle(cyc) && !WorkflowGraph.validate(cyc).isEmpty && WorkflowGraph.executionOrder(cyc) == nil)
        #expect(Set(WorkflowTask.all.map(\.capability)) == Set(Capability.allCases))
    }

    @Test func runnerSkipsOptionalPausesForManualAndKeepsEarlierResults() async throws {
        let r = try rig { req in req.url!.path.hasSuffix("/models") ? (self.modelList, 200) : (self.chat(), 200) }
        let (c, _) = try await connected(r)
        try r.gw.store.setDefault(.llm, connection: c.id, model: "m-small")
        let runner = WorkflowRunner(gateway: r.gw)
        let lesson = WorkflowTask.find("lessonContent")!, narr = WorkflowTask.find("narration")!, summ = WorkflowTask.find("summaries")!
        var s = await runner.run([Stage(task: lesson) { _ in "lesson text" }, Stage(task: narr) { _ in "audio" }, Stage(task: summ) { prev in "sum of " + (prev["lessonContent"] ?? "") }])
        #expect(s["lessonContent"] == .done("lesson text"))
        if case .skipped = s["narration"]! {} else { Issue.record("optional unconfigured stage should be skipped") }
        #expect(s["summaries"] == .done("sum of lesson text"))

        var route = TaskRoute(task: "summaries"); route.manualBridge = true; try r.gw.store.save(route)
        s = await runner.run([Stage(task: lesson) { _ in "ok" }, Stage(task: summ) { _ in "never" }])
        if case .pendingManual = s["summaries"]! {} else { Issue.record("expected a manual pause") }
        #expect(s["lessonContent"] == .done("ok"))

        try r.gw.store.resetRoute("summaries")
        s = await runner.run([Stage(task: lesson) { _ in "kept" }, Stage(task: summ, optional: true) { _ in throw GatewayError.malformed }])
        #expect(s["lessonContent"] == .done("kept"))
        if case .failed = s["summaries"]! {} else { Issue.record("optional failure should be recorded") }
        s = await runner.run([Stage(task: WorkflowTask.find("documentParsing")!) { _ in "x" }])        // required + unconfigured
        if case .failed(let m) = s["documentParsing"]! { #expect(m.contains("Document Parsing")) } else { Issue.record("required unconfigured stage should fail") }
    }

    // MARK: Presets, export, persistence

    @Test func presetsUseRealPricedModelsAndShowChangesFirst() async throws {
        let r = try rig { _ in (self.modelList, 200) }
        let (c, _) = try await connected(r, price: nil)
        var ms = try r.gw.store.models(connection: c.id)
        ms[0].outputPricePerM = 1; ms[1].outputPricePerM = 9; try ms.forEach { try r.gw.store.save($0) }
        let planner = PresetPlanner(store: r.gw.store)
        let cheap = try planner.plan(.budget); let high = try planner.plan(.highQuality)
        #expect(cheap.first?.to.hasPrefix(ms[0].modelId) == true && high.first?.to.hasPrefix(ms[1].modelId) == true)
        #expect(try r.gw.store.capabilityDefault(.llm) == nil)             // planning changes nothing
        try planner.apply(try planner.plan(.balanced))
        #expect(try r.gw.store.capabilityDefault(.llm) != nil && (try r.gw.store.route("planningAgent")).inherit == false)
        #expect(try planner.plan(.balanced).isEmpty)                      // already applied: nothing left to change
        let none = try rig { _ in (self.modelList, 200) }
        #expect(try PresetPlanner(store: none.gw.store).plan(.budget).isEmpty)
    }

    @Test func exportHasNoSecretsAndImportAsksForMissingKeys() async throws {
        let r = try rig { _ in (self.modelList, 200) }
        let (c, _) = try await connected(r)
        try r.gw.store.setDefault(Capability.llm, connection: c.id, model: "m-small")
        var route = TaskRoute(task: quiz.id); route.inherit = false; route.connectionId = c.id; route.modelId = "m-big"; try r.gw.store.save(route)
        let data = try JSONEncoder().encode(try GatewayConfigExport.make(r.gw.store))
        #expect(!String(decoding: data, as: UTF8.self).contains("sk-secret"))
        let fresh = try rig { _ in (Data(), 200) }
        let cfg = try JSONDecoder().decode(GatewayConfigExport.self, from: data)
        let missing = try cfg.apply(to: fresh.gw.store, secrets: fresh.secrets)
        #expect(missing == ["OpenAI"])
        #expect(try fresh.gw.store.route(quiz.id).modelId == "m-big" && fresh.gw.store.capabilityDefault(.llm)?.modelId == "m-small")
        #expect(try fresh.gw.resolve(quiz).primary?.connection.status == .configured)
    }

    @Test func configurationSurvivesReopeningTheDatabase() async throws {
        let dir = try tempDir(); let url = dir.appendingPathComponent("t.sqlite")
        let db = try AppDatabase.open(at: url); let s = InMemorySecretStore()
        let gw = AIGateway(db: db, secrets: s, transport: MockTransport { _ in (self.modelList, 200) })
        let (c, _) = try await gw.connect(providerId: "openai", apiKey: "k")
        try gw.store.setDefault(.llm, connection: c.id, model: "m-small")
        var route = TaskRoute(task: quiz.id); route.maxRetries = 2; route.instruction = "Be brief."; try gw.store.save(route)
        var b = BudgetSettings(); b.daily = 3; try b.save(gw.settings)
        let gw2 = AIGateway(db: try AppDatabase.open(at: url), secrets: s)
        #expect(try gw2.store.connections().count == 1 && gw2.store.capabilityDefault(.llm)?.modelId == "m-small")
        #expect(try gw2.store.route(quiz.id).instruction == "Be brief." && BudgetSettings.load(gw2.settings).daily == 3)
        #expect(try gw2.resolve(quiz).primary?.model.modelId == "m-small")
    }

    // MARK: Existing bridge

    @Test func existingRequestsRouteThroughTheGatewayAndImportLikeAPaste() async throws {
        let rig0 = try Rig()
        let t = try rig0.ai.createGenerationTask(courseId: rig0.course.id, params: GenerationParams(count: 3))
        let batch = try rig0.ai.batches(taskId: t.id)[0]
        let reply = Fx.envelope(batch.requestId, Array(Fx.all.prefix(3)))
        let transport = MockTransport { req in req.url!.path.hasSuffix("/models") ? (self.modelList, 200) : (self.chat(reply), 200) }
        let gw = AIGateway(db: rig0.db, secrets: InMemorySecretStore(), transport: transport)
        let svc = DirectAIService(ai: rig0.ai, settings: SettingsStore(db: rig0.db), secrets: InMemorySecretStore(), transport: transport)
        #expect(svc.gatewayTarget(batchId: batch.id, via: gw) == nil)                       // nothing configured: callers fall back
        let (c, _) = try await gw.connect(providerId: "openai", apiKey: "k")
        try gw.store.setDefault(.llm, connection: c.id, model: "m-small")
        #expect(svc.gatewayTarget(batchId: batch.id, via: gw)?.model.modelId == "m-small")
        guard case .questions(let rep) = try await svc.send(batchId: batch.id, via: gw) else { Issue.record("expected questions"); return }
        #expect(rep.accepted.count == 3)
        let row = try #require(try gw.usage.requests().first)
        #expect(row.task == "quizGeneration" && row.courseId == rig0.course.id)
    }
}

final class Counter: @unchecked Sendable {
    private let l = NSLock(); private var n = 0
    func next() -> Int { l.withLock { n += 1; return n } }
    var value: Int { l.withLock { n } }
}

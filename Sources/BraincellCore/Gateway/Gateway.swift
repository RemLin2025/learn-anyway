import Foundation

public enum CostEstimator {
    /// (micro-USD, basis). Unknown prices give nil, never zero; local models are free of cloud charges.
    public static func estimate(model: AIModelRecord, spec: ProviderSpec?, input: Int?, output: Int?) -> (Int64?, String) {
        if spec?.isLocal == true { return (0, "local") }
        guard let ip = model.inputPricePerM, let op = model.outputPricePerM, let i = input, let o = output else { return (nil, "unknown") }
        return (Int64((Double(i) * ip + Double(o) * op).rounded()), "estimated")   // $/M tokens == µ$/token
    }
}

public struct BudgetSettings: Sendable, Equatable {
    public var daily: Double?, monthly: Double?, perRequest: Double?
    public var warnPercent = 80
    public var maxRequestsPerDay: Int?
    public var enforce = false
    public init() {}
    public static func load(_ s: SettingsStore) -> BudgetSettings {
        var b = BudgetSettings()
        func d(_ k: SettingKey) -> Double? { ((try? s.string(k)) ?? nil).flatMap(Double.init).flatMap { $0 > 0 ? $0 : nil } }
        b.daily = d(.budgetDaily); b.monthly = d(.budgetMonthly); b.perRequest = d(.budgetPerRequest)
        b.warnPercent = (try? s.int(.budgetWarnPercent, default: 80)) ?? 80
        b.maxRequestsPerDay = ((try? s.string(.budgetMaxRequestsPerDay)) ?? nil).flatMap(Int.init).flatMap { $0 > 0 ? $0 : nil }
        b.enforce = (try? s.bool(.budgetEnforce)) ?? false
        return b
    }
    public func save(_ s: SettingsStore) throws {
        try s.set(.budgetDaily, daily.map { String($0) } ?? ""); try s.set(.budgetMonthly, monthly.map { String($0) } ?? "")
        try s.set(.budgetPerRequest, perRequest.map { String($0) } ?? ""); try s.set(.budgetWarnPercent, String(warnPercent))
        try s.set(.budgetMaxRequestsPerDay, maxRequestsPerDay.map { String($0) } ?? ""); try s.set(.budgetEnforce, enforce)
    }
}

/// Every model request the app makes goes through here: routing, budget checks, bounded retries, fallback and usage recording.
/// App-level limits cannot stop charges made outside Learn Anyway.
public final class AIGateway: @unchecked Sendable {
    public let store: GatewayStore
    public let settings: SettingsStore
    let secrets: SecretStore
    let client: ProviderClient
    public let usage: UsageService
    /// Injected so tests don’t wait on real backoff.
    var sleep: @Sendable (TimeInterval) async -> Void = { try? await Task.sleep(nanoseconds: UInt64($0 * 1_000_000_000)) }
    var now: @Sendable () -> Date = { Date() }

    public init(db: AppDatabase, secrets: SecretStore, transport: HTTPTransport = URLSessionTransport()) {
        store = GatewayStore(db: db); settings = SettingsStore(db: db); self.secrets = secrets
        client = ProviderClient(transport: transport); usage = UsageService(store: store)
    }
    func setClock(sleep: @escaping @Sendable (TimeInterval) async -> Void, now: @escaping @Sendable () -> Date) { self.sleep = sleep; self.now = now }

    public func resolve(_ task: WorkflowTask) throws -> Resolution { try ModelRouter(store: store).resolve(task) }
    /// Resolves every task from a single database read (used by the workflow canvas).
    public func resolveAll() throws -> [String: Resolution] { try ModelRouter(store: store).resolveAll() }

    // MARK: Connections

    /// Validates the key with a real model-list call BEFORE anything is stored. Nothing is spent (listing is free on every supported provider).
    @discardableResult
    public func connect(providerId: String, name: String? = nil, baseURL: String? = nil, apiKey: String) async throws -> (AIConnection, Int) {
        guard let spec = ProviderRegistry.spec(providerId), spec.isImplemented else { throw GatewayError.unsupported("That provider isn’t supported yet.") }
        let base = (baseURL?.isEmpty == false ? baseURL! : spec.baseURL)
        if let bad = ProviderRegistry.validateBaseURL(base) { throw GatewayError.unavailable(bad) }
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if spec.needsKey, key.isEmpty { throw GatewayError.noKey }
        var c = AIConnection(id: UUID(), providerId: providerId, name: name ?? spec.name, baseURL: baseURL?.isEmpty == false ? baseURL : nil,
                             enabled: true, status: .configured, lastCheckedAt: nil, createdAt: now())
        let found = try await client.listModels(c, key: key)       // throws .invalidCredentials etc. without storing anything
        if spec.needsKey { try secrets.write(c.keyAccount, value: key) }
        c.status = .ready; c.lastCheckedAt = now()
        try store.save(c)
        try store.merge(discovered: found.map { record($0, c) })
        return (c, found.count)
    }

    public func replaceKey(_ c: AIConnection, apiKey: String) async throws {
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        _ = try await client.listModels(c, key: key)
        try secrets.write(c.keyAccount, value: key)
        var u = c; u.status = .ready; u.lastCheckedAt = now(); try store.save(u)
    }

    public func refreshModels(_ c: AIConnection) async throws -> Int {
        var u = c
        do {
            let found = try await client.listModels(c, key: try secrets.read(c.keyAccount))
            try store.merge(discovered: found.map { record($0, c) })
            u.status = c.enabled ? .ready : .disabled; u.lastCheckedAt = now(); try store.save(u)
            return found.count
        } catch let e as GatewayError {
            u.status = e == .invalidCredentials ? .invalidCredentials : .unavailable; u.lastCheckedAt = now(); try? store.save(u); throw e
        }
    }

    public func setEnabled(_ c: AIConnection, _ on: Bool) throws {
        var u = c; u.enabled = on; u.status = on ? (c.status == .disabled ? .configured : c.status) : .disabled; try store.save(u)
    }

    /// Applies a non-secret settings export using the app's own Keychain; returns the connections that still need a key.
    public func importConfig(_ c: GatewayConfigExport) throws -> [String] { try c.apply(to: store, secrets: secrets) }

    public func hasKey(_ c: AIConnection) -> Bool { ((try? secrets.read(c.keyAccount)) ?? nil)?.isEmpty == false }

    /// Deletes the stored key and the connection (models and defaults go with it; task routes revert to inheriting).
    public func disconnect(_ c: AIConnection) throws { try secrets.delete(c.keyAccount); try store.removeConnection(c.id) }

    func record(_ d: DiscoveredModel, _ c: AIConnection) -> AIModelRecord {
        AIModelRecord(id: UUID(), connectionId: c.id, modelId: d.id, displayName: d.name, capability: .llm, source: "discovered",
                      inputPricePerM: d.inputPricePerM, outputPricePerM: d.outputPricePerM, health: .untested, createdAt: now())
    }

    // MARK: Requests

    /// A rough pre-send estimate (≈4 characters per token) for the per-request warning. nil when prices are unknown.
    public func estimatedCost(_ t: Target, promptCharacters: Int, maxOutputTokens: Int = 4096) -> Double? {
        let (m, basis) = CostEstimator.estimate(model: t.model, spec: t.connection.spec, input: promptCharacters / 4, output: maxOutputTokens)
        return basis == "unknown" ? nil : m.map { Double($0) / 1_000_000 }
    }

    public func budgetCheck() throws {
        let b = BudgetSettings.load(settings)
        let day = try usage.spend(since: Calendar.current.startOfDay(for: now()))
        if let cap = b.maxRequestsPerDay, try usage.requestCount(since: Calendar.current.startOfDay(for: now())) >= cap {
            throw GatewayError.budgetBlocked("The daily request limit (\(cap)) set in Usage & Analytics has been reached.")
        }
        guard b.enforce else { return }
        if let d = b.daily, day >= d { throw GatewayError.budgetBlocked("The daily budget of \(Self.usd(d)) is used up (known costs only). Raise it in Usage & Analytics.") }
        if let m = b.monthly {
            let start = Calendar.current.date(from: Calendar.current.dateComponents([.year, .month], from: now()))!
            if try usage.spend(since: start) >= m { throw GatewayError.budgetBlocked("The monthly budget of \(Self.usd(m)) is used up (known costs only). Raise it in Usage & Analytics.") }
        }
    }
    static func usd(_ v: Double) -> String { String(format: "$%.2f", v) }

    @discardableResult
    public func complete(task: WorkflowTask, prompt: String, courseId: UUID? = nil, label: String? = nil) async throws -> LLMResult {
        guard task.capability == .llm else { throw GatewayError.unsupported("\(task.title) isn’t an LLM task, and no adapter for \(task.capability.label) exists in this build yet.") }
        let res = try resolve(task)
        if res.manual { throw GatewayError.manualRequired("\(task.title) is set to the manual ChatGPT Bridge. Prepare the request and import the reply yourself.") }
        guard let primary = res.primary else { throw GatewayError.unavailable(res.problem ?? "No model available.") }
        try budgetCheck()
        let route = try store.route(task.id)
        var req = LLMRequest(prompt: prompt, system: route.instruction?.isEmpty == false ? route.instruction : nil,
                             temperature: route.temperature, maxTokens: route.maxTokens, timeout: TimeInterval(max(5, route.timeoutSeconds)))
        req.prompt = prompt
        var last: Error = GatewayError.malformed
        for (i, target) in [primary, res.fallback].compactMap({ $0 }).enumerated() {
            let tries = max(0, min(route.maxRetries, 3)) + 1            // hard ceiling: a billable call is never repeated without bound
            for attempt in 1...tries {
                if Task.isCancelled { throw GatewayError.cancelled }
                let started = now()
                do {
                    var out = try await client.complete(target.connection, model: target.model.modelId, key: try secrets.read(target.connection.keyAccount), req)
                    out.trace = res.trace + (i == 1 ? ["Answered by the fallback model."] : [])
                    try log(target, task, courseId, started, out, nil)
                    return out
                } catch {
                    let ge = (error as? GatewayError) ?? (error is CancellationError ? .cancelled : .network(error.localizedDescription))
                    try? log(target, task, courseId, started, nil, ge)
                    last = ge
                    if ge == .cancelled { throw ge }
                    guard ge.isRetryable, attempt < tries else { break }
                    if case .rateLimited(let ra) = ge { await sleep(min(ra ?? 2, 30)) } else { await sleep(min(pow(2, Double(attempt - 1)), 8)) }
                }
            }
        }
        throw last
    }

    /// One minimal request to check a model works. Costs a few tokens; recorded like any other request.
    public func test(_ t: Target) async -> Result<String, GatewayError> {
        let started = now()
        do {
            let out = try await client.complete(t.connection, model: t.model.modelId, key: try secrets.read(t.connection.keyAccount),
                                                LLMRequest(prompt: "Reply with the single word OK.", maxTokens: 16, timeout: 30))
            try log(t, WorkflowTask.find("summaries")!, nil, started, out, nil, taskLabel: "test")
            var m = t.model; m.health = .ready; try store.save(m)
            return .success(out.text)
        } catch {
            let ge = (error as? GatewayError) ?? .network(error.localizedDescription)
            try? log(t, WorkflowTask.find("summaries")!, nil, started, nil, ge, taskLabel: "test")
            var m = t.model; m.health = .failed; try? store.save(m)
            return .failure(ge)
        }
    }

    func log(_ t: Target, _ task: WorkflowTask, _ course: UUID?, _ started: Date, _ out: LLMResult?, _ err: GatewayError?, taskLabel: String? = nil) throws {
        let (cost, basis) = out == nil ? (nil, "unknown") : CostEstimator.estimate(model: t.model, spec: t.connection.spec, input: out?.inputTokens, output: out?.outputTokens)
        try store.record(AIRequestRecord(id: UUID(), ts: started, connectionId: t.connection.id, providerId: t.connection.providerId, modelId: t.model.modelId,
                                         capability: task.capability, task: taskLabel ?? task.id, courseId: course, status: err == nil ? "success" : "failed",
                                         latencyMs: Int(now().timeIntervalSince(started) * 1000), inputTokens: out?.inputTokens, outputTokens: out?.outputTokens,
                                         cachedTokens: out?.cachedTokens, costMicros: cost, costBasis: basis, errorCategory: err?.category))
    }
}

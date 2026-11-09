import Foundation
import GRDB

// MARK: Pipeline execution

public enum StageState: Equatable, Sendable {
    case pending, running
    case done(String)
    case skipped(String)
    case failed(String)
    /// Needs the learner to use the manual ChatGPT Bridge; the run pauses here without blocking the app.
    case pendingManual(String)
}

public struct Stage: Sendable {
    public let task: WorkflowTask
    public let optional: Bool
    public let run: @Sendable (_ previous: [String: String]) async throws -> String
    public init(task: WorkflowTask, optional: Bool? = nil, run: @escaping @Sendable ([String: String]) async throws -> String) {
        self.task = task; self.optional = optional ?? task.optional; self.run = run
    }
}

/// Runs stages in order, passing each stage’s output to later ones.
/// A failed optional stage never discards earlier results; a required failure stops the run but keeps completed stages.
public struct WorkflowRunner: Sendable {
    let gateway: AIGateway
    public init(gateway: AIGateway) { self.gateway = gateway }

    public func run(_ stages: [Stage], onChange: (@Sendable (String, StageState) -> Void)? = nil) async -> [String: StageState] {
        var states = Dictionary(uniqueKeysWithValues: stages.map { ($0.task.id, StageState.pending) })
        var outputs: [String: String] = [:]
        func set(_ id: String, _ s: StageState) { states[id] = s; onChange?(id, s) }
        for st in stages {
            if Task.isCancelled { set(st.task.id, .failed("Cancelled.")); break }
            let res = try? gateway.resolve(st.task)
            if res?.manual == true { set(st.task.id, .pendingManual("\(st.task.title) is set to the manual ChatGPT Bridge. Prepare the request, paste it into ChatGPT, then import the reply.")); break }
            if res?.isReady != true {
                let why = res?.problem ?? "Not configured."
                if st.optional { set(st.task.id, .skipped(why)); continue }
                set(st.task.id, .failed(why)); break
            }
            set(st.task.id, .running)
            do { let out = try await st.run(outputs); outputs[st.task.id] = out; set(st.task.id, .done(out)) }
            catch {
                let msg = error.localizedDescription
                set(st.task.id, .failed(msg))
                if !st.optional || (error as? GatewayError) == .cancelled { break }
            }
        }
        return states
    }
}

// MARK: Presets

public enum Preset: String, CaseIterable, Sendable, Identifiable {
    case balanced = "Balanced", budget = "Budget", highQuality = "High Quality"
    public var id: String { rawValue }
    public var summary: String {
        switch self {
        case .balanced: "A mid-priced default; harder tasks use your strongest model."
        case .budget: "Your cheapest usable model everywhere."
        case .highQuality: "Your most capable (highest-priced) model everywhere."
        }
    }
}

public struct PlannedChange: Identifiable, Sendable, Equatable {
    public var id: String { taskId ?? "default.llm" }
    public let taskId: String?          // nil = the LLM default
    public let title: String
    public let from: String
    public let to: String
    let connection: UUID?; let model: String?
}

/// Builds a preset from models that actually exist and are usable now. Ranking uses known prices only (no model names are hardcoded);
/// with no priced model it produces nothing rather than guessing.
public struct PresetPlanner: Sendable {
    let store: GatewayStore
    public init(store: GatewayStore) { self.store = store }
    static let heavy = ["planningAgent", "codingProblem", "answerEvaluation", "knowledgeGap", "longAnswer"]

    public func plan(_ p: Preset) throws -> [PlannedChange] {
        let conns = Dictionary(uniqueKeysWithValues: try store.connections().filter { $0.enabled && $0.status != .invalidCredentials }.map { ($0.id, $0) })
        let ranked = try store.models(capability: .llm)
            .filter { conns[$0.connectionId] != nil && $0.health != .failed }
            .compactMap { m -> (AIModelRecord, Double)? in
                if conns[m.connectionId]?.spec?.isLocal == true { return (m, 0) }
                guard let o = m.outputPricePerM else { return nil }; return (m, o)
            }.sorted { $0.1 < $1.1 }
        guard !ranked.isEmpty else { return [] }
        let cheapest = ranked.first!.0, top = ranked.last!.0, mid = ranked[ranked.count / 2].0
        let routes = try store.routes()
        let curDefault = try store.capabilityDefault(.llm)
        func name(_ c: UUID?, _ m: String?) -> String { guard let c, let m else { return "Not set" }; return "\(m) · \(conns[c]?.name ?? "?")" }
        var out: [PlannedChange] = []
        let def = p == .budget ? cheapest : p == .highQuality ? top : mid
        if curDefault?.modelId != def.modelId || curDefault?.connectionId != def.connectionId {
            out.append(PlannedChange(taskId: nil, title: "Default Model", from: name(curDefault?.connectionId, curDefault?.modelId), to: name(def.connectionId, def.modelId), connection: def.connectionId, model: def.modelId))
        }
        for id in Self.heavy {
            guard let t = WorkflowTask.find(id) else { continue }
            let r = routes[id]
            let wantModel: AIModelRecord? = p == .balanced ? top : nil
            let cur = (r?.inherit ?? true) ? "Follows default" : name(r?.connectionId, r?.modelId)
            let new = wantModel.map { name($0.connectionId, $0.modelId) } ?? "Follows default"
            if cur != new { out.append(PlannedChange(taskId: id, title: t.title, from: cur, to: new, connection: wantModel?.connectionId, model: wantModel?.modelId)) }
        }
        return out
    }

    public func apply(_ changes: [PlannedChange]) throws {
        for c in changes {
            if let id = c.taskId {
                var r = try store.route(id)
                if let conn = c.connection, let m = c.model { r.inherit = false; r.connectionId = conn; r.modelId = m } else { r.inherit = true; r.connectionId = nil; r.modelId = nil }
                try store.save(r)
            } else if let conn = c.connection, let m = c.model { try store.setDefault(.llm, connection: conn, model: m) }
        }
    }
}

// MARK: Plan defaults

public extension GatewayStore {
    /// What connecting a plan provider would change if applied: only unset or different LLM defaults. Never applied silently.
    func suggestedDefault(for connection: AIConnection) throws -> (model: AIModelRecord, replaces: CapabilityDefault?)? {
        guard let m = try models(connection: connection.id, capability: .llm).first else { return nil }
        let cur = try capabilityDefault(.llm)
        if cur?.connectionId == connection.id && cur?.modelId == m.modelId { return nil }
        return (m, cur)
    }
}

// MARK: Export / import of non-secret settings

public struct GatewayConfigExport: Codable, Sendable {
    public struct Conn: Codable, Sendable { public var providerId: String, name: String; public var baseURL: String?; public var enabled: Bool }
    public struct Mod: Codable, Sendable { public var providerId: String, connection: String, modelId: String, displayName: String, capability: Capability; public var inputPricePerM: Double?, outputPricePerM: Double? }
    public struct Def: Codable, Sendable { public var capability: Capability, providerId: String, connection: String, modelId: String }
    public struct Route: Codable, Sendable { public var task: String, inherit: Bool, manualBridge: Bool; public var providerId: String?, connection: String?, modelId: String?; public var maxRetries: Int; public var instruction: String?, temperature: Double?, maxTokens: Int?; public var timeoutSeconds: Int }
    public var version = 1
    public var connections: [Conn] = [], models: [Mod] = [], defaults: [Def] = [], routes: [Route] = []

    /// Contains no API keys, by construction: keys never leave the Keychain.
    public static func make(_ s: GatewayStore) throws -> GatewayConfigExport {
        let conns = try s.connections(); let byId = Dictionary(uniqueKeysWithValues: conns.map { ($0.id, $0) })
        var e = GatewayConfigExport()
        e.connections = conns.map { Conn(providerId: $0.providerId, name: $0.name, baseURL: $0.baseURL, enabled: $0.enabled) }
        e.models = try s.models().compactMap { m in byId[m.connectionId].map { Mod(providerId: $0.providerId, connection: $0.name, modelId: m.modelId, displayName: m.displayName, capability: m.capability, inputPricePerM: m.inputPricePerM, outputPricePerM: m.outputPricePerM) } }
        e.defaults = try s.capabilityDefaults().compactMap { d in byId[d.connectionId].map { Def(capability: d.capability, providerId: $0.providerId, connection: $0.name, modelId: d.modelId) } }
        e.routes = try s.routes().values.map { r in
            let c = r.connectionId.flatMap { byId[$0] }
            return Route(task: r.task, inherit: r.inherit, manualBridge: r.manualBridge, providerId: c?.providerId, connection: c?.name, modelId: r.modelId, maxRetries: r.maxRetries, instruction: r.instruction, temperature: r.temperature, maxTokens: r.maxTokens, timeoutSeconds: r.timeoutSeconds)
        }
        return e
    }

    /// Creates missing connections (without credentials) and applies defaults/routes. Returns the connections that still need a key.
    @discardableResult
    public func apply(to s: GatewayStore, secrets: SecretStore) throws -> [String] {
        var existing = try s.connections()
        var missing: [String] = []
        func find(_ p: String, _ n: String) -> AIConnection? { existing.first { $0.providerId == p && $0.name == n } }
        for c in connections where find(c.providerId, c.name) == nil {
            guard ProviderRegistry.spec(c.providerId)?.isImplemented == true else { continue }
            if let u = c.baseURL, ProviderRegistry.validateBaseURL(u) != nil { continue }
            let n = AIConnection(id: UUID(), providerId: c.providerId, name: c.name, baseURL: c.baseURL, enabled: c.enabled, status: .configured, lastCheckedAt: nil, createdAt: Date())
            try s.save(n); existing.append(n)
        }
        for c in existing where ProviderRegistry.spec(c.providerId)?.needsKey == true && ((try? secrets.read(c.keyAccount)) ?? nil) == nil { missing.append(c.name) }
        for m in models { if let c = find(m.providerId, m.connection) {
            try s.merge(discovered: [AIModelRecord(id: UUID(), connectionId: c.id, modelId: m.modelId, displayName: m.displayName, capability: m.capability, source: "imported", inputPricePerM: m.inputPricePerM, outputPricePerM: m.outputPricePerM, health: .untested, createdAt: Date())]) } }
        for d in defaults { if let c = find(d.providerId, d.connection) { try s.setDefault(d.capability, connection: c.id, model: d.modelId) } }
        for r in routes where WorkflowTask.find(r.task) != nil {
            var x = TaskRoute(task: r.task); x.inherit = r.inherit; x.manualBridge = r.manualBridge; x.modelId = r.modelId
            x.connectionId = (r.providerId != nil && r.connection != nil) ? find(r.providerId!, r.connection!)?.id : nil
            x.maxRetries = min(3, max(0, r.maxRetries)); x.instruction = r.instruction; x.temperature = r.temperature; x.maxTokens = r.maxTokens; x.timeoutSeconds = r.timeoutSeconds
            try s.save(x)
        }
        return Array(Set(missing)).sorted()
    }
}

// MARK: Bridge to the existing request packages

public extension DirectAIService {
    /// Routes a prepared batch through the gateway (task routing, retries, fallback, usage tracking) and imports the reply exactly like a pasted one.
    @discardableResult
    func send(batchId: UUID, via gateway: AIGateway) async throws -> AnyImportReport {
        let pkg = try ai.prepare(batchId: batchId)
        let (task, course) = try gatewayTask(batchId)
        let out = try await gateway.complete(task: task, prompt: pkg.singlePrompt, courseId: course)
        try ai.markExported(batchId: batchId, method: .api)
        return try ai.importAny(out.text, targetBatchId: batchId)
    }

    /// The model this batch would be sent to, or nil when the gateway has nothing for it (callers then fall back to the legacy direct path or the manual bridge).
    func gatewayTarget(batchId: UUID, via gateway: AIGateway) -> Target? {
        guard let (task, _) = try? gatewayTask(batchId) else { return nil }
        return (try? gateway.resolve(task))?.primary
    }

    private func gatewayTask(_ batchId: UUID) throws -> (WorkflowTask, UUID?) {
        let t: AITask? = try ai.db.read { db in
            guard let b = try AITaskBatch.fetchOne(db, key: batchId) else { return nil }
            return try AITask.fetchOne(db, key: b.taskId)
        }
        guard let t else { throw GatewayError.unavailable("That request no longer exists.") }
        return (WorkflowTask.forLegacy(t.kind), t.courseId)
    }
}

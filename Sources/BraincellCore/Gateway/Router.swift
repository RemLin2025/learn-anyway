import Foundation

/// Why a task resolved the way it did. `trace` is shown in the UI.
public struct Resolution: Sendable {
    public var primary: Target?
    public var fallback: Target?
    public var manual = false
    public var inherited = false
    public var trace: [String] = []
    /// Set when nothing can serve the task: an actionable sentence.
    public var problem: String?
    public init() {}
    public var isReady: Bool { manual || primary != nil }
}

/// Deterministic model selection:
/// 1. explicit task override → 2. capability default → 3. configured fallback → 4. unavailable (with an explanation).
/// A model is only ever offered for the capability it was registered for, so the LLM default can never serve image or speech tasks.
public struct ModelRouter: Sendable {
    let store: GatewayStore
    public init(store: GatewayStore) { self.store = store }

    func target(_ conn: UUID?, _ modelId: String?, cap: Capability, conns: [UUID: AIConnection], models: [AIModelRecord], why: inout [String], label: String) -> Target? {
        guard let conn, let modelId else { return nil }
        guard let c = conns[conn] else { why.append("\(label): provider no longer exists."); return nil }
        guard c.enabled, c.status != .invalidCredentials else { why.append("\(label): \(c.name) is \(c.enabled ? "rejecting its credentials" : "disabled")."); return nil }
        guard let spec = c.spec, spec.supports(cap) else { why.append("\(label): \(c.name) has no adapter for \(cap.label) in this build."); return nil }
        guard let m = models.first(where: { $0.connectionId == conn && $0.modelId == modelId && $0.capability == cap }) else {
            why.append("\(label): \(modelId) isn’t registered as a \(cap.label) model."); return nil
        }
        return Target(connection: c, model: m)
    }

    /// One read of everything routing needs, so resolving every task costs one pass instead of several queries each.
    struct Snapshot {
        let routes: [String: TaskRoute]; let conns: [UUID: AIConnection]; let models: [AIModelRecord]; let defaults: [Capability: CapabilityDefault]
    }
    func snapshot() throws -> Snapshot {
        Snapshot(routes: try store.routes(), conns: Dictionary(uniqueKeysWithValues: try store.connections().map { ($0.id, $0) }), models: try store.models(),
                 defaults: Dictionary(uniqueKeysWithValues: try store.capabilityDefaults().map { ($0.capability, $0) }))
    }
    public func resolveAll(_ tasks: [WorkflowTask] = WorkflowTask.all) throws -> [String: Resolution] {
        let snap = try snapshot()
        return Dictionary(uniqueKeysWithValues: tasks.map { ($0.id, resolve($0, snap)) })
    }
    public func resolve(_ task: WorkflowTask) throws -> Resolution { resolve(task, try snapshot()) }

    func resolve(_ task: WorkflowTask, _ snap: Snapshot) -> Resolution {
        let route = snap.routes[task.id] ?? TaskRoute(task: task.id)
        let conns = snap.conns
        let models = snap.models.filter { $0.capability == task.capability }
        var r = Resolution()
        if route.manualBridge {
            r.manual = true; r.trace.append("Uses the manual ChatGPT Bridge: you copy the request into ChatGPT and import the reply.")
            return r
        }
        var why: [String] = []
        if !route.inherit, let t = target(route.connectionId, route.modelId, cap: task.capability, conns: conns, models: models, why: &why, label: "Task override") {
            r.primary = t; r.trace.append("Using this task’s own setting: \(t.label).")
        } else {
            r.trace += why; why = []
            if !route.inherit { r.trace.append("Own setting unusable; falling back to the default.") }
            if let d = snap.defaults[task.capability],
               let t = target(d.connectionId, d.modelId, cap: task.capability, conns: conns, models: models, why: &why, label: "\(task.capability.label) default") {
                r.primary = t; r.inherited = true; r.trace.append("Following the \(task.capability.label) default: \(t.label).")
            } else { r.trace += why }
        }
        if let f = target(route.fallbackConnectionId, route.fallbackModelId, cap: task.capability, conns: conns, models: models, why: &why, label: "Fallback"), f != r.primary {
            r.fallback = f; r.trace.append("Fallback if that fails: \(f.label).")
        } else { r.trace += why }
        if r.primary == nil, let f = r.fallback { r.primary = f; r.fallback = nil; r.trace.append("No primary model, so the fallback is used directly.") }
        if r.primary == nil {
            let anyConn = !conns.isEmpty
            r.problem = anyConn
                ? "\(task.title) has no usable \(task.capability.label) model. Open Model Services → \(task.capability.label) and choose one."
                : "No AI provider is connected. Open AI Provider Plans or Model Services to add one, or switch this task to the manual ChatGPT Bridge."
        }
        return r
    }
}

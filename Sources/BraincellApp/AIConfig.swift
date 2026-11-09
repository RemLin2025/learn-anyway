import SwiftUI
import BraincellCore

/// UI-facing state for the AI settings screens. All logic lives in BraincellCore's AIGateway; this only holds published copies and runs async actions.
@MainActor
final class AIConfig: ObservableObject {
    let gw: AIGateway
    @Published private(set) var connections: [AIConnection] = []
    @Published private(set) var models: [AIModelRecord] = []
    @Published private(set) var defaults: [Capability: CapabilityDefault] = [:]
    @Published private(set) var routes: [String: TaskRoute] = [:]
    /// Every task's resolved model, computed from one database read per reload (never per render).
    @Published private(set) var resolutions: [String: Resolution] = [:]
    @Published var busy: Set<String> = []
    @Published var message: String?
    @Published var error: String?
    /// Increments on every change so charts and tables reload.
    @Published private(set) var rev = 0

    init(gateway: AIGateway) { gw = gateway; reload() }

    func reload() {
        connections = (try? gw.store.connections()) ?? []
        models = (try? gw.store.models()) ?? []
        defaults = Dictionary(uniqueKeysWithValues: ((try? gw.store.capabilityDefaults()) ?? []).map { ($0.capability, $0) })
        routes = (try? gw.store.routes()) ?? [:]
        resolutions = (try? gw.resolveAll()) ?? [:]
        rev += 1
    }

    func connections(for provider: String) -> [AIConnection] { connections.filter { $0.providerId == provider } }
    func models(_ c: AIConnection, _ cap: Capability? = nil) -> [AIModelRecord] { models.filter { $0.connectionId == c.id && (cap == nil || $0.capability == cap) } }
    func connection(_ id: UUID?) -> AIConnection? { connections.first { $0.id == id } }
    func resolution(_ t: WorkflowTask) -> Resolution { resolutions[t.id] ?? Resolution() }

    /// Per-capability readiness for the overview strip: ready only when a usable default exists AND an adapter is implemented.
    func readiness(_ c: Capability) -> (label: String, ok: Bool) {
        if let d = defaults[c], let conn = connection(d.connectionId), conn.enabled, conn.spec?.supports(c) == true, conn.status != .invalidCredentials { return ("Ready", true) }
        if ProviderRegistry.all.contains(where: { $0.supports(c) }) { return connections.contains { $0.spec?.supports(c) == true } ? ("No default model", false) : ("Not configured", false) }
        return ("Not available yet", false)
    }

    func run(_ key: String, _ work: @escaping () async throws -> String?) {
        busy.insert(key); error = nil
        Task {
            do { message = try await work() } catch { self.error = error.localizedDescription }
            busy.remove(key); reload()
        }
    }

    func connect(provider: String, name: String?, baseURL: String?, key: String, done: @escaping () -> Void = {}) {
        run("connect-\(provider)") { [gw] in
            let (c, n) = try await gw.connect(providerId: provider, name: name, baseURL: baseURL, apiKey: key)
            done()
            return "Connected \(c.name): key verified, \(n) model(s) found. Nothing was spent."
        }
    }
    func refresh(_ c: AIConnection) { run("refresh-\(c.id)") { [gw] in "Found \(try await gw.refreshModels(c)) model(s)." } }
    func test(_ t: Target) {
        run("test-\(t.model.id)") { [gw] in
            switch await gw.test(t) { case .success(let s): return "\(t.model.displayName) works (replied “\(s.prefix(40))”)."; case .failure(let e): throw e }
        }
    }
    func setDefault(_ c: Capability, _ conn: AIConnection, _ model: String) { try? gw.store.setDefault(c, connection: conn.id, model: model); reload() }
    func disconnect(_ c: AIConnection) { do { try gw.disconnect(c) } catch { self.error = error.localizedDescription }; reload() }
    func setEnabled(_ c: AIConnection, _ on: Bool) { try? gw.setEnabled(c, on); reload() }
    func addModel(_ c: AIConnection, id: String, cap: Capability = .llm, inPrice: Double?, outPrice: Double?) {
        let m = AIModelRecord(id: UUID(), connectionId: c.id, modelId: id, displayName: id, capability: cap, source: "manual", inputPricePerM: inPrice, outputPricePerM: outPrice, health: .untested, createdAt: Date())
        try? gw.store.save(m); reload()
    }
    func update(_ m: AIModelRecord) { try? gw.store.save(m); reload() }
    func remove(_ m: AIModelRecord) {
        if let d = defaults[m.capability], d.connectionId == m.connectionId, d.modelId == m.modelId { try? gw.store.clearDefault(m.capability) }
        try? gw.store.removeModel(m.id); reload()
    }
    func save(_ r: TaskRoute) { try? gw.store.save(r); reload() }
    func reset(_ task: String) { try? gw.store.resetRoute(task); reload() }
    func route(_ t: WorkflowTask) -> TaskRoute { routes[t.id] ?? TaskRoute(task: t.id) }
    func usedByRoutes(_ c: AIConnection) -> Int { routes.values.filter { $0.connectionId == c.id && !$0.inherit }.count + defaults.values.filter { $0.connectionId == c.id }.count }
}

extension ConnectionStatus {
    var color: Color {
        switch self { case .ready: Theme.mastery; case .configured: Theme.attention; case .invalidCredentials: Theme.error; case .unavailable: Theme.error; case .disabled: Theme.textSecondary }
    }
}

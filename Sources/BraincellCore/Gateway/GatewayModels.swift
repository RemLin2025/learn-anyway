import Foundation
import GRDB

public struct AIConnection: Codable, Identifiable, Hashable, Sendable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "ai_connections"
    public var id: UUID
    public var providerId: String
    public var name: String
    public var baseURL: String?
    public var enabled: Bool
    public var status: ConnectionStatus
    public var lastCheckedAt: Date?
    public var createdAt: Date
    public init(id: UUID = UUID(), providerId: String, name: String, baseURL: String? = nil, enabled: Bool = true, status: ConnectionStatus = .configured, lastCheckedAt: Date? = nil, createdAt: Date = Date()) {
        self.id = id; self.providerId = providerId; self.name = name; self.baseURL = baseURL; self.enabled = enabled; self.status = status; self.lastCheckedAt = lastCheckedAt; self.createdAt = createdAt
    }
    /// Keychain account for this connection’s key. Stable, derived from the id; the key itself is never in the database.
    public var keyAccount: String { "ai-conn-\(id.uuidString)" }
    public var spec: ProviderSpec? { ProviderRegistry.spec(providerId) }
    public var effectiveBaseURL: String { (baseURL?.isEmpty == false ? baseURL : nil) ?? spec?.baseURL ?? "" }
}

public enum ModelHealth: String, Codable, Sendable { case untested, ready, failed }

public struct AIModelRecord: Codable, Identifiable, Hashable, Sendable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "ai_models"
    public var id: UUID
    public var connectionId: UUID
    public var modelId: String
    public var displayName: String
    public var capability: Capability
    public var source: String
    public var inputPricePerM: Double?
    public var outputPricePerM: Double?
    public var health: ModelHealth
    public var createdAt: Date
    public init(id: UUID = UUID(), connectionId: UUID, modelId: String, displayName: String, capability: Capability, source: String, inputPricePerM: Double? = nil, outputPricePerM: Double? = nil, health: ModelHealth = .untested, createdAt: Date = Date()) {
        self.id = id; self.connectionId = connectionId; self.modelId = modelId; self.displayName = displayName; self.capability = capability; self.source = source
        self.inputPricePerM = inputPricePerM; self.outputPricePerM = outputPricePerM; self.health = health; self.createdAt = createdAt
    }
}

public struct CapabilityDefault: Codable, Hashable, Sendable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "ai_capability_defaults"
    public var capability: Capability
    public var connectionId: UUID
    public var modelId: String
    public init(capability: Capability, connectionId: UUID, modelId: String) { self.capability = capability; self.connectionId = connectionId; self.modelId = modelId }
}

public struct TaskRoute: Codable, Hashable, Sendable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "ai_task_routes"
    public var task: String
    public var inherit: Bool = true
    public var connectionId: UUID?
    public var modelId: String?
    public var fallbackConnectionId: UUID?
    public var fallbackModelId: String?
    public var maxRetries: Int = 1
    public var manualBridge: Bool = false
    public var instruction: String?
    public var temperature: Double?
    public var maxTokens: Int?
    public var timeoutSeconds: Int = 120
    public var updatedAt: Date = Date()
    public init(task: String) { self.task = task }
}

public struct AIRequestRecord: Codable, Identifiable, Hashable, Sendable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "ai_requests"
    public var id: UUID
    public var ts: Date
    public var connectionId: UUID?
    public var providerId: String
    public var modelId: String
    public var capability: Capability
    public var task: String
    public var courseId: UUID?
    public var status: String
    public var latencyMs: Int
    public var inputTokens: Int?
    public var outputTokens: Int?
    public var cachedTokens: Int?
    public var costMicros: Int64?
    public var costBasis: String
    public var errorCategory: String?
    public init(id: UUID = UUID(), ts: Date, connectionId: UUID?, providerId: String, modelId: String, capability: Capability, task: String, courseId: UUID?, status: String, latencyMs: Int,
                inputTokens: Int?, outputTokens: Int?, cachedTokens: Int?, costMicros: Int64?, costBasis: String, errorCategory: String?) {
        self.id = id; self.ts = ts; self.connectionId = connectionId; self.providerId = providerId; self.modelId = modelId; self.capability = capability; self.task = task; self.courseId = courseId
        self.status = status; self.latencyMs = latencyMs; self.inputTokens = inputTokens; self.outputTokens = outputTokens; self.cachedTokens = cachedTokens; self.costMicros = costMicros
        self.costBasis = costBasis; self.errorCategory = errorCategory
    }
}

public struct LayoutPoint: Codable, Hashable, Sendable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "ai_workflow_layout"
    public var task: String; public var x: Double; public var y: Double
    public init(task: String, x: Double, y: Double) { self.task = task; self.x = x; self.y = y }
}

/// A concrete connection + model pair a request can be sent to.
public struct Target: Hashable, Sendable {
    public let connection: AIConnection
    public let model: AIModelRecord
    public init(connection: AIConnection, model: AIModelRecord) { self.connection = connection; self.model = model }
    public var label: String { "\(model.displayName) · \(connection.name)" }
}

/// CRUD over the gateway tables. All non-secret configuration lives here.
public struct GatewayStore: Sendable {
    public let db: AppDatabase
    public init(db: AppDatabase) { self.db = db }

    public func connections() throws -> [AIConnection] { try db.read { try AIConnection.order(Column("createdAt")).fetchAll($0) } }
    public func connection(_ id: UUID) throws -> AIConnection? { try db.read { try AIConnection.fetchOne($0, key: id) } }
    public func save(_ c: AIConnection) throws { try db.write { try c.save($0) } }
    /// Removing a connection cascades to its models and defaults; task routes pointing at it fall back to inheriting.
    public func removeConnection(_ id: UUID) throws {
        try db.write {
            try $0.execute(sql: "UPDATE ai_task_routes SET inherit = 1, connectionId = NULL, modelId = NULL WHERE connectionId = ?", arguments: [id])
            _ = try AIConnection.deleteOne($0, key: id)
        }
    }

    public func models(connection: UUID? = nil, capability: Capability? = nil) throws -> [AIModelRecord] {
        try db.read {
            var r = AIModelRecord.all()
            if let connection { r = r.filter(Column("connectionId") == connection) }
            if let capability { r = r.filter(Column("capability") == capability.rawValue) }
            return try r.order(Column("displayName")).fetchAll($0)
        }
    }
    public func save(_ m: AIModelRecord) throws { try db.write { try m.save($0) } }
    public func removeModel(_ id: UUID) throws { try db.write { _ = try AIModelRecord.deleteOne($0, key: id) } }

    /// Inserts discovered models, keeping existing rows (and their health, prices and manual entries) untouched.
    public func merge(discovered: [AIModelRecord]) throws {
        try db.write { db in
            for m in discovered {
                let exists = try AIModelRecord.filter(Column("connectionId") == m.connectionId && Column("modelId") == m.modelId && Column("capability") == m.capability.rawValue).fetchOne(db)
                if var e = exists {
                    if e.inputPricePerM == nil, let p = m.inputPricePerM { e.inputPricePerM = p }
                    if e.outputPricePerM == nil, let p = m.outputPricePerM { e.outputPricePerM = p }
                    try e.save(db)
                } else { try m.insert(db) }
            }
        }
    }

    public func capabilityDefault(_ c: Capability) throws -> CapabilityDefault? { try db.read { try CapabilityDefault.fetchOne($0, key: c.rawValue) } }
    public func capabilityDefaults() throws -> [CapabilityDefault] { try db.read { try CapabilityDefault.fetchAll($0) } }
    public func setDefault(_ c: Capability, connection: UUID, model: String) throws {
        try db.write { try CapabilityDefault(capability: c, connectionId: connection, modelId: model).save($0) }
    }
    public func clearDefault(_ c: Capability) throws { try db.write { _ = try CapabilityDefault.deleteOne($0, key: c.rawValue) } }

    public func routes() throws -> [String: TaskRoute] { try db.read { Dictionary(uniqueKeysWithValues: try TaskRoute.fetchAll($0).map { ($0.task, $0) }) } }
    public func route(_ task: String) throws -> TaskRoute { try db.read { try TaskRoute.fetchOne($0, key: task) } ?? TaskRoute(task: task) }
    public func save(_ r: TaskRoute) throws { var r = r; r.updatedAt = Date(); try db.write { try r.save($0) } }
    public func resetRoute(_ task: String) throws { try db.write { _ = try TaskRoute.deleteOne($0, key: task) } }
    public func resetAllRoutes() throws { try db.write { _ = try TaskRoute.deleteAll($0) } }

    public func layout() throws -> [String: LayoutPoint] { try db.read { Dictionary(uniqueKeysWithValues: try LayoutPoint.fetchAll($0).map { ($0.task, $0) }) } }
    public func save(_ p: LayoutPoint) throws { try db.write { try p.save($0) } }
    public func resetLayout() throws { try db.write { _ = try LayoutPoint.deleteAll($0) } }
    /// Positions saved by the first workflow editor were absolute coordinates of a layout that no longer exists; drop them once.
    public func pruneLegacyLayout() throws { try db.write { try $0.execute(sql: "DELETE FROM ai_workflow_layout WHERE task NOT LIKE 'o:%'") } }

    public func record(_ r: AIRequestRecord) throws { try db.write { try r.insert($0) } }
}

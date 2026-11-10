import Foundation
import GRDB

public struct UsageRange: Sendable, Equatable {
    public var from: Date?; public var to: Date?
    public init(from: Date? = nil, to: Date? = nil) { self.from = from; self.to = to }
    public static func lastDays(_ n: Int, now: Date = Date()) -> UsageRange { UsageRange(from: Calendar.current.date(byAdding: .day, value: -(n - 1), to: Calendar.current.startOfDay(for: now))) }
    public static var all: UsageRange { UsageRange() }
}

public struct UsageTotals: Sendable, Equatable {
    public var requests = 0, succeeded = 0, failed = 0
    public var inputTokens = 0, outputTokens = 0, cachedTokens = 0
    /// Successful requests whose provider reported no token counts at all (shown as unknown, never as zero).
    public var unreportedTokenRequests = 0
    public var knownCostMicros: Int64 = 0
    public var unknownCostRequests = 0
    public var avgLatencyMs = 0
    public var totalTokens: Int { inputTokens + outputTokens }
    public var costIsComplete: Bool { unknownCostRequests == 0 }
    public init() {}
}
public struct UsageGroup: Identifiable, Sendable, Equatable {
    public var id: String { key }
    public var key: String; public var provider: String; public var model: String; public var capability: String
    public var requests = 0, tokens = 0, errors = 0
    public var knownCostMicros: Int64 = 0; public var unknownCost = 0
}
public struct DayUsage: Identifiable, Sendable, Equatable {
    public var id: Date { day }
    public var day: Date; public var requests = 0, tokens = 0; public var costMicros: Int64 = 0
}

/// Aggregates the request log. Only metadata is stored (no prompts, replies or source text), and manual ChatGPT Bridge work never appears here.
public struct UsageService: Sendable {
    let store: GatewayStore
    public init(store: GatewayStore) { self.store = store }

    public func requests(_ r: UsageRange = .all, capability: Capability? = nil, status: String? = nil) throws -> [AIRequestRecord] {
        try store.db.read { db in
            var q = AIRequestRecord.all()
            if let f = r.from { q = q.filter(Column("ts") >= f) }
            if let t = r.to { q = q.filter(Column("ts") <= t) }
            if let capability { q = q.filter(Column("capability") == capability.rawValue) }
            if let status { q = q.filter(Column("status") == status) }
            return try q.order(Column("ts").desc).fetchAll(db)
        }
    }

    public func totals(_ rows: [AIRequestRecord]) -> UsageTotals {
        var t = UsageTotals(); var lat = 0
        for r in rows {
            t.requests += 1; r.status == "success" ? (t.succeeded += 1) : (t.failed += 1)
            t.inputTokens += r.inputTokens ?? 0; t.outputTokens += r.outputTokens ?? 0; lat += r.latencyMs
            if let c = r.costMicros { t.knownCostMicros += c } else if r.status == "success" { t.unknownCostRequests += 1 }
        }
        t.avgLatencyMs = rows.isEmpty ? 0 : lat / rows.count
        return t
    }

    public func byDay(_ rows: [AIRequestRecord]) -> [DayUsage] {
        let cal = Calendar.current
        var m: [Date: DayUsage] = [:]
        for r in rows {
            let d = cal.startOfDay(for: r.ts)
            var x = m[d] ?? DayUsage(day: d)
            x.requests += 1; x.tokens += (r.inputTokens ?? 0) + (r.outputTokens ?? 0); x.costMicros += r.costMicros ?? 0
            m[d] = x
        }
        return m.values.sorted { $0.day < $1.day }
    }

    public enum GroupBy { case model, provider, capability }
    public func grouped(_ rows: [AIRequestRecord], by g: GroupBy) -> [UsageGroup] {
        var m: [String: UsageGroup] = [:]
        for r in rows {
            let key = g == .model ? "\(r.providerId)/\(r.modelId)/\(r.capability.rawValue)" : g == .provider ? r.providerId : r.capability.rawValue
            var x = m[key] ?? UsageGroup(key: key, provider: r.providerId, model: g == .model ? r.modelId : "", capability: g == .capability ? r.capability.label : r.capability.label)
            x.requests += 1; x.tokens += (r.inputTokens ?? 0) + (r.outputTokens ?? 0)
            if r.status != "success" { x.errors += 1 }
            if let c = r.costMicros { x.knownCostMicros += c } else if r.status == "success" { x.unknownCost += 1 }
            m[key] = x
        }
        return m.values.sorted { $0.requests > $1.requests }
    }

    // MARK: SQL aggregates (no request rows are loaded into memory)

    private static func whereClause(_ r: UsageRange, capability: Capability? = nil, status: String? = nil, provider: String? = nil, model: String? = nil) -> (String, StatementArguments) {
        var c: [String] = [], a: [DatabaseValueConvertible] = []
        if let f = r.from { c.append("ts >= ?"); a.append(f) }
        if let t = r.to { c.append("ts <= ?"); a.append(t) }
        if let capability { c.append("capability = ?"); a.append(capability.rawValue) }
        if let status { c.append(status == "failed" ? "status != 'success'" : "status = ?"); if status != "failed" { a.append(status) } }
        if let provider { c.append("providerId = ?"); a.append(provider) }
        if let model { c.append("modelId = ?"); a.append(model) }
        return (c.isEmpty ? "" : "WHERE " + c.joined(separator: " AND "), StatementArguments(a))
    }

    public func totals(_ r: UsageRange, capability: Capability? = nil, status: String? = nil, provider: String? = nil, model: String? = nil) throws -> UsageTotals {
        let (w, args) = Self.whereClause(r, capability: capability, status: status, provider: provider, model: model)
        return try store.db.read { db in
            let row = try Row.fetchOne(db, sql: """
                SELECT COUNT(*) n, COALESCE(SUM(status = 'success'),0) ok, COALESCE(SUM(inputTokens),0) i, COALESCE(SUM(outputTokens),0) o, COALESCE(SUM(cachedTokens),0) c,
                       COALESCE(SUM(costMicros),0) cost, COALESCE(SUM(status = 'success' AND costMicros IS NULL),0) unk,
                       COALESCE(SUM(status = 'success' AND inputTokens IS NULL AND outputTokens IS NULL),0) nt, COALESCE(CAST(AVG(latencyMs) AS INTEGER),0) lat
                FROM ai_requests \(w)
                """, arguments: args)!
            var t = UsageTotals()
            t.requests = row["n"]; t.succeeded = row["ok"]; t.failed = t.requests - t.succeeded
            t.inputTokens = row["i"]; t.outputTokens = row["o"]; t.cachedTokens = row["c"]
            t.knownCostMicros = row["cost"]; t.unknownCostRequests = row["unk"]; t.unreportedTokenRequests = row["nt"]; t.avgLatencyMs = row["lat"]
            return t
        }
    }

    public enum Dimension: String, Sendable { case provider = "providerId", model = "modelId", task = "task" }
    public struct Slice: Identifiable, Sendable, Equatable { public var id: String { key }; public var key: String; public var requests = 0, tokens = 0, errors = 0 }

    /// Top slices by request count along one dimension, aggregated in SQL.
    public func slices(_ r: UsageRange, by d: Dimension, limit: Int = 8) throws -> [Slice] {
        let (w, args) = Self.whereClause(r)
        return try store.db.read { db in
            try Row.fetchAll(db, sql: "SELECT \(d.rawValue) k, COUNT(*) n, COALESCE(SUM(COALESCE(inputTokens,0)+COALESCE(outputTokens,0)),0) t, COALESCE(SUM(status != 'success'),0) e FROM ai_requests \(w) GROUP BY k ORDER BY n DESC LIMIT \(limit)", arguments: args)
                .map { Slice(key: $0["k"], requests: $0["n"], tokens: $0["t"], errors: $0["e"]) }
        }
    }

    /// Newest-first page of the request log with filters applied in SQL.
    public func page(_ r: UsageRange, capability: Capability? = nil, status: String? = nil, provider: String? = nil, model: String? = nil, limit: Int = 300) throws -> [AIRequestRecord] {
        let (w, args) = Self.whereClause(r, capability: capability, status: status, provider: provider, model: model)
        return try store.db.read { try AIRequestRecord.fetchAll($0, sql: "SELECT * FROM ai_requests \(w) ORDER BY ts DESC LIMIT \(limit)", arguments: args) }
    }

    public func distinctValues(_ column: Dimension) throws -> [String] {
        try store.db.read { try String.fetchAll($0, sql: "SELECT DISTINCT \(column.rawValue) FROM ai_requests ORDER BY 1") }
    }

    public func dailyTotals(_ r: UsageRange) throws -> [DayUsage] {
        let (w, args) = Self.whereClause(r)
        return try store.db.read { db in
            let cal = Calendar.current, f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; f.calendar = cal
            return try Row.fetchAll(db, sql: "SELECT strftime('%Y-%m-%d', ts, 'localtime') d, COUNT(*) n, COALESCE(SUM(COALESCE(inputTokens,0)+COALESCE(outputTokens,0)),0) t, COALESCE(SUM(costMicros),0) c FROM ai_requests \(w) GROUP BY d ORDER BY d", arguments: args)
                .compactMap { row in f.date(from: row["d"] as String).map { DayUsage(day: $0, requests: row["n"], tokens: row["t"], costMicros: row["c"]) } }
        }
    }

    public func spend(since: Date) throws -> Double { Double(try store.db.read { try Int64.fetchOne($0, sql: "SELECT COALESCE(SUM(costMicros),0) FROM ai_requests WHERE ts >= ?", arguments: [since]) ?? 0 }) / 1_000_000 }
    public func requestCount(since: Date) throws -> Int { try store.db.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM ai_requests WHERE ts >= ? AND status != 'blocked'", arguments: [since]) ?? 0 } }

    // MARK: CSV (contains no prompts, replies or keys)

    static func esc(_ s: String) -> String { s.contains(where: { ",\"\n".contains($0) }) ? "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\"" : s }
    public func historyCSV(_ rows: [AIRequestRecord]) -> String {
        let f = ISO8601DateFormatter()
        var out = "timestamp,task,provider,model,capability,status,latency_ms,input_tokens,output_tokens,cost_usd,cost_basis,error\n"
        for r in rows {
            let cost = r.costMicros.map { String(format: "%.6f", Double($0) / 1_000_000) } ?? "unknown"
            out += [f.string(from: r.ts), r.task, r.providerId, r.modelId, r.capability.rawValue, r.status, String(r.latencyMs),
                    r.inputTokens.map(String.init) ?? "", r.outputTokens.map(String.init) ?? "", cost, r.costBasis, r.errorCategory ?? ""].map(Self.esc).joined(separator: ",") + "\n"
        }
        return out
    }
    public func summaryCSV(_ rows: [AIRequestRecord]) -> String {
        var out = "provider,model,capability,requests,tokens,known_cost_usd,requests_with_unknown_cost,errors\n"
        for g in grouped(rows, by: .model) {
            out += [g.provider, g.model, g.capability, String(g.requests), String(g.tokens), String(format: "%.6f", Double(g.knownCostMicros) / 1_000_000), String(g.unknownCost), String(g.errors)].map(Self.esc).joined(separator: ",") + "\n"
        }
        return out
    }
}

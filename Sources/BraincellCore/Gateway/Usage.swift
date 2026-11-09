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
    public var inputTokens = 0, outputTokens = 0
    public var knownCostMicros: Int64 = 0
    public var unknownCostRequests = 0
    public var avgLatencyMs = 0
    public var totalTokens: Int { inputTokens + outputTokens }
    public var costIsComplete: Bool { unknownCostRequests == 0 }
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

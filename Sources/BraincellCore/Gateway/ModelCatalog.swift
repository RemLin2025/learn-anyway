import Foundation

/// Parses and validates a user-typed price (USD per million tokens). Empty means "no override".
public enum PriceInput {
    public enum Failure: Error, Equatable, Sendable { case notANumber, negative, tooLarge }
    public static let maxPerMillion = 10_000.0
    public static func parse(_ text: String) -> Result<Double?, Failure> {
        let t = text.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "$", with: "").replacingOccurrences(of: ",", with: ".")
        if t.isEmpty { return .success(nil) }
        guard let v = Double(t), v.isFinite else { return .failure(.notANumber) }
        if v < 0 { return .failure(.negative) }
        if v > maxPerMillion { return .failure(.tooLarge) }
        return .success(v)
    }
    public static func message(_ f: Failure) -> String {
        switch f { case .notANumber: "Enter a number such as 3.00."; case .negative: "A price can’t be negative."; case .tooLarge: "That’s above $10,000 per million tokens, so it’s probably a typo." }
    }
    public static func format(_ v: Double?) -> String {
        guard let v else { return "Unknown" }
        return v == 0 ? "Free" : v < 0.01 ? String(format: "$%.4f", v) : String(format: "$%.2f", v)
    }
}

/// One precomputed row of the model table. Everything the view needs is a plain value, so scrolling does no work.
public struct ModelRow: Identifiable, Hashable, Sendable {
    public let id: UUID
    public let name: String
    public let modelId: String
    public let provider: String
    public let capability: Capability
    public let health: ModelHealth
    public let input: Double?, output: Double?
    public let custom: Bool
    public let assignments: Int
    public let isDefault: Bool
    public let favorite: Bool
    public var free: Bool { input == 0 && output == 0 }
    public var priced: Bool { input != nil && output != nil }
    public init(id: UUID, name: String, modelId: String, provider: String, capability: Capability, health: ModelHealth, input: Double?, output: Double?, custom: Bool, assignments: Int, isDefault: Bool, favorite: Bool) {
        self.id = id; self.name = name; self.modelId = modelId; self.provider = provider; self.capability = capability; self.health = health
        self.input = input; self.output = output; self.custom = custom; self.assignments = assignments; self.isDefault = isDefault; self.favorite = favorite
    }
}

public struct ModelQuery: Equatable, Sendable {
    public enum Scope: String, CaseIterable, Sendable { case all = "All models", assigned = "Assigned", favorites = "Favorites", verified = "Verified", free = "Free", unpriced = "No price" }
    public enum Sort: String, CaseIterable, Sendable { case name = "Name", input = "Input price", output = "Output price" }
    public var text = ""
    public var scope = Scope.all
    public var sort = Sort.name
    public var ascending = true
    public init() {}
}

public enum ModelCatalog {
    /// Pure and thread-safe: the view runs this off the main actor, debounced and cancellable.
    public static func filter(_ rows: [ModelRow], _ q: ModelQuery) -> [ModelRow] {
        let terms = q.text.lowercased().split(separator: " ").map(String.init)
        var out = rows.filter { r in
            switch q.scope {
            case .all: break
            case .assigned: if r.assignments == 0 && !r.isDefault { return false }
            case .favorites: if !r.favorite { return false }
            case .verified: if r.health != .ready { return false }
            case .free: if !r.free { return false }
            case .unpriced: if r.priced { return false }
            }
            if terms.isEmpty { return true }
            let hay = (r.name + " " + r.modelId + " " + r.provider).lowercased()
            return terms.allSatisfy { hay.contains($0) }
        }
        func key(_ r: ModelRow) -> Double? { q.sort == .input ? r.input : q.sort == .output ? r.output : nil }
        out.sort { a, b in
            if q.sort == .name { let c = a.name.localizedCaseInsensitiveCompare(b.name); return q.ascending ? c == .orderedAscending : c == .orderedDescending }
            switch (key(a), key(b)) {            // unknown prices always sort last
            case let (x?, y?): return x == y ? a.name < b.name : (q.ascending ? x < y : x > y)
            case (nil, _?): return false
            case (_?, nil): return true
            default: return a.name < b.name
            }
        }
        return out
    }
}

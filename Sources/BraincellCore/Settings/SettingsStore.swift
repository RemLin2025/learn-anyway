import Foundation
import GRDB

public enum SettingKey: String, Sendable {
    case appearance          // system | light | dark
    case onboardingDismissed // true | false
    case codeFontSize        // points, 10...24
    case coachEnabled        // true | false (default true)
    case confidencePrompts   // minimal (default) | off
    case focusMinutes        // default 25
    case shortBreakMinutes   // default 5
    case longBreakMinutes    // default 15
    case notifyOnFocusEnd    // true | false (default false)
    case showMenuBarTimer    // true | false (default false)
    case codeExecutionEnabled // true once the learner opts in to sandboxed code execution
    case directAPIEnabled    // true once the learner opts in to sending requests straight to the Anthropic API
    case directAPIModel      // model id used for direct requests
    case budgetDaily         // USD, empty = none
    case budgetMonthly
    case budgetPerRequest    // warn above this estimated cost
    case budgetWarnPercent   // default 80
    case budgetMaxRequestsPerDay // hard app-level request cap
    case budgetEnforce       // true = block requests once a daily/monthly budget is spent
    case viewedProgress      // true once the learner has opened Skills or Insights
}

public enum AppearanceSetting: String, Sendable, CaseIterable {
    case system, light, dark
}

/// Key/value settings persisted in SQLite. Contains no secrets (Keychain is reserved for those).
public struct SettingsStore: Sendable {
    let db: AppDatabase
    public init(db: AppDatabase) { self.db = db }

    public func string(_ key: SettingKey) throws -> String? {
        try db.read { try String.fetchOne($0, sql: "SELECT value FROM settings WHERE key = ?", arguments: [key.rawValue]) }
    }

    public func set(_ key: SettingKey, _ value: String) throws {
        try db.write {
            try $0.execute(sql: """
                INSERT INTO settings (key, value, updatedAt) VALUES (?, ?, ?)
                ON CONFLICT(key) DO UPDATE SET value = excluded.value, updatedAt = excluded.updatedAt
                """, arguments: [key.rawValue, value, Date()])
        }
    }

    public func bool(_ key: SettingKey, default d: Bool = false) throws -> Bool {
        try string(key).map { $0 == "true" } ?? d
    }

    public func set(_ key: SettingKey, _ value: Bool) throws { try set(key, value ? "true" : "false") }

    public func int(_ key: SettingKey, default d: Int) throws -> Int { try string(key).flatMap(Int.init) ?? d }

    public func appearance() throws -> AppearanceSetting {
        try string(.appearance).flatMap(AppearanceSetting.init(rawValue:)) ?? .system
    }
}

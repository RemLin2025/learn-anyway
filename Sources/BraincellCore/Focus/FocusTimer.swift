import Foundation
import GRDB

public enum FocusKind: String, Codable, Sendable, DatabaseValueConvertible, CaseIterable {
    case work, shortBreak, longBreak
    public var label: String { switch self { case .work: "Focus"; case .shortBreak: "Short break"; case .longBreak: "Long break" } }
}

/// Pure timer state. It trusts wall-clock deltas, not tick counts, so a throttled or delayed timer stays accurate.
///
/// Deliberate policy: time while the app is merely in the background still counts as active focus (the learner may be
/// working in another window); time the Mac spends **asleep** counts as paused, never as focus.
public struct FocusTimer: Sendable, Equatable {
    public enum Phase: Sendable, Equatable { case running, paused, finished, stopped }

    public let kind: FocusKind
    public let plannedSeconds: Double
    public private(set) var phase: Phase
    public private(set) var activeSeconds: Double = 0
    public private(set) var pausedSeconds: Double = 0
    public private(set) var startedAt: Date
    private var lastTick: Date
    private var asleep = false

    public init(kind: FocusKind, plannedSeconds: Double, now: Date) {
        self.kind = kind; self.plannedSeconds = max(1, plannedSeconds); phase = .running; startedAt = now; lastTick = now
    }

    public var remainingSeconds: Double { max(0, plannedSeconds - activeSeconds) }
    public var isActive: Bool { phase == .running || phase == .paused }

    /// Advance to `now`. Running time counts as active; paused (or asleep) time counts as paused.
    public mutating func tick(_ now: Date) {
        let delta = max(0, now.timeIntervalSince(lastTick)); lastTick = now
        switch phase {
        case .running where !asleep:
            activeSeconds += delta
            if activeSeconds >= plannedSeconds { activeSeconds = plannedSeconds; phase = .finished }
        case .running, .paused: pausedSeconds += delta
        case .finished, .stopped: break
        }
    }

    public mutating func pause(_ now: Date) { tick(now); if phase == .running { phase = .paused } }
    public mutating func resume(_ now: Date) { tick(now); if phase == .paused { phase = .running } }
    public mutating func stop(_ now: Date) { tick(now); if isActive { phase = .stopped } }

    /// The Mac is going to sleep: from here until `didWake`, time is not focus time.
    public mutating func willSleep(_ now: Date) { tick(now); asleep = true }
    public mutating func didWake(_ now: Date) { tick(now); asleep = false }
}

public struct FocusInterval: Codable, Sendable, Identifiable, Hashable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "focus_intervals"
    public var id: UUID
    public var kind: FocusKind
    public var plannedSeconds: Int
    public var activeSeconds: Int
    public var pausedSeconds: Int
    public var startedAt: Date
    public var updatedAt: Date
    public var endedAt: Date?
    public var endState: String?
    public var sessionId: UUID?
    public var courseId: UUID?
}

public struct FocusSettings: Sendable, Equatable {
    public var focusMinutes = 25
    public var shortBreakMinutes = 5
    public var longBreakMinutes = 15
    /// A long break follows every Nth completed focus interval.
    public var longBreakEvery = 4
    public init() {}

    public static let presets = [15, 25, 45]

    public func seconds(_ k: FocusKind) -> Double {
        Double(max(1, min(240, k == .work ? focusMinutes : (k == .shortBreak ? shortBreakMinutes : longBreakMinutes)))) * 60
    }

    /// What to offer after an interval ends.
    public func next(after kind: FocusKind, completedFocusCount: Int) -> FocusKind {
        guard kind == .work else { return .work }
        return completedFocusCount > 0 && completedFocusCount % longBreakEvery == 0 ? .longBreak : .shortBreak
    }
}

/// Persists intervals. Focus time is *only* a record: it never creates evidence, XP or mastery.
public struct FocusService: Sendable {
    let db: AppDatabase
    public init(db: AppDatabase) { self.db = db }

    public func settings(_ store: SettingsStore) -> FocusSettings {
        var s = FocusSettings()
        s.focusMinutes = (try? store.int(.focusMinutes, default: 25)) ?? 25
        s.shortBreakMinutes = (try? store.int(.shortBreakMinutes, default: 5)) ?? 5
        s.longBreakMinutes = (try? store.int(.longBreakMinutes, default: 15)) ?? 15
        return s
    }

    @discardableResult
    public func begin(_ timer: FocusTimer, sessionId: UUID? = nil, courseId: UUID? = nil) throws -> FocusInterval {
        let i = FocusInterval(id: UUID(), kind: timer.kind, plannedSeconds: Int(timer.plannedSeconds), activeSeconds: 0, pausedSeconds: 0,
                              startedAt: timer.startedAt, updatedAt: timer.startedAt, endedAt: nil, endState: nil, sessionId: sessionId, courseId: courseId)
        try db.write { try i.insert($0) }
        return i
    }

    /// Heartbeat: keeps the stored active/paused time current so a crash loses seconds, not minutes.
    public func save(_ id: UUID, timer: FocusTimer, now: Date) throws {
        try db.write { d in
            guard var i = try FocusInterval.fetchOne(d, key: id), i.endedAt == nil else { return }
            i.activeSeconds = Int(timer.activeSeconds.rounded()); i.pausedSeconds = Int(timer.pausedSeconds.rounded()); i.updatedAt = now
            switch timer.phase {
            case .finished: i.endedAt = now; i.endState = "completed"
            case .stopped: i.endedAt = now; i.endState = "stopped"
            default: break
            }
            try i.update(d)
        }
    }

    /// An interval left open by a quit or crash is closed as interrupted at its last heartbeat. It is never resumed silently.
    @discardableResult
    public func recoverInterrupted() throws -> Int {
        try db.write { d in
            let open = try FocusInterval.filter(Column("endedAt") == nil).fetchAll(d)
            for var i in open { i.endedAt = i.updatedAt; i.endState = "interrupted"; try i.update(d) }
            return open.count
        }
    }

    public func intervals(since: Date? = nil, limit: Int = 200) throws -> [FocusInterval] {
        try db.read { d in
            var q = FocusInterval.order(Column("startedAt").desc).limit(limit)
            if let s = since { q = q.filter(Column("startedAt") >= s) }
            return try q.fetchAll(d)
        }
    }

    public func completedFocusCountToday(now: Date = Date(), calendar: Calendar = .current) throws -> Int {
        try db.read { try FocusInterval.filter(Column("kind") == FocusKind.work && Column("endState") == "completed" && Column("startedAt") >= calendar.startOfDay(for: now)).fetchCount($0) }
    }

    /// Total active focus (work intervals only) in the window.
    public func focusSeconds(since: Date) throws -> Int {
        try db.read { try Int.fetchOne($0, sql: "SELECT COALESCE(SUM(activeSeconds), 0) FROM focus_intervals WHERE kind = 'work' AND startedAt >= ?", arguments: [since]) ?? 0 }
    }
}

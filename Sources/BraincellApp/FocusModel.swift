import SwiftUI
import AppKit
import UserNotifications
import BraincellCore

/// Drives the Pomodoro timer. The state machine and persistence live in Core; this only ticks, listens for
/// sleep/wake, notifies (if the user opted in and macOS allows it) and surfaces the "interval ended" prompt.
@MainActor
final class FocusModel: ObservableObject {
    let app: AppModel
    @Published var timer: FocusTimer?
    @Published var settings = FocusSettings()
    @Published var completedToday = 0
    /// Set when an interval finishes; cleared when the learner chooses what to do next.
    @Published var endedKind: FocusKind?
    @Published var notifyOnEnd = false { didSet { if oldValue != notifyOnEnd { persistNotify() } } }
    @Published var showMenuBar = false { didSet { if oldValue != showMenuBar { try? app.settings?.set(.showMenuBarTimer, showMenuBar) } } }

    private var intervalId: UUID?
    private var ticker: Timer?
    private var lastSave = Date.distantPast
    private var observers: [NSObjectProtocol] = []

    init(app: AppModel) {
        self.app = app
        if let s = app.settings, let svc = svc {
            settings = svc.settings(s)
            notifyOnEnd = (try? s.bool(.notifyOnFocusEnd)) ?? false
            showMenuBar = (try? s.bool(.showMenuBarTimer)) ?? false
        }
        _ = try? svc?.recoverInterrupted()           // an interval left open by a quit/crash is closed, never silently resumed
        refreshCount()
        let ws = NSWorkspace.shared.notificationCenter
        observers.append(ws.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in MainActor.assumeIsolated { self?.mutate { $0.willSleep(Date()) } } })
        observers.append(ws.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in MainActor.assumeIsolated { self?.mutate { $0.didWake(Date()) }; self?.afterTick() } })
        observers.append(NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in MainActor.assumeIsolated { self?.persist(force: true) } })
    }

    private var svc: FocusService? { app.db.map { FocusService(db: $0) } }
    var isRunning: Bool { timer?.phase == .running }
    var isPaused: Bool { timer?.phase == .paused }
    var remainingText: String { timer.map { Self.clock($0.remainingSeconds) } ?? "" }

    static func clock(_ s: Double) -> String { let t = Int(s.rounded(.up)); return String(format: "%d:%02d", t / 60, t % 60) }

    // MARK: Controls

    func start(_ kind: FocusKind) {
        stopIfNeeded()
        endedKind = nil
        let t = FocusTimer(kind: kind, plannedSeconds: settings.seconds(kind), now: Date())
        timer = t
        let course = app.activeSessionID.flatMap { try? app.practice?.session($0).courseId } ?? nil
        intervalId = try? svc?.begin(t, sessionId: app.activeSessionID, courseId: course ?? nil).id
        startTicking()
    }

    func pause() { mutate { $0.pause(Date()) }; persist(force: true) }
    func resume() { mutate { $0.resume(Date()) }; persist(force: true) }
    func stop() { mutate { $0.stop(Date()) }; persist(force: true); finish(silently: true) }

    func dismissEnd() { endedKind = nil }

    /// "Take a break now" after a focus interval: pauses an open practice session (nothing is submitted or discarded).
    func takeBreak() {
        let next = settings.next(after: .work, completedFocusCount: completedToday)
        if let sid = app.activeSessionID { try? app.practice?.setStatus(sid, .paused) }
        start(next)
    }

    func saveSettings() {
        guard let s = app.settings else { return }
        try? s.set(.focusMinutes, String(settings.focusMinutes)); try? s.set(.shortBreakMinutes, String(settings.shortBreakMinutes)); try? s.set(.longBreakMinutes, String(settings.longBreakMinutes))
    }

    // MARK: Ticking

    private func startTicking() {
        ticker?.invalidate()
        ticker = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.mutate { $0.tick(Date()) }; self?.afterTick() } }
        RunLoop.main.add(ticker!, forMode: .common)
    }

    private func mutate(_ f: (inout FocusTimer) -> Void) { guard var t = timer else { return }; f(&t); timer = t }

    private func afterTick() {
        guard let t = timer else { return }
        if t.phase == .finished { persist(force: true); finish(silently: false) } else { persist(force: false) }
    }

    private func persist(force: Bool) {
        guard let t = timer, let id = intervalId, force || Date().timeIntervalSince(lastSave) >= 10 else { return }
        try? svc?.save(id, timer: t, now: Date()); lastSave = Date()
    }

    private func finish(silently: Bool) {
        let kind = timer?.kind
        ticker?.invalidate(); ticker = nil; timer = nil; intervalId = nil
        refreshCount()
        guard !silently, let kind else { return }
        endedKind = kind
        notifyIfAllowed(kind)
    }

    private func stopIfNeeded() { if timer?.isActive == true { stop() } }
    private func refreshCount() { completedToday = (try? svc?.completedFocusCountToday()) ?? 0 }

    // MARK: Notifications (opt-in, only if macOS authorises them)

    private func persistNotify() {
        try? app.settings?.set(.notifyOnFocusEnd, notifyOnEnd)
        guard notifyOnEnd, Bundle.main.bundleIdentifier != nil else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { [weak self] granted, _ in
            if !granted { DispatchQueue.main.async { self?.notifyOnEnd = false } }
        }
    }

    private func notifyIfAllowed(_ kind: FocusKind) {
        guard notifyOnEnd, Bundle.main.bundleIdentifier != nil else { return }
        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { s in
            guard s.authorizationStatus == .authorized else { return }
            let c = UNMutableNotificationContent()
            c.title = kind == .work ? "Focus interval finished" : "Break over"
            c.body = kind == .work ? "Finish your question, then take a break." : "Ready to focus again?"
            center.add(UNNotificationRequest(identifier: UUID().uuidString, content: c, trigger: nil))
        }
    }
}

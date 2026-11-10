import SwiftUI
import AppKit
import BraincellCore

/// Developer aid (BRAINCELL_BENCH + BRAINCELL_DATA_DIR): drives the AI Workflow canvas with synthetic mouse-drag events delivered to the
/// real window, and records how much CPU the app burns. Same code runs against any build, so before/after numbers are comparable.
enum Bench {
    static func cpuSeconds() -> Double {
        var u = rusage(); getrusage(RUSAGE_SELF, &u)
        return Double(u.ru_utime.tv_sec) + Double(u.ru_utime.tv_usec) / 1e6 + Double(u.ru_stime.tv_sec) + Double(u.ru_stime.tv_usec) / 1e6
    }

    /// Visual interactions (expand/collapse, drag, reset) must never change routing, and visual state must survive a restart.
    @MainActor static func persistenceCheck(_ model: AppModel, dir: URL) async {
        guard let gw = model.gateway, let cfg = model.aiConfig, ProcessInfo.processInfo.environment["BRAINCELL_DATA_DIR"] != nil else { return }
        let c = AIConnection(providerId: "openrouter", name: "OpenRouter", status: .ready)
        try? gw.store.save(c)
        for n in ["m1", "m2"] { try? gw.store.save(AIModelRecord(connectionId: c.id, modelId: n, displayName: n, capability: .llm, source: "manual")) }
        try? gw.store.setDefault(.llm, connection: c.id, model: "m1")
        var r = TaskRoute(task: "answerEvaluation"); r.inherit = false; r.connectionId = c.id; r.modelId = "m2"; try? gw.store.save(r)
        cfg.reload()
        func snap() -> [String] { WorkflowTask.all.map { "\($0.id)=\(cfg.resolution($0).primary?.model.modelId ?? "-")/\(cfg.routes[$0.id]?.inherit ?? true)" } }
        let before = snap()
        UserDefaults.standard.removeObject(forKey: "wf.expanded")
        var log = ""
        let a = WorkflowState(cfg: cfg)
        log += "fresh: expanded=\(a.expanded.count) nodes=\(a.layout.nodes.count)\n"
        a.toggle(.study); a.toggle(.core); a.commitDrag("quizGeneration", by: CGSize(width: 40, height: -25)); a.select("quizGeneration"); a.showDeps = true
        log += "after toggles+drag: expanded=\(a.expanded.map(\.rawValue).sorted()) nodes=\(a.layout.nodes.count)\n"
        a.setAll(false); a.setAll(true)
        let b = WorkflowState(cfg: cfg)            // a second instance reads what a persisted: the same path a relaunch takes
        let moved = b.layout.node("quizGeneration")!.rect, base = WorkflowCanvasLayout.make(expanded: b.expanded).node("quizGeneration")!.rect
        log += "reloaded: expanded=\(b.expanded.count) showDeps=\(b.showDeps) quizOffset=\(moved.minX - base.minX),\(moved.minY - base.minY)\n"
        let afterVisual = snap()
        log += "routing unchanged by expand/collapse/drag/select: \(before == afterVisual)\n"
        b.resetLayout()
        let reset = b.layout.node("quizGeneration")!.rect == WorkflowCanvasLayout.make(expanded: b.expanded).node("quizGeneration")!.rect
        log += "reset layout restores positions: \(reset); routing still unchanged: \(before == snap())\n"
        try? log.write(to: dir.appendingPathComponent("persist.txt"), atomically: true, encoding: .utf8)
    }

    @MainActor static func run(_ model: AppModel, dir: URL) async {
        if ProcessInfo.processInfo.environment["BRAINCELL_BENCH"] == "persist" { await persistenceCheck(model, dir: dir); return }
        guard let gw = model.gateway, ProcessInfo.processInfo.environment["BRAINCELL_DATA_DIR"] != nil else { return }
        let c = AIConnection(providerId: "openrouter", name: "OpenRouter", status: .ready, lastCheckedAt: Date())
        try? gw.store.save(c)
        for (i, n) in ["openai/gpt-4o-mini", "anthropic/claude-sonnet"].enumerated() {
            try? gw.store.save(AIModelRecord(connectionId: c.id, modelId: n, displayName: n, capability: .llm, source: "discovered", inputPricePerM: Double(i + 1), outputPricePerM: Double(i + 2)))
        }
        try? gw.store.setDefault(.llm, connection: c.id, model: "openai/gpt-4o-mini")
        model.aiConfig?.reload()
        UserDefaults.standard.set("AI Workflow", forKey: "settingsSection")
        UserDefaults.standard.set(["Core generation", "Study content", "Research & sources", "Multimedia", "Study experience"], forKey: "wf.expanded")   // worst case: every node visible
        UserDefaults.standard.removeObject(forKey: "wf.cam")
        model.snapshotOpenSettings = true
        try? await Task.sleep(nanoseconds: 2_500_000_000)
        guard let w = NSApp.windows.first(where: { $0.isVisible && ($0.title == "Settings" || $0.identifier?.rawValue.contains("Settings") == true || $0.title.contains("General")) }), let cv = w.contentView else { NSLog("bench: no settings window"); return }
        w.setContentSize(NSSize(width: 1180, height: 780))
        try? await Task.sleep(nanoseconds: 1_500_000_000)

        var out = "build: \(ProcessInfo.processInfo.environment["BRAINCELL_BENCH_LABEL"] ?? "?")\nwindow: \(Int(cv.bounds.width))x\(Int(cv.bounds.height))\n"
        // Idle: nothing is happening, so CPU should be ~0.
        let i0 = cpuSeconds(), t0 = Date()
        try? await Task.sleep(nanoseconds: 4_000_000_000)
        out += String(format: "idle: %.1f%% CPU over %.1f s\n", (cpuSeconds() - i0) / Date().timeIntervalSince(t0) * 100, Date().timeIntervalSince(t0))

        // Pan: press on empty canvas, drag in two circles (240 events at ~125 Hz), release.
        func point(_ x: CGFloat, _ yFromTop: CGFloat) -> NSPoint { cv.convert(NSPoint(x: x, y: cv.isFlipped ? yFromTop : cv.bounds.height - yFromTop), to: nil) }
        func ev(_ t: NSEvent.EventType, _ p: NSPoint, _ n: Int) -> NSEvent {
            NSEvent.mouseEvent(with: t, location: p, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: w.windowNumber, context: nil, eventNumber: n, clickCount: 1, pressure: 1)!
        }
        let cx: CGFloat = 300, cy: CGFloat = 215, r: CGFloat = 70
        w.sendEvent(ev(.leftMouseDown, point(cx + r, cy), 1))
        var handle: [Double] = []
        let c0 = cpuSeconds(), w0 = Date()
        let n = 270   // 2.25 turns, so the drag ends displaced from where it started and the pan is visible in the screenshot
        for i in 0..<n {
            let a = Double(i) / 120 * 2 * .pi
            let s = Date()
            w.sendEvent(ev(.leftMouseDragged, point(cx + r * CGFloat(cos(a)), cy + r * CGFloat(sin(a))), 2 + i))
            handle.append(Date().timeIntervalSince(s) * 1000)
            try? await Task.sleep(nanoseconds: 8_000_000)
        }
        let wall = Date().timeIntervalSince(w0), cpu = cpuSeconds() - c0
        if let rep = cv.bitmapImageRepForCachingDisplay(in: cv.bounds) { cv.cacheDisplay(in: cv.bounds, to: rep); try? rep.representation(using: .png, properties: [:])?.write(to: dir.appendingPathComponent("bench-after-drag.png")) }
        w.sendEvent(ev(.leftMouseUp, point(cx + r, cy), 300))
        handle.sort()
        out += String(format: "pan drag: %d events in %.2f s, CPU %.0f%% of one core (%.1f ms CPU per event)\n", n, wall, cpu / wall * 100, cpu / Double(n) * 1000)
        out += String(format: "event handling on main thread: mean %.2f ms, p95 %.2f ms, max %.2f ms\n", handle.reduce(0, +) / Double(n), handle[Int(Double(handle.count) * 0.95)], handle.last!)
        try? await Task.sleep(nanoseconds: 1_000_000_000)
        let i1 = cpuSeconds(), t1 = Date()
        try? await Task.sleep(nanoseconds: 3_000_000_000)
        out += String(format: "idle after interaction: %.1f%% CPU\n", (cpuSeconds() - i1) / Date().timeIntervalSince(t1) * 100)
        try? out.write(to: dir.appendingPathComponent("bench.txt"), atomically: true, encoding: .utf8)
    }
}

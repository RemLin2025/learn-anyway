import SwiftUI
import AppKit
import BraincellCore

/// Developer aid: with BRAINCELL_SNAPSHOT_DIR set, loads the demo workspace, walks the main screens and writes
/// PNGs of the app's own window (no screen-recording permission needed), then quits. Inert otherwise.
@MainActor
enum SnapshotRunner {
    static var dir: URL? { ProcessInfo.processInfo.environment["BRAINCELL_SNAPSHOT_DIR"].map { URL(fileURLWithPath: $0, isDirectory: true) } }
    static var isActive: Bool { dir != nil }

    static func run(_ model: AppModel) async {
        guard let dir else { return }
        NSLog("snapshot: starting, dir=%@", dir.path)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if ProcessInfo.processInfo.environment["BRAINCELL_AXONLY"] != nil {
            model.loadDemo()
            let r = await axAudit(model)
            try? r.joined(separator: "\n").write(to: dir.appendingPathComponent("ax-audit.txt"), atomically: true, encoding: .utf8)
            NSApp.terminate(nil); return
        }
        if ProcessInfo.processInfo.environment["BRAINCELL_SELFTEST"] != nil {
            model.loadDemo()
            await modelSelfTest(model, dir: dir)
            NSApp.terminate(nil); return
        }
        if ProcessInfo.processInfo.environment["BRAINCELL_SETTINGS_SNAP"] != nil { await settingsScenario(model, dir: dir); NSApp.terminate(nil); return }
        func shot(_ name: String) async {
            NSLog("snapshot: shot %@", name)
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            guard let v = NSApp.windows.first(where: { $0.isVisible && $0.contentView != nil })?.contentView,
                  let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) else { return }
            v.cacheDisplay(in: v.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: dir.appendingPathComponent("\(name).png"))
        }
        model.selection = .home
        await shot("01-home-empty")
        model.loadDemo()
        await shot("02-course-assessments")
        model.selection = .questionBank
        await shot("03-question-bank")
        model.selection = .aiTasks
        await shot("04-ai-tasks")
        if let c = model.courseList.first, let ids = try? model.practice?.questionIds(courseId: c.id), !ids.isEmpty {
            model.startPractice(questionIds: ids, title: "Demo practice", courseId: c.id)
            for (i, name) in [(0, "flashcard"), (1, "choice"), (4, "numeric"), (5, "tracing"), (6, "coding"), (7, "longform"), (8, "proof")] {
                model.snapshotIndex = i
                await shot("1\(i)-practice-\(name)")
                if i == 6 { await editorSelfTest(model, dir: dir) }
            }
        }
        await gradingScenario(model, shot: shot)
        await adaptiveScenario(model, shot: shot)
        await releaseScenario(model, dir: dir, shot: shot)
        NSApp.terminate(nil)
    }

    /// Screenshots of the four AI settings pages with synthetic data (never real keys). Only with BRAINCELL_SETTINGS_SNAP, and only against BRAINCELL_DATA_DIR.
    static func settingsScenario(_ model: AppModel, dir: URL) async {
        guard let gw = model.gateway, ProcessInfo.processInfo.environment["BRAINCELL_DATA_DIR"] != nil else { return }
        let c = AIConnection(providerId: "openrouter", name: "OpenRouter", status: .ready, lastCheckedAt: Date())
        try? gw.store.save(c)
        for (i, n) in ["openai/gpt-4o-mini", "anthropic/claude-sonnet", "deepseek/deepseek-chat"].enumerated() {
            try? gw.store.save(AIModelRecord(connectionId: c.id, modelId: n, displayName: n, capability: .llm, source: "discovered", inputPricePerM: Double(i + 1) * 0.5, outputPricePerM: Double(i + 1) * 2, health: i == 0 ? .ready : .untested))
        }
        try? gw.store.setDefault(.llm, connection: c.id, model: "openai/gpt-4o-mini")
        var r = TaskRoute(task: "answerEvaluation"); r.inherit = false; r.connectionId = c.id; r.modelId = "anthropic/claude-sonnet"; try? gw.store.save(r)
        var m = TaskRoute(task: "tutoring"); m.manualBridge = true; try? gw.store.save(m)
        for d in 0..<20 { for k in 0..<(1 + d % 4) {
            let t = Calendar.current.date(byAdding: .hour, value: -(d * 24 + k), to: Date())!
            try? gw.store.record(AIRequestRecord(id: UUID(), ts: t, connectionId: c.id, providerId: "openrouter", modelId: k % 2 == 0 ? "openai/gpt-4o-mini" : "deepseek/deepseek-chat", capability: .llm, task: k % 2 == 0 ? "quizGeneration" : "answerEvaluation", courseId: nil,
                status: d == 3 && k == 0 ? "failed" : "success", latencyMs: 900 + d * 40, inputTokens: 1800 + d * 90, outputTokens: 600 + k * 120, cachedTokens: nil, costMicros: k % 2 == 0 ? Int64(2400 + d * 100) : nil, costBasis: k % 2 == 0 ? "estimated" : "unknown", errorCategory: d == 3 && k == 0 ? "rate_limit" : nil))
        } }
        model.aiConfig?.reload()
        model.snapshotOpenSettings = true
        try? await Task.sleep(nanoseconds: 2_000_000_000)
        guard let w = NSApp.windows.first(where: { $0.isVisible && ($0.title == "Settings" || $0.identifier?.rawValue.contains("Settings") == true || $0.title.contains("General")) }) else { NSLog("snapshot: no settings window"); return }
        w.setContentSize(NSSize(width: 1180, height: 780))
        for (i, s) in SettingsSection.allCases.enumerated() {
            UserDefaults.standard.set(s.rawValue, forKey: "settingsSection")
            try? await Task.sleep(nanoseconds: 1_800_000_000)
            if i == 3 { try? await Task.sleep(nanoseconds: 800_000_000) }
            guard let v = w.contentView, let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) else { continue }
            v.cacheDisplay(in: v.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: dir.appendingPathComponent("s\(i)-\(s.rawValue.prefix(5)).png"))
        }
    }

    /// Submits and grades a mixed set of answers through the real services, then captures the M5 screens.
    static func gradingScenario(_ model: AppModel, shot: (String) async -> Void) async {
        guard let c = model.courseList.first, let p = model.practice, let ev = model.evaluation,
              let rows = try? model.questions?.list(QuestionFilter()) else { return }
        func qid(_ t: String) -> UUID? { rows.first { $0.title.hasPrefix(t) }?.id }
        func run(_ plan: [(String, (inout PracticeResponse) -> Void)], title: String, finish: Bool) -> UUID? {
            let ids = plan.compactMap { qid($0.0) }
            guard let s = try? p.start(questionIds: ids, title: title, courseId: c.id), let items = try? p.items(sessionId: s.id) else { return nil }
            for (i, step) in plan.enumerated() where i < items.count {
                var r = PracticeResponse(); step.1(&r)
                if let a = try? p.submit(itemId: items[i].id, response: r) { _ = try? ev.evaluate(attemptId: a.id) }
            }
            if finish { try? p.setStatus(s.id, .completed) } else { try? p.moveTo(sessionId: s.id, ordinal: 0) }
            return s.id
        }
        model.snapshotIndex = nil
        let mixed: [(String, (inout PracticeResponse) -> Void)] = [
            ("Recursive call count", { $0.text = "7" }),
            ("Which call removes", { $0.selected = ["b"] }),
            ("Name the interface", { $0.text = "Iterable" }),
            ("Explain fail-fast", { $0.text = "The iterator remembers modCount." }),
            ("What does Iterator.hasNext", { $0.revealed = true }),
            ("Prove the sum", { $0.text = "Base case: n=1. Step: $$n^2+(2n+1)=(n+1)^2$$" }),
        ]
        if let sid = run(mixed, title: "Demo session", finish: true) { model.activeSessionID = sid; await shot("20-summary"); model.activeSessionID = nil }
        let two: [(String, (inout PracticeResponse) -> Void)] = [("Recursive call count", { $0.text = "8" }), ("Explain fail-fast", { $0.text = "It throws when the list changes." })]
        if let sid = run(two, title: "Result panels", finish: false) {
            model.activeSessionID = sid; await shot("21-result-graded")
            model.snapshotIndex = 1; await shot("22-result-pending")
            model.activeSessionID = nil
        }
        model.selection = .skills; await shot("23-skills")
        if let pending = try? ev.pendingAttempts(courseId: c.id), !pending.isEmpty,
           (try? model.ai?.createGradingTask(courseId: c.id, attemptIds: pending.map(\.id))) != nil {
            model.reload(); model.selection = .aiTasks; await shot("24-ai-grading")
        }
    }

    /// Drives the real NSTextView on the coding question: Return auto-indent, typing, undo, and that the edit
    /// reaches the database through the debounced autosave. Results go to selftest.txt.
    static func editorSelfTest(_ model: AppModel, dir: URL) async {
        var log: [String] = []
        func find(_ v: NSView) -> NSTextView? { if let t = v as? NSTextView { return t }; for c in v.subviews { if let t = find(c) { return t } }; return nil }
        guard let root = NSApp.windows.first(where: { $0.isVisible })?.contentView, let tv = find(root) else { log.append("FAIL no text view"); try? log.joined(separator: "\n").write(to: dir.appendingPathComponent("selftest.txt"), atomically: true, encoding: .utf8); return }
        tv.window?.makeFirstResponder(tv)
        log.append("initial: \(tv.string.debugDescription)")
        tv.setSelectedRange(NSRange(location: ("def squares(n):" as NSString).length, length: 0))
        tv.doCommand(by: #selector(NSResponder.insertNewline(_:)))
        log.append("after Return: \(tv.string.debugDescription)  caret=\(tv.selectedRange().location)")
        log.append(tv.string.hasPrefix("def squares(n):\n    \n") ? "PASS auto-indent after colon" : "FAIL auto-indent")
        tv.insertText("return 1", replacementRange: tv.selectedRange())
        log.append("after typing: \(tv.string.debugDescription)")
        try? await Task.sleep(nanoseconds: 1_500_000_000)
        if let sid = model.activeSessionID, let svc = model.practice, let items = try? svc.items(sessionId: sid), items.count > 6,
           let spec = try? svc.spec(for: items[6]), let r = try? svc.response(for: items[6], spec: spec) {
            log.append(r.files.first?.content.contains("return 1") == true ? "PASS autosaved to database: \(r.files[0].content.debugDescription)" : "FAIL draft not saved: \(r.files.first?.content.debugDescription ?? "nil")")
            log.append("item status: \(items[6].status.rawValue)")
        } else { log.append("FAIL could not read draft") }
        let before = tv.string
        tv.undoManager?.undo()
        log.append(tv.string != before ? "PASS undo changed text -> \(tv.string.debugDescription)" : "FAIL undo had no effect")
        try? log.joined(separator: "\n").write(to: dir.appendingPathComponent("selftest.txt"), atomically: true, encoding: .utf8)
    }

    /// Captures the M6 screens: plan tab, Home suggestions, planned practice item and the coach banner.
    static func adaptiveScenario(_ model: AppModel, shot: (String) async -> Void) async {
        guard let c = model.courseList.first, let p = model.practice, let ev = model.evaluation,
              let rows = try? model.questions?.list(QuestionFilter()) else { return }
        func qid(_ t: String) -> UUID? { rows.first { $0.title.hasPrefix(t) }?.id }
        // A rated flashcard comes due (time is fast-forwarded in the database for the screenshot only).
        if let fc = qid("What does Iterator.hasNext"), let s = try? p.start(questionIds: [fc], title: "Card", courseId: c.id),
           let it = try? p.items(sessionId: s.id).first, var r = Optional(PracticeResponse()) {
            r.revealed = true
            if let a = try? p.submit(itemId: it.id, response: r) { _ = try? ev.evaluate(attemptId: a.id); _ = try? ev.selfReview(attemptId: a.id, score: 0.8, rating: "good") }
            try? p.setStatus(s.id, .completed)
            try? model.db?.write { try $0.execute(sql: "UPDATE review_states SET due = ?", arguments: [Date().addingTimeInterval(-60)]) }
        }
        model.reload(); model.selection = .home; await shot("30-home-adaptive")

        model.selectedCourseID = c.id; model.requestedCourseTab = "plan"; model.selection = .courses
        await shot("31-plan")

        let two: [String] = ["Which call removes", "Trace the iterator loop"]
        let ids = two.compactMap(qid)
        if let sid = (try? p.start(planned: ids.map { .init(questionId: $0, kind: $0 == ids.first ? .repair : .advance, reason: "“Java iterators”: your estimate is ≈ 43% (preliminary confidence). “Recursion” is a prerequisite that hasn’t been assessed.") },
                                 title: "Planned session", courseId: c.id, mode: .mastery))?.id, let items = try? p.items(sessionId: sid) {
            for (i, wrong) in ["a-wrong", "99"].enumerated() where i < items.count {
                var r = PracticeResponse()
                if i == 0 { r.selected = ["b"] } else { r.text = wrong }
                if let a = try? p.submit(itemId: items[i].id, response: r) { _ = try? ev.evaluate(attemptId: a.id) }
            }
            try? p.moveTo(sessionId: sid, ordinal: 0)
            model.activeSessionID = sid
            model.snapshotIndex = nil; model.snapshotIndex = 1
            await shot("32-practice-planned-coach")
            model.activeSessionID = nil
        }
    }

    /// M7 screens: Insights, skill map, light appearance, and an accessibility audit of the live accessibility tree.
    static func releaseScenario(_ model: AppModel, dir: URL, shot: (String) async -> Void) async {
        model.selection = .insights; await shot("40-insights")
        model.selection = .skills; model.snapshotMap = true; await shot("41-skill-map")
        model.setAppearance(.light)
        model.selection = .home; await shot("42-light-home")
        model.selection = .skills; await shot("43-light-skills-map")
        model.selection = .insights; await shot("44-light-insights")
        model.setAppearance(.dark)

        var report: [String] = []
        for item in SidebarItem.allCases {
            model.selection = item
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            guard let root = NSApp.windows.first(where: { $0.isVisible })?.contentView else { continue }
            var counts: [String: Int] = [:], unlabeled: [String] = []
            func walk(_ el: Any, _ depth: Int) {
                guard depth < 60 else { return }
                guard let a = el as? NSAccessibilityProtocol else { return }
                let role = a.accessibilityRole()?.rawValue ?? "none"
                counts[role, default: 0] += 1
                let controls: Set<String> = ["AXButton", "AXPopUpButton", "AXCheckBox", "AXRadioButton", "AXTextField", "AXSlider", "AXMenuButton", "AXStepper"]
                if controls.contains(role) {
                    let label = [a.accessibilityLabel(), a.accessibilityTitle(), a.accessibilityHelp(), (a.accessibilityValue() as? String)].compactMap { $0 }.first { !$0.isEmpty }
                    if label == nil { unlabeled.append("\(role) at depth \(depth)") }
                }
                for c in (a.accessibilityChildren() ?? []) { walk(c, depth + 1) }
            }
            walk(root, 0)
            let total = counts.values.reduce(0, +)
            report.append("\(item.rawValue): \(total) accessibility elements (\(counts.sorted { $0.value > $1.value }.prefix(5).map { "\($0.key)×\($0.value)" }.joined(separator: ", "))); controls without any label/title/help: \(unlabeled.count)\(unlabeled.isEmpty ? "" : " → " + unlabeled.prefix(8).joined(separator: "; "))")
        }
        try? report.joined(separator: "\n").write(to: dir.appendingPathComponent("a11y-audit.txt"), atomically: true, encoding: .utf8)
    }

    /// Asks SwiftUI to build its accessibility tree (as an assistive technology would), then lists controls that have
    /// no label, title, help or value, with enough detail to find them.
    static func axAudit(_ model: AppModel) async -> [String] {
        var log: [String] = []
        NSApp.setValue(true, forKey: "accessibilityEnhancedUserInterface")
        for item in SidebarItem.allCases {
            model.selection = item; model.activeSessionID = nil
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            guard let root = NSApp.windows.first(where: { $0.isVisible })?.contentView else { continue }
            var roles: [String: Int] = [:], unlabeled: [String] = []
            func text(_ a: NSAccessibilityProtocol) -> String? { [a.accessibilityLabel(), a.accessibilityTitle(), a.accessibilityHelp(), a.accessibilityValue() as? String].compactMap { $0 }.first { !$0.isEmpty } }
            func descendantText(_ a: NSAccessibilityProtocol, _ d: Int = 0) -> String? {
                if d > 4 { return nil }
                for c in a.accessibilityChildren() ?? [] { if let p = c as? NSAccessibilityProtocol { if let t = text(p) { return t }; if let t = descendantText(p, d + 1) { return t } } }
                return nil
            }
            func walk(_ el: Any, _ d: Int) {
                guard d < 80, let a = el as? NSAccessibilityProtocol else { return }
                let role = a.accessibilityRole()?.rawValue ?? "none"; roles[role, default: 0] += 1
                if ["AXButton", "AXPopUpButton", "AXCheckBox", "AXRadioButton", "AXTextField", "AXTextArea", "AXMenuButton", "AXStepper", "AXSlider"].contains(role), text(a) == nil {
                    let f = a.accessibilityFrame()
                    unlabeled.append("\(role) at (\(Int(f.minX)),\(Int(f.minY)) \(Int(f.width))×\(Int(f.height))) child text: \(descendantText(a) ?? "none") placeholder: \((a as? NSObject)?.value(forKey: "accessibilityPlaceholderValue") as? String ?? "none")")
                }
                for c in a.accessibilityChildren() ?? [] { walk(c, d + 1) }
            }
            walk(root, 0)
            log.append("AX \(item.rawValue): \(roles.values.reduce(0, +)) elements; unlabeled controls: \(unlabeled.count)")
            for u in unlabeled { log.append("    · " + u) }
        }
        // Practice screens, one per question type.
        if let c = model.courseList.first, let ids = try? model.practice?.questionIds(courseId: c.id), !ids.isEmpty {
            model.startPractice(questionIds: ids, title: "AX audit", courseId: c.id)
            for i in 0..<ids.count {
                model.snapshotIndex = nil; model.snapshotIndex = i
                try? await Task.sleep(nanoseconds: 1_300_000_000)
                guard let root = NSApp.windows.first(where: { $0.isVisible })?.contentView else { continue }
                var n = 0, unl: [String] = []
                func w(_ el: Any, _ d: Int) {
                    guard d < 80, let a = el as? NSAccessibilityProtocol else { return }
                    n += 1
                    let role = a.accessibilityRole()?.rawValue ?? ""
                    if ["AXButton", "AXPopUpButton", "AXCheckBox", "AXRadioButton", "AXTextField", "AXTextArea", "AXStepper", "AXSlider"].contains(role),
                       [a.accessibilityLabel(), a.accessibilityTitle(), a.accessibilityHelp(), a.accessibilityValue() as? String].compactMap({ $0 }).allSatisfy({ $0.isEmpty }), a.accessibilityFrame().width > 1 {
                        let f = a.accessibilityFrame(); unl.append("\(role) at (\(Int(f.minX)),\(Int(f.minY)) \(Int(f.width))×\(Int(f.height)))")
                    }
                    for c in a.accessibilityChildren() ?? [] { w(c, d + 1) }
                }
                w(root, 0)
                if ProcessInfo.processInfo.environment["BRAINCELL_AXDUMP"] == "\(i + 1)" {
                    func dump(_ el: Any, _ d: Int) {
                        guard d < 40, let a = el as? NSAccessibilityProtocol else { return }
                        let f = a.accessibilityFrame()
                        log.append(String(repeating: "  ", count: d) + "- \(a.accessibilityRole()?.rawValue ?? "?") label=\(a.accessibilityLabel() ?? "") title=\(a.accessibilityTitle() ?? "") (\(Int(f.minX)),\(Int(f.minY)) \(Int(f.width))×\(Int(f.height)))")
                        for c in a.accessibilityChildren() ?? [] { dump(c, d + 1) }
                    }
                    log.append("DUMP question \(i + 1):"); dump(root, 0)
                }
                log.append("AX Practice question \(i + 1): \(n) elements; unlabeled controls: \(unl.count)" + unl.map { "\n    · " + $0 }.joined())
            }
            model.activeSessionID = nil
        }
        return log
    }

    /// Drives the real PracticeModel / FocusModel / backup logic inside the running app (real timers, real run loop,
    /// real database), calling the same actions the buttons call. A substitute for click-testing; it does not
    /// exercise the SwiftUI view wiring itself. Results go to selftest-models.txt.
    static func modelSelfTest(_ model: AppModel, dir: URL) async {
        var log: [String] = []
        var failures = 0
        func check(_ ok: Bool, _ what: String) { log.append((ok ? "PASS " : "FAIL ") + what); if !ok { failures += 1 } }
        func sleep(_ s: Double) async { try? await Task.sleep(nanoseconds: UInt64(s * 1_000_000_000)) }
        guard let c = model.courseList.first, let p = model.practice, let rows = try? model.questions?.list(QuestionFilter()), let ev = model.evaluation else { log.append("FAIL setup"); return }
        func qid(_ t: String) -> UUID { rows.first { $0.title.hasPrefix(t) }!.id }

        // ── PracticeModel: the flow behind the practice screen's buttons ───────────────────────────────
        let ids = [qid("Recursive call count"), qid("Name the interface"), qid("Explain fail-fast"), qid("What does Iterator.hasNext")]
        let sid = (try? p.start(questionIds: ids, title: "Self-test", courseId: c.id))!.id
        let pm = PracticeModel(app: model, sessionID: sid)
        check(pm.items.count == 4 && pm.index == 0 && pm.spec?.type == .numeric, "session loads on the first question")

        pm.response.text = "7"
        await sleep(1.0)                                                                  // debounce is 600 ms
        let draft = (try? p.response(for: pm.items[0], spec: pm.spec!))?.text
        check(draft == "7", "typing autosaves a draft to the database (got \(draft ?? "nil"))")

        pm.togglePause()
        let t0 = pm.seconds; pm.tick(active: true)
        check(pm.paused && pm.seconds == t0 && (try? p.session(sid))?.status == .paused, "pause stops the timer and is persisted")
        pm.togglePause(); pm.tick(active: true)
        check(!pm.paused && pm.seconds == t0 + 1, "resume restarts the timer")
        pm.tick(active: false)
        check(pm.seconds == t0 + 1, "an inactive window doesn't count as active time")

        pm.submit()
        check(pm.locked && pm.attempt != nil && pm.result?.evaluation.state == .graded && pm.result?.evaluation.score == 1, "submit creates an attempt and grades it (numeric 7 is right)")
        pm.response.text = "99"; await sleep(0.8)
        check((try? p.attempt(itemId: pm.items[0].id))?.decodedResponse.text == "7", "a submitted answer can't be edited or re-saved")

        pm.go(1)
        check(pm.index == 1 && pm.spec?.type == .shortAnswer, "Next moves to the short answer")
        pm.response.text = "half an answer"
        pm.skip()
        let skipped = pm.items[1]
        check(skipped.status == .skipped && pm.index == 2, "Skip marks the item and advances")
        check((try? p.response(for: skipped, spec: try! p.spec(for: skipped)))?.text == "half an answer", "skipping keeps what was typed")
        pm.go(-1)
        check(pm.response.text == "half an answer", "going back restores the skipped draft")
        pm.go(1)

        check(pm.spec?.type == .longForm, "reached the essay")
        let hintsBefore = pm.hintsUsed
        pm.revealHint()
        check(pm.hintsUsed == hintsBefore + 1 || (pm.spec?.hints.isEmpty ?? true), "hint reveal is recorded")
        pm.response.text = "It throws when the list changes."
        pm.submit()
        check(pm.result?.evaluation.state == .pending && pm.result?.evaluation.score == nil, "an essay stays pending (not wrong)")
        pm.selfReview(score: 0.5, rubricPoints: nil)
        check(pm.result?.evaluation.state == .graded && pm.result?.evaluation.trust == .selfReported, "self-review grades it as lower-confidence evidence")

        pm.go(1)
        check(pm.spec?.type == .flashcard, "reached the flashcard")
        pm.response.revealed = true
        pm.submit()
        pm.selfReview(score: 0.8, rubricPoints: nil, rating: "good")
        check((try? model.reviews?.state(questionId: ids[3])) != nil, "rating a flashcard schedules a review (FSRS)")

        pm.finish()
        let sum = pm.summary
        check(sum != nil && sum!.skipped == 1 && sum!.correct >= 2, "finish shows a summary (skipped 1, correct \(sum?.correct ?? -1))")
        pm.exit()
        check(model.activeSessionID == nil && (try? p.resumableSession()) == nil, "exit from a finished session leaves nothing to resume")

        // An unfinished session pauses on exit and can be resumed with its draft.
        let sid2 = (try? p.start(questionIds: [ids[0]], title: "Unfinished", courseId: c.id))!.id
        model.activeSessionID = sid2
        let pm2 = PracticeModel(app: model, sessionID: sid2)
        pm2.response.text = "typed but never submitted"
        pm2.exit()
        let resumed = try? p.resumableSession()
        check(resumed?.id == sid2 && resumed?.status == .paused, "leaving mid-question pauses the session")
        let pm3 = PracticeModel(app: model, sessionID: sid2)
        check(pm3.response.text == "typed but never submitted", "resuming restores the draft")


        // ── Sandboxed code execution through the real PracticeModel ───────────────────────────────────
        let codeQ = qid("Write a Python generator")
        let ref = (try? model.questions?.detail(codeQ).spec.answer.referenceSolution) ?? ""
        let off = PracticeModel(app: model, sessionID: (try! p.start(questionIds: [codeQ], title: "Code off", courseId: c.id)).id)
        await off.runTests()
        if case .unavailable = off.testReport ?? .ran([]) { check(true, "with code execution off, Run Tests reports it is unavailable (nothing runs)") } else { check(false, "code ran while switched off: \(String(describing: off.testReport))") }
        model.setCodeExecution(true)
        check(model.codeExecutionEnabled && model.codeRunner.isAvailable, "enabling code execution makes the sandbox runner available")
        let verdict = try? await CodeVerificationService(db: model.db!).verify(questionId: codeQ, runner: model.codeRunner)
        check(verdict == .verified && (try? model.questions?.detail(codeQ).question.readiness) == .verified, "Verify Tests: the reference solution passes its own tests and the question becomes Verified")
        let cp = PracticeModel(app: model, sessionID: (try! p.start(questionIds: [codeQ], title: "Code on", courseId: c.id)).id)
        cp.response.files = [CodeFile(name: "main.py", language: "python", content: "n = int(input())\nfor i in range(n): print(i*i)\n")]
        await cp.runTests()
        if case .ran(let o) = cp.testReport ?? .ran([]) {
            check(o.count == 4 && o.allSatisfy { $0.status == .passed }, "Run Tests: a correct solution passes 4 of 4")
            check(o.first { $0.hidden }?.expected == nil, "the hidden test reveals nothing in the report")
        } else { check(false, "Run Tests produced \(String(describing: cp.testReport))") }
        cp.response.files = [CodeFile(name: "main.py", language: "python", content: "n = int(input())\nprint(n)\n")]
        await cp.runTests()
        check(cp.testReport?.passedCount == 0 && cp.testReport?.totalCount == 4, "Run Tests: a wrong solution fails its tests (\(cp.testReport?.passedCount ?? -1) of 4 passed)")
        await cp.tryRun(stdin: "4\n")
        check(cp.tryOutput?.stdout == "4\n", "Try it echoes the program's output")
        cp.response.files = [CodeFile(name: "main.py", language: "python", content: "print(open('/etc/passwd').read()[:20])\n")]
        await cp.tryRun(stdin: "")
        check(cp.tryOutput?.termination != .exited(0) && !(cp.tryOutput?.stdout.contains("User Database") ?? false), "Try it: a program reading /etc/passwd is blocked")
        cp.response.files = [CodeFile(name: "main.py", language: "python", content: ref)]
        await sleep(0.8)
        cp.submit()
        await sleep(4)
        check(cp.locked && cp.result?.evaluation.state == .graded && cp.result?.evaluation.score == 1 && cp.result?.evaluation.trust == .trusted, "submitting a correct solution grades it automatically via the sandbox (\(cp.result?.evaluation.feedback ?? "no result"))")
        check((cp.result?.xp ?? 0) > 0, "…and awards XP")
        model.setCodeExecution(false)

        // ── FocusModel: real timers ───────────────────────────────────────────────────────────────────
        let evidenceBefore = (try? model.db?.read { try LearningEvidence.fetchCount($0) + XPEvent.fetchCount($0) }) ?? -1
        let fm = FocusModel(app: model)
        fm.settings.shortBreakMinutes = 1
        fm.start(.work)
        await sleep(3.2)
        let r1 = fm.timer?.remainingSeconds ?? 0
        check(fm.isRunning && r1 < fm.settings.seconds(.work) - 2.5 && r1 > fm.settings.seconds(.work) - 4.5, "focus timer counts down in real time (remaining \(Int(r1)) s)")
        fm.pause(); let atPause = fm.timer?.remainingSeconds ?? 0
        await sleep(2.2)
        check(fm.isPaused && abs((fm.timer?.remainingSeconds ?? 0) - atPause) < 0.01, "pause freezes the countdown")
        fm.resume()
        NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.willSleepNotification, object: nil)      // the Mac goes to sleep…
        await sleep(2.2)
        NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.didWakeNotification, object: nil)        // …and wakes
        check((fm.timer?.pausedSeconds ?? 0) >= 4 && abs((fm.timer?.remainingSeconds ?? 0) - atPause) < 0.6, "time asleep counts as paused, not focus")
        fm.stop()
        let ivs = (try? FocusService(db: model.db!).intervals()) ?? []
        check(fm.timer == nil && ivs.first?.endState == "stopped" && (ivs.first?.activeSeconds ?? 0) >= 3 && (ivs.first?.pausedSeconds ?? 0) >= 4, "stop closes the interval with active \(ivs.first?.activeSeconds ?? -1) s / paused \(ivs.first?.pausedSeconds ?? -1) s")
        let evidenceAfter = (try? model.db?.read { try LearningEvidence.fetchCount($0) + XPEvent.fetchCount($0) }) ?? -2
        check(evidenceBefore >= 0 && evidenceBefore == evidenceAfter, "focus time adds no evidence or XP (\(evidenceBefore) → \(evidenceAfter))")

        fm.start(.shortBreak)                                                                                     // a full 60-second break
        for _ in 0..<66 { await sleep(1); if fm.endedKind != nil { break } }
        check(fm.endedKind == .shortBreak && fm.timer == nil, "a break ends by itself and raises the end-of-interval prompt")
        check((try? FocusService(db: model.db!).intervals().first)??.endState == "completed", "the finished interval is stored as completed")
        check((try? FocusService(db: model.db!).recoverInterrupted()) == 0, "nothing is left open")

        // ── Backup / restore logic behind the Settings buttons ─────────────────────────────────────────
        let before = (try? model.db?.read { try Int.fetchOne($0, sql: "SELECT (SELECT COUNT(*) FROM attempts) * 1000 + (SELECT COUNT(*) FROM questions)") ?? 0 }) ?? -1
        let out = dir.appendingPathComponent("backups")
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let made = try? model.performBackup(into: out)
        check(made != nil && made!.manifest.counts["questions"] == 9, "Create Backup writes a backup folder")
        _ = try? model.courses?.createCourse(name: "Created after the backup")
        model.reload()
        let n1 = model.courseList.count
        let restored = try? model.performRestore(from: made!.url)
        check(restored != nil && model.courseList.count == n1 - 1 && model.selection == .home && model.activeSessionID == nil, "Restore replaces newer data and resets the UI state")
        let after = (try? model.db?.read { try Int.fetchOne($0, sql: "SELECT (SELECT COUNT(*) FROM attempts) * 1000 + (SELECT COUNT(*) FROM questions)") ?? 0 }) ?? -2
        check(after == before, "the restored database matches the backed-up one")
        let safety = (try? FileManager.default.contentsOfDirectory(atPath: model.storage!.root.appendingPathComponent("Safety Backups").path)) ?? []
        check(safety.count == 1, "a safety backup of the replaced data was kept")
        check((try? model.performRestore(from: dir)) == nil, "restoring from a non-backup folder is refused")

        log += await axAudit(model)

        log.append("\(failures == 0 ? "ALL PASSED" : "\(failures) FAILED")")
        try? log.joined(separator: "\n").write(to: dir.appendingPathComponent("selftest-models.txt"), atomically: true, encoding: .utf8)
    }
}

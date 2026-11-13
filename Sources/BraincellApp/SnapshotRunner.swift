import SwiftUI
import PDFKit
import CoreText
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
        if ProcessInfo.processInfo.environment["BRAINCELL_E2E"] != nil { await prepE2E(model, dir: dir); NSApp.terminate(nil); return }
        if ProcessInfo.processInfo.environment["BRAINCELL_UNI_SNAP"] != nil { await universalScenario(model, dir: dir); NSApp.terminate(nil); return }
        if ProcessInfo.processInfo.environment["BRAINCELL_REVIEW_SNAP"] != nil { await reviewScenario(model, dir: dir); NSApp.terminate(nil); return }
        if ProcessInfo.processInfo.environment["BRAINCELL_MATH_SNAP"] != nil { await mathScenario(model, dir: dir); NSApp.terminate(nil); return }
        if ProcessInfo.processInfo.environment["BRAINCELL_CHAT_SNAP"] != nil { await chatScenario(model, dir: dir); NSApp.terminate(nil); return }
        if ProcessInfo.processInfo.environment["BRAINCELL_TEMPLATE_SNAP"] != nil { await templateScenario(model, dir: dir); NSApp.terminate(nil); return }
        if ProcessInfo.processInfo.environment["BRAINCELL_LIBRARY_SNAP"] != nil { await libraryScenario(model, dir: dir); NSApp.terminate(nil); return }
        if ProcessInfo.processInfo.environment["BRAINCELL_BENCH"] != nil { await Bench.run(model, dir: dir); NSApp.terminate(nil); return }
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
        model.openQuestionBank()
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

    /// Drives the real Home chat against a local scripted model server (BRAINCELL_CHAT_PORT) and screenshots each stage. Only against BRAINCELL_DATA_DIR.
    /// Screenshots of math-heavy questions (structured, legacy plain text, long equations) in dark and light. Uses only the demo workspace.
    static func mathScenario(_ model: AppModel, dir: URL) async {
        model.loadDemo()
        guard let c = model.courseList.first, let qs = model.questions else { return }
        func shot(_ name: String) async {
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            guard let v = NSApp.windows.first(where: { $0.isVisible && $0.contentView != nil })?.contentView, let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) else { return }
            v.cacheDisplay(in: v.bounds, to: rep); try? rep.representation(using: .png, properties: [:])?.write(to: dir.appendingPathComponent("\(name).png"))
        }
        func make(_ title: String, _ text: String) -> UUID? {
            try? qs.create(courseId: c.id, spec: QuestionSpec(type: .longForm, title: title, difficulty: 4, learningObjective: "Reason about correlation", content: [.markdown(text)],
                answer: AnswerSpec(), evaluation: EvaluationSpec(method: .aiRubric, rubric: [RubricItem(criterion: "Correct", points: 3)]), hints: ["Standardize first."])).id
        }
        let structured = "Suppose \\(X\\) and \\(Y\\) have finite, positive variances \\(\\sigma_X^2\\) and \\(\\sigma_Y^2\\). Define the standardized variables\n\\[U=\\frac{X-\\mathbb{E}[X]}{\\sigma_X}, \\qquad V=\\frac{Y-\\mathbb{E}[Y]}{\\sigma_Y}.\\]\nAssume \\(\\mathbb{E}[UV]=1\\).\n\n**Part A.** Show that \\(\\mathbb{E}[(U-V)^2]=0\\).\n**Part B.** Conclude that \\(Y=aX+b\\) almost surely for some \\(a>0\\), and find \\(a\\) in terms of \\(\\sigma_X\\) and \\(\\sigma_Y\\)."
        let legacy = "Suppose X and Y have finite, positive variances.\nU=(X-E[X])/σ_X\nShow that Corr(X,Y)=1 implies Y is linear in X."
        let pr4 = "Independent trials each succeed with probability 0.30. Let \\(T\\) be the number of trials through and including the first success. Find \\(\\Pr(T=4)\\)."
        let long = "The sample variance is\n\\[s^2=\\frac{1}{n-1}\\sum_{i=1}^{n}\\left(x_i-\\bar{x}\\right)^2=\\frac{1}{n-1}\\left(\\sum_{i=1}^{n}x_i^2-n\\bar{x}^2\\right)+\\text{an extremely long trailing term that must scroll instead of overflowing the card}\\]\nand for a matrix \\(A\\):\n\\[A=\\begin{pmatrix}1&2\\\\3&4\\end{pmatrix},\\quad \\int_0^1 x^2\\,dx=\\frac13\\]\n\\begin{aligned}a&=b+c\\\\ d&=e\\end{aligned}\nBroken: \\(\\frac{1}{ and a \\(\\unknown{x}\\) span."
        let ids = [make("Structured", structured), make("Legacy", legacy), make("Long", long), make("Probability", pr4)].compactMap { $0 }
        CalculatorPanel.shared.toggle(model: model)
        try? await Task.sleep(nanoseconds: 1_500_000_000)
        if let v = NSApp.windows.first(where: { $0.title == "Calculator" && $0.isVisible })?.contentView, let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) {
            v.cacheDisplay(in: v.bounds, to: rep); try? rep.representation(using: .png, properties: [:])?.write(to: dir.appendingPathComponent("calculator.png"))
        } else { NSLog("snapshot: calculator panel not visible") }
        CalculatorPanel.shared.toggle(model: model)
        model.startPractice(questionIds: ids, title: "Math", courseId: c.id)
        for (i, n) in ["structured", "legacy", "long", "pr"].enumerated() { model.snapshotIndex = i; await shot("math-\(n)-dark") }
        model.setAppearance(.light)
        for (i, n) in ["structured", "legacy", "long"].enumerated() { model.snapshotIndex = i; await shot("math-\(n)-light") }
    }

    static func chatScenario(_ model: AppModel, dir: URL) async {
        guard let chat = model.chat, let gw = model.gateway, let courses = model.courses, let docs = model.documents, let port = ProcessInfo.processInfo.environment["BRAINCELL_CHAT_PORT"],
              ProcessInfo.processInfo.environment["BRAINCELL_DATA_DIR"] != nil else { return }
        var log = ""
        func note(_ s: String) { log += s + "\n"; try? log.write(to: dir.appendingPathComponent("chat-log.txt"), atomically: true, encoding: .utf8) }
        func shotWin(_ name: String, wait: UInt64 = 1_200_000_000) async {
            try? await Task.sleep(nanoseconds: wait)
            guard let v = NSApp.windows.first(where: { $0.isVisible && $0.contentView != nil && $0.title != "Settings" })?.contentView, let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) else { return }
            v.cacheDisplay(in: v.bounds, to: rep); try? rep.representation(using: .png, properties: [:])?.write(to: dir.appendingPathComponent("\(name).png"))
        }
        func until(_ secs: Double, _ cond: @MainActor () -> Bool) async -> Bool { let end = Date().addingTimeInterval(secs); while Date() < end { if cond() { return true }; try? await Task.sleep(nanoseconds: 250_000_000) }; return cond() }
        func pendingApproval() -> UUID? {
            chat.messages.last(where: { $0.kind == .approval }).flatMap { m in (try? JSONSerialization.jsonObject(with: Data((m.payload ?? "{}").utf8))) as? [String: String] }
                .flatMap { $0["status"] == "proposed" ? $0["actionId"].flatMap(UUID.init) : nil }
        }
        do {
            let (c, n) = try await gw.connect(providerId: "custom", name: "Local scripted model", baseURL: "http://127.0.0.1:\(port)/v1", apiKey: "test")
            try gw.store.setDefault(.llm, connection: c.id, model: "scripted-model"); note("connected, \(n) model(s)")
        } catch { note("connect failed: \(error.localizedDescription)"); return }
        model.aiConfig?.reload()
        let cal = Calendar.current
        let course = try? courses.createCourse(name: "COMP301 Midterm 2 (Frank)")
        if let course {
            let friday = cal.nextDate(after: Date(), matching: DateComponents(weekday: 6), matchingPolicy: .nextTime)
            _ = try? courses.addAssessment(courseId: course.id, name: "Midterm 2", kind: .midterm, deadline: friday, isCumulative: true)
            _ = try? courses.addSkill(courseId: course.id, name: "Pointers")
            let f = dir.appendingPathComponent("notes.txt"); try? "Lecture 4: Pointers\n\nA pointer stores a memory address. The dereference operator * reads the value at that address. malloc from stdlib.h allocates heap memory.".write(to: f, atomically: true, encoding: .utf8)
            _ = try? docs.importFile(at: f, courseId: course.id)
        }
        model.reload(); model.selection = .home; chat.newChat()
        await shotWin("chat-1-empty")
        chat.draft = "Explain a difficult concept from my course step by step: "
        await shotWin("chat-2-suggestion-in-composer", wait: 400_000_000)
        chat.draft = "Help me prepare for my COMP301 Midterm 2 next Friday. I want a study plan and practice problems."
        chat.send()
        note("sent; waiting for approval: \(await until(40) { pendingApproval() != nil })")
        await shotWin("chat-3-approval")
        if let a = pendingApproval() { chat.approve(a) }
        note("preview: \(await until(60) { chat.messages.contains { $0.kind == .preview } && !chat.thinking })")
        await shotWin("chat-4-preview")
        if let gid = chat.messages.last(where: { $0.kind == .preview }).flatMap({ m in ((try? JSONSerialization.jsonObject(with: Data((m.payload ?? "{}").utf8))) as? [String: String])?["actionId"].flatMap(UUID.init) }) { chat.savePreview(gid) }
        _ = await until(20) { (try? model.questions?.list({ var f = QuestionFilter(); f.courseId = course?.id; return f }()).count) == 3 }
        note("questions in bank after save: \((try? model.questions?.list({ var f = QuestionFilter(); f.courseId = course?.id; return f }()).count) ?? -1)")
        chat.draft = "Please rebuild my plan now that the questions are saved."; chat.send()
        _ = await until(40) { !chat.thinking && chat.messages.last?.role == .assistant && chat.messages.last?.kind == .text }
        await shotWin("chat-5-plan")
        note("plans: \((try? chat.store.plans().count) ?? -1), conversations: \(chat.conversations.count)")
        chat.newChat(); chat.draft = "Help me prepare for my BIO101 exam."; chat.send()
        note("bio approval: \(await until(40) { pendingApproval() != nil })")
        await shotWin("chat-6-create-course")
        if let a = pendingApproval() { chat.approve(a) }
        _ = await until(40) { !chat.thinking && chat.messages.last?.role == .assistant && chat.messages.last?.kind == .text }
        note("courses: \(model.courseList.map(\.name))")
        model.reload()
        await shotWin("chat-7-created")
        note("done")
    }

    /// Library screenshots from synthetic files. Only with BRAINCELL_LIBRARY_SNAP and BRAINCELL_DATA_DIR (never your real library).
    /// Template gallery, practice-set section and a real worksheet PDF rendered to PNG (checks pagination, math layout and annotations visually).
    static func templateScenario(_ model: AppModel, dir: URL) async {
        model.loadDemo()
        guard let c = model.courseList.first, let db = model.db, let ids = try? model.practice?.questionIds(courseId: c.id), !ids.isEmpty, let sets = model.practiceSets, let ws = model.worksheets else { return }
        let setId = UUID()
        try? db.write { d in
            try d.execute(sql: "INSERT INTO practice_sets (id, courseId, assessmentId, title, requestKey, paramsJSON, fresh, taskId, createdAt) VALUES (?,?,NULL,'Demo practice set','snap','{}',0,NULL,?)", arguments: [setId, c.id, Date()])
            for (i, q) in ids.enumerated() {
                let slot = "{\"id\":\"s\(i + 1)\",\"topic\":\"Demo\",\"archetype\":\"directComputation\",\"difficulty\":3,\"format\":\"any\",\"exemplars\":[],\"rationale\":\"\"}"
                try d.execute(sql: "INSERT INTO practice_set_items (setId, slotId, position, slotJSON, questionId, origin) VALUES (?,?,?,?,?,'reused')", arguments: [setId, "s\(i + 1)", i, slot, q])
            }
        }
        func shotWin(_ name: String) async {
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            guard let v = NSApp.windows.first(where: { $0.isVisible && $0.contentView != nil })?.contentView, let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) else { return }
            v.cacheDisplay(in: v.bounds, to: rep); try? rep.representation(using: .png, properties: [:])?.write(to: dir.appendingPathComponent("\(name).png"))
        }
        model.selectedCourseID = c.id; model.selection = .courses
        await shotWin("tpl-1-assessments")
        model.librarySection = .templates; model.selection = .library
        await shotWin("tpl-2-gallery")
        if let w = try? ws.generate(setId: setId, template: .examWorksheet), let doc = PDFDocument(url: ws.url(w)) {
            try? ws.save(WorksheetAnnotation(worksheetId: w.id, page: 0, kind: .field, x: 0.2, y: 0.35, w: 0.4, h: 0.05, text: "x = 4.5"))
            let out = dir.appendingPathComponent("tpl-annotated.pdf"); try? ws.export(w, to: out, annotations: .flattened)
            for (n, d) in [("plain", doc), ("annotated", PDFDocument(url: out) ?? doc)] {
                for i in 0..<min(2, d.pageCount) { if let pg = d.page(at: i) { let img = pg.thumbnail(of: CGSize(width: 900, height: 1165), for: .mediaBox); if let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) { try? rep.representation(using: .png, properties: [:])?.write(to: dir.appendingPathComponent("tpl-worksheet-\(n)-p\(i + 1).png")) } } }
            }
            NSLog("snapshot: worksheet pages=%d questions=%d", w.pageCount, ids.count)
        }
        // Math typesetting check: the gallery's sample questions (fractions, big operators, scripts) through the PDF writer.
        let mathDoc = RenderBuilder.build(template: .examWorksheet, title: "Math layout check", questions: TemplateExamples.questions.map { (UUID(), $0, Optional("Probability")) } + [(UUID(), QuestionSpec(type: .derivationProof, title: "m", difficulty: 3, learningObjective: "o",
            content: [.markdown("Show that $\\sqrt{a^2+b^2}\\ge a$ and evaluate:"), ContentBlock(kind: .math, latex: "\\begin{pmatrix} a & b \\\\ c & d \\end{pmatrix}^{-1}=\\frac{1}{ad-bc}\\begin{pmatrix} d & -b \\\\ -c & a \\end{pmatrix}"), ContentBlock(kind: .math, latex: "\\int_{0}^{\\infty} e^{-x^{2}}\\,dx=\\frac{\\sqrt{\\pi}}{2}"), ContentBlock(kind: .math, latex: "\\sum_{k=1}^{n} \\left(\\frac{k}{n}\\right)^{2}")],
            answer: AnswerSpec(), evaluation: EvaluationSpec(method: .aiRubric)), "T")])
        let mp = dir.appendingPathComponent("tpl-math.pdf"); _ = try? WorksheetRenderer.write(mathDoc, to: mp)
        if let d = PDFDocument(url: mp) { for i in 0..<min(2, d.pageCount) { if let pg = d.page(at: i), let tiff = pg.thumbnail(of: CGSize(width: 1100, height: 1424), for: .mediaBox).tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) { try? rep.representation(using: .png, properties: [:])?.write(to: dir.appendingPathComponent("tpl-math-p\(i + 1).png")) } } }
        _ = sets
    }

    static func libraryScenario(_ model: AppModel, dir: URL) async {
        guard let lib = model.library, let courses = model.courses, ProcessInfo.processInfo.environment["BRAINCELL_DATA_DIR"] != nil else { return }
        let src = dir.appendingPathComponent("src", isDirectory: true); let fm = FileManager.default
        func png(_ path: String, _ r: CGFloat, _ g: CGFloat, _ b: CGFloat) {
            let u = src.appendingPathComponent(path); try? fm.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
            let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 320, pixelsHigh: 220, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
            NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
            NSGradient(starting: NSColor(calibratedRed: r, green: g, blue: b, alpha: 1), ending: NSColor(calibratedRed: b, green: r, blue: g, alpha: 1))!.draw(in: NSRect(x: 0, y: 0, width: 320, height: 220), angle: 35)
            NSGraphicsContext.restoreGraphicsState(); try? rep.representation(using: .png, properties: [:])?.write(to: u)
        }
        func pdf(_ path: String, _ text: String) {
            let u = src.appendingPathComponent(path); try? fm.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
            var box = CGRect(x: 0, y: 0, width: 612, height: 792); let ctx = CGContext(u as CFURL, mediaBox: &box, nil)!
            ctx.beginPDFPage(nil); let attr = NSAttributedString(string: text, attributes: [.font: CTFontCreateWithName("Helvetica-Bold" as CFString, 28, nil)])
            ctx.textPosition = CGPoint(x: 60, y: 700); CTLineDraw(CTLineCreateWithAttributedString(attr), ctx); ctx.endPDFPage(); ctx.closePDF()
        }
        func txt(_ path: String, _ s: String) { let u = src.appendingPathComponent(path); try? fm.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true); try? s.write(to: u, atomically: true, encoding: .utf8) }
        guard let a = try? courses.createCourse(name: "COMP211"), let b = try? courses.createCourse(name: "COMP301 Midterm"), let old = try? courses.createCourse(name: "STAT435") else { return }
        pdf("Lecture Notes/Week 1 Pointers.pdf", "Pointers"); pdf("Lecture Notes/Week 2 Memory.pdf", "Memory"); png("Lecture Notes/Images/stack diagram.png", 0.3, 0.5, 0.9); png("Lecture Notes/Images/heap.png", 0.9, 0.4, 0.3)
        txt("Lecture Notes/syllabus.md", "# Syllabus\nWeek 1 ...")
        _ = lib.importFolder(src.appendingPathComponent("Lecture Notes"), into: .course(a.id))
        pdf("Slides.pdf", "UML Relationships"); png("whiteboard.png", 0.2, 0.7, 0.5); txt("Code Examples.txt", "int main() { return 0; }")
        _ = lib.importFiles([src.appendingPathComponent("Slides.pdf"), src.appendingPathComponent("whiteboard.png"), src.appendingPathComponent("Code Examples.txt")], into: .course(b.id))
        let research = try? lib.createFolder("Research", in: .root); _ = try? lib.createFolder("References", in: .root)
        pdf("Paper.pdf", "A paper"); png("figure.png", 0.8, 0.8, 0.2); txt("reading list.txt", "1. Foo\n2. Bar")
        _ = lib.importFiles([src.appendingPathComponent("Paper.pdf"), src.appendingPathComponent("figure.png"), src.appendingPathComponent("reading list.txt")], into: research.map { .folder($0) } ?? .root)
        _ = lib.importFiles([src.appendingPathComponent("figure.png")], into: .root)
        if let first = try? lib.list(.root).first(where: { $0.name == "figure.png" }) { try? lib.setFavorite([first.ref], true) }
        pdf("old.pdf", "Old"); _ = lib.importFiles([src.appendingPathComponent("old.pdf")], into: .course(old.id)); try? lib.deleteCourse(old.id)
        model.reload()
        func shotWin(_ name: String) async {
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            guard let v = NSApp.windows.first(where: { $0.isVisible && $0.contentView != nil && $0.title != "Settings" })?.contentView, let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) else { return }
            v.cacheDisplay(in: v.bounds, to: rep); try? rep.representation(using: .png, properties: [:])?.write(to: dir.appendingPathComponent("\(name).png"))
        }
        UserDefaults.standard.set("grid", forKey: "libraryLayout"); model.selection = .library
        await shotWin("lib-1-root-grid")
        UserDefaults.standard.set("list", forKey: "libraryLayout"); await shotWin("lib-2-root-list")
        UserDefaults.standard.set("grid", forKey: "libraryLayout")
        model.snapshotCourseTab = "materials"; model.selectedCourseID = a.id; model.selection = .courses
        await shotWin("lib-3-course-materials")
        model.snapshotLibrarySearch = "e"; model.selection = .library
        await shotWin("lib-4-search")
        model.snapshotLibrarySearch = ""; model.snapshotShowDeleted = true
        await shotWin("lib-5-recently-deleted")
        if let w = NSApp.windows.first(where: { $0.isVisible && $0.title != "Settings" && $0.contentView != nil }) { model.snapshotShowDeleted = false; w.setContentSize(NSSize(width: 900, height: 600)) }
        UserDefaults.standard.set("grid", forKey: "libraryLayout"); model.snapshotLibrarySearch = "e"
        await shotWin("lib-6-narrow")
        UserDefaults.standard.removeObject(forKey: "libraryLayout")
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
        for i in 0..<450 {            // a large catalog, like OpenRouter's, to check scrolling and filtering
            try? gw.store.save(AIModelRecord(connectionId: c.id, modelId: "vendor\(i % 12)/model-\(i)-with-a-fairly-long-name", displayName: "Vendor \(i % 12) Model \(i) Long Display Name", capability: .llm, source: "discovered", inputPricePerM: i % 9 == 0 ? nil : Double(i % 30) * 0.1, outputPricePerM: i % 9 == 0 ? nil : Double(i % 30) * 0.4))
        }
        model.aiConfig?.reload()
        let wfOnly = ProcessInfo.processInfo.environment["BRAINCELL_WF_ONLY"]
        if let wfOnly {                                      // workflow-page shots at several window sizes, optionally pre-expanded
            UserDefaults.standard.set(SettingsSection.workflow.rawValue, forKey: "settingsSection"); UserDefaults.standard.set("map", forKey: "wf.mode")
            UserDefaults.standard.set(wfOnly.split(separator: ",").map(String.init).filter { !$0.isEmpty }, forKey: "wf.expanded")
            UserDefaults.standard.removeObject(forKey: "wf.cam")
        }
        model.openSettings()
        try? await Task.sleep(nanoseconds: 2_000_000_000)
        guard let w = NSApp.windows.first(where: { $0.isVisible && $0.contentView != nil }) else { NSLog("snapshot: no window"); return }
        NSLog("snapshot: windows=%d (Settings is in-app, expect 1 content window)", NSApp.windows.filter { $0.isVisible && $0.contentView != nil && !($0 is NSPanel) && $0.frame.width > 300 }.count)
        if wfOnly != nil {
            for (name, size) in [("wide", NSSize(width: 1500, height: 900)), ("default", NSSize(width: 1180, height: 780)), ("min", NSSize(width: 980, height: 640))] {
                w.setContentSize(size)
                try? await Task.sleep(nanoseconds: 1_800_000_000)
                guard let v = w.contentView, let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) else { continue }
                v.cacheDisplay(in: v.bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])?.write(to: dir.appendingPathComponent("wf-\(name).png"))
            }
            return
        }
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

    /// End-to-end run of the exam-preparation flow through the real wizard model, services, database and HTTP gateway against scripts/mock-model-server.py
    /// (BRAINCELL_E2E_PORT, BRAINCELL_E2E_LOG). Two phases in two processes (BRAINCELL_E2E_PHASE=1,2) over one BRAINCELL_DATA_DIR so a real quit/relaunch happens in
    /// the middle. Mocked model: results prove the app's behaviour and call counts, not live-model quality. Writes PASS/FAIL lines to e2e-log.txt.
    static func prepE2E(_ model: AppModel, dir: URL) async {
        let env = ProcessInfo.processInfo.environment
        guard env["BRAINCELL_DATA_DIR"] != nil, let port = env["BRAINCELL_E2E_PORT"], let logPath = env["BRAINCELL_E2E_LOG"], let gw = model.gateway, let courses = model.courses, let docs = model.documents,
              let ps = model.practiceSets, let practice = model.practice, let ev = model.evaluation, let lib = model.library, let qs = model.questions, let chat = model.chat else { return }
        let phase = env["BRAINCELL_E2E_PHASE"] ?? "1"
        var out = ""
        func note(_ s: String) { out += s + "\n"; try? out.write(to: dir.appendingPathComponent("e2e-log-phase\(phase).txt"), atomically: true, encoding: .utf8) }
        func check(_ name: String, _ ok: Bool, _ detail: String = "") { note("\(ok ? "PASS" : "FAIL") \(name)\(detail.isEmpty ? "" : " — " + detail)") }
        func calls(_ kind: String) -> Int { ((try? String(contentsOfFile: logPath, encoding: .utf8)) ?? "").split(separator: "\n").filter { $0.contains("\"\(kind)\"") }.count }
        func shot(_ name: String, sheet: Bool = false) async {
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            let w = NSApp.windows.first(where: { $0.isVisible && ($0.attachedSheet != nil || !sheet) && $0.contentView != nil })
            guard let v = (sheet ? w?.attachedSheet?.contentView : w?.contentView), let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) else { return }
            v.cacheDisplay(in: v.bounds, to: rep); try? rep.representation(using: .png, properties: [:])?.write(to: dir.appendingPathComponent("e2e\(phase)-\(name).png"))
        }
        func until(_ secs: Double, _ cond: @MainActor () -> Bool) async -> Bool { let end = Date().addingTimeInterval(secs); while Date() < end { if cond() { return true }; try? await Task.sleep(nanoseconds: 200_000_000) }; return cond() }
        do {
            let (c, _) = try await gw.connect(providerId: "custom", name: "Mock model", baseURL: "http://127.0.0.1:\(port)/v1", apiKey: "test")
            try gw.store.setDefault(.llm, connection: c.id, model: "scripted-model")
        } catch { note("FAIL connect — \(error.localizedDescription)"); return }
        model.aiConfig?.reload()
        note("phase \(phase); model calls so far — topics \(calls("topics")), questions \(calls("questions")), summary \(calls("summary"))")

        if phase == "1" {
            guard let course = try? courses.createCourse(name: "STOR435") else { return }
            for (n, t) in [("notes.txt", "Chapter 2: Estimation. Chapter 2 is worth 40% of the exam grade.\n\nMaximum likelihood estimators maximize the likelihood. Worked example: the MLE of an exponential rate is 1/mean.\n\nConfidence intervals cover the parameter with a stated probability."), ("syllabus.txt", "Midterm 3 covers estimation and confidence intervals.")] {
                let f = dir.appendingPathComponent(n); try? t.write(to: f, atomically: true, encoding: .utf8); _ = try? docs.importFile(at: f, courseId: course.id)
            }
            model.reload(); model.selection = .home; chat.newChat()
            await shot("01-home")
            model.openExamPrep()                                                    // exactly what the “Prepare for an exam” button calls
            check("Prepare for an exam opens the wizard", await until(5) { ExamPrepModel.current != nil && model.prepRequest != nil })
            guard let m = ExamPrepModel.current else { return }
            await shot("02-course", sheet: true)
            m.courseId = course.id; m.assessmentName = "Midterm 3"; m.begin()
            check("course + new assessment accepted, materials step", m.step == .materials && m.job != nil, "assessments: \((try? courses.assessments(courseId: course.id).map(\.name)) ?? [])")
            check("relevant materials found", m.materials?.readable.count == 2, "\(m.materials?.readable.map(\.name) ?? [])")
            await shot("03-materials", sheet: true)
            m.next(); check("no model call before analysis", calls("topics") == 0)
            m.analyze(); _ = await until(30) { !m.busy }
            check("analysis ran once", calls("topics") == 1 && m.map?.topics.count == 3, "topics \(m.map?.topics.map(\.name) ?? [])")
            let est = m.map?.topics.first { $0.name == "Estimation" }
            check("instructor weight kept as stated; estimates not presented as instructor", est?.importance.source == .instructor && est?.importance.weightPercent == 40 && m.map?.topics.first { $0.name == "Maximum likelihood" }?.importance.weightPercent == nil)
            await shot("04-analyzed", sheet: true)
            m.go(.review); await shot("05-review", sheet: true)
            m.templateId = "builtin.guided"; m.saveReview(); m.go(.template); await shot("06-template", sheet: true)
            m.go(.configure); m.count = 4; await shot("07-configure", sheet: true)
            m.makePlan()
            check("reuse breakdown shown before any generation cost", m.plan?.reused == 0 && m.plan?.missing == 4 && calls("questions") == 0, "plan reused \(m.plan?.reused ?? -1), to generate \(m.plan?.missing ?? -1)")
            await shot("08-plan", sheet: true)
            note("ENDING PHASE 1 with the workflow unfinished (step: \(m.step.rawValue)).")
            model.prepRequest = nil; try? await Task.sleep(nanoseconds: 500_000_000)      // an open sheet would hold the app open at quit
            return
        }

        // Phase 2: a fresh process over the same data directory.
        guard let course = model.courseList.first(where: { $0.name == "STOR435" }) else { note("FAIL course missing after relaunch"); return }
        model.selection = .home
        model.openExamPrep(courseId: course.id, assessment: "Midterm 3")           // what chat's auto-open and Home both do
        check("wizard reopens", await until(5) { ExamPrepModel.current != nil })
        guard let m = ExamPrepModel.current else { return }
        check("resumes at the saved step with saved choices", m.step == .create && m.templateId == "builtin.guided" && m.plan?.missing == 4 && m.map?.topics.count == 3, "step \(m.step.rawValue)")
        check("relaunch made no model call", calls("topics") == 1 && calls("questions") == 0)
        await shot("01-resumed", sheet: true)
        m.generate(); _ = await until(30) { !m.busy }
        let setsNow = (try? ps.sets(courseId: course.id)) ?? []
        check("missing questions generated and saved", m.finished && calls("questions") >= 1 && setsNow.count == 1, "question calls \(calls("questions"))")
        guard let set = setsNow.first else { return }
        let items = (try? ps.items(setId: set.id)) ?? []
        check("set has 4 saved questions", items.filter { $0.questionId != nil }.count == 4)
        await shot("02-created", sheet: true)
        model.prepRequest = nil
        model.selection = .library; model.librarySection = .practiceSets; await shot("03-library-sets")
        check("set appears in Library search", ((try? model.librarySearch?.search("Midterm"))?.hits(.practiceSet).contains { $0.key == set.id.uuidString }) == true)
        model.selection = .courses; model.selectedCourseID = course.id; try? await Task.sleep(nanoseconds: 800_000_000); model.courseTabRequest = "practice"; await shot("04-course-practice")
        let guided = (try? model.templates?.template("builtin.guided")) ?? .guided
        model.startSetSession(setId: set.id, template: guided)
        check("practice session begins", model.activeSessionID != nil)
        let sid = model.activeSessionID
        if let sid, let its = try? practice.items(sessionId: sid).first {
            var r = PracticeResponse(); r.selected = ["a"]
            if let a = try? practice.submit(itemId: its.id, response: r) { _ = try? ev.evaluate(attemptId: a.id) }
        }
        await shot("05-session")
        model.activeSessionID = nil; try? await Task.sleep(nanoseconds: 500_000_000)
        model.startSetSession(setId: set.id, template: guided)
        let p1 = try? ps.progress(setId: set.id)
        check("exit then resume returns to the same attempt with its answer", model.activeSessionID == sid && p1?.answered == 1 && p1?.total == 4, "answered \(p1?.answered ?? -1)/\(p1?.total ?? -1)")
        model.activeSessionID = nil
        // Edit the set while the attempt exists.
        let extra = (try? qs.create(courseId: course.id, spec: QuestionSpec(type: .shortAnswer, title: "Extra question", difficulty: 2, learningObjective: "x", content: [.markdown("Name the estimator.")], answer: AnswerSpec(accepted: ["mle"]), evaluation: EvaluationSpec(method: .exact))))?.id
        if let extra { try? ps.add(questionId: extra, to: set.id) }
        let p2 = try? ps.progress(setId: set.id), sessionItems = sid.flatMap { try? practice.items(sessionId: $0).count }
        check("editing the set leaves the existing attempt unchanged", p2?.answered == 1 && p2?.total == 4 && p2?.stale == true && sessionItems == 4 && ((try? ps.items(setId: set.id).count) ?? 0) == 5, "attempt \(p2?.answered ?? -1)/\(p2?.total ?? -1), set now \((try? ps.items(setId: set.id).count) ?? -1) questions")
        let before = calls("questions")
        try? ps.update(setId: set.id, templateId: "builtin.flashcards")
        check("switching template makes no model call", calls("questions") == before && calls("topics") == 1)
        // Reuse: a second assessment reuses saved questions.
        if let co = model.chat.map({ ExamPrepCoordinator($0.ctx) }), let j = try? co.start(course: course, assessmentName: "Midterm 4"), let plan = try? co.plan(j.id, count: 4) {
            check("existing questions are reused before generating", plan.reused > 0, "same-shape plan: reused \(plan.reused), to generate \(plan.missing)")
            if let p3 = try? co.plan(j.id, count: 3) { note("INFO a 3-question plan has different topic/archetype slots: reused \(p3.reused), to generate \(p3.missing) (reuse never takes loosely related questions)") }
        } else { check("reuse plan", false) }
        // Source change invalidates only the analysis.
        let f = dir.appendingPathComponent("extra-notes.txt"); try? "Bootstrap resampling estimates the sampling distribution.".write(to: f, atomically: true, encoding: .utf8); _ = try? docs.importFile(at: f, courseId: course.id)
        if let co = model.chat.map({ ExamPrepCoordinator($0.ctx) }), let j = co.existingJob(courseId: course.id, assessmentName: "Midterm 3") {
            let stale = (try? co.materials(courseId: course.id, job: j))?.analysisStale == true
            check("changed source marks analysis stale", stale)
            _ = try? await co.analyze(j.id)
            check("only the topic analysis reran", calls("topics") == 2 && calls("questions") == before, "topic calls \(calls("topics"))")
            check("template choice and saved questions survived", ((try? co.job(j.id))?.state.templateId) == "builtin.guided" && ((try? ps.items(setId: set.id).count) ?? 0) == 5)
        }
        // Delete / restore.
        try? ps.delete(setId: set.id)
        let trash = (try? lib.recentlyDeleted()) ?? []
        check("deleted set is in Library → Recently Deleted", trash.contains { $0.ref.kind == .practiceSet && $0.ref.id == set.id })
        model.selection = .library; model.librarySection = .recentlyDeleted; model.reload(); await shot("06-recently-deleted")
        if let item = trash.first(where: { $0.ref.id == set.id }) { try? lib.restore(item.ref) }
        check("restore brings the set back with its attempt", ((try? ps.sets(courseId: course.id))?.contains { $0.id == set.id }) == true && (try? ps.progress(setId: set.id))?.answered == 1)
        try? lib.deleteCourse(course.id); model.reload()
        check("deleted course disappears", !model.courseList.contains { $0.id == course.id })
        try? lib.restore(LibraryRef(id: course.id, kind: .courseFolder)); model.reload()
        check("restored course keeps its practice set and progress", model.courseList.contains { $0.id == course.id } && (try? ps.progress(setId: set.id))?.answered == 1)
        note("FINAL model calls — topics \(calls("topics")), questions \(calls("questions")), summary \(calls("summary"))")

        // Summaries: reuse before generating.
        model.openSummaries(courseId: course.id)
        try? await Task.sleep(nanoseconds: 1_000_000_000)
        if let svc = model.noteSummaries, let cand = try? svc.candidates(courseId: course.id), let first = cand.first {
            let r1 = try? await svc.summarize(documentIds: [first.id]); let r2 = try? await svc.summarize(documentIds: [first.id])
            check("summary generated once then reused", r1?.generated == 1 && r2?.reused == 1 && r2?.modelCalls == 0 && calls("summary") == 1, "summary calls \(calls("summary"))")
        }
        await shot("07-summaries", sheet: true)
        model.summaryRequest = nil
    }

    /// Universal Library and course Practice tab screenshots on the demo workspace. Only with BRAINCELL_UNI_SNAP and a throwaway BRAINCELL_DATA_DIR.
    static func universalScenario(_ model: AppModel, dir: URL) async {
        guard ProcessInfo.processInfo.environment["BRAINCELL_DATA_DIR"] != nil else { return }
        model.loadDemo()
        func shot(_ name: String) async {
            try? await Task.sleep(nanoseconds: 1_800_000_000)
            guard let v = NSApp.windows.first(where: { $0.isVisible && $0.contentView != nil })?.contentView, let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) else { return }
            v.cacheDisplay(in: v.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: dir.appendingPathComponent("\(name).png"))
        }
        if let c = model.courseList.first, let ps = model.practiceSets, let p = model.practice, let ev = model.evaluation, let ids = try? p.questionIds(courseId: c.id), ids.count >= 5 {
            if let a = try? ps.createEmpty(courseId: c.id, title: "Midterm 2 review", templateId: LearningTemplate.interactive.id) {
                for q in ids.prefix(4) { try? ps.add(questionId: q, to: a.id) }
                if let r = try? ps.startSession(setId: a.id, template: .interactive, templates: model.templates!), let its = try? p.items(sessionId: r.session.id) {
                    for it in its.prefix(2) { var x = PracticeResponse(); x.text = "7"; x.selected = ["a"]; if let at = try? p.submit(itemId: it.id, response: x) { _ = try? ev.evaluate(attemptId: at.id) } }
                }
                try? ps.add(questionId: ids[4], to: a.id)                                    // edited after the attempt began
            }
            if let b = try? ps.createEmpty(courseId: c.id, title: "Iterators warm-up", templateId: "builtin.flashcards") { for q in ids.suffix(3) { try? ps.add(questionId: q, to: b.id) } }
            model.reload()
        }
        model.selection = .library
        for s in [LibrarySection.all, .materials, .questions, .practiceSets, .templates] { model.librarySection = s; await shot("u-\(s.rawValue.replacingOccurrences(of: " ", with: ""))") }
        if let c = model.courseList.first { model.selectedCourseID = c.id; model.selection = .courses; try? await Task.sleep(nanoseconds: 1_500_000_000); model.courseTabRequest = "practice"; await shot("u-coursePractice") }
        model.selection = .home; model.selectedCourseID = model.courseList.first?.id
        model.openExamPrep(courseId: model.courseList.first?.id, assessment: "Midterm 2")
        try? await Task.sleep(nanoseconds: 2_000_000_000)
        if let w = NSApp.windows.first(where: { $0.isVisible && $0.attachedSheet != nil }), let sv = w.attachedSheet?.contentView, let rep = sv.bitmapImageRepForCachingDisplay(in: sv.bounds) {
            sv.cacheDisplay(in: sv.bounds, to: rep); try? rep.representation(using: .png, properties: [:])?.write(to: dir.appendingPathComponent("u-prepWizard.png"))
        }
        model.prepRequest = nil
        model.selection = .home; await shot("u-home")
    }

    /// Post-submission review screens: a wrong and a right answer on a question with per-option explanations (multiline code option included), an old
    /// question without them, and a seeded tutor conversation. Only with BRAINCELL_REVIEW_SNAP and a throwaway BRAINCELL_DATA_DIR.
    static func reviewScenario(_ model: AppModel, dir: URL) async {
        guard ProcessInfo.processInfo.environment["BRAINCELL_DATA_DIR"] != nil else { return }
        model.loadDemo()
        guard let c = model.courseList.first, let qs = model.questions, let p = model.practice, let ev = model.evaluation, let tutor = model.tutorService, let db = model.db else { return }
        func shot(_ name: String) async {
            await shot1(name, bottom: false); await shot1(name + "-bottom", bottom: true)
        }
        func shot1(_ name: String, bottom: Bool) async {
            if bottom, let v = NSApp.windows.first(where: { $0.isVisible })?.contentView {
                func scrollers(_ v: NSView) -> [NSScrollView] { (v as? NSScrollView).map { [$0] } ?? [] + v.subviews.flatMap(scrollers) }
                if let sv = scrollers(v).max(by: { $0.frame.height < $1.frame.height }), let doc = sv.documentView { doc.scroll(NSPoint(x: 0, y: doc.isFlipped ? max(0, doc.bounds.height - sv.contentView.bounds.height) : 0)) }
            }
            try? await Task.sleep(nanoseconds: 1_800_000_000)
            guard let v = NSApp.windows.first(where: { $0.isVisible && $0.contentView != nil })?.contentView, let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) else { return }
            v.cacheDisplay(in: v.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: dir.appendingPathComponent("\(name).png"))
        }
        let cs = [("a", "class Box<T> { T item; T get() { return item; } }", "Declares T and uses it for both the field and the return type, so no cast is needed."),
                  ("b", "class Box { T item; }", "Uses T without declaring a type parameter, so it does not compile."),
                  ("c", "class Box<T> {\n    Object item;\n    T get() { return item; }\n}", "Stores an Object, which cannot be returned as T without a cast."),
                  ("d", "class Box<T> { Object get() { return null; } }", "Returns Object, so callers lose the generic return type.")]
        let spec = QuestionSpec(type: .singleChoice, title: "Declaring a generic container", difficulty: 3, learningObjective: "generics",
                                content: [.markdown("Which declaration of a generic `Box` compiles and keeps the item’s type?")],
                                answer: AnswerSpec(choices: cs.map { Choice(id: $0.0, text: $0.1, why: $0.2) }, correctIds: ["a"]), evaluation: EvaluationSpec(method: .choice),
                                solution: [.markdown("A type parameter must be declared before use.")])
        guard let q = try? qs.create(courseId: c.id, spec: spec) else { return }
        let old = (try? qs.list(QuestionFilter()))?.first { $0.title.hasPrefix("Which call removes") }?.id
        func session(_ id: UUID, pick: String, title: String) -> UUID? {
            guard let s = try? p.start(questionIds: [id], title: title, courseId: c.id), let it = try? p.items(sessionId: s.id).first else { return nil }
            var r = PracticeResponse(); r.selected = [pick]
            if let a = try? p.submit(itemId: it.id, response: r) {
                _ = try? ev.evaluate(attemptId: a.id)
                if title.hasPrefix("Wrong") {
                    try? db.write { d in
                        try TutorMessage(id: UUID(), attemptId: a.id, questionId: id, role: "user", content: "Why is my answer wrong?", createdAt: Date()).insert(d)
                        try TutorMessage(id: UUID(), attemptId: a.id, questionId: id, role: "assistant", content: "Option C stores the value as `Object`:\n\n```java\nObject item;\nT get() { return item; } // error: Object cannot convert to T\n```\n\nA field of type `T` keeps the type; \\(T\\) is only known to the compiler, so an `Object` needs an unchecked cast.", createdAt: Date().addingTimeInterval(1)).insert(d)
                    }
                }
            }
            return s.id
        }
        _ = tutor
        model.snapshotIndex = nil
        if let sid = session(q.id, pick: "c", title: "Wrong pick") { model.activeSessionID = sid; await shot("r1-wrong"); model.activeSessionID = nil }
        if let sid = session(q.id, pick: "a", title: "Right pick") { model.activeSessionID = sid; await shot("r2-right"); model.activeSessionID = nil }
        if let o = old, let sid = session(o, pick: "b", title: "Old question") { model.activeSessionID = sid; await shot("r3-old"); model.activeSessionID = nil }
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

        model.selectedCourseID = c.id; model.selection = .library
        await shot("31-library")

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
        guard let c = model.courseList.first, let p = model.practice, let rows = try? model.questions?.list(QuestionFilter()), model.evaluation != nil else { log.append("FAIL setup"); return }
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

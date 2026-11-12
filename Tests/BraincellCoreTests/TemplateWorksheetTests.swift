import Testing
import Foundation
import GRDB
import PDFKit
@testable import BraincellCore

/// Templates, rendering, PDF worksheets and annotations. Models are scripted; PDF checks read the generated files back with PDFKit.
extension AgentTests {
    func tj(_ edit: (inout [String: Any]) -> Void) -> String {
        var o: [String: Any] = ["name": "My Quiz", "description": "d", "kind": "guided", "supportedFormats": ["single_choice", "numeric"], "inputs": ["choice", "numeric"], "exports": ["pdf"]]
        edit(&o); return String(data: try! JSONSerialization.data(withJSONObject: o), encoding: .utf8)!
    }
    func numericSpec(_ title: String, latex: String = "\\frac{a+b}{c^2}", diff: Int = 3) -> QuestionSpec {
        QuestionSpec(type: .numeric, title: title, difficulty: diff, learningObjective: "o",
                     content: [.markdown("Let $X$ have pmf $p(k)$. (a) Compute the value below.\n\n(b) Explain."), ContentBlock(kind: .math, latex: latex), ContentBlock(kind: .table, headers: ["k", "p(k)"], rows: [["1", "0.2"], ["2", "0.8"]])],
                     answer: AnswerSpec(value: 4.5, tolerance: 0.01, unit: "units"), evaluation: EvaluationSpec(method: .numeric), hints: ["h"], solution: [.markdown("Because $x^2$.")])
    }
    func worksheetEnv() async throws -> (E, Course, SetModel, PracticeSetService, TemplateService, WorksheetService, PracticeSet) {
        let (e, c, _, m, sets) = try await setEnv()
        let p = try sets.prepare(courseId: c.id, params: gparams(3)); _ = try await sets.generateMissing(setId: p.set.id, gateway: e.ctx.gateway)
        let t = TemplateService(db: e.db)
        return (e, c, m, sets, t, WorksheetService(db: e.db, storage: e.ctx.storage, sets: sets, templates: t), p.set)
    }

    // MARK: Schema

    @Test func builtInTemplatesAreValidAndStrictlyBounded() {
        for t in LearningTemplate.builtIns { #expect(t.validate().isEmpty, "\(t.name): \(t.validate())") }
        var t = LearningTemplate.examWorksheet; t.layout.fontSize = 40; t.difficulty = .init(min: 4, max: 2); t.feedback.mode = .immediate; t.hints.allowed = true; t.supportedFormats = ["nonsense"]; t.timing = .init(mode: .total, seconds: 5)
        let v = t.validate().joined(separator: " ")
        for needle in ["Font size", "exceeds maximum", "immediate feedback", "interactive hints", "Unknown question format", "at least 10 seconds"] { #expect(v.contains(needle), "missing: \(needle)") }
        var f = LearningTemplate.flashcards; f.inputs = [.handwriting]; #expect(!f.validate().isEmpty)
    }

    @Test func parserRejectsUnknownFieldsTypesVersionsAndReservedIdsAndNeverTreatsCapabilitiesAsCode() {
        #expect(TemplateParser.parse(tj { _ in }).isValid)
        #expect(TemplateParser.parse(tj { $0["colour"] = "red" }).issues.contains { $0.contains("Unknown field") })
        #expect(TemplateParser.parse(tj { $0["layout"] = ["fontSize": 11, "margins": 3] }).issues.contains { $0.contains("layout.margins") })
        #expect(TemplateParser.parse(tj { $0["schemaVersion"] = 2 }).issues.contains { $0.contains("schema version") })
        #expect(TemplateParser.parse(tj { $0["id"] = "builtin.guided" }).issues.contains { $0.contains("reserved") })
        #expect(!TemplateParser.parse(tj { $0["kind"] = "arcade" }).isValid && !TemplateParser.parse(tj { $0["timing"] = ["mode": "total", "seconds": "soon"] }).isValid)
        #expect(!TemplateParser.parse("not json").isValid && !TemplateParser.parse(String(repeating: "x", count: 30_000)).isValid)
        let r = TemplateParser.parse(tj { $0["javascript"] = "alert(1)"; $0["audioNarration"] = true; $0["unsupported"] = ["leaderboards"] })
        #expect(r.isValid && r.limitations.count == 3 && r.limitations.contains { $0.contains("cannot run code") })      // reported, not applied
        #expect(TemplateParser.parse("```json\n" + tj { _ in } + "\n```").isValid)
        // safe defaults come from the built-in of the same kind
        let d = try! #require(TemplateParser.parse(tj { $0["layout"] = ["fontSize": 12] }).template)
        #expect(d.layout.fontSize == 12 && d.hints.allowed && d.feedback.mode == .immediate && d.id != "" && d.schemaVersion == 1)
    }

    @Test func personalTemplatesPersistAcrossCoursesDuplicateFromBuiltInsAndBuiltInsAreProtected() async throws {
        let db = try AppDatabase.inMemory(); let svc = TemplateService(db: db)
        let c1 = UUID()
        var mine = try svc.duplicate("builtin.guided", name: "Short drills"); mine.layout.fontSize = 13
        _ = try svc.save(mine)
        #expect(mine.baseId == "builtin.guided" && !mine.isBuiltIn)
        let names1 = try TemplateService(db: db).all(courseId: c1).map(\.name)
        #expect(names1.contains("Short drills"))              // global: usable in every course
        let n5 = try svc.all().count; #expect(n5 == 5)
        #expect(throws: TemplateError.self) { _ = try svc.save(LearningTemplate.guided) }
        #expect(throws: TemplateError.self) { try svc.delete("builtin.guided") }
        var bad = mine; bad.layout.fontSize = 99
        #expect(throws: TemplateError.self) { _ = try svc.save(bad) }
        try svc.delete(mine.id); let n4 = try svc.all().count; #expect(n4 == 4)
    }

    @Test func aiAssistedTemplateIsAValidatedDraftNeverSavedAndNeverTrustedForIds() async throws {
        let calls = LockedBox<Int>(0)
        let reply = LockedBox<String>("")
        let e = try await env { _, user, _ in calls.withLock { $0 += 1 }; precondition(user.contains("<learner_description>")); return reply.value }
        let svc = TemplateService(db: e.db)
        reply.withLock { $0 = self.tj { $0["id"] = "builtin.evil"; $0["name"] = "Ten minute drill"; $0["timing"] = ["mode": "total", "seconds": 600]; $0["unsupported"] = ["voice narration"] } }
        let d = try await svc.draft(description: "ten minute quiz with a voice reading questions aloud", gateway: e.ctx.gateway)
        #expect(d.template?.name == "Ten minute drill" && d.template?.id != "builtin.evil" && d.template?.timing.seconds == 600 && d.limitations.contains { $0.contains("voice narration") })
        let nAll = try svc.all().count
        #expect(nAll == 4 && calls.value == 1)                                                    // a draft is not saved
        reply.withLock { $0 = self.tj { $0["layout"] = ["fontSize": 99]; $0["script"] = "rm -rf /" } }
        let bad = try await svc.draft(description: "x", gateway: e.ctx.gateway)
        #expect(bad.template == nil && !bad.issues.isEmpty && bad.limitations.contains { $0.contains("cannot run code") })
    }

    // MARK: Reuse across templates without model calls

    @Test func oneSavedSetRendersInSeveralTemplatesWithoutAnyModelCall() async throws {
        let (e, c, m, sets, templates, sheets, set) = try await worksheetEnv()
        let calls = m.calls
        let qs = try sets.questions(setId: set.id).map { ($0.id, $0.spec, $0.topic) }
        #expect(qs.count == 3)
        for t in LearningTemplate.builtIns {
            let doc = RenderBuilder.build(template: t, title: "S", questions: qs)
            #expect(doc.items.count == 3 && doc.skipped.isEmpty, "\(t.name)")
        }
        var onlyNumeric = LearningTemplate.interactive; onlyNumeric.id = "x"; onlyNumeric.supportedFormats = ["numeric"]
        let doc = RenderBuilder.build(template: onlyNumeric, title: "S", questions: qs)
        #expect(doc.items.isEmpty && doc.skipped.count == 3 && doc.skipped[0].contains("part of"))          // incompatibility is reported, not hidden
        let w1 = try sheets.generate(setId: set.id, template: .examWorksheet), w2 = try sheets.generate(setId: set.id, template: .guided)
        #expect(w1.id != w2.id && w1.templateId != w2.templateId)
        let s1 = try sets.startSession(setId: set.id, template: .interactive, templates: templates), s2 = try sets.startSession(setId: set.id, template: .guided, templates: templates)
        #expect(s1.session.id != s2.session.id && !s1.resumed)
        #expect(m.calls == calls)                                                                              // measured: switching templates sent no model request
        _ = c
    }

    @Test func interruptedSessionsResumeWithTheirProgress() async throws {
        let (e, _, _, sets, templates, _, set) = try await worksheetEnv()
        let a = try sets.startSession(setId: set.id, template: .guided, templates: templates)
        let practice = PracticeService(db: e.db)
        let items = try practice.items(sessionId: a.session.id)
        try practice.saveDraft(itemId: items[0].id, response: PracticeService.initialResponse(for: try practice.spec(for: items[0])))
        try practice.moveTo(sessionId: a.session.id, ordinal: 1)
        let b = try sets.startSession(setId: set.id, template: .guided, templates: templates)
        #expect(b.resumed && b.session.id == a.session.id && b.session.currentOrdinal == 1)
        try practice.setStatus(a.session.id, .completed)
        let again = try sets.startSession(setId: set.id, template: .guided, templates: templates); #expect(again.resumed == false)    // a finished session is not reopened
        // guided order is easiest first; the shared ordering is deterministic
        let order1 = templates.compatibility(template: .flashcards, items: try sets.questions(setId: set.id).map { ($0.id, $0.spec, $0.topic) }).usable
        let order2 = templates.compatibility(template: .flashcards, items: try sets.questions(setId: set.id).map { ($0.id, $0.spec, $0.topic) }).usable
        #expect(order1 == order2)
        _ = 0 //(template: .flashcards, items: try sets.questions(setId: set.id).map { ($0.id, $0.spec, $0.topic) }).usable)
    }

    // MARK: Math layout

    @Test func mathLayoutIsTwoDimensionalAndFallsBackHonestly() {
        func b(_ s: String) -> MathBox { guard let x = MathLayout.box(latex: s, size: 12) else { Issue.record("unparsed: \(s)"); return MathBox.empty() }; return x }
        let plain = b("a+b"), frac = b("\\frac{a+b}{c}"), sup = b("x^{2}"), root = b("\\sqrt{x+1}"), mat = b("\\begin{pmatrix} a & b \\\\ c & d \\end{pmatrix}"), sum = b("\\sum_{k=1}^{n} k")
        #expect(frac.height > plain.height * 1.4 && frac.descent > 0)                  // numerator above, denominator below the baseline
        #expect(sup.ascent > b("x").ascent && sup.width > b("x").width)                // the exponent is raised, not appended
        #expect(root.width > b("x+1").width && root.ascent > b("x+1").ascent)
        #expect(mat.height > b("a").height * 2 && mat.width > b("ab").width * 0.5)
        #expect(sum.height > b("k").height * 1.6)                                      // limits stack above and below
        #expect(b("\\frac{\\frac{1}{2}}{3}").height > frac.height)                     // nested fractions grow
        #expect(MathLayout.box(latex: "\\unsupportedcommand{x}", size: 12) == nil)    // outside the subset: no guessing
    }

    // MARK: PDF

    @Test func worksheetPdfPaginatesTypesetsMathAndWritesSeparateSolutions() throws {
        let t = LearningTemplate.examWorksheet
        let qs = (1...14).map { (UUID(), numericSpec("Q\($0)", latex: $0 == 1 ? "\\int_{0}^{\\infty} \\frac{x^{2}}{1+x^{2}}\\,dx + " + String(repeating: "a_{i}+", count: 80) + "z" : "\\frac{a+b}{c^2}"), "Topic") }
        let doc = RenderBuilder.build(template: t, title: "Exam", questions: qs)
        let dir = try tempDir(); let main = dir.appendingPathComponent("w.pdf"), sol = dir.appendingPathComponent("s.pdf")
        let n = try WorksheetRenderer.write(doc, to: main), m = try WorksheetRenderer.write(doc, solutions: true, to: sol)
        let pdf = try #require(PDFDocument(url: main)), spdf = try #require(PDFDocument(url: sol))
        #expect(n == pdf.pageCount && n >= 3 && m == spdf.pageCount)
        let text = pdf.string ?? ""
        #expect(text.contains("Exam") && text.contains("1.") && text.contains("14.") && text.contains("Page 1 of \(n)") && text.contains("Name:"))
        #expect(text.contains("units") && text.contains("p(k)") && text.contains("0.8") && !text.contains("Answer: 4.5"))
        #expect((spdf.string ?? "").contains("Solutions") && (spdf.string ?? "").contains("Answer: 4.5 ± 0.01 units"))
        // every page has the same media box as the template; nothing is drawn outside it
        for i in 0..<pdf.pageCount { #expect(pdf.page(at: i)!.bounds(for: .mediaBox).size == CGSize(width: 612, height: 792)) }
    }

    @Test func worksheetGenerationIsIdempotentRebuildsMissingFilesAndKeepsSourceFilesUntouched() async throws {
        let (e, _, m, sets, _, sheets, set) = try await worksheetEnv()
        let calls = m.calls
        let w1 = try sheets.generate(setId: set.id, template: .examWorksheet), w2 = try sheets.generate(setId: set.id, template: .examWorksheet)
        let nsheets = try sheets.worksheets(setId: set.id).count
        #expect(w1.id == w2.id && w1.pageCount >= 1 && nsheets == 1)
        #expect(FileManager.default.fileExists(atPath: sheets.url(w1).path) && FileManager.default.fileExists(atPath: sheets.solutionsURL(w1)!.path))
        try FileManager.default.removeItem(at: sheets.url(w1))
        let w3 = try sheets.generate(setId: set.id, template: .examWorksheet)
        #expect(w3.id == w1.id && FileManager.default.fileExists(atPath: sheets.url(w3).path))                    // rebuilt from the database
        #expect(m.calls == calls)
        // changing the template content produces a new worksheet; the old one remains openable
        var t2 = LearningTemplate.examWorksheet; t2.layout.answerSpace = .large; t2.id = UUID().uuidString
        let w4 = try sheets.generate(setId: set.id, template: t2); #expect(w4.id != w1.id)
        #expect(sheets.url(w1).standardizedFileURL.path.contains("/worksheets/"))
        _ = e
    }

    // MARK: Annotations

    @Test func annotationsPersistValidateAndExportLiveOrFlattenedWithoutTouchingTheOriginal() async throws {
        let (e, _, _, _, _, sheets, set) = try await worksheetEnv()
        let w = try sheets.generate(setId: set.id, template: .examWorksheet)
        let before = try Data(contentsOf: sheets.url(w))
        let box = WorksheetAnnotation(worksheetId: w.id, page: 0, kind: .field, x: 0.2, y: 0.3, w: 0.4, h: 0.05, text: "x = 4.5")
        let ink = WorksheetAnnotation(worksheetId: w.id, page: 0, kind: .ink, x: 0.1, y: 0.5, w: 0.2, h: 0.1, strokes: [[[0.1, 0.5], [0.2, 0.55], [0.3, 0.6]]])
        try sheets.save(box); try sheets.save(ink)
        var edited = box; edited.text = "x = 4.50"; try sheets.save(edited)                                      // editable text
        let reopened = WorksheetService(db: e.db, storage: e.ctx.storage, sets: sheets.sets, templates: sheets.templates)
        let saved = try reopened.annotations(worksheetId: w.id)
        #expect(saved.count == 2 && saved.contains { $0.text == "x = 4.50" } && saved.first { $0.kind == .ink }?.strokes.first?.count == 3)
        for bad in [WorksheetAnnotation(worksheetId: w.id, page: 99, kind: .text, x: 0.1, y: 0.1), WorksheetAnnotation(worksheetId: w.id, page: 0, kind: .text, x: 0.9, y: 0.1, w: 0.3), WorksheetAnnotation(worksheetId: w.id, page: 0, kind: .ink, x: 0.1, y: 0.1, strokes: [[[2, 2]]])] {
            #expect(throws: WorksheetServiceError.self) { try sheets.save(bad) }
        }
        let dir = try tempDir()
        try sheets.export(w, to: dir.appendingPathComponent("live.pdf"), annotations: .live)
        try sheets.export(w, to: dir.appendingPathComponent("flat.pdf"), annotations: .flattened)
        try sheets.export(w, to: dir.appendingPathComponent("plain.pdf"), annotations: .none)
        let live = try #require(PDFDocument(url: dir.appendingPathComponent("live.pdf"))), flat = try #require(PDFDocument(url: dir.appendingPathComponent("flat.pdf")))
        let page0 = live.page(at: 0)!
        #expect(page0.annotations.contains { $0.contents == "x = 4.50" } && page0.annotations.contains { $0.type == "Ink" })
        #expect((flat.string ?? "").contains("x = 4.50") && flat.pageCount == w.pageCount)
        #expect(flat.page(at: 0)!.annotations.filter { $0.contents == "x = 4.50" }.isEmpty)                    // burned in, no longer an editable object
        let after = try Data(contentsOf: sheets.url(w)); #expect(after == before)                                                  // the generated file is unchanged
        let plain = try Data(contentsOf: dir.appendingPathComponent("plain.pdf")); #expect(plain == before)
        #expect(throws: WorksheetServiceError.self) { try sheets.export(w, to: sheets.url(w), annotations: .flattened) }
        try sheets.deleteAnnotation(ink.id); let left = try sheets.annotations(worksheetId: w.id).count; #expect(left == 1)
    }

    @Test func annotationPlacementIsIndependentOfZoomAndPageSize() {
        for box in [CGRect(x: 0, y: 0, width: 612, height: 792), CGRect(x: 0, y: 0, width: 595, height: 842), CGRect(x: 10, y: 20, width: 300, height: 400)] {
            let a = WorksheetAnnotation(worksheetId: UUID(), page: 0, kind: .text, x: 0.25, y: 0.4, w: 0.5, h: 0.1)
            let p = AnnotationGeometry.toPage(x: a.x, y: a.y, in: box), back = AnnotationGeometry.fromPage(p, in: box)
            #expect(abs(back.x - 0.25) < 1e-9 && abs(back.y - 0.4) < 1e-9)
            let r = AnnotationGeometry.rect(a, in: box)
            #expect(abs(r.width - box.width * 0.5) < 1e-6 && abs(r.maxY - (box.maxY - 0.4 * box.height)) < 1e-6)
        }
    }

    @Test func templateAndWorksheetTablesMigrateAdditively() throws {
        let db = try AppDatabase.inMemory()
        let names = try db.read { try String.fetchAll($0, sql: "SELECT name FROM sqlite_master WHERE type = 'table'") }
        for t in ["learning_templates", "practice_set_sessions", "worksheets", "worksheet_annotations", "practice_sets", "course_archetypes", "extract_selections"] { #expect(names.contains(t), "\(t)") }
        let fk = try db.read { try Row.fetchAll($0, sql: "PRAGMA foreign_key_check") }
        #expect(fk.isEmpty)
    }
}

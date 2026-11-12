import Foundation
import GRDB
import PDFKit
import CoreGraphics
import CoreText
#if canImport(AppKit)
import AppKit
#endif

public struct Worksheet: Sendable, Equatable, Identifiable {
    public var id: UUID, setId: UUID
    public var templateId: String, contentHash: String
    public var path: String, solutionsPath: String?
    public var pageCount: Int
    public var createdAt: Date
}

public struct WorksheetAnnotation: Sendable, Equatable, Identifiable {
    public enum Kind: String, Sendable { case text, field, ink }
    public var id: UUID, worksheetId: UUID
    public var page: Int                                // 0-based
    public var kind: Kind
    public var x: Double, y: Double, w: Double, h: Double   // fraction of the page, origin top-left, so placement is independent of zoom
    public var text: String
    public var strokes: [[[Double]]]                    // ink: strokes of [x, y] points, page-normalized
    public init(id: UUID = UUID(), worksheetId: UUID, page: Int, kind: Kind, x: Double, y: Double, w: Double = 0.3, h: Double = 0.05, text: String = "", strokes: [[[Double]]] = []) {
        self.id = id; self.worksheetId = worksheetId; self.page = page; self.kind = kind; self.x = x; self.y = y; self.w = w; self.h = h; self.text = text; self.strokes = strokes
    }
}

public enum AnnotationGeometry {
    /// Page-normalized (top-left origin) → PDF page coordinates (bottom-left origin) for any media box.
    public static func toPage(x: Double, y: Double, in box: CGRect) -> CGPoint { CGPoint(x: box.minX + CGFloat(x) * box.width, y: box.maxY - CGFloat(y) * box.height) }
    public static func fromPage(_ p: CGPoint, in box: CGRect) -> (x: Double, y: Double) { (Double((p.x - box.minX) / box.width), Double((box.maxY - p.y) / box.height)) }
    public static func rect(_ a: WorksheetAnnotation, in box: CGRect) -> CGRect {
        CGRect(x: box.minX + CGFloat(a.x) * box.width, y: box.maxY - CGFloat(a.y + a.h) * box.height, width: CGFloat(a.w) * box.width, height: CGFloat(a.h) * box.height)
    }
}

public enum AnnotationExportMode: Sendable { case none, live, flattened }

public enum WorksheetServiceError: Error, LocalizedError, Equatable {
    case notFound, invalidAnnotation(String), unsafePath
    public var errorDescription: String? {
        switch self { case .notFound: "That worksheet no longer exists."; case .invalidAnnotation(let m): "Invalid annotation: \(m)"; case .unsafePath: "That location isn’t allowed." }
    }
}

public final class WorksheetService: @unchecked Sendable {
    let db: AppDatabase, root: URL
    let sets: PracticeSetService, templates: TemplateService
    public init(db: AppDatabase, storage: ManagedStorage, sets: PracticeSetService, templates: TemplateService) { self.db = db; root = storage.root.appendingPathComponent("worksheets", isDirectory: true); self.sets = sets; self.templates = templates }

    static func row(_ r: Row) -> Worksheet { Worksheet(id: r["id"], setId: r["setId"], templateId: r["templateId"], contentHash: r["contentHash"], path: r["path"], solutionsPath: r["solutionsPath"], pageCount: r["pageCount"], createdAt: r["createdAt"]) }
    public func url(_ w: Worksheet) -> URL { root.deletingLastPathComponent().appendingPathComponent(w.path) }
    public func solutionsURL(_ w: Worksheet) -> URL? { w.solutionsPath.map { root.deletingLastPathComponent().appendingPathComponent($0) } }
    public func worksheet(_ id: UUID) throws -> Worksheet? { try db.read { try Row.fetchOne($0, sql: "SELECT * FROM worksheets WHERE id = ?", arguments: [id]).map(Self.row) } }
    public func worksheets(setId: UUID) throws -> [Worksheet] { try db.read { try Row.fetchAll($0, sql: "SELECT * FROM worksheets WHERE setId = ? ORDER BY createdAt DESC", arguments: [setId]).map(Self.row) } }

    // MARK: Generate (deterministic from the saved set; no model call)

    /// Creates the worksheet for a saved set and template, or returns the existing one when nothing changed (same template, same question revisions).
    /// If the files were deleted they are rebuilt from the database, never from a model.
    @discardableResult
    public func generate(setId: UUID, template t: LearningTemplate, title: String? = nil) throws -> Worksheet {
        guard let set = try sets.practiceSet(setId) else { throw WorksheetServiceError.notFound }
        let qs = try sets.questions(setId: setId)
        let doc = RenderBuilder.build(template: t, title: title ?? set.title, questions: qs.map { ($0.id, $0.spec, $0.topic) })
        let tj = String(data: (try? { let e = JSONEncoder(); e.outputFormatting = [.sortedKeys]; return try e.encode(t) }()) ?? Data(), encoding: .utf8) ?? ""
        let hash = QuestionHashing.sha256(WorksheetRenderer.version + "|" + tj + "|" + (title ?? set.title) + "|" + qs.map { $0.revisionId.uuidString }.joined(separator: ","))
        if let ex = try db.read({ try Row.fetchOne($0, sql: "SELECT * FROM worksheets WHERE setId = ? AND contentHash = ?", arguments: [setId, hash]).map(Self.row) }) {
            if FileManager.default.fileExists(atPath: url(ex).path) { return ex }
            try writeFiles(ex, doc: doc, template: t); return ex
        }
        let rel = "worksheets/\(setId.uuidString)/\(hash.prefix(16))"
        var w = Worksheet(id: UUID(), setId: setId, templateId: t.id, contentHash: hash, path: rel + ".pdf", solutionsPath: t.exports.contains(.solutionsPdf) ? rel + "-solutions.pdf" : nil, pageCount: 0, createdAt: Date())
        w.pageCount = try writeFiles(w, doc: doc, template: t)
        try db.write { try $0.execute(sql: "INSERT OR IGNORE INTO worksheets (id, setId, templateId, contentHash, path, solutionsPath, pageCount, createdAt) VALUES (?,?,?,?,?,?,?,?)", arguments: [w.id, w.setId, w.templateId, w.contentHash, w.path, w.solutionsPath, w.pageCount, w.createdAt]) }
        return try db.read { try Row.fetchOne($0, sql: "SELECT * FROM worksheets WHERE setId = ? AND contentHash = ?", arguments: [setId, hash]).map(Self.row) } ?? w
    }

    @discardableResult
    func writeFiles(_ w: Worksheet, doc: RenderDocument, template t: LearningTemplate) throws -> Int {
        let main = url(w)
        guard main.standardizedFileURL.path.hasPrefix(root.standardizedFileURL.path) else { throw WorksheetServiceError.unsafePath }      // generated files only live under worksheets/
        let n = try WorksheetRenderer.write(doc, solutions: false, to: main)
        if let s = solutionsURL(w) { try WorksheetRenderer.write(doc, solutions: true, to: s) }
        return n
    }

    // MARK: Annotations (separate from generated content)

    static func validate(_ a: WorksheetAnnotation, pages: Int) throws {
        guard (0..<max(pages, 1)).contains(a.page) else { throw WorksheetServiceError.invalidAnnotation("page out of range") }
        guard [a.x, a.y, a.w, a.h].allSatisfy({ $0.isFinite }), a.x >= 0, a.y >= 0, a.w > 0, a.h > 0, a.x + a.w <= 1.0001, a.y + a.h <= 1.0001 else { throw WorksheetServiceError.invalidAnnotation("outside the page") }
        guard a.text.count <= 2_000 else { throw WorksheetServiceError.invalidAnnotation("text is too long") }
        guard a.strokes.count <= 400, a.strokes.allSatisfy({ $0.count <= 4_000 && $0.allSatisfy { $0.count == 2 && $0.allSatisfy { $0.isFinite && $0 >= 0 && $0 <= 1 } } }) else { throw WorksheetServiceError.invalidAnnotation("drawing is too large or outside the page") }
    }

    public func save(_ a: WorksheetAnnotation) throws {
        guard let w = try worksheet(a.worksheetId) else { throw WorksheetServiceError.notFound }
        try Self.validate(a, pages: w.pageCount)
        let stroke = a.strokes.isEmpty ? nil : String(data: try JSONEncoder().encode(a.strokes), encoding: .utf8)
        try db.write { try $0.execute(sql: """
            INSERT INTO worksheet_annotations (id, worksheetId, page, kind, x, y, w, h, text, strokeJSON, createdAt, updatedAt) VALUES (?,?,?,?,?,?,?,?,?,?,?,?)
            ON CONFLICT(id) DO UPDATE SET page = excluded.page, x = excluded.x, y = excluded.y, w = excluded.w, h = excluded.h, text = excluded.text, strokeJSON = excluded.strokeJSON, updatedAt = excluded.updatedAt
            """, arguments: [a.id, a.worksheetId, a.page, a.kind.rawValue, a.x, a.y, a.w, a.h, a.text, stroke, Date(), Date()]) }
    }
    public func deleteAnnotation(_ id: UUID) throws { try db.write { try $0.execute(sql: "DELETE FROM worksheet_annotations WHERE id = ?", arguments: [id]) } }
    public func annotations(worksheetId: UUID) throws -> [WorksheetAnnotation] {
        try db.read { try Row.fetchAll($0, sql: "SELECT * FROM worksheet_annotations WHERE worksheetId = ? ORDER BY page, createdAt, rowid", arguments: [worksheetId]).map { r in
            WorksheetAnnotation(id: r["id"], worksheetId: r["worksheetId"], page: r["page"], kind: Kind(rawValue: r["kind"]) ?? .text, x: r["x"], y: r["y"], w: r["w"], h: r["h"], text: r["text"],
                                strokes: (r["strokeJSON"] as String?).flatMap { try? JSONDecoder().decode([[[Double]]].self, from: Data($0.utf8)) } ?? [])
        } }
    }
    typealias Kind = WorksheetAnnotation.Kind

    // MARK: Export

    /// Writes a copy of the worksheet. The generated file and the stored annotations are never modified. `.live` keeps annotations editable in other
    /// PDF viewers; `.flattened` burns them into the page content.
    public func export(_ w: Worksheet, to dest: URL, annotations mode: AnnotationExportMode, solutions: Bool = false) throws {
        guard let src = solutions ? solutionsURL(w) : Optional(url(w)), FileManager.default.fileExists(atPath: src.path) else { throw WorksheetServiceError.notFound }
        guard dest.standardizedFileURL != src.standardizedFileURL else { throw WorksheetServiceError.unsafePath }
        try FileManager.default.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
        let notes = solutions || mode == .none ? [] : try annotations(worksheetId: w.id)
        if notes.isEmpty { if FileManager.default.fileExists(atPath: dest.path) { try FileManager.default.removeItem(at: dest) }; try FileManager.default.copyItem(at: src, to: dest); return }
        guard let doc = PDFDocument(url: src) else { throw WorksheetServiceError.notFound }
        if mode == .live { try Self.addLive(notes, to: doc); guard doc.write(to: dest) else { throw WorksheetError.cannotCreate("could not write the annotated copy") } }
        else { try Self.flatten(notes, from: doc, to: dest) }
    }

    static func addLive(_ notes: [WorksheetAnnotation], to doc: PDFDocument) throws {
        for a in notes {
            guard let page = doc.page(at: a.page) else { continue }
            let box = page.bounds(for: .mediaBox)
            switch a.kind {
            case .text, .field:
                let ann = PDFAnnotation(bounds: AnnotationGeometry.rect(a, in: box), forType: .freeText, withProperties: nil)
                ann.contents = a.text; ann.font = NSFont(name: "Helvetica", size: 11) ?? .systemFont(ofSize: 11); ann.fontColor = .black
                ann.color = a.kind == .field ? NSColor(calibratedRed: 1, green: 0.98, blue: 0.8, alpha: 1) : .clear
                if a.kind == .field { let b = PDFBorder(); b.lineWidth = 0.8; ann.border = b }
                page.addAnnotation(ann)
            case .ink:
                for s in a.strokes where s.count > 1 {
                    let pts = s.map { AnnotationGeometry.toPage(x: $0[0], y: $0[1], in: box) }
                    let r = pts.reduce(CGRect.null) { $0.union(CGRect(origin: $1, size: .zero)) }.insetBy(dx: -2, dy: -2)
                    let path = NSBezierPath(); path.move(to: CGPoint(x: pts[0].x - r.minX, y: pts[0].y - r.minY)); for p in pts.dropFirst() { path.line(to: CGPoint(x: p.x - r.minX, y: p.y - r.minY)) }
                    let ann = PDFAnnotation(bounds: r, forType: .ink, withProperties: nil); ann.color = .black; let b = PDFBorder(); b.lineWidth = 1.5; ann.border = b; ann.add(path)
                    page.addAnnotation(ann)
                }
            }
        }
    }

    static func flatten(_ notes: [WorksheetAnnotation], from doc: PDFDocument, to dest: URL) throws {
        guard let first = doc.page(at: 0) else { throw WorksheetServiceError.notFound }
        var box0 = first.bounds(for: .mediaBox)
        guard let ctx = CGContext(dest as CFURL, mediaBox: &box0, [kCGPDFContextCreator: "Learn Anyway export"] as CFDictionary) else { throw WorksheetError.cannotCreate("no drawing context") }
        for i in 0..<doc.pageCount {
            guard let page = doc.page(at: i) else { continue }
            var box = page.bounds(for: .mediaBox)
            ctx.beginPDFPage([kCGPDFContextMediaBox as String: Data(bytes: &box, count: MemoryLayout<CGRect>.size)] as CFDictionary)
            page.draw(with: .mediaBox, to: ctx)
            ctx.setFillColor(CGColor(gray: 0, alpha: 1)); ctx.setStrokeColor(CGColor(gray: 0, alpha: 1))
            for a in notes where a.page == i {
                let r = AnnotationGeometry.rect(a, in: box)
                switch a.kind {
                case .text, .field:
                    if a.kind == .field { ctx.setLineWidth(0.8); ctx.stroke(r) }
                    let attr = NSAttributedString(string: a.text, attributes: [.font: MathLayout.font(11), NSAttributedString.Key(kCTForegroundColorFromContextAttributeName as String): true])
                    let fs = CTFramesetterCreateWithAttributedString(attr)
                    let frame = CTFramesetterCreateFrame(fs, CFRange(location: 0, length: 0), CGPath(rect: r.insetBy(dx: 2, dy: 2), transform: nil), nil)
                    CTFrameDraw(frame, ctx)
                case .ink:
                    ctx.setLineWidth(1.5); ctx.setLineCap(.round); ctx.setLineJoin(.round)
                    for s in a.strokes where s.count > 1 {
                        let pts = s.map { AnnotationGeometry.toPage(x: $0[0], y: $0[1], in: box) }
                        ctx.move(to: pts[0]); for p in pts.dropFirst() { ctx.addLine(to: p) }; ctx.strokePath()
                    }
                }
            }
            ctx.endPDFPage()
        }
        ctx.closePDF()
    }
}

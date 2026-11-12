import SwiftUI
import PDFKit
import BraincellCore

enum AnnotationTool: String, CaseIterable, Identifiable { case select = "Select", text = "Text", field = "Answer field", draw = "Draw"; var id: String { rawValue } }

/// PDFView that turns clicks and drags into page-normalized annotations. Positions are stored as fractions of the page, so they stay put at any zoom.
final class AnnotatingPDFView: PDFView {
    var tool: AnnotationTool = .select
    var onPlace: ((Int, CGPoint) -> Void)?                 // page index, normalized (top-left origin)
    var onStroke: ((Int, [CGPoint]) -> Void)?
    private var stroke: [CGPoint] = []
    private var strokePage: PDFPage?

    private func hit(_ e: NSEvent) -> (PDFPage, CGPoint)? {
        let p = convert(e.locationInWindow, from: nil)
        guard let page = page(for: p, nearest: false) else { return nil }
        return (page, convert(p, to: page))
    }
    private func normalized(_ pt: CGPoint, _ page: PDFPage) -> CGPoint {
        let n = AnnotationGeometry.fromPage(pt, in: page.bounds(for: .mediaBox)); return CGPoint(x: n.x, y: n.y)
    }
    override func mouseDown(with e: NSEvent) {
        switch tool {
        case .select: super.mouseDown(with: e)
        case .text, .field: if let (page, pt) = hit(e), let doc = document { onPlace?(doc.index(for: page), normalized(pt, page)) }
        case .draw: if let (page, pt) = hit(e) { strokePage = page; stroke = [normalized(pt, page)] }
        }
    }
    override func mouseDragged(with e: NSEvent) {
        guard tool == .draw, let page = strokePage else { super.mouseDragged(with: e); return }
        let p = convert(e.locationInWindow, from: nil)
        stroke.append(normalized(convert(p, to: page), page))
    }
    override func mouseUp(with e: NSEvent) {
        guard tool == .draw, let page = strokePage, let doc = document else { super.mouseUp(with: e); return }
        if stroke.count > 1 { onStroke?(doc.index(for: page), stroke) }
        stroke = []; strokePage = nil
    }
}

struct WorksheetPDFView: NSViewRepresentable {
    let url: URL
    let annotations: [WorksheetAnnotation]
    let tool: AnnotationTool
    let onPlace: (Int, CGPoint) -> Void
    let onStroke: (Int, [CGPoint]) -> Void
    let onReady: (PDFView) -> Void

    func makeNSView(context: Context) -> AnnotatingPDFView {
        let v = AnnotatingPDFView(); v.autoScales = true; v.displayMode = .singlePageContinuous; v.displaysPageBreaks = true
        v.document = PDFDocument(url: url); onReady(v); return v
    }
    func updateNSView(_ v: AnnotatingPDFView, context: Context) {
        v.tool = tool; v.onPlace = onPlace; v.onStroke = onStroke
        guard let doc = v.document else { return }
        for i in 0..<doc.pageCount { if let p = doc.page(at: i) { for a in p.annotations where a.userName?.hasPrefix(WorksheetService.liveTag) == true { p.removeAnnotation(a) } } }
        try? WorksheetService.addLive(annotations, to: doc)                                    // redraw exactly what is stored
        v.setNeedsDisplay(v.bounds)
    }
}

/// The generated worksheet with answer annotations. Annotations live in the database apart from the PDF; export chooses live, flattened or none.
struct WorksheetSheet: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let worksheet: Worksheet
    let title: String
    @State private var notes: [WorksheetAnnotation] = []
    @State private var tool: AnnotationTool = .select
    @State private var pending: (page: Int, point: CGPoint, kind: WorksheetAnnotation.Kind)?
    @State private var draft = ""
    @State private var editing: WorksheetAnnotation?
    @State private var pdf: PDFView?
    @State private var showSolutions = false

    private var url: URL? { model.worksheets.flatMap { showSolutions ? $0.solutionsURL(worksheet) : $0.url(worksheet) } }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: Theme.Space.md) {
                Text(title).font(Theme.sectionTitle).lineLimit(1)
                Spacer()
                if !showSolutions { SegmentedControl(selection: $tool, options: AnnotationTool.allCases) { $0.rawValue } }
                if worksheet.solutionsPath != nil { Toggle("Solutions", isOn: $showSolutions).toggleStyle(.switch).controlSize(.small) }
                Menu {
                    Button("Export PDF (answers editable)…") { export(.live) }
                    Button("Export PDF (answers flattened)…") { export(.flattened) }
                    Button("Export blank worksheet…") { export(.none) }
                    if worksheet.solutionsPath != nil { Button("Export solutions PDF…") { export(.none, solutions: true) } }
                    Divider()
                    Button("Print…") { printIt() }
                    Button("Show in Finder") { if let u = model.worksheets?.url(worksheet) { NSWorkspace.shared.activateFileViewerSelecting([u]) } }
                } label: { Label("Export", systemImage: "square.and.arrow.up") }.menuStyle(.button).fixedSize()
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }.padding(Theme.Space.md)
            Divider()
            HStack(spacing: 0) {
                if let url {
                    WorksheetPDFView(url: url, annotations: showSolutions ? [] : notes, tool: showSolutions ? .select : tool,
                                     onPlace: { page, pt in pending = (page, pt, tool == .field ? .field : .text); draft = "" },
                                     onStroke: { page, pts in addStroke(page, pts) }, onReady: { pdf = $0 })
                } else { Text("The worksheet file is missing.").frame(maxWidth: .infinity) }
                Divider()
                annotationList.frame(width: 220)
            }
        }
        .frame(minWidth: 860, minHeight: 640)
        .onAppear { reloadNotes() }
        .sheet(isPresented: Binding(get: { pending != nil || editing != nil }, set: { if !$0 { pending = nil; editing = nil } })) {
            VStack(alignment: .leading, spacing: Theme.Space.md) {
                Text(editing == nil ? "Add text" : "Edit text").font(Theme.sectionTitle)
                TextField("Your answer", text: $draft, axis: .vertical).lineLimit(3...8)
                HStack { Spacer(); Button("Cancel") { pending = nil; editing = nil }.keyboardShortcut(.cancelAction); Button("Save") { commitText() }.buttonStyle(.primary).keyboardShortcut(.defaultAction).disabled(draft.trimmed.isEmpty) }
            }.dialogSurface(width: 420)
        }
    }

    private var annotationList: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Answers on this worksheet").font(.callout.weight(.semibold)).padding([.horizontal, .top], 10)
            if notes.isEmpty { Text("Choose Text or Answer field, then click the page. Choose Draw to write with the mouse or a stylus.").font(.caption).foregroundStyle(Theme.textSecondary).padding(.horizontal, 10) }
            List(notes) { n in
                HStack {
                    VStack(alignment: .leading) { Text(n.kind == .ink ? "Drawing" : n.text).lineLimit(2); Text("Page \(n.page + 1)").font(.caption2).foregroundStyle(Theme.textSecondary) }
                    Spacer()
                    if n.kind != .ink { Button { editing = n; draft = n.text } label: { Image(systemName: "pencil") }.buttonStyle(.plain).accessibilityLabel("Edit") }
                    Button { delete(n) } label: { Image(systemName: "trash") }.buttonStyle(.plain).accessibilityLabel("Delete")
                }
            }
        }
    }

    private func reloadNotes() { notes = (try? model.worksheets?.annotations(worksheetId: worksheet.id)) ?? [] }
    private func save(_ a: WorksheetAnnotation) { do { try model.worksheets?.save(a) } catch { model.alertMessage = error.localizedDescription }; reloadNotes() }
    private func delete(_ a: WorksheetAnnotation) { try? model.worksheets?.deleteAnnotation(a.id); reloadNotes() }
    private func commitText() {
        if var e = editing { e.text = draft; save(e) }
        else if let p = pending {
            let w = p.kind == .field ? 0.4 : 0.35, h = p.kind == .field ? 0.05 : 0.04
            save(WorksheetAnnotation(worksheetId: worksheet.id, page: p.page, kind: p.kind, x: min(max(0, p.point.x), 1 - w), y: min(max(0, p.point.y), 1 - h), w: w, h: h, text: draft))
        }
        pending = nil; editing = nil
    }
    private func addStroke(_ page: Int, _ pts: [CGPoint]) {
        let xs = pts.map(\.x), ys = pts.map(\.y); guard let x0 = xs.min(), let x1 = xs.max(), let y0 = ys.min(), let y1 = ys.max() else { return }
        save(WorksheetAnnotation(worksheetId: worksheet.id, page: page, kind: .ink, x: Double(x0), y: Double(y0), w: max(0.01, Double(x1 - x0)), h: max(0.01, Double(y1 - y0)), strokes: [pts.prefix(4_000).map { [Double($0.x), Double($0.y)] }]))
    }
    private func export(_ mode: AnnotationExportMode, solutions: Bool = false) {
        guard let svc = model.worksheets else { return }
        let p = NSSavePanel(); p.allowedContentTypes = [.pdf]; p.nameFieldStringValue = title + (solutions ? " – solutions" : "") + ".pdf"
        guard p.runModal() == .OK, let dest = p.url else { return }
        do { try svc.export(worksheet, to: dest, annotations: mode, solutions: solutions) } catch { model.alertMessage = error.localizedDescription }
    }
    private func printIt() { pdf?.document?.printOperation(for: NSPrintInfo.shared, scalingMode: .pageScaleToFit, autoRotate: true)?.runModal(for: NSApp.keyWindow ?? NSWindow(), delegate: nil, didRun: nil, contextInfo: nil) }
}

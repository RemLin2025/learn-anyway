import Foundation
import CoreGraphics
import CoreText

public enum WorksheetError: Error, LocalizedError, Equatable {
    case cannotCreate(String)
    public var errorDescription: String? { if case .cannotCreate(let m) = self { return "The PDF could not be created: \(m)" }; return nil }
}

/// Lays a `RenderDocument` out into pages and writes a PDF with CoreGraphics. The layout is a pure function of the document: the same saved questions
/// and template always paginate and typeset identically (PDF metadata such as the creation date is the only thing that varies between files).
public enum WorksheetRenderer {
    public static let version = "ws.v1"
    static let margin: CGFloat = 54

    typealias Op = (CGContext, CGFloat) -> Void           // draws with the page's pdf height so top-based y can be converted

    final class Pager {
        let w: CGFloat, h: CGFloat, bottom: CGFloat
        var pages: [[Op]] = [[]]
        var y: CGFloat = WorksheetRenderer.margin
        init(w: CGFloat, h: CGFloat) { self.w = w; self.h = h; bottom = h - WorksheetRenderer.margin - 14 }
        func ensure(_ height: CGFloat) { if y + height > bottom && y > WorksheetRenderer.margin + 1 { pages.append([]); y = WorksheetRenderer.margin } }
        func add(_ height: CGFloat, keepTogether: Bool = true, _ op: @escaping (CGContext, CGFloat, CGFloat) -> Void) {   // (context, pageHeight, topY)
            if keepTogether { ensure(height) } else if y + height > bottom { pages.append([]); y = WorksheetRenderer.margin }
            let top = y
            pages[pages.count - 1].append { c, ph in op(c, ph, top) }
            y += height
        }
        func space(_ s: CGFloat) { y += s }
    }

    // MARK: Inline text with real math

    struct Atom { var width: CGFloat, ascent: CGFloat, descent: CGFloat, draw: (CGContext, CGPoint) -> Void; var breakable: Bool }

    static func atoms(_ inl: [MathInline], size: CGFloat, bold: Bool = false, italic: Bool = false) -> [Atom] {
        var out: [Atom] = []
        let f = MathLayout.font(size, italic: italic, bold: bold)
        for piece in inl {
            switch piece {
            case .text(let s):
                let clean = s.replacingOccurrences(of: "**", with: "").replacingOccurrences(of: "`", with: "")
                var word = ""
                func flush() { if !word.isEmpty { let b = MathLayout.text(word, font: f); out.append(Atom(width: b.width, ascent: b.ascent, descent: b.descent, draw: b.draw, breakable: word.hasSuffix(" ") || word.hasSuffix("\n"))); word = "" } }
                for ch in clean { word.append(ch); if ch == " " { flush() } }
                flush()
            case .math(let l):
                if let b = MathLayout.box(latex: l, size: size) { out.append(Atom(width: b.width + size * 0.15, ascent: b.ascent, descent: b.descent, draw: b.draw, breakable: true)) }
                else { let b = MathLayout.text(l, font: MathLayout.font(size, italic: true)); out.append(Atom(width: b.width, ascent: b.ascent, descent: b.descent, draw: b.draw, breakable: true)) }   // unsupported LaTeX: show the source
            }
        }
        return out
    }

    struct Line { var atoms: [Atom]; var ascent: CGFloat; var descent: CGFloat; var indent: CGFloat; var height: CGFloat { ascent + descent } }

    static func wrap(_ a: [Atom], width: CGFloat, size: CGFloat, indent: CGFloat = 0, firstIndent: CGFloat = 0) -> [Line] {
        var lines: [Line] = [], cur: [Atom] = [], x: CGFloat = 0
        func close() { if !cur.isEmpty || lines.isEmpty { lines.append(Line(atoms: cur, ascent: max(cur.map(\.ascent).max() ?? size * 0.8, size * 0.8), descent: max(cur.map(\.descent).max() ?? size * 0.25, size * 0.25), indent: lines.isEmpty ? firstIndent : indent)) }; cur = []; x = 0 }
        for at in a {
            let avail = width - (lines.isEmpty ? firstIndent : indent)
            if x + at.width > avail, !cur.isEmpty { close() }
            cur.append(at); x += at.width
        }
        close()
        return lines
    }

    static func addLines(_ p: Pager, _ lines: [Line], x0: CGFloat, size: CGFloat, gap: CGFloat = 0.28) {
        for l in lines {
            let h = l.height + size * gap
            p.add(h, keepTogether: false) { c, ph, top in
                var x = x0 + l.indent
                for a in l.atoms { a.draw(c, CGPoint(x: x, y: ph - (top + l.ascent))); x += a.width }
            }
        }
    }

    static func paragraph(_ p: Pager, _ inl: [MathInline], x0: CGFloat, width: CGFloat, size: CGFloat, bold: Bool = false, italic: Bool = false, hanging: CGFloat = 0, first: CGFloat = 0) {
        addLines(p, wrap(atoms(inl, size: size, bold: bold, italic: italic), width: width, size: size, indent: hanging, firstIndent: first), x0: x0, size: size)
    }

    // MARK: Blocks

    static func blocks(_ p: Pager, _ bs: [RenderBlock], x0: CGFloat, width: CGFloat, size: CGFloat) {
        for b in bs {
            switch b {
            case .paragraph(let i): paragraph(p, i, x0: x0, width: width, size: size)
            case .heading(let i): paragraph(p, i, x0: x0, width: width, size: size * 1.1, bold: true)
            case .part(let label, let i): paragraph(p, [.text(label + " ")] + i, x0: x0, width: width, size: size, hanging: size * 1.6)
            case .list(let ordered, let items):
                for (n, it) in items.enumerated() { paragraph(p, [.text(ordered ? "\(n + 1). " : "• ")] + it, x0: x0 + size, width: width - size, size: size, hanging: size * 1.2) }
            case .display(let latex, let boxed):
                if let m = MathLayout.box(latex: latex, size: size * 1.1, display: true) {
                    let scale = m.width > width ? width / m.width : 1                               // wider than the page: scale down rather than clip
                    let h = (m.height + size * 0.8) * scale
                    p.add(h) { c, ph, top in
                        c.saveGState(); c.translateBy(x: x0 + (width - m.width * scale) / 2, y: ph - (top + size * 0.4 * scale + m.ascent * scale)); c.scaleBy(x: scale, y: scale)
                        m.draw(c, .zero); c.restoreGState()
                        if boxed { c.setLineWidth(0.7); c.stroke(CGRect(x: x0 + (width - m.width * scale) / 2 - 4, y: ph - top - h + 2, width: m.width * scale + 8, height: h - 4)) }
                    }
                } else { paragraph(p, [.text(latex)], x0: x0, width: width, size: size, italic: true) }
            case .code(let t): code(p, t, x0: x0, width: width, size: size)
            case .table(let headers, let rows): table(p, headers, rows, x0: x0, width: width, size: size)
            case .image(let alt): paragraph(p, [.text("[Image: \(alt)]")], x0: x0, width: width, size: size, italic: true)
            }
            p.space(size * 0.3)
        }
    }

    static func code(_ p: Pager, _ text: String, x0: CGFloat, width: CGFloat, size: CGFloat) {
        let f = MathLayout.mono(size * 0.85), cw = MathLayout.line("M", font: f).1
        let per = max(10, Int((width - 12) / cw))
        var rows: [String] = []
        for l in text.components(separatedBy: "\n") { var s = Substring(l); if s.isEmpty { rows.append("") }; while !s.isEmpty { rows.append(String(s.prefix(per))); s = s.dropFirst(per) } }
        let lh = size * 1.15
        for (i, r) in rows.enumerated() {
            p.add(lh, keepTogether: false) { c, ph, top in
                c.setFillColor(CGColor(gray: 0.95, alpha: 1)); c.fill(CGRect(x: x0, y: ph - top - lh, width: width, height: lh)); c.setFillColor(CGColor(gray: 0, alpha: 1))
                let (l, _, a, _) = MathLayout.line(r, font: f); c.textPosition = CGPoint(x: x0 + 6, y: ph - top - a - (lh - a) / 3); CTLineDraw(l, c); _ = i
            }
        }
    }

    static func table(_ p: Pager, _ headers: [String], _ rows: [[String]], x0: CGFloat, width: CGFloat, size: CGFloat) {
        let all = (headers.isEmpty ? [] : [headers]) + rows
        let cols = max(1, all.map(\.count).max() ?? 1), cw = width / CGFloat(cols), pad: CGFloat = 4
        for (ri, r) in all.enumerated() {
            let cells = (0..<cols).map { j -> [Line] in wrap(atoms(MathMarkdown.inline(j < r.count ? r[j] : ""), size: size * 0.95, bold: ri == 0 && !headers.isEmpty), width: cw - 2 * pad, size: size * 0.95) }
            let h = (cells.map { $0.reduce(0) { $0 + $1.height + size * 0.2 } }.max() ?? size) + 2 * pad
            p.add(h) { c, ph, top in
                c.setLineWidth(0.5); c.stroke(CGRect(x: x0, y: ph - top - h, width: width, height: h))
                for j in 0..<cols {
                    if j > 0 { c.move(to: CGPoint(x: x0 + CGFloat(j) * cw, y: ph - top)); c.addLine(to: CGPoint(x: x0 + CGFloat(j) * cw, y: ph - top - h)); c.strokePath() }
                    var y = top + pad
                    for l in cells[j] { var x = x0 + CGFloat(j) * cw + pad; for a in l.atoms { a.draw(c, CGPoint(x: x, y: ph - (y + l.ascent))); x += a.width }; y += l.height + size * 0.2 }
                }
            }
        }
    }

    // MARK: Items and document

    static func answerArea(_ p: Pager, _ item: RenderItem, x0: CGFloat, width: CGFloat, size: CGFloat) {
        switch item.answerArea {
        case .none, .choices: break
        case .lines(let n):
            for _ in 0..<n { p.add(24) { c, ph, top in c.setLineWidth(0.4); c.setStrokeColor(CGColor(gray: 0.55, alpha: 1)); c.move(to: CGPoint(x: x0, y: ph - top - 20)); c.addLine(to: CGPoint(x: x0 + width, y: ph - top - 20)); c.strokePath(); c.setStrokeColor(CGColor(gray: 0, alpha: 1)) } }
        case .box(let h):
            p.add(h) { c, ph, top in c.setLineWidth(0.5); c.setStrokeColor(CGColor(gray: 0.5, alpha: 1)); c.stroke(CGRect(x: x0, y: ph - top - h, width: width, height: h - 4)); c.setStrokeColor(CGColor(gray: 0, alpha: 1)) }
        case .numeric(let unit):
            paragraph(p, [.text("Answer: ______________" + (unit.map { " \($0)" } ?? ""))], x0: x0, width: width, size: size)
        case .flashcardBack:
            p.add(60) { c, ph, top in c.setLineWidth(0.5); c.setStrokeColor(CGColor(gray: 0.5, alpha: 1)); c.stroke(CGRect(x: x0, y: ph - top - 56, width: width, height: 52)); c.setStrokeColor(CGColor(gray: 0, alpha: 1)) }
        }
    }

    static func layoutItem(_ p: Pager, _ item: RenderItem, doc: RenderDocument, solutions: Bool, size: CGFloat) {
        let x0 = margin, w = p.w - 2 * margin, ind: CGFloat = size * 2
        p.ensure(size * 6)
        var head: [MathInline] = [.text("\(item.number).  ")]
        if let t = item.topic { head.append(.text("[\(t)]  ")) }
        let pts = item.points.map { "[\(WorksheetRenderer.fmt($0)) pt\($0 == 1 ? "" : "s")]" } ?? ""
        let headLines = wrap(atoms(head + (item.blocks.isEmpty ? [.text(item.title)] : []), size: size, bold: true), width: w - 60, size: size)
        let firstH = (headLines.first?.height ?? size) + size * 0.3
        p.add(firstH) { c, ph, top in
            var x = x0; for a in headLines.first?.atoms ?? [] { a.draw(c, CGPoint(x: x, y: ph - (top + (headLines.first?.ascent ?? size)))); x += a.width }
            if !pts.isEmpty { let b = MathLayout.text(pts, font: MathLayout.font(size * 0.9)); b.draw(c, CGPoint(x: x0 + w - b.width, y: ph - (top + b.ascent))) }
        }
        blocks(p, item.blocks, x0: x0 + ind, width: w - ind, size: size)
        for ch in item.choices {
            let at = atoms([.text("(\(ch.label))  ")] + ch.text, size: size)
            addLines(p, wrap(at, width: w - ind - size * 1.5, size: size, indent: size * 2.4), x0: x0 + ind + size * 1.5, size: size, gap: 0.35)
        }
        if solutions {
            if !item.answerKey.isEmpty { paragraph(p, [.text("Answer: " + item.answerKey)], x0: x0 + ind, width: w - ind, size: size, bold: true) }
            if !item.solution.isEmpty { p.space(size * 0.2); blocks(p, item.solution, x0: x0 + ind, width: w - ind, size: size) }
        } else {
            answerArea(p, item, x0: x0 + ind, width: w - ind, size: size)
        }
        if !item.sources.isEmpty { paragraph(p, [.text("Source: " + item.sources.joined(separator: "; "))], x0: x0 + ind, width: w - ind, size: size * 0.8, italic: true) }
        p.space(size * 1.1)
    }

    static func fmt(_ v: Double) -> String { v == v.rounded() ? String(Int(v)) : String(format: "%g", v) }

    /// Lays the document out and returns the pages as drawing lists. Exposed so tests can inspect pagination without writing a file.
    static func layout(_ doc: RenderDocument, solutions: Bool) -> (pages: [[Op]], size: CGSize) {
        let ps = doc.layout.pageSize.points, size = CGFloat(doc.layout.fontSize)
        let p = Pager(w: CGFloat(ps.w), h: CGFloat(ps.h)), w = p.w - 2 * margin
        paragraph(p, [.text(doc.title + (solutions ? " — Solutions" : ""))], x0: margin, width: w, size: size * 1.5, bold: true)
        if !doc.header.isEmpty { paragraph(p, [.text(doc.header)], x0: margin, width: w, size: size, italic: true) }
        if !solutions && doc.layout.answerSpace != .none && !doc.items.isEmpty {
            p.add(size * 2) { c, ph, top in
                let l = MathLayout.text("Name: ______________________    Date: ______________", font: MathLayout.font(size)); l.draw(c, CGPoint(x: margin, y: ph - (top + l.ascent + 4)))
            }
        }
        if let t = doc.totalPoints, !solutions { paragraph(p, [.text("Total: \(fmt(t)) points")], x0: margin, width: w, size: size) }
        if !doc.instructions.isEmpty { paragraph(p, [.text(doc.instructions)], x0: margin, width: w, size: size, italic: true) }
        p.space(size * 0.8)
        for it in doc.items { layoutItem(p, it, doc: doc, solutions: solutions, size: size) }
        if doc.items.isEmpty { paragraph(p, [.text("This template has no questions to show for the selected set.")], x0: margin, width: w, size: size, italic: true) }
        return (p.pages, CGSize(width: p.w, height: p.h))
    }

    @discardableResult
    public static func write(_ doc: RenderDocument, solutions: Bool = false, to url: URL) throws -> Int {
        let (pages, sz) = layout(doc, solutions: solutions)
        var box = CGRect(origin: .zero, size: sz)
        let aux: [CFString: Any] = [kCGPDFContextTitle: doc.title, kCGPDFContextCreator: "Learn Anyway worksheet \(version)"]
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard let ctx = CGContext(url as CFURL, mediaBox: &box, aux as CFDictionary) else { throw WorksheetError.cannotCreate("no drawing context") }
        let footer = MathLayout.font(9)
        for (i, ops) in pages.enumerated() {
            ctx.beginPDFPage(nil)
            ctx.setFillColor(CGColor(gray: 0, alpha: 1)); ctx.setStrokeColor(CGColor(gray: 0, alpha: 1))
            for op in ops { op(ctx, sz.height) }
            let f = MathLayout.text("Page \(i + 1) of \(pages.count)", font: footer); f.draw(ctx, CGPoint(x: sz.width / 2 - f.width / 2, y: margin / 2))
            ctx.endPDFPage()
        }
        ctx.closePDF()
        return pages.count
    }
}

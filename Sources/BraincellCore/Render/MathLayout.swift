import Foundation
import CoreGraphics
import CoreText

/// A laid-out piece of mathematics: size metrics plus a drawing routine anchored at the baseline-left point. Boxes compose, so fractions, roots,
/// scripts, big operators with limits, fences that stretch to their content, matrices and aligned equations get real two-dimensional layout
/// instead of being flattened into a line of symbols.
public struct MathBox {
    public var width: CGFloat, ascent: CGFloat, descent: CGFloat
    var draw: (CGContext, CGPoint) -> Void
    public var height: CGFloat { ascent + descent }
    static func empty(_ w: CGFloat = 0) -> MathBox { MathBox(width: w, ascent: 0, descent: 0) { _, _ in } }
}

public enum MathLayout {
    static func font(_ size: CGFloat, italic: Bool = false, bold: Bool = false) -> CTFont {
        let name = italic ? "TimesNewRomanPS-ItalicMT" : bold ? "TimesNewRomanPS-BoldMT" : "TimesNewRomanPSMT"
        return CTFontCreateWithName(name as CFString, size, nil)
    }
    static func mono(_ size: CGFloat) -> CTFont { CTFontCreateWithName("Menlo-Regular" as CFString, size, nil) }

    public static func line(_ s: String, font: CTFont) -> (CTLine, CGFloat, CGFloat, CGFloat) {
        let attr = NSAttributedString(string: s, attributes: [.font: font, NSAttributedString.Key(kCTForegroundColorFromContextAttributeName as String): true])
        let l = CTLineCreateWithAttributedString(attr)
        var a: CGFloat = 0, d: CGFloat = 0, g: CGFloat = 0
        let w = CTLineGetTypographicBounds(l, &a, &d, &g)
        return (l, CGFloat(w), a, d)
    }
    static func text(_ s: String, font: CTFont) -> MathBox {
        let (l, w, a, d) = line(s, font: font)
        return MathBox(width: w, ascent: a, descent: d) { c, p in c.textPosition = p; CTLineDraw(l, c) }
    }

    /// Parses and lays out LaTeX. nil when the source is outside the supported subset (callers show the source text instead of guessing).
    public static func box(latex: String, size: CGFloat, display: Bool = false) -> MathBox? {
        (try? Latex.parse(latex)).map { layout($0, size: size) }
    }

    static let relations: Set<String> = ["=", "<", ">", "≤", "≥", "≠", "≈", "∈", "→", "⇒", "⇔", "≡", "∼"]
    static let binaries: Set<String> = ["+", "−", "-", "±", "×", "·", "∪", "∩"]

    public static func layout(_ n: MathNode, size: CGFloat) -> MathBox {
        let axis = size * 0.28
        switch n {
        case .symbol(let s):
            let glyph = s == "-" ? "−" : s
            let italic = glyph.count == 1 && (glyph.first!.isLetter) && !(glyph.first!.isNumber)
            return text(glyph, font: font(size, italic: italic))
        case .text(let s): return text(s, font: font(size))
        case .space: return .empty(size * 0.3)
        case .row(let xs):
            var parts: [MathBox] = []
            for (i, x) in xs.enumerated() {
                if case .symbol(let s) = x, i > 0, i < xs.count - 1, relations.contains(s) || binaries.contains(s) { let g = size * (relations.contains(s) ? 0.28 : 0.2); parts += [.empty(g), layout(x, size: size), .empty(g)] }
                else { parts.append(layout(x, size: size)) }
            }
            return hbox(parts)
        case .frac(let a, let b):
            let nb = layout(a, size: size * 0.92), db = layout(b, size: size * 0.92)
            let t = max(0.6, size * 0.045), gap = size * 0.14, pad = size * 0.12
            let w = max(nb.width, db.width) + 2 * pad
            let nBase = axis + t / 2 + gap + nb.descent, dBase = axis - t / 2 - gap - db.ascent
            return MathBox(width: w, ascent: nBase + nb.ascent, descent: max(0, -(dBase - db.descent))) { c, p in
                nb.draw(c, CGPoint(x: p.x + (w - nb.width) / 2, y: p.y + nBase)); db.draw(c, CGPoint(x: p.x + (w - db.width) / 2, y: p.y + dBase))
                c.setLineWidth(t); c.move(to: CGPoint(x: p.x + pad / 2, y: p.y + axis)); c.addLine(to: CGPoint(x: p.x + w - pad / 2, y: p.y + axis)); c.strokePath()
            }
        case .sqrt(let body, let idx):
            let b = layout(body, size: size), gap = size * 0.12, t = max(0.6, size * 0.045), rad = size * 0.55
            let ib = idx.map { layout($0, size: size * 0.55) }
            let lead = max(0, (ib?.width ?? 0) - rad * 0.45)
            let top = b.ascent + gap
            return MathBox(width: lead + rad + b.width + size * 0.08, ascent: top + t, descent: b.descent) { c, p in
                let x0 = p.x + lead
                c.setLineWidth(t); c.setLineJoin(.miter)
                c.move(to: CGPoint(x: x0, y: p.y + top * 0.45)); c.addLine(to: CGPoint(x: x0 + rad * 0.25, y: p.y + top * 0.5))
                c.addLine(to: CGPoint(x: x0 + rad * 0.55, y: p.y - b.descent)); c.addLine(to: CGPoint(x: x0 + rad, y: p.y + top)); c.addLine(to: CGPoint(x: x0 + rad + b.width + size * 0.04, y: p.y + top)); c.strokePath()
                b.draw(c, CGPoint(x: x0 + rad, y: p.y)); ib?.draw(c, CGPoint(x: p.x, y: p.y + top * 0.55))
            }
        case .sup(let base, let e): return scripts(layout(base, size: size), sup: layout(e, size: size * 0.7), sub: nil, size: size)
        case .sub(let base, let e): return scripts(layout(base, size: size), sup: nil, sub: layout(e, size: size * 0.7), size: size)
        case .supsub(let base, let lo, let hi): return scripts(layout(base, size: size), sup: layout(hi, size: size * 0.7), sub: layout(lo, size: size * 0.7), size: size)
        case .bigOp(let s, let lo, let hi):
            let isInt = s == "∫" || s == "∮", isWord = s.count > 1
            let op = text(s, font: font(isWord ? size : size * 1.45))
            let lb = lo.map { layout($0, size: size * 0.7) }, hb = hi.map { layout($0, size: size * 0.7) }
            if isInt { return scripts(op, sup: hb, sub: lb, size: size, tight: true) }
            let w = max(op.width, lb?.width ?? 0, hb?.width ?? 0)
            let up = (hb.map { $0.height + size * 0.08 } ?? 0), down = (lb.map { $0.height + size * 0.08 } ?? 0)
            return MathBox(width: w + size * 0.1, ascent: op.ascent * 0.8 + up + axis * 0.2, descent: op.descent * 0.8 + down) { c, p in
                op.draw(c, CGPoint(x: p.x + (w - op.width) / 2, y: p.y - axis * 0.3))
                hb?.draw(c, CGPoint(x: p.x + (w - hb!.width) / 2, y: p.y + op.ascent * 0.8 + size * 0.08 + hb!.descent))
                lb?.draw(c, CGPoint(x: p.x + (w - lb!.width) / 2, y: p.y - op.descent * 0.8 - size * 0.08 - lb!.ascent))
            }
        case .delimited(let l, let body, let r):
            let b = layout(body, size: size)
            return hbox([fence(l, height: b.height, size: size, axis: axis, body: b), b, fence(r, height: b.height, size: size, axis: axis, body: b)])
        case .matrix(let rows, let l, let r):
            let g = grid(rows.map { $0.map { layout($0, size: size) } }, size: size, align: { _ in .center })
            return hbox([fence(l, height: g.height, size: size, axis: axis, body: g), g, fence(r, height: g.height, size: size, axis: axis, body: g)])
        case .aligned(let rows): return grid(rows.map { $0.map { layout($0, size: size) } }, size: size, colGap: size * 0.2, align: { $0 == 0 ? .right : .left })
        case .accent(let kind, let body):
            let b = layout(body, size: size), y = b.ascent + size * 0.1
            return MathBox(width: b.width, ascent: y + size * 0.12, descent: b.descent) { c, p in
                b.draw(c, p); c.setLineWidth(max(0.6, size * 0.045))
                let x0 = p.x + b.width * 0.12, x1 = p.x + b.width * 0.88, yy = p.y + y
                switch kind {
                case "hat": c.move(to: CGPoint(x: x0, y: yy)); c.addLine(to: CGPoint(x: (x0 + x1) / 2, y: yy + size * 0.12)); c.addLine(to: CGPoint(x: x1, y: yy))
                case "tilde": c.move(to: CGPoint(x: x0, y: yy)); c.addCurve(to: CGPoint(x: x1, y: yy + size * 0.08), control1: CGPoint(x: x0 + (x1 - x0) * 0.3, y: yy + size * 0.14), control2: CGPoint(x: x0 + (x1 - x0) * 0.6, y: yy - size * 0.06))
                case "vec": c.move(to: CGPoint(x: x0, y: yy + size * 0.04)); c.addLine(to: CGPoint(x: x1, y: yy + size * 0.04)); c.move(to: CGPoint(x: x1 - size * 0.08, y: yy + size * 0.09)); c.addLine(to: CGPoint(x: x1, y: yy + size * 0.04)); c.addLine(to: CGPoint(x: x1 - size * 0.08, y: yy - size * 0.01))
                default: c.move(to: CGPoint(x: x0, y: yy + size * 0.04)); c.addLine(to: CGPoint(x: x1, y: yy + size * 0.04))
                }
                c.strokePath()
            }
        }
    }

    static func hbox(_ parts: [MathBox]) -> MathBox {
        let w = parts.reduce(0) { $0 + $1.width }
        return MathBox(width: w, ascent: parts.map(\.ascent).max() ?? 0, descent: parts.map(\.descent).max() ?? 0) { c, p in
            var x = p.x; for b in parts { b.draw(c, CGPoint(x: x, y: p.y)); x += b.width }
        }
    }

    static func scripts(_ base: MathBox, sup: MathBox?, sub: MathBox?, size: CGFloat, tight: Bool = false) -> MathBox {
        let gap = size * 0.04
        let supUp = max(size * 0.42, base.ascent * 0.62), subDown = max(size * 0.18, base.descent + size * 0.08)
        let w = base.width + gap + max(sup?.width ?? 0, sub?.width ?? 0)
        let asc = max(base.ascent, supUp + (sup?.ascent ?? 0)), desc = max(base.descent, subDown + (sub?.descent ?? 0))
        let dx: CGFloat = tight ? size * 0.12 : 0
        return MathBox(width: w + dx, ascent: asc, descent: desc) { c, p in
            base.draw(c, p)
            sup?.draw(c, CGPoint(x: p.x + base.width + gap + dx, y: p.y + supUp)); sub?.draw(c, CGPoint(x: p.x + base.width + gap, y: p.y - subDown))
        }
    }

    enum Align { case left, center, right }
    static func grid(_ rows: [[MathBox]], size: CGFloat, colGap: CGFloat? = nil, align: @escaping (Int) -> Align) -> MathBox {
        let cols = rows.map(\.count).max() ?? 0, gapX = colGap ?? size * 0.9, gapY = size * 0.3
        guard cols > 0 else { return .empty() }
        var widths = Array(repeating: CGFloat(0), count: cols)
        for r in rows { for (j, b) in r.enumerated() { widths[j] = max(widths[j], b.width) } }
        let heights = rows.map { r in (asc: r.map(\.ascent).max() ?? 0, desc: r.map(\.descent).max() ?? 0) }
        let total = heights.reduce(0) { $0 + $1.asc + $1.desc } + gapY * CGFloat(max(0, rows.count - 1))
        let w = widths.reduce(0, +) + gapX * CGFloat(cols - 1), axis = size * 0.28
        return MathBox(width: w, ascent: total / 2 + axis, descent: max(0, total / 2 - axis)) { c, p in
            var y = p.y + total / 2 + axis
            for (i, r) in rows.enumerated() {
                y -= heights[i].asc
                var x = p.x
                for j in 0..<cols {
                    if j < r.count { let b = r[j]; let off: CGFloat = { switch align(j) { case .left: 0; case .center: (widths[j] - b.width) / 2; case .right: widths[j] - b.width } }(); b.draw(c, CGPoint(x: x + off, y: y)) }
                    x += widths[j] + gapX
                }
                y -= heights[i].desc + gapY
            }
        }
    }

    /// Fences are drawn as paths scaled to the content height, so tall fractions and matrices get tall brackets.
    static func fence(_ s: String, height: CGFloat, size: CGFloat, axis: CGFloat, body: MathBox) -> MathBox {
        guard !s.isEmpty, s != "." else { return .empty() }
        let h = max(height, size * 1.05) + size * 0.1, w = size * 0.34, top = body.ascent + size * 0.05, bottom = -(body.descent + size * 0.05)
        let left = ["(", "[", "{", "⌊", "⌈", "⟨", "|", "‖"].contains(s)
        return MathBox(width: w, ascent: top, descent: -bottom) { c, p in
            let x = p.x, xr = p.x + w, y0 = p.y + bottom, y1 = p.y + top, m = (y0 + y1) / 2
            c.setLineWidth(max(0.7, size * 0.055)); c.setLineJoin(.round)
            switch s {
            case "(": c.move(to: CGPoint(x: xr - 2, y: y1)); c.addQuadCurve(to: CGPoint(x: xr - 2, y: y0), control: CGPoint(x: x - w * 0.15, y: m))
            case ")": c.move(to: CGPoint(x: x + 2, y: y1)); c.addQuadCurve(to: CGPoint(x: x + 2, y: y0), control: CGPoint(x: xr + w * 0.15, y: m))
            case "[": c.move(to: CGPoint(x: xr - 2, y: y1)); c.addLine(to: CGPoint(x: x + 3, y: y1)); c.addLine(to: CGPoint(x: x + 3, y: y0)); c.addLine(to: CGPoint(x: xr - 2, y: y0))
            case "]": c.move(to: CGPoint(x: x + 2, y: y1)); c.addLine(to: CGPoint(x: xr - 3, y: y1)); c.addLine(to: CGPoint(x: xr - 3, y: y0)); c.addLine(to: CGPoint(x: x + 2, y: y0))
            case "{": c.move(to: CGPoint(x: xr - 2, y: y1)); c.addQuadCurve(to: CGPoint(x: x + w / 2, y: y1 - h * 0.2), control: CGPoint(x: x + w / 2, y: y1)); c.addLine(to: CGPoint(x: x + w / 2, y: m + 2)); c.addQuadCurve(to: CGPoint(x: x + 1, y: m), control: CGPoint(x: x + w / 2, y: m)); c.addQuadCurve(to: CGPoint(x: x + w / 2, y: m - 2), control: CGPoint(x: x + w / 2, y: m)); c.addLine(to: CGPoint(x: x + w / 2, y: y0 + h * 0.2)); c.addQuadCurve(to: CGPoint(x: xr - 2, y: y0), control: CGPoint(x: x + w / 2, y: y0))
            case "}": c.move(to: CGPoint(x: x + 2, y: y1)); c.addQuadCurve(to: CGPoint(x: x + w / 2, y: y1 - h * 0.2), control: CGPoint(x: x + w / 2, y: y1)); c.addLine(to: CGPoint(x: x + w / 2, y: m + 2)); c.addQuadCurve(to: CGPoint(x: xr - 1, y: m), control: CGPoint(x: x + w / 2, y: m)); c.addQuadCurve(to: CGPoint(x: x + w / 2, y: m - 2), control: CGPoint(x: x + w / 2, y: m)); c.addLine(to: CGPoint(x: x + w / 2, y: y0 + h * 0.2)); c.addQuadCurve(to: CGPoint(x: x + 2, y: y0), control: CGPoint(x: x + w / 2, y: y0))
            case "|": c.move(to: CGPoint(x: x + w / 2, y: y1)); c.addLine(to: CGPoint(x: x + w / 2, y: y0))
            case "‖": c.move(to: CGPoint(x: x + w / 2 - 1.5, y: y1)); c.addLine(to: CGPoint(x: x + w / 2 - 1.5, y: y0)); c.move(to: CGPoint(x: x + w / 2 + 1.5, y: y1)); c.addLine(to: CGPoint(x: x + w / 2 + 1.5, y: y0))
            case "⌊": c.move(to: CGPoint(x: x + 3, y: y1)); c.addLine(to: CGPoint(x: x + 3, y: y0)); c.addLine(to: CGPoint(x: xr - 2, y: y0))
            case "⌋": c.move(to: CGPoint(x: xr - 3, y: y1)); c.addLine(to: CGPoint(x: xr - 3, y: y0)); c.addLine(to: CGPoint(x: x + 2, y: y0))
            case "⌈": c.move(to: CGPoint(x: x + 3, y: y0)); c.addLine(to: CGPoint(x: x + 3, y: y1)); c.addLine(to: CGPoint(x: xr - 2, y: y1))
            case "⌉": c.move(to: CGPoint(x: xr - 3, y: y0)); c.addLine(to: CGPoint(x: xr - 3, y: y1)); c.addLine(to: CGPoint(x: x + 2, y: y1))
            default: _ = left
            }
            c.strokePath()
        }
    }
}

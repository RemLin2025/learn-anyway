import SwiftUI
import BraincellCore

/// The reusable math-aware content view: Markdown prose with inline and display LaTeX, equation boxes, question parts, lists and code.
/// Parsing is deterministic (`MathMarkdown`) and cached; rendering is native (no web view, no images, no HTML), so math is sharp,
/// follows the theme and text scale, and untrusted content can't run anything. Use it for questions, solutions, hints, chat and previews.
struct MathContentView: View {
    let text: String
    var upgradeLegacy = true
    @ScaledMetric(relativeTo: .body) private var size: CGFloat = 16

    var body: some View {
        let blocks = MathParseCache.blocks(text, upgradeLegacy: upgradeLegacy)
        VStack(alignment: .leading, spacing: size * 0.6) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, b in block(b) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .environment(\.openURL, OpenURLAction { _ in .discarded })          // links in content are inert
    }

    @ViewBuilder private func block(_ b: MathBlock) -> some View {
        switch b {
        case .paragraph(let i): InlineContent(inlines: i, size: size)
        case .heading(let i): InlineContent(inlines: i, size: size * 1.1, weight: .semibold)
        case .display(let latex, let boxed): DisplayMath(latex: latex, boxed: boxed, size: size * 1.35)
        case .part(let label, let i):
            HStack(alignment: .firstTextBaseline, spacing: size * 0.6) {
                Text(label).font(.system(size: size * 0.82, weight: .semibold, design: .rounded)).foregroundStyle(Theme.accent)
                    .padding(.horizontal, 8).padding(.vertical, 2).background(Theme.accent.opacity(0.14), in: Capsule())
                    .accessibilityLabel(label)
                InlineContent(inlines: i, size: size)
            }
        case .list(let ordered, let items):
            VStack(alignment: .leading, spacing: size * 0.3) {
                ForEach(Array(items.enumerated()), id: \.offset) { n, it in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(ordered ? "\(n + 1)." : "•").font(.system(size: size)).foregroundStyle(Theme.textSecondary).monospacedDigit()
                        InlineContent(inlines: it, size: size)
                    }
                }
            }
        case .code(let lang, let code):
            VStack(alignment: .leading, spacing: 4) {
                if let l = lang { Text(l.uppercased()).font(.caption2.weight(.semibold)).foregroundStyle(Theme.textSecondary) }
                ScrollView(.horizontal, showsIndicators: false) { Text(code).font(.system(size: size * 0.9, design: .monospaced)).textSelection(.enabled).fixedSize(horizontal: true, vertical: true) }
            }
            .padding(10).frame(maxWidth: .infinity, alignment: .leading).background(Theme.elevated, in: RoundedRectangle(cornerRadius: 8))
            .accessibilityLabel("Code, \(lang ?? "unknown language")")
        }
    }
}

/// Parse results are cached per text, so rapid navigation and re-renders never re-parse.
enum MathParseCache {
    private final class Box { let blocks: [MathBlock]; init(_ b: [MathBlock]) { blocks = b } }
    private static let cache: NSCache<NSString, Box> = { let c = NSCache<NSString, Box>(); c.countLimit = 400; return c }()
    static func blocks(_ text: String, upgradeLegacy: Bool) -> [MathBlock] {
        let key = (upgradeLegacy ? "L" : "N") + text as NSString
        if let hit = cache.object(forKey: key) { return hit.blocks }
        let parsed = MathMarkdown.parse(upgradeLegacy ? (MathMarkdown.legacyUpgrade(text) ?? text) : text)
        cache.setObject(Box(parsed), forKey: key)
        return parsed
    }
}

/// A display equation on its own line. Substantial ones sit in a subtle box; anything wider than the card scrolls instead of overflowing.
struct DisplayMath: View {
    let latex: String
    let boxed: Bool
    let size: CGFloat
    @State private var scrollHeight: CGFloat?
    var body: some View {
        let m = MathView(latex: latex, size: size)
        ViewThatFits(in: .horizontal) {
            m
            // A horizontal ScrollView doesn't size itself to its content's height, so measure it (otherwise sub/superscripts are clipped).
            ScrollView(.horizontal, showsIndicators: true) {
                m.padding(.bottom, 8).background(GeometryReader { g in Color.clear.preference(key: DisplayHeightKey.self, value: g.size.height) })
            }
            .frame(height: scrollHeight).onPreferenceChange(DisplayHeightKey.self) { scrollHeight = $0 }
        }
        .padding(boxed ? 12 : 4)
        .frame(maxWidth: .infinity, alignment: boxed ? .leading : .center)
        .background(boxed ? Theme.elevated.opacity(0.55) : .clear, in: RoundedRectangle(cornerRadius: 10))
        .padding(.vertical, boxed ? 2 : 4)
    }
}

private struct DisplayHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

/// One paragraph. Simple inline math (letters, scripts, Greek, simple roots and fractions) becomes real styled text inside the sentence so it
/// wraps and selects like prose. Inline math that needs two-dimensional layout is typeset by `MathView` inside a wrapping flow.
struct InlineContent: View {
    let inlines: [MathInline]
    let size: CGFloat
    var weight: Font.Weight = .regular

    var body: some View {
        if let t = InlineMath.attributed(inlines, size: size, weight: weight) {
            Text(t).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
        } else {
            FlowLayout(spacing: 0, lineSpacing: size * 0.25) {
                ForEach(Array(InlineMath.words(inlines).enumerated()), id: \.offset) { _, w in
                    switch w {
                    case .word(let s): Text(InlineMath.markdown(s, size: size, weight: weight))
                    case .math(let l): MathView(latex: l, size: size * 1.05).padding(.horizontal, 2)
                    }
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(InlineMath.spoken(inlines))
        }
    }
}

enum InlineMath {
    enum Word { case word(String), math(String) }

    static func markdown(_ s: String, size: CGFloat, weight: Font.Weight) -> AttributedString {
        var a = (try? AttributedString(markdown: s, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(s)
        a.font = .system(size: size, weight: weight)
        return a
    }

    /// Whole-paragraph attributed text, or nil when some inline math needs real 2-D layout.
    static func attributed(_ inlines: [MathInline], size: CGFloat, weight: Font.Weight) -> AttributedString? {
        var out = AttributedString()
        for i in inlines {
            switch i {
            case .text(let s): out += markdown(s, size: size, weight: weight)
            case .math(let l):
                guard let node = try? Latex.parse(l) else {      // malformed or unsupported LaTeX stays visible as its source
                    var lit = AttributedString(l); lit.font = .system(size: size * 0.9, design: .monospaced); out += lit; continue
                }
                guard let a = styled(node, size: size, weight: weight) else { return nil }
                out += a
            }
        }
        return out
    }

    static func styled(_ n: MathNode, size: CGFloat, weight: Font.Weight, script: Bool = false) -> AttributedString? {
        func run(_ s: String, italic: Bool) -> AttributedString {
            var a = AttributedString(s); a.font = italic ? .system(size: size, weight: weight, design: .serif).italic() : .system(size: size, weight: weight, design: .serif); return a
        }
        switch n {
        case .symbol(let s):
            let isVar = s.count == 1 && s.first!.isLetter
            var a = run(s, italic: isVar)
            if "=+−≤≥≠≈∈∉⊂⊆∪∩→⇒⇔·×±∼".contains(s) && s.count == 1 { a = run(" " + s + " ", italic: false) }
            return a
        case .text(let s): return run(s, italic: false)
        case .space: return run(" ", italic: false)
        case .row(let xs):
            var out = AttributedString(); for x in xs { guard let a = styled(x, size: size, weight: weight) else { return nil }; out += a }; return out
        case .sup(let b, let e), .sub(let b, let e):
            guard let base = styled(b, size: size, weight: weight), var sc = styled(e, size: size * 0.7, weight: weight, script: true) else { return nil }
            if case .sup = n { sc.baselineOffset = size * 0.38 } else { sc.baselineOffset = -size * 0.2 }
            return base + sc
        case .supsub(let b, let lo, let hi):
            guard let base = styled(b, size: size, weight: weight), var l = styled(lo, size: size * 0.7, weight: weight, script: true), var h = styled(hi, size: size * 0.7, weight: weight, script: true) else { return nil }
            l.baselineOffset = -size * 0.2; h.baselineOffset = size * 0.38
            return base + l + h
        case .frac(let a, let b):
            guard isShort(a), isShort(b), let x = styled(a, size: size, weight: weight), let y = styled(b, size: size, weight: weight) else { return nil }
            return x + run("/", italic: false) + y
        case .sqrt(let x, nil):
            guard isShort(x), let b = styled(x, size: size, weight: weight) else { return nil }
            return run("√", italic: false) + b
        case .delimited(let l, let x, let r):
            guard let b = styled(x, size: size, weight: weight) else { return nil }
            return run(l, italic: false) + b + run(r, italic: false)
        case .accent(let acc, let x):
            guard case .symbol(let s) = x, s.count == 1 else { return nil }
            return run(s + acc, italic: true)
        case .sqrt, .bigOp, .matrix, .aligned: return nil
        }
    }

    /// Short enough to read as a/b or √x inside a sentence.
    static func isShort(_ n: MathNode) -> Bool {
        switch n {
        case .symbol: true
        case .row(let xs): xs.count <= 3 && xs.allSatisfy { if case .symbol = $0 { true } else { false } }
        default: false
        }
    }

    static func words(_ inlines: [MathInline]) -> [Word] {
        var out: [Word] = []
        for i in inlines {
            switch i {
            case .math(let l): out.append(.math(l))
            case .text(let s):
                var cur = ""
                for ch in s { cur.append(ch); if ch == " " || ch == "\n" { out.append(.word(cur)); cur = "" } }
                if !cur.isEmpty { out.append(.word(cur)) }
            }
        }
        return out
    }

    static func spoken(_ inlines: [MathInline]) -> String {
        inlines.map { i in switch i { case .text(let s): s; case .math(let l): Latex.unicode(l) ?? l } }.joined()
    }
}

/// Wraps children left to right; each line is centred vertically so inline math sits with its sentence.
struct FlowLayout: Layout {
    var spacing: CGFloat = 0
    var lineSpacing: CGFloat = 4

    private func lines(_ width: CGFloat, _ subviews: Subviews) -> (rows: [[(Int, CGSize)]], heights: [CGFloat]) {
        var rows: [[(Int, CGSize)]] = [[]], heights: [CGFloat] = [0], x: CGFloat = 0
        for (i, s) in subviews.enumerated() {
            let sz = s.sizeThatFits(.unspecified)
            if x + sz.width > width, !rows[rows.count - 1].isEmpty { rows.append([]); heights.append(0); x = 0 }
            rows[rows.count - 1].append((i, sz)); heights[heights.count - 1] = max(heights[heights.count - 1], sz.height); x += sz.width + spacing
        }
        return (rows, heights)
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let w = proposal.width ?? 600
        let l = lines(w, subviews)
        return CGSize(width: w, height: l.heights.reduce(0, +) + lineSpacing * CGFloat(max(0, l.heights.count - 1)))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let l = lines(bounds.width, subviews); var y = bounds.minY
        for (r, row) in l.rows.enumerated() {
            var x = bounds.minX
            for (i, sz) in row { subviews[i].place(at: CGPoint(x: x, y: y + (l.heights[r] - sz.height) / 2), proposal: ProposedViewSize(sz)); x += sz.width + spacing }
            y += l.heights[r] + lineSpacing
        }
    }
}

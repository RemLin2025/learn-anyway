import SwiftUI
import BraincellCore

/// Native, offline rendering of the LaTeX subset in `Latex`. Falls back to the source if parsing fails.
struct MathView: View {
    let latex: String
    var size: CGFloat = 20

    var body: some View {
        Group {
            if let node = try? Latex.parse(latex) {
                MathNodeView(node: node, size: size)
            } else {
                Text(latex).font(.system(size: size * 0.8, design: .monospaced)).foregroundStyle(Theme.textSecondary)
                    .help("This formula uses LaTeX Learn Anyway can’t typeset yet; showing the source.")
            }
        }
        .fixedSize()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Latex.unicode(latex) ?? latex)
    }
}

struct MathNodeView: View {
    let node: MathNode
    let size: CGFloat

    var body: some View {
        switch node {
        case .symbol(let s): symbol(s)
        case .text(let s): Text(s).font(.system(size: size, design: .serif))
        case .row(let xs):
            HStack(alignment: .center, spacing: size * 0.03) { ForEach(Array(xs.enumerated()), id: \.offset) { MathNodeView(node: $1, size: size) } }
        case .frac(let a, let b):
            VStack(spacing: size * 0.08) {
                MathNodeView(node: a, size: size * 0.85)
                Rectangle().frame(height: 1).foregroundStyle(.primary)
                MathNodeView(node: b, size: size * 0.85)
            }.fixedSize()
        case .sqrt(let x, let idx):
            HStack(alignment: .top, spacing: 0) {
                if let idx { MathNodeView(node: idx, size: size * 0.6).offset(y: size * 0.1) }
                Text("√").font(.system(size: size * 1.15, design: .serif))
                MathNodeView(node: x, size: size).padding(.top, 3).overlay(alignment: .top) { Rectangle().frame(height: 1) }
            }
        case .sup(let b, let e):
            HStack(alignment: .top, spacing: 0) { MathNodeView(node: b, size: size); MathNodeView(node: e, size: size * 0.65).offset(y: -size * 0.25) }
        case .sub(let b, let e):
            HStack(alignment: .bottom, spacing: 0) { MathNodeView(node: b, size: size); MathNodeView(node: e, size: size * 0.65).offset(y: size * 0.25) }
        case .supsub(let b, let lo, let hi):
            HStack(alignment: .center, spacing: 0) {
                MathNodeView(node: b, size: size)
                VStack(spacing: size * 0.1) { MathNodeView(node: hi, size: size * 0.65); MathNodeView(node: lo, size: size * 0.65) }
            }
        case .bigOp(let s, let lo, let hi):
            VStack(spacing: 0) {
                if let hi { MathNodeView(node: hi, size: size * 0.65) }
                Text(s).font(.system(size: s == "lim" ? size : size * 1.5, design: .serif))
                if let lo { MathNodeView(node: lo, size: size * 0.65) }
            }
        case .delimited(let l, let x, let r):
            HStack(spacing: 1) { Text(l).font(.system(size: size * 1.3, design: .serif)); MathNodeView(node: x, size: size); Text(r).font(.system(size: size * 1.3, design: .serif)) }
        case .matrix(let rows, let l, let r):
            HStack(spacing: 2) {
                if !l.isEmpty { Text(l).font(.system(size: size * Double(max(1.4, Double(rows.count) * 1.1)), design: .serif)) }
                Grid(horizontalSpacing: size * 0.8, verticalSpacing: size * 0.2) {
                    ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                        GridRow { ForEach(Array(row.enumerated()), id: \.offset) { MathNodeView(node: $1, size: size) } }
                    }
                }
                if !r.isEmpty { Text(r).font(.system(size: size * Double(max(1.4, Double(rows.count) * 1.1)), design: .serif)) }
            }
        case .accent(let a, let x):
            if case .symbol(let t) = x, t.count == 1 { Text(t + a).font(.system(size: size, design: .serif)).italic() }
            else { VStack(spacing: 0) { MathNodeView(node: x, size: size).padding(.top, 3).overlay(alignment: .top) { Rectangle().frame(height: 1) } } }   // a container is required: a bare recursive branch makes SwiftUI recurse forever
        case .aligned(let rows):
            Grid(alignment: .leading, horizontalSpacing: 4, verticalSpacing: size * 0.25) {
                ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                    GridRow { ForEach(Array(row.enumerated()), id: \.offset) { c, n in MathNodeView(node: n, size: size).gridColumnAlignment(c == 0 ? .trailing : .leading) } }
                }
            }
        case .space: Color.clear.frame(width: size * 0.3, height: 1)
        }
    }

    @ViewBuilder private func symbol(_ s: String) -> some View {
        let isVar = s.count == 1 && (s.first!.isLetter)
        let isOp = "=+−≤≥≠≈∈∉⊂⊆∪∩→⇒⇔·×±".contains(s) && s.count == 1
        Text(s).font(.system(size: size, design: .serif)).italic(isVar)
            .padding(.horizontal, isOp ? size * 0.18 : 0)
    }
}

/// Compatibility wrapper: every call site gets the full math-aware renderer.
struct RichText: View {
    let text: String
    var font: Font = .body
    var body: some View { MathContentView(text: text) }

    static func attributed(_ s: String) -> AttributedString {
        let converted = Latex.inlineConverted(s)
        return (try? AttributedString(markdown: converted, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(converted)
    }
}

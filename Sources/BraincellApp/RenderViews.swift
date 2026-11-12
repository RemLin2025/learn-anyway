import SwiftUI
import BraincellCore

/// Interactive view of a `RenderDocument`: the same model the PDF writer consumes, so the gallery preview matches the exported worksheet.
struct RenderBlocksView: View {
    let blocks: [RenderBlock]
    var size: CGFloat = 13
    var body: some View {
        VStack(alignment: .leading, spacing: size * 0.5) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, b in block(b) }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
    @ViewBuilder private func block(_ b: RenderBlock) -> some View {
        switch b {
        case .paragraph(let i): InlineContent(inlines: i, size: size)
        case .heading(let i): InlineContent(inlines: i, size: size * 1.1, weight: .semibold)
        case .part(let l, let i): InlineContent(inlines: [.text(l + " ")] + i, size: size)
        case .display(let l, let boxed): DisplayMath(latex: l, boxed: boxed, size: size * 1.3)
        case .list(let ordered, let items):
            VStack(alignment: .leading, spacing: 3) { ForEach(Array(items.enumerated()), id: \.offset) { n, it in InlineContent(inlines: [.text(ordered ? "\(n + 1). " : "• ")] + it, size: size) } }
        case .code(let t): Text(t).font(.system(size: size * 0.9, design: .monospaced)).padding(8).frame(maxWidth: .infinity, alignment: .leading).background(Theme.elevated, in: RoundedRectangle(cornerRadius: 6))
        case .table(let h, let rows):
            Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 4) {
                if !h.isEmpty { GridRow { ForEach(Array(h.enumerated()), id: \.offset) { _, c in Text(c).font(.system(size: size, weight: .semibold)) } }; Divider() }
                ForEach(Array(rows.enumerated()), id: \.offset) { _, r in GridRow { ForEach(Array(r.enumerated()), id: \.offset) { _, c in InlineContent(inlines: MathMarkdown.inline(c), size: size) } } }
            }.padding(8).overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.border))
        case .image(let alt): Text("[Image: \(alt)]").italic().font(.system(size: size))
        }
    }
}

struct RenderItemView: View {
    let item: RenderItem
    var showSolution = false
    var size: CGFloat = 13
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text("\(item.number).").font(.system(size: size, weight: .bold))
                if let t = item.topic { Badge(text: t) }
                Spacer()
                if let p = item.points { Text("[\(p == p.rounded() ? String(Int(p)) : String(p)) pt\(p == 1 ? "" : "s")]").font(.system(size: size * 0.9)).foregroundStyle(Theme.textSecondary) }
            }
            RenderBlocksView(blocks: item.blocks, size: size)
            ForEach(item.choices, id: \.id) { c in HStack(alignment: .firstTextBaseline, spacing: 6) { Text("(\(c.label))").font(.system(size: size, weight: .medium)); InlineContent(inlines: c.text, size: size) }.padding(.leading, 12) }
            answerArea
            if showSolution {
                if !item.answerKey.isEmpty { Text("Answer: " + item.answerKey).font(.system(size: size, weight: .semibold)) }
                RenderBlocksView(blocks: item.solution, size: size)
            }
            if !item.sources.isEmpty { Text("Source: " + item.sources.joined(separator: "; ")).font(.caption).italic().foregroundStyle(Theme.textSecondary) }
        }
    }
    @ViewBuilder private var answerArea: some View {
        switch item.answerArea {
        case .none, .choices: EmptyView()
        case .lines(let n): VStack(spacing: 14) { ForEach(0..<min(n, 4), id: \.self) { _ in Rectangle().fill(Theme.border).frame(height: 1) } }.padding(.top, 8)
        case .box(let h): RoundedRectangle(cornerRadius: 4).strokeBorder(Theme.border).frame(height: min(h / 2, 90))
        case .numeric(let u): Text("Answer: ____________" + (u.map { " \($0)" } ?? "")).font(.system(size: size))
        case .flashcardBack: RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.border, style: StrokeStyle(lineWidth: 1, dash: [4])).frame(height: 36).overlay(Text("Flip to reveal").font(.caption).foregroundStyle(Theme.textSecondary))
        }
    }
}

struct RenderDocumentView: View {
    let doc: RenderDocument
    var showSolutions = false
    var limit = 3
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(doc.title).font(.system(.headline, design: .serif))
            if !doc.instructions.isEmpty { Text(doc.instructions).italic().font(.footnote).foregroundStyle(Theme.textSecondary) }
            ForEach(doc.items.prefix(limit)) { RenderItemView(item: $0, showSolution: showSolutions) }
            if doc.items.isEmpty { Text("No questions in this set are compatible with this template.").foregroundStyle(Theme.textSecondary) }
        }.padding(16).frame(maxWidth: .infinity, alignment: .leading).background(Color.white.opacity(0.96), in: RoundedRectangle(cornerRadius: 6)).environment(\.colorScheme, .light)
    }
}

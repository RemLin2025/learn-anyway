import SwiftUI
import BraincellCore

/// Pannable, zoomable map of the skill hierarchy (solid edges) and prerequisites (dashed). Branches collapse.
/// Nodes are real buttons, so the map is keyboard-navigable and exposes VoiceOver labels.
struct SkillMapView: View {
    let skills: [Skill]
    let relations: [SkillRelation]
    let masteries: [UUID: SkillMastery]
    @Binding var selected: UUID?
    @State private var collapsed: Set<UUID> = []
    @State private var zoom: CGFloat = 1
    private let nodeW: CGFloat = 200, nodeH: CGFloat = 44

    var body: some View {
        let g = SkillGraphLayout.layout(skills: skills, relations: relations, collapsed: collapsed)
        let parents = Set(relations.filter { $0.kind == .hierarchy }.map(\.fromSkillId))
        let pos = Dictionary(uniqueKeysWithValues: g.nodes.map { ($0.id, CGPoint(x: $0.x + 12, y: $0.y + 12)) })
        let width = (g.nodes.map(\.x).max() ?? 0) + nodeW + 40, height = (g.nodes.map(\.y).max() ?? 0) + nodeH + 40
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Button { zoom = max(0.5, zoom - 0.15) } label: { Image(systemName: "minus.magnifyingglass") }.accessibilityLabel("Zoom out")
                Button { zoom = min(2, zoom + 0.15) } label: { Image(systemName: "plus.magnifyingglass") }.accessibilityLabel("Zoom in")
                Button("Reset") { zoom = 1 }
                Button(collapsed.isEmpty ? "Collapse all" : "Expand all") { collapsed = collapsed.isEmpty ? parents : [] }
                Spacer()
                Label("hierarchy", systemImage: "arrow.right").font(.caption).foregroundStyle(Theme.textSecondary)
                Label("prerequisite", systemImage: "arrow.right").font(.caption).foregroundStyle(Theme.attention)
            }.padding(8).buttonStyle(.borderless)
            Divider()
            ScrollView([.horizontal, .vertical]) {
                ZStack(alignment: .topLeading) {
                    Canvas { ctx, _ in
                        for e in g.edges {
                            guard let a = pos[e.from], let b = pos[e.to] else { continue }
                            var p = Path(); let s = CGPoint(x: a.x + nodeW, y: a.y + nodeH / 2), t = CGPoint(x: b.x, y: b.y + nodeH / 2)
                            p.move(to: s); p.addCurve(to: t, control1: CGPoint(x: s.x + 30, y: s.y), control2: CGPoint(x: t.x - 30, y: t.y))
                            if e.kind == .prerequisite { ctx.stroke(p, with: .color(Theme.attention), style: StrokeStyle(lineWidth: 1.5, dash: [5, 4])) }
                            else { ctx.stroke(p, with: .color(.secondary.opacity(0.6)), lineWidth: 1.2) }
                        }
                    }.frame(width: width, height: height)
                    ForEach(g.nodes) { n in
                        node(n, hasChildren: parents.contains(n.id)).position(x: pos[n.id]!.x + nodeW / 2, y: pos[n.id]!.y + nodeH / 2)
                    }
                }
                .frame(width: width, height: height, alignment: .topLeading)
                .scaleEffect(zoom, anchor: .topLeading)
                .frame(width: width * zoom, height: height * zoom, alignment: .topLeading)
                .padding(12)
            }
            .gesture(MagnifyGesture().onChanged { zoom = min(2, max(0.5, $0.magnification)) })
        }
    }

    private func node(_ n: SkillNode, hasChildren: Bool) -> some View {
        let m = masteries[n.id]
        let label: String = (m?.isUnknown ?? true) ? "Unknown" : "≈ \(Int(((m?.overall ?? 0) * 100).rounded()))% · \(m!.confidence.label)"
        let tint: Color = (m?.isUnknown ?? true) ? .secondary : (m!.confidence == .strong ? Theme.mastery : (m!.confidence == .moderate ? Theme.accent : Theme.attention))
        return HStack(spacing: 4) {
            Button { selected = n.id } label: {
                VStack(alignment: .leading, spacing: 1) {
                    Text(n.name).font(.callout.weight(.medium)).lineLimit(1)
                    Text(label).font(.caption2).foregroundStyle(Theme.textSecondary)
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(n.name), mastery \(label)").accessibilityAddTraits(selected == n.id ? .isSelected : [])
            if hasChildren {
                Button { if collapsed.contains(n.id) { collapsed.remove(n.id) } else { collapsed.insert(n.id) } } label: {
                    Image(systemName: n.hasHiddenChildren ? "chevron.right.circle" : "chevron.down.circle")
                }.buttonStyle(.borderless).accessibilityLabel(n.hasHiddenChildren ? "Expand \(n.name)" : "Collapse \(n.name)")
            }
        }
        .padding(.horizontal, 10).frame(width: nodeW, height: nodeH)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(tint, style: StrokeStyle(lineWidth: selected == n.id ? 3 : 1.5, dash: (m?.isUnknown ?? true) ? [4, 3] : [])))
    }
}

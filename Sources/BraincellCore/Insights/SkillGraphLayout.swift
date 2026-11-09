import Foundation

public struct SkillNode: Sendable, Equatable, Identifiable {
    public var id: UUID; public var name: String; public var depth: Int; public var x: Double; public var y: Double
    public var hasHiddenChildren: Bool
}
public struct SkillEdge: Sendable, Equatable { public var from: UUID; public var to: UUID; public var kind: SkillRelationKind }

/// Deterministic left-to-right layout of the skill hierarchy, with prerequisite edges drawn between nodes.
/// Each skill appears once (at its shallowest depth); collapsed branches hide their hierarchy descendants.
public enum SkillGraphLayout {
    public static let columnWidth = 250.0, rowHeight = 64.0

    public static func layout(skills: [Skill], relations: [SkillRelation], collapsed: Set<UUID> = []) -> (nodes: [SkillNode], edges: [SkillEdge]) {
        let byId = Dictionary(uniqueKeysWithValues: skills.map { ($0.id, $0) })
        let hier = relations.filter { $0.kind == .hierarchy && byId[$0.fromSkillId] != nil && byId[$0.toSkillId] != nil }
        var children: [UUID: [UUID]] = [:]
        for r in hier { children[r.fromSkillId, default: []].append(r.toSkillId) }
        func name(_ id: UUID) -> String { byId[id]!.name }
        for k in children.keys { children[k]!.sort { name($0).localizedCaseInsensitiveCompare(name($1)) == .orderedAscending } }
        let childIds = Set(hier.map(\.toSkillId))
        let roots = skills.filter { !childIds.contains($0.id) }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }

        var depth: [UUID: Int] = [:], order: [UUID] = [], hidden: Set<UUID> = []
        func visit(_ id: UUID, _ d: Int, _ path: Set<UUID>) {
            guard !path.contains(id) else { return }
            if let existing = depth[id] { depth[id] = min(existing, d); return }   // already placed: keep the shallowest depth
            depth[id] = d; order.append(id)
            if collapsed.contains(id) { if !(children[id] ?? []).isEmpty { hidden.insert(id) }; return }
            for c in children[id] ?? [] { visit(c, d + 1, path.union([id])) }
        }
        for r in roots { visit(r.id, 0, []) }
        let nodes = order.enumerated().map { i, id in
            SkillNode(id: id, name: name(id), depth: depth[id]!, x: Double(depth[id]!) * columnWidth, y: Double(i) * rowHeight, hasHiddenChildren: hidden.contains(id))
        }
        let shown = Set(order)
        let edges = relations.filter { shown.contains($0.fromSkillId) && shown.contains($0.toSkillId) && ($0.kind == .hierarchy || $0.kind == .prerequisite) }
            .map { SkillEdge(from: $0.fromSkillId, to: $0.toSkillId, kind: $0.kind) }
        return (nodes, edges)
    }
}

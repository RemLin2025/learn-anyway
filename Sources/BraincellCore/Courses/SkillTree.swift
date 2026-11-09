import Foundation

public enum SkillTree {
    public struct Row: Sendable, Equatable { public var skill: Skill; public var depth: Int }

    /// Depth-first, name-sorted flattening of the hierarchy relations. A skill with several parents
    /// appears under each; relations whose endpoints are not in `skills` are ignored.
    public static func flatten(_ skills: [Skill], relations: [SkillRelation]) -> [Row] {
        let byId = Dictionary(uniqueKeysWithValues: skills.map { ($0.id, $0) })
        let edges = relations.filter { $0.kind == .hierarchy && byId[$0.fromSkillId] != nil && byId[$0.toSkillId] != nil }
        var children: [UUID: [Skill]] = [:]
        for e in edges { children[e.fromSkillId, default: []].append(byId[e.toSkillId]!) }
        let childIds = Set(edges.map(\.toSkillId))
        func byName(_ a: Skill, _ b: Skill) -> Bool { a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending }
        var rows: [Row] = []
        func visit(_ s: Skill, _ depth: Int, _ path: Set<UUID>) {
            guard !path.contains(s.id) else { return }
            rows.append(Row(skill: s, depth: depth))
            for c in (children[s.id] ?? []).sorted(by: byName) { visit(c, depth + 1, path.union([s.id])) }
        }
        for r in skills.filter({ !childIds.contains($0.id) }).sorted(by: byName) { visit(r, 0, []) }
        return rows
    }
}

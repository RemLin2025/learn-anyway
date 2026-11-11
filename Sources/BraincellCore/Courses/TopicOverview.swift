import Foundation
import GRDB

/// What the Topics tab shows for one topic: where it sits, how important it is (and how we know), what backs it, and what practice exists.
public struct TopicRow: Sendable, Identifiable, Equatable {
    public enum Weight: Sendable, Equatable {
        case official(Double)         // instructor-stated percent, with a quote in the study map
        case estimate(Double?)        // heuristic study share (percent), not an exam percentage
        case userSet                  // the learner chose a level
        case unknown
        public var label: String {
            switch self {
            case .official(let p): "Official \(Int(p.rounded()))%"
            case .estimate(let p): p.map { "Study estimate ~\(Int($0.rounded()))%" } ?? "Study estimate"
            case .userSet: "Set by you"
            case .unknown: "Importance unknown"
            }
        }
    }
    public var skill: Skill
    public var depth: Int
    public var hasChildren: Bool
    public var inScope: Bool                 // in the selected assessment (true when no assessment is selected)
    public var weight: Weight
    public var level: String?                // high | medium | low, from the study map when present
    public var evidence: String
    public var sources: [StudyMapDocument.SourceRef]
    public var questionCount: Int
    public var id: UUID { skill.id }
}

public extension CourseService {
    /// Topic rows for a course, optionally viewed through one assessment's scope. Weights come from the saved study map (official vs.
    /// estimate) and are never invented: a topic without evidence is `unknown`.
    func topicRows(courseId: UUID, assessmentId: UUID?, store: AgentStore) throws -> [TopicRow] {
        let skills = try self.skills(courseId: courseId)
        let rels = try relations(courseId: courseId)
        let flat = SkillTree.flatten(skills, relations: rels)
        let parents = Set(rels.filter { $0.kind == .hierarchy }.map(\.fromSkillId))
        let scoped: [UUID: AssessmentSkill] = try assessmentId.map { a in
            Dictionary(uniqueKeysWithValues: try db.read { try AssessmentSkill.filter(Column("assessmentId") == a).fetchAll($0) }.map { ($0.skillId, $0) })
        } ?? [:]
        let counts: [UUID: Int] = try db.read { d in
            Dictionary(uniqueKeysWithValues: try Row.fetchAll(d, sql: "SELECT skillId, COUNT(*) c FROM question_skills qs JOIN questions q ON q.id = qs.questionId WHERE q.archivedAt IS NULL AND q.courseId = ? GROUP BY skillId", arguments: [courseId]).map { ($0["skillId"] as UUID, $0["c"] as Int) })
        }
        let map = (try store.maps(courseId: courseId).first { $0.assessmentId == assessmentId } ?? store.maps(courseId: courseId).first)?.document
        let shares = map.map { StudyPrep.shares($0.topics) } ?? [:]
        return flat.map { r in
            let t = map?.topics.first { AgentContext.norm($0.name) == AgentContext.norm(r.skill.name) }
            let a = scoped[r.skill.id]
            var w: TopicRow.Weight = .unknown
            if a?.importanceSource == .userAdjusted { w = .userSet }
            else if let t, t.importance.source == .instructor, let p = t.importance.weightPercent { w = .official(p) }
            else if let t, t.importance.source == .estimated { w = .estimate(shares[t.name]) }
            return TopicRow(skill: r.skill, depth: r.depth, hasChildren: parents.contains(r.skill.id), inScope: assessmentId == nil || a != nil, weight: w,
                            level: a?.importanceSource == .userAdjusted ? a?.importance.map { $0 >= 0.66 ? "high" : $0 >= 0.33 ? "medium" : "low" } : (t?.importance.level == "unknown" ? nil : t?.importance.level),
                            evidence: t?.importance.evidence ?? "", sources: t?.sources ?? [], questionCount: counts[r.skill.id] ?? 0)
        }
    }

    /// The learner's own importance choice. Survives re-analysis because later syncs never overwrite an existing scope row.
    func setImportance(assessmentId: UUID, skillId: UUID, level: String) throws {
        try addToScope(assessmentId: assessmentId, skillId: skillId, importance: level == "high" ? 0.9 : level == "medium" ? 0.5 : 0.15, source: .userAdjusted)
    }

    /// Folds `from` into `into`: questions, assessment scope and relations move over (nothing is deleted), then `from` is archived.
    func mergeSkills(from: UUID, into: UUID) throws {
        guard from != into else { return }
        try db.write { d in
            guard let a = try Skill.fetchOne(d, key: from), let b = try Skill.fetchOne(d, key: into), a.archivedAt == nil, b.archivedAt == nil else { throw CourseError.notFound }
            try d.execute(sql: "UPDATE OR IGNORE question_skills SET skillId = ? WHERE skillId = ?", arguments: [into, from])
            try d.execute(sql: "DELETE FROM question_skills WHERE skillId = ?", arguments: [from])
            try d.execute(sql: "UPDATE OR IGNORE assessment_skills SET skillId = ? WHERE skillId = ?", arguments: [into, from])
            try d.execute(sql: "DELETE FROM assessment_skills WHERE skillId = ?", arguments: [from])
            try d.execute(sql: "UPDATE OR IGNORE skill_relations SET fromSkillId = ? WHERE fromSkillId = ?", arguments: [into, from])
            try d.execute(sql: "UPDATE OR IGNORE skill_relations SET toSkillId = ? WHERE toSkillId = ?", arguments: [into, from])
            try d.execute(sql: "DELETE FROM skill_relations WHERE fromSkillId = ? OR toSkillId = ? OR fromSkillId = toSkillId", arguments: [from, from])
            var s = a; s.archivedAt = Date(); try s.update(d)
        }
    }
}

import Foundation
import GRDB

public enum PracticeDifficulty: String, CaseIterable, Sendable, Identifiable {
    case mixed = "Mixed", easy = "Easy", medium = "Medium", hard = "Hard"
    public var id: String { rawValue }
    public func contains(_ d: Int) -> Bool { switch self { case .mixed: true; case .easy: d <= 2; case .medium: d == 3; case .hard: d >= 4 } }
}
public enum PracticeKind: String, CaseIterable, Sendable, Identifiable {
    case topic = "Topic practice", mixed = "Mixed practice", exam = "Exam practice"
    public var id: String { rawValue }
}

public struct PracticeCandidate: Sendable, Equatable { public var id: UUID; public var skillIds: [UUID]; public var difficulty: Int; public var type: QuestionType
    public init(id: UUID, skillIds: [UUID], difficulty: Int, type: QuestionType) { self.id = id; self.skillIds = skillIds; self.difficulty = difficulty; self.type = type } }

public enum PracticeSelector {
    /// Picks `count` questions: filters by difficulty/type/topics, gives every chosen topic at least one question when the count allows,
    /// then spreads the rest in proportion to `weights` (study priority: a heuristic, not the real exam split). Deterministic, no repeats.
    public static func select(_ all: [PracticeCandidate], count: Int, skills: Set<UUID>, weights: [UUID: Double], difficulty: PracticeDifficulty, types: Set<QuestionType>) -> [UUID] {
        let pool = all.filter { c in difficulty.contains(c.difficulty) && (types.isEmpty || types.contains(c.type)) && (skills.isEmpty || c.skillIds.contains { skills.contains($0) }) }
            .sorted { $0.id.uuidString < $1.id.uuidString }
        guard count > 0, !pool.isEmpty else { return [] }
        let topics = (skills.isEmpty ? Set(pool.flatMap(\.skillIds)) : skills).filter { s in pool.contains { $0.skillIds.contains(s) } }.sorted { $0.uuidString < $1.uuidString }
        var picked: [UUID] = [], used = Set<UUID>()
        func take(for s: UUID) -> Bool {
            // Alternate difficulties inside a topic so "mixed" really is mixed.
            let cands = pool.filter { !used.contains($0.id) && $0.skillIds.contains(s) }
            let target = 2 + picked.count % 3                 // cycles 2,3,4 so a topic's questions span difficulties
            guard let c = cands.min(by: { (a: PracticeCandidate, b: PracticeCandidate) -> Bool in abs(a.difficulty - target) < abs(b.difficulty - target) }) else { return false }
            used.insert(c.id); picked.append(c.id); return true
        }
        if count >= topics.count { for s in topics where picked.count < count { _ = take(for: s) } }
        let total = topics.reduce(0.0) { $0 + max(0.05, weights[$1] ?? 1) }
        var quota = Dictionary(uniqueKeysWithValues: topics.map { ($0, Int((Double(count) * max(0.05, weights[$0] ?? 1) / max(total, 0.0001)).rounded(.down))) })
        for s in topics { var have = picked.filter { id in pool.first { $0.id == id }?.skillIds.contains(s) == true }.count
            while have < (quota[s] ?? 0), picked.count < count, take(for: s) { have += 1 } }
        quota.removeAll()
        var i = 0
        while picked.count < count, !topics.isEmpty, i < count * max(1, topics.count) * 2 { _ = take(for: topics[i % topics.count]); i += 1 }
        for c in pool where picked.count < count && !used.contains(c.id) { picked.append(c.id); used.insert(c.id) }
        return picked
    }
}

public extension PracticeService {
    func candidates(courseId: UUID, assessmentId: UUID?) throws -> [PracticeCandidate] {
        let ids = Set(try questionIds(courseId: courseId, assessmentId: assessmentId))
        var f = QuestionFilter(); f.courseId = courseId
        let rows = try QuestionService(db: db).list(f).filter { ids.contains($0.id) }
        let skillsByQ: [UUID: [UUID]] = try db.read { d in
            Dictionary(grouping: try Row.fetchAll(d, sql: "SELECT questionId, skillId FROM question_skills"), by: { $0["questionId"] as UUID }).mapValues { $0.map { $0["skillId"] as UUID } }
        }
        return rows.map { PracticeCandidate(id: $0.id, skillIds: skillsByQ[$0.id] ?? [], difficulty: $0.difficulty, type: $0.question.type) }
    }
}

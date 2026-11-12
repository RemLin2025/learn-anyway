import Foundation
import GRDB

public struct PlanSlot: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var topic: String
    public var reasoningSkill: String?
    public var archetype: String
    public var difficulty: Int
    public var format: String                       // "single_choice", "any", …
    public var exemplars: [SourceQuestionRef]
    public var exemplarSummary: String?             // a compact description of the source technique (not the source text)
    public var rationale: String
    public var archetypeKey: String? = nil          // the reusable course-level archetype this slot follows (nil for plans made before archetypes existed)
}

public struct GenerationPlan: Codable, Equatable, Sendable {
    public var mode: GenerationMode
    public var slots: [PlanSlot]
    public var excludedTopics: [String]
    public var limitations: [String]
    public var styleUsed: Bool
    public var weakTargets: [String]               // local summary of weaker topic names; no attempts or scores are sent
}

public enum GenerationPlanner {
    public struct TopicInput: Sendable { public var name: String; public var existingCount: Int; public var weak: Bool
        public init(name: String, existingCount: Int, weak: Bool = false) { self.name = name; self.existingCount = existingCount; self.weak = weak } }

    /// Interleaves `weights` into a list of `total` keys by largest remainder, so a distribution is followed across the whole task, not per batch.
    static func allocate(_ weights: [String: Int], total: Int) -> [String] {
        let sum = weights.values.reduce(0, +)
        guard sum > 0, total > 0 else { return [] }
        let exact = weights.map { ($0.key, Double($0.value) * Double(total) / Double(sum)) }.sorted { $0.0 < $1.0 }
        var counts = Dictionary(uniqueKeysWithValues: exact.map { ($0.0, Int($0.1)) })
        var left = total - counts.values.reduce(0, +)
        for (k, v) in exact.sorted(by: { ($0.1 - floor($0.1), $1.0) > ($1.1 - floor($1.1), $0.0) }) where left > 0 { counts[k, default: 0] += 1; left -= 1; _ = v }
        var out: [String] = []
        let keys = counts.keys.sorted()
        while out.count < total { var moved = false; for k in keys where (counts[k] ?? 0) > 0 { out.append(k); counts[k]! -= 1; moved = true; if out.count == total { break } }; if !moved { break } }
        return out
    }

    public static func plan(mode: GenerationMode, count: Int, topics: [TopicInput], sources: [SourceQuestionRow], profile: StyleProfile?, config: AssessmentConfig, excluded: [String], archetypes: [ArchetypeModel] = []) -> GenerationPlan {
        var limitations: [String] = []
        var pool = topics.sorted { ($0.existingCount, $0.name) < ($1.existingCount, $1.name) }       // least-covered first
        if mode == .weakSkills {
            let weak = pool.filter(\.weak)
            if weak.isEmpty { limitations.append("No weaker topics could be identified from your practice yet, so topics are balanced instead.") } else { pool = weak }
        }
        if pool.isEmpty { return GenerationPlan(mode: mode, slots: [], excludedTopics: excluded, limitations: ["No topics are in scope."], styleUsed: false, weakTargets: []) }
        let styleOK = profile?.sufficientForStyleMatching == true
        var mode = mode
        if (mode == .matchInstructorStyle || mode == .similarReasoning) && sources.isEmpty {
            limitations.append("No analyzed instructor questions are available, so this is general practice rather than instructor-style practice.")
            mode = .broaderTopics
        } else if mode == .matchInstructorStyle && !styleOK {
            limitations.append("Too few complete source questions were recovered to describe the instructor's style reliably; using what was found as examples only.")
        }
        let format = config.format ?? profile?.formats.value.max { $0.value < $1.value }?.key ?? "any"
        let norm: (String) -> String = { $0.skillKey }
        func topicFor(_ i: Int, prefer names: [String]) -> TopicInput {
            if let hit = pool.first(where: { t in names.contains { norm($0) == norm(t.name) } }) { return hit }
            return pool[i % pool.count]
        }
        func exemplar(_ r: SourceQuestionRow?) -> ([SourceQuestionRef], String?) {
            guard let r else { return ([], nil) }
            let p = r.payload
            let summary = ([p.primaryArchetype.isEmpty ? nil : "archetype \(p.primaryArchetype)", p.requested.isEmpty ? nil : "asks: \(String(p.requested.prefix(160)))", p.steps.isEmpty ? nil : "method: " + p.steps.prefix(5).map(\.description).joined(separator: " → ")].compactMap { $0 }).joined(separator: "; ")
            return ([SourceQuestionRef(sourceQuestionId: r.id.uuidString, document: r.documentTitle, page: p.pages.first, locator: p.locator)], summary.isEmpty ? nil : String(summary.prefix(500)))
        }
        var slots: [PlanSlot] = []
        let completeSources = sources.filter { $0.payload.isComplete }
        let usable = completeSources.isEmpty ? sources : completeSources
        switch mode {
        case .similarReasoning:
            let ordered = usable.sorted { ($0.documentTitle, $0.payload.locator) < ($1.documentTitle, $1.payload.locator) }
            for i in 0..<count {
                let s = ordered[i % ordered.count]
                let t = topicFor(i, prefer: s.payload.topics)
                let (ex, sum) = exemplar(s)
                slots.append(PlanSlot(id: "s\(i + 1)", topic: t.name, reasoningSkill: s.payload.reasoningSkills.first, archetype: s.payload.primaryArchetype.isEmpty ? Archetype.multistepCalculation.rawValue : s.payload.primaryArchetype,
                                      difficulty: s.payload.difficulty, format: format, exemplars: ex, exemplarSummary: sum, rationale: "Same reasoning as a source question, in a new scenario with a different construction."))
            }
        case .matchInstructorStyle:
            let archs = allocate(profile?.archetypes.value.filter { !$0.key.isEmpty } ?? [:], total: count)
            let diffs = allocate(profile?.difficulty.value ?? [:], total: count)
            for i in 0..<count {
                let a = archs.isEmpty ? Archetype.multistepCalculation.rawValue : archs[i % archs.count]
                let used = Set(slots.compactMap { $0.exemplars.first?.sourceQuestionId })
                let sameArch = usable.filter { $0.payload.primaryArchetype == a }
                let ex = sameArch.first { !used.contains($0.id.uuidString) } ?? sameArch.first
                let t = topicFor(i, prefer: ex?.payload.topics ?? [])
                let (e, sum) = exemplar(ex)
                slots.append(PlanSlot(id: "s\(i + 1)", topic: t.name, reasoningSkill: ex?.payload.reasoningSkills.first, archetype: a, difficulty: Int(diffs.isEmpty ? "3" : diffs[i % diffs.count]) ?? 3, format: format,
                                      exemplars: e, exemplarSummary: sum, rationale: "Follows the observed distribution of archetypes and difficulty."))
            }
        case .broaderTopics, .weakSkills:
            let archs = Archetype.allCases.map(\.rawValue)
            let diffCycle = mode == .weakSkills ? [2, 3, 3, 4] : [2, 3, 4, 3, 2, 5]
            for i in 0..<count {
                let t = pool[i % pool.count]
                let a = archs[(i / max(1, pool.count) + i) % archs.count]
                let sameTopic = sources.first { $0.payload.topics.contains { norm($0) == norm(t.name) } && $0.payload.primaryArchetype == a }
                let (e, sum) = exemplar(sameTopic)
                slots.append(PlanSlot(id: "s\(i + 1)", topic: t.name, reasoningSkill: sameTopic?.payload.reasoningSkills.first, archetype: a, difficulty: diffCycle[i % diffCycle.count], format: format,
                                      exemplars: e, exemplarSummary: sum, rationale: mode == .weakSkills ? "Targets a weaker topic." : "Covers the least-practised topics with varied reasoning demands."))
            }
        }
        // Slots follow the aggregated course-level archetype (merged method, constraints, mistakes) instead of one source question's description.
        let byKey = Dictionary(archetypes.map { ($0.key, $0) }, uniquingKeysWith: { a, _ in a })
        for i in slots.indices {
            guard let sid = slots[i].exemplars.first?.sourceQuestionId, let r = sources.first(where: { $0.id.uuidString == sid }), let a = byKey[ArchetypeLibrary.key(for: r.payload)] else { continue }
            slots[i].archetypeKey = a.key; slots[i].exemplarSummary = ArchetypeLibrary.summary(a)
            slots[i].exemplars = [slots[i].exemplars[0]] + a.sources.filter { $0.sourceQuestionId != sid }.prefix(2)
        }
        return GenerationPlan(mode: mode, slots: slots, excludedTopics: excluded, limitations: limitations, styleUsed: mode == .matchInstructorStyle && styleOK,
                              weakTargets: mode == .weakSkills ? pool.filter(\.weak).map(\.name) : [])
    }
}

public final class GenerationPlanStore: @unchecked Sendable {
    let db: AppDatabase
    public init(db: AppDatabase) { self.db = db }

    static func load(_ d: Database, taskId: UUID) throws -> GenerationPlan? {
        try String.fetchOne(d, sql: "SELECT planJSON FROM generation_plans WHERE taskId = ?", arguments: [taskId]).flatMap { try? JSONDecoder().decode(GenerationPlan.self, from: Data($0.utf8)) }
    }
    static func unmet(_ d: Database, taskId: UUID) throws -> [PlanSlot] {
        guard let p = try load(d, taskId: taskId) else { return [] }
        let met = Set(try String.fetchAll(d, sql: "SELECT slotId FROM question_provenance WHERE planId = ? AND slotId IS NOT NULL", arguments: [taskId.uuidString]))
        return p.slots.filter { !met.contains($0.id) }
    }

    public func save(_ p: GenerationPlan, taskId: UUID) throws {
        let json = String(data: try JSONEncoder().encode(p), encoding: .utf8) ?? "{}"
        try db.write { try $0.execute(sql: "INSERT OR REPLACE INTO generation_plans (taskId, mode, planJSON, createdAt) VALUES (?,?,?,?)", arguments: [taskId, p.mode.rawValue, json, Date()]) }
    }
    public func load(taskId: UUID) throws -> GenerationPlan? {
        try db.read { try String.fetchOne($0, sql: "SELECT planJSON FROM generation_plans WHERE taskId = ?", arguments: [taskId]) }.flatMap { try? JSONDecoder().decode(GenerationPlan.self, from: Data($0.utf8)) }
    }
    /// Slots with no accepted question yet, across the whole task. Survives restarts, continuation and repair.
    public func unmetSlots(taskId: UUID) throws -> [PlanSlot] {
        guard let p = try load(taskId: taskId) else { return [] }
        let met = Set(try db.read { try String.fetchAll($0, sql: "SELECT slotId FROM question_provenance WHERE planId = ? AND slotId IS NOT NULL", arguments: [taskId.uuidString]) })
        return p.slots.filter { !met.contains($0.id) }
    }
    /// Local summary of weaker topic names (lowest measured mastery). Only names are returned; no attempts, answers or scores leave the Mac.
    public static func weakTopicNames(db: AppDatabase, courseId: UUID, limit: Int = 6) throws -> [String] {
        let skills = try CourseService(db: db).skills(courseId: courseId)
        let m = try ProgressionService(db: db).masteries(courseId: courseId)
        return skills.compactMap { s -> (String, Double)? in guard let x = m[s.id], !x.isUnknown, let o = x.overall, o < 0.6 else { return nil }; return (s.name, o) }.sorted { $0.1 < $1.1 }.prefix(limit).map(\.0)
    }
}

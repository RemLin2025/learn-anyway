import Foundation
import GRDB

/// A course-level problem pattern: what kind of problem it is, which topics it touches and which reasoning steps solve it, aggregated across every
/// analyzed document. It is independent of any assessment, practice format or renderer: those *select* archetypes, they do not own them.
public struct ArchetypeModel: Codable, Equatable, Sendable, Identifiable {
    public var id: String { key }
    public var key: String                          // stable identity: kind | primary topic | primary reasoning skill (normalized)
    public var kind: String                         // Archetype raw value, or "unclassified"
    public var title: String
    public var topics: [String], subtopics: [String], objectives: [String]
    public var reasoningSkills: [String]
    public var steps: [SolutionStep]                // required reasoning steps, merged across sources (richest source first)
    public var concepts: [String], formulas: [String]
    public var given: [String], requested: [String], assumptions: [String]   // problem structure
    public var answerFormat: String                 // dominant format; "" when unknown
    public var formats: [String: Int]
    public var intervalChoices: Bool
    public var roundingDecimals: Int?
    public var difficultyTypical: Int, difficultyMin: Int, difficultyMax: Int
    public var mistakes: [String], distractors: [String]
    public var constraints: [String]                // rules a valid variation must keep
    public var sources: [SourceQuestionRef]         // original references; never copied question text
    public var sourceCount: Int, completeCount: Int
    public var confidence: Double                   // heuristic 0–0.9 from how many complete sources support it; never 1.0
    public var verification: String                 // "source-extracted" (taken from instructor material, answers not independently checked) | "incomplete-source"
    public var fingerprint: String                  // hash of the source questions this was built from; reuse elsewhere is keyed on it
}

public struct ArchetypeBuildReport: Equatable, Sendable { public var rebuilt: Bool; public var upserted: Int; public var unchanged: Int; public var removed: Int }

public final class ArchetypeLibrary: @unchecked Sendable {
    public static let version = "arch.v1"
    let db: AppDatabase
    public init(db: AppDatabase) { self.db = db }

    public static func key(for p: SourceQuestionPayload) -> String {
        let kind = Archetype(rawValue: p.primaryArchetype)?.rawValue ?? (p.primaryArchetype.isEmpty ? "unclassified" : p.primaryArchetype.skillKey)
        return [kind, p.topics.first?.skillKey ?? "", p.reasoningSkills.first?.skillKey ?? ""].joined(separator: "|")
    }

    // MARK: Aggregation (pure)

    static func build(key: String, rows: [SourceQuestionRow]) -> ArchetypeModel {
        let ps = rows.map(\.payload).sorted { $0.richness > $1.richness }
        func uniq(_ xs: [String], cap: Int = 12) -> [String] {
            var seen = Set<String>(), out: [String] = []
            for x in xs { let t = x.trimmingCharacters(in: .whitespacesAndNewlines); if !t.isEmpty, seen.insert(t.skillKey).inserted { out.append(t); if out.count == cap { break } } }
            return out
        }
        var seenStep = Set<String>(), steps: [SolutionStep] = []
        for s in ps.flatMap(\.steps) where seenStep.insert(s.description.skillKey).inserted && steps.count < 10 { steps.append(s) }
        let formats = ps.map(\.format).filter { !$0.isEmpty }.reduce(into: [String: Int]()) { $0[$1, default: 0] += 1 }
        let diffs = ps.map(\.difficulty).sorted()
        let complete = ps.filter(\.isComplete).count
        let kind = key.split(separator: "|", omittingEmptySubsequences: false).first.map(String.init) ?? "unclassified"
        let interval = ps.contains { $0.intervalChoices }, rounding = ps.compactMap(\.roundingDecimals).first
        let assumptions = uniq(ps.flatMap(\.assumptions), cap: 6)
        var cons = ["Keep the reasoning steps and the answer format; change the scenario, quantities and construction, not only numbers or names.",
                    "Every probability must be valid (non-negative, correct totals) and every value inside its support or domain."]
        if interval { cons.append("Answer choices are non-overlapping numeric intervals; exactly one contains the correct result after rounding.") }
        if let r = rounding { cons.append("Round final answers to \(r) decimal places.") }
        if !assumptions.isEmpty { cons.append("Keep these assumptions stated or implied: " + assumptions.prefix(3).joined(separator: "; ") + ".") }
        if formats.keys.contains(where: { $0.contains("choice") }) { cons.append("Build distractors from the listed common mistakes, not random numbers.") }
        cons += ps.flatMap { $0.variationConstraints ?? [] }
        var refs: [SourceQuestionRef] = [], seenRef = Set<String>()
        for r in rows.sorted(by: { ($0.documentTitle, $0.payload.locator) < ($1.documentTitle, $1.payload.locator) }) where seenRef.insert(r.id.uuidString).inserted {
            refs.append(SourceQuestionRef(sourceQuestionId: r.id.uuidString, document: r.documentTitle, page: r.payload.pages.first, locator: r.payload.locator))
        }
        let fp = QuestionHashing.sha256(version + "|" + rows.map { "\($0.id)|\($0.payload.richness)" }.sorted().joined(separator: ","))
        return ArchetypeModel(key: key, kind: kind, title: (Archetype(rawValue: kind)?.title ?? "Unclassified") + (ps.first?.topics.first.map { " · \($0)" } ?? ""),
                              topics: uniq(ps.flatMap(\.topics), cap: 6), subtopics: uniq(ps.flatMap(\.subtopics)), objectives: uniq(ps.map(\.objective), cap: 6),
                              reasoningSkills: uniq(ps.flatMap(\.reasoningSkills)), steps: steps, concepts: uniq(ps.flatMap { $0.concepts ?? [] }), formulas: uniq(ps.flatMap { $0.formulas ?? [] }),
                              given: uniq(ps.flatMap(\.given), cap: 8), requested: uniq(ps.map(\.requested), cap: 6), assumptions: assumptions,
                              answerFormat: formats.max { ($0.value, $1.key) < ($1.value, $0.key) }?.key ?? "", formats: formats, intervalChoices: interval, roundingDecimals: rounding,
                              difficultyTypical: diffs.isEmpty ? 3 : diffs[diffs.count / 2], difficultyMin: diffs.first ?? 3, difficultyMax: diffs.last ?? 3,
                              mistakes: uniq(ps.flatMap(\.mistakes) + ps.flatMap(\.steps).compactMap(\.commonError)), distractors: uniq(ps.flatMap(\.distractorRationale)),
                              constraints: uniq(cons, cap: 14), sources: refs, sourceCount: rows.count, completeCount: complete,
                              confidence: rows.isEmpty ? 0 : min(0.9, 0.2 + 0.2 * Double(complete)), verification: complete > 0 ? "source-extracted" : "incomplete-source", fingerprint: fp)
    }

    // MARK: Persistence

    /// Brings the course's archetypes in line with its current (non-stale) source analyses. A no-op when nothing underneath changed:
    /// the whole-course fingerprint is compared first, then each archetype's own, so unchanged archetypes keep their ids and timestamps.
    @discardableResult
    public func rebuildIfNeeded(courseId: UUID) throws -> ArchetypeBuildReport {
        let rows = try SourceAnalysisService(db: db, gateway: nil).sourceQuestions(courseId: courseId)
        let whole = QuestionHashing.sha256(Self.version + "|" + rows.map { "\($0.id)|\($0.payload.richness)" }.sorted().joined(separator: ","))
        return try db.write { d in
            if try String.fetchOne(d, sql: "SELECT fingerprint FROM archetype_aggregates WHERE courseId = ?", arguments: [courseId]) == whole { return ArchetypeBuildReport(rebuilt: false, upserted: 0, unchanged: 0, removed: 0) }
            let groups = Dictionary(grouping: rows, by: { Self.key(for: $0.payload) })
            var upserted = 0, unchanged = 0
            for (key, g) in groups {
                let m = Self.build(key: key, rows: g)
                if let ex = try Row.fetchOne(d, sql: "SELECT id, fingerprint FROM course_archetypes WHERE courseId = ? AND key = ?", arguments: [courseId, key]) {
                    if (ex["fingerprint"] as String) == m.fingerprint { unchanged += 1; continue }
                    let id: UUID = ex["id"]
                    try d.execute(sql: "UPDATE course_archetypes SET modelJSON = ?, fingerprint = ?, updatedAt = ? WHERE id = ?", arguments: [Self.json(m), m.fingerprint, Date(), id])
                    try d.execute(sql: "DELETE FROM course_archetype_sources WHERE archetypeId = ?", arguments: [id])
                    for r in g { try d.execute(sql: "INSERT INTO course_archetype_sources (archetypeId, sourceQuestionId) VALUES (?,?)", arguments: [id, r.id]) }
                } else {
                    let id = UUID()
                    try d.execute(sql: "INSERT INTO course_archetypes (id, courseId, key, kind, modelJSON, fingerprint, updatedAt) VALUES (?,?,?,?,?,?,?)", arguments: [id, courseId, key, m.kind, Self.json(m), m.fingerprint, Date()])
                    for r in g { try d.execute(sql: "INSERT INTO course_archetype_sources (archetypeId, sourceQuestionId) VALUES (?,?)", arguments: [id, r.id]) }
                }
                upserted += 1
            }
            let live = Set(groups.keys)
            var removed = 0
            for k in try String.fetchAll(d, sql: "SELECT key FROM course_archetypes WHERE courseId = ?", arguments: [courseId]) where !live.contains(k) {
                try d.execute(sql: "DELETE FROM course_archetypes WHERE courseId = ? AND key = ?", arguments: [courseId, k]); removed += 1      // no source supports it any more
            }
            try d.execute(sql: "INSERT INTO archetype_aggregates (courseId, fingerprint, builtAt) VALUES (?,?,?) ON CONFLICT(courseId) DO UPDATE SET fingerprint = excluded.fingerprint, builtAt = excluded.builtAt", arguments: [courseId, whole, Date()])
            return ArchetypeBuildReport(rebuilt: true, upserted: upserted, unchanged: unchanged, removed: removed)
        }
    }

    static func json(_ m: ArchetypeModel) -> String { String(data: (try? JSONEncoder().encode(m)) ?? Data(), encoding: .utf8) ?? "{}" }

    /// Archetypes for a course, optionally narrowed to topics (by normalized name) and without excluded topics. Rebuilds first only if the sources changed.
    public func archetypes(courseId: UUID, topics: [String]? = nil, excluding: [String] = [], kind: Archetype? = nil) throws -> [ArchetypeModel] {
        try rebuildIfNeeded(courseId: courseId)
        let all = try db.read { try String.fetchAll($0, sql: "SELECT modelJSON FROM course_archetypes WHERE courseId = ? ORDER BY key", arguments: [courseId]) }.compactMap { try? JSONDecoder().decode(ArchetypeModel.self, from: Data($0.utf8)) }
        let tk = topics?.map(\.skillKey), ek = excluding.map(\.skillKey)
        return all.filter { m in
            let mk = m.topics.map(\.skillKey)
            if let tk, !mk.contains(where: { t in tk.contains { $0 == t || $0.hasPrefix(t) || t.hasPrefix($0) } }) { return false }
            if !ek.isEmpty, !mk.isEmpty, mk.allSatisfy({ t in ek.contains { $0 == t || t.hasPrefix($0) } }) { return false }
            return kind == nil || m.kind == kind!.rawValue
        }
    }

    public func archetype(courseId: UUID, key: String) throws -> ArchetypeModel? {
        try rebuildIfNeeded(courseId: courseId)
        return try db.read { try String.fetchOne($0, sql: "SELECT modelJSON FROM course_archetypes WHERE courseId = ? AND key = ?", arguments: [courseId, key]) }.flatMap { try? JSONDecoder().decode(ArchetypeModel.self, from: Data($0.utf8)) }
    }

    /// Compact technique description for prompts: merged method, constraints and mistakes. No source text.
    public static func summary(_ m: ArchetypeModel) -> String {
        var p = ["archetype \(m.kind)"]
        if !m.requested.isEmpty { p.append("asks: " + String(m.requested[0].prefix(120))) }
        if !m.steps.isEmpty { p.append("method: " + m.steps.prefix(5).map(\.description).joined(separator: " → ")) }
        if !m.formulas.isEmpty { p.append("uses: " + m.formulas.prefix(3).joined(separator: "; ")) }
        if !m.mistakes.isEmpty { p.append("typical errors: " + m.mistakes.prefix(2).joined(separator: "; ")) }
        return String(p.joined(separator: "; ").prefix(600))
    }
}

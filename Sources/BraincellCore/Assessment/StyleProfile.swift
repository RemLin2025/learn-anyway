import Foundation
import GRDB

/// A value with where it came from and how sure we are. Confirmed instructions, inferred patterns and user-provided settings stay distinct.
public struct Observed<T: Codable & Equatable & Sendable>: Codable, Equatable, Sendable {
    public var value: T
    public var basis: ConfigBasis
    public var confidence: Double          // 0–1; 1 only for confirmed/user-provided
    public var refs: [String]              // "document · locator" supporting references
    public init(_ value: T, basis: ConfigBasis, confidence: Double, refs: [String] = []) { self.value = value; self.basis = basis; self.confidence = confidence; self.refs = refs }
}

public struct StyleProfile: Codable, Equatable, Sendable {
    public var formats: Observed<[String: Int]>
    public var archetypes: Observed<[String: Int]>
    public var difficulty: Observed<[String: Int]>          // "1"…"5" → count (a spread, not a measured difficulty)
    public var averageSteps: Observed<Double>
    public var reasoningSkills: Observed<[String: Int]>
    public var roundingDecimals: Observed<[String: Int]>
    public var choicePatterns: [String]                      // e.g. "numeric intervals in 3 of 9 choice questions"
    public var distractorPatterns: [String]
    public var coverage: Coverage
    public var config: AssessmentConfig
    public var limitations: [String]
    /// Enough recovered, complete source questions to imitate their style (not to infer exam weights).
    public var sufficientForStyleMatching: Bool

    public struct Coverage: Codable, Equatable, Sendable {
        public var documents: Int, documentsAnalyzed: Int
        public var questionsRecovered: Int, completeQuestions: Int
        public var windowsDone: Int, windowsTotal: Int
        public var isComplete: Bool { documents == documentsAnalyzed && windowsDone == windowsTotal && documents > 0 }
    }
}

public final class AssessmentService: @unchecked Sendable {
    public static let minQuestionsForStyle = 5
    let db: AppDatabase
    public init(db: AppDatabase) { self.db = db }

    // MARK: Config

    public func config(assessmentId: UUID) throws -> AssessmentConfig {
        try db.read { d in
            try String.fetchOne(d, sql: "SELECT configJSON FROM assessment_config WHERE assessmentId = ?", arguments: [assessmentId]).flatMap { try? JSONDecoder().decode(AssessmentConfig.self, from: Data($0.utf8)) }
        } ?? AssessmentConfig()
    }
    public func setConfig(_ c: AssessmentConfig, assessmentId: UUID) throws {
        let json = String(data: try JSONEncoder().encode(c), encoding: .utf8) ?? "{}"
        try db.write { try $0.execute(sql: "INSERT INTO assessment_config (assessmentId, configJSON, updatedAt) VALUES (?,?,?) ON CONFLICT(assessmentId) DO UPDATE SET configJSON = excluded.configJSON, updatedAt = excluded.updatedAt", arguments: [assessmentId, json, Date()]) }
    }

    // MARK: Scope

    public struct Scope: Equatable, Sendable { public var skillIds: [UUID]; public var excludedNames: [String]; public var limitations: [String] }

    /// Topics this assessment may draw on. Explicit includes/excludes are enforced: an empty result is an error, never a silent fallback to the
    /// whole course, and excluded topics (and their children) are removed even if the caller passed them or sources mention them.
    public func scope(courseId: UUID, assessmentId: UUID?, requested: [UUID], tasks: AITaskService) throws -> Scope {
        let courses = CourseService(db: db)
        let all = try courses.skills(courseId: courseId)
        let rels = try courses.relations(courseId: courseId).filter { $0.kind == .hierarchy }
        var children: [UUID: [UUID]] = [:]
        for r in rels { children[r.fromSkillId, default: []].append(r.toSkillId) }
        func subtree(_ roots: [Skill]) -> Set<UUID> {
            var out = Set<UUID>(), stack = roots.map(\.id)
            while let n = stack.popLast() { if out.insert(n).inserted { stack += children[n] ?? [] } }
            return out
        }
        func match(_ names: [String]) -> [Skill] { let keys = names.map(\.skillKey); return all.filter { s in keys.contains { s.normalizedName == $0 || s.normalizedName.hasPrefix($0) } } }

        let cfg = try assessmentId.map { try config(assessmentId: $0) } ?? AssessmentConfig()
        var base = requested
        if base.isEmpty, let a = assessmentId, let asm = try db.read({ try Assessment.fetchOne($0, key: a) }) { base = try db.read { try AITaskService.scopedSkillIds($0, asm) } }
        let explicit = cfg.hasExplicitScope
        if base.isEmpty && !explicit { base = all.map(\.id) }                       // no restriction anywhere: the whole course
        if base.isEmpty && explicit { base = all.map(\.id) }                         // includes/excludes narrow the whole course
        var allowed = Set(base)
        var lim: [String] = []
        if !cfg.scopeIncludes.isEmpty { allowed.formIntersection(subtree(match(cfg.scopeIncludes))); lim.append("Scope limited to: " + cfg.scopeIncludes.joined(separator: ", ")) }
        let excluded = subtree(match(cfg.scopeExcludes))
        allowed.subtract(excluded)
        if !cfg.scopeExcludes.isEmpty { lim.append("Excluded: " + cfg.scopeExcludes.joined(separator: ", ")) }
        if allowed.isEmpty && explicit { throw AITaskError.invalidParams("The assessment’s scope leaves no topics. Check the includes/excludes (\(cfg.scopeIncludes.joined(separator: ", ")) / \(cfg.scopeExcludes.joined(separator: ", "))).") }
        return Scope(skillIds: all.map(\.id).filter(allowed.contains), excludedNames: cfg.scopeExcludes, limitations: lim)
    }

    // MARK: Style profile

    /// Builds (and persists) the profile from the course's current source analyses. Cached by a fingerprint of those analyses and the config, so an
    /// unchanged bank is not recomputed.
    @discardableResult
    public func profile(courseId: UUID, assessmentId: UUID?) throws -> StyleProfile {
        let analyses = SourceAnalysisService(db: db, gateway: nil)
        let rows = try analyses.sourceQuestions(courseId: courseId)
        let cfg = try assessmentId.map { try config(assessmentId: $0) } ?? AssessmentConfig()
        let docs = try db.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM documents WHERE courseId = ? AND deletedAt IS NULL AND kind IN ('pdf','text','pasted')", arguments: [courseId]) ?? 0 }
        let stats = try db.read { try Row.fetchAll($0, sql: "SELECT documentId, windowsDone, windowsTotal, limitations FROM source_analyses WHERE courseId = ? AND status != 'stale'", arguments: [courseId]) }
        let cfgJSON = String(data: (try? JSONEncoder().encode(cfg)) ?? Data(), encoding: .utf8) ?? ""
        let fp = QuestionHashing.sha256(rows.map { "\($0.id)|\($0.payload.locator)|\($0.payload.richness)" }.joined() + cfgJSON + "\(stats.count)\(docs)")
        if let cached = try db.read({ try Row.fetchOne($0, sql: "SELECT profileJSON, fingerprint FROM style_profiles WHERE courseId = ? AND assessmentId IS ?", arguments: [courseId, assessmentId]) }),
           (cached["fingerprint"] as String) == fp, let p = try? JSONDecoder().decode(StyleProfile.self, from: Data((cached["profileJSON"] as String).utf8)) { return p }

        func count<K: Hashable>(_ xs: [K]) -> [K: Int] { xs.reduce(into: [:]) { $0[$1, default: 0] += 1 } }
        let refs = rows.map { "\($0.documentTitle) · \($0.payload.locator)" }
        let n = rows.count, complete = rows.filter { $0.payload.isComplete }.count
        let conf = n == 0 ? 0 : min(0.9, Double(complete) / Double(max(n, Self.minQuestionsForStyle * 2)))
        let formats = count(rows.map { $0.payload.format }.filter { !$0.isEmpty })
        let arch = count(rows.flatMap { [$0.payload.primaryArchetype] + $0.payload.secondaryArchetypes }.filter { !$0.isEmpty })
        let diff = Dictionary(uniqueKeysWithValues: count(rows.map { $0.payload.difficulty }).map { (String($0.key), $0.value) })
        let skills = count(rows.flatMap { $0.payload.reasoningSkills })
        let rounding = Dictionary(uniqueKeysWithValues: count(rows.compactMap { $0.payload.roundingDecimals }).map { (String($0.key), $0.value) })
        let steps = rows.isEmpty ? 0 : Double(rows.reduce(0) { $0 + $1.payload.steps.count }) / Double(rows.count)
        let choiceQs = rows.filter { $0.payload.choices != nil || $0.payload.format.contains("choice") }
        let intervals = choiceQs.filter { $0.payload.intervalChoices }.count
        var choicePatterns: [String] = []
        if !choiceQs.isEmpty { choicePatterns.append("\(choiceQs.count) of \(n) recovered questions are multiple choice" + (intervals > 0 ? "; \(intervals) use numeric-interval choices" : "")) }
        let distractors = Array(Set(rows.flatMap { $0.payload.distractorRationale })).sorted().prefix(8).map { $0 }
        var lim: [String] = ["Counts describe the practice bank's style. They are not exam topic weights."]
        let done = stats.reduce(0) { $0 + ($1["windowsDone"] as Int) }, total = stats.reduce(0) { $0 + ($1["windowsTotal"] as Int) }
        let docLimits = stats.compactMap { ($0["limitations"] as String).isEmpty ? nil : ($0["limitations"] as String) }
        lim += docLimits
        if stats.count < docs { lim.append("\(docs - stats.count) readable document(s) have not been analyzed.") }
        if done < total { lim.append("\(total - done) analysis window(s) are not finished, so the source bank may be incomplete.") }
        let sufficient = complete >= Self.minQuestionsForStyle
        if !sufficient { lim.append(n == 0 ? "No source questions have been analyzed yet; style matching isn't available, so general practice is offered." : "Only \(complete) complete source question(s) were recovered; that is too few to describe the style reliably.") }
        let p = StyleProfile(formats: Observed(formats, basis: .inferred, confidence: conf, refs: refs), archetypes: Observed(arch, basis: .inferred, confidence: conf, refs: refs),
                             difficulty: Observed(diff, basis: .inferred, confidence: min(conf, 0.6)), averageSteps: Observed(steps, basis: .inferred, confidence: conf),
                             reasoningSkills: Observed(skills, basis: .inferred, confidence: conf), roundingDecimals: Observed(rounding, basis: cfg.roundingDecimals == nil ? .inferred : .userProvided, confidence: conf),
                             choicePatterns: choicePatterns, distractorPatterns: distractors,
                             coverage: .init(documents: docs, documentsAnalyzed: stats.count, questionsRecovered: n, completeQuestions: complete, windowsDone: done, windowsTotal: total),
                             config: cfg, limitations: lim, sufficientForStyleMatching: sufficient)
        let json = String(data: try JSONEncoder().encode(p), encoding: .utf8) ?? "{}"
        try db.write { d in
            try d.execute(sql: "DELETE FROM style_profiles WHERE courseId = ? AND assessmentId IS ?", arguments: [courseId, assessmentId])
            try d.execute(sql: "INSERT INTO style_profiles (id, courseId, assessmentId, profileJSON, fingerprint, updatedAt) VALUES (?,?,?,?,?,?)", arguments: [UUID(), courseId, assessmentId, json, fp, Date()])
        }
        return p
    }
}

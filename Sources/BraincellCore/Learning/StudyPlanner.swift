import Foundation
import GRDB

public enum StudyMode: String, Codable, Sendable, CaseIterable { case cram, mastery }

public enum PlannerError: Error, LocalizedError, Equatable {
    case notFound, assessmentRequired, noBudget
    public var errorDescription: String? {
        switch self {
        case .notFound: "That course or assessment no longer exists."
        case .assessmentRequired: "Cram mode needs an assessment to aim at."
        case .noBudget: "Give the plan at least a few minutes."
        }
    }
}

/// Everything the user can constrain. The planner never goes outside these.
public struct PlanRequest: Sendable {
    public var courseId: UUID
    public var assessmentId: UUID?
    public var mode: StudyMode
    public var budgetMinutes: Int
    /// If non-empty, plan only these skills.
    public var focusSkillIds: Set<UUID> = []
    public var excludedSkillIds: Set<UUID> = []
    public var excludedQuestionIds: Set<UUID> = []
    public var maxDifficulty: Int?
    public var allowedTypes: Set<QuestionType>?
    public var now: Date = Date()
    public init(courseId: UUID, assessmentId: UUID? = nil, mode: StudyMode, budgetMinutes: Int) {
        self.courseId = courseId; self.assessmentId = assessmentId; self.mode = mode; self.budgetMinutes = budgetMinutes
    }
}

public struct PlannedItem: Sendable, Identifiable, Equatable {
    public var questionId: UUID
    public var skillId: UUID?
    public var skillName: String?
    public var kind: ItemKind
    /// Plain-language explanation shown to the learner.
    public var reason: String
    public var estimatedMinutes: Double
    public var title: String
    public var type: QuestionType
    public var priority: Double
    public var id: UUID { questionId }
}

public struct SkillPriority: Sendable {
    public var skill: Skill
    public var priority: Double
    public var mastery: SkillMastery
    public var note: String
}

public struct StudyPlan: Sendable {
    public var mode: StudyMode
    public var assessmentName: String?
    public var items: [PlannedItem]
    public var budgetMinutes: Int
    public var notes: [String]
    public var skills: [SkillPriority]
    public var totalMinutes: Double { items.reduce(0) { $0 + $1.estimatedMinutes } }
}

public struct Recommendation: Sendable {
    public var course: Course
    public var assessment: Assessment?
    public var plan: StudyPlan
    public var headline: String
}

/// Local, deterministic study planner: needs no AI and no network. Every choice carries a reason.
public struct PlannerService: Sendable {
    let db: AppDatabase
    let estimator: any MasteryEstimator
    public init(db: AppDatabase, estimator: any MasteryEstimator = HeuristicMasteryEstimator()) { self.db = db; self.estimator = estimator }

    static let defaultSeconds: [QuestionType: Double] = [
        .flashcard: 30, .singleChoice: 60, .multipleSelect: 90, .shortAnswer: 60, .numeric: 120,
        .codeTracing: 150, .coding: 600, .longForm: 420, .derivationProof: 600,
    ]

    // MARK: Plan

    public func plan(_ r: PlanRequest) throws -> StudyPlan {
        guard r.budgetMinutes >= 1 else { throw PlannerError.noBudget }
        if r.mode == .cram && r.assessmentId == nil { throw PlannerError.assessmentRequired }
        return try db.read { d in try Self.build(d, r, estimator: estimator) }
    }

    // MARK: Internals

    struct SkillInfo {
        var skill: Skill
        var mastery: SkillMastery
        var importance: Double
        var importanceText: String
        var daysSinceEvidence: Double?
        var lastScore: Double?
        var priority = 0.0
        var reasons: [String] = []
    }

    struct Candidate {
        var q: Question; var title: String; var difficulty: Int; var attempts: Int; var lastAttempt: Date?; var lastScore: Double?
        var minutes: Double
    }

    static func scopeSkills(_ d: Database, _ a: Assessment) throws -> [Skill] {
        if a.isCumulative {
            return try Skill.fetchAll(d, sql: "SELECT s.* FROM skills s JOIN course_skills c ON c.skillId = s.id WHERE c.courseId = ? AND s.archivedAt IS NULL ORDER BY s.name", arguments: [a.courseId])
        }
        return try Skill.fetchAll(d, sql: "SELECT s.* FROM skills s JOIN assessment_skills x ON x.skillId = s.id WHERE x.assessmentId = ? AND s.archivedAt IS NULL ORDER BY s.name", arguments: [a.id])
    }

    static func minutesByType(_ d: Database) throws -> [QuestionType: Double] {
        var out = defaultSeconds.mapValues { $0 / 60 }
        for row in try Row.fetchAll(d, sql: "SELECT q.type AS t, AVG(a.activeSeconds) AS avg, COUNT(*) AS n FROM attempts a JOIN questions q ON q.id = a.questionId GROUP BY q.type") {
            if let n: Int = row["n"], n >= 3, let avg: Double = row["avg"], avg >= 5, let t: QuestionType = row["t"] { out[t] = avg / 60 }
        }
        return out
    }

    static func build(_ d: Database, _ r: PlanRequest, estimator: any MasteryEstimator) throws -> StudyPlan {
        guard let course = try Course.fetchOne(d, key: r.courseId) else { throw PlannerError.notFound }
        let assessment = try r.assessmentId.flatMap { try Assessment.fetchOne(d, key: $0) }
        if r.assessmentId != nil && assessment == nil { throw PlannerError.notFound }
        var notes: [String] = []

        // 1. Scope: the exam's scope is authoritative; the user's constraints narrow it further.
        var skills = try assessment.map { try scopeSkills(d, $0) } ??
            Skill.fetchAll(d, sql: "SELECT s.* FROM skills s JOIN course_skills c ON c.skillId = s.id WHERE c.courseId = ? AND s.archivedAt IS NULL ORDER BY s.name", arguments: [course.id])
        let inScope = Set(skills.map(\.id))
        if !r.focusSkillIds.isEmpty { skills = skills.filter { r.focusSkillIds.contains($0.id) } }
        skills = skills.filter { !r.excludedSkillIds.contains($0.id) }

        // 2. Per-skill facts.
        let asmSkills: [UUID: AssessmentSkill] = try assessment.map { a in
            Dictionary(uniqueKeysWithValues: try AssessmentSkill.filter(Column("assessmentId") == a.id).fetchAll(d).map { ($0.skillId, $0) })
        } ?? [:]
        var infos: [UUID: SkillInfo] = [:]
        for s in skills {
            let evidence = try ProgressionEngine.evidenceInputs(d, skillId: s.id)
            let m = estimator.estimate(skillId: s.id, evidence: evidence, now: r.now)
            let (imp, text) = importance(asmSkills[s.id], assessmentImportance: assessment?.importance, assessmentSource: assessment?.importanceSource, assessment: assessment)
            let latest = try LearningEvidence.filter(Column("skillId") == s.id && Column("supersededAt") == nil).order(Column("occurredAt").desc).fetchOne(d)
            infos[s.id] = SkillInfo(skill: s, mastery: m, importance: imp, importanceText: text,
                                    daysSinceEvidence: latest.map { r.now.timeIntervalSince($0.occurredAt) / 86_400 }, lastScore: latest?.score)
        }

        // 3. Urgency.
        var urgency = 1.0
        if r.mode == .cram, let a = assessment {
            if let dl = a.deadline {
                let days = dl.timeIntervalSince(r.now) / 86_400
                if days < 0 { notes.append("\(a.name)’s deadline has passed; planning as if it were today.") }
                urgency = 1 + 0.5 * min(1, max(0, (14 - days) / 14))
                if days >= 0 && days <= 14 { for k in infos.keys { infos[k]!.reasons.append("\(a.name) is in \(Int(days.rounded(.up))) day\(Int(days.rounded(.up)) == 1 ? "" : "s")") } }
            } else { notes.append("\(a.name) has no deadline, so time pressure isn’t considered.") }
            if asmSkills.values.contains(where: { $0.importanceSource == .aiEstimate }) || a.importanceSource == .aiEstimate {
                notes.append("Some importance values are AI estimates; they are treated as a rough guess, not as confirmed exam weight.")
            }
        }

        // 4. Priorities: gap in what you can demonstrate, weighted by importance, plus uncertainty.
        for k in infos.keys {
            var i = infos[k]!
            let gap = i.mastery.isUnknown ? 0.7 : 1 - (i.mastery.overall ?? 0.5)
            let uncertainty = 0.25 * max(0, 1 - i.mastery.overallWeight / 4)
            switch r.mode {
            case .cram: i.priority = i.importance * gap * urgency + uncertainty
            case .mastery: i.priority = gap + 0.3 * min(1, (i.daysSinceEvidence ?? 0) / 60) + uncertainty
            }
            infos[k] = i
        }

        // 5. Prerequisites: a weak prerequisite is worked on first and its dependent waits (only within scope).
        let prereqs = try SkillRelation.filter(Column("kind") == SkillRelationKind.prerequisite).fetchAll(d)
        for rel in prereqs {
            guard var dep = infos[rel.toSkillId] else { continue }
            guard var pre = infos[rel.fromSkillId] else {
                if inScope.contains(rel.toSkillId), let p = try Skill.fetchOne(d, key: rel.fromSkillId), !inScope.contains(p.id) {
                    notes.append("“\(dep.skill.name)” builds on “\(p.name)”, which isn’t part of this plan’s scope.")
                }
                continue
            }
            if !pre.mastery.isUnknown, (pre.mastery.overall ?? 1) < 0.5 {
                pre.priority += 0.3 * dep.priority; pre.reasons.append("a prerequisite for “\(dep.skill.name)”, which depends on it")
                dep.priority *= 0.6; dep.reasons.append("waiting until “\(pre.skill.name)” improves")
                infos[rel.fromSkillId] = pre; infos[rel.toSkillId] = dep
            }
        }

        // 6. Candidate questions. Per-question facts come from three aggregate queries, not one query per question.
        let minutes = try minutesByType(d)
        let reviewDue: [UUID: Date] = Dictionary(try Row.fetchAll(d, sql: "SELECT questionId, due FROM review_states").map { ($0["questionId"] as UUID, $0["due"] as Date) }, uniquingKeysWith: { a, _ in a })
        var attemptStats: [UUID: (count: Int, last: Date)] = [:]
        for row in try Row.fetchAll(d, sql: "SELECT questionId, COUNT(*) AS c, MAX(submittedAt) AS m FROM attempts GROUP BY questionId") { attemptStats[row["questionId"]] = (row["c"], row["m"]) }
        var lastScores: [UUID: Double] = [:]
        for row in try Row.fetchAll(d, sql: """
            SELECT a.questionId AS q, e.score AS s FROM attempts a JOIN evaluations e ON e.attemptId = a.id AND e.supersededAt IS NULL AND e.score IS NOT NULL
            WHERE a.submittedAt = (SELECT MAX(t.submittedAt) FROM attempts t WHERE t.questionId = a.questionId)
            """) { lastScores[row["q"]] = row["s"] }
        var candidates: [UUID: [Candidate]] = [:]
        var used = Set<UUID>()
        var skillsWithoutQuestions: [String] = []
        for s in skills.sorted(by: { (infos[$0.id]?.priority ?? 0) > (infos[$1.id]?.priority ?? 0) }) {
            let rows = try Row.fetchAll(d, sql: """
                SELECT q.*, v.title AS vTitle, v.difficulty AS vDiff FROM questions q
                JOIN question_skills qs ON qs.questionId = q.id JOIN question_revisions v ON v.id = q.currentRevisionId
                WHERE qs.skillId = ? AND q.archivedAt IS NULL ORDER BY q.createdAt, q.rowid
                """, arguments: [s.id])
            var list: [Candidate] = []
            for row in rows {
                let q = try Question(row: row)
                let diff: Int = row["vDiff"]
                if used.contains(q.id) || r.excludedQuestionIds.contains(q.id) { continue }
                if let max = r.maxDifficulty, diff > max { continue }
                if let types = r.allowedTypes, !types.contains(q.type) { continue }
                if let due = reviewDue[q.id] {
                    if due > r.now { continue }                                                    // spaced repetition: not due yet
                    if ReviewEngine.isReviewable(q.type) { continue }                              // due cards are added as reviews
                }
                let st = attemptStats[q.id]
                list.append(Candidate(q: q, title: row["vTitle"], difficulty: diff, attempts: st?.count ?? 0, lastAttempt: st?.last, lastScore: lastScores[q.id],
                                      minutes: minutes[q.type] ?? 1))
            }
            if list.isEmpty { skillsWithoutQuestions.append(s.name); continue }
            let info = infos[s.id]!
            let target = info.mastery.isUnknown ? 2 : min(5, max(1, 1 + Int(((info.mastery.overall ?? 0.5) * 3).rounded())))
            func score(_ c: Candidate) -> Double {
                var v = 0.0
                if c.attempts == 0 { v += 0.4 }
                if let last = c.lastAttempt, r.now.timeIntervalSince(last) < 86_400 { v -= 0.6 }
                if c.attempts > 0, (c.lastScore ?? 1) < 0.5 { v += 0.3 }
                v -= 0.15 * Double(abs(c.difficulty - target))
                switch c.q.readiness { case .verified: v += 0.1; case .needsReview: v -= 0.3; default: break }
                return v
            }
            candidates[s.id] = list.sorted { score($0) > score($1) }
            for c in list { used.insert(c.q.id) }
        }
        if !skillsWithoutQuestions.isEmpty {
            notes.append("No questions yet for: \(skillsWithoutQuestions.prefix(4).joined(separator: ", "))\(skillsWithoutQuestions.count > 4 ? "…" : ""). Generate some in AI Tasks.")
        }

        // 7. Assemble: due reviews first, then a balanced rotation over the highest-priority skills.
        var items: [PlannedItem] = []
        var total = 0.0
        let reviewShare = r.mode == .cram ? 0.3 : 0.5
        let reviews = try dueReviews(d, r, scope: Set(skills.map(\.id)), minutes: minutes)
        for (rv, mins) in reviews where total + mins <= Double(r.budgetMinutes) * reviewShare || items.isEmpty && total + mins <= Double(r.budgetMinutes) {
            let days = rv.lastReview.map { Int(r.now.timeIntervalSince($0) / 86_400) }
            items.append(PlannedItem(questionId: rv.questionId, skillId: nil, skillName: nil, kind: .review,
                                     reason: "Due for review\(days.map { $0 == 0 ? " — last seen earlier today" : " — last seen \($0) day\($0 == 1 ? "" : "s") ago" } ?? ""); predicted recall ≈ \(Int((rv.retrievability * 100).rounded()))%.",
                                     estimatedMinutes: mins, title: rv.title, type: rv.type, priority: 10))
            total += mins
        }
        var picks: [UUID: Int] = [:]
        let approxItems = max(3, r.budgetMinutes / 3)
        let cap = max(2, Int((0.4 * Double(approxItems)).rounded(.up)))
        var exhausted = Set<UUID>()
        var last: UUID? = items.last?.skillId
        while true {
            let open = candidates.keys.filter { !exhausted.contains($0) && !(candidates[$0]?.isEmpty ?? true) && (picks[$0] ?? 0) < cap }
            guard !open.isEmpty else { break }
            let pool = open.count > 1 ? open.filter { $0 != last } : open
            let sid = pool.max { lhs, rhs in
                (infos[lhs]!.priority / (1 + 0.8 * Double(picks[lhs] ?? 0))) < (infos[rhs]!.priority / (1 + 0.8 * Double(picks[rhs] ?? 0)))
            }!
            guard let idx = candidates[sid]!.firstIndex(where: { total + $0.minutes <= Double(r.budgetMinutes) || items.isEmpty }) else { exhausted.insert(sid); continue }
            let c = candidates[sid]!.remove(at: idx)
            let info = infos[sid]!
            let repair = c.attempts > 0 && (c.lastScore ?? 1) < 0.5
            items.append(PlannedItem(questionId: c.q.id, skillId: sid, skillName: info.skill.name, kind: repair ? .repair : .advance,
                                     reason: explain(info, assessment: assessment, mode: r.mode, repair: repair), estimatedMinutes: c.minutes,
                                     title: c.title, type: c.q.type, priority: info.priority))
            total += c.minutes; picks[sid, default: 0] += 1; last = sid
        }
        if items.isEmpty { notes.append("Nothing eligible fits right now. Add questions for the skills in scope, relax the filters, or raise the time budget.") }
        if r.mode == .mastery && assessment == nil { notes.append("Mastery mode has no deadline: it favours due reviews, weak skills and skills you haven’t touched lately.") }

        let prios = infos.values.sorted { $0.priority > $1.priority }.map {
            SkillPriority(skill: $0.skill, priority: $0.priority, mastery: $0.mastery, note: $0.reasons.joined(separator: "; "))
        }
        return StudyPlan(mode: r.mode, assessmentName: assessment?.name, items: items, budgetMinutes: r.budgetMinutes, notes: notes, skills: prios)
    }

    static func dueReviews(_ d: Database, _ r: PlanRequest, scope: Set<UUID>, minutes: [QuestionType: Double]) throws -> [(DueReview, Double)] {
        let all = try ReviewService.dueRows(d, courseId: r.courseId, now: r.now)
        return try all.compactMap { rv in
            if r.excludedQuestionIds.contains(rv.questionId) { return nil }
            if let types = r.allowedTypes, !types.contains(rv.type) { return nil }
            let qs = Set(try UUID.fetchAll(d, sql: "SELECT skillId FROM question_skills WHERE questionId = ?", arguments: [rv.questionId]))
            if r.assessmentId != nil || !r.focusSkillIds.isEmpty { guard !qs.isDisjoint(with: scope) else { return nil } }
            if r.excludedSkillIds.isEmpty == false, !qs.isDisjoint(with: r.excludedSkillIds), qs.isSubset(of: r.excludedSkillIds) { return nil }
            return (rv, minutes[rv.type] ?? 0.5)
        }
    }

    static func importance(_ row: AssessmentSkill?, assessmentImportance: Double?, assessmentSource: ImportanceSource?, assessment: Assessment?) -> (Double, String) {
        guard let row, let v = row.importance else { return (1.0, "in scope") }
        var w = 0.5 + v
        let text: String
        switch row.importanceSource {
        case .instructorConfirmed: text = "confirmed important by your instructor"
        case .userAdjusted: text = "marked important by you"
        case .aiEstimate: w = 1 + (w - 1) * 0.5; text = "estimated important by AI (unconfirmed)"
        case .unset: text = "in scope"
        }
        return (w, text)
    }

    static func explain(_ i: SkillInfo, assessment: Assessment?, mode: StudyMode, repair: Bool) -> String {
        var parts: [String] = []
        let m = i.mastery
        let state = m.isUnknown ? "nothing is assessed yet, so a question here shows where you stand"
            : "your estimate is ≈ \(Int(((m.overall ?? 0) * 100).rounded()))% (\(m.confidence.label.lowercased()) confidence)"
        if let a = assessment, mode == .cram { parts.append("“\(i.skill.name)” is \(i.importanceText) for \(a.name); \(state).") }
        else { parts.append("“\(i.skill.name)”: \(state).") }
        if repair { parts.append("You missed this one last time, so it’s worth another look.") }
        if !i.reasons.isEmpty { parts.append(i.reasons.joined(separator: "; ").prefix(1).uppercased() + i.reasons.joined(separator: "; ").dropFirst() + ".") }
        if mode == .mastery, let days = i.daysSinceEvidence, days > 14 { parts.append("Last practised \(Int(days)) days ago.") }
        return parts.joined(separator: " ")
    }
}

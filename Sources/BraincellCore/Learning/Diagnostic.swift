import Foundation
import GRDB

extension PlannerService {

    /// A short set of representative quick questions, one per skill nothing is known about yet.
    /// It exists to create first evidence, not to measure: results stay Preliminary.
    public func diagnostic(courseId: UUID, assessmentId: UUID? = nil, maxQuestions: Int = 10, now: Date = Date()) throws -> StudyPlan {
        try db.read { d in
            guard try Course.exists(d, key: courseId) else { throw PlannerError.notFound }
            let assessment = try assessmentId.flatMap { try Assessment.fetchOne(d, key: $0) }
            let skills = try assessment.map { try Self.scopeSkills(d, $0) } ??
                Skill.fetchAll(d, sql: "SELECT s.* FROM skills s JOIN course_skills c ON c.skillId = s.id WHERE c.courseId = ? AND s.archivedAt IS NULL ORDER BY s.name", arguments: [courseId])
            let asm: [UUID: AssessmentSkill] = try assessment.map { a in
                Dictionary(uniqueKeysWithValues: try AssessmentSkill.filter(Column("assessmentId") == a.id).fetchAll(d).map { ($0.skillId, $0) })
            } ?? [:]
            var notes = ["A short diagnostic gives early signals only. Results stay Preliminary until you’ve answered more, and are not an accurate measure of what you know."]
            let unknown = try skills.filter { try estimator.estimate(skillId: $0.id, evidence: ProgressionEngine.evidenceInputs(d, skillId: $0.id), now: now).isUnknown }
            let ordered = unknown.sorted {
                let a = Self.importance(asm[$0.id], assessmentImportance: nil, assessmentSource: nil, assessment: assessment).0
                let b = Self.importance(asm[$1.id], assessmentImportance: nil, assessmentSource: nil, assessment: assessment).0
                return a != b ? a > b : $0.name < $1.name
            }
            if unknown.isEmpty { notes.append("Every skill in scope already has some evidence, so no diagnostic is needed.") }
            let quick: [QuestionType] = [.singleChoice, .shortAnswer, .numeric, .multipleSelect, .flashcard, .codeTracing]
            let minutes = try Self.minutesByType(d)
            var items: [PlannedItem] = [], used = Set<UUID>(), noQuestions: [String] = []
            for s in ordered {
                guard items.count < maxQuestions else { notes.append("\(ordered.count - items.count) more skills have no evidence yet; run another diagnostic later."); break }
                let rows = try Row.fetchAll(d, sql: """
                    SELECT q.*, v.title AS vTitle, v.difficulty AS vDiff FROM questions q JOIN question_skills qs ON qs.questionId = q.id
                    JOIN question_revisions v ON v.id = q.currentRevisionId
                    WHERE qs.skillId = ? AND q.archivedAt IS NULL ORDER BY q.createdAt, q.rowid
                    """, arguments: [s.id])
                let best = try rows.compactMap { row -> (Question, String, Int)? in
                    let q = try Question(row: row)
                    guard quick.contains(q.type), !used.contains(q.id), try Attempt.filter(Column("questionId") == q.id).fetchCount(d) == 0 else { return nil }
                    return (q, row["vTitle"], row["vDiff"])
                }.min { a, b in
                    func key(_ x: (Question, String, Int)) -> Double { Double(abs(x.2 - 2)) + (x.0.readiness == .verified ? 0 : 0.5) + (x.0.readiness == .needsReview ? 2 : 0) + Double(quick.firstIndex(of: x.0.type) ?? 9) * 0.01 }
                    return key(a) < key(b)
                }
                guard let (q, title, _) = best else { noQuestions.append(s.name); continue }
                used.insert(q.id)
                items.append(PlannedItem(questionId: q.id, skillId: s.id, skillName: s.name, kind: .diagnostic,
                                         reason: "Quick check on “\(s.name)”: nothing has been assessed there yet, so one short question gives a first signal.",
                                         estimatedMinutes: minutes[q.type] ?? 1, title: title, type: q.type, priority: 0))
            }
            if !noQuestions.isEmpty { notes.append("No short questions available for: \(noQuestions.prefix(4).joined(separator: ", ")).") }
            return StudyPlan(mode: .mastery, assessmentName: assessment?.name, items: items, budgetMinutes: Int(items.reduce(0) { $0 + $1.estimatedMinutes }.rounded(.up)),
                             notes: notes, skills: [])
        }
    }

    /// What to do next, from local evidence only: aim at the nearest upcoming exam, otherwise keep learning.
    public func recommendation(now: Date = Date(), budgetMinutes: Int = 20) throws -> Recommendation? {
        let (courses, upcoming): ([Course], [(Assessment, Course)]) = try db.read { d in
            let cs = try Course.filter(Column("archivedAt") == nil).order(Column("createdAt").desc).fetchAll(d)
            let ups = try cs.flatMap { c in try Assessment.filter(Column("courseId") == c.id && Column("deadline") != nil && Column("deadline") >= now).fetchAll(d).map { ($0, c) } }
            return (cs, ups.sorted { $0.0.deadline! < $1.0.deadline! })
        }
        if let (a, c) = upcoming.first {
            let plan = try self.plan(PlanRequest(courseId: c.id, assessmentId: a.id, mode: .cram, budgetMinutes: budgetMinutes).with(now: now))
            let days = Int((a.deadline!.timeIntervalSince(now) / 86_400).rounded(.up))
            return Recommendation(course: c, assessment: a, plan: plan, headline: "\(a.name) is in \(days) day\(days == 1 ? "" : "s"): \(budgetMinutes) focused minutes")
        }
        for c in courses {
            let plan = try self.plan(PlanRequest(courseId: c.id, mode: .mastery, budgetMinutes: budgetMinutes).with(now: now))
            if !plan.items.isEmpty { return Recommendation(course: c, assessment: nil, plan: plan, headline: "Keep learning \(c.name)") }
        }
        return nil
    }
}

extension PlanRequest {
    func with(now: Date) -> PlanRequest { var r = self; r.now = now; return r }
}

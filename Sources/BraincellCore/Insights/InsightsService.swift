import Foundation
import GRDB

public struct StudyDay: Sendable, Equatable { public var day: Date; public var minutes: Double; public var attempts: Int }

public struct SessionRow: Sendable, Identifiable {
    public var session: StudySession
    public var answered: Int, total: Int, graded: Int, correct: Int, pending: Int
    public var minutes: Double
    public var xp: Int
    public var id: UUID { session.id }
}

public struct AttemptRow: Sendable, Identifiable {
    public var attempt: Attempt
    public var title: String
    public var type: QuestionType
    public var evaluation: Evaluation?
    public var xp: Int
    public var id: UUID { attempt.id }
}

public struct ForecastDay: Sendable, Equatable { public var day: Date; public var due: Int }

public struct ExamCoverage: Sendable, Identifiable {
    public var assessment: Assessment
    public var progress: AssessmentProgress
    public var daysLeft: Int?
    public var id: UUID { assessment.id }
    /// Honest wording: coverage of evidence, never a predicted grade.
    public var summary: String {
        if progress.skillCount == 0 { return "No topics in scope yet" }
        if progress.assessedSkillCount == 0 { return "Not enough evidence yet — nothing in scope has been assessed" }
        return "\(progress.assessedSkillCount) of \(progress.skillCount) topics have some evidence (\(progress.confidence.label.lowercased()) confidence overall)"
    }
}

public struct TrendPoint: Sendable, Equatable { public var at: Date; public var overall: Double?; public var weight: Double }

public enum HistoryKind: String, Sendable { case mistake, reflection, breakthrough, milestone, focus }

public struct HistoryEntry: Sendable, Identifiable {
    public var id = UUID()
    public var at: Date
    public var kind: HistoryKind
    public var title: String
    public var detail: String
}

/// Read-only views over what the learner has done. No predictions of exam grades anywhere.
public struct InsightsService: Sendable {
    let db: AppDatabase
    public init(db: AppDatabase) { self.db = db }

    // MARK: Study history

    /// Active minutes per day from answered questions (time on questions that were never submitted isn't counted).
    public func studyDays(courseId: UUID? = nil, days: Int = 30, now: Date = Date(), calendar: Calendar = .current) throws -> [StudyDay] {
        let start = calendar.date(byAdding: .day, value: -(days - 1), to: calendar.startOfDay(for: now))!
        let rows: [(Date, Int)] = try db.read { d in
            var sql = "SELECT a.submittedAt AS at, a.activeSeconds AS secs FROM attempts a JOIN questions q ON q.id = a.questionId WHERE a.submittedAt >= ?"
            var args: [DatabaseValueConvertible] = [start]
            if let c = courseId { sql += " AND q.courseId = ?"; args.append(c) }
            return try Row.fetchAll(d, sql: sql, arguments: StatementArguments(args)).map { ($0["at"], $0["secs"]) }
        }
        var byDay: [Date: (Double, Int)] = [:]
        for (at, secs) in rows { let k = calendar.startOfDay(for: at); let v = byDay[k] ?? (0, 0); byDay[k] = (v.0 + Double(secs) / 60, v.1 + 1) }
        return (0..<days).map { i in
            let day = calendar.date(byAdding: .day, value: i, to: start)!
            return StudyDay(day: day, minutes: byDay[day]?.0 ?? 0, attempts: byDay[day]?.1 ?? 0)
        }
    }

    public func sessions(courseId: UUID? = nil, limit: Int = 30) throws -> [SessionRow] {
        try db.read { d in
            var q = StudySession.order(Column("startedAt").desc).limit(limit)
            if let c = courseId { q = q.filter(Column("courseId") == c) }
            let sessions = try q.fetchAll(d)
            guard !sessions.isEmpty else { return [] }
            let marks = sessions.map { _ in "?" }.joined(separator: ",")
            let ids = StatementArguments(sessions.map { $0.id })
            // One pass over items; one over graded attempts. (Previously a query per item.)
            var items: [UUID: (total: Int, answered: Int, seconds: Int)] = [:]
            for r in try Row.fetchAll(d, sql: "SELECT sessionId, COUNT(*) AS t, SUM(status = 'submitted') AS a, SUM(activeSeconds) AS s FROM session_items WHERE sessionId IN (\(marks)) GROUP BY sessionId", arguments: ids) {
                items[r["sessionId"]] = (r["t"], r["a"] ?? 0, r["s"] ?? 0)
            }
            var results: [UUID: (graded: Int, correct: Int, pending: Int, xp: Int)] = [:]
            for r in try Row.fetchAll(d, sql: """
                SELECT i.sessionId AS sid,
                       SUM(e.state = 'graded') AS g, SUM(e.state = 'graded' AND e.score >= 0.8) AS c, SUM(e.state = 'pending') AS p,
                       COALESCE(SUM((SELECT SUM(x.amount) FROM xp_events x WHERE x.attemptId = a.id)), 0) AS xp
                FROM session_items i JOIN attempts a ON a.sessionItemId = i.id
                LEFT JOIN evaluations e ON e.attemptId = a.id AND e.supersededAt IS NULL
                WHERE i.sessionId IN (\(marks)) GROUP BY i.sessionId
                """, arguments: ids) {
                results[r["sid"]] = (r["g"] ?? 0, r["c"] ?? 0, r["p"] ?? 0, r["xp"] ?? 0)
            }
            return sessions.map { s in
                let it = items[s.id] ?? (0, 0, 0), r = results[s.id] ?? (0, 0, 0, 0)
                return SessionRow(session: s, answered: it.answered, total: it.total, graded: r.graded, correct: r.correct, pending: r.pending,
                                  minutes: Double(it.seconds) / 60, xp: r.xp)
            }
        }
    }

    public func attempts(courseId: UUID? = nil, limit: Int = 100) throws -> [AttemptRow] {
        try db.read { d in
            var sql = "SELECT a.*, q.type AS qType, r.title AS qTitle FROM attempts a JOIN questions q ON q.id = a.questionId JOIN question_revisions r ON r.id = a.revisionId"
            var args: [DatabaseValueConvertible] = []
            if let c = courseId { sql += " WHERE q.courseId = ?"; args.append(c) }
            sql += " ORDER BY a.submittedAt DESC, a.rowid DESC LIMIT ?"; args.append(limit)
            return try Row.fetchAll(d, sql: sql, arguments: StatementArguments(args)).map { row in
                let a = try Attempt(row: row)
                return AttemptRow(attempt: a, title: row["qTitle"], type: row["qType"], evaluation: try ProgressionEngine.active(d, attemptId: a.id),
                                  xp: try Int.fetchOne(d, sql: "SELECT COALESCE(SUM(amount),0) FROM xp_events WHERE attemptId = ?", arguments: [a.id]) ?? 0)
            }
        }
    }

    // MARK: Reviews and exams

    /// Cards that will come due on each of the next `days` days (today includes everything overdue).
    public func forecast(courseId: UUID? = nil, days: Int = 7, now: Date = Date(), calendar: Calendar = .current) throws -> [ForecastDay] {
        let start = calendar.startOfDay(for: now)
        let dues: [Date] = try db.read { d in
            var sql = "SELECT s.due FROM review_states s JOIN questions q ON q.id = s.questionId WHERE q.archivedAt IS NULL"
            var args: [DatabaseValueConvertible] = []
            if let c = courseId { sql += " AND q.courseId = ?"; args.append(c) }
            return try Date.fetchAll(d, sql: sql, arguments: StatementArguments(args))
        }
        return (0..<days).map { i in
            let day = calendar.date(byAdding: .day, value: i, to: start)!, next = calendar.date(byAdding: .day, value: 1, to: day)!
            return ForecastDay(day: day, due: dues.filter { i == 0 ? $0 < next : ($0 >= day && $0 < next) }.count)
        }
    }

    public func exams(courseId: UUID, now: Date = Date()) throws -> [ExamCoverage] {
        let prog = ProgressionService(db: db)
        return try CourseService(db: db).assessments(courseId: courseId).map { a in
            ExamCoverage(assessment: a, progress: try prog.assessmentProgress(assessmentId: a.id, now: now),
                         daysLeft: a.deadline.map { Int(($0.timeIntervalSince(now) / 86_400).rounded(.up)) })
        }
    }

    // MARK: Trends and history

    /// One point per grading event that touched the skill (from the append-only estimate snapshots).
    public func skillTrend(skillId: UUID) throws -> [TrendPoint] {
        try ProgressionService(db: db).history(skillId: skillId).map { TrendPoint(at: $0.computedAt, overall: $0.overall, weight: $0.overallWeight) }
    }

    /// Cumulative XP by day for a course, straight from the ledger (corrections included).
    public func xpTrend(courseId: UUID, calendar: Calendar = .current) throws -> [(day: Date, total: Int)] {
        let events = try ProgressionService(db: db).ledger(courseId: courseId).reversed()
        var running = 0, byDay: [Date: Int] = [:]
        for e in events { running += e.amount; byDay[calendar.startOfDay(for: e.createdAt)] = running }
        return byDay.sorted { $0.key < $1.key }.map { (day: $0.key, total: $0.value) }
    }

    /// Mistakes, reflections, breakthroughs and milestones in one chronological list (newest first).
    public func timeline(courseId: UUID, limit: Int = 100) throws -> [HistoryEntry] {
        let h = LearningHistoryService(db: db)
        var out: [HistoryEntry] = []
        for m in try h.mistakes(courseId: courseId, limit: limit) {
            var detail = m.skillNames.joined(separator: ", ")
            if m.timesMissed > 1 { detail += (detail.isEmpty ? "" : " · ") + "missed \(m.timesMissed)×" }
            if m.wasHighConfidence { detail += " · you felt sure" }
            out.append(HistoryEntry(at: m.submittedAt, kind: .mistake, title: m.title, detail: detail))
        }
        for r in try h.reflections(courseId: courseId) { out.append(HistoryEntry(at: r.createdAt, kind: .reflection, title: "Your note", detail: r.text)) }
        for b in try h.breakthroughs(courseId: courseId) { out.append(HistoryEntry(at: b.at, kind: .breakthrough, title: "Breakthrough on “\(b.skillName)”", detail: "Solved “\(b.questionTitle)” on your own after earlier trouble")) }
        for m in try ProgressionService(db: db).milestones(courseId: courseId) { out.append(HistoryEntry(at: m.achievedAt, kind: .milestone, title: m.title, detail: "")) }
        return Array(out.sorted { $0.at > $1.at }.prefix(limit))
    }
}

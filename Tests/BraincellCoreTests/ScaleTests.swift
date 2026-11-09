import Testing
import Foundation
import GRDB
@testable import BraincellCore

/// Builds a large library and times the paths the UI runs on the main thread. Size is adjustable:
/// `BRAINCELL_SCALE_QUESTIONS` / `BRAINCELL_SCALE_ATTEMPTS` (defaults keep the normal suite quick).
@Suite(.serialized) struct ScaleTests {
    static let questions = Int(ProcessInfo.processInfo.environment["BRAINCELL_SCALE_QUESTIONS"] ?? "") ?? 1_500
    static let attempts = Int(ProcessInfo.processInfo.environment["BRAINCELL_SCALE_ATTEMPTS"] ?? "") ?? 2_500
    static let skillCount = 40

    func time<T>(_ label: String, _ log: inout [String], _ f: () throws -> T) rethrows -> (T, Double) {
        let t0 = Date(); let v = try f(); let ms = Date().timeIntervalSince(t0) * 1_000
        log.append(String(format: "%-34@ %8.1f ms", label as NSString, ms)); return (v, ms)
    }

    @Test func largeLibraryStaysResponsive() throws {
        var log: [String] = []
        let dir = try tempDir()
        let storage = ManagedStorage(root: dir.appendingPathComponent("storage"))
        let db = try AppDatabase.open(at: dir.appendingPathComponent("big.sqlite"))
        let courses = CourseService(db: db)
        let course = try courses.createCourse(name: "Big course")
        let skills = try (0..<Self.skillCount).map { try courses.addSkill(courseId: course.id, name: "Skill \($0)").skill }
        for i in 1..<Self.skillCount where i % 4 != 0 { try courses.addRelation(from: skills[i - 1 - (i - 1) % 4 * 0].id, to: skills[i].id, kind: i % 3 == 0 ? .prerequisite : .hierarchy) }
        let finalExam = try courses.addAssessment(courseId: course.id, name: "Final", deadline: Date().addingTimeInterval(20 * 86_400), isCumulative: true)
        let m1 = try courses.addAssessment(courseId: course.id, name: "Midterm 1")
        for s in skills.prefix(15) { try courses.addToScope(assessmentId: m1.id, skillId: s.id) }

        // ── seed ────────────────────────────────────────────────────────────────────────────────────
        let seedStart = Date()
        var qids: [UUID] = [], types: [Int] = []
        let fx = Fx.all
        try db.write { d in
            for i in 0..<Self.questions {
                let t = [4, 1, 3, 0, 7, 5, 6, 8][i % 8]
                var e = fx[t]; e["title"] = "Question \(i) about topic \(i % 97)"
                e["content"] = [Fx.md("Statement \(i). " + String(repeating: "Lorem ipsum dolor sit amet. ", count: 8))]
                let v = QuestionValidator.validate(entry: e, index: 0)
                let q = try QuestionService.insert(d, courseId: course.id, spec: v.question!.spec, validation: v, skillIds: [skills[i % skills.count].id],
                                                   assessmentIds: i % 3 == 0 ? [finalExam.id] : [], origin: .manual, aiImportId: nil, familyId: nil, extraNotes: [])
                qids.append(q.id); types.append(t)
            }
        }
        log.append(String(format: "%-34@ %8.1f ms", "seed \(Self.questions) questions" as NSString, Date().timeIntervalSince(seedStart) * 1_000))
        let seed2 = Date()
        var sessionIds: [UUID] = []
        try db.write { d in
            var done = 0
            while done < Self.attempts {
                let s = StudySession(id: UUID(), courseId: course.id, assessmentId: nil, title: "Seed \(sessionIds.count)", status: .completed, currentOrdinal: 0,
                                     startedAt: Date().addingTimeInterval(-Double(sessionIds.count) * 3_600), updatedAt: Date(), completedAt: Date())
                try s.insert(d); sessionIds.append(s.id)
                for k in 0..<min(50, Self.attempts - done) {
                    let qi = (done * 7 + k * 13) % qids.count
                    let q = try Question.fetchOne(d, key: qids[qi])!
                    let item = SessionItem(id: UUID(), sessionId: s.id, ordinal: k, questionId: q.id, revisionId: q.currentRevisionId, status: .submitted, hintsUsed: done % 5 == 0 ? 1 : 0, activeSeconds: 30 + done % 60)
                    try item.insert(d)
                    var r = PracticeResponse(); r.text = (done % 3 == 0) ? "wrong" : "14"; r.selected = [done % 3 == 0 ? "b" : "a"]; r.revealed = true
                    let a = Attempt(id: UUID(), sessionItemId: item.id, questionId: q.id, revisionId: q.currentRevisionId, response: PracticeService.encode(r),
                                    hintsUsed: item.hintsUsed, activeSeconds: item.activeSeconds, submittedAt: Date().addingTimeInterval(-Double(done) * 60))
                    try a.insert(d)
                    let spec = try QuestionRevision.fetchOne(d, key: q.currentRevisionId)!.spec!
                    let o = Evaluator.evaluate(spec: spec, response: r, answerKeyVerified: q.readiness == .verified)
                    try ProgressionEngine.commit(d, attempt: a, outcome: o, source: .deterministic, revisionId: q.currentRevisionId, reason: "seed", detail: "{}", batchId: nil)
                    done += 1
                }
            }
        }
        log.append(String(format: "%-34@ %8.1f ms", "seed \(Self.attempts) graded attempts" as NSString, Date().timeIntervalSince(seed2) * 1_000))

        // ── timings (these run on the main thread in the UI) ───────────────────────────────────────
        let qs = QuestionService(db: db), prog = ProgressionService(db: db), planner = PlannerService(db: db), ins = InsightsService(db: db)
        let hist = LearningHistoryService(db: db), reviews = ReviewService(db: db), practice = PracticeService(db: db)
        var worst = 0.0
        func t<T>(_ l: String, _ f: () throws -> T) throws -> T { let (v, ms) = try time(l, &log, f); worst = max(worst, ms); return v }
        let rows = try t("question list (all)") { try qs.list() }
        #expect(rows.count == Self.questions)
        var f = QuestionFilter(); f.text = "topic 42"
        _ = try t("question search") { try qs.list(f) }
        f = QuestionFilter(); f.assessmentId = finalExam.id; f.sort = .difficulty
        _ = try t("question filter+sort (assessment)") { try qs.list(f) }
        _ = try t("course masteries (\(Self.skillCount) skills)") { try prog.masteries(courseId: course.id) }
        _ = try t("course XP + ledger") { _ = try prog.courseXP(course.id); return try prog.ledger(courseId: course.id) }
        _ = try t("assessment progress (cumulative)") { try prog.assessmentProgress(assessmentId: finalExam.id) }
        var req = PlanRequest(courseId: course.id, assessmentId: finalExam.id, mode: .cram, budgetMinutes: 60)
        req.now = Date()
        let plan = try t("cram plan (cumulative final)") { try planner.plan(req) }
        #expect(!plan.items.isEmpty)
        _ = try t("mastery plan") { try planner.plan(PlanRequest(courseId: course.id, mode: .mastery, budgetMinutes: 60)) }
        _ = try t("diagnostic") { try planner.diagnostic(courseId: course.id) }
        _ = try t("home recommendation") { try planner.recommendation() }
        _ = try t("due reviews") { try reviews.due(courseId: course.id, now: Date().addingTimeInterval(30 * 86_400)) }
        _ = try t("insights: study days") { try ins.studyDays(courseId: course.id) }
        _ = try t("insights: sessions (30)") { try ins.sessions(courseId: course.id) }
        _ = try t("insights: attempts (100)") { try ins.attempts(courseId: course.id) }
        _ = try t("insights: exams") { try ins.exams(courseId: course.id) }
        _ = try t("insights: forecast") { try ins.forecast(courseId: course.id) }
        _ = try t("insights: timeline") { try ins.timeline(courseId: course.id) }
        _ = try t("insights: XP trend") { try ins.xpTrend(courseId: course.id) }
        _ = try t("history: mistakes (50)") { try hist.mistakes(courseId: course.id) }
        _ = try t("history: weak spots") { try hist.weakSpots(courseId: course.id) }
        _ = try t("history: breakthroughs") { try hist.breakthroughs(courseId: course.id) }
        _ = try t("session results (50 items)") { try prog.sessionResults(sessionId: sessionIds[0]) }
        _ = try t("resumable session") { try practice.resumableSession() }
        _ = try t("questionIds for final") { try practice.questionIds(courseId: course.id, assessmentId: finalExam.id) }
        let g = try t("skill map layout") { SkillGraphLayout.layout(skills: try courses.skills(courseId: course.id), relations: try courses.relations(courseId: course.id)) }
        #expect(g.nodes.count == Self.skillCount)
        let backup = try t("backup create") { try BackupService(db: db, storage: storage).create(in: dir.appendingPathComponent("b")) }
        _ = try t("backup validate") { try BackupService.validate(at: backup.url) }
        // New work on a big library: evaluating + grading one more answer.
        let qid = qids[0]
        let s = try practice.start(questionIds: [qid], title: "one more", courseId: course.id)
        var r = PracticeResponse(); r.text = "14"; r.selected = ["a"]; r.revealed = true
        let a = try practice.submit(itemId: try practice.items(sessionId: s.id)[0].id, response: r)
        _ = try t("grade one answer") { try EvaluationService(db: db).evaluate(attemptId: a.id) }

        print("\n── scale (\(Self.questions) questions, \(Self.attempts) attempts) ──\n" + log.joined(separator: "\n") + "\n")
        #expect(worst < 3_000, "slowest operation took \(Int(worst)) ms")
    }
}

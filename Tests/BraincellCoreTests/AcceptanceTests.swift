import Testing
import Foundation
import GRDB
@testable import BraincellCore

/// The end-to-end COMP 211 study journey from the brief, driven only through the services the app uses.
/// It restarts the database mid-way, adds Midterm 1 and a cumulative Final later, and finishes with a backup/restore.
@Suite struct COMP211JourneyTests {
    struct App {
        let db: AppDatabase, storage: ManagedStorage
        var courses: CourseService { CourseService(db: db) }
        var docs: DocumentService { DocumentService(db: db, storage: storage) }
        var qs: QuestionService { QuestionService(db: db) }
        var ai: AITaskService { AITaskService(db: db) }
        var practice: PracticeService { PracticeService(db: db) }
        var eval: EvaluationService { EvaluationService(db: db) }
        var prog: ProgressionService { ProgressionService(db: db) }
        var planner: PlannerService { PlannerService(db: db) }
        var reviews: ReviewService { ReviewService(db: db) }
        var insights: InsightsService { InsightsService(db: db) }
        var focus: FocusService { FocusService(db: db) }
    }

    struct Numbers: Equatable {
        var xp: Int, questions: Int, attempts: Int, evaluations: Int, evidence: Int, reviewStates: Int, skills: Int
        var mastery: [String: Double?]
    }

    func numbers(_ app: App, course: UUID) throws -> Numbers {
        let skills = try app.courses.skills(courseId: course)
        var m: [String: Double?] = [:]
        for s in skills { m[s.name] = try app.prog.mastery(skillId: s.id).overall.map { ($0 * 1e6).rounded() / 1e6 } }   // recency makes it time-dependent at ~1e-15
        let xp = try app.prog.courseXP(course).xp
        return try app.db.read { d in
            Numbers(xp: xp, questions: try Question.fetchCount(d), attempts: try Attempt.fetchCount(d),
                    evaluations: try Evaluation.fetchCount(d), evidence: try LearningEvidence.fetchCount(d), reviewStates: try ReviewState.fetchCount(d),
                    skills: skills.count, mastery: m)
        }
    }

    func response(for spec: QuestionSpec) -> PracticeResponse {
        var r = PracticeResponse()
        switch spec.type {
        case .numeric: r.text = "14"
        case .singleChoice: r.selected = ["b"]                         // deliberately wrong
        case .shortAnswer: r.text = "hasNext"
        case .flashcard: r.revealed = true
        default: r.text = "My written explanation of the idea."
        }
        return r
    }

    @Test func fullJourney() throws {
        let dir = try tempDir()
        let path = dir.appendingPathComponent("braincell.sqlite")
        let storage = ManagedStorage(root: dir.appendingPathComponent("storage"))
        var app = App(db: try AppDatabase.open(at: path), storage: storage)

        // ── 1. Course, Midterm 2, materials ───────────────────────────────────────────────────────
        let course = try app.courses.createCourse(name: "COMP 211")
        let m2 = try app.courses.addAssessment(courseId: course.id, name: "Midterm 2", deadline: Date().addingTimeInterval(10 * 86_400 + 3_600))
        let pdf = dir.appendingPathComponent("lecture.pdf")
        makePDF(pages: ["Iterators expose hasNext and next", "Generics let classes take type parameters", "Recursion needs a base case"], at: pdf)
        let lecture = try app.docs.importFile(at: pdf, courseId: course.id).document
        _ = try app.docs.importPasted(text: "Office hours notes: the exam covers iterators and generics.", title: "Notes", courseId: course.id)
        #expect(try lecture.extractionStatus == .ok && lecture.pageCount == 3 && (try app.docs.documents(courseId: course.id)).count == 2)

        // ── 2. Topics, relationships, exam scope ─────────────────────────────────────────────────
        let java = try app.courses.addSkill(courseId: course.id, name: "Java").skill
        let iterators = try app.courses.addSkill(courseId: course.id, name: "Java iterators", parentId: java.id).skill
        let generics = try app.courses.addSkill(courseId: course.id, name: "Generics", parentId: java.id).skill
        let recursion = try app.courses.addSkill(courseId: course.id, name: "Recursion").skill
        try app.courses.addRelation(from: recursion.id, to: iterators.id, kind: .prerequisite)
        try app.courses.addToScope(assessmentId: m2.id, skillId: iterators.id, importance: 0.9, source: .instructorConfirmed)
        try app.courses.addToScope(assessmentId: m2.id, skillId: generics.id)

        // ── 3. Manual ChatGPT workflow: request → (user runs ChatGPT) → partly valid response → repair ──
        let task = try app.ai.createGenerationTask(courseId: course.id, assessmentId: m2.id, params: GenerationParams(count: 6, documentIds: [lecture.id]))
        let batch = try app.ai.batches(taskId: task.id)[0]
        let pkg = try app.ai.prepare(batchId: batch.id)
        #expect(pkg.singlePrompt.contains("hasNext and next") && pkg.singlePrompt.contains("Java iterators") && pkg.manifest.documents.map(\.title) == ["lecture"])
        try app.ai.markExported(batchId: batch.id, method: .clipboard)
        #expect(try app.ai.status(taskId: task.id) == .awaitingImport)

        func q(_ type: String, _ title: String, _ answer: [String: Any], _ method: String, _ skill: String, extra: [String: Any] = [:]) -> [String: Any] {
            Fx.base(type, title: title, answer: answer, method: method, skills: [skill], extra: extra.merging(["assessments": ["Midterm 2"]]) { a, _ in a })
        }
        let numeric = q("numeric", "Compute the expression", ["value": 14, "tolerance": 0.01, "verificationExpression": "2+3*4"], "numeric", "Java iterators")
        let single = q("single_choice", "Which call removes?", ["choices": [["id": "a", "text": "it.remove()"], ["id": "b", "text": "it.delete()"]], "correctIds": ["a"]], "choice", "Java iterators")
        let essay = q("long_form", "Explain fail-fast iterators", [:], "ai_rubric", "Java iterators", extra: ["evaluation": ["method": "ai_rubric", "rubric": [["criterion": "clear", "points": 2]]]])
        let short = q("short_answer", "Name the interface for-each needs", ["accepted": ["hasNext"], "caseSensitive": false], "exact", "Generics")
        let card = q("flashcard", "What is a type parameter?", ["back": [Fx.md("A placeholder type")]], "self_review", "Generics")
        var broken = q("derivation_proof", "Prove the invariant", [:], "ai_rubric", "Generics"); broken["difficulty"] = 9
        let first = try app.ai.importResponse(Fx.envelope(batch.requestId, [numeric, single, essay, short, card, broken]), targetBatchId: batch.id)
        #expect(first.accepted.count == 5 && first.rejected.count == 1 && first.batchStatus == .needsRepair)
        let repair = try app.ai.createRepairBatch(from: batch.id)
        #expect(try app.ai.prepare(batchId: repair.id).singlePrompt.contains("questions[5].difficulty"))
        var fixed = broken; fixed["difficulty"] = 3
        fixed["evaluation"] = ["method": "ai_rubric", "rubric": [["criterion": "valid", "points": 3]]]
        _ = try app.ai.importResponse(Fx.envelope(repair.requestId, [fixed]), targetBatchId: repair.id)
        #expect(try app.ai.status(taskId: task.id) == .completed)
        #expect(try app.qs.list().count == 6)
        var inM2 = QuestionFilter(); inM2.assessmentId = m2.id
        #expect(try app.qs.list(inM2).count == 6)

        // ── 4. Cram plan → session → answers → grades ────────────────────────────────────────────
        var req = PlanRequest(courseId: course.id, assessmentId: m2.id, mode: .cram, budgetMinutes: 25)
        req.now = Date()
        let plan = try app.planner.plan(req)
        #expect(plan.items.count == 6 && plan.items.allSatisfy { !$0.reason.isEmpty })
        #expect(plan.skills.first { $0.skill.id == recursion.id } == nil)               // out of scope: never planned
        #expect(plan.items.first?.reason.contains("confirmed important by your instructor") == true || plan.items.contains { $0.reason.contains("confirmed important by your instructor") })
        let session = try app.practice.start(planned: plan.items.map { .init(questionId: $0.questionId, kind: $0.kind, reason: $0.reason) },
                                             title: "Cram Midterm 2", courseId: course.id, assessmentId: m2.id, mode: .cram)
        var gradedAttempts: [Attempt] = []
        for item in try app.practice.items(sessionId: session.id) {
            let spec = try app.practice.spec(for: item)
            if !spec.hints.isEmpty && spec.type == .shortAnswer { try app.practice.revealHint(itemId: item.id, level: 0) }
            try app.practice.addActiveSeconds(itemId: item.id, 45)
            let a = try app.practice.submit(itemId: item.id, response: response(for: spec))
            let r = try app.eval.evaluate(attemptId: a.id)
            gradedAttempts.append(a)
            if spec.type == .flashcard { #expect(r.evaluation.state == .pending) }
        }
        try app.practice.setStatus(session.id, .completed)
        var results = try app.prog.sessionResults(sessionId: session.id)
        #expect(results.pending == 3 && results.incorrect == 1 && results.correct == 2 && results.xp > 0)  // essay, flashcard, proof pending; wrong choice; numeric + short right
        // Flashcard: self-rated → scheduled by FSRS. Essay: graded in ChatGPT.
        let cardAttempt = try #require(try app.eval.pendingAttempts().first { $0.type == .flashcard }).attempt
        _ = try app.eval.selfReview(attemptId: cardAttempt.id, score: 0.8, rating: "good")
        let essayAttempt = try #require(try app.eval.pendingAttempts().first { $0.type == .longForm })
        let grading = try app.ai.createGradingTask(courseId: course.id, attemptIds: [essayAttempt.id])
        let gb = try app.ai.batches(taskId: grading.id)[0]
        #expect(try app.ai.prepare(batchId: gb.id).singlePrompt.contains("My written explanation"))
        let gradeJSON = String(data: try JSONSerialization.data(withJSONObject: ["schemaVersion": GradeSchema.version, "requestId": gb.requestId,
            "grades": [["attemptId": essayAttempt.id.uuidString, "score": 0.9, "feedback": "Clear."]]]), encoding: .utf8)!
        #expect(try app.ai.importGrades(gradeJSON, targetBatchId: gb.id).graded.count == 1)
        results = try app.prog.sessionResults(sessionId: session.id)   // only the proof is still waiting for a grade
        #expect(results.pending == 1 && results.correct == 4 && results.incorrect == 1, "\(results.pending) pending, \(results.correct) correct, \(results.partial) partial, \(results.incorrect) incorrect")
        #expect(try app.reviews.state(questionId: cardAttempt.questionId) != nil)                          // flashcard + short answer cards
        #expect(try app.reviews.state(questionId: try app.practice.attempt(itemId: cardAttempt.sessionItemId)!.questionId)?.schedulerVersion == FSRSScheduler.version)

        // Mastery: assessed skills have evidence; the untouched one is Unknown (not 0%).
        #expect(try app.prog.mastery(skillId: iterators.id).confidence != .unknown && (try app.prog.mastery(skillId: generics.id)).confidence != .unknown)
        #expect(try app.prog.mastery(skillId: recursion.id).isUnknown && (try app.prog.mastery(skillId: recursion.id)).overall == nil)

        // ── 5. Work in progress at quit time: unfinished session, awaiting AI import, open focus timer ──
        let loose = try app.practice.start(questionIds: Array(plan.items.prefix(2).map(\.questionId)), title: "Unfinished", courseId: course.id)
        let looseItem = try app.practice.items(sessionId: loose.id)[0]
        var draft = PracticeResponse(); draft.text = "half-finished answer"
        try app.practice.saveDraft(itemId: looseItem.id, response: draft)
        let task2 = try app.ai.createGenerationTask(courseId: course.id, assessmentId: m2.id, params: GenerationParams(count: 3))
        let b2 = try app.ai.batches(taskId: task2.id)[0]
        _ = try app.ai.prepare(batchId: b2.id); try app.ai.markExported(batchId: b2.id, method: .file)
        let timer = FocusTimer(kind: .work, plannedSeconds: 1_500, now: Date()); _ = try app.focus.begin(timer, courseId: course.id)
        let before = try numbers(app, course: course.id)
        let xpEventKeys = try app.db.read { try String.fetchAll($0, sql: "SELECT eventKey FROM xp_events ORDER BY eventKey") }

        // ── 6. RESTART ────────────────────────────────────────────────────────────────────────────
        app = App(db: try AppDatabase.open(at: path), storage: storage)
        #expect(try numbers(app, course: course.id) == before)
        #expect(try app.db.read { try String.fetchAll($0, sql: "SELECT eventKey FROM xp_events ORDER BY eventKey") } == xpEventKeys)
        let resumed = try #require(try app.practice.resumableSession())
        #expect(resumed.id == loose.id)
        let ritem = try app.practice.items(sessionId: resumed.id)[0]
        #expect(try app.practice.response(for: ritem, spec: try app.practice.spec(for: ritem)).text == "half-finished answer")
        #expect(try app.ai.status(taskId: task2.id) == .awaitingImport && (try app.ai.batches(taskId: task2.id))[0].transferMethod == .file)
        #expect(try app.focus.recoverInterrupted() == 1)

        // ── 7. Later: Midterm 1 and a cumulative Final. Skills and questions are reused, nothing resets ─
        let m1 = try app.courses.addAssessment(courseId: course.id, name: "Midterm 1")
        let same = try app.courses.addSkill(courseId: course.id, name: "  JAVA  Iterators ")
        #expect(!same.created && same.skill.id == iterators.id)                                              // no automatic duplicate
        try app.courses.addToScope(assessmentId: m1.id, skillId: iterators.id)
        try app.courses.addToScope(assessmentId: m1.id, skillId: recursion.id)
        let rq = try app.qs.create(courseId: course.id, spec: QuestionValidator.validate(entry: { var e = Fx.all[4]; e["title"] = "Recursive count"; return e }(), index: 0).question!.spec, skillIds: [recursion.id])
        let fin = try app.courses.addAssessment(courseId: course.id, name: "Final Exam", kind: .final, deadline: Date().addingTimeInterval(40 * 86_400), isCumulative: true)
        let shared = try #require(try app.qs.list().first { $0.title == "Compute the expression" })
        try app.qs.addToAssessment(questionIds: [shared.id], assessmentId: m1.id)
        try app.qs.addToAssessment(questionIds: [shared.id, rq.id], assessmentId: fin.id)
        let afterAdding = try numbers(app, course: course.id)
        #expect(afterAdding.xp == before.xp && afterAdding.attempts == before.attempts && afterAdding.evaluations == before.evaluations)
        #expect(afterAdding.questions == before.questions + 1 && afterAdding.skills == before.skills)    // one new question; skills unchanged
        #expect(afterAdding.mastery == before.mastery)                                                    // mastery untouched by new exams
        for (a, qid) in [(m1.id, shared.id), (fin.id, shared.id), (m2.id, shared.id)] {                   // one record, three exams
            var f = QuestionFilter(); f.assessmentId = a; #expect(try app.qs.list(f).contains { $0.id == qid })
        }
        #expect(try app.db.read { try Question.filter(Column("id") == shared.id).fetchCount($0) } == 1)
        #expect(Set(try app.practice.questionIds(courseId: course.id, assessmentId: fin.id)).count == afterAdding.questions - 0)
        let pM2 = try app.prog.assessmentProgress(assessmentId: m2.id), pM1 = try app.prog.assessmentProgress(assessmentId: m1.id), pF = try app.prog.assessmentProgress(assessmentId: fin.id)
        #expect(pM2.skillCount == 2 && pM2.assessedSkillCount == 2)
        #expect(pM1.skillCount == 2 && pM1.assessedSkillCount == 1)                                       // Recursion still unassessed
        #expect(pF.skillCount == 4 && pF.assessedSkillCount == 2 && pF.questionCount == afterAdding.questions)

        // Cram for the Final: reaches the newly in-scope skill, reasons mention the exam and its date.
        var fr = PlanRequest(courseId: course.id, assessmentId: fin.id, mode: .cram, budgetMinutes: 30); fr.now = Date()
        let finalPlan = try app.planner.plan(fr)
        #expect(finalPlan.items.contains { $0.questionId == rq.id } && finalPlan.items.allSatisfy { !$0.reason.isEmpty })
        #expect(finalPlan.items.contains { $0.reason.contains("Final Exam") })

        // ── 8. Insights are honest about evidence ──────────────────────────────────────────────────
        let ex = try app.insights.exams(courseId: course.id)
        #expect(ex.count == 3 && ex.first { $0.assessment.id == m1.id }!.summary.contains("1 of 2") && ex.allSatisfy { !$0.summary.lowercased().contains("grade") })
        #expect(try app.insights.sessions(courseId: course.id).count >= 2 && (try app.insights.timeline(courseId: course.id)).contains { $0.kind == .milestone })

        // ── 9. Backup → restore into a brand-new install → identical state, and it still works ───────
        let backup = try BackupService(db: app.db, storage: storage).create(in: dir.appendingPathComponent("backups"))
        let freshDir = dir.appendingPathComponent("fresh")
        let freshStorage = ManagedStorage(root: freshDir.appendingPathComponent("storage"))
        try FileManager.default.createDirectory(at: freshStorage.root, withIntermediateDirectories: true)
        let restored = App(db: try AppDatabase.open(at: freshDir.appendingPathComponent("braincell.sqlite")), storage: freshStorage)
        try BackupService(db: restored.db, storage: freshStorage).restore(from: backup.url, safetyBackupIn: nil)
        #expect(try numbers(restored, course: course.id) == afterAdding)
        #expect(try restored.docs.documents(courseId: course.id).count == 2)
        #expect(try Data(contentsOf: freshStorage.url(forStoredPath: lecture.storedPath)) == (try Data(contentsOf: storage.url(forStoredPath: lecture.storedPath))))
        let again = try restored.practice.start(questionIds: [rq.id], title: "After restore", courseId: course.id)
        var rr = PracticeResponse(); rr.text = "14"
        let ra = try restored.practice.submit(itemId: try restored.practice.items(sessionId: again.id)[0].id, response: rr)
        #expect(try restored.eval.evaluate(attemptId: ra.id).evaluation.state == .graded)
        #expect(try restored.prog.mastery(skillId: recursion.id).confidence == .preliminary)

        // ── 10. Invariants that must hold at the end of any journey ─────────────────────────────────
        try app.db.read { d in
            let names = try String.fetchAll(d, sql: "SELECT s.normalizedName FROM skills s JOIN course_skills c ON c.skillId = s.id WHERE c.courseId = ? AND s.archivedAt IS NULL", arguments: [course.id])
            #expect(Set(names).count == names.count)                                                        // no duplicate concepts
            let ledger = try Int.fetchOne(d, sql: "SELECT SUM(amount) FROM xp_events WHERE courseId = ?", arguments: [course.id])
            #expect(ledger == afterAdding.xp)
            let skillXP = try Int.fetchOne(d, sql: "SELECT COALESCE(SUM(amount),0) FROM xp_event_skills") ?? 0
            #expect(skillXP <= afterAdding.xp && skillXP >= 0)                                              // skill XP never double counts
            #expect(try Int.fetchOne(d, sql: "SELECT COUNT(*) FROM evaluations WHERE supersededAt IS NULL") == afterAdding.attempts)  // one current grade per attempt
            #expect(try Int.fetchOne(d, sql: "SELECT COUNT(*) FROM learning_evidence le JOIN evaluations e ON e.id = le.evaluationId WHERE le.supersededAt IS NULL AND e.state != 'graded'") == 0)
            #expect(try Row.fetchOne(d, sql: "PRAGMA foreign_key_check") == nil)
            #expect(try String.fetchOne(d, sql: "PRAGMA integrity_check") == "ok")
        }
    }
}

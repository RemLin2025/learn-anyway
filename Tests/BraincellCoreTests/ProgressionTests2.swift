import Testing
import Foundation
import GRDB
@testable import BraincellCore

@Suite struct CorrectionAndProgressTests {
    @Test func answerChangeIsDetectedAndRegradingCorrectsXPAuditably() throws {
        let rig = try Rig()
        var spec = QuestionValidator.validate(entry: Fx.all[4], index: 0).question!.spec
        spec.answer.verificationExpression = nil
        let q = try rig.qs.create(courseId: rig.course.id, spec: spec, skillIds: [rig.skillA.id])
        try rig.qs.markVerified(q.id)
        let a = try rig.attempt(q, text: "14")
        let before = try rig.eval.evaluate(attemptId: a.id)
        let full = XPRules.participation(difficulty: 2, attemptNumber: 1) + XPRules.correctness(difficulty: 2)
        #expect(before.evaluation.score == 1 && before.xp == full)
        #expect(try rig.eval.affectedAttempts(questionId: q.id).isEmpty)

        // The key was wrong: the author fixes it to 15 and re-verifies.
        var fixed = spec; fixed.answer.value = 15
        let rev2 = try rig.qs.edit(questionId: q.id, spec: fixed)
        try rig.qs.markVerified(q.id)
        #expect(try rig.eval.affectedAttempts(questionId: q.id).map(\.id) == [a.id])
        #expect(try rig.eval.result(attemptId: a.id)?.evaluation.score == 1)       // nothing changes silently
        #expect(try rig.qs.revisions(q.id).count == 2 && a.revisionId != rev2.id)  // the attempt still points at revision 1

        #expect(try rig.eval.regradeQuestion(questionId: q.id) == 1)
        let after = try #require(try rig.eval.result(attemptId: a.id))
        #expect(after.evaluation.score == 0 && after.evaluation.revisionId == rev2.id)
        #expect(after.attempt.revisionId == a.revisionId)                           // attempt itself is untouched
        #expect(after.xp == XPRules.participation(difficulty: 2, attemptNumber: 1)) // bonus reversed
        #expect(try rig.eval.affectedAttempts(questionId: q.id).isEmpty)

        // History and ledger tell the whole story.
        let hist = try rig.eval.history(attemptId: a.id)
        #expect(hist.map(\.score) == [1, 0] && hist[0].supersededAt != nil)
        let ledger = try rig.prog.ledger(courseId: rig.course.id)
        #expect(ledger.contains { $0.kind == .correction && $0.amount == -XPRules.correctness(difficulty: 2) })
        #expect(ledger.reduce(0) { $0 + $1.amount } == after.xp)
        // Old evidence is superseded, new evidence points at the new revision, skill estimate follows.
        let live = try rig.prog.evidence(skillId: rig.skillA.id)
        #expect(live.count == 1 && live[0].score == 0 && live[0].revisionId == rev2.id)
        #expect(try rig.db.read { try LearningEvidence.fetchCount($0) } == 2)
        #expect(try rig.prog.mastery(skillId: rig.skillA.id).overall == 0)
        #expect(try rig.prog.history(skillId: rig.skillA.id).count == 2)
        // Skill XP stays consistent with the corrected ledger.
        #expect(try rig.prog.skillXP(rig.skillA.id).xp == after.xp)
    }

    @Test func disputeRemovesEvidenceAndBonusUntilRegraded() throws {
        let rig = try Rig()
        let q = try rig.question(4)
        let a = try rig.attempt(q, text: "14")
        let r = try rig.eval.evaluate(attemptId: a.id)
        #expect(r.xp > XPRules.participation(difficulty: 2, attemptNumber: 1))
        let d = try rig.eval.dispute(attemptId: a.id, note: "Key looks wrong")
        #expect(d.evaluation.state == .needsReview && d.evaluation.score == nil && d.evaluation.reason.contains("Key looks wrong"))
        #expect(d.xp == XPRules.participation(difficulty: 2, attemptNumber: 1))
        #expect(try rig.prog.mastery(skillId: rig.skillA.id).isUnknown)
        let o = try rig.eval.overrideGrade(attemptId: a.id, correct: true)
        #expect(o.evaluation.trust == .selfReported && o.evaluation.score == 1)
        #expect(try rig.eval.history(attemptId: a.id).count == 3)
        #expect(try rig.eval.history(attemptId: a.id).filter { $0.supersededAt == nil }.count == 1)
    }

    @Test func courseXPIsNotDoubleCountedAcrossSkills() throws {
        let rig = try Rig()
        let q = try rig.question(4, skills: [rig.skillA, rig.skillB])
        let r = try rig.eval.evaluate(attemptId: try rig.attempt(q, text: "14").id)
        let course = try rig.prog.courseXP(rig.course.id).xp
        let a = try rig.prog.skillXP(rig.skillA.id).xp, b = try rig.prog.skillXP(rig.skillB.id).xp
        #expect(course == r.xp && a + b == course && a > 0 && b > 0)
        // Untagged questions still count for the course, just for no skill.
        let loose = try rig.qs.create(courseId: rig.course.id, spec: QuestionValidator.validate(entry: Fx.all[3], index: 0).question!.spec)
        _ = try rig.eval.evaluate(attemptId: try rig.attempt(loose, text: "hasNext").id)
        #expect(try rig.prog.courseXP(rig.course.id).xp > course)
        #expect(try rig.prog.skillXP(rig.skillA.id).xp + rig.prog.skillXP(rig.skillB.id).xp == course)
    }

    @Test func xpAndMasteryAreIndependentSystems() throws {
        let rig = try Rig()
        // Lots of participation XP from pending (ungraded) work: XP rises, mastery stays Unknown.
        for i in 0..<3 { _ = try rig.eval.evaluate(attemptId: try rig.attempt(try rig.question(7, title: "LF \(i)"), text: "x").id) }
        #expect(try rig.prog.courseXP(rig.course.id).xp > 0)
        #expect(try rig.prog.mastery(skillId: rig.skillA.id).isUnknown)
        // And the other way round: a wrong graded answer lowers mastery while XP never goes below participation.
        let wrong = try rig.eval.evaluate(attemptId: try rig.attempt(try rig.question(3), text: "nope").id)
        #expect(wrong.evaluation.score == 0 && wrong.xp > 0)
        #expect(try rig.prog.mastery(skillId: rig.skillA.id).overall == 0)
    }

    @Test func courseAndAssessmentProgressStayDistinct() throws {
        let rig = try Rig()
        let m1 = try rig.courses.addAssessment(courseId: rig.course.id, name: "Midterm 1")
        let m2 = try rig.courses.addAssessment(courseId: rig.course.id, name: "Midterm 2")
        let fin = try rig.courses.addAssessment(courseId: rig.course.id, name: "Final", kind: .final, isCumulative: true)
        try rig.courses.addToScope(assessmentId: m1.id, skillId: rig.skillA.id)
        try rig.courses.addToScope(assessmentId: m2.id, skillId: rig.skillB.id)
        let q = try rig.question(4)
        try rig.qs.addToAssessment(questionIds: [q.id], assessmentId: m1.id)
        try rig.qs.addToAssessment(questionIds: [q.id], assessmentId: fin.id)
        var p = try rig.prog.assessmentProgress(assessmentId: m1.id)
        #expect(p.assessedSkillCount == 0 && p.meanMastery == nil && p.confidence == .unknown && p.questionCount == 1 && p.attemptedQuestionCount == 0)

        _ = try rig.eval.evaluate(attemptId: try rig.attempt(q, text: "14").id)
        p = try rig.prog.assessmentProgress(assessmentId: m1.id)
        #expect(p == AssessmentProgress(skillCount: 1, assessedSkillCount: 1, questionCount: 1, attemptedQuestionCount: 1, meanMastery: 1, confidence: .preliminary))
        let f = try rig.prog.assessmentProgress(assessmentId: fin.id)
        #expect(f.skillCount == 2 && f.assessedSkillCount == 1)                    // cumulative sees the whole course
        let p2 = try rig.prog.assessmentProgress(assessmentId: m2.id)
        #expect(p2.assessedSkillCount == 0 && p2.meanMastery == nil)               // other exam: nothing assessed, not "0%"
        #expect(try rig.prog.courseXP(rig.course.id).xp > 0)                       // XP is a course-level measure
    }

    @Test func addingAnExamLaterKeepsXPAndMastery() throws {
        // The COMP 211 acceptance journey: Midterm 2 first, then Midterm 1 and a cumulative Final.
        let rig = try Rig()
        let m2 = try rig.courses.addAssessment(courseId: rig.course.id, name: "Midterm 2")
        try rig.courses.addToScope(assessmentId: m2.id, skillId: rig.skillA.id)
        let q = try rig.question(4)
        try rig.qs.addToAssessment(questionIds: [q.id], assessmentId: m2.id)
        _ = try rig.eval.evaluate(attemptId: try rig.attempt(q, text: "14").id)
        let xp = try rig.prog.courseXP(rig.course.id).xp, mastery = try rig.prog.mastery(skillId: rig.skillA.id).overall
        let m1 = try rig.courses.addAssessment(courseId: rig.course.id, name: "Midterm 1")
        let again = try rig.courses.addSkill(courseId: rig.course.id, name: "JAVA  iterators")
        #expect(!again.created && again.skill.id == rig.skillA.id)                 // reused, never duplicated
        try rig.courses.addToScope(assessmentId: m1.id, skillId: again.skill.id)
        let fin = try rig.courses.addAssessment(courseId: rig.course.id, name: "Final", kind: .final, isCumulative: true)
        try rig.qs.addToAssessment(questionIds: [q.id], assessmentId: fin.id)
        #expect(try rig.prog.courseXP(rig.course.id).xp == xp && (try rig.prog.mastery(skillId: rig.skillA.id).overall) == mastery)
        #expect(try rig.prog.assessmentProgress(assessmentId: m1.id).assessedSkillCount == 1)   // existing evidence counts for the new exam
        #expect(try rig.practice.questionIds(courseId: rig.course.id, assessmentId: fin.id) == [q.id])  // question reused, not copied
    }

    @Test func milestonesAreAwardedOnceAtLevelThresholds() throws {
        let rig = try Rig()
        _ = try rig.eval.evaluate(attemptId: try rig.attempt(try rig.question(4), text: "14").id)       // 19 XP
        _ = try rig.eval.evaluate(attemptId: try rig.attempt(try rig.question(3, title: "SA 2"), text: "hasNext").id)   // → crosses 25
        let ms = try rig.prog.milestones(courseId: rig.course.id)
        #expect(ms.contains { $0.key == "first_attempt" })
        #expect(ms.contains { $0.key == "skill_level:\(rig.skillA.id):2" && $0.title.contains("Java iterators") })
        #expect(ms.contains { $0.key == "course_level:\(rig.course.id):2" })
        let n = ms.count
        _ = try rig.eval.regradeQuestion(questionId: try rig.db.read { try Question.fetchAll($0)[0].id })
        #expect(try rig.prog.milestones(courseId: rig.course.id).count == n)                              // not duplicated
        #expect(Set(ms.map(\.key)).count == ms.count)
        let s = try rig.prog.skillXP(rig.skillA.id)
        #expect(s.level == 2 && s.xpIntoLevel == s.xp - 25 && s.xpForNextLevel == 75)
    }

    @Test func sessionResultsSummariseHonestly() throws {
        let rig = try Rig()
        let qs = [try rig.question(4), try rig.question(1), try rig.question(7), try rig.question(3, title: "Skip me")]
        let s = try rig.practice.start(questionIds: qs.map(\.id), title: "Mixed", courseId: rig.course.id)
        let items = try rig.practice.items(sessionId: s.id)
        func submit(_ i: Int, _ f: (inout PracticeResponse) -> Void) throws {
            var r = PracticeResponse(); f(&r)
            let a = try rig.practice.submit(itemId: items[i].id, response: r); _ = try rig.eval.evaluate(attemptId: a.id)
        }
        try submit(0) { $0.text = "14" }                 // trusted correct
        try submit(1) { $0.selected = ["b"] }            // provisional incorrect
        try submit(2) { $0.text = "essay" }              // pending
        try rig.practice.skip(itemId: items[3].id)
        let r = try rig.prog.sessionResults(sessionId: s.id)
        #expect(r.correct == 1 && r.incorrect == 1 && r.pending == 1 && r.skipped == 1 && r.unanswered == 0 && r.needsReview == 0)
        #expect(r.provisional == 1 && r.items.count == 4 && r.xp > 0)
        #expect(r.xp == (try rig.prog.courseXP(rig.course.id).xp))
    }

    @Test func everythingSurvivesRestart() throws {
        let dir = try tempDir(); let path = dir.appendingPathComponent("m5.sqlite")
        let rig = try Rig(db: try AppDatabase.open(at: path))
        let q = try rig.question(4)
        let r = try rig.eval.evaluate(attemptId: try rig.attempt(q, text: "14").id)
        let reopened = try Rig.reopen(path, course: rig.course, skill: rig.skillA)
        #expect(try reopened.prog.courseXP(rig.course.id).xp == r.xp)
        #expect(try reopened.prog.mastery(skillId: rig.skillA.id).overall == 1)
        #expect(try reopened.eval.result(attemptId: r.attempt.id)?.evaluation.id == r.evaluation.id)
        #expect(try reopened.prog.milestones().isEmpty == false)
    }
}

extension Rig {
    /// Services over an existing database (no new course/skills).
    struct Reopened { let prog: ProgressionService; let eval: EvaluationService }
    static func reopen(_ path: URL, course: Course, skill: Skill) throws -> Reopened {
        let db = try AppDatabase.open(at: path)
        return Reopened(prog: ProgressionService(db: db), eval: EvaluationService(db: db))
    }
}

@Suite struct AIGradingTests {
    func pendingEssays(_ rig: Rig, _ n: Int) throws -> [Attempt] {
        var out: [Attempt] = []
        for i in 0..<n {
            let a = try rig.attempt(try rig.question(7, title: "Essay \(i)"), text: "Answer \(i)")
            _ = try rig.eval.evaluate(attemptId: a.id); out.append(a)
        }
        return out
    }
    func grades(_ requestId: String, _ entries: [[String: Any]]) -> String {
        String(data: try! JSONSerialization.data(withJSONObject: ["schemaVersion": GradeSchema.version, "requestId": requestId, "grades": entries], options: [.sortedKeys]), encoding: .utf8)!
    }

    @Test func requestContainsEverythingNeededAndDisclosesIt() throws {
        let rig = try Rig()
        let a = try pendingEssays(rig, 2)
        let task = try rig.ai.createGradingTask(courseId: rig.course.id, attemptIds: a.map(\.id))
        let b = try rig.ai.batches(taskId: task.id)[0]
        #expect(b.kind == .grade && b.expectedCount == 2)
        let pkg = try rig.ai.prepare(batchId: b.id)
        for x in a { #expect(pkg.singlePrompt.contains(x.id.uuidString) && pkg.singlePrompt.contains(x.revisionId.uuidString)) }
        #expect(pkg.singlePrompt.contains("Answer 0") && pkg.singlePrompt.contains("clear") && pkg.singlePrompt.contains("Learning objective"))
        #expect(pkg.singlePrompt.contains(b.requestId) && pkg.singlePrompt.contains(GradeSchema.version))
        #expect(pkg.manifest.includedResponses == 2 && pkg.manifest.kind == .grade && pkg.manifest.excluded.contains { $0.contains("reflections") })
        #expect(Set(pkg.files.map(\.name)).isSuperset(of: ["instructions.md", "attempts.md", "response_schema.json", "manifest.json"]))
        #expect(throws: AITaskError.self) { try rig.ai.createRepairBatch(from: b.id) }
        #expect(try rig.ai.status(taskId: task.id) == .draft)
        // Only pending answers from one course can be sent.
        let graded = try rig.attempt(try rig.question(4, title: "Num"), text: "14"); _ = try rig.eval.evaluate(attemptId: graded.id)
        #expect(throws: AITaskError.self) { try rig.ai.createGradingTask(courseId: rig.course.id, attemptIds: [graded.id]) }
        #expect(throws: AITaskError.self) { try rig.ai.createGradingTask(courseId: rig.course.id, attemptIds: []) }
    }

    @Test func importedGradesReferenceOriginalAttemptsAndFeedProgression() throws {
        let rig = try Rig()
        let a = try pendingEssays(rig, 2)
        let task = try rig.ai.createGradingTask(courseId: rig.course.id, attemptIds: a.map(\.id))
        let b = try rig.ai.batches(taskId: task.id)[0]
        try rig.ai.markExported(batchId: b.id, method: .clipboard)
        let resp = grades(b.requestId, [["attemptId": a[0].id.uuidString, "score": 0.9, "feedback": "Strong."],
                                        ["attemptId": a[1].id.uuidString, "rubricScores": [["criterion": "clear", "points": 1]], "feedback": "Thin."]])
        #expect(AITaskService.peekSchemaVersion("```json\n\(resp)\n```") == GradeSchema.version)
        let rep = try rig.ai.importGrades(resp, targetBatchId: b.id)
        #expect(rep.graded.count == 2 && rep.rejected.isEmpty && rep.batchStatus == .imported && !rep.alreadyImported)
        let r0 = try #require(try rig.eval.result(attemptId: a[0].id)), r1 = try #require(try rig.eval.result(attemptId: a[1].id))
        #expect(r0.evaluation.attemptId == a[0].id && r0.evaluation.trust == .aiGraded && r0.evaluation.score == 0.9 && r0.evaluation.batchId == b.id)
        #expect(r0.evaluation.feedback == "Strong." && r0.evaluation.source == .aiImport)
        #expect(r1.evaluation.score == 0.5)                                    // 1 of the rubric's 2 points
        #expect(r0.xp == XPRules.participation(difficulty: 2, attemptNumber: 1) + XPRules.correctness(difficulty: 2))   // ≥0.8, AI-graded, unassisted
        #expect(r1.xp == XPRules.participation(difficulty: 2, attemptNumber: 1))
        #expect(try rig.prog.evidence(skillId: rig.skillA.id).count == 2)
        #expect(try rig.eval.history(attemptId: a[0].id).map(\.state) == [.pending, .graded])
        #expect(try rig.ai.status(taskId: task.id) == .completed && (try rig.eval.pendingAttempts().isEmpty))
        // Re-pasting is a no-op.
        let again = try rig.ai.importGrades(resp, targetBatchId: b.id)
        #expect(again.alreadyImported && again.graded.isEmpty)
        #expect(try rig.prog.courseXP(rig.course.id).xp == r0.xp + r1.xp)
        #expect(try rig.db.read { try Evaluation.fetchCount($0) } == 4)
        #expect(try rig.ai.imports(batchId: b.id)[0].rawResponse == resp)
    }

    @Test func badGradesAreRejectedIndividually() throws {
        let rig = try Rig()
        let a = try pendingEssays(rig, 3)
        let auto = try rig.attempt(try rig.question(4, title: "Auto"), text: "14"); _ = try rig.eval.evaluate(attemptId: auto.id)
        let task = try rig.ai.createGradingTask(courseId: rig.course.id, attemptIds: a.map(\.id))
        let b = try rig.ai.batches(taskId: task.id)[0]
        let resp = grades(b.requestId, [
            ["attemptId": a[0].id.uuidString, "score": 1, "feedback": "ok"],                 // fine
            ["attemptId": a[0].id.uuidString, "score": 0, "feedback": "dup"],                // duplicate
            ["attemptId": UUID().uuidString, "score": 1, "feedback": "x"],                   // not in the request
            ["attemptId": auto.id.uuidString, "score": 0, "feedback": "x"],                  // machine-graded, not part of the batch
            ["attemptId": a[1].id.uuidString, "score": 7, "feedback": "x"],                  // out of range
            ["attemptId": a[2].id.uuidString, "feedback": "no score"],                       // no score at all
            ["feedback": "no id"],
        ])
        let rep = try rig.ai.importGrades(resp, targetBatchId: b.id)
        #expect(rep.graded.map(\.attemptId) == [a[0].id])
        #expect(rep.rejected.count == 6 && rep.batchStatus == .needsRepair)
        #expect(rep.rejected.contains { $0.issues.contains { $0.contains("duplicate") } } && rep.rejected.contains { $0.issues.contains { $0.contains("isn’t part of this request") } })
        #expect(try rig.eval.pendingAttempts().count == 2)                                   // others stay pending, not incorrect
        #expect(try rig.eval.result(attemptId: a[1].id)?.evaluation.state == .pending)
        #expect(try rig.eval.result(attemptId: auto.id)?.evaluation.source == .deterministic)
        #expect(try rig.ai.status(taskId: task.id) == .needsAttention)
    }

    @Test func wrongRequestSchemaAndMalformedAreRefusedAndPreserved() throws {
        let rig = try Rig()
        let a = try pendingEssays(rig, 1), b2 = try pendingEssays(rig, 1)
        let t1 = try rig.ai.createGradingTask(courseId: rig.course.id, attemptIds: a.map(\.id))
        let t2 = try rig.ai.createGradingTask(courseId: rig.course.id, attemptIds: b2.map(\.id))
        let b1 = try rig.ai.batches(taskId: t1.id)[0], b2b = try rig.ai.batches(taskId: t2.id)[0]
        let resp = grades(b2b.requestId, [["attemptId": b2[0].id.uuidString, "score": 1, "feedback": "x"]])
        #expect(throws: AITaskError.requestMismatch(expected: b1.requestId, found: b2b.requestId)) { try rig.ai.importGrades(resp, targetBatchId: b1.id) }
        #expect(throws: AITaskError.unknownRequest("req-x")) { try rig.ai.importGrades(grades("req-x", [])) }
        #expect(throws: AITaskError.unsupportedSchema("braincell.grades.v0")) {
            try rig.ai.importGrades("{\"schemaVersion\":\"braincell.grades.v0\",\"requestId\":\"\(b1.requestId)\",\"grades\":[]}", targetBatchId: b1.id)
        }
        #expect(throws: AITaskError.self) { try rig.ai.importGrades("not json", targetBatchId: b1.id) }
        #expect(try rig.eval.pendingAttempts().count == 2)
        #expect(try rig.db.read { try AIImport.fetchCount($0) } == 4)                         // raw text of every failed attempt kept
        // A question-generation response is recognisable as such, so the UI can route it elsewhere.
        #expect(AITaskService.peekSchemaVersion(Fx.envelope("r", [])) == QuestionSchema.version)
    }

    @Test func aiGradeCanBeDisputedAndReplacedWithoutLosingHistory() throws {
        let rig = try Rig()
        let a = try pendingEssays(rig, 1)
        let t = try rig.ai.createGradingTask(courseId: rig.course.id, attemptIds: a.map(\.id))
        let b = try rig.ai.batches(taskId: t.id)[0]
        _ = try rig.ai.importGrades(grades(b.requestId, [["attemptId": a[0].id.uuidString, "score": 0.1, "feedback": "Weak."]]), targetBatchId: b.id)
        _ = try rig.eval.dispute(attemptId: a[0].id, note: "It missed my second paragraph")
        #expect(try rig.prog.mastery(skillId: rig.skillA.id).isUnknown)                     // under review: no evidence
        let fixed = try rig.eval.selfReview(attemptId: a[0].id, score: 0.8, note: "Reviewed")
        #expect(fixed.evaluation.score == 0.8)
        #expect(try rig.eval.history(attemptId: a[0].id).map(\.state) == [.pending, .graded, .needsReview, .graded])
        #expect(try rig.eval.history(attemptId: a[0].id).map { $0.score } == [nil, 0.1, nil, 0.8])
    }
}

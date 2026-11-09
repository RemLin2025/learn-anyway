import Testing
import Foundation
import GRDB
@testable import BraincellCore

@Suite struct AIBridgeTests {
    let db: AppDatabase, courses: CourseService, ai: AITaskService, qs: QuestionService, docs: DocumentService
    let course: Course, midterm: Assessment, dir: URL

    init() throws {
        db = try AppDatabase.inMemory(); courses = CourseService(db: db); ai = AITaskService(db: db); qs = QuestionService(db: db)
        dir = try tempDir()
        docs = DocumentService(db: db, storage: ManagedStorage(root: dir))
        course = try courses.createCourse(name: "COMP 211")
        midterm = try courses.addAssessment(courseId: course.id, name: "Midterm 2")
        let s = try courses.addSkill(courseId: course.id, name: "Java iterators").skill
        try courses.addToScope(assessmentId: midterm.id, skillId: s.id)
    }

    func newTask(count: Int = 3, params: GenerationParams? = nil) throws -> (AITask, AITaskBatch) {
        var p = params ?? GenerationParams(count: count); p.count = count
        let t = try ai.createGenerationTask(courseId: course.id, assessmentId: midterm.id, params: p)
        return (t, try ai.batches(taskId: t.id)[0])
    }

    func qs3(_ n: Int = 3) -> [[String: Any]] { Array(Fx.all.prefix(n)) }

    // MARK: Request preparation

    @Test func largeTasksSplitIntoBatchesWithUniqueRequestIds() throws {
        let t = try ai.createGenerationTask(courseId: course.id, params: GenerationParams(count: 25))
        let b = try ai.batches(taskId: t.id)
        #expect(b.map(\.expectedCount) == [10, 10, 5])
        #expect(Set(b.map(\.requestId)).count == 3)
        #expect(b.allSatisfy { $0.status == .draft })
        #expect(try ai.status(taskId: t.id) == .draft)
        #expect(throws: AITaskError.self) { try ai.createGenerationTask(courseId: course.id, params: GenerationParams(count: 0)) }
    }

    @Test func promptContainsContractAndDisclosesContext() throws {
        let src = dir.appendingPathComponent("n.txt")
        try "Iterators expose hasNext and next.\n\nA for-each loop uses an Iterator.".write(to: src, atomically: true, encoding: .utf8)
        let d = try docs.importFile(at: src, courseId: course.id).document
        _ = try qs.create(courseId: course.id, spec: QuestionValidator.validate(entry: Fx.all[0], index: 0).question!.spec)
        let (_, batch) = try newTask(params: GenerationParams(count: 2, types: [.flashcard, .numeric], documentIds: [d.id], notes: "focus on edge cases"))
        let pkg = try ai.prepare(batchId: batch.id)
        #expect(pkg.singlePrompt.contains(batch.requestId))
        #expect(pkg.singlePrompt.contains(QuestionSchema.version))
        #expect(pkg.singlePrompt.contains("Java iterators"))
        #expect(pkg.singlePrompt.contains("hasNext and next"))
        #expect(pkg.singlePrompt.contains("- FC")) // existing question titles to avoid duplicates
        #expect(pkg.manifest.documents.map(\.title) == ["n"])
        #expect(pkg.manifest.existingQuestionTitles == 1 && pkg.manifest.includesUserNotes)
        #expect(pkg.manifest.excluded.contains { $0.contains("attempt") })
        #expect(pkg.recommended == .clipboard)
        #expect(Set(pkg.files.map(\.name)).isSuperset(of: ["instructions.md", "response_schema.json", "manifest.json", "context_skills.md"]))
        #expect(!pkg.singlePrompt.contains("Pasted"))
        // Nothing is "exported" until the user acts.
        #expect(try ai.batches(taskId: batch.taskId)[0].status == .draft)
    }

    @Test func largeContextRecommendsFileExport() throws {
        let big = (0..<40).map { "Paragraph \($0) " + String(repeating: "iterator ", count: 120) }.joined(separator: "\n\n")
        let d = try docs.importPasted(text: big, title: "Big", courseId: course.id).document
        let (_, batch) = try newTask(params: GenerationParams(count: 5, documentIds: [d.id]))
        let pkg = try ai.prepare(batchId: batch.id)
        #expect(pkg.recommended == .file)
        #expect(pkg.manifest.documents[0].truncated)
        #expect(pkg.manifest.documents[0].characters <= PromptBuilder.extractBudget)
        let out = dir.appendingPathComponent("export"); try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        try AITaskService.write(pkg.files + [ExportFile(name: "../evil.txt", content: "x")], to: out)
        #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("evil.txt").path))
        #expect(FileManager.default.fileExists(atPath: out.appendingPathComponent("manifest.json").path))
    }

    @Test func exportMarksAwaitingImportAndSurvivesRestart() throws {
        let path = dir.appendingPathComponent("db.sqlite")
        let file = try AppDatabase.open(at: path)
        let c = try CourseService(db: file).createCourse(name: "X")
        let svc = AITaskService(db: file)
        let t = try svc.createGenerationTask(courseId: c.id, params: GenerationParams(count: 3))
        let b = try svc.batches(taskId: t.id)[0]
        try svc.prepare(batchId: b.id)
        try svc.markExported(batchId: b.id, method: .clipboard)
        let reopened = AITaskService(db: try AppDatabase.open(at: path))
        let again = try reopened.batches(taskId: t.id)[0]
        #expect(again.status == .awaitingImport && again.transferMethod == .clipboard && again.exportedAt != nil)
        #expect(!again.requestText.isEmpty && again.requestId == b.requestId)
        #expect(try reopened.status(taskId: t.id) == .awaitingImport)
    }

    // MARK: Import

    @Test func validResponseImportsAndLinksEverything() throws {
        let (t, b) = try newTask(count: 3)
        let r = try ai.importResponse(Fx.envelope(b.requestId, qs3()), targetBatchId: b.id)
        #expect(r.accepted.count == 3 && r.rejected.isEmpty && r.batchStatus == .imported && !r.alreadyImported)
        #expect(try ai.status(taskId: t.id) == .completed)
        let rows = try qs.list()
        #expect(rows.count == 3)
        // Task's assessment and the named skill are attached; verified/unverified honestly reported.
        var f = QuestionFilter(); f.assessmentId = midterm.id
        #expect(try qs.list(f).count == 3)
        let d = try qs.detail(r.accepted[0].questionId)
        #expect(d.skills.map(\.name) == ["Java iterators"])
        #expect(d.revision.origin == .aiImport && d.revision.aiImportId == r.importId)
        #expect(r.accepted.allSatisfy { $0.readiness == .unverified })
        #expect(try ai.imports(batchId: b.id)[0].rawResponse.contains("FC")) // original preserved
    }

    @Test func fencedJSONWithProseIsAccepted() throws {
        let (_, b) = try newTask(count: 1)
        let wrapped = "Sure! Here you go:\n```json\n\(Fx.envelope(b.requestId, qs3(1)))\n```\nLet me know if you need more."
        #expect(try ai.importResponse(wrapped).accepted.count == 1)
    }

    @Test func malformedAndUnsupportedFailGracefullyAndPreserveText() throws {
        let (_, b) = try newTask(count: 1)
        #expect(throws: AITaskError.self) { try ai.importResponse("{ this is not json", targetBatchId: b.id) }
        #expect(throws: AITaskError.malformedJSON("no JSON object found")) { try ai.importResponse("just words") }
        #expect(throws: AITaskError.unsupportedSchema("braincell.questions.v99")) {
            try ai.importResponse(Fx.envelope(b.requestId, qs3(1), version: "braincell.questions.v99"), targetBatchId: b.id)
        }
        #expect(throws: AITaskError.missingRequestId) { try ai.importResponse("{\"schemaVersion\":\"\(QuestionSchema.version)\",\"questions\":[]}") }
        #expect(try qs.list().isEmpty)
        let kept = try ai.imports(batchId: b.id)
        #expect(kept.count == 2 && kept.contains { $0.outcome == .malformed })
        #expect(try db.read { try AIImport.fetchCount($0) } == 4) // every unusable response was preserved
        #expect(try ai.batches(taskId: b.taskId)[0].status == .draft) // unchanged
    }

    @Test func wrongRequestIdIsNeverAttachedToAnotherTask() throws {
        let (_, b1) = try newTask(count: 1)
        let (_, b2) = try newTask(count: 1)
        let resp = Fx.envelope(b2.requestId, qs3(1))
        #expect(throws: AITaskError.requestMismatch(expected: b1.requestId, found: b2.requestId)) { try ai.importResponse(resp, targetBatchId: b1.id) }
        #expect(throws: AITaskError.unknownRequest("req-nope")) { try ai.importResponse(Fx.envelope("req-nope", qs3(1))) }
        #expect(try qs.list().isEmpty)
        // Without a target, an exact requestId match routes to its own batch.
        #expect(try ai.importResponse(resp).batchId == b2.id)
    }

    @Test func pastingTheSameResponseTwiceImportsOnce() throws {
        let (_, b) = try newTask(count: 3)
        let resp = Fx.envelope(b.requestId, qs3())
        let first = try ai.importResponse(resp, targetBatchId: b.id)
        let second = try ai.importResponse(resp, targetBatchId: b.id)
        #expect(second.alreadyImported && second.importId == first.importId && second.accepted.isEmpty)
        // Reformatted JSON (different bytes, same content) is the same response.
        let pretty = String(data: try JSONSerialization.data(withJSONObject: JSONSerialization.jsonObject(with: Data(resp.utf8)), options: [.prettyPrinted]), encoding: .utf8)!
        #expect(try ai.importResponse(pretty, targetBatchId: b.id).alreadyImported)
        #expect(try qs.list().count == 3)
    }

    @Test func sameQuestionsInANewResponseAreDuplicatesNotCopies() throws {
        let (_, b1) = try newTask(count: 2)
        _ = try ai.importResponse(Fx.envelope(b1.requestId, qs3(2)))
        let (_, b2) = try newTask(count: 2)
        let r = try ai.importResponse(Fx.envelope(b2.requestId, qs3(2)))
        #expect(r.accepted.isEmpty && r.duplicates.count == 2 && r.batchStatus == .imported)
        #expect(try qs.list().count == 2)
    }

    @Test func partialBatchKeepsAcceptedAndRepairNamesExactIssues() throws {
        let (t, b) = try newTask(count: 3)
        var bad = Fx.all[1]; bad["difficulty"] = 9
        bad["answer"] = ["choices": [["id": "a", "text": "A"], ["id": "b", "text": "B"]], "correctIds": ["zz"]]
        let r = try ai.importResponse(Fx.envelope(b.requestId, [Fx.all[0], bad, Fx.all[3]]), targetBatchId: b.id)
        #expect(r.accepted.count == 2 && r.rejected.count == 1 && r.batchStatus == .needsRepair)
        #expect(try qs.list().count == 2)
        #expect(try ai.status(taskId: t.id) == .needsAttention)

        let repair = try ai.createRepairBatch(from: b.id)
        #expect(repair.kind == .repair && repair.parentBatchId == b.id && repair.expectedCount == 1 && repair.requestId != b.requestId)
        let text = try ai.prepare(batchId: repair.id).singlePrompt
        #expect(text.contains("questions[1].difficulty"))
        #expect(text.contains("questions[1].answer.correctIds"))
        #expect(text.contains("“zz” is not one of the choice ids"))
        #expect(text.contains(repair.requestId))

        // Fixed version comes back under the repair request and resolves the original batch.
        var fixed = bad; fixed["difficulty"] = 3
        fixed["answer"] = ["choices": [["id": "a", "text": "A"], ["id": "b", "text": "B"]], "correctIds": ["a"]]
        let r2 = try ai.importResponse(Fx.envelope(repair.requestId, [fixed]), targetBatchId: repair.id)
        #expect(r2.accepted.count == 1 && r2.batchStatus == .imported)
        #expect(try ai.batches(taskId: t.id).first { $0.id == b.id }?.status == .imported)
        #expect(try ai.status(taskId: t.id) == .completed)
        #expect(try qs.list().count == 3)
    }

    @Test func shortResponseOffersContinuationThatSkipsWhatWeHave() throws {
        let (t, b) = try newTask(count: 4)
        let r = try ai.importResponse(Fx.envelope(b.requestId, qs3(2)))
        #expect(r.batchStatus == .incomplete)
        #expect(throws: AITaskError.nothingToRepair) { try ai.createRepairBatch(from: b.id) }
        let cont = try ai.createContinuationBatch(from: b.id)
        #expect(cont.kind == .continue && cont.expectedCount == 2)
        let prompt = try ai.prepare(batchId: cont.id).singlePrompt
        #expect(prompt.contains("Already accepted") && prompt.contains("- FC") && prompt.contains("- SC"))
        let r2 = try ai.importResponse(Fx.envelope(cont.requestId, Array(Fx.all[2...3])))
        #expect(r2.batchStatus == .imported)
        #expect(try ai.status(taskId: t.id) == .completed)
    }

    @Test func probableDuplicateAndAmbiguousSkillNeedReview() throws {
        _ = try courses.addSkill(courseId: course.id, name: "Java iterators advanced")
        let (_, b) = try newTask(count: 2)
        var q1 = Fx.all[0]; q1["skills"] = ["Java iterators"]
        var q2 = Fx.all[0]; q2["content"] = [Fx.md("Totally different statement")]; q2["importId"] = "q2"; q2["skills"] = ["iterators"]
        let r = try ai.importResponse(Fx.envelope(b.requestId, [q1, q2]))
        #expect(r.accepted.count == 2)
        let d2 = try qs.detail(r.accepted[1].questionId)
        #expect(d2.question.readiness == .needsReview)
        #expect(d2.question.notes.contains { $0.contains("Probable duplicate") })
        #expect(d2.question.notes.contains { $0.contains("Ambiguous skill “iterators”") })
        #expect(d2.skills.isEmpty) // ambiguous: nothing silently attached
    }

    @Test func unknownSkillCreatedOnlyInThisCourse() throws {
        let other = try courses.createCourse(name: "Other")
        _ = try courses.addSkill(courseId: other.id, name: "Brand new topic")
        let (_, b) = try newTask(count: 1)
        var q = Fx.all[0]; q["skills"] = ["Brand new topic"]
        _ = try ai.importResponse(Fx.envelope(b.requestId, [q]))
        let mine = try courses.skills(courseId: course.id).map(\.id)
        let theirs = try courses.skills(courseId: other.id).map(\.id)
        #expect(Set(mine).isDisjoint(with: theirs))
        #expect(try courses.skills(courseId: course.id).contains { $0.name == "Brand new topic" })
    }

    @Test func oversizedAndOverlongResponsesAreRefused() throws {
        #expect(throws: AITaskError.self) { try ai.importResponse(String(repeating: "x", count: AITaskService.maxResponseBytes + 1)) }
        let (_, b) = try newTask(count: 1)
        let many = Array(repeating: Fx.all[0], count: AITaskService.maxQuestionsPerResponse + 1)
        #expect(throws: AITaskError.tooManyQuestions(51)) { try ai.importResponse(Fx.envelope(b.requestId, many)) }
    }

    @Test func importIsAtomic() throws {
        // A failure while committing must leave no half-imported questions behind.
        let (_, b) = try newTask(count: 2)
        try db.write { try $0.execute(sql: "DROP TABLE question_skills") } // sabotage the skill link step
        #expect(throws: (any Error).self) { try ai.importResponse(Fx.envelope(b.requestId, qs3(2))) }
        #expect(try db.read { try Question.fetchCount($0) } == 0)
        #expect(try db.read { try AIImport.filter(Column("outcome") == ImportOutcomeKind.imported).fetchCount($0) } == 0)
        #expect(try ai.batches(taskId: b.taskId)[0].status == .draft)
    }
}

@Suite struct DemoTests {
    @Test func demoLoadsThroughRealPipelineAndIsIdempotent() throws {
        let db = try AppDatabase.inMemory()
        let c = try DemoWorkspace.load(into: db)
        let qs = QuestionService(db: db)
        var f = QuestionFilter(); f.courseId = c.id
        let rows = try qs.list(f)
        #expect(rows.count == 9)
        #expect(Set(rows.map(\.question.type)) == Set(QuestionType.allCases)) // one of every type
        #expect(rows.contains { $0.question.readiness == .verified })         // numeric with verified expression
        #expect(try DemoWorkspace.load(into: db).id == c.id)
        #expect(try qs.list(f).count == 9)
        #expect(try CourseService(db: db).courses().count == 1)
    }
}

import Testing
import Foundation
import GRDB
@testable import BraincellCore

@Suite struct ValidatorTests {
    @Test func everySupportedTypeValidates() {
        #expect(Fx.all.count == QuestionType.allCases.count)
        for (i, q) in Fx.all.enumerated() {
            let r = QuestionValidator.validate(entry: q, index: i)
            #expect(!r.hasBlocking, "\(q["type"]!): \(r.issues)")
            #expect(r.question?.spec.type.rawValue == q["type"] as? String)
        }
    }

    @Test func readinessLevels() {
        let numeric = QuestionValidator.validate(entry: Fx.all[4], index: 0)
        #expect(numeric.readiness == .verified)               // 2+3*4 = 14 independently confirmed
        #expect(QuestionValidator.validate(entry: Fx.all[1], index: 0).readiness == .unverified) // valid, not independently checked
        var wrong = Fx.all[4]; wrong["answer"] = ["value": 15, "tolerance": 0, "verificationExpression": "2+3*4"]
        let w = QuestionValidator.validate(entry: wrong, index: 0)
        #expect(w.readiness == .needsReview)                  // stated answer contradicts the expression
        #expect(w.issues.contains { $0.message.contains("evaluates to 14") })
        var noSolution = Fx.all[1]; noSolution["solution"] = []
        #expect(QuestionValidator.validate(entry: noSolution, index: 0).readiness == .needsReview)
        #expect(QuestionValidator.validate(entry: "nope", index: 0).readiness == .invalid)
        #expect(!Readiness.unverified.allowsTrustedAutoGrading && Readiness.verified.allowsTrustedAutoGrading)
    }

    @Test func issuesCarryExactPaths() {
        var q = Fx.all[1]
        q["difficulty"] = 9
        q["type"] = "single_choice"
        q["answer"] = ["choices": [["id": "a", "text": "A"], ["id": "b", "text": "B"]], "correctIds": ["z"]]
        q["evaluation"] = ["method": "exact"]
        let r = QuestionValidator.validate(entry: q, index: 3)
        let paths = Set(r.issues.map(\.path))
        #expect(paths.contains("questions[3].difficulty"))
        #expect(paths.contains("questions[3].evaluation.method"))
        #expect(r.question == nil)
        var q2 = Fx.all[1]; q2["answer"] = ["choices": [["id": "a", "text": "A"], ["id": "b", "text": "B"]], "correctIds": ["z"]]
        #expect(QuestionValidator.validate(entry: q2, index: 0).issues.first?.path == "questions[0].answer.correctIds")
    }

    @Test func structuralLimitsAndTypeRules() {
        var q = Fx.all[1]; q["type"] = "hologram"
        #expect(QuestionValidator.validate(entry: q, index: 0).issues.first?.message.contains("unsupported question type") == true)
        var img = Fx.all[0]; img["content"] = [["kind": "image", "ref": "x.png"]] // missing accessible description
        #expect(QuestionValidator.validate(entry: img, index: 0).issues.contains { $0.path.hasSuffix("description") })
        var long = Fx.all[0]; long["title"] = String(repeating: "x", count: 500)
        #expect(QuestionValidator.validate(entry: long, index: 0).hasBlocking)
        var lang = Fx.all[6]; lang["answer"] = ["language": "ruby"]
        #expect(QuestionValidator.validate(entry: lang, index: 0).hasBlocking)
        var single = Fx.all[1]; single["answer"] = ["choices": [["id": "a", "text": "A"], ["id": "b", "text": "B"]], "correctIds": ["a", "b"]]
        #expect(QuestionValidator.validate(entry: single, index: 0).hasBlocking)
    }

    @Test func numbersOneAndZeroAreNotBooleans() throws {
        var q = Fx.all[0]; q["difficulty"] = 1
        #expect(!QuestionValidator.validate(entry: q, index: 0).hasBlocking)
        let json = try JSONSerialization.jsonObject(with: Data(#"{"d": true, "n": 1}"#.utf8)) as! [String: Any]
        var bad = Fx.all[0]; bad["difficulty"] = json["d"]!
        #expect(QuestionValidator.validate(entry: bad, index: 0).hasBlocking) // real booleans still rejected
    }

    @Test func arithmeticEvaluator() throws {
        #expect(try ArithmeticEvaluator.evaluate("2+3*4") == 14)
        #expect(try ArithmeticEvaluator.evaluate("-(2^3)^2") == -64)  // unary minus binds looser than ^
        #expect(try ArithmeticEvaluator.evaluate("25/2") == 12.5)
        #expect(abs(try ArithmeticEvaluator.evaluate("2*pi") - 6.283185307) < 1e-6)
        #expect(throws: ArithmeticEvaluator.EvalError.divideByZero) { try ArithmeticEvaluator.evaluate("1/0") }
        #expect(throws: ArithmeticEvaluator.EvalError.syntax) { try ArithmeticEvaluator.evaluate("system(\"rm\")") }
        #expect(throws: ArithmeticEvaluator.EvalError.syntax) { try ArithmeticEvaluator.evaluate("(1+2") }
        #expect(throws: ArithmeticEvaluator.EvalError.tooLong) { try ArithmeticEvaluator.evaluate(String(repeating: "(", count: 60) + "1" + String(repeating: ")", count: 60)) }
    }
}

@Suite struct QuestionServiceTests {
    let db: AppDatabase, courses: CourseService, qs: QuestionService
    let course: Course, skill: Skill
    init() throws {
        db = try AppDatabase.inMemory(); courses = CourseService(db: db); qs = QuestionService(db: db)
        course = try courses.createCourse(name: "COMP 211")
        skill = try courses.addSkill(courseId: course.id, name: "Java iterators").skill
    }

    func spec(_ title: String = "Iterator basics", answer: Int = 14) -> QuestionSpec {
        QuestionValidator.validate(entry: { var q = Fx.all[4]; q["title"] = title; q["answer"] = ["value": answer, "tolerance": 0, "verificationExpression": "2+3*4"]; return q }(), index: 0).question!.spec
    }

    @Test func oneQuestionServesManyAssessmentsWithoutDuplication() throws {
        let q = try qs.create(courseId: course.id, spec: spec(), skillIds: [skill.id])
        let m1 = try courses.addAssessment(courseId: course.id, name: "Midterm 1")
        let fin = try courses.addAssessment(courseId: course.id, name: "Final", kind: .final, isCumulative: true)
        try qs.addToAssessment(questionIds: [q.id], assessmentId: m1.id)
        try qs.addToAssessment(questionIds: [q.id], assessmentId: fin.id)
        try qs.addToAssessment(questionIds: [q.id], assessmentId: fin.id) // idempotent
        #expect(try db.read { try Question.fetchCount($0) } == 1)
        var f = QuestionFilter(); f.assessmentId = m1.id
        #expect(try qs.list(f).map(\.id) == [q.id])
        f.assessmentId = fin.id
        #expect(try qs.list(f).map(\.id) == [q.id])
        let other = try courses.createCourse(name: "Other")
        let foreign = try courses.addAssessment(courseId: other.id, name: "X")
        #expect(throws: QuestionError.wrongCourse) { try qs.addToAssessment(questionIds: [q.id], assessmentId: foreign.id) }
    }

    @Test func editCreatesRevisionAndOldOneIsImmutable() throws {
        let q = try qs.create(courseId: course.id, spec: spec(), skillIds: [skill.id])
        let first = try qs.revisions(q.id)[0]
        let rev2 = try qs.edit(questionId: q.id, spec: spec("Renamed", answer: 14))
        #expect(rev2.number == 2)
        let revs = try qs.revisions(q.id)
        #expect(revs.count == 2)
        #expect(revs[0].payload == first.payload && revs[0].title == "Iterator basics") // history untouched
        let d = try qs.detail(q.id)
        #expect(d.revision.id == rev2.id && d.spec.title == "Renamed")
        // The database itself refuses to alter a revision.
        #expect(throws: DatabaseError.self) {
            try db.write { try $0.execute(sql: "UPDATE question_revisions SET title = 'tampered' WHERE id = ?", arguments: [first.id]) }
        }
    }

    @Test func verificationResetsOnEditAndUserCanVerify() throws {
        let q = try qs.create(courseId: course.id, spec: spec())
        #expect(try qs.detail(q.id).question.readiness == .verified)
        try qs.edit(questionId: q.id, spec: spec("Changed", answer: 15))   // contradicts expression
        #expect(try qs.detail(q.id).question.readiness == .needsReview)
        try qs.markVerified(q.id)
        let d = try qs.detail(q.id)
        #expect(d.question.readiness == .verified && d.question.verificationSource == .user)
    }

    @Test func invalidSpecIsRejected() throws {
        var s = spec(); s.title = ""
        #expect(throws: QuestionError.self) { try qs.create(courseId: course.id, spec: s) }
        #expect(try db.read { try Question.fetchCount($0) } == 0)
    }

    @Test func searchFilterSortAndSavedViews() throws {
        let a = try qs.create(courseId: course.id, spec: spec("Alpha iterators"), skillIds: [skill.id])
        var s2 = QuestionValidator.validate(entry: Fx.all[0], index: 0).question!.spec; s2.title = "Zeta flashcard"; s2.difficulty = 5
        let z = try qs.create(courseId: course.id, spec: s2)
        var f = QuestionFilter()
        f.text = "iterators"; #expect(try qs.list(f).map(\.id) == [a.id])
        f = QuestionFilter(); f.text = "100%"; #expect(try qs.list(f).isEmpty) // LIKE wildcards are escaped
        f = QuestionFilter(); f.type = .flashcard; #expect(try qs.list(f).map(\.id) == [z.id])
        f = QuestionFilter(); f.skillId = skill.id; #expect(try qs.list(f).map(\.id) == [a.id])
        f = QuestionFilter(); f.minDifficulty = 4; #expect(try qs.list(f).map(\.id) == [z.id])
        f = QuestionFilter(); f.readiness = .verified; #expect(try qs.list(f).map(\.id) == [a.id])
        f = QuestionFilter(); f.sort = .title; #expect(try qs.list(f).map(\.title) == ["Alpha iterators", "Zeta flashcard"])
        try qs.setArchived([a.id], archived: true)
        #expect(try qs.list().map(\.id) == [z.id])
        f = QuestionFilter(); f.includeArchived = true; #expect(try qs.list(f).count == 2)
        f = QuestionFilter(); f.type = .numeric; f.includeArchived = true
        try qs.saveView(name: "Numeric", filter: f)
        let v = try qs.savedViews()[0]
        #expect(QuestionService.filter(from: v) == f)
    }

    @Test func duplicateJoinsFamilyAndBulkSkillTags() throws {
        let q = try qs.create(courseId: course.id, spec: spec(), skillIds: [skill.id])
        let copy = try qs.duplicate(q.id)
        let a = try qs.detail(q.id).question, b = try qs.detail(copy.id).question
        #expect(a.familyId != nil && a.familyId == b.familyId)
        #expect(try qs.detail(copy.id).spec.title == "Iterator basics (copy)")
        let s2 = try courses.addSkill(courseId: course.id, name: "Generics").skill
        try qs.setSkills(questionIds: [q.id, copy.id], skillIds: [s2.id])
        #expect(try qs.detail(q.id).skills.map(\.name) == ["Generics"])
        #expect(try qs.detail(copy.id).skills.map(\.name) == ["Generics"])
    }
}

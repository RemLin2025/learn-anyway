import Testing
import Foundation
import GRDB
@testable import BraincellCore

@Suite struct CourseTests {
    let db: AppDatabase
    let svc: CourseService
    init() throws { db = try AppDatabase.inMemory(); svc = CourseService(db: db) }

    /// Acceptance scenario: COMP 211 with Midterm 2, later Midterm 1 and a cumulative Final.
    @Test func comp211MultiAssessment() throws {
        let course = try svc.createCourse(name: "COMP 211")
        let m2 = try svc.addAssessment(courseId: course.id, name: "Midterm 2")
        let (iter, _) = try svc.addSkill(courseId: course.id, name: "Java iterators")
        let (gen, _) = try svc.addSkill(courseId: course.id, name: "Generics", parentId: iter.id)
        try svc.addToScope(assessmentId: m2.id, skillId: iter.id, importance: 0.8, source: .userAdjusted)
        try svc.addToScope(assessmentId: m2.id, skillId: gen.id)

        // Later: Midterm 1 reuses "java  ITERATORS" (same skill, no duplicate) plus a new skill.
        let m1 = try svc.addAssessment(courseId: course.id, name: "Midterm 1")
        let again = try svc.addSkill(courseId: course.id, name: "  java   ITERATORS ")
        #expect(again.created == false)
        #expect(again.skill.id == iter.id)
        let (arr, created) = try svc.addSkill(courseId: course.id, name: "Arrays")
        #expect(created)
        try svc.addToScope(assessmentId: m1.id, skillId: iter.id)
        try svc.addToScope(assessmentId: m1.id, skillId: arr.id)

        let final = try svc.addAssessment(courseId: course.id, name: "Final", kind: .final, isCumulative: true)
        #expect(try svc.skills(courseId: course.id).count == 3)
        #expect(Set(try svc.scopedSkills(assessmentId: final.id).map(\.id)) == [iter.id, gen.id, arr.id])
        #expect(Set(try svc.scopedSkills(assessmentId: m2.id).map(\.id)) == [iter.id, gen.id])
        #expect(try svc.assessments(courseId: course.id).map(\.name) == ["Midterm 2", "Midterm 1", "Final"])

        // A skill added after the final exists is automatically in the cumulative scope.
        let (late, _) = try svc.addSkill(courseId: course.id, name: "Recursion")
        #expect(try svc.scopedSkills(assessmentId: final.id).contains { $0.id == late.id })
    }

    @Test func sameNamedSkillsAcrossCoursesAreNotMerged() throws {
        let a = try svc.createCourse(name: "COMP 211")
        let b = try svc.createCourse(name: "COMP 301")
        let sa = try svc.addSkill(courseId: a.id, name: "Recursion")
        let sb = try svc.addSkill(courseId: b.id, name: "Recursion")
        #expect(sb.created)
        #expect(sa.skill.id != sb.skill.id)
        try svc.addRelation(from: sa.skill.id, to: sb.skill.id, kind: .related) // explicit link works
    }

    @Test func scopeRejectsForeignSkill() throws {
        let a = try svc.createCourse(name: "A"), b = try svc.createCourse(name: "B")
        let m = try svc.addAssessment(courseId: a.id, name: "M")
        let s = try svc.addSkill(courseId: b.id, name: "X").skill
        #expect(throws: CourseError.skillNotInCourse) { try svc.addToScope(assessmentId: m.id, skillId: s.id) }
    }

    @Test func relationsRejectCyclesAndAreIdempotent() throws {
        let c = try svc.createCourse(name: "C")
        let a = try svc.addSkill(courseId: c.id, name: "A").skill
        let b = try svc.addSkill(courseId: c.id, name: "B", parentId: a.id).skill
        let d = try svc.addSkill(courseId: c.id, name: "D", parentId: b.id).skill
        #expect(throws: CourseError.wouldCreateCycle) { try svc.addRelation(from: d.id, to: a.id, kind: .hierarchy) }
        #expect(throws: CourseError.wouldCreateCycle) { try svc.addRelation(from: a.id, to: a.id, kind: .prerequisite) }
        // Hierarchy and prerequisite are independent graphs.
        try svc.addRelation(from: d.id, to: a.id, kind: .prerequisite)
        try svc.addRelation(from: d.id, to: a.id, kind: .prerequisite)
        #expect(try svc.relations(courseId: c.id).count == 3)
    }

    @Test func quickCramConvertsWithoutLosingWork() throws {
        let qc = try svc.startQuickCram(topic: "Java iterators")
        #expect(qc.kind == .quickCram)
        let skills = try svc.skills(courseId: qc.id)
        #expect(skills.map(\.name) == ["Java iterators"])
        try svc.convertToCourse(qc.id, name: "COMP 211")
        let after = try svc.courses().first { $0.id == qc.id }
        #expect(after?.kind == .structured)
        #expect(after?.name == "COMP 211")
        #expect(try svc.skills(courseId: qc.id).map(\.id) == skills.map(\.id)) // same skill rows
        #expect(throws: CourseError.notQuickCram) { try svc.convertToCourse(qc.id, name: "x") }
    }

    @Test func validationAndArchive() throws {
        #expect(throws: CourseError.emptyName) { try svc.createCourse(name: "   ") }
        let c = try svc.createCourse(name: "C")
        let s = try svc.addSkill(courseId: c.id, name: "Old").skill
        try svc.renameSkill(s.id, to: "New")
        #expect(try svc.skills(courseId: c.id).map(\.name) == ["New"])
        try svc.archiveSkill(s.id)
        #expect(try svc.skills(courseId: c.id).isEmpty)
        try svc.archiveCourse(c.id)
        #expect(try svc.courses().isEmpty)
    }
}

@Suite struct SkillTreeTests {
    @Test func flattensWithDepth() throws {
        let db = try AppDatabase.inMemory(); let svc = CourseService(db: db)
        let c = try svc.createCourse(name: "C")
        let root = try svc.addSkill(courseId: c.id, name: "Java").skill
        let it = try svc.addSkill(courseId: c.id, name: "Iterators", parentId: root.id).skill
        _ = try svc.addSkill(courseId: c.id, name: "Generic iterators", parentId: it.id)
        _ = try svc.addSkill(courseId: c.id, name: "Arrays")
        let rows = SkillTree.flatten(try svc.skills(courseId: c.id), relations: try svc.relations(courseId: c.id))
        #expect(rows.map(\.skill.name) == ["Arrays", "Java", "Iterators", "Generic iterators"])
        #expect(rows.map(\.depth) == [0, 0, 1, 2])
    }
}

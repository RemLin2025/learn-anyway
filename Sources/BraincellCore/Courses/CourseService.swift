import Foundation
import GRDB

public enum CourseError: Error, Equatable, LocalizedError {
    case emptyName
    case nameTooLong
    case notFound
    case skillNotInCourse
    case wouldCreateCycle
    case notQuickCram

    public var errorDescription: String? {
        switch self {
        case .emptyName: "A name is required."
        case .nameTooLong: "That name is too long."
        case .notFound: "That item no longer exists."
        case .skillNotInCourse: "That skill does not belong to this course."
        case .wouldCreateCycle: "That link would create a cycle between skills."
        case .notQuickCram: "Only Quick Cram workspaces can be converted."
        }
    }
}

public extension String {
    /// Case-, diacritic- and whitespace-insensitive key used to detect the same skill within one course.
    var skillKey: String {
        folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}

/// Courses, assessments, skills and their relationships.
/// Skills are only reused within one course automatically; cross-course links are explicit (`.related`).
public struct CourseService: Sendable {
    let db: AppDatabase
    public init(db: AppDatabase) { self.db = db }

    static func clean(_ name: String) throws -> String {
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !n.isEmpty else { throw CourseError.emptyName }
        guard n.count <= 200 else { throw CourseError.nameTooLong }
        return n
    }

    // MARK: Courses

    @discardableResult
    public func createCourse(name: String) throws -> Course {
        let c = Course(id: UUID(), name: try Self.clean(name), kind: .structured, createdAt: Date(), archivedAt: nil)
        try db.write { try c.insert($0) }
        return c
    }

    /// Minimal-setup entry: a draft course named after the topic, with that topic as its first skill.
    @discardableResult
    public func startQuickCram(topic: String) throws -> Course {
        let name = try Self.clean(topic)
        let c = Course(id: UUID(), name: name, kind: .quickCram, createdAt: Date(), archivedAt: nil)
        try db.write { d in
            try c.insert(d)
            _ = try Self.addSkill(d, courseId: c.id, name: name, parentId: nil)
        }
        return c
    }

    /// Keeps the same course row, so questions, attempts and XP that reference it are untouched.
    public func convertToCourse(_ id: UUID, name: String) throws {
        let n = try Self.clean(name)
        try db.write { d in
            guard var c = try Course.fetchOne(d, key: id) else { throw CourseError.notFound }
            guard c.kind == .quickCram else { throw CourseError.notQuickCram }
            c.kind = .structured
            c.name = n
            try c.update(d)
        }
    }

    public func renameCourse(_ id: UUID, to name: String) throws {
        let n = try Self.clean(name)
        try db.write { d in
            guard var c = try Course.fetchOne(d, key: id) else { throw CourseError.notFound }
            c.name = n
            try c.update(d)
        }
    }

    public func courses(includeArchived: Bool = false) throws -> [Course] {
        try db.read { d in
            var q = Course.order(Column("createdAt").desc)
            if !includeArchived { q = q.filter(Column("archivedAt") == nil) }
            return try q.fetchAll(d)
        }
    }

    public func archiveCourse(_ id: UUID) throws {
        try db.write { d in
            guard var c = try Course.fetchOne(d, key: id) else { throw CourseError.notFound }
            c.archivedAt = Date()
            try c.update(d)
        }
    }

    // MARK: Assessments

    @discardableResult
    public func addAssessment(courseId: UUID, name: String, kind: AssessmentKind = .midterm,
                              deadline: Date? = nil, isCumulative: Bool = false) throws -> Assessment {
        let n = try Self.clean(name)
        return try db.write { d in
            guard try Course.exists(d, key: courseId) else { throw CourseError.notFound }
            let next = try Int.fetchOne(d, sql: "SELECT COALESCE(MAX(sortOrder), -1) + 1 FROM assessments WHERE courseId = ?",
                                        arguments: [courseId]) ?? 0
            let a = Assessment(id: UUID(), courseId: courseId, name: n, kind: kind, deadline: deadline,
                               isCumulative: isCumulative, importance: nil, importanceSource: .unset,
                               sortOrder: next, createdAt: Date())
            try a.insert(d)
            return a
        }
    }

    public func updateAssessment(_ a: Assessment) throws {
        var a = a
        a.name = try Self.clean(a.name)
        try db.write { try a.update($0) }
    }

    public func deleteAssessment(_ id: UUID) throws {
        _ = try db.write { try Assessment.deleteOne($0, key: id) }
    }

    public func assessments(courseId: UUID) throws -> [Assessment] {
        try db.read { try Assessment.filter(Column("courseId") == courseId).order(Column("sortOrder")).fetchAll($0) }
    }

    // MARK: Skills

    /// Reuses an existing skill of the same course whose name matches (case/space/diacritic-insensitive).
    /// Never matches across courses.
    @discardableResult
    public func addSkill(courseId: UUID, name: String, parentId: UUID? = nil) throws -> (skill: Skill, created: Bool) {
        try db.write { try Self.addSkill($0, courseId: courseId, name: name, parentId: parentId) }
    }

    static func addSkill(_ d: Database, courseId: UUID, name: String, parentId: UUID?) throws -> (skill: Skill, created: Bool) {
        let n = try clean(name)
        guard try Course.exists(d, key: courseId) else { throw CourseError.notFound }
        let key = n.skillKey
        let existing = try Skill.fetchOne(d, sql: """
            SELECT skills.* FROM skills JOIN course_skills ON course_skills.skillId = skills.id
            WHERE course_skills.courseId = ? AND skills.normalizedName = ? AND skills.archivedAt IS NULL
            """, arguments: [courseId, key])
        let skill: Skill
        let created: Bool
        if let existing { skill = existing; created = false } else {
            skill = Skill(id: UUID(), name: n, normalizedName: key, summary: "", createdAt: Date(), archivedAt: nil)
            try skill.insert(d)
            try CourseSkill(courseId: courseId, skillId: skill.id).insert(d)
            created = true
        }
        if let parentId { try addRelation(d, from: parentId, to: skill.id, kind: .hierarchy) }
        return (skill, created)
    }

    public func renameSkill(_ id: UUID, to name: String) throws {
        let n = try Self.clean(name)
        try db.write { d in
            guard var s = try Skill.fetchOne(d, key: id) else { throw CourseError.notFound }
            s.name = n
            s.normalizedName = n.skillKey
            try s.update(d)
        }
    }

    /// Archived skills keep their history (evidence, XP) but disappear from lists and scopes.
    public func archiveSkill(_ id: UUID) throws {
        try db.write { d in
            guard var s = try Skill.fetchOne(d, key: id) else { throw CourseError.notFound }
            s.archivedAt = Date()
            try s.update(d)
        }
    }

    public func skills(courseId: UUID) throws -> [Skill] {
        try db.read { d in
            try Skill.fetchAll(d, sql: """
                SELECT skills.* FROM skills JOIN course_skills ON course_skills.skillId = skills.id
                WHERE course_skills.courseId = ? AND skills.archivedAt IS NULL ORDER BY skills.name COLLATE NOCASE
                """, arguments: [courseId])
        }
    }

    // MARK: Relations

    public func addRelation(from: UUID, to: UUID, kind: SkillRelationKind) throws {
        try db.write { try Self.addRelation($0, from: from, to: to, kind: kind) }
    }

    static func addRelation(_ d: Database, from: UUID, to: UUID, kind: SkillRelationKind) throws {
        guard from != to else { throw CourseError.wouldCreateCycle }
        if try SkillRelation.filter(Column("fromSkillId") == from && Column("toSkillId") == to && Column("kind") == kind).fetchCount(d) > 0 {
            return // idempotent
        }
        if kind != .related {
            // Adding from→to creates a cycle iff `from` is already reachable from `to`.
            var seen: Set<UUID> = [], stack = [to]
            while let cur = stack.popLast() {
                if cur == from { throw CourseError.wouldCreateCycle }
                guard seen.insert(cur).inserted else { continue }
                stack += try UUID.fetchAll(d, sql: "SELECT toSkillId FROM skill_relations WHERE fromSkillId = ? AND kind = ?",
                                           arguments: [cur, kind])
            }
        }
        try SkillRelation(id: UUID(), fromSkillId: from, toSkillId: to, kind: kind).insert(d)
    }

    public func removeRelation(_ id: UUID) throws {
        _ = try db.write { try SkillRelation.deleteOne($0, key: id) }
    }

    public func relations(courseId: UUID) throws -> [SkillRelation] {
        try db.read { d in
            try SkillRelation.fetchAll(d, sql: """
                SELECT r.* FROM skill_relations r
                WHERE r.fromSkillId IN (SELECT skillId FROM course_skills WHERE courseId = ?)
                  AND r.toSkillId IN (SELECT skillId FROM course_skills WHERE courseId = ?)
                """, arguments: [courseId, courseId])
        }
    }

    // MARK: Assessment scope

    public func addToScope(assessmentId: UUID, skillId: UUID, importance: Double? = nil,
                           source: ImportanceSource = .unset) throws {
        try db.write { d in
            guard let a = try Assessment.fetchOne(d, key: assessmentId) else { throw CourseError.notFound }
            guard try CourseSkill.exists(d, key: ["courseId": a.courseId, "skillId": skillId]) else {
                throw CourseError.skillNotInCourse
            }
            try AssessmentSkill(assessmentId: assessmentId, skillId: skillId, importance: importance,
                                importanceSource: source).save(d)
        }
    }

    public func removeFromScope(assessmentId: UUID, skillId: UUID) throws {
        _ = try db.write { try AssessmentSkill.deleteOne($0, key: ["assessmentId": assessmentId, "skillId": skillId]) }
    }

    /// Skills an assessment covers. Cumulative assessments cover the whole course.
    public func scopedSkills(assessmentId: UUID) throws -> [Skill] {
        try db.read { d in
            guard let a = try Assessment.fetchOne(d, key: assessmentId) else { throw CourseError.notFound }
            if a.isCumulative {
                return try Skill.fetchAll(d, sql: """
                    SELECT skills.* FROM skills JOIN course_skills ON course_skills.skillId = skills.id
                    WHERE course_skills.courseId = ? AND skills.archivedAt IS NULL ORDER BY skills.name COLLATE NOCASE
                    """, arguments: [a.courseId])
            }
            return try Skill.fetchAll(d, sql: """
                SELECT skills.* FROM skills JOIN assessment_skills ON assessment_skills.skillId = skills.id
                WHERE assessment_skills.assessmentId = ? AND skills.archivedAt IS NULL ORDER BY skills.name COLLATE NOCASE
                """, arguments: [assessmentId])
        }
    }
}

import Foundation
import GRDB

public enum QuestionError: Error, LocalizedError, Equatable {
    case invalid([ValidationIssue])
    case notFound
    case wrongCourse
    case revisionImmutable

    public var errorDescription: String? {
        switch self {
        case .invalid(let i): "The question isn’t valid: " + i.filter { $0.severity == .blocking }.map(\.description).joined(separator: "; ")
        case .notFound: "That question no longer exists."
        case .wrongCourse: "The skill or assessment belongs to a different course."
        case .revisionImmutable: "Revisions can’t be changed; edit the question to create a new one."
        }
    }
}

public struct QuestionFilter: Codable, Sendable, Equatable {
    public enum Sort: String, Codable, Sendable, CaseIterable { case newest, title, difficulty }
    public var text = ""
    public var courseId: UUID?
    public var assessmentId: UUID?
    public var skillId: UUID?
    public var type: QuestionType?
    public var minDifficulty: Int?
    public var maxDifficulty: Int?
    public var readiness: Readiness?
    public var includeArchived = false
    public var sort: Sort = .newest
    public init() {}
}

public struct QuestionRow: Sendable, Identifiable, Hashable {
    public var question: Question
    public var title: String
    public var difficulty: Int
    public var id: UUID { question.id }
}

public struct QuestionDetail: Sendable {
    public var question: Question
    public var revision: QuestionRevision
    public var spec: QuestionSpec
    public var skills: [Skill]
    public var assessments: [Assessment]
}

public struct QuestionService: Sendable {
    let db: AppDatabase
    public init(db: AppDatabase) { self.db = db }

    // MARK: Create / edit

    @discardableResult
    public func create(courseId: UUID, spec: QuestionSpec, skillIds: [UUID] = [], assessmentIds: [UUID] = [],
                       origin: RevisionOrigin = .manual) throws -> Question {
        let r = QuestionValidator.validate(spec: spec)
        guard !r.hasBlocking, let clean = r.question?.spec else { throw QuestionError.invalid(r.issues) }
        return try db.write {
            try Self.insert($0, courseId: courseId, spec: clean, validation: r, skillIds: skillIds, assessmentIds: assessmentIds,
                            origin: origin, aiImportId: nil, familyId: nil, extraNotes: [])
        }
    }

    /// Creates the question and its first revision. Used by manual creation and by the AI importer (inside its transaction).
    static func insert(_ d: Database, courseId: UUID, spec: QuestionSpec, validation: ValidationResult, skillIds: [UUID],
                       assessmentIds: [UUID], origin: RevisionOrigin, aiImportId: UUID?, familyId: UUID?,
                       extraNotes: [String]) throws -> Question {
        guard try Course.exists(d, key: courseId) else { throw CourseError.notFound }
        let notes = validation.issues.filter { $0.severeEnoughForNotes }.map(\.description) + extraNotes
        let readiness: Readiness = notes.isEmpty ? (validation.computedVerification ? .verified : .unverified) : .needsReview
        let revId = UUID()
        let q = Question(id: UUID(), courseId: courseId, familyId: familyId, currentRevisionId: revId, type: spec.type,
                         readiness: readiness, verificationSource: validation.computedVerification && notes.isEmpty ? .computed : .none,
                         reviewNotes: encodeNotes(notes), archivedAt: nil, createdAt: Date())
        try q.insert(d)
        try makeRevision(d, id: revId, questionId: q.id, number: 1, spec: spec, origin: origin, aiImportId: aiImportId).insert(d)
        for s in skillIds { try link(d, questionId: q.id, courseId: courseId, skillId: s) }
        for a in assessmentIds { try linkAssessment(d, questionId: q.id, courseId: courseId, assessmentId: a) }
        return q
    }

    static func makeRevision(_ d: Database, id: UUID, questionId: UUID, number: Int, spec: QuestionSpec,
                             origin: RevisionOrigin, aiImportId: UUID?) throws -> QuestionRevision {
        let payload = String(data: try JSONEncoder().encode(spec), encoding: .utf8) ?? "{}"
        return QuestionRevision(id: id, questionId: questionId, number: number, title: spec.title, difficulty: spec.difficulty,
                                learningObjective: spec.learningObjective, payload: payload,
                                contentHash: QuestionHashing.contentHash(spec), origin: origin, aiImportId: aiImportId, createdAt: Date())
    }

    static func encodeNotes(_ n: [String]) -> String {
        (try? JSONEncoder().encode(n)).flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
    }

    /// Editing never mutates a revision: it appends a new one and re-validates. Verification resets,
    /// because a verified answer may no longer be correct.
    @discardableResult
    public func edit(questionId: UUID, spec: QuestionSpec) throws -> QuestionRevision {
        let r = QuestionValidator.validate(spec: spec)
        guard !r.hasBlocking, let clean = r.question?.spec else { throw QuestionError.invalid(r.issues) }
        return try db.write { d in
            guard var q = try Question.fetchOne(d, key: questionId) else { throw QuestionError.notFound }
            let next = (try Int.fetchOne(d, sql: "SELECT MAX(number) FROM question_revisions WHERE questionId = ?", arguments: [questionId]) ?? 0) + 1
            let rev = try Self.makeRevision(d, id: UUID(), questionId: questionId, number: next, spec: clean, origin: .edit, aiImportId: nil)
            try rev.insert(d)
            let notes = r.issues.filter { $0.severeEnoughForNotes }.map(\.description)
            q.currentRevisionId = rev.id
            q.type = clean.type
            q.readiness = notes.isEmpty ? (r.computedVerification ? .verified : .unverified) : .needsReview
            q.verificationSource = r.computedVerification && notes.isEmpty ? .computed : .none
            q.reviewNotes = Self.encodeNotes(notes)
            try q.update(d)
            return rev
        }
    }

    /// The user vouches for the answer. Recorded as a distinct verification source.
    public func markVerified(_ id: UUID) throws {
        try db.write { d in
            guard var q = try Question.fetchOne(d, key: id) else { throw QuestionError.notFound }
            q.readiness = .verified; q.verificationSource = .user
            try q.update(d)
        }
    }

    @discardableResult
    public func duplicate(_ id: UUID) throws -> Question {
        try db.write { d in
            guard var src = try Question.fetchOne(d, key: id), let rev = try QuestionRevision.fetchOne(d, key: src.currentRevisionId),
                  var spec = rev.spec else { throw QuestionError.notFound }
            if src.familyId == nil { // duplicates are variants of one another
                let f = QuestionFamily(id: UUID(), title: spec.title, createdAt: Date())
                try f.insert(d); src.familyId = f.id; try src.update(d)
            }
            spec.title += " (copy)"
            let v = QuestionValidator.validate(spec: spec)
            let copy = try Self.insert(d, courseId: src.courseId, spec: spec, validation: v,
                                       skillIds: try UUID.fetchAll(d, sql: "SELECT skillId FROM question_skills WHERE questionId = ?", arguments: [id]),
                                       assessmentIds: try UUID.fetchAll(d, sql: "SELECT assessmentId FROM question_assessments WHERE questionId = ?", arguments: [id]),
                                       origin: .duplicate, aiImportId: nil, familyId: src.familyId, extraNotes: [])
            return copy
        }
    }

    // MARK: Tags and scope

    static func link(_ d: Database, questionId: UUID, courseId: UUID, skillId: UUID) throws {
        guard try CourseSkill.exists(d, key: ["courseId": courseId, "skillId": skillId]) else { throw QuestionError.wrongCourse }
        try QuestionSkill(questionId: questionId, skillId: skillId).save(d)
    }

    static func linkAssessment(_ d: Database, questionId: UUID, courseId: UUID, assessmentId: UUID) throws {
        guard let a = try Assessment.fetchOne(d, key: assessmentId), a.courseId == courseId else { throw QuestionError.wrongCourse }
        try QuestionAssessment(questionId: questionId, assessmentId: assessmentId).save(d)
    }

    /// Replaces the skill tags of each question.
    public func setSkills(questionIds: [UUID], skillIds: [UUID]) throws {
        try db.write { d in
            for qid in questionIds {
                guard let q = try Question.fetchOne(d, key: qid) else { throw QuestionError.notFound }
                try d.execute(sql: "DELETE FROM question_skills WHERE questionId = ?", arguments: [qid])
                for s in skillIds { try Self.link(d, questionId: qid, courseId: q.courseId, skillId: s) }
            }
        }
    }

    /// One question row can serve many assessments; this only adds a link.
    public func addToAssessment(questionIds: [UUID], assessmentId: UUID) throws {
        try db.write { d in
            for qid in questionIds {
                guard let q = try Question.fetchOne(d, key: qid) else { throw QuestionError.notFound }
                try Self.linkAssessment(d, questionId: qid, courseId: q.courseId, assessmentId: assessmentId)
            }
        }
    }

    public func removeFromAssessment(questionIds: [UUID], assessmentId: UUID) throws {
        try db.write { d in
            for qid in questionIds {
                _ = try QuestionAssessment.deleteOne(d, key: ["questionId": qid, "assessmentId": assessmentId])
            }
        }
    }

    public func setArchived(_ ids: [UUID], archived: Bool) throws {
        try db.write { d in
            for id in ids {
                guard var q = try Question.fetchOne(d, key: id) else { throw QuestionError.notFound }
                q.archivedAt = archived ? Date() : nil
                try q.update(d)
            }
        }
    }

    // MARK: Reading

    public func detail(_ id: UUID) throws -> QuestionDetail {
        try db.read { d in
            guard let q = try Question.fetchOne(d, key: id), let rev = try QuestionRevision.fetchOne(d, key: q.currentRevisionId),
                  let spec = rev.spec else { throw QuestionError.notFound }
            let skills = try Skill.fetchAll(d, sql: "SELECT s.* FROM skills s JOIN question_skills qs ON qs.skillId = s.id WHERE qs.questionId = ? ORDER BY s.name COLLATE NOCASE", arguments: [id])
            let asm = try Assessment.fetchAll(d, sql: "SELECT a.* FROM assessments a JOIN question_assessments qa ON qa.assessmentId = a.id WHERE qa.questionId = ? ORDER BY a.sortOrder", arguments: [id])
            return QuestionDetail(question: q, revision: rev, spec: spec, skills: skills, assessments: asm)
        }
    }

    public func revisions(_ questionId: UUID) throws -> [QuestionRevision] {
        try db.read { try QuestionRevision.filter(Column("questionId") == questionId).order(Column("number")).fetchAll($0) }
    }

    public func list(_ f: QuestionFilter = QuestionFilter()) throws -> [QuestionRow] {
        var sql = "SELECT q.*, r.title AS rTitle, r.difficulty AS rDifficulty FROM questions q JOIN question_revisions r ON r.id = q.currentRevisionId WHERE 1=1"
        var args: [DatabaseValueConvertible] = []
        if !f.includeArchived { sql += " AND q.archivedAt IS NULL" }
        if let c = f.courseId { sql += " AND q.courseId = ?"; args.append(c) }
        if let a = f.assessmentId { sql += " AND q.id IN (SELECT questionId FROM question_assessments WHERE assessmentId = ?)"; args.append(a) }
        if let s = f.skillId { sql += " AND q.id IN (SELECT questionId FROM question_skills WHERE skillId = ?)"; args.append(s) }
        if let t = f.type { sql += " AND q.type = ?"; args.append(t) }
        if let r = f.readiness { sql += " AND q.readiness = ?"; args.append(r) }
        if let lo = f.minDifficulty { sql += " AND r.difficulty >= ?"; args.append(lo) }
        if let hi = f.maxDifficulty { sql += " AND r.difficulty <= ?"; args.append(hi) }
        let text = f.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty {
            let esc = text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "%", with: "\\%").replacingOccurrences(of: "_", with: "\\_")
            sql += " AND (r.title LIKE ? ESCAPE '\\' OR r.payload LIKE ? ESCAPE '\\')"
            args += ["%\(esc)%", "%\(esc)%"]
        }
        switch f.sort {
        case .newest: sql += " ORDER BY q.createdAt DESC"
        case .title: sql += " ORDER BY r.title COLLATE NOCASE"
        case .difficulty: sql += " ORDER BY r.difficulty, r.title COLLATE NOCASE"
        }
        return try db.read { d in
            try Row.fetchAll(d, sql: sql, arguments: StatementArguments(args)).map { row in
                QuestionRow(question: try Question(row: row), title: row["rTitle"], difficulty: row["rDifficulty"])
            }
        }
    }

    // MARK: Saved views

    public func saveView(name: String, filter: QuestionFilter) throws {
        let n = try CourseService.clean(name)
        let json = String(data: try JSONEncoder().encode(filter), encoding: .utf8) ?? "{}"
        try db.write { try SavedView(id: UUID(), name: n, filterJSON: json, createdAt: Date()).insert($0) }
    }

    public func savedViews() throws -> [SavedView] {
        try db.read { try SavedView.order(Column("createdAt")).fetchAll($0) }
    }

    public func deleteView(_ id: UUID) throws { _ = try db.write { try SavedView.deleteOne($0, key: id) } }

    public static func filter(from view: SavedView) -> QuestionFilter {
        (try? JSONDecoder().decode(QuestionFilter.self, from: Data(view.filterJSON.utf8))) ?? QuestionFilter()
    }
}

extension ValidationIssue {
    /// Review-severity issues become reasons shown on the question.
    var severeEnoughForNotes: Bool { severity == .review }
}

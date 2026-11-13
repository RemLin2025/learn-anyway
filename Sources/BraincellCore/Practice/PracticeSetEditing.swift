import Foundation
import GRDB

public enum PracticeSetError: Error, LocalizedError, Equatable {
    case alreadyInSet, questionNotFound, setNotFound, emptyTitle
    public var errorDescription: String? {
        switch self {
        case .alreadyInSet: "That question is already in this set."
        case .questionNotFound: "That question no longer exists."
        case .setNotFound: "That practice set no longer exists."
        case .emptyTitle: "A practice set needs a name."
        }
    }
}

/// Where a set stands, from real saved attempts only: nothing here is estimated.
public struct SetProgress: Equatable, Sendable {
    public enum State: String, Sendable { case notStarted, inProgress, completed }
    public var state: State
    public var answered: Int
    public var total: Int
    public var sessionId: UUID?
    public var templateId: String?
    public var lastActivity: Date?
    /// The set was edited after this attempt began. The attempt keeps the questions it started with; a new attempt uses the current ones.
    public var stale: Bool
    public static let none = SetProgress(state: .notStarted, answered: 0, total: 0, sessionId: nil, templateId: nil, lastActivity: nil, stale: false)
}

/// Editing a practice set changes only the set's membership and settings. Study sessions (attempts) hold their own question and revision references, so
/// completed and in-progress attempts are never rewritten; every edit bumps `revision` so a stale attempt can be told apart.
extension PracticeSetService {
    func touch(_ d: Database, _ setId: UUID) throws {
        try d.execute(sql: "UPDATE practice_sets SET revision = revision + 1, updatedAt = ? WHERE id = ?", arguments: [Date(), setId])
    }

    /// A set with no questions yet, for building one by hand from the Library. No model is involved.
    @discardableResult
    public func createEmpty(courseId: UUID, assessmentId: UUID? = nil, title: String, templateId: String? = nil) throws -> PracticeSet {
        let n = title.trimmingCharacters(in: .whitespacesAndNewlines); guard !n.isEmpty else { throw PracticeSetError.emptyTitle }
        let id = UUID(), now = Date()
        let params = String(data: (try? JSONEncoder().encode(GenerationParams(count: 0))) ?? Data("{}".utf8), encoding: .utf8) ?? "{}"
        return try db.write { d in
            try d.execute(sql: "INSERT INTO practice_sets (id, courseId, assessmentId, title, requestKey, paramsJSON, fresh, taskId, createdAt, templateId, revision, updatedAt) VALUES (?,?,?,?,?,?,?,?,?,?,?,?)",
                          arguments: [id, courseId, assessmentId, String(n.prefix(200)), "manual-" + id.uuidString, params, false, nil as UUID?, now, templateId, 1, now])
            return Self.set(try Row.fetchOne(d, sql: "SELECT * FROM practice_sets WHERE id = ?", arguments: [id])!)
        }
    }

    public func update(setId: UUID, title: String? = nil, description: String? = nil, templateId: String? = nil) throws {
        try db.write { d in
            guard try Bool.fetchOne(d, sql: "SELECT EXISTS(SELECT 1 FROM practice_sets WHERE id = ?)", arguments: [setId]) == true else { throw PracticeSetError.setNotFound }
            if let t = title { let n = t.trimmingCharacters(in: .whitespacesAndNewlines); guard !n.isEmpty else { throw PracticeSetError.emptyTitle }
                try d.execute(sql: "UPDATE practice_sets SET title = ?, updatedAt = ? WHERE id = ?", arguments: [String(n.prefix(200)), Date(), setId]) }
            if let x = description { try d.execute(sql: "UPDATE practice_sets SET description = ?, updatedAt = ? WHERE id = ?", arguments: [x.trimmingCharacters(in: .whitespacesAndNewlines).prefix(2_000).description, Date(), setId]) }
            if let t = templateId { try d.execute(sql: "UPDATE practice_sets SET templateId = ?, updatedAt = ? WHERE id = ?", arguments: [t, Date(), setId]) }   // presentation only: not a content revision
        }
    }

    /// Adds an existing question by reference (any course). A question can be in a set once.
    public func add(questionId: UUID, to setId: UUID) throws {
        try db.write { d in
            guard try Bool.fetchOne(d, sql: "SELECT EXISTS(SELECT 1 FROM practice_sets WHERE id = ? AND deletedAt IS NULL)", arguments: [setId]) == true else { throw PracticeSetError.setNotFound }
            guard let rid = try UUID.fetchOne(d, sql: "SELECT currentRevisionId FROM questions WHERE id = ?", arguments: [questionId]),
                  let spec = try QuestionRevision.fetchOne(d, key: rid)?.spec else { throw PracticeSetError.questionNotFound }
            if try Bool.fetchOne(d, sql: "SELECT EXISTS(SELECT 1 FROM practice_set_items WHERE setId = ? AND questionId = ?)", arguments: [setId, questionId]) == true { throw PracticeSetError.alreadyInSet }
            let pos = (try Int.fetchOne(d, sql: "SELECT MAX(position) FROM practice_set_items WHERE setId = ?", arguments: [setId]) ?? -1) + 1
            let slot = PlanSlot(id: "m-" + UUID().uuidString.prefix(8).lowercased(), topic: spec.title, reasoningSkill: nil, archetype: "manual", difficulty: spec.difficulty, format: spec.type.rawValue, exemplars: [], exemplarSummary: nil, rationale: "Added by you")
            let json = String(data: try JSONEncoder().encode(slot), encoding: .utf8) ?? "{}"
            try d.execute(sql: "INSERT INTO practice_set_items (setId, slotId, position, slotJSON, questionId, origin) VALUES (?,?,?,?,?,?)", arguments: [setId, slot.id, pos, json, questionId, "added"])
            try touch(d, setId)
        }
    }

    public func remove(questionId: UUID, from setId: UUID) throws {
        try db.write { d in
            try d.execute(sql: "DELETE FROM practice_set_items WHERE setId = ? AND questionId = ?", arguments: [setId, questionId])
            let slots = try String.fetchAll(d, sql: "SELECT slotId FROM practice_set_items WHERE setId = ? ORDER BY position", arguments: [setId])
            for (i, s) in slots.enumerated() { try d.execute(sql: "UPDATE practice_set_items SET position = ? WHERE setId = ? AND slotId = ?", arguments: [i, setId, s]) }
            try touch(d, setId)
        }
    }

    /// `order` lists slot ids in the new order; unknown ids are ignored and omitted slots keep their relative order at the end.
    public func reorder(setId: UUID, slotOrder order: [String]) throws {
        try db.write { d in
            let current = try String.fetchAll(d, sql: "SELECT slotId FROM practice_set_items WHERE setId = ? ORDER BY position", arguments: [setId])
            let known = Set(current)
            let final = order.filter(known.contains) + current.filter { !order.contains($0) }
            for (i, s) in final.enumerated() { try d.execute(sql: "UPDATE practice_set_items SET position = ? WHERE setId = ? AND slotId = ?", arguments: [i, setId, s]) }
            try touch(d, setId)
        }
    }

    @discardableResult
    public func duplicate(setId: UUID) throws -> PracticeSet {
        try db.write { d in
            guard let src = try Row.fetchOne(d, sql: "SELECT * FROM practice_sets WHERE id = ?", arguments: [setId]) else { throw PracticeSetError.setNotFound }
            let id = UUID(), now = Date()
            try d.execute(sql: "INSERT INTO practice_sets (id, courseId, assessmentId, title, requestKey, paramsJSON, fresh, taskId, createdAt, description, templateId, revision, updatedAt) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?)",
                          arguments: [id, src["courseId"] as UUID, src["assessmentId"] as UUID?, ((src["title"] as String) + " (copy)"), "dup-" + id.uuidString, src["paramsJSON"] as String, src["fresh"] as Bool, nil as UUID?, now, src["description"] as String?, src["templateId"] as String?, 1, now])
            try d.execute(sql: "INSERT INTO practice_set_items (setId, slotId, position, slotJSON, questionId, origin) SELECT ?, slotId, position, slotJSON, questionId, origin FROM practice_set_items WHERE setId = ?", arguments: [id, setId])
            return Self.set(try Row.fetchOne(d, sql: "SELECT * FROM practice_sets WHERE id = ?", arguments: [id])!)
        }
    }

    /// Removes a set that was only ever a plan (no attempt, never opened by the learner), e.g. the previous plan when the wizard settings change. Not recoverable and not listed
    /// in Recently Deleted, because the learner never saw it as a set. Refuses (returns false) if any attempt exists.
    @discardableResult
    public func discardUnused(setId: UUID) throws -> Bool {
        guard try progress(setId: setId).state == .notStarted else { return false }
        try db.write { try $0.execute(sql: "DELETE FROM practice_sets WHERE id = ?", arguments: [setId]) }
        return true
    }

    /// A set title that doesn't collide with a live set in the course ("Midterm 3 practice", then "Midterm 3 practice (2)").
    public func uniqueTitle(_ base: String, courseId: UUID, excluding setId: UUID? = nil) throws -> String {
        let taken = Set(try sets(courseId: courseId).filter { $0.id != setId }.map(\.title))
        if !taken.contains(base) { return base }
        var n = 2; while taken.contains("\(base) (\(n))") { n += 1 }
        return "\(base) (\(n))"
    }

    /// Soft delete: the set disappears from lists but can be restored; its questions and every past attempt are untouched.
    public func delete(setId: UUID) throws { try db.write { try $0.execute(sql: "UPDATE practice_sets SET deletedAt = ? WHERE id = ?", arguments: [Date(), setId]) } }
    public func restore(setId: UUID) throws { try db.write { try $0.execute(sql: "UPDATE practice_sets SET deletedAt = NULL WHERE id = ?", arguments: [setId]) } }
    public func deletedSets(courseId: UUID? = nil) throws -> [PracticeSet] {
        try db.read { try Row.fetchAll($0, sql: "SELECT * FROM practice_sets WHERE deletedAt IS NOT NULL AND (? IS NULL OR courseId = ?) ORDER BY deletedAt DESC", arguments: [courseId, courseId]).map(Self.set) }
    }

    /// Progress of the most recent attempt (any template), counted from saved session items.
    public func progress(setId: UUID) throws -> SetProgress {
        try db.read { d in
            let rev = try Int.fetchOne(d, sql: "SELECT revision FROM practice_sets WHERE id = ?", arguments: [setId]) ?? 1
            guard let r = try Row.fetchOne(d, sql: "SELECT ps.sessionId, ps.templateId, ps.revision, s.status, s.updatedAt FROM practice_set_sessions ps JOIN study_sessions s ON s.id = ps.sessionId WHERE ps.setId = ? ORDER BY ps.createdAt DESC LIMIT 1", arguments: [setId]) else {
                return SetProgress(state: .notStarted, answered: 0, total: 0, sessionId: nil, templateId: nil, lastActivity: nil, stale: false)
            }
            let sid: UUID = r["sessionId"]
            let total = try Int.fetchOne(d, sql: "SELECT COUNT(*) FROM session_items WHERE sessionId = ?", arguments: [sid]) ?? 0
            let answered = try Int.fetchOne(d, sql: "SELECT COUNT(*) FROM session_items WHERE sessionId = ? AND status = 'submitted'", arguments: [sid]) ?? 0
            let completed = (r["status"] as String) == "completed"
            let state: SetProgress.State = completed ? .completed : (answered > 0 ? .inProgress : .inProgress)
            return SetProgress(state: state, answered: answered, total: total, sessionId: sid, templateId: r["templateId"], lastActivity: r["updatedAt"], stale: (r["revision"] as Int) != rev)
        }
    }
}

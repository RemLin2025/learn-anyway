import Foundation
import GRDB

public struct PracticeSet: Sendable, Equatable, Identifiable {
    public var id: UUID, courseId: UUID
    public var assessmentId: UUID?
    public var title: String
    public var fresh: Bool
    public var taskId: UUID?
    public var createdAt: Date
}

public struct PracticeSetItem: Sendable, Equatable {
    public var slot: PlanSlot
    public var position: Int
    public var questionId: UUID?
    public var origin: String?             // "reused" | "generated"; nil while the slot is still unfilled
}

public struct PreparedSet: Sendable, Equatable { public var set: PracticeSet; public var reused: Int; public var missing: Int; public var alreadyExisted: Bool }
public struct SetGenerationReport: Sendable, Equatable { public var modelCalls: Int; public var filled: Int; public var missing: Int }

public struct VerificationLabel: Sendable, Equatable {
    public enum Level: String, Sendable { case recomputed, structuralOnly, failed }
    public var level: Level
    public var text: String
}

/// Reusable practice sets. A set is an ordered list of slots; each slot is filled either by a compatible question generated earlier or by a new one.
/// Question content, reasoning archetype, set, renderer and attempt are separate: this service only links questions to archetypes and sets.
public final class PracticeSetService: @unchecked Sendable {
    let db: AppDatabase, ai: AITaskService
    public init(db: AppDatabase, ai: AITaskService) { self.db = db; self.ai = ai }

    static func configHash(_ p: GenerationParams, assessmentId: UUID?) -> String {
        let e = JSONEncoder(); e.outputFormatting = [.sortedKeys]
        return QuestionHashing.sha256(String(data: (try? e.encode(p)) ?? Data(), encoding: .utf8)! + "|" + (assessmentId?.uuidString ?? "-"))
    }

    // MARK: Prepare

    /// Plans a set and fills what it can from existing questions. Repeating the same request (same `requestKey`; by default the same configuration)
    /// returns the same set, so retries never duplicate it. `fresh: true` never reuses a question that already sits in any set, and always makes a new set.
    @discardableResult
    public func prepare(courseId: UUID, assessmentId: UUID? = nil, params: GenerationParams, fresh: Bool = false, requestKey: String? = nil) throws -> PreparedSet {
        let key = requestKey ?? (fresh ? UUID().uuidString : Self.configHash(params, assessmentId: assessmentId))
        if let s = try existing(courseId: courseId, key: key) { return try summarize(s, alreadyExisted: true) }
        let scope = try AssessmentService(db: db).scope(courseId: courseId, assessmentId: assessmentId, requested: params.skillIds, tasks: ai)
        var p = params
        if !p.skillIds.isEmpty || !scope.limitations.isEmpty { p.skillIds = scope.skillIds }
        guard (1...200).contains(p.count) else { throw AITaskError.invalidParams("Ask for between 1 and 200 questions.") }
        if p.skillIds.isEmpty { p.skillIds = try db.read { try UUID.fetchAll($0, sql: "SELECT skillId FROM course_skills JOIN skills ON skills.id = skillId WHERE courseId = ? AND archivedAt IS NULL", arguments: [courseId]) } }
        let plan = try ai.makePlan(courseId: courseId, assessmentId: assessmentId, params: p, scope: scope)
        let current = Dictionary(uniqueKeysWithValues: try ArchetypeLibrary(db: db).archetypes(courseId: courseId).map { ($0.key, $0.fingerprint) })
        let title = "Practice set · \(p.count) questions"
        let pjson = String(data: try JSONEncoder().encode(p), encoding: .utf8) ?? "{}"
        let id = UUID()
        let created: Bool = try db.write { d in
            // The unique (course, request key) index makes concurrent identical requests converge on one set.
            if try Int.fetchOne(d, sql: "SELECT COUNT(*) FROM practice_sets WHERE courseId = ? AND requestKey = ?", arguments: [courseId, key]) ?? 0 > 0 { return false }
            try d.execute(sql: "INSERT INTO practice_sets (id, courseId, assessmentId, title, requestKey, paramsJSON, fresh, taskId, createdAt) VALUES (?,?,?,?,?,?,?,NULL,?)", arguments: [id, courseId, assessmentId, title, key, pjson, fresh, Date()])
            var taken = Set<UUID>()
            for (n, slot) in plan.slots.enumerated() {
                let q = try Self.reusable(d, courseId: courseId, slot: slot, params: p, current: current, fresh: fresh, taken: taken)
                if let q { taken.insert(q) }
                try d.execute(sql: "INSERT INTO practice_set_items (setId, slotId, position, slotJSON, questionId, origin) VALUES (?,?,?,?,?,?)",
                               arguments: [id, slot.id, n, String(data: try JSONEncoder().encode(slot), encoding: .utf8) ?? "{}", q, q == nil ? nil : "reused"])
            }
            try Self.saveMissingPlan(d, setId: id, plan: plan, courseId: courseId, assessmentId: assessmentId, params: p)
            return true
        }
        guard let set = try existing(courseId: courseId, key: key) else { throw AITaskError.notFound }
        return try summarize(set, alreadyExisted: !created)
    }

    /// Compatible, current, unflagged questions for a slot, least-used first so repeated requests rotate instead of repeating.
    static func reusable(_ d: Database, courseId: UUID, slot: PlanSlot, params: GenerationParams, current: [String: String], fresh: Bool, taken: Set<UUID>) throws -> UUID? {
        let rows = try Row.fetchAll(d, sql: """
            SELECT l.questionId, l.archetypeKey, l.archetypeFingerprint, l.kind, l.topicKey, l.format, l.difficulty,
                   (SELECT COUNT(*) FROM practice_set_items i WHERE i.questionId = l.questionId) AS uses,
                   (SELECT COUNT(*) FROM attempts a WHERE a.questionId = l.questionId) AS attempts
            FROM question_archetype_links l JOIN questions q ON q.id = l.questionId
            WHERE l.courseId = ? AND q.archivedAt IS NULL
              AND NOT EXISTS (SELECT 1 FROM question_evidence e WHERE e.questionId = l.questionId AND e.result = 'failed')
            ORDER BY uses, attempts, l.createdAt
            """, arguments: [courseId])
        let topic = slot.topic.skillKey
        for r in rows {
            let qid: UUID = r["questionId"]
            if taken.contains(qid) { continue }
            if fresh && ((r["uses"] as Int) > 0 || (r["attempts"] as Int) > 0) { continue }                 // fresh = never served and never attempted
            guard (r["topicKey"] as String) == topic else { continue }
            if let k = slot.archetypeKey {
                guard (r["archetypeKey"] as String?) == k, let fp = r["archetypeFingerprint"] as String?, current[k] == fp else { continue }   // built from an older version of the pattern: not reused
            } else if (r["kind"] as String) != slot.archetype { continue }
            if slot.format != "any", (r["format"] as String) != slot.format { continue }
            if !params.types.isEmpty, !params.types.contains(where: { $0.rawValue == (r["format"] as String) }) { continue }
            let diff: Int = r["difficulty"]
            guard abs(diff - slot.difficulty) <= 1, (params.minDifficulty...params.maxDifficulty).contains(diff) else { continue }
            return qid
        }
        return nil
    }

    /// Creates (once) the generation task for the slots that reuse could not fill. Atomic: a crash leaves either no task or a complete one.
    static func saveMissingPlan(_ d: Database, setId: UUID, plan: GenerationPlan, courseId: UUID, assessmentId: UUID?, params: GenerationParams) throws {
        guard try UUID.fetchOne(d, sql: "SELECT taskId FROM practice_sets WHERE id = ?", arguments: [setId]) == nil else { return }
        let missingIds = Set(try String.fetchAll(d, sql: "SELECT slotId FROM practice_set_items WHERE setId = ? AND questionId IS NULL", arguments: [setId]))
        guard !missingIds.isEmpty else { return }
        var p = params; p.count = missingIds.count
        let task = try AITaskService.insertGenerationTask(d, courseId: courseId, assessmentId: assessmentId, params: p)
        var sub = plan; sub.slots = plan.slots.filter { missingIds.contains($0.id) }                         // original slot ids are kept, so imports map back to the set
        try GenerationPlanStore.save(d, sub, taskId: task.id)
        try d.execute(sql: "UPDATE practice_sets SET taskId = ? WHERE id = ?", arguments: [task.id, setId])
    }

    // MARK: Read / sync

    func existing(courseId: UUID, key: String) throws -> PracticeSet? {
        try db.read { d in try Row.fetchOne(d, sql: "SELECT * FROM practice_sets WHERE courseId = ? AND requestKey = ?", arguments: [courseId, key]).map(Self.set) }
    }
    static func set(_ r: Row) -> PracticeSet { PracticeSet(id: r["id"], courseId: r["courseId"], assessmentId: r["assessmentId"], title: r["title"], fresh: r["fresh"], taskId: r["taskId"], createdAt: r["createdAt"]) }
    public func practiceSet(_ id: UUID) throws -> PracticeSet? { try db.read { try Row.fetchOne($0, sql: "SELECT * FROM practice_sets WHERE id = ?", arguments: [id]).map(Self.set) } }
    public func sets(courseId: UUID) throws -> [PracticeSet] { try db.read { try Row.fetchAll($0, sql: "SELECT * FROM practice_sets WHERE courseId = ? ORDER BY createdAt DESC", arguments: [courseId]).map(Self.set) } }

    public func items(setId: UUID) throws -> [PracticeSetItem] {
        try db.read { d in try Row.fetchAll(d, sql: "SELECT slotJSON, position, questionId, origin FROM practice_set_items WHERE setId = ? ORDER BY position", arguments: [setId]).compactMap { r in
            guard let slot = try? JSONDecoder().decode(PlanSlot.self, from: Data((r["slotJSON"] as String).utf8)) else { return nil }
            return PracticeSetItem(slot: slot, position: r["position"], questionId: r["questionId"], origin: r["origin"])
        } }
    }

    func summarize(_ s: PracticeSet, alreadyExisted: Bool) throws -> PreparedSet {
        let it = try items(setId: s.id)
        return PreparedSet(set: s, reused: it.filter { $0.origin == "reused" }.count, missing: it.filter { $0.questionId == nil }.count, alreadyExisted: alreadyExisted)
    }

    /// Moves questions imported for the set's task into its slots. Idempotent; safe after any partial import, retry or restart.
    @discardableResult
    public func refresh(setId: UUID) throws -> PreparedSet {
        guard let s = try practiceSet(setId) else { throw AITaskError.notFound }
        if let t = s.taskId {
            try db.write { d in
                for r in try Row.fetchAll(d, sql: "SELECT p.slotId, p.questionId FROM question_provenance p JOIN questions q ON q.id = p.questionId WHERE p.planId = ? AND p.slotId IS NOT NULL AND q.archivedAt IS NULL", arguments: [t.uuidString]) {
                    let q: UUID = r["questionId"]
                    if try Int.fetchOne(d, sql: "SELECT COUNT(*) FROM practice_set_items WHERE setId = ? AND questionId = ?", arguments: [setId, q]) ?? 0 > 0 { continue }
                    try d.execute(sql: "UPDATE practice_set_items SET questionId = ?, origin = 'generated' WHERE setId = ? AND slotId = ? AND questionId IS NULL", arguments: [q, setId, r["slotId"] as String])
                }
            }
        }
        return try summarize(s, alreadyExisted: true)
    }

    // MARK: Generate only what is missing

    /// Sends only batches that have not been imported yet, one model call each, then fills the set. Resumable: finished batches are never resent,
    /// a failed or cancelled call leaves everything stored so far. Concurrent calls for one set share one run.
    @discardableResult
    public func generateMissing(setId: UUID, gateway: AIGateway) async throws -> SetGenerationReport {
        try await Self.inflight.join(setId.uuidString) { try await self.run(setId: setId, gateway: gateway) }
    }
    private static let inflight = InFlight<SetGenerationReport>()

    func run(setId: UUID, gateway: AIGateway) async throws -> SetGenerationReport {
        guard let s = try practiceSet(setId) else { throw AITaskError.notFound }
        var calls = 0
        if let t = s.taskId {
            for b in try ai.batches(taskId: t) where b.status == .draft {
                try Task.checkCancellation()
                let still = try ai.batches(taskId: t).first { $0.id == b.id }
                guard still?.status == .draft else { continue }
                let pkg = try ai.prepare(batchId: b.id)
                let out = try await gateway.complete(task: WorkflowTask.find("quizGeneration")!, prompt: pkg.singlePrompt, courseId: s.courseId)
                calls += 1
                _ = try ai.importResponse(out.text, targetBatchId: b.id)
                try refresh(setId: setId)
            }
        }
        // A reply that returned fewer questions than asked is continued once for exactly the unmet slots (existing continuation flow).
        if let t = s.taskId, try refresh(setId: setId).missing > 0, let part = try ai.batches(taskId: t).last(where: { $0.status == .incomplete && $0.kind == .generate }) {
            try Task.checkCancellation()
            let cont = try ai.createContinuationBatch(from: part.id)
            let pkg = try ai.prepare(batchId: cont.id)
            let out = try await gateway.complete(task: WorkflowTask.find("quizGeneration")!, prompt: pkg.singlePrompt, courseId: s.courseId)
            calls += 1
            _ = try ai.importResponse(out.text, targetBatchId: cont.id)
        }
        let r = try refresh(setId: setId)
        return SetGenerationReport(modelCalls: calls, filled: r.set.taskId == nil ? r.reused : r.reused + (try items(setId: setId).filter { $0.origin == "generated" }.count), missing: r.missing)
    }

    // MARK: Honest labels

    /// What has actually been checked for a question. "Recomputed" only when a deterministic check passed; otherwise it is labelled unverified.
    public func verification(questionId: UUID) throws -> VerificationLabel {
        let rows = try db.read { try Row.fetchAll($0, sql: "SELECT kind, result, checkName FROM question_evidence WHERE questionId = ?", arguments: [questionId]) }
        if rows.contains(where: { ($0["result"] as String) == "failed" && ($0["kind"] as String) != "schema" }) { return .init(level: .failed, text: "A verification check failed; review before relying on the answer.") }
        if let r = rows.first(where: { ($0["kind"] as String) == "deterministic" && ($0["result"] as String) == "passed" }) { return .init(level: .recomputed, text: "Answer recomputed by \(r["checkName"] as String).") }
        return .init(level: .structuralOnly, text: "Not independently verified: only the format was checked.")
    }
}

/// Shares one run among concurrent callers; the run is cancelled only when every caller has gone.
final class InFlight<T: Sendable>: @unchecked Sendable {
    final class Run { var task: Task<Void, Never>?; var waiters: [UUID: CheckedContinuation<T, Error>] = [:]; var gone: Set<UUID> = []; var result: Result<T, Error>? }
    private let l = NSLock(); private var runs: [String: Run] = [:]

    func join(_ key: String, _ work: @escaping @Sendable () async throws -> T) async throws -> T {
        let id = UUID()
        let run: Run = l.withLock {
            if let r = runs[key] { return r }
            let r = Run(); runs[key] = r
            r.task = Task { [self] in
                let res: Result<T, Error>
                do { res = .success(try await work()) } catch { res = .failure(error) }
                finish(key, r, res)
            }
            return r
        }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<T, Error>) in
                l.withLock {
                    if let res = run.result { c.resume(with: res) }
                    else if run.gone.contains(id) { c.resume(throwing: CancellationError()); abandonIfEmpty(key, run) }
                    else { run.waiters[id] = c }
                }
            }
        } onCancel: {
            l.withLock {
                if let c = run.waiters.removeValue(forKey: id) { c.resume(throwing: CancellationError()); abandonIfEmpty(key, run) }
                else { run.gone.insert(id) }
            }
        }
    }
    private func abandonIfEmpty(_ key: String, _ run: Run) {
        guard run.waiters.isEmpty, run.result == nil else { return }
        if runs[key] === run { runs[key] = nil }
        run.task?.cancel()
    }
    private func finish(_ key: String, _ run: Run, _ res: Result<T, Error>) {
        let ws: [CheckedContinuation<T, Error>] = l.withLock {
            run.result = res; if runs[key] === run { runs[key] = nil }
            defer { run.waiters = [:] }; return Array(run.waiters.values)
        }
        ws.forEach { $0.resume(with: res) }
    }
}

import Foundation
import GRDB

extension AITaskService {

    /// Validates a pasted/loaded response and commits accepted questions in one transaction.
    /// - Parameter targetBatchId: when the user imports into a specific batch, the response's requestId must match it.
    public func importResponse(_ raw: String, targetBatchId: UUID? = nil) throws -> ImportReport {
        guard raw.utf8.count <= Self.maxResponseBytes else { throw AITaskError.responseTooLarge(Self.maxResponseBytes / 1_048_576) }

        // 1. Parse (tolerating a code fence or surrounding prose).
        guard let obj = Self.parse(raw) else {
            try preserve(raw, batchId: targetBatchId, outcome: .malformed, issues: ["Could not parse JSON"])
            throw AITaskError.malformedJSON(Self.parseFailureDetail(raw))
        }
        guard let env = obj as? [String: Any] else {
            try preserve(raw, batchId: targetBatchId, outcome: .rejected, issues: ["Top level is not an object"])
            throw AITaskError.notAnObject
        }
        let canonical = (try? JSONSerialization.data(withJSONObject: env, options: [.sortedKeys])).flatMap { String(data: $0, encoding: .utf8) } ?? raw
        let hash = QuestionHashing.sha256(canonical)

        // 2. Idempotency: the same response is only ever imported once.
        if let prior = try db.read({ try AIImport.filter(Column("responseHash") == hash && Column("outcome") == ImportOutcomeKind.imported).fetchOne($0) }),
           let bid = prior.batchId, let batch = try db.read({ try AITaskBatch.fetchOne($0, key: bid) }) {
            return ImportReport(importId: prior.id, batchId: bid, alreadyImported: true, accepted: [], duplicates: [],
                                rejected: (try? JSONDecoder().decode([RejectedEntry].self, from: Data(prior.rejectedEntries.utf8))) ?? [],
                                batchStatus: batch.status)
        }

        // 3. Envelope checks.
        guard let version = env["schemaVersion"] as? String, version == QuestionSchema.version else {
            let found = env["schemaVersion"] as? String
            try preserve(raw, batchId: targetBatchId, outcome: .rejected, issues: ["Unsupported schemaVersion \(found ?? "(missing)")"])
            throw AITaskError.unsupportedSchema(found)
        }
        guard let requestId = env["requestId"] as? String, !requestId.isEmpty else {
            try preserve(raw, batchId: targetBatchId, outcome: .rejected, issues: ["Missing requestId"])
            throw AITaskError.missingRequestId
        }
        let matched = try db.read { try AITaskBatch.filter(Column("requestId") == requestId).fetchOne($0) }
        if let t = targetBatchId {
            let target = try db.read { try AITaskBatch.fetchOne($0, key: t) }
            guard let target else { throw AITaskError.notFound }
            guard matched?.id == t else {
                try preserve(raw, batchId: t, outcome: .rejected, issues: ["requestId \(requestId) does not match this batch"])
                throw AITaskError.requestMismatch(expected: target.requestId, found: requestId)
            }
        }
        guard let batch = matched else {
            try preserve(raw, batchId: nil, outcome: .rejected, issues: ["Unknown requestId \(requestId)"])
            throw AITaskError.unknownRequest(requestId)
        }
        guard let entries = env["questions"] as? [Any] else {
            try preserve(raw, batchId: batch.id, outcome: .rejected, issues: ["Missing questions array"])
            throw AITaskError.missingQuestions
        }
        guard entries.count <= Self.maxQuestionsPerResponse else {
            try preserve(raw, batchId: batch.id, outcome: .rejected, issues: ["Too many questions (\(entries.count))"])
            throw AITaskError.tooManyQuestions(entries.count)
        }

        // 4. Validate each entry, then commit everything atomically.
        let results = entries.enumerated().map { QuestionValidator.validate(entry: $1, index: $0) }
        return try db.write { d in
            guard let task = try AITask.fetchOne(d, key: batch.taskId) else { throw AITaskError.notFound }
            let importId = UUID()
            var accepted: [AcceptedQuestion] = [], duplicates: [String] = [], rejected: [RejectedEntry] = []
            var seen = Set<String>()
            var allIssues: [ValidationIssue] = []

            for (i, r) in results.enumerated() {
                allIssues += r.issues
                guard !r.hasBlocking, let iq = r.question else {
                    let json = (try? JSONSerialization.data(withJSONObject: entries[i], options: [.sortedKeys, .prettyPrinted])).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
                    let title = ((entries[i] as? [String: Any])?["title"] as? String)
                    let id = ((entries[i] as? [String: Any])?["importId"] as? String) ?? "q\(i + 1)"
                    rejected.append(RejectedEntry(index: i, importId: id, title: title, entryJSON: json, issues: r.issues.filter { $0.severity == .blocking }))
                    continue
                }
                let hash = QuestionHashing.contentHash(iq.spec)
                let dup = try Int.fetchOne(d, sql: """
                    SELECT COUNT(*) FROM question_revisions r JOIN questions q ON q.id = r.questionId
                    WHERE q.courseId = ? AND q.archivedAt IS NULL AND r.contentHash = ? AND r.id = q.currentRevisionId
                    """, arguments: [task.courseId, hash]) ?? 0
                if dup > 0 || !seen.insert(hash).inserted { duplicates.append(iq.spec.title); continue }

                var notes: [String] = []
                let probable = try String.fetchOne(d, sql: """
                    SELECT r.title FROM question_revisions r JOIN questions q ON q.id = r.questionId
                    WHERE q.courseId = ? AND q.archivedAt IS NULL AND q.type = ? AND r.id = q.currentRevisionId
                      AND lower(r.title) = lower(?) LIMIT 1
                    """, arguments: [task.courseId, iq.spec.type, iq.spec.title.trimmingCharacters(in: .whitespaces)])
                if let probable { notes.append("Probable duplicate of existing question “\(probable)”") }

                let (skillIds, skillNotes) = try Self.resolveSkills(d, courseId: task.courseId, names: iq.skillNames)
                notes += skillNotes
                var asmIds = try Self.resolveAssessments(d, courseId: task.courseId, names: iq.assessmentNames, notes: &notes)
                if let a = task.assessmentId, !asmIds.contains(a) { asmIds.append(a) }

                let q = try QuestionService.insert(d, courseId: task.courseId, spec: iq.spec, validation: r, skillIds: skillIds,
                                                   assessmentIds: asmIds, origin: .aiImport, aiImportId: importId, familyId: nil, extraNotes: notes)
                accepted.append(AcceptedQuestion(importId: iq.importId, questionId: q.id, title: iq.spec.title, readiness: q.readiness))
            }

            let status: BatchStatus
            if !rejected.isEmpty { status = .needsRepair }
            else if accepted.count + duplicates.count < batch.expectedCount { status = .incomplete }
            else { status = .imported }

            let imp = AIImport(id: importId, batchId: batch.id, responseHash: hash, rawResponse: raw, outcome: .imported,
                               returnedCount: entries.count, acceptedCount: accepted.count, duplicateCount: duplicates.count,
                               rejectedCount: rejected.count,
                               issues: Self.json(allIssues), rejectedEntries: Self.json(rejected), createdAt: Date())
            try imp.insert(d)
            try d.execute(sql: "UPDATE ai_task_batches SET status = ? WHERE id = ?", arguments: [status, batch.id])

            // A repair/continuation that finishes cleanly resolves the batch it came from.
            var cursor = status == .imported ? batch.parentBatchId : nil
            while let pid = cursor {
                try d.execute(sql: "UPDATE ai_task_batches SET status = ? WHERE id = ?", arguments: [BatchStatus.imported, pid])
                cursor = try UUID.fetchOne(d, sql: "SELECT parentBatchId FROM ai_task_batches WHERE id = ?", arguments: [pid])
            }
            return ImportReport(importId: importId, batchId: batch.id, alreadyImported: false, accepted: accepted,
                                duplicates: duplicates, rejected: rejected, batchStatus: status)
        }
    }

    // MARK: Helpers

    /// Stores an unusable response so it is never lost; it does not count as imported.
    private func preserve(_ raw: String, batchId: UUID?, outcome: ImportOutcomeKind, issues: [String]) throws {
        try db.write { d in
            try AIImport(id: UUID(), batchId: batchId, responseHash: QuestionHashing.sha256(raw), rawResponse: raw, outcome: outcome,
                         returnedCount: 0, acceptedCount: 0, duplicateCount: 0, rejectedCount: 0,
                         issues: Self.json(issues), rejectedEntries: "[]", createdAt: Date()).insert(d)
        }
    }

    static func json<T: Encodable>(_ v: T) -> String {
        (try? JSONEncoder().encode(v)).flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
    }

    /// Accepts bare JSON, a ```json fence, or JSON embedded in prose.
    static func parse(_ raw: String) -> Any? {
        let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let d = t.data(using: .utf8), let o = try? JSONSerialization.jsonObject(with: d) { return o }
        guard let s = t.firstIndex(of: "{"), let e = t.lastIndex(of: "}"), s < e,
              let d = String(t[s...e]).data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: d)
    }

    static func parseFailureDetail(_ raw: String) -> String {
        let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty { return "empty" }
        if !t.contains("{") { return "no JSON object found" }
        do { _ = try JSONSerialization.jsonObject(with: Data(t.utf8)); return "unknown problem" }
        catch { return ((error as NSError).userInfo[NSDebugDescriptionErrorKey] as? String) ?? "syntax error" }
    }

    /// Exact (case/space-insensitive) match → attach. One or more near matches → ambiguous: attach nothing and flag.
    /// No match at all → create the skill in this course (never touches other courses).
    static func resolveSkills(_ d: Database, courseId: UUID, names: [String]) throws -> ([UUID], [String]) {
        let existing = try Skill.fetchAll(d, sql: """
            SELECT skills.* FROM skills JOIN course_skills ON course_skills.skillId = skills.id
            WHERE course_skills.courseId = ? AND skills.archivedAt IS NULL
            """, arguments: [courseId])
        var ids: [UUID] = [], notes: [String] = []
        for name in names {
            let key = name.skillKey
            if let hit = existing.first(where: { $0.normalizedName == key }) { ids.append(hit.id); continue }
            let near = existing.filter { key.count >= 3 && ($0.normalizedName.contains(key) || key.contains($0.normalizedName)) }
            if !near.isEmpty {
                notes.append("Ambiguous skill “\(name)” (similar to \(near.map { "“\($0.name)”" }.joined(separator: ", "))); not tagged")
                continue
            }
            ids.append(try CourseService.addSkill(d, courseId: courseId, name: name, parentId: nil).skill.id)
        }
        if names.isEmpty { notes.append("No skills listed; tag skills before relying on this question") }
        return (Array(Set(ids)), notes)
    }

    static func resolveAssessments(_ d: Database, courseId: UUID, names: [String], notes: inout [String]) throws -> [UUID] {
        let all = try Assessment.filter(Column("courseId") == courseId).fetchAll(d)
        var ids: [UUID] = []
        for n in names {
            if let a = all.first(where: { $0.name.skillKey == n.skillKey }) { ids.append(a.id) }
            else { notes.append("Unknown assessment “\(n)”; not linked") }
        }
        return ids
    }
}

import Foundation
import GRDB

public struct GradeRejection: Codable, Sendable, Equatable {
    public var attemptId: String?
    public var issues: [String]
}

public struct GradeImportReport: Sendable {
    public var importId: UUID
    public var batchId: UUID
    public var alreadyImported: Bool
    public var graded: [(attemptId: UUID, score: Double)]
    public var rejected: [GradeRejection]
    public var batchStatus: BatchStatus
}

extension AITaskService {

    /// The schemaVersion declared by a response, so the UI can route it to the right importer.
    public static func peekSchemaVersion(_ raw: String) -> String? {
        (Self.parse(raw) as? [String: Any])?["schemaVersion"] as? String
    }

    /// Validates and commits ChatGPT's grades. Each grade must reference an attempt that this batch asked about;
    /// grades never touch other attempts, and automatic (machine-checked) grades can't be overwritten this way.
    public func importGrades(_ raw: String, targetBatchId: UUID? = nil) throws -> GradeImportReport {
        guard raw.utf8.count <= Self.maxResponseBytes else { throw AITaskError.responseTooLarge(Self.maxResponseBytes / 1_048_576) }
        guard let obj = Self.parse(raw) else {
            try preserveGrade(raw, batchId: targetBatchId, outcome: .malformed, issue: "Could not parse JSON")
            throw AITaskError.malformedJSON(Self.parseFailureDetail(raw))
        }
        guard let env = obj as? [String: Any] else { throw AITaskError.notAnObject }
        let canonical = (try? JSONSerialization.data(withJSONObject: env, options: [.sortedKeys])).flatMap { String(data: $0, encoding: .utf8) } ?? raw
        let hash = QuestionHashing.sha256(canonical)

        if let prior = try db.read({ try AIImport.filter(Column("responseHash") == hash && Column("outcome") == ImportOutcomeKind.imported).fetchOne($0) }),
           let bid = prior.batchId, let batch = try db.read({ try AITaskBatch.fetchOne($0, key: bid) }) {
            return GradeImportReport(importId: prior.id, batchId: bid, alreadyImported: true, graded: [],
                                     rejected: (try? JSONDecoder().decode([GradeRejection].self, from: Data(prior.rejectedEntries.utf8))) ?? [], batchStatus: batch.status)
        }
        guard let version = env["schemaVersion"] as? String, version == GradeSchema.version else {
            try preserveGrade(raw, batchId: targetBatchId, outcome: .rejected, issue: "Unsupported schemaVersion")
            throw AITaskError.unsupportedSchema(env["schemaVersion"] as? String)
        }
        guard let requestId = env["requestId"] as? String, !requestId.isEmpty else {
            try preserveGrade(raw, batchId: targetBatchId, outcome: .rejected, issue: "Missing requestId"); throw AITaskError.missingRequestId
        }
        let matched = try db.read { try AITaskBatch.filter(Column("requestId") == requestId).fetchOne($0) }
        if let t = targetBatchId {
            guard let target = try db.read({ try AITaskBatch.fetchOne($0, key: t) }) else { throw AITaskError.notFound }
            guard matched?.id == t else {
                try preserveGrade(raw, batchId: t, outcome: .rejected, issue: "requestId \(requestId) does not match this batch")
                throw AITaskError.requestMismatch(expected: target.requestId, found: requestId)
            }
        }
        guard let batch = matched, batch.kind == .grade else {
            try preserveGrade(raw, batchId: nil, outcome: .rejected, issue: "Unknown requestId \(requestId)")
            throw AITaskError.unknownRequest(requestId)
        }
        guard let entries = env["grades"] as? [Any] else {
            try preserveGrade(raw, batchId: batch.id, outcome: .rejected, issue: "Missing grades array"); throw AITaskError.missingQuestions
        }
        guard entries.count <= Self.maxQuestionsPerBatch * 5 else { throw AITaskError.tooManyQuestions(entries.count) }

        return try db.write { d in
            let allowed = Set(try UUID.fetchAll(d, sql: "SELECT attemptId FROM ai_batch_attempts WHERE batchId = ?", arguments: [batch.id]))
            var graded: [(UUID, Double)] = [], rejected: [GradeRejection] = [], seen = Set<UUID>()
            let importId = UUID()
            for entry in entries {
                guard let e = entry as? [String: Any], let idStr = e["attemptId"] as? String else {
                    rejected.append(GradeRejection(attemptId: nil, issues: ["grades[]: each grade needs an attemptId"])); continue
                }
                guard let aid = UUID(uuidString: idStr), allowed.contains(aid) else {
                    rejected.append(GradeRejection(attemptId: idStr, issues: ["attemptId isn’t part of this request"])); continue
                }
                guard seen.insert(aid).inserted else { rejected.append(GradeRejection(attemptId: idStr, issues: ["duplicate grade for this attempt"])); continue }
                guard let attempt = try Attempt.fetchOne(d, key: aid), let spec = try QuestionRevision.fetchOne(d, key: attempt.revisionId)?.spec else {
                    rejected.append(GradeRejection(attemptId: idStr, issues: ["attempt no longer exists"])); continue
                }
                if let cur = try ProgressionEngine.active(d, attemptId: aid), cur.source == .deterministic, cur.state == .graded {
                    rejected.append(GradeRejection(attemptId: idStr, issues: ["already graded automatically; an imported grade can’t replace it"])); continue
                }
                var issues: [String] = []
                var score: Double?
                if let rs = e["rubricScores"] as? [[String: Any]], !rs.isEmpty {
                    let rubric = spec.evaluation.rubric ?? []
                    let maxPts = rubric.reduce(0) { $0 + $1.points }
                    let pts = rs.compactMap { ($0["points"] as? NSNumber)?.doubleValue }
                    if pts.count != rs.count || pts.contains(where: { $0 < 0 || !$0.isFinite }) { issues.append("rubricScores: every item needs points ≥ 0") }
                    else if maxPts > 0 { score = min(1, pts.reduce(0, +) / maxPts) }
                    else { issues.append("rubricScores given but the question has no rubric; send a score instead") }
                }
                if score == nil, issues.isEmpty {
                    if let n = e["score"] as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID(), (0...1).contains(n.doubleValue) { score = n.doubleValue }
                    else { issues.append("score must be a number from 0 to 1 (or provide rubricScores)") }
                }
                let feedback = (e["feedback"] as? String) ?? ""
                if feedback.count > 4_000 { issues.append("feedback is longer than 4000 characters") }
                guard issues.isEmpty, let score else { rejected.append(GradeRejection(attemptId: idStr, issues: issues)); continue }
                let detail = (try? JSONSerialization.data(withJSONObject: ["rubricScores": e["rubricScores"] ?? [], "importId": importId.uuidString], options: [.sortedKeys])).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
                let o = EvaluationOutcome(method: .aiRubric, state: .graded, score: score, trust: .aiGraded, feedback: feedback.isEmpty ? "Graded in ChatGPT." : feedback)
                try ProgressionEngine.commit(d, attempt: attempt, outcome: o, source: .aiImport, revisionId: attempt.revisionId,
                                             reason: "Imported from ChatGPT grading", detail: detail, batchId: batch.id)
                graded.append((aid, score))
            }
            let remaining = try allowed.filter { id in (try ProgressionEngine.active(d, attemptId: id)?.state) == .pending }.count
            let status: BatchStatus = remaining == 0 && rejected.isEmpty ? .imported : (rejected.isEmpty ? .incomplete : .needsRepair)
            try AIImport(id: importId, batchId: batch.id, responseHash: hash, rawResponse: raw, outcome: .imported, returnedCount: entries.count,
                         acceptedCount: graded.count, duplicateCount: 0, rejectedCount: rejected.count, issues: "[]",
                         rejectedEntries: Self.json(rejected), createdAt: Date()).insert(d)
            try d.execute(sql: "UPDATE ai_task_batches SET status = ? WHERE id = ?", arguments: [status, batch.id])
            return GradeImportReport(importId: importId, batchId: batch.id, alreadyImported: false, graded: graded, rejected: rejected, batchStatus: status)
        }
    }

    private func preserveGrade(_ raw: String, batchId: UUID?, outcome: ImportOutcomeKind, issue: String) throws {
        try db.write { d in
            try AIImport(id: UUID(), batchId: batchId, responseHash: QuestionHashing.sha256(raw), rawResponse: raw, outcome: outcome, returnedCount: 0,
                         acceptedCount: 0, duplicateCount: 0, rejectedCount: 0, issues: Self.json([issue]), rejectedEntries: "[]", createdAt: Date()).insert(d)
        }
    }
}

import Foundation
import GRDB

public enum GradeSchema {
    public static let version = "cramlab.grades.v1"
    public static let json = #"""
    {
      "$schema": "http://json-schema.org/draft-07/schema#",
      "title": "Braincell grade batch",
      "type": "object",
      "required": ["schemaVersion", "requestId", "grades"],
      "additionalProperties": false,
      "properties": {
        "schemaVersion": { "const": "cramlab.grades.v1" },
        "requestId": { "type": "string", "description": "Copy EXACTLY from the request." },
        "grades": { "type": "array", "items": {
          "type": "object",
          "required": ["attemptId", "feedback"],
          "properties": {
            "attemptId": { "type": "string", "description": "Copy EXACTLY from the attempt heading." },
            "score": { "type": "number", "minimum": 0, "maximum": 1, "description": "Overall score; omit if rubricScores are given." },
            "rubricScores": { "type": "array", "items": { "type": "object", "required": ["criterion", "points"],
              "properties": { "criterion": { "type": "string" }, "points": { "type": "number", "minimum": 0 } } } },
            "feedback": { "type": "string", "maxLength": 4000 }
          }
        } }
      }
    }
    """#
}

extension AITaskService {

    /// Creates a grading task for pending attempts of ONE course, split into batches of ≤10 attempts.
    @discardableResult
    public func createGradingTask(courseId: UUID, attemptIds: [UUID]) throws -> AITask {
        guard !attemptIds.isEmpty else { throw AITaskError.invalidParams("Choose at least one answer to grade.") }
        return try db.write { d in
            guard let course = try Course.fetchOne(d, key: courseId) else { throw AITaskError.notFound }
            for id in attemptIds {
                guard let a = try Attempt.fetchOne(d, key: id), let q = try Question.fetchOne(d, key: a.questionId), q.courseId == courseId else {
                    throw AITaskError.invalidParams("All answers must belong to the same course.")
                }
                guard let e = try ProgressionEngine.active(d, attemptId: id), e.state == .pending else {
                    throw AITaskError.invalidParams("An answer you selected is no longer waiting for a grade.")
                }
            }
            let task = AITask(id: UUID(), kind: .subjectiveGrading, courseId: courseId, assessmentId: nil,
                              title: "Grade \(attemptIds.count) answer\(attemptIds.count == 1 ? "" : "s") · \(course.name)", params: "{}", createdAt: Date())
            try task.insert(d)
            for (i, chunk) in stride(from: 0, to: attemptIds.count, by: Self.maxQuestionsPerBatch).map({ Array(attemptIds[$0..<min($0 + Self.maxQuestionsPerBatch, attemptIds.count)]) }).enumerated() {
                let b = Self.newBatch(d, taskId: task.id, parent: nil, ordinal: i, kind: .grade, expected: chunk.count)
                try b.insert(d)
                for id in chunk { try d.execute(sql: "INSERT INTO ai_batch_attempts (batchId, attemptId) VALUES (?, ?)", arguments: [b.id, id]) }
            }
            return task
        }
    }

    static func prepareGrading(_ d: Database, batch: AITaskBatch, course: Course) throws -> RequestPackage {
        var b = batch
        let attempts = try Attempt.fetchAll(d, sql: "SELECT a.* FROM attempts a JOIN ai_batch_attempts x ON x.attemptId = a.id WHERE x.batchId = ? ORDER BY a.submittedAt, a.rowid", arguments: [b.id])
        var body = "# Attempts to grade\n"
        var types: [String] = []
        for a in attempts {
            guard let rev = try QuestionRevision.fetchOne(d, key: a.revisionId), let spec = rev.spec else { continue }
            types.append(spec.type.rawValue)
            body += "\n---\n\n## Attempt \(a.id.uuidString)\n"
            body += "Question: \(spec.title) (\(spec.type.label), difficulty \(spec.difficulty)/5, revision \(rev.id.uuidString))\n"
            body += "Learning objective: \(spec.learningObjective)\n\n### Statement\n\(describe(spec.content))\n"
            if let r = spec.evaluation.rubric, !r.isEmpty { body += "\n### Rubric\n" + r.map { "- \($0.criterion) (\(Int($0.points)) pts)" }.joined(separator: "\n") + "\n" }
            if !spec.solution.isEmpty { body += "\n### Reference solution\n\(describe(spec.solution))\n" }
            body += "\n### Student response\n\(describe(a.decodedResponse, spec: spec))\n"
        }
        let instructions = """
        # Braincell grading request — \(course.name)

        You are grading a student's answers. Be fair, specific and consistent with the rubric. Grade ONLY the attempts listed in attempts.md.

        ## Output rules
        1. Reply with ONE JSON object and nothing else (a ```json fence is fine), matching response_schema.json.
        2. `schemaVersion` must be "\(GradeSchema.version)". `requestId` must be exactly "\(b.requestId)".
        3. For each attempt give `attemptId` (copied exactly), a `score` from 0 (nothing correct) to 1 (fully correct) — or `rubricScores` with points per criterion — and short, constructive `feedback`.
        4. Do not grade attempts that are not listed. Do not invent attempt IDs.
        5. If the response is blank or off-topic, give score 0 and say so.

        Request ID: \(b.requestId)
        """
        let single = [instructions, "## Response JSON schema\n```json\n\(GradeSchema.json)\n```", body].joined(separator: "\n\n---\n\n")
        let transfer: TransferMethod = single.count <= PromptBuilder.compactLimit ? .clipboard : .file
        let manifest = RequestManifest(requestId: b.requestId, schemaVersion: GradeSchema.version, kind: .grade, course: course.name, assessment: nil,
                                       expectedCount: attempts.count, questionTypes: Array(Set(types)).sorted(), difficulty: "", skills: [], documents: [],
                                       existingQuestionTitles: 0, repairEntries: 0, includesUserNotes: false, includedResponses: attempts.count, characterCount: single.count,
                                       recommendedTransfer: transfer,
                                       excluded: ["No other attempts, scores or study history", "No private reflections", "No document extracts or other course material"])
        let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        let files = [ExportFile(name: "instructions.md", content: instructions), ExportFile(name: "response_schema.json", content: GradeSchema.json),
                     ExportFile(name: "attempts.md", content: body),
                     ExportFile(name: "manifest.json", content: (try? enc.encode(manifest)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}")]
        let cover = "I'm attaching files for a Braincell grading request. Read instructions.md and follow it exactly. Reply with ONLY the JSON object described in response_schema.json. The requestId to echo back is: \(b.requestId)"
        b.requestText = single
        b.manifest = String(data: try JSONEncoder().encode(manifest), encoding: .utf8) ?? "{}"
        try b.update(d)
        return RequestPackage(singlePrompt: single, coverPrompt: cover, files: files, manifest: manifest)
    }

    static func describe(_ blocks: [ContentBlock]) -> String {
        blocks.map { b -> String in
            switch b.kind {
            case .code: "```\(b.language ?? "")\n\(b.text ?? "")\n```"
            case .math: "$$\(b.latex ?? "")$$"
            default: b.plainText
            }
        }.joined(separator: "\n\n")
    }

    static func describe(_ r: PracticeResponse, spec: QuestionSpec) -> String {
        if !r.files.isEmpty { return r.files.map { "File \($0.name):\n```\($0.language)\n\($0.content)\n```" }.joined(separator: "\n\n") }
        if !r.selected.isEmpty { return "Selected: " + r.selected.joined(separator: ", ") }
        return r.text.isEmpty ? "(blank)" : r.text
    }
}

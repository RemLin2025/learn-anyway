import Foundation
import GRDB

/// Topic analysis: ChatGPT proposes a skill structure for a course; the learner reviews it (new / matches / ambiguous /
/// hierarchy / prerequisites / assessment coverage), edits or declines parts, and only then does anything change.
/// Applying never deletes or resets anything, so existing mastery, XP and attempts are untouched.
public enum TopicSchema {
    public static let version = "cramlab.topics.v1"
    public static let maxSkills = 80
    public static let json = """
    {
      "$schema": "https://json-schema.org/draft/2020-12/schema",
      "type": "object",
      "required": ["schemaVersion", "requestId", "skills"],
      "properties": {
        "schemaVersion": { "const": "cramlab.topics.v1" },
        "requestId": { "type": "string" },
        "skills": {
          "type": "array", "maxItems": 80,
          "items": {
            "type": "object",
            "required": ["id", "name"],
            "properties": {
              "id": { "type": "string", "description": "Short unique id for this response, e.g. t1" },
              "name": { "type": "string", "maxLength": 200 },
              "summary": { "type": "string", "maxLength": 500 },
              "parent": { "type": "string", "description": "id of another proposed skill, or the exact name of an existing skill" },
              "prerequisites": { "type": "array", "maxItems": 10, "items": { "type": "string" }, "description": "ids or existing skill names that should be learned first" },
              "assessments": { "type": "array", "maxItems": 10, "items": { "type": "string" }, "description": "exact names of the course assessments that cover this skill" }
            }
          }
        }
      }
    }
    """
}

public enum TopicMatch: Sendable, Equatable {
    case new
    case existing(Skill)
    /// Similar to one or more existing skills but not the same name: the learner decides.
    case ambiguous([Skill])
}

public struct TopicItem: Sendable, Equatable, Identifiable {
    public var id: String
    public var name: String
    public var summary: String
    public var parentRef: String?
    public var prerequisiteRefs: [String]
    public var assessments: [String]
    public var match: TopicMatch
}

public struct TopicProposal: Sendable {
    public var batchId: UUID
    public var importId: UUID
    public var items: [TopicItem]
    /// Entries of the response that were unusable, with the reason (never silently dropped).
    public var problems: [String]
    /// Assessment names that don't exist in the course.
    public var unknownAssessments: [String]
    public var alreadyApplied: Bool
}

public struct TopicDecision: Sendable, Equatable {
    public var accept: Bool
    public var name: String?
    /// For an ambiguous item: fold it into this existing skill instead of creating a new one.
    public var mergeInto: UUID?
    public init(accept: Bool = true, name: String? = nil, mergeInto: UUID? = nil) { self.accept = accept; self.name = name; self.mergeInto = mergeInto }
}

public struct TopicApplyReport: Sendable, Equatable {
    public var created: [String] = []
    public var reused: [String] = []
    public var relationsAdded = 0
    public var coverageAdded = 0
    public var skipped: [String] = []
}

public enum AnyImportReport: Sendable {
    case questions(ImportReport), grades(GradeImportReport), topics(TopicProposal)
}

extension AITaskService {

    /// Routes a reply to the right importer by its `schemaVersion`; all of them preserve the raw text and validate before changing anything.
    public func importAny(_ raw: String, targetBatchId: UUID? = nil) throws -> AnyImportReport {
        switch Self.peekSchemaVersion(raw) {
        case GradeSchema.version: .grades(try importGrades(raw, targetBatchId: targetBatchId))
        case TopicSchema.version: .topics(try importTopics(raw, targetBatchId: targetBatchId))
        default: .questions(try importResponse(raw, targetBatchId: targetBatchId))
        }
    }

    // MARK: Creating and preparing

    @discardableResult
    public func createTopicAnalysisTask(courseId: UUID, documentIds: [UUID] = [], notes: String = "") throws -> AITask {
        try db.write { d in
            guard let course = try Course.fetchOne(d, key: courseId) else { throw AITaskError.notFound }
            for id in documentIds { guard try Document.fetchOne(d, key: id)?.courseId == courseId else { throw AITaskError.invalidParams("A document belongs to another course.") } }
            let p = GenerationParams(count: 1, documentIds: documentIds, includeExistingTitles: false, notes: String(notes.prefix(1_000)))
            let task = AITask(id: UUID(), kind: .topicAnalysis, courseId: courseId, assessmentId: nil, title: "Topic analysis · \(course.name)",
                              params: String(data: try JSONEncoder().encode(p), encoding: .utf8) ?? "{}", createdAt: Date())
            try task.insert(d)
            try Self.newBatch(d, taskId: task.id, parent: nil, ordinal: 0, kind: .topics, expected: 1).insert(d)
            return task
        }
    }

    static func prepareTopics(_ d: Database, batch: AITaskBatch, task: AITask, course: Course) throws -> RequestPackage {
        var b = batch
        let params = (try? JSONDecoder().decode(GenerationParams.self, from: Data(task.params.utf8))) ?? GenerationParams()
        let skills = try Skill.fetchAll(d, sql: "SELECT skills.* FROM skills JOIN course_skills ON course_skills.skillId = skills.id WHERE courseId = ? AND archivedAt IS NULL ORDER BY name COLLATE NOCASE", arguments: [course.id]).map(\.name)
        let assessments = try Assessment.filter(Column("courseId") == course.id).order(Column("name")).fetchAll(d).map(\.name)
        var extracts = "", docs: [RequestManifest.DocumentEntry] = [], budget = PromptBuilder.extractBudget
        for docId in params.documentIds {
            guard let doc = try Document.fetchOne(d, key: docId), doc.courseId == course.id else { continue }
            var used = 0, truncated = false
            for c in try DocumentChunk.filter(Column("documentId") == docId && Column("isLowContent") == false).order(Column("ordinal")).fetchAll(d) {
                guard budget > 0 else { truncated = true; break }
                let text = String(c.text.prefix(budget))
                if text.count < c.text.count { truncated = true }
                extracts += "\n\n### \(doc.title)\(c.pageNumber.map { " (page \($0))" } ?? "")\n\(text)"
                budget -= text.count; used += text.count
            }
            docs.append(.init(title: doc.title, characters: used, truncated: truncated))
        }
        let instructions = """
        # Braincell topic analysis — \(course.name)

        Propose a skill structure for this course so the student can study it. Use ONLY the course material below (if any) and the existing skills and assessments listed.

        ## Output rules
        1. Reply with ONE JSON object and nothing else (a ```json fence is fine), matching response_schema.json.
        2. `schemaVersion` must be "\(TopicSchema.version)". `requestId` must be exactly "\(b.requestId)".
        3. Give 5–\(TopicSchema.maxSkills) skills: concrete, studyable topics (not chapter titles like "Introduction"). Use at most three levels of hierarchy.
        4. Reuse the EXACT name of an existing skill when you mean it. Do not invent near-duplicates of existing skills.
        5. `parent` is the id of another skill in your response (or the exact name of an existing skill). `prerequisites` only where one skill genuinely needs another first; avoid cycles.
        6. `assessments` may only contain names from the assessment list below.
        7. Do not invent facts about the course that the material does not support.

        Existing skills: \(skills.isEmpty ? "(none)" : skills.joined(separator: "; "))
        Assessments: \(assessments.isEmpty ? "(none)" : assessments.joined(separator: "; "))
        \(params.notes.isEmpty ? "" : "Extra guidance from the student: \(params.notes)")

        Request ID: \(b.requestId)
        """
        let body = extracts.isEmpty ? "# Course material\n\n(No documents were attached; work from the course name and the lists above.)" : "# Course material\(extracts)"
        let single = [instructions, "## Response JSON schema\n```json\n\(TopicSchema.json)\n```", body].joined(separator: "\n\n---\n\n")
        let transfer: TransferMethod = single.count <= PromptBuilder.compactLimit ? .clipboard : .file
        let manifest = RequestManifest(requestId: b.requestId, schemaVersion: TopicSchema.version, kind: .topics, course: course.name, assessment: nil,
                                       expectedCount: 0, questionTypes: [], difficulty: "", skills: skills, documents: docs, existingQuestionTitles: 0,
                                       repairEntries: 0, includesUserNotes: !params.notes.isEmpty, characterCount: single.count, recommendedTransfer: transfer,
                                       excluded: ["No questions, answers, scores or study history", "No private reflections", "No files other than the document extracts listed above"])
        let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        let files = [ExportFile(name: "instructions.md", content: instructions), ExportFile(name: "response_schema.json", content: TopicSchema.json),
                     ExportFile(name: "material.md", content: body),
                     ExportFile(name: "manifest.json", content: (try? enc.encode(manifest)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}")]
        let cover = "I'm attaching files for a Braincell topic analysis. Read instructions.md and follow it exactly. Reply with ONLY the JSON object described in response_schema.json. The requestId to echo back is: \(b.requestId)"
        b.requestText = single
        b.manifest = String(data: try JSONEncoder().encode(manifest), encoding: .utf8) ?? "{}"
        try b.update(d)
        return RequestPackage(singlePrompt: single, coverPrompt: cover, files: files, manifest: manifest)
    }

    // MARK: Importing (staging; nothing about the course changes yet)

    @discardableResult
    public func importTopics(_ raw: String, targetBatchId: UUID? = nil) throws -> TopicProposal {
        func preserve(_ outcome: ImportOutcomeKind, _ issue: String, batch: UUID?) throws {
            try db.write { d in
                try AIImport(id: UUID(), batchId: batch, responseHash: QuestionHashing.sha256(raw), rawResponse: raw, outcome: outcome, returnedCount: 0,
                             acceptedCount: 0, duplicateCount: 0, rejectedCount: 0, issues: Self.json([issue]), rejectedEntries: "[]", createdAt: Date()).insert(d)
            }
        }
        guard raw.utf8.count <= Self.maxResponseBytes else { throw AITaskError.responseTooLarge(Self.maxResponseBytes / 1_048_576) }
        guard let obj = Self.parse(raw) else { try preserve(.malformed, "Could not parse JSON", batch: targetBatchId); throw AITaskError.malformedJSON(Self.parseFailureDetail(raw)) }
        guard let env = obj as? [String: Any] else { throw AITaskError.notAnObject }
        guard env["schemaVersion"] as? String == TopicSchema.version else { try preserve(.rejected, "Unsupported schemaVersion", batch: targetBatchId); throw AITaskError.unsupportedSchema(env["schemaVersion"] as? String) }
        guard let requestId = env["requestId"] as? String, !requestId.isEmpty else { try preserve(.rejected, "Missing requestId", batch: targetBatchId); throw AITaskError.missingRequestId }
        let matched = try db.read { try AITaskBatch.filter(Column("requestId") == requestId).fetchOne($0) }
        if let t = targetBatchId {
            guard let target = try db.read({ try AITaskBatch.fetchOne($0, key: t) }) else { throw AITaskError.notFound }
            guard matched?.id == t else { try preserve(.rejected, "requestId \(requestId) does not match this batch", batch: t); throw AITaskError.requestMismatch(expected: target.requestId, found: requestId) }
        }
        guard let batch = matched, batch.kind == .topics else { try preserve(.rejected, "Unknown requestId \(requestId)", batch: nil); throw AITaskError.unknownRequest(requestId) }
        guard let entries = env["skills"] as? [Any] else { try preserve(.rejected, "Missing skills array", batch: batch.id); throw AITaskError.noTopics }
        guard entries.count <= TopicSchema.maxSkills else { try preserve(.rejected, "Too many skills", batch: batch.id); throw AITaskError.tooManyQuestions(entries.count) }

        let (valid, problems) = Self.validateTopicEntries(entries)
        guard !valid.isEmpty else { try preserve(.rejected, problems.first ?? "No usable skills", batch: batch.id); throw AITaskError.noTopics }

        let canonical = (try? JSONSerialization.data(withJSONObject: env, options: [.sortedKeys])).flatMap { String(data: $0, encoding: .utf8) } ?? raw
        let hash = QuestionHashing.sha256(canonical)
        let importId: UUID = try db.write { d in
            if let prior = try AIImport.filter(Column("batchId") == batch.id && Column("responseHash") == hash && Column("outcome") == ImportOutcomeKind.imported).fetchOne(d) { return prior.id }
            let id = UUID()
            try AIImport(id: id, batchId: batch.id, responseHash: hash, rawResponse: raw, outcome: .imported, returnedCount: entries.count, acceptedCount: 0,
                         duplicateCount: 0, rejectedCount: problems.count, issues: "[]", rejectedEntries: Self.json(problems), createdAt: Date()).insert(d)
            return id
        }
        guard let p = try topicProposal(batchId: batch.id) else { throw AITaskError.noTopics }
        _ = importId
        return p
    }

    /// The staged proposal, re-matched against the course as it is now (so a second look after applying shows items as existing).
    public func topicProposal(batchId: UUID) throws -> TopicProposal? {
        try db.read { d in
            guard let batch = try AITaskBatch.fetchOne(d, key: batchId), batch.kind == .topics,
                  let imp = try Self.latestImport(d, batchId: batchId), let task = try AITask.fetchOne(d, key: batch.taskId),
                  let env = Self.parse(imp.rawResponse) as? [String: Any], let entries = env["skills"] as? [Any] else { return nil }
            let (valid, problems) = Self.validateTopicEntries(entries)
            let existing = try Skill.fetchAll(d, sql: "SELECT skills.* FROM skills JOIN course_skills ON course_skills.skillId = skills.id WHERE courseId = ? AND archivedAt IS NULL", arguments: [task.courseId])
            let asm = Set(try Assessment.filter(Column("courseId") == task.courseId).fetchAll(d).map { $0.name.skillKey })
            var unknown = Set<String>()
            let items = valid.map { e -> TopicItem in
                for a in e.assessments where !asm.contains(a.skillKey) { unknown.insert(a) }
                return TopicItem(id: e.id, name: e.name, summary: e.summary, parentRef: e.parent, prerequisiteRefs: e.prerequisites, assessments: e.assessments,
                                 match: Self.match(e.name, existing))
            }
            return TopicProposal(batchId: batchId, importId: imp.id, items: items, problems: problems, unknownAssessments: unknown.sorted(), alreadyApplied: batch.status == .imported)
        }
    }

    struct RawTopic { var id: String, name: String, summary: String, parent: String?, prerequisites: [String], assessments: [String] }

    static func validateTopicEntries(_ entries: [Any]) -> ([RawTopic], [String]) {
        var out: [RawTopic] = [], problems: [String] = [], ids = Set<String>(), names = Set<String>()
        func strings(_ v: Any?, max: Int) -> [String]? {
            guard let v else { return [] }
            guard let a = v as? [String], a.count <= max, a.allSatisfy({ !$0.isEmpty && $0.count <= 200 }) else { return nil }
            return a
        }
        for (i, raw) in entries.enumerated() {
            let label = "skills[\(i)]"
            guard let e = raw as? [String: Any] else { problems.append("\(label): not an object"); continue }
            guard let id = e["id"] as? String, !id.isEmpty, id.count <= 40, ids.insert(id).inserted else { problems.append("\(label): needs a unique short id"); continue }
            guard let name = (e["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty, name.count <= 200 else { problems.append("\(label) (\(id)): needs a name of 1–200 characters"); continue }
            guard names.insert(name.skillKey).inserted else { problems.append("\(label) (\(id)): “\(name)” duplicates another skill in the response"); continue }
            guard let prereqs = strings(e["prerequisites"], max: 10), let asm = strings(e["assessments"], max: 10) else { problems.append("\(label) (\(id)): prerequisites/assessments must be short lists of text"); continue }
            let summary = (e["summary"] as? String) ?? ""
            guard summary.count <= 500 else { problems.append("\(label) (\(id)): summary is longer than 500 characters"); continue }
            let parent = (e["parent"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            out.append(RawTopic(id: id, name: name, summary: summary, parent: parent, prerequisites: prereqs, assessments: asm))
        }
        return (out, problems)
    }

    static func match(_ name: String, _ existing: [Skill]) -> TopicMatch {
        let key = name.skillKey
        if let s = existing.first(where: { $0.normalizedName == key }) { return .existing(s) }
        func tokens(_ s: String) -> Set<String> { Set(s.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init).filter { $0.count > 1 }) }
        let t = tokens(name)
        let scored = existing.compactMap { s -> (Skill, Double)? in
            let u = tokens(s.name); let inter = Double(t.intersection(u).count), uni = Double(t.union(u).count)
            var score = uni > 0 ? inter / uni : 0
            if min(key.count, s.normalizedName.count) >= 4, key.contains(s.normalizedName) || s.normalizedName.contains(key) { score = max(score, 0.7) }
            return score >= 0.5 ? (s, score) : nil
        }.sorted { $0.1 > $1.1 }
        return scored.isEmpty ? .new : .ambiguous(scored.prefix(3).map(\.0))
    }

    // MARK: Applying the reviewed proposal

    /// Commits what the learner accepted, in one transaction. Defaults: new → create, existing → reuse, ambiguous → skipped until decided.
    @discardableResult
    public func applyTopics(batchId: UUID, decisions: [String: TopicDecision] = [:]) throws -> TopicApplyReport {
        guard let proposal = try topicProposal(batchId: batchId) else { throw AITaskError.noTopics }
        return try db.write { d in
            guard let batch = try AITaskBatch.fetchOne(d, key: batchId), let task = try AITask.fetchOne(d, key: batch.taskId) else { throw AITaskError.notFound }
            let courseId = task.courseId
            var report = TopicApplyReport()
            var resolved: [String: UUID] = [:]            // item id → skill id
            var names: [String: UUID] = [:]                // normalized name → skill id (proposed items)

            for item in proposal.items {
                let dec = decisions[item.id]
                let defaultAccept: Bool = { if case .ambiguous = item.match { return dec?.mergeInto != nil } else { return true } }()
                guard dec?.accept ?? defaultAccept else { report.skipped.append("“\(item.name)” was not accepted"); continue }
                let skill: Skill
                if let target = dec?.mergeInto {
                    guard let s = try Skill.fetchOne(d, sql: "SELECT skills.* FROM skills JOIN course_skills ON course_skills.skillId = skills.id WHERE skills.id = ? AND courseId = ? AND archivedAt IS NULL", arguments: [target, courseId]) else {
                        report.skipped.append("“\(item.name)”: the skill to merge into is no longer in this course"); continue
                    }
                    skill = s; report.reused.append(s.name)
                } else if case .existing(let s) = item.match, dec?.name == nil {
                    skill = s; report.reused.append(s.name)
                } else {
                    let (s, created) = try CourseService.addSkill(d, courseId: courseId, name: dec?.name ?? item.name, parentId: nil)
                    var s2 = s
                    if created, !item.summary.isEmpty { s2.summary = item.summary; try s2.update(d) }
                    skill = s2
                    if created { report.created.append(s.name) } else { report.reused.append(s.name) }
                }
                resolved[item.id] = skill.id; names[item.name.skillKey] = skill.id
            }

            func lookup(_ ref: String) throws -> UUID? {
                if let id = resolved[ref] { return id }
                if let id = names[ref.skillKey] { return id }
                return try UUID.fetchOne(d, sql: "SELECT skills.id FROM skills JOIN course_skills ON course_skills.skillId = skills.id WHERE courseId = ? AND normalizedName = ? AND archivedAt IS NULL", arguments: [courseId, ref.skillKey])
            }
            for item in proposal.items {
                guard let me = resolved[item.id] else { continue }
                func link(_ ref: String, kind: SkillRelationKind, parentIsRef: Bool) throws {
                    guard let other = try lookup(ref) else { report.skipped.append("“\(item.name)”: “\(ref)” isn’t a known skill, so that link was left out"); return }
                    do {
                        let before = try SkillRelation.fetchCount(d)
                        try CourseService.addRelation(d, from: parentIsRef ? other : me, to: parentIsRef ? me : other, kind: kind)
                        if try SkillRelation.fetchCount(d) > before { report.relationsAdded += 1 }
                    } catch CourseError.wouldCreateCycle { report.skipped.append("“\(item.name)”: linking “\(ref)” would create a cycle") }
                }
                if let p = item.parentRef { try link(p, kind: .hierarchy, parentIsRef: true) }
                for pre in item.prerequisiteRefs { try link(pre, kind: .prerequisite, parentIsRef: true) }
                for name in item.assessments {
                    guard let a = try Assessment.fetchOne(d, sql: "SELECT * FROM assessments WHERE courseId = ? AND lower(name) = lower(?)", arguments: [courseId, name]) else { continue }
                    if a.isCumulative { continue }                      // already covers the whole course
                    if try AssessmentSkill.fetchOne(d, key: ["assessmentId": a.id, "skillId": me]) == nil {
                        try AssessmentSkill(assessmentId: a.id, skillId: me, importance: nil, importanceSource: .unset).insert(d)
                        report.coverageAdded += 1
                    }
                }
            }
            try d.execute(sql: "UPDATE ai_task_batches SET status = ? WHERE id = ?", arguments: [BatchStatus.imported, batchId])
            return report
        }
    }
}

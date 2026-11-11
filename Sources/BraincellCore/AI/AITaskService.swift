import Foundation
import GRDB

public struct GenerationParams: Codable, Sendable, Equatable {
    public var count: Int
    public var types: [QuestionType]
    public var minDifficulty: Int
    public var maxDifficulty: Int
    public var skillIds: [UUID]
    public var documentIds: [UUID]
    public var includeExistingTitles: Bool
    public var notes: String
    /// Planning mode (nil = Broader Topic Practice). Decoding old params without it works.
    public var mode: GenerationMode?
    public init(count: Int = 10, types: [QuestionType] = [], minDifficulty: Int = 1, maxDifficulty: Int = 5,
                skillIds: [UUID] = [], documentIds: [UUID] = [], includeExistingTitles: Bool = true, notes: String = "", mode: GenerationMode? = nil) {
        self.mode = mode
        self.count = count; self.types = types; self.minDifficulty = minDifficulty; self.maxDifficulty = maxDifficulty
        self.skillIds = skillIds; self.documentIds = documentIds; self.includeExistingTitles = includeExistingTitles; self.notes = notes
    }
}

public enum AITaskError: Error, LocalizedError, Equatable {
    case notFound
    case invalidParams(String)
    case nothingToContinue
    case nothingToRepair
    // Import failures
    case responseTooLarge(Int)
    case malformedJSON(String)
    case notAnObject
    case unsupportedSchema(String?)
    case missingRequestId
    case requestMismatch(expected: String, found: String)
    case unknownRequest(String)
    case tooManyQuestions(Int)
    case missingQuestions
    case noTopics

    public var errorDescription: String? {
        switch self {
        case .notFound: "That AI task no longer exists."
        case .invalidParams(let m): m
        case .nothingToContinue: "Nothing is missing from this batch."
        case .nothingToRepair: "There are no rejected questions to repair."
        case .responseTooLarge(let mb): "The response is larger than \(mb) MB. Ask for fewer questions per batch."
        case .malformedJSON(let d): "That isn’t valid JSON (\(d)). Copy ChatGPT’s whole reply, or ask it to “return only the JSON object”. Your text was kept."
        case .notAnObject: "The response must be a single JSON object."
        case .unsupportedSchema(let v): "Unsupported schemaVersion \(v.map { "“\($0)”" } ?? "(missing)"). This version of Learn Anyway reads “\(QuestionSchema.version)”."
        case .missingRequestId: "The response has no requestId, so it can’t be matched to a request."
        case .requestMismatch(let e, let f): "This response answers a different request (\(f)); this batch expects \(e). Nothing was imported."
        case .unknownRequest(let f): "No request of yours has ID \(f). It may belong to another Learn Anyway library. Nothing was imported."
        case .tooManyQuestions(let n): "The response contains \(n) questions; the limit is \(AITaskService.maxQuestionsPerResponse)."
        case .missingQuestions: "The response has no “questions” array."
        case .noTopics: "The response has no usable skills. Nothing was changed."
        }
    }
}

public struct RejectedEntry: Codable, Sendable, Equatable {
    public var index: Int
    public var importId: String
    public var title: String?
    public var entryJSON: String
    public var issues: [ValidationIssue]
}

public struct AcceptedQuestion: Sendable, Equatable {
    public var importId: String
    public var questionId: UUID
    public var title: String
    public var readiness: Readiness
}

public struct ImportReport: Sendable {
    public var importId: UUID
    public var batchId: UUID
    /// True when this exact response had already been imported; nothing changed.
    public var alreadyImported: Bool
    public var accepted: [AcceptedQuestion]
    public var duplicates: [String]       // titles skipped as exact duplicates
    public var rejected: [RejectedEntry]
    public var batchStatus: BatchStatus
}

public enum TaskStatus: String, Sendable {
    case draft, awaitingImport, needsAttention, completed
}

/// Plans AI requests, tracks their lifecycle, and validates/commits responses. It never calls a network service:
/// the user moves text between Learn Anyway and ChatGPT by hand.
public struct AITaskService: Sendable {
    public static let maxResponseBytes = 2 * 1024 * 1024
    public static let maxQuestionsPerResponse = 50
    public static let maxQuestionsPerBatch = 10

    let db: AppDatabase
    public init(db: AppDatabase) { self.db = db }

    // MARK: Creating tasks

    /// Splits `params.count` into batches of at most 10 questions, each with its own request ID.
    /// Creates a generation task and its shared plan. Scope exclusions are enforced here, so AI Tasks and Home chat get the same behavior.
    @discardableResult
    public func createGenerationTask(courseId: UUID, assessmentId: UUID? = nil, params: GenerationParams) throws -> AITask {
        var p = params
        let scope = try AssessmentService(db: db).scope(courseId: courseId, assessmentId: assessmentId, requested: p.skillIds, tasks: self)
        if !p.skillIds.isEmpty || !scope.limitations.isEmpty { p.skillIds = scope.skillIds }       // narrowing only; the default path below is unchanged
        let task = try insertGenerationTask(courseId: courseId, assessmentId: assessmentId, params: p)
        try buildPlan(task: task, scope: scope)
        return task
    }

    func buildPlan(task: AITask, scope: AssessmentService.Scope) throws {
        let params = self.params(of: task)
        let skills = try db.read { d in try Skill.fetchAll(d, keys: params.skillIds).filter { $0.archivedAt == nil } }
        let counts: [UUID: Int] = try db.read { d in
            Dictionary(uniqueKeysWithValues: try Row.fetchAll(d, sql: "SELECT skillId, COUNT(*) c FROM question_skills qs JOIN questions q ON q.id = qs.questionId WHERE q.archivedAt IS NULL AND q.courseId = ? GROUP BY skillId", arguments: [task.courseId]).map { ($0["skillId"] as UUID, $0["c"] as Int) })
        }
        let mode = params.mode ?? .broaderTopics
        let weak = mode == .weakSkills ? Set(try GenerationPlanStore.weakTopicNames(db: db, courseId: task.courseId).map { $0.skillKey }) : []
        let docs = params.documentIds.isEmpty ? nil : Set(params.documentIds)
        let sources = try SourceAnalysisService(db: db, gateway: nil).sourceQuestions(courseId: task.courseId, documentIds: docs)
        let svc = AssessmentService(db: db)
        let profile = (mode == .matchInstructorStyle || mode == .similarReasoning) ? try svc.profile(courseId: task.courseId, assessmentId: task.assessmentId) : nil
        let cfg = try task.assessmentId.map { try svc.config(assessmentId: $0) } ?? AssessmentConfig()
        var plan = GenerationPlanner.plan(mode: mode, count: params.count, topics: skills.map { .init(name: $0.name, existingCount: counts[$0.id] ?? 0, weak: weak.contains($0.normalizedName)) },
                                          sources: sources, profile: profile, config: cfg, excluded: scope.excludedNames)
        plan.limitations += scope.limitations
        try GenerationPlanStore(db: db).save(plan, taskId: task.id)
    }

    @discardableResult
    func insertGenerationTask(courseId: UUID, assessmentId: UUID?, params: GenerationParams) throws -> AITask {
        guard (1...200).contains(params.count) else { throw AITaskError.invalidParams("Ask for between 1 and 200 questions.") }
        guard 1 <= params.minDifficulty, params.minDifficulty <= params.maxDifficulty, params.maxDifficulty <= 5 else {
            throw AITaskError.invalidParams("Difficulty must be within 1–5.")
        }
        return try db.write { d in
            guard let course = try Course.fetchOne(d, key: courseId) else { throw AITaskError.notFound }
            var p = params
            if let a = assessmentId, try Assessment.fetchOne(d, key: a)?.courseId != courseId { throw AITaskError.invalidParams("That assessment belongs to another course.") }
            if p.skillIds.isEmpty { // default scope: the assessment's skills, else the whole course
                if let a = assessmentId, let asm = try Assessment.fetchOne(d, key: a) {
                    p.skillIds = try Self.scopedSkillIds(d, asm)
                }
                if p.skillIds.isEmpty { p.skillIds = try UUID.fetchAll(d, sql: "SELECT skillId FROM course_skills JOIN skills ON skills.id = skillId WHERE courseId = ? AND archivedAt IS NULL", arguments: [courseId]) }
            }
            let title = "\(p.count) questions · \(course.name)"
            let task = AITask(id: UUID(), kind: .questionGeneration, courseId: courseId, assessmentId: assessmentId, title: title,
                              params: String(data: try JSONEncoder().encode(p), encoding: .utf8) ?? "{}", createdAt: Date())
            try task.insert(d)
            var remaining = p.count, ordinal = 0
            while remaining > 0 {
                let n = min(remaining, Self.maxQuestionsPerBatch)
                try Self.newBatch(d, taskId: task.id, parent: nil, ordinal: ordinal, kind: .generate, expected: n).insert(d)
                remaining -= n; ordinal += 1
            }
            return task
        }
    }

    static func scopedSkillIds(_ d: Database, _ a: Assessment) throws -> [UUID] {
        if a.isCumulative {
            return try UUID.fetchAll(d, sql: "SELECT skillId FROM course_skills JOIN skills ON skills.id = skillId WHERE courseId = ? AND archivedAt IS NULL", arguments: [a.courseId])
        }
        return try UUID.fetchAll(d, sql: "SELECT skillId FROM assessment_skills JOIN skills ON skills.id = skillId WHERE assessmentId = ? AND archivedAt IS NULL", arguments: [a.id])
    }

    static func blueprintText(_ plan: GenerationPlan, _ slots: [PlanSlot]) -> String {
        var t = "## Blueprint\nMode: \(plan.mode.title). Write exactly one question per slot and put the slot id in `metadata.provenance.slotId`.\n"
        t += "Originality: each question must change the substantive construction, context or reasoning application of any example. Swapping numbers or names is not enough. Never copy instructor text.\n"
        for s in slots {
            t += "- Slot \(s.id): topic “\(s.topic)”; archetype \(s.archetype); difficulty \(s.difficulty); format \(s.format)" + (s.reasoningSkill.map { "; reasoning skill: \($0)" } ?? "") + ". \(s.rationale)\n"
            if let e = s.exemplars.first { t += "    Technique to transfer (from \(e.document ?? "source")\(e.page.map { ", p.\($0)" } ?? "") \(e.locator ?? "")): \(s.exemplarSummary ?? "see source extract")\n" }
        }
        if !plan.excludedTopics.isEmpty { t += "Excluded topics (never write questions on or require these): " + plan.excludedTopics.joined(separator: ", ") + "\n" }
        if !plan.weakTargets.isEmpty { t += "The learner is weaker on these topics (names only): " + plan.weakTargets.joined(separator: ", ") + "\n" }
        for l in plan.limitations { t += "Note: \(l)\n" }
        return t
    }

    static func newBatch(_ d: Database, taskId: UUID, parent: UUID?, ordinal: Int, kind: BatchKind, expected: Int) -> AITaskBatch {
        AITaskBatch(id: UUID(), taskId: taskId, parentBatchId: parent, ordinal: ordinal, kind: kind,
                    requestId: "req-" + UUID().uuidString.lowercased(), expectedCount: expected, requestText: "", manifest: "{}",
                    transferMethod: nil, status: .draft, exportedAt: nil, createdAt: Date())
    }

    public func tasks() throws -> [AITask] { try db.read { try AITask.order(Column("createdAt").desc).fetchAll($0) } }
    public func batches(taskId: UUID) throws -> [AITaskBatch] {
        try db.read { try AITaskBatch.filter(Column("taskId") == taskId).order(Column("ordinal"), Column("createdAt")).fetchAll($0) }
    }
    public func imports(batchId: UUID) throws -> [AIImport] {
        try db.read { try AIImport.filter(Column("batchId") == batchId).order(Column("createdAt").desc).fetchAll($0) }
    }
    public func params(of task: AITask) -> GenerationParams {
        (try? JSONDecoder().decode(GenerationParams.self, from: Data(task.params.utf8))) ?? GenerationParams()
    }

    public func status(taskId: UUID) throws -> TaskStatus {
        let s = Set(try batches(taskId: taskId).map(\.status))
        if s.contains(.awaitingImport) { return .awaitingImport }
        if s.contains(.needsRepair) || s.contains(.incomplete) { return .needsAttention }
        if s.contains(.draft) { return .draft }
        return .completed
    }

    // MARK: Preparing and exporting

    /// Builds the request for a batch (and stores the text so it survives restarts). Safe to call repeatedly;
    /// the request ID never changes.
    @discardableResult
    public func prepare(batchId: UUID) throws -> RequestPackage {
        try db.write { d in
            guard var b = try AITaskBatch.fetchOne(d, key: batchId), let task = try AITask.fetchOne(d, key: b.taskId),
                  let course = try Course.fetchOne(d, key: task.courseId) else { throw AITaskError.notFound }
            if task.kind == .subjectiveGrading { return try Self.prepareGrading(d, batch: b, course: course) }
            if task.kind == .topicAnalysis { return try Self.prepareTopics(d, batch: b, task: task, course: course) }
            let params = self.params(of: task)
            let skills = try Skill.fetchAll(d, keys: params.skillIds).filter { $0.archivedAt == nil }.map(\.name).sorted()
            let assessment = try task.assessmentId.flatMap { try Assessment.fetchOne(d, key: $0) }

            var existing: [String] = []
            if params.includeExistingTitles {
                existing = try String.fetchAll(d, sql: """
                    SELECT r.title FROM questions q JOIN question_revisions r ON r.id = q.currentRevisionId
                    WHERE q.courseId = ? AND q.archivedAt IS NULL ORDER BY q.createdAt DESC LIMIT ?
                    """, arguments: [task.courseId, PromptBuilder.maxExistingTitles])
            }
            // Planned slots for this request (generate: its slice of the task-wide plan; continue: the first unmet slots).
            let plan = try GenerationPlanStore.load(d, taskId: task.id)
            var slots: [PlanSlot] = []
            if let plan, b.kind == .generate {
                let start = try Int.fetchOne(d, sql: "SELECT COALESCE(SUM(expectedCount), 0) FROM ai_task_batches WHERE taskId = ? AND kind = 'generate' AND ordinal < ?", arguments: [b.taskId, b.ordinal]) ?? 0
                slots = Array(plan.slots.dropFirst(start).prefix(b.expectedCount))
            } else if plan != nil, b.kind == .continue { slots = Array(try GenerationPlanStore.unmet(d, taskId: task.id).prefix(b.expectedCount)) }
            var docsForExtract: [(title: String, chunks: [DocumentChunk])] = []
            for docId in params.documentIds {
                guard let doc = try Document.fetchOne(d, key: docId), doc.courseId == task.courseId else { continue }
                docsForExtract.append((doc.title, try DocumentChunk.filter(Column("documentId") == docId && Column("isLowContent") == false).order(Column("ordinal")).fetchAll(d)))
            }
            let selected = ExtractSelector.select(docsForExtract, queries: slots.map(\.topic) + skills + [assessment?.name ?? ""], budget: PromptBuilder.extractBudget)
            let extracts = selected.extracts, truncated = selected.truncated

            var input = PromptInput(kind: b.kind, requestId: b.requestId, count: b.expectedCount, params: params,
                                    courseName: course.name, assessmentName: assessment?.name, skills: skills,
                                    existingTitles: existing, extracts: extracts, truncatedDocs: truncated,
                                    batchLabel: "")
            let siblings = try AITaskBatch.filter(Column("taskId") == b.taskId && Column("kind") == BatchKind.generate).fetchCount(d)
            if let plan, !slots.isEmpty { input.blueprint = Self.blueprintText(plan, slots); input.blueprintSlots = slots.count; input.mode = plan.mode.rawValue; input.weakTargets = plan.weakTargets; input.excludedTopics = plan.excludedTopics }
            input.batchLabel = b.kind == .generate ? "batch \(b.ordinal + 1) of \(siblings)" : "\(b.kind.rawValue) request"

            if b.kind == .repair, let parent = b.parentBatchId, let imp = try Self.latestImport(d, batchId: parent) {
                let rejected = (try? JSONDecoder().decode([RejectedEntry].self, from: Data(imp.rejectedEntries.utf8))) ?? []
                input.repair = rejected.map { .init(importId: $0.importId, entryJSON: $0.entryJSON, issues: $0.issues.map(\.description)) }
            }
            if b.kind == .continue, let parent = b.parentBatchId {
                input.alreadyHave = try String.fetchAll(d, sql: """
                    SELECT r.title FROM question_revisions r JOIN ai_imports i ON i.id = r.aiImportId WHERE i.batchId = ?
                    """, arguments: [parent])
            }
            let pkg = PromptBuilder.build(input)
            b.requestText = pkg.singlePrompt
            b.manifest = String(data: try JSONEncoder().encode(pkg.manifest), encoding: .utf8) ?? "{}"
            try b.update(d)
            return pkg
        }
    }

    /// Called only after the user explicitly copied or exported the request.
    public func markExported(batchId: UUID, method: TransferMethod) throws {
        try db.write { d in
            guard var b = try AITaskBatch.fetchOne(d, key: batchId) else { throw AITaskError.notFound }
            if b.status == .draft || b.status == .awaitingImport { b.status = .awaitingImport }
            b.transferMethod = method; b.exportedAt = Date()
            try b.update(d)
        }
    }

    public static func manifest(of batch: AITaskBatch) -> RequestManifest? {
        try? JSONDecoder().decode(RequestManifest.self, from: Data(batch.manifest.utf8))
    }

    /// Writes the package files into `folder` (which must already exist). File names are fixed and sanitized,
    /// so nothing can escape the folder.
    public static func write(_ files: [ExportFile], to folder: URL) throws {
        for f in files {
            guard !f.name.contains("/"), !f.name.contains(".."), !f.name.hasPrefix(".") else { continue }
            try f.content.write(to: folder.appendingPathComponent(f.name), atomically: true, encoding: .utf8)
        }
    }

    // MARK: Repair & continuation

    @discardableResult
    public func createRepairBatch(from batchId: UUID) throws -> AITaskBatch {
        try db.write { d in
            guard let parent = try AITaskBatch.fetchOne(d, key: batchId) else { throw AITaskError.notFound }
            guard parent.kind != .grade, parent.kind != .topics else { throw AITaskError.invalidParams(Self.gradeRetryMessage) }
            guard let imp = try Self.latestImport(d, batchId: batchId),
                  let rejected = try? JSONDecoder().decode([RejectedEntry].self, from: Data(imp.rejectedEntries.utf8)), !rejected.isEmpty
            else { throw AITaskError.nothingToRepair }
            let ord = (try Int.fetchOne(d, sql: "SELECT MAX(ordinal) FROM ai_task_batches WHERE taskId = ?", arguments: [parent.taskId]) ?? 0) + 1
            let b = Self.newBatch(d, taskId: parent.taskId, parent: batchId, ordinal: ord, kind: .repair, expected: rejected.count)
            try b.insert(d)
            return b
        }
    }

    @discardableResult
    public func createContinuationBatch(from batchId: UUID) throws -> AITaskBatch {
        try db.write { d in
            guard let parent = try AITaskBatch.fetchOne(d, key: batchId) else { throw AITaskError.notFound }
            guard parent.kind != .grade, parent.kind != .topics else { throw AITaskError.invalidParams(Self.gradeRetryMessage) }
            let returned = try Self.latestImport(d, batchId: batchId)?.returnedCount ?? 0
            let remaining = parent.expectedCount - returned
            guard remaining > 0 else { throw AITaskError.nothingToContinue }
            let ord = (try Int.fetchOne(d, sql: "SELECT MAX(ordinal) FROM ai_task_batches WHERE taskId = ?", arguments: [parent.taskId]) ?? 0) + 1
            let b = Self.newBatch(d, taskId: parent.taskId, parent: batchId, ordinal: ord, kind: .continue, expected: remaining)
            try b.insert(d)
            return b
        }
    }

    static let gradeRetryMessage = "Grading and topic requests can’t be repaired or continued. Create a new request instead."

    static func latestImport(_ d: Database, batchId: UUID) throws -> AIImport? {
        try AIImport.filter(Column("batchId") == batchId && Column("outcome") == ImportOutcomeKind.imported)
            .order(Column("createdAt").desc).fetchOne(d)
    }
}

import Foundation
import GRDB

/// Tools that change app data. Each requires user approval (the runner enforces it before `run` is ever called) and is idempotent by design:
/// creating something that already exists returns the existing record instead of a duplicate.
extension AgentRegistry {
    static let writes: [ToolSpec] = [
        ToolSpec(name: "courses.create", summary: "Create a course (reuses an existing course with the same name).", params: [ToolParam("name", "string", "Course name, e.g. COMP301", required: true)], permission: .write, approval: true,
                 describe: { a, _ in "Create the course “\(a.string("name") ?? "")”" }) { a, c, _ in
            let name = try a.require("name")
            if let existing = try c.courses.courses().first(where: { AgentContext.norm($0.name) == AgentContext.norm(name) }) {
                return ToolOutput(text: "A course named “\(existing.name)” already exists (id \(existing.id.uuidString)); nothing was created.", summary: "Already exists: \(existing.name)", chips: [ActionChip(label: "Open \(existing.name)", action: "openCourse", courseId: existing.id)])
            }
            let created = try c.courses.createCourse(name: name)
            return ToolOutput(text: "Created course “\(created.name)” (id \(created.id.uuidString)).", summary: "Created \(created.name)", chips: [ActionChip(label: "Open \(created.name)", action: "openCourse", courseId: created.id)])
        },
        ToolSpec(name: "quickCram.start", summary: "Start a Quick Cram: a lightweight course for one topic (reuses an existing one with the same name).", params: [ToolParam("topic", "string", "The single topic to cram", required: true)], permission: .write, approval: true,
                 describe: { a, _ in "Start a Quick Cram on “\(a.string("topic") ?? "")”" }) { a, c, _ in
            let topic = try a.require("topic")
            if let ex = try c.courses.courses().first(where: { AgentContext.norm($0.name) == AgentContext.norm(topic) }) {
                return ToolOutput(text: "“\(ex.name)” already exists (id \(ex.id.uuidString)); nothing was created.", summary: "Already exists", chips: [ActionChip(label: "Open \(ex.name)", action: "openCourse", courseId: ex.id)])
            }
            let made = try c.courses.startQuickCram(topic: topic)
            return ToolOutput(text: "Created Quick Cram “\(made.name)” (id \(made.id.uuidString)). It has no materials or questions yet.", summary: "Quick Cram: \(made.name)", chips: [ActionChip(label: "Open \(made.name)", action: "openCourse", courseId: made.id)])
        },
        ToolSpec(name: "courses.rename", summary: "Rename a course.", params: [ToolParam("course", "string", "Current name or id", required: true), ToolParam("newName", "string", "New name", required: true)], permission: .write, approval: true,
                 describe: { a, _ in "Rename “\(a.string("course") ?? "")” to “\(a.string("newName") ?? "")”" }) { a, c, _ in
            let course = try c.course(try a.require("course")); let n = try a.require("newName")
            try c.courses.renameCourse(course.id, to: n)
            return ToolOutput(text: "Renamed “\(course.name)” to “\(n)”.", summary: "Renamed to \(n)")
        },
        ToolSpec(name: "courses.delete", summary: "Delete a course. It moves to Recently Deleted for seven days and can be restored.", params: [ToolParam("course", "string", "Course name or id", required: true)], permission: .destructive, approval: true,
                 describe: { a, _ in "Delete the course “\(a.string("course") ?? "")” (recoverable from Recently Deleted for seven days)" }) { a, c, _ in
            let course = try c.course(try a.require("course"))
            try c.library.deleteCourse(course.id)
            return ToolOutput(text: "Moved “\(course.name)” to Recently Deleted. It can be restored for seven days.", summary: "Deleted \(course.name)", chips: [ActionChip(label: "Open Library", action: "openLibrary")])
        },
        ToolSpec(name: "assessments.create", summary: "Add an assessment (exam, quiz…) to a course.", params: [ToolParam("course", "string", "Course name or id", required: true), ToolParam("name", "string", "e.g. Midterm 2", required: true), ToolParam("kind", "string", "midterm | final | quiz | assignment | other"), ToolParam("deadline", "string", "Date yyyy-MM-dd (resolve relative dates yourself from today's date)"), ToolParam("cumulative", "boolean", "Covers the whole course")], permission: .write, approval: true,
                 describe: { a, _ in "Add “\(a.string("name") ?? "")” to \(a.string("course") ?? "")\(a.string("deadline").map { ", due \($0)" } ?? "")" }) { a, c, _ in
            let course = try c.course(try a.require("course")); let name = try a.require("name")
            if let ex = try c.courses.assessments(courseId: course.id).first(where: { AgentContext.norm($0.name) == AgentContext.norm(name) }) {
                return ToolOutput(text: "“\(ex.name)” already exists in \(course.name)\(ex.deadline.map { " (due \(c.fmt($0)))" } ?? ""); nothing was created.", summary: "Already exists: \(ex.name)")
            }
            let kind = a.string("kind").flatMap { AssessmentKind(rawValue: $0.lowercased()) } ?? .midterm
            let made = try c.courses.addAssessment(courseId: course.id, name: name, kind: kind, deadline: try a.date("deadline", calendar: c.calendar), isCumulative: a.bool("cumulative") ?? false)
            return ToolOutput(text: "Added assessment “\(made.name)” to \(course.name)\(made.deadline.map { ", due \(c.fmt($0))" } ?? "").", summary: "Added \(made.name)")
        },
        ToolSpec(name: "materials.attachToCourse", summary: "Move existing Library files into a course's Materials.", params: [ToolParam("documentIds", "array<string>", "Document ids from library.search", required: true), ToolParam("course", "string", "Course name or id", required: true)], permission: .write, approval: true,
                 describe: { a, _ in "Move \(a.strings("documentIds").count) file(s) into \(a.string("course") ?? "")" }) { a, c, _ in
            let course = try c.course(try a.require("course"))
            let ids = a.strings("documentIds").compactMap(UUID.init)
            guard !ids.isEmpty else { throw ToolError.invalid("No valid document ids.") }
            let known = Set(try c.db.read { try UUID.fetchAll($0, sql: "SELECT id FROM documents WHERE deletedAt IS NULL AND id IN (\(ids.map { _ in "?" }.joined(separator: ",")))", arguments: StatementArguments(ids)) })
            guard known.count == ids.count else { throw ToolError.notFound("Some documents don’t exist. Use library.search for valid ids.") }
            try c.library.move(ids.map { LibraryRef(id: $0, kind: .other) }, to: .course(course.id))
            return ToolOutput(text: "Moved \(ids.count) file(s) into \(course.name). They are now in both Materials and Library.", summary: "Attached \(ids.count) file(s)", chips: [ActionChip(label: "Open \(course.name)", action: "openCourse", courseId: course.id)])
        },
        ToolSpec(name: "questions.generate", summary: "Draft practice questions from the course's readable materials with the configured model. Nothing is saved until the learner approves the preview.",
                 params: [ToolParam("course", "string", "Course name or id", required: true), ToolParam("assessment", "string", "Assessment name (optional)"), ToolParam("count", "integer", "1–30"), ToolParam("minDifficulty", "integer", "1–5"), ToolParam("maxDifficulty", "integer", "1–5"), ToolParam("notes", "string", "Focus or style notes")], permission: .write, approval: true,
                 describe: { a, c in
                     let p = (try? c.gateway.resolve(WorkflowTask.find("quizGeneration")!))?.primary?.connection
                     let where_ = p == nil ? "the configured model" : (p!.spec?.isLocal == true ? "\(p!.name) (stays on this Mac)" : "\(p!.name) (excerpts of your course materials are sent there and may be billed)")
                     return "Generate up to \(min(30, max(1, a.int("count") ?? 10))) practice questions for \(a.string("course") ?? "the course") using \(where_). You will see a preview before anything is saved."
                 }, run: generate),
        ToolSpec(name: "questions.save", summary: "Save a previewed question set into the Question Bank.", params: [ToolParam("generationId", "string", "Id returned by questions.generate", required: true)], permission: .write, approval: true,
                 describe: { _, _ in "Save the previewed questions to the Question Bank" }, run: { a, c, _ in try await save(generationId: try a.uuid("generationId") ?? { throw ToolError.invalid("generationId must be the id from questions.generate.") }(), c) }),
        ToolSpec(name: "studyPlans.create", summary: "Build and save a day-by-day plan from the course's real questions and measured mastery (existing planner). Resolve dates from today's date before calling.",
                 params: [ToolParam("course", "string", "Course name or id", required: true), ToolParam("assessment", "string", "Assessment name (optional)"), ToolParam("title", "string", "Plan title"), ToolParam("dueDate", "string", "Exam date yyyy-MM-dd"), ToolParam("startDate", "string", "yyyy-MM-dd, default today"), ToolParam("minutesPerDay", "integer", "Study minutes per day, 10–480")], permission: .write, approval: false,
                 describe: { a, _ in "Create a study plan for \(a.string("course") ?? "")" }, run: createPlan),
    ]

    // MARK: Generation → preview → save

    public struct GenerationResult: Codable, Sendable {
        public struct Batch: Codable, Sendable { public var batchId: UUID; public var raw: String }
        public struct Item: Codable, Sendable { public var title: String; public var type: String; public var difficulty: Int; public var valid: Bool; public var issue: String? }
        public var courseId: UUID; public var batches: [Batch]; public var items: [Item]; public var saved: Bool = false; public var savedSummary: String?
    }

    @Sendable static func generate(_ a: ToolArgs, _ c: AgentContext, _ info: ToolRunInfo) async throws -> ToolOutput {
        let course = try c.course(try a.require("course")); let asm = try c.assessment(a.string("assessment"), in: course)
        let readable = try c.docs.documents(courseId: course.id).filter { ($0.kind == .pdf || $0.kind == .text || $0.kind == .pasted) && $0.extractionStatus != .failed }
        let skills = try c.courses.skills(courseId: course.id)
        guard !readable.isEmpty || !skills.isEmpty else { throw ToolError.unavailable("\(course.name) has no readable materials and no topics, so there is nothing to base questions on. Ask the learner to add lecture notes or a syllabus first.") }
        let lo = min(5, max(1, a.int("minDifficulty") ?? 1)), hi = min(5, max(lo, a.int("maxDifficulty") ?? 5))
        var notes = a.string("notes") ?? "", docIds = readable.prefix(12).map(\.id)
        // A saved study map steers generation: its cited documents come first, and each example's structure and extra step are required to carry over.
        if let d = (try c.store.maps(courseId: course.id, conversationId: info.conversationId).first ?? c.store.maps(courseId: course.id).first)?.document {
            let cited = Set(d.topics.flatMap(\.sources).map(\.documentId) + d.structures.map(\.source.documentId))
            if !cited.isEmpty { docIds = Array((readable.filter { cited.contains($0.id) } + readable.filter { !cited.contains($0.id) }).prefix(12).map(\.id)) }
            if !d.structures.isEmpty {
                notes += "\n\nSOURCE PROBLEM STRUCTURES (from the learner's own material). Each new question must be ORIGINAL and keep the learning objective, solution structure, constraints, difficulty and the distinguishing extra step of one of these, changing the context, givens and numbers (not a reworded copy). Include progressive hints and a worked solution, and name the source example it mirrors:\n"
                notes += d.structures.prefix(12).map { "- \($0.family) [\($0.source.documentName)\($0.source.page.map { " p.\($0)" } ?? "")]: objective \($0.objective); givens \($0.givens.joined(separator: ", ")); unknowns \($0.unknowns.joined(separator: ", ")); method \($0.method); EXTRA STEP: \($0.extraStep); common mistakes: \($0.commonMistakes.joined(separator: ", "))" }.joined(separator: "\n")
            }
            let weighted = d.topics.filter { $0.importance.source == .instructor }.map { "\($0.name) (\($0.importance.level)\($0.importance.weightPercent.map { " \(Int($0))%" } ?? ""))" }
            if !weighted.isEmpty { notes += "\nInstructor-stated priorities: " + weighted.joined(separator: ", ") + ". Do not invent other weights." }
            notes = String(notes.prefix(6000))
        }
        let params = GenerationParams(count: min(30, max(1, a.int("count") ?? 10)), minDifficulty: lo, maxDifficulty: hi, documentIds: docIds, notes: notes)
        let task = try c.ai.createGenerationTask(courseId: course.id, assessmentId: asm?.id, params: params)
        var result = GenerationResult(courseId: course.id, batches: [], items: [])
        for b in try c.ai.batches(taskId: task.id) {
            try Task.checkCancellation()
            let pkg = try c.ai.prepare(batchId: b.id)
            info.stage("Generating practice")
            let out = try await c.gateway.complete(task: WorkflowTask.find("quizGeneration")!, prompt: pkg.singlePrompt, courseId: course.id)
            result.batches.append(.init(batchId: b.id, raw: out.text))
            info.stage("Validating results")
            guard let env = AITaskService.parse(out.text) as? [String: Any], let entries = env["questions"] as? [Any] else {
                result.items.append(.init(title: "Reply for batch \(b.ordinal + 1) wasn’t valid question JSON", type: "-", difficulty: 0, valid: false, issue: "Unreadable reply; it will not be saved.")); continue
            }
            for (i, e) in entries.enumerated() {
                let v = QuestionValidator.validate(entry: e, index: i)
                if v.hasBlocking || v.question == nil { result.items.append(.init(title: ((e as? [String: Any])?["title"] as? String) ?? "Question \(i + 1)", type: "-", difficulty: 0, valid: false, issue: v.issues.first { $0.severity == .blocking }?.description)) }
                else if let q = v.question { result.items.append(.init(title: q.spec.title, type: q.spec.type.rawValue, difficulty: q.spec.difficulty, valid: true, issue: nil)) }
            }
        }
        let enc = String(data: try JSONEncoder().encode(result), encoding: .utf8) ?? "{}"
        try c.store.setStatus(info.actionId, .running, result: enc)
        let ok = result.items.filter(\.valid).count
        return ToolOutput(text: "Drafted \(result.items.count) question(s); \(ok) valid, \(result.items.count - ok) rejected by validation. Validation was STRUCTURAL (schema, required fields); the answers were NOT independently verified, so say so and don’t call them verified. NOTHING is saved yet. The learner sees a preview with Save/Discard buttons. generationId=\(info.actionId.uuidString)\n" + result.items.prefix(30).map { "- \($0.title) [\($0.type), d\($0.difficulty)]\($0.valid ? "" : " REJECTED: \($0.issue ?? "")")" }.joined(separator: "\n"),
                          summary: "\(ok) question(s) drafted", generationId: info.actionId)
    }

    /// Commits a previewed generation through the existing import (validation, duplicate detection, atomic commit). Safe to call twice.
    @Sendable static func save(generationId: UUID, _ c: AgentContext) async throws -> ToolOutput {
        guard let act = try c.store.action(generationId), act.tool == "questions.generate", let data = act.result?.data(using: .utf8),
              var g = try? JSONDecoder().decode(GenerationResult.self, from: data) else { throw ToolError.notFound("No drafted question set with that id.") }
        if g.saved { return ToolOutput(text: g.savedSummary ?? "Already saved.", summary: "Already saved") }
        var accepted = 0, dup = 0, rejected = 0
        for b in g.batches {
            do { let r = try c.ai.importResponse(b.raw, targetBatchId: b.batchId); accepted += r.accepted.count; dup += r.duplicates.count; rejected += r.rejected.count }
            catch { rejected += 1 }
        }
        let summary = "Saved \(accepted) question(s) to the Question Bank\(dup > 0 ? ", skipped \(dup) duplicate(s)" : "")\(rejected > 0 ? ", \(rejected) rejected by validation" : ""). They are marked Unverified until reviewed."
        g.saved = true; g.savedSummary = summary
        try c.store.setStatus(generationId, .succeeded, result: String(data: try JSONEncoder().encode(g), encoding: .utf8))
        return ToolOutput(text: summary, summary: "Saved \(accepted) question(s)", chips: [ActionChip(label: "Open Question Bank", action: "openQuestionBank", courseId: g.courseId), ActionChip(label: "Practice", action: "startPractice", courseId: g.courseId)])
    }

    // MARK: Study plan

    @Sendable static func createPlan(_ a: ToolArgs, _ c: AgentContext, _ info: ToolRunInfo) async throws -> ToolOutput {
        let course = try c.course(try a.require("course")); let asm = try c.assessment(a.string("assessment"), in: course)
        let cal = c.calendar, today = cal.startOfDay(for: c.now())
        let start = try a.date("startDate", calendar: cal).map { max($0, today) } ?? today
        let due = try a.date("dueDate", calendar: cal) ?? asm?.deadline.map { cal.startOfDay(for: $0) }
        var notes: [String] = []
        var count = 7
        if let due {
            let d = cal.dateComponents([.day], from: start, to: due).day ?? 0
            if d <= 0 { count = 1; notes.append("The exam date is today or already passed, so this is a single cram day.") } else { count = min(28, d) }
            if d > 28 { notes.append("The exam is \(d) days away; the plan covers the first 28 days. Ask for a new plan closer to the date.") }
        } else { notes.append("No exam date was given, so this is a 7-day plan.") }
        let minutes = min(480, max(10, a.int("minutesPerDay") ?? 45))
        let total = try c.questions.list({ var f = QuestionFilter(); f.courseId = course.id; return f }()).count
        if total == 0 { notes.append("The Question Bank for this course is empty, so there are no practice questions to schedule yet. Generate questions first, then rebuild the plan.") }
        let skills = try c.courses.skills(courseId: course.id)
        if skills.isEmpty { notes.append("No topics are recorded for this course; the plan can only use questions, not topic scope.") }
        // An assessment with no topics assigned has no scope to plan against (the planner would find nothing). Say so and plan over the whole course.
        let scoped = try asm.map { try c.courses.scopedSkills(assessmentId: $0.id) } ?? []
        let useScope = asm != nil && (asm!.isCumulative || !scoped.isEmpty)
        if let asm, !useScope { notes.append("“\(asm.name)” has no topics assigned yet, so I can’t tell which topics it covers. This plan draws from all topics in \(course.name); please confirm the exam scope.") }
        var used = Set<UUID>(), days: [StudyPlanDocument.Day] = []
        for i in 0..<count {
            let date = cal.date(byAdding: .day, value: i, to: start)!, left = count - i
            var req = PlanRequest(courseId: course.id, assessmentId: useScope ? asm?.id : nil, mode: (useScope && left <= 2) ? .cram : .mastery, budgetMinutes: minutes)
            req.excludedQuestionIds = used; req.now = date
            let plan = try? c.planner.plan(req)
            let items = (plan?.items ?? []).map { StudyPlanDocument.Item(questionId: $0.questionId, title: $0.title, type: $0.type.rawValue, minutes: $0.estimatedMinutes, reason: $0.reason) }
            used.formUnion(items.map(\.questionId))
            let note = left == 1 && due != nil ? "Last day before the exam: light, cumulative review and rest." : (i > 0 && i % 3 == 2 ? "Review checkpoint: revisit anything you got wrong earlier." : "")
            days.append(.init(date: date, label: c.fmt(date), minutes: Int(items.reduce(0) { $0 + $1.minutes }.rounded()), focus: (plan?.skills ?? []).prefix(3).map { $0.skill.name }, items: items, note: note))
        }
        let doc = StudyPlanDocument(courseName: course.name, assessmentName: asm?.name, days: days, notes: notes, topics: skills.prefix(30).map(\.name))
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601
        let json = String(data: try enc.encode(doc), encoding: .utf8) ?? "{}"
        let title = a.string("title") ?? "\(asm?.name ?? "Study") plan · \(course.name)"
        let rec: StudyPlanRecord = try c.db.write { d in
            if var ex = try StudyPlanRecord.filter(Column("courseId") == course.id && Column("title") == title).fetchOne(d) {
                ex.planJSON = json; ex.dueDate = due; ex.assessmentId = asm?.id; ex.updatedAt = c.now(); try ex.update(d); return ex
            }
            let r = StudyPlanRecord(id: UUID(), conversationId: info.conversationId, courseId: course.id, assessmentId: asm?.id, title: title, dueDate: due, planJSON: json, createdAt: c.now(), updatedAt: c.now())
            try r.insert(d); return r
        }
        let questions = doc.totalQuestions
        return ToolOutput(text: "Saved study plan “\(title)” [plan \(rec.id.uuidString)]: \(days.count) day(s), \(questions) scheduled question(s) from \(total) in the bank, \(minutes) min/day. " + notes.joined(separator: " ") + "\n" + days.prefix(14).enumerated().map { "day \($0.offset + 1) \($0.element.label): \($0.element.items.count) q, focus: \($0.element.focus.joined(separator: ", "))" }.joined(separator: "\n"),
                          summary: "Plan saved · \(days.count) days", planId: rec.id,
                          chips: questions > 0 ? [ActionChip(label: "Start today’s practice", action: "startPractice", courseId: course.id, planId: rec.id, dayIndex: 0)] : [])
    }
}

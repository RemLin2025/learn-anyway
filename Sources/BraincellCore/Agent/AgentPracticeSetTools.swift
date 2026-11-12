import Foundation
import GRDB

extension AgentRegistry {
    static let practiceSetTools: [ToolSpec] = [
        ToolSpec(name: "practiceSets.list", summary: "List the saved practice sets for a course or assessment: how many questions each has, how many were reused versus newly generated, and whether any slots are still empty. Reading never calls a model.",
                 params: [ToolParam("course", "string", "Course name or id", required: true), ToolParam("assessment", "string", "Assessment name or id (optional)")], permission: .read, approval: false,
                 describe: { a, _ in "List practice sets for \(a.string("course") ?? "the course")" }, run: listSets),
        ToolSpec(name: "practiceSets.create", summary: "Create a practice set. Existing compatible questions are reused; only missing ones are generated (one model call per batch). Asking for fresh=true never reuses questions already served or attempted. Repeating an identical request returns the same set. The set can then be opened as interactive practice, guided learning, flashcards or a printable PDF worksheet without regenerating anything.",
                 params: [ToolParam("course", "string", "Course name or id", required: true), ToolParam("assessment", "string", "Assessment name or id (optional)"), ToolParam("count", "integer", "Number of questions (1–30)"),
                          ToolParam("topics", "array", "Topic names to include (optional)"), ToolParam("minDifficulty", "integer", "1–5"), ToolParam("maxDifficulty", "integer", "1–5"), ToolParam("format", "string", "Question format, e.g. single_choice, numeric, short_answer"),
                          ToolParam("fresh", "boolean", "true = only new questions"), ToolParam("mode", "string", "matchInstructorStyle | similarReasoning | broaderTopics | weakSkills")],
                 permission: .write, approval: true, describe: { a, _ in "Create a \(a.int("count") ?? 10)-question practice set in \(a.string("course") ?? "the course")" + (a.bool("fresh") == true ? " with all-new questions" : "") }, run: createSet),
        ToolSpec(name: "practiceSets.resume", summary: "Finish a practice set whose generation was interrupted or incomplete. Sends only the missing batches; a complete set makes no model call.",
                 params: [ToolParam("set", "string", "Practice set id", required: true)], permission: .write, approval: true, describe: { _, _ in "Finish generating the practice set" }, run: resumeSet),
        ToolSpec(name: "practiceSets.open", summary: "Open a saved practice set for the learner and show how it can be presented. No model call.",
                 params: [ToolParam("set", "string", "Practice set id", required: true)], permission: .read, approval: false, describe: { _, _ in "Open the practice set" }, run: openSet),
        ToolSpec(name: "templates.list", summary: "List learning templates (built-in and the learner's own) with their supported question formats.",
                 params: [], permission: .read, approval: false, describe: { _, _ in "List learning templates" }, run: listTemplates),
    ]

    static func setLine(_ s: PracticeSet, _ it: [PracticeSetItem]) -> String {
        let filled = it.filter { $0.questionId != nil }.count, reused = it.filter { $0.origin == "reused" }.count
        return "- \(s.title) (id \(s.id.uuidString)): \(filled)/\(it.count) questions, \(reused) reused, \(filled - reused) generated" + (filled < it.count ? "; \(it.count - filled) still to generate" : "") + (s.fresh ? "; fresh" : "")
    }

    @Sendable static func listSets(_ a: ToolArgs, _ c: AgentContext, _ info: ToolRunInfo) async throws -> ToolOutput {
        let course = try c.course(try a.require("course")); let asm = try c.assessment(a.string("assessment"), in: course)
        let sets = try c.practiceSets.sets(courseId: course.id).filter { asm == nil || $0.assessmentId == asm!.id }
        guard !sets.isEmpty else { return ToolOutput(text: "No practice sets yet for \(asm?.name ?? course.name). Offer to create one.", summary: "0 sets") }
        return ToolOutput(text: sets.prefix(20).map { setLine($0, (try? c.practiceSets.items(setId: $0.id)) ?? []) }.joined(separator: "\n"), summary: "\(sets.count) sets",
                          chips: sets.prefix(3).map { ActionChip(label: "Open " + $0.title, action: "openPracticeSet", courseId: course.id, assessmentId: $0.assessmentId, setId: $0.id) })
    }

    @Sendable static func createSet(_ a: ToolArgs, _ c: AgentContext, _ info: ToolRunInfo) async throws -> ToolOutput {
        let course = try c.course(try a.require("course")); let asm = try c.assessment(a.string("assessment"), in: course)
        let lo = min(5, max(1, a.int("minDifficulty") ?? 1)), hi = min(5, max(lo, a.int("maxDifficulty") ?? 5))
        var skillIds: [UUID] = []
        let topics = a.strings("topics")
        if !topics.isEmpty {
            let all = try c.courses.skills(courseId: course.id)
            for t in topics {
                guard let s = all.first(where: { AgentContext.norm($0.name) == AgentContext.norm(t) }) ?? all.first(where: { AgentContext.norm($0.name).contains(AgentContext.norm(t)) }) else {
                    throw ToolError.notFound("No topic matches “\(t)”. Topics in this course: " + all.prefix(25).map(\.name).joined(separator: ", ") + ".")
                }
                skillIds.append(s.id)
            }
        }
        var types: [QuestionType] = []
        if let f = a.string("format") { guard let t = QuestionType(rawValue: f) else { throw ToolError.invalid("Unknown format “\(f)”. Use one of: " + QuestionType.allCases.map(\.rawValue).joined(separator: ", ") + ".") }; types = [t] }
        let params = GenerationParams(count: min(30, max(1, a.int("count") ?? 10)), types: types, minDifficulty: lo, maxDifficulty: hi, skillIds: skillIds, documentIds: [], mode: a.string("mode").flatMap(GenerationMode.init(rawValue:)))
        info.stage("Planning practice set")
        let prepared = try c.practiceSets.prepare(courseId: course.id, assessmentId: asm?.id, params: params, fresh: a.bool("fresh") ?? false)
        info.stage(prepared.missing > 0 ? "Generating \(prepared.missing) new question(s)" : "Reusing saved questions")
        let r = try await c.practiceSets.generateMissing(setId: prepared.set.id, gateway: c.gateway)
        let items = try c.practiceSets.items(setId: prepared.set.id)
        let txt = "\(prepared.alreadyExisted ? "This request already had a set, so it was reopened. " : "")Practice set “\(prepared.set.title)” (id \(prepared.set.id.uuidString)): \(items.filter { $0.questionId != nil }.count)/\(items.count) questions ready; \(prepared.reused) reused from earlier practice, \(r.modelCalls) model call(s) made for new ones."
            + (r.missing > 0 ? " \(r.missing) slot(s) are still empty; offer to resume." : "")
            + " Generated questions are structurally validated only unless a math check ran; do not call them verified."
        return ToolOutput(text: txt, summary: "Set: \(items.count) questions", chips: [ActionChip(label: "Open practice set", action: "openPracticeSet", courseId: course.id, assessmentId: asm?.id, setId: prepared.set.id)])
    }

    static func setId(_ a: ToolArgs) throws -> UUID { guard let id = UUID(uuidString: try a.require("set")) else { throw ToolError.invalid("That is not a practice set id.") }; return id }

    @Sendable static func resumeSet(_ a: ToolArgs, _ c: AgentContext, _ info: ToolRunInfo) async throws -> ToolOutput {
        let id = try setId(a); guard let s = try c.practiceSets.practiceSet(id) else { throw ToolError.notFound("No such practice set.") }
        info.stage("Finishing the practice set")
        let r = try await c.practiceSets.generateMissing(setId: id, gateway: c.gateway)
        return ToolOutput(text: r.modelCalls == 0 && r.missing == 0 ? "The set was already complete; no model call was needed." : "Made \(r.modelCalls) model call(s); \(r.missing) slot(s) still empty.", summary: r.missing == 0 ? "Set complete" : "\(r.missing) missing",
                          chips: [ActionChip(label: "Open practice set", action: "openPracticeSet", courseId: s.courseId, assessmentId: s.assessmentId, setId: id)])
    }

    @Sendable static func openSet(_ a: ToolArgs, _ c: AgentContext, _ info: ToolRunInfo) async throws -> ToolOutput {
        let id = try setId(a); guard let s = try c.practiceSets.practiceSet(id) else { throw ToolError.notFound("No such practice set.") }
        let it = try c.practiceSets.items(setId: id)
        let ts = try c.templates.all(courseId: s.courseId).map(\.name).joined(separator: ", ")
        return ToolOutput(text: setLine(s, it) + "\nIt can be presented with: \(ts). Switching presentation never regenerates questions.", summary: "Opened set",
                          chips: [ActionChip(label: "Open practice set", action: "openPracticeSet", courseId: s.courseId, assessmentId: s.assessmentId, setId: id)])
    }

    @Sendable static func listTemplates(_ a: ToolArgs, _ c: AgentContext, _ info: ToolRunInfo) async throws -> ToolOutput {
        let ts = try c.templates.all()
        return ToolOutput(text: ts.map { "- \($0.name) [\($0.kind.title)\($0.isBuiltIn ? ", built-in" : "")]: \($0.description) Formats: \($0.supportedFormats.joined(separator: ", "))." }.joined(separator: "\n"), summary: "\(ts.count) templates")
    }
}

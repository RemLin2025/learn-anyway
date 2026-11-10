import Foundation

/// A real, executed flow. Every pipeline here mirrors code that exists in the app (the `source` names it), so the
/// workflow view never invents a sequence. Tasks that no pipeline runs are listed separately as "not wired into a flow".
public struct PipelineStep: Identifiable, Hashable, Sendable {
    public enum Kind: Hashable, Sendable {
        /// A step that calls a model through the gateway (`WorkflowTask.id`).
        case model(String)
        /// A step that runs locally with no model (parsing, validation, saving, your approval).
        case local(title: String, detail: String)
    }
    public let id: String
    public let kind: Kind
    public let after: [String]
    public let optional: Bool
    /// Plain-language note such as "repeats up to 6 times per message".
    public let note: String?
    /// True for steps that wait for the learner.
    public let needsApproval: Bool
    public var title: String {
        switch kind { case .model(let t): WorkflowTask.find(t)?.title ?? t; case .local(let t, _): t }
    }
}

public struct WorkflowPipeline: Identifiable, Hashable, Sendable {
    public let id: String
    public let title: String
    public let summary: String
    public let source: String
    public let steps: [PipelineStep]

    /// Steps grouped by depth; steps in one layer don't depend on each other and could run side by side.
    public var layers: [[PipelineStep]] {
        var depth: [String: Int] = [:]
        let byId = Dictionary(uniqueKeysWithValues: steps.map { ($0.id, $0) })
        func d(_ s: PipelineStep) -> Int {
            if let x = depth[s.id] { return x }
            let v = (s.after.compactMap { byId[$0] }.map(d).max() ?? -1) + 1
            depth[s.id] = v; return v
        }
        let layered = Dictionary(grouping: steps, by: d)
        return layered.keys.sorted().map { layered[$0]! }
    }
    public var modelTaskIds: [String] { steps.compactMap { if case .model(let t) = $0.kind { t } else { nil } } }

    static func m(_ task: String, after: [String] = [], optional: Bool = false, note: String? = nil) -> PipelineStep {
        PipelineStep(id: task, kind: .model(task), after: after, optional: optional, note: note, needsApproval: false)
    }
    static func l(_ id: String, _ title: String, _ detail: String, after: [String] = [], approval: Bool = false, note: String? = nil) -> PipelineStep {
        PipelineStep(id: id, kind: .local(title: title, detail: detail), after: after, optional: false, note: note, needsApproval: approval)
    }

    public static let all: [WorkflowPipeline] = [
        WorkflowPipeline(id: "questions", title: "Generate Practice Questions",
            summary: "Turns your course materials and topics into reviewed questions in the Question Bank.",
            source: "AgentWriteTools.generate / save, AITaskService",
            steps: [
                l("read", "Read course materials", "Extracted document text (or the course topics when no text exists)."),
                m("quizGeneration", after: ["read"], note: "One request per batch of up to 10 questions."),
                l("validate", "Validate & preview", "Every question is checked against the question schema; invalid ones are flagged, not saved.", after: ["quizGeneration"]),
                l("approve", "You approve", "Nothing is saved until you press Save.", after: ["validate"], approval: true),
                l("save", "Save to Question Bank", "Imported atomically with duplicate detection.", after: ["approve"]),
            ]),
        WorkflowPipeline(id: "chat", title: "Chat Assistant",
            summary: "The Home chat: the model answers or asks the app to do something, one tool call at a time.",
            source: "AgentRunner.advance",
            steps: [
                l("message", "Your message", "Plus recent history, the selected course and a course list."),
                m("chatAssistant", after: ["message"], note: "Repeats after each tool result, up to 6 tool calls per message."),
                l("tool", "Validate tool call", "Unknown tools and bad arguments are rejected.", after: ["chatAssistant"]),
                l("approval", "Your approval", "Required for every write or delete; read-only tools skip it.", after: ["tool"], approval: true),
                l("run", "Run in the app", "Uses the existing course, library, question-bank and planner services.", after: ["approval"]),
            ]),
        WorkflowPipeline(id: "plan", title: "Create Study Plan",
            summary: "Builds a day-by-day plan from the questions and mastery you already have.",
            source: "AgentWriteTools.createPlan, PlannerService",
            steps: [
                m("chatAssistant", note: "Decides to call the study-plan tool."),
                l("planner", "Plan the days", "The planner picks real questions per day from the bank and your weak topics. No model is called.", after: ["chatAssistant"]),
                l("persist", "Save the plan", "Stored as a plan you can reopen from chat.", after: ["planner"]),
            ]),
        WorkflowPipeline(id: "grading", title: "Grade a Written Answer",
            summary: "Sends a prepared grading request to the model (or the manual bridge) and imports the checked reply.",
            source: "DirectAIService.send, AITaskService",
            steps: [
                l("prepare", "Prepare request", "Builds the grading request from the question and your answer."),
                m("answerEvaluation", after: ["prepare"], note: "Or the manual ChatGPT Bridge when the task is set to it."),
                l("import", "Validate & import", "The reply is checked against the grade schema before it is stored.", after: ["answerEvaluation"]),
            ]),
        WorkflowPipeline(id: "topics", title: "Analyze Course Topics",
            summary: "Asks the model for a topic tree and imports it after validation.",
            source: "DirectAIService.send, AITaskService",
            steps: [
                l("prepare", "Prepare request", "Packages your course description and material excerpts."),
                m("topicGeneration", after: ["prepare"], note: "Or the manual ChatGPT Bridge when the task is set to it."),
                l("import", "Validate & import", "Topics are validated and merged into the course.", after: ["topicGeneration"]),
            ]),
    ]

    /// Tasks that no pipeline above runs. They can be assigned a model, but nothing calls them yet.
    public static var unwiredTaskIds: [String] {
        let used = Set(all.flatMap(\.modelTaskIds))
        return WorkflowTask.all.filter { !used.contains($0.id) }.map(\.id)
    }
}

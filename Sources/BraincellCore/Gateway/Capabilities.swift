import Foundation

/// What a model can be asked to do. A model record carries exactly one capability, so routing never has to guess.
public enum Capability: String, CaseIterable, Codable, Sendable, Identifiable {
    case llm, imageGeneration, videoGeneration, tts, stt, documentParsing, webSearch, webFetch, embeddings, vision
    public var id: String { rawValue }
    public var label: String {
        switch self {
        case .llm: "LLM"; case .imageGeneration: "Image Generation"; case .videoGeneration: "Video Generation"
        case .tts: "Text-to-Speech"; case .stt: "Speech Recognition"; case .documentParsing: "Document Parsing"
        case .webSearch: "Web Search"; case .webFetch: "Web Fetch"; case .embeddings: "Embeddings"; case .vision: "Vision"
        }
    }
    public var symbol: String {
        switch self {
        case .llm: "cube"; case .imageGeneration: "photo"; case .videoGeneration: "film"; case .tts: "speaker.wave.2"
        case .stt: "mic"; case .documentParsing: "doc.text"; case .webSearch: "magnifyingglass"; case .webFetch: "globe"
        case .embeddings: "square.grid.3x3"; case .vision: "eye"
        }
    }
}

public enum TaskGroup: String, CaseIterable, Sendable {
    case core = "Core generation", study = "Study content", research = "Research & sources", media = "Multimedia", experience = "Study experience"
}

/// A configurable task route (one node in the AI Workflow). Routes are per-task settings, not a fixed pipeline:
/// `dependsOn` records only genuine data dependencies and is used for display and validation.
public struct WorkflowTask: Identifiable, Hashable, Sendable {
    public let id: String
    public let title: String
    public let capability: Capability
    public let group: TaskGroup
    public let summary: String
    public let dependsOn: [String]
    public let optional: Bool

    static func t(_ id: String, _ title: String, _ cap: Capability, _ g: TaskGroup, _ summary: String, after: [String] = [], optional: Bool = false) -> WorkflowTask {
        WorkflowTask(id: id, title: title, capability: cap, group: g, summary: summary, dependsOn: after, optional: optional)
    }

    public static let all: [WorkflowTask] = [
        t("chatAssistant", "Chat Assistant", .llm, .core, "The Home chat: answers questions and calls app tools."),
        t("planningAgent", "Planning Agent", .llm, .core, "Decides how a larger request is broken into steps."),
        t("courseOutline", "Course Outline", .llm, .core, "Drafts a course outline from your sources.", after: ["sourceSummarization"]),
        t("learningObjectives", "Learning Objectives", .llm, .core, "Writes measurable objectives for each part.", after: ["courseOutline"]),
        t("topicGeneration", "Topics & Subtopics", .llm, .core, "Proposes the skill tree (used by topic analysis).", after: ["courseOutline"]),
        t("lessonStructure", "Lesson Structure", .llm, .core, "Plans the sections of a lesson.", after: ["topicGeneration"]),
        t("lessonContent", "Lesson Content", .llm, .core, "Writes the lesson text.", after: ["lessonStructure", "contextRetrieval"]),
        t("explanations", "Explanations", .llm, .core, "Explains a concept in depth.", after: ["lessonContent"], optional: true),
        t("examples", "Examples", .llm, .core, "Worked examples for a concept.", after: ["lessonContent"], optional: true),
        t("simplification", "Concept Simplification", .llm, .core, "Restates difficult material simply."),
        t("summaries", "Summaries", .llm, .core, "Summaries of lessons or sources."),

        t("flashcards", "Flashcard Generation", .llm, .study, "Creates flashcards.", after: ["contextRetrieval"]),
        t("quizGeneration", "Quiz Generation", .llm, .study, "Generates practice questions (used by Question Bank requests).", after: ["contextRetrieval"]),
        t("multipleChoice", "Multiple-Choice Questions", .llm, .study, "Multiple-choice items."),
        t("shortAnswer", "Short-Answer Questions", .llm, .study, "Short-answer items."),
        t("longAnswer", "Long-Answer Questions", .llm, .study, "Long-form and proof items."),
        t("codingProblem", "Coding Problem Generation", .llm, .study, "Coding exercises with tests."),
        t("answerEvaluation", "Answer Evaluation", .llm, .study, "Grades written answers (used by AI grading)."),
        t("hints", "Hint Generation", .llm, .study, "Hints that don’t give the answer away.", after: ["answerEvaluation"], optional: true),
        t("tutoring", "Personalized Tutoring", .llm, .study, "Tutor replies when you’re stuck."),
        t("knowledgeGap", "Knowledge Gap Analysis", .llm, .study, "Finds what to review."),

        t("documentParsing", "Document Parsing", .documentParsing, .research, "Extracts text from PDFs and documents."),
        t("vision", "Vision / Images", .vision, .research, "Reads diagrams and screenshots."),
        t("webSearch", "Web Search", .webSearch, .research, "Finds supporting sources.", optional: true),
        t("webFetch", "Web Fetch", .webFetch, .research, "Extracts a webpage’s main content.", after: ["webSearch"], optional: true),
        t("sourceSummarization", "Source Summarization", .llm, .research, "Condenses parsed sources.", after: ["documentParsing"]),
        t("embeddings", "Embeddings", .embeddings, .research, "Indexes material for retrieval."),
        t("contextRetrieval", "Context Retrieval", .embeddings, .research, "Finds the relevant passages.", after: ["embeddings"]),

        t("imageGeneration", "Image Generation", .imageGeneration, .media, "Diagrams and illustrations.", after: ["lessonContent"], optional: true),
        t("videoGeneration", "Video Generation", .videoGeneration, .media, "Short explanatory videos.", after: ["lessonContent"], optional: true),
        t("narration", "Narration (TTS)", .tts, .media, "Reads a lesson aloud.", after: ["lessonContent"], optional: true),
        t("speechRecognition", "Speech Recognition", .stt, .media, "Transcribes spoken answers.", optional: true),

        t("studyPlan", "Study Plan Generation", .llm, .experience, "Builds a study plan."),
        t("difficultyAdaptation", "Difficulty Adaptation", .llm, .experience, "Tunes difficulty to you."),
        t("reviewRecommendations", "Review Recommendations", .llm, .experience, "Suggests what to review next."),
    ]

    public static func find(_ id: String) -> WorkflowTask? { all.first { $0.id == id } }

    /// Task used when an existing manual-bridge request kind is sent through the gateway.
    public static func forLegacy(_ kind: AITaskKind) -> WorkflowTask {
        find(kind == .questionGeneration ? "quizGeneration" : kind == .subjectiveGrading ? "answerEvaluation" : "topicGeneration")!
    }
}

/// Dependency-graph checks for the workflow. Edges come from `WorkflowTask.dependsOn`.
public enum WorkflowGraph {
    public struct Issue: Equatable, Sendable { public let message: String }

    /// Unknown targets and cycles. (Capability compatibility is enforced by routing, not by edges.)
    public static func validate(_ tasks: [WorkflowTask] = WorkflowTask.all) -> [Issue] {
        var issues: [Issue] = []
        let ids = Set(tasks.map(\.id))
        for t in tasks { for d in t.dependsOn where !ids.contains(d) { issues.append(Issue(message: "\(t.id) depends on unknown task \(d)")) } }
        if hasCycle(tasks) { issues.append(Issue(message: "The dependency graph contains a cycle.")) }
        return issues
    }

    public static func hasCycle(_ tasks: [WorkflowTask]) -> Bool {
        let deps = Dictionary(uniqueKeysWithValues: tasks.map { ($0.id, $0.dependsOn) })
        var state: [String: Int] = [:]   // 1 visiting, 2 done
        func visit(_ n: String) -> Bool {
            if state[n] == 2 { return false }
            if state[n] == 1 { return true }
            state[n] = 1
            for d in deps[n] ?? [] where visit(d) { return true }
            state[n] = 2; return false
        }
        return tasks.contains { visit($0.id) }
    }

    /// A valid execution order (dependencies first), or nil when cyclic.
    public static func executionOrder(_ tasks: [WorkflowTask] = WorkflowTask.all) -> [String]? {
        guard !hasCycle(tasks) else { return nil }
        let byId = Dictionary(uniqueKeysWithValues: tasks.map { ($0.id, $0) })
        var out: [String] = [], seen = Set<String>()
        func visit(_ n: String) { guard !seen.contains(n), let t = byId[n] else { return }; seen.insert(n); t.dependsOn.forEach(visit); out.append(n) }
        tasks.forEach { visit($0.id) }
        return out
    }
}

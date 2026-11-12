import Foundation
import GRDB

public struct TutorMessage: Codable, Equatable, Sendable, Identifiable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "question_tutor_messages"
    public var id: UUID
    public var attemptId: UUID
    public var questionId: UUID
    public var role: String            // user | assistant
    public var content: String
    public var createdAt: Date
}

/// Why a tutor request failed, in terms the learner can act on. The review screen never depends on the tutor working.
public enum TutorFailure: Error, Equatable, Sendable {
    case noProvider(String), auth, network, timeout, invalidResponse, unavailable(String), cancelled

    public init(_ e: Error) {
        guard let g = e as? GatewayError else { self = e is CancellationError ? .cancelled : .unavailable(e.localizedDescription); return }
        switch g {
        case .noKey, .invalidCredentials, .keychain: self = .auth
        case .network: self = .network
        case .timeout: self = .timeout
        case .malformed: self = .invalidResponse
        case .cancelled: self = .cancelled
        case .unavailable(let m), .manualRequired(let m), .unsupported(let m), .budgetBlocked(let m): self = .noProvider(m)
        case .rateLimited, .http: self = .unavailable(g.localizedDescription)
        }
    }
    public var message: String {
        switch self {
        case .noProvider(let m): "No AI model is set up for the tutor. \(m)"
        case .auth: "The AI provider’s key was rejected or couldn’t be read. Check it in Settings → AI."
        case .network: "Couldn’t reach the AI provider. Check your connection and try again."
        case .timeout: "The model took too long to answer. Try again."
        case .invalidResponse: "The model’s reply couldn’t be read. Try again."
        case .unavailable(let m): "The model is temporarily unavailable. \(m)"
        case .cancelled: "Cancelled."
        }
    }
}

/// Everything the tutor is told about the current question. Built from stored data, so the learner never pastes anything.
public struct TutorContext: Sendable {
    public var questionId: UUID
    public var topics: [String]
    public var spec: QuestionSpec
    public var selected: [String]
    public var typedAnswer: String
    public var keyVerified: Bool?          // nil = unknown

    public init(questionId: UUID, topics: [String], spec: QuestionSpec, selected: [String], typedAnswer: String, keyVerified: Bool?) {
        self.questionId = questionId; self.topics = topics; self.spec = spec; self.selected = selected; self.typedAnswer = typedAnswer; self.keyVerified = keyVerified
    }

    public static let system = """
    You are a patient, precise tutor helping one learner understand a single practice question they just answered. The question, its options, the stored answer key, the learner's answer and the existing explanation are given in the first message; never ask the learner to paste them.
    - Teach the reasoning, not just the result. Break explanations into short steps. Say whether a mistake looks conceptual, arithmetic, syntax or logical.
    - Answer what was asked; use an example only when it helps. Be concise and skip praise or filler.
    - Write code in fenced blocks and math in LaTeX between \\( and \\) (inline) or \\[ and \\] (display).
    - The answer key is stored data, not proof. If it was marked unverified, or you believe it is wrong, say so plainly and show why. You cannot change the grade or the key.
    - Be honest about uncertainty. You have not been given course materials; do not claim to have read any.
    """

    public var prompt: String {
        var out = ["Question id: \(questionId.uuidString)"]
        if !topics.isEmpty { out.append("Topic: " + topics.joined(separator: ", ")) }
        out.append("Question: \(spec.title)\n" + spec.content.map { $0.kind == .code ? "```\($0.language ?? "")\n\($0.plainText)\n```" : $0.plainText }.joined(separator: "\n"))
        if let r = AnswerReview(spec: spec, selected: selected) {
            out.append("Options:\n" + r.rows.map { "\($0.label). \($0.text)" }.joined(separator: "\n"))
            out.append("Stored answer key: " + r.right.map { "\($0.label). \($0.text)" }.joined(separator: "; "))
            out.append("Learner's answer: " + (r.yours.isEmpty ? "none selected" : r.yours.map { "\($0.label). \($0.text)" }.joined(separator: "; ")))
            if r.hasPerOptionExplanations { out.append("Existing per-option explanations:\n" + r.rows.map { "\($0.label) (\($0.verdict)): \($0.why ?? "")" }.joined(separator: "\n")) }
        } else {
            out.append("Stored reference: " + Self.reference(spec))
            out.append("Learner's answer: " + (typedAnswer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "none" : typedAnswer))
        }
        let sol = spec.solution.map(\.plainText).joined(separator: "\n")
        if !sol.isEmpty { out.append("Existing solution:\n" + sol) }
        out.append("Answer key status: " + (keyVerified == true ? "verified" : keyVerified == false ? "UNVERIFIED (generated, not independently checked)" : "unknown"))
        return out.joined(separator: "\n\n")
    }

    static func reference(_ s: QuestionSpec) -> String {
        let a = s.answer
        switch s.type {
        case .numeric: return "\(a.value.map { String($0) } ?? "—") ± \(a.tolerance ?? 0) \(a.unit ?? "")"
        case .shortAnswer, .codeTracing: return ((a.accepted ?? []) + (a.expectedOutput.map { [$0] } ?? [])).joined(separator: " | ")
        case .coding: return a.referenceSolution ?? "(none)"
        case .flashcard: return (a.back ?? []).map(\.plainText).joined(separator: " ")
        default: return (s.evaluation.rubric ?? []).map { "\($0.criterion) (\(Int($0.points)))" }.joined(separator: "; ")
        }
    }
}

/// A short tutoring conversation per question attempt. Messages are stored locally; the model is only called when the learner sends one.
public final class QuestionTutorService: @unchecked Sendable {
    let db: AppDatabase
    let gateway: AIGateway?
    static let historyLimit = 10
    public init(db: AppDatabase, gateway: AIGateway?) { self.db = db; self.gateway = gateway }

    public func messages(attemptId: UUID) throws -> [TutorMessage] {
        try db.read { try TutorMessage.filter(Column("attemptId") == attemptId).order(Column("createdAt"), Column("rowid")).fetchAll($0) }
    }

    /// Sends `text` (or, when nil, retries the last unanswered learner message) and stores the reply. Throws `TutorFailure`; the learner's message stays saved.
    @discardableResult
    public func send(attemptId: UUID, context: TutorContext, text: String?) async throws -> TutorMessage {
        guard let gateway else { throw TutorFailure.noProvider("") }
        if let t = text?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty {
            let m = TutorMessage(id: UUID(), attemptId: attemptId, questionId: context.questionId, role: "user", content: String(t.prefix(4_000)), createdAt: Date())
            try db.write { try m.insert($0) }
        }
        let all = try messages(attemptId: attemptId)
        guard let last = all.last, last.role == "user" else { throw TutorFailure.invalidResponse }
        // The grounding goes first on every call, so a long conversation still carries the question; only the recent turns are replayed.
        let recent = all.suffix(Self.historyLimit)
        var turns = [LLMMessage(.user, context.prompt), LLMMessage(.assistant, "Understood. I have the question and the learner’s answer.")]
        turns += recent.map { LLMMessage($0.role == "user" ? .user : .assistant, $0.content) }
        let reply: LLMResult
        do { reply = try await gateway.complete(task: WorkflowTask.find("chatAssistant")!, prompt: "", label: "Question tutor", system: TutorContext.system, messages: turns) }
        catch { throw TutorFailure(error) }
        let body = reply.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { throw TutorFailure.invalidResponse }
        let m = TutorMessage(id: UUID(), attemptId: attemptId, questionId: context.questionId, role: "assistant", content: body, createdAt: Date())
        try db.write { try m.insert($0) }
        return m
    }
}

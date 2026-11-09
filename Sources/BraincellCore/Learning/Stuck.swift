import Foundation
import GRDB

public enum StuckKind: String, CaseIterable, Sendable, Identifiable {
    case dontUnderstandConcept, dontKnowWhereToStart, stuckOnNextStep, solutionNotWorking
    public var id: String { rawValue }
    public var label: String {
        switch self {
        case .dontUnderstandConcept: "I don’t understand the concept"
        case .dontKnowWhereToStart: "I don’t know where to start"
        case .stuckOnNextStep: "I’m stuck on the next step"
        case .solutionNotWorking: "My solution isn’t working"
        }
    }
}

public struct StuckGuidance: Sendable {
    public var kind: StuckKind
    public var message: String
    /// True when a prepared hint is still available.
    public var hasNextHint: Bool
    public var prerequisites: [(skill: Skill, mastery: SkillMastery)]
    public var objective: String
}

public struct StuckService: Sendable {
    let db: AppDatabase
    public init(db: AppDatabase) { self.db = db }

    /// Uses only prepared content: the question's hints and its skills' prerequisite links.
    public func guidance(itemId: UUID, kind: StuckKind, now: Date = Date()) throws -> StuckGuidance {
        try db.read { d in
            guard let item = try SessionItem.fetchOne(d, key: itemId), let spec = try QuestionRevision.fetchOne(d, key: item.revisionId)?.spec else { throw PracticeError.notFound }
            let skillIds = try UUID.fetchAll(d, sql: "SELECT skillId FROM question_skills WHERE questionId = ?", arguments: [item.questionId])
            var pre: [(Skill, SkillMastery)] = []
            for s in skillIds {
                for pid in try UUID.fetchAll(d, sql: "SELECT fromSkillId FROM skill_relations WHERE toSkillId = ? AND kind = 'prerequisite'", arguments: [s]) {
                    guard let p = try Skill.fetchOne(d, key: pid), p.archivedAt == nil, !pre.contains(where: { $0.0.id == pid }) else { continue }
                    pre.append((p, HeuristicMasteryEstimator().estimate(skillId: pid, evidence: try ProgressionEngine.evidenceInputs(d, skillId: pid), now: now)))
                }
            }
            let more = item.hintsUsed < spec.hints.count
            let msg: String
            switch kind {
            case .dontUnderstandConcept:
                msg = pre.isEmpty ? "Let’s step back to the idea behind this: “\(spec.learningObjective)”. Reveal the first hint, or ask for help below." : "This question builds on other skills. Reviewing them first may help; the objective is “\(spec.learningObjective)”."
            case .dontKnowWhereToStart: msg = "Start by writing down what is given and what is being asked. \(more ? "The next prepared hint is a gentle nudge." : "No more prepared hints; ask for help below if you’re still stuck.")"
            case .stuckOnNextStep: msg = more ? "Try the next hint; each one reveals a little more." : "You’ve used all prepared hints. Re-read the statement, then ask for help below or skip and come back."
            case .solutionNotWorking: msg = "Re-read the statement and check edge cases step by step. \(spec.type == .coding ? "Braincell can’t run code, so trace your solution by hand with a tiny example. " : "")\(more ? "A hint may point at what to check." : "")"
            }
            return StuckGuidance(kind: kind, message: msg, hasNextHint: more, prerequisites: pre.map { (skill: $0.0, mastery: $0.1) }, objective: spec.learningObjective)
        }
    }
}

/// A help request the learner can copy into ChatGPT themselves. The reference solution is deliberately not included.
public enum TutorPrompt {
    public struct Built: Sendable { public var text: String; public var disclosure: [String] }

    public static func build(spec: QuestionSpec, response: PracticeResponse, kind: StuckKind, revealedHints: Int, skillNames: [String], includeResponse: Bool) -> Built {
        func describe(_ blocks: [ContentBlock]) -> String { AITaskService.describe(blocks) }
        var t = """
        I'm studying for a course and I'm stuck on a practice question. Please tutor me: ask guiding questions and give small hints rather than the full solution, and check my reasoning step by step.

        Where I'm stuck: \(kind.label).
        Skills: \(skillNames.isEmpty ? "(not specified)" : skillNames.joined(separator: ", "))
        Learning objective: \(spec.learningObjective)

        ## Question: \(spec.title)
        \(describe(spec.content))
        """
        if revealedHints > 0 { t += "\n\n## Hints I've already seen\n" + spec.hints.prefix(revealedHints).enumerated().map { "\($0 + 1). \($1)" }.joined(separator: "\n") }
        var disclosure = ["The question statement and learning objective", "The skill names", "Which kind of help you asked for"]
        if revealedHints > 0 { disclosure.append("\(revealedHints) hint(s) you have already seen") }
        if includeResponse {
            let r = AITaskService.describe(response, spec: spec)
            if r != "(blank)" { t += "\n\n## My attempt so far\n\(r)"; disclosure.append("Your current attempt (optional; you can turn this off)") }
        }
        return Built(text: t, disclosure: disclosure + ["Not included: the reference solution, your history, scores or reflections"])
    }
}

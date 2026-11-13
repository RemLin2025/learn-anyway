import Foundation

/// How a submitted choice question is shown: one row per option in display order, with the learner's pick and the key marked.
/// Pure data so the same logic drives the screen, VoiceOver text and the tutor prompt.
public struct AnswerReview: Equatable, Sendable {
    public struct Row: Equatable, Sendable, Identifiable {
        public var id: String
        public var label: String          // A, B, C…
        public var text: String
        public var isCorrect: Bool
        public var isSelected: Bool
        public var why: String?
        public var verdict: String { isCorrect ? "Correct" : (isSelected ? "Incorrect (your choice)" : "Incorrect") }
    }
    public var rows: [Row]
    public var hasPerOptionExplanations: Bool

    public static func label(_ i: Int) -> String { i < 26 ? String(UnicodeScalar(65 + i)!) : "\(i + 1)" }

    /// nil for question types that are not choice questions.
    public init?(spec: QuestionSpec, selected: [String]) {
        guard spec.type == .singleChoice || spec.type == .multipleSelect, let choices = spec.answer.choices else { return nil }
        let key = Set(spec.answer.correctIds ?? [])
        rows = choices.enumerated().map { i, c in Row(id: c.id, label: Self.label(i), text: c.text, isCorrect: key.contains(c.id), isSelected: selected.contains(c.id), why: c.why) }
        hasPerOptionExplanations = !choices.isEmpty && choices.allSatisfy { ($0.why ?? "").isEmpty == false }
    }

    public var right: [Row] { rows.filter(\.isCorrect) }
    public var yours: [Row] { rows.filter(\.isSelected) }
    public var answeredCorrectly: Bool { Set(right.map(\.id)) == Set(yours.map(\.id)) }
}

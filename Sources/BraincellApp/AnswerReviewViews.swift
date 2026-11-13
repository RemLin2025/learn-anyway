import SwiftUI
import BraincellCore

/// A choice's text as markdown: multi-line text without a fence is code (or a list), so it keeps its line breaks and indentation in a monospaced block.
enum ChoiceMarkdown {
    /// Text that is clearly code (several lines, or statement/brace syntax) is shown as a code block; prose and math are left to the markdown renderer.
    static func text(_ s: String) -> String {
        guard !s.contains("```"), !s.contains("\\("), !s.contains("$") else { return s }
        return s.contains("\n") || s.contains(";") || s.contains("{") || s.contains("->") ? "```\n" + s + "\n```" : s
    }
}

/// The compact review under the answer options: right answer, your answer, and why each option is right or wrong.
struct AnswerReviewSection: View {
    @ObservedObject var pm: PracticeModel
    let spec: QuestionSpec
    var onExplain: () -> Void

    var body: some View {
        if let r = AnswerReview(spec: spec, selected: pm.response.selected) {
            Card(padding: Theme.Space.lg) {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text("Answer review").font(Theme.cardTitle).accessibilityAddTraits(.isHeader)
                        Spacer()
                        if pm.keyVerified != true {
                            Label("Unverified answer key", systemImage: "questionmark.circle").font(.caption).foregroundStyle(Theme.textSecondary)
                                .help("This answer key was generated and hasn’t been independently checked. Matching it is not proof the answer is right.")
                        }
                    }
                    line("Right answer", r.right)
                    line("Your answer", r.yours)
                    Divider()
                    Text("Why each answer is right or wrong").font(.subheadline.weight(.semibold))
                    if r.hasPerOptionExplanations {
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(r.rows) { row in
                                HStack(alignment: .firstTextBaseline, spacing: 8) {
                                    Text("•").foregroundStyle(Theme.textSecondary)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text("\(row.label) — \(row.verdict)").font(.callout.weight(.semibold)).foregroundStyle(row.isCorrect ? Theme.mastery : (row.isSelected ? Theme.error : Color.primary))
                                        RichText(text: row.why ?? "")
                                    }
                                }.accessibilityElement(children: .combine)
                            }
                        }
                    } else {
                        if !spec.solution.isEmpty { BlocksView(blocks: spec.solution) }
                        Text("No option-by-option explanation was saved for this question.").font(.caption).foregroundStyle(Theme.textSecondary)
                        Button { onExplain() } label: { Label("Explain each option with AI", systemImage: "sparkles") }.buttonStyle(.borderless).font(.callout)
                    }
                }
            }
        }
    }

    private func line(_ title: String, _ rows: [AnswerReview.Row]) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(title).font(.caption.weight(.semibold)).foregroundStyle(Theme.textSecondary).frame(width: 84, alignment: .leading)
            VStack(alignment: .leading, spacing: 4) {
                if rows.isEmpty { Text(title == "Your answer" ? "No answer selected" : "Not available").foregroundStyle(Theme.textSecondary) }
                ForEach(rows) { r in
                    HStack(alignment: .firstTextBaseline, spacing: 6) { Text("\(r.label).").font(.callout.weight(.semibold)); RichText(text: ChoiceMarkdown.text(r.text)) }
                }
            }
        }.accessibilityElement(children: .combine)
    }
}

// MARK: Tutor

@MainActor
final class TutorModel: ObservableObject {
    let attemptId: UUID
    let context: TutorContext
    private let svc: QuestionTutorService
    @Published private(set) var messages: [TutorMessage] = []
    @Published private(set) var sending = false
    @Published private(set) var failure: TutorFailure?
    @Published var draft = ""
    @Published var expanded = false
    let suggestions: [String]

    init(attemptId: UUID, context: TutorContext, svc: QuestionTutorService, answeredCorrectly: Bool) {
        self.attemptId = attemptId; self.context = context; self.svc = svc
        suggestions = [answeredCorrectly ? "Why do the other options fail?" : "Why is my answer wrong?", "Explain this step by step.", "Show me a similar example.", "What’s the key concept?"]
        messages = (try? svc.messages(attemptId: attemptId)) ?? []
        expanded = !messages.isEmpty
    }

    /// The last learner message never got a reply (a failure, or the app quit mid-request).
    var needsRetry: Bool { !sending && messages.last?.role == "user" }

    func send(_ text: String? = nil) {
        let t = (text ?? draft).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !sending, !t.isEmpty else { return }
        draft = ""; expanded = true
        run(t)
    }
    func retry() { guard needsRetry else { return }; run(nil) }

    private func run(_ text: String?) {
        sending = true; failure = nil
        if let text { messages.append(TutorMessage(id: UUID(), attemptId: attemptId, questionId: context.questionId, role: "user", content: text, createdAt: Date())) }
        Task {
            do { try await svc.send(attemptId: attemptId, context: context, text: text) }
            catch let f as TutorFailure { if f != .cancelled { failure = f } }
            catch { failure = TutorFailure(error) }
            messages = (try? svc.messages(attemptId: attemptId)) ?? messages
            sending = false
            if failure == nil { AccessibilityNotification.Announcement("AI tutor replied").post() }
        }
    }
}

struct TutorSection: View {
    @ObservedObject var tutor: TutorModel
    @FocusState private var focused: Bool

    var body: some View {
        Card(padding: Theme.Space.lg) {
            VStack(alignment: .leading, spacing: 12) {
                Button { tutor.expanded.toggle() } label: {
                    HStack(alignment: .firstTextBaseline) {
                        VStack(alignment: .leading, spacing: 2) {
                            Label("Ask AI Tutor", systemImage: "sparkles").font(Theme.cardTitle)
                            Text("Ask why an option is right or wrong, or how to solve similar problems. The tutor already knows this question and your answer.")
                                .font(.caption).foregroundStyle(Theme.textSecondary).multilineTextAlignment(.leading)
                        }
                        Spacer()
                        Image(systemName: tutor.expanded ? "chevron.up" : "chevron.down").foregroundStyle(Theme.textSecondary)
                    }.contentShape(Rectangle())
                }
                .buttonStyle(.plain).accessibilityValue(tutor.expanded ? "Expanded" : "Collapsed").accessibilityHint("Shows or hides the tutor")
                if tutor.expanded { content }
            }
        }
    }

    @ViewBuilder private var content: some View {
        if !tutor.messages.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(tutor.messages) { m in
                    if m.role == "user" {
                        Text(m.content).padding(.horizontal, 10).padding(.vertical, 6).background(Theme.accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
                            .frame(maxWidth: .infinity, alignment: .trailing).accessibilityLabel("You asked: \(m.content)")
                    } else {
                        RichText(text: m.content).padding(10).background(Theme.elevated.opacity(0.6), in: RoundedRectangle(cornerRadius: 8))
                            .accessibilityLabel("Tutor: \(m.content)")
                    }
                }
            }
        }
        if tutor.sending { HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Thinking…").foregroundStyle(Theme.textSecondary) }.accessibilityElement(children: .combine).accessibilityLabel("Tutor is thinking") }
        if let f = tutor.failure {
            HStack(alignment: .firstTextBaseline) {
                Label(f.message, systemImage: "exclamationmark.triangle").font(.callout).foregroundStyle(Theme.attention)
                if tutor.needsRetry { Button("Try again") { tutor.retry() } }
            }
        } else if tutor.needsRetry { Button("Try again") { tutor.retry() } }
        FlowSuggestions(items: tutor.suggestions, disabled: tutor.sending) { tutor.send($0) }
        HStack(alignment: .bottom, spacing: 8) {
            TextField("Ask about this question", text: $tutor.draft, axis: .vertical).lineLimit(1...5).textFieldStyle(AppFieldStyle())
                .focused($focused).onSubmit { tutor.send() }.accessibilityLabel("Message to the AI tutor")
            Button { tutor.send() } label: { Image(systemName: "arrow.up.circle.fill").font(.title2) }
                .buttonStyle(.plain).foregroundStyle(Theme.accent).disabled(tutor.sending || tutor.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .help("Send").accessibilityLabel("Send")
        }
    }
}

private struct FlowSuggestions: View {
    let items: [String]
    let disabled: Bool
    let pick: (String) -> Void
    var body: some View {
        FlowLayout(spacing: 6, lineSpacing: 6) {
            ForEach(items, id: \.self) { s in
                Button { pick(s) } label: { Text(s).font(.caption).padding(.horizontal, 10).padding(.vertical, 5).background(Theme.surface, in: Capsule()).overlay(Capsule().strokeBorder(Theme.border)).contentShape(Capsule()) }
                    .buttonStyle(.plain).disabled(disabled)
            }
        }
    }
}

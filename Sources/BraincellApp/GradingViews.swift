import SwiftUI
import BraincellCore

/// The grade shown right after submitting: honest about trust, never red/punitive, never guessing for pending work.
struct GradePanel: View {
    @ObservedObject var pm: PracticeModel
    let spec: QuestionSpec

    static func verdictText(_ e: Evaluation) -> String {
        let s = e.score ?? 0
        if s >= 0.8 { return "Correct" }
        if s > 0 { return "Partly correct · \(Int((s * 100).rounded()))%" }
        return "Not quite"
    }

    static func trustText(_ t: GradeTrust) -> String {
        switch t {
        case .trusted: "Checked against a verified answer key"
        case .provisional: "Provisional: the answer key isn’t independently verified, so this counts for less"
        case .selfReported: "Self-reviewed: counts as lower-confidence evidence"
        case .aiGraded: "Graded in ChatGPT"
        }
    }

    var body: some View {
        if let r = pm.result {
            let e = r.evaluation
            Card {
                VStack(alignment: .leading, spacing: 10) {
                    switch e.state {
                    case .graded:
                        let good = (e.score ?? 0) >= 0.8
                        Label(Self.verdictText(e), systemImage: good ? "checkmark.circle.fill" : "circle.dotted")
                            .font(.title3.weight(.semibold)).foregroundStyle(good ? Theme.mastery : Theme.attention)
                        Text(e.feedback).font(.callout)
                        Text(Self.trustText(e.trust)).font(.caption).foregroundStyle(Theme.textSecondary)
                        if e.source != .selfReview || e.trust != .selfReported { disagreeMenu }
                    case .pending:
                        Label("Waiting for a grade", systemImage: "hourglass").font(.title3.weight(.semibold)).foregroundStyle(Theme.textSecondary)
                        Text("This isn’t counted as right or wrong. Review it yourself against the reference below, or grade many written answers later with ChatGPT (AI Tasks).")
                            .font(.callout).foregroundStyle(Theme.textSecondary)
                        if spec.evaluation.method == .codeTests {
                            if pm.app.codeRunner.isAvailable {
                                Button { Task { await pm.gradeCode() } } label: { Label("Run the tests and grade", systemImage: "play.fill") }.buttonStyle(.primary).disabled(pm.running)
                            } else { Text("Turn on code execution in Settings to grade this automatically, or review it yourself below.").font(.caption).foregroundStyle(Theme.textSecondary) }
                        }
                        SelfReviewView(spec: spec, onSave: pm.selfReview)
                    case .needsReview, .evaluatorUnavailable:
                        Label("Needs your review", systemImage: "questionmark.circle").font(.title3.weight(.semibold)).foregroundStyle(Theme.attention)
                        Text(e.feedback).font(.callout)
                        SelfReviewView(spec: spec, onSave: pm.selfReview)
                    }
                    if r.xp != 0 {
                        Label("+\(r.xp) XP", systemImage: "sparkles").font(.callout.weight(.medium)).foregroundStyle(Theme.accent)
                            .accessibilityLabel("\(r.xp) experience points earned")
                    }
                }
            }
        }
    }

    private var disagreeMenu: some View {
        Menu("I disagree with this grade") {
            Button("Mark as correct") { pm.overrideGrade(correct: true) }
            Button("Mark as incorrect") { pm.overrideGrade(correct: false) }
        }.menuStyle(.borderlessButton).fixedSize().font(.caption)
    }
}

struct SelfReviewView: View {
    let spec: QuestionSpec
    var onSave: (Double, [String: Double]?, String?) -> Void
    @State private var points: [String: Double] = [:]

    var body: some View {
        if spec.type == .flashcard {
            VStack(alignment: .leading, spacing: 6) {
                Text("How well did you recall it?").font(.subheadline)
                HStack {
                    ForEach([("Again", 0.0), ("Hard", 0.4), ("Good", 0.8), ("Easy", 1.0)], id: \.0) { name, score in
                        Button(name) { onSave(score, nil, name.lowercased()) }
                    }
                }
            }
        } else if let rubric = spec.evaluation.rubric, !rubric.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text("Score yourself against the rubric").font(.subheadline)
                ForEach(rubric, id: \.criterion) { item in
                    Stepper(value: Binding(get: { points[item.criterion] ?? 0 }, set: { points[item.criterion] = $0 }), in: 0...item.points, step: 0.5) {
                        HStack { Text(item.criterion); Spacer(); Text("\(points[item.criterion] ?? 0, specifier: "%g") / \(item.points, specifier: "%g")").monospacedDigit().foregroundStyle(Theme.textSecondary) }
                    }
                }
                Button("Save self-review") {
                    let total = rubric.reduce(0) { $0 + $1.points }, got = rubric.reduce(0) { $0 + (points[$1.criterion] ?? 0) }
                    onSave(total > 0 ? min(1, got / total) : 0, points, nil)
                }.buttonStyle(.primary)
            }
        } else {
            VStack(alignment: .leading, spacing: 6) {
                Text("How did you do?").font(.subheadline)
                HStack {
                    Button("Missed it") { onSave(0, nil, nil) }
                    Button("Partly") { onSave(0.5, nil, nil) }
                    Button("Got it") { onSave(1, nil, nil) }
                }
            }
        }
    }
}

// MARK: AI grading task

struct GradeTaskSheet: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    var onCreate: (UUID) -> Void
    @State private var pending: [PendingAttempt] = []
    @State private var courseId: UUID?
    @State private var chosen: Set<UUID> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Grade pending answers with ChatGPT").font(.headline)
            Text("Pick written or code answers that are still waiting for a grade. You’ll review exactly what gets shared before copying anything.")
                .font(.caption).foregroundStyle(Theme.textSecondary)
            if pending.isEmpty {
                EmptyStateView(symbol: "checkmark.circle", title: "Nothing is waiting", message: "Answers that need a subjective grade appear here after you submit them.")
            } else {
                Picker("Course", selection: $courseId) {
                    ForEach(courseIds, id: \.self) { id in Text(model.courseList.first { $0.id == id }?.name ?? "Course").tag(UUID?.some(id)) }
                }
                List(pending.filter { $0.courseId == courseId }) { p in
                    Toggle(isOn: Binding(get: { chosen.contains(p.id) }, set: { if $0 { chosen.insert(p.id) } else { chosen.remove(p.id) } })) {
                        VStack(alignment: .leading) { Text(p.title); Text(p.type.label).font(.caption).foregroundStyle(Theme.textSecondary) }
                    }
                }.frame(height: 220)
            }
            HStack { Spacer(); Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Create Task", action: create).keyboardShortcut(.defaultAction).disabled(chosen.isEmpty) }
        }
        .padding(Theme.Space.xl).frame(width: 480).background(Theme.background)
        .onAppear {
            pending = (try? model.evaluation?.pendingAttempts()) ?? []
            courseId = courseIds.first
            chosen = Set(pending.filter { $0.courseId == courseId }.map(\.id))
        }
        .onChange(of: courseId) { _, c in chosen = Set(pending.filter { $0.courseId == c }.map(\.id)) }
    }

    private var courseIds: [UUID] { var seen: [UUID] = []; for p in pending where !seen.contains(p.courseId) { seen.append(p.courseId) }; return seen }

    private func create() {
        guard let c = courseId else { return }
        model.perform { if let t = try model.ai?.createGradingTask(courseId: c, attemptIds: Array(chosen)) { onCreate(t.id) } }
        dismiss()
    }
}

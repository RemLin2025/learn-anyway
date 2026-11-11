import SwiftUI
import BraincellCore

/// Inspectable assessment style profile: what was detected, how sure we are, what the learner or instructor stated, and what is missing.
struct StyleProfileSheet: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let courseId: UUID
    let assessment: Assessment?
    @State private var profile: StyleProfile?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack { Text("Style profile · \(assessment?.name ?? "course")").font(.headline); Spacer(); Button("Done") { dismiss() }.keyboardShortcut(.defaultAction) }
            if let p = profile {
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        section("Exam settings (your input)") {
                            let c = p.config
                            row("Questions", c.examQuestionCount.map(String.init)); row("Minutes", c.durationMinutes.map(String.init)); row("Points each", c.pointsPerQuestion.map { String(format: "%g", $0) })
                            row("Format", c.format); row("Closed book", c.closedBook.map { $0 ? "yes" : "no" })
                            if !c.scopeExcludes.isEmpty { row("Excluded topics", c.scopeExcludes.joined(separator: ", ")) }
                            Text("These are user-provided unless you confirmed them against the instructor's announcement.").font(.caption).foregroundStyle(Theme.textSecondary)
                        }
                        section("Detected from instructor questions (inferred, \(Int(p.archetypes.confidence * 100))% confidence)") {
                            row("Formats", list(p.formats.value)); row("Reasoning archetypes", list(p.archetypes.value)); row("Difficulty spread (estimate)", list(p.difficulty.value))
                            row("Average solution steps", String(format: "%.1f", p.averageSteps.value)); row("Rounding", list(p.roundingDecimals.value))
                            ForEach(p.choicePatterns, id: \.self) { Text("• \($0)").font(.callout) }
                        }
                        section("Coverage") {
                            row("Questions recovered", "\(p.coverage.questionsRecovered) (\(p.coverage.completeQuestions) complete)")
                            row("Files analyzed", "\(p.coverage.documentsAnalyzed) of \(p.coverage.documents)"); row("Analysis windows", "\(p.coverage.windowsDone) of \(p.coverage.windowsTotal)")
                        }
                        section("Limitations") { ForEach(p.limitations, id: \.self) { Text("• \($0)").font(.callout).foregroundStyle(Theme.attention) } }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
            } else { ProgressView() }
        }
        .padding(Theme.Space.xl).frame(width: 560, height: 560).background(Theme.background)
        .task { if let db = model.db { profile = try? AssessmentService(db: db).profile(courseId: courseId, assessmentId: assessment?.id) } }
    }

    private func list(_ d: [String: Int]) -> String { d.isEmpty ? "none observed" : d.sorted { $0.value > $1.value }.prefix(6).map { "\($0.key) ×\($0.value)" }.joined(separator: ", ") }
    private func row(_ k: String, _ v: String?) -> some View { HStack(alignment: .top) { Text(k).foregroundStyle(Theme.textSecondary).frame(width: 190, alignment: .leading); Text(v ?? "unknown") } .font(.callout) }
    private func section<C: View>(_ t: String, @ViewBuilder _ c: () -> C) -> some View { VStack(alignment: .leading, spacing: 6) { Text(t).font(.subheadline.weight(.semibold)); c() } }
}

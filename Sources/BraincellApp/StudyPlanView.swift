import SwiftUI
import BraincellCore

/// Course tab: build a plan for an exam (Cram) or for long-term learning (Mastery), see why each question was
/// chosen, remove what you don't want, then start.
struct StudyPlanTab: View {
    @EnvironmentObject var model: AppModel
    let course: Course
    @State private var mode: StudyMode = .mastery
    @State private var assessments: [Assessment] = []
    @State private var assessmentId: UUID?
    @State private var minutes = 25
    @State private var skills: [Skill] = []
    @State private var focus: Set<UUID> = []
    @State private var maxDifficulty = 5
    @State private var plan: StudyPlan?
    @State private var included: Set<UUID> = []
    @State private var dueCount = 0
    @State private var showConstraints = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if dueCount == 0 {
                    Label("No reviews due. You’re all caught up on flashcards and short answers.", systemImage: "checkmark.circle").font(.callout).foregroundStyle(Theme.textSecondary)
                }
                if dueCount > 0 {
                    Card {
                        HStack {
                            Label("\(dueCount) review\(dueCount == 1 ? "" : "s") due", systemImage: "arrow.triangle.2.circlepath").font(.headline).foregroundStyle(Theme.mastery)
                            Spacer()
                            Button("Review now") { model.startReviews(courseId: course.id) }.buttonStyle(.primary)
                        }
                    }
                }
                Card {
                    VStack(alignment: .leading, spacing: 10) {
                        Picker("Mode", selection: $mode) {
                            Text("Cram for an exam").tag(StudyMode.cram); Text("Mastery (no deadline)").tag(StudyMode.mastery)
                        }.pickerStyle(.segmented).frame(maxWidth: 420)
                        if mode == .cram {
                            Picker("Assessment", selection: $assessmentId) {
                                Text("Choose…").tag(UUID?.none)
                                ForEach(assessments) { Text($0.name).tag(UUID?.some($0.id)) }
                            }.frame(maxWidth: 360)
                            if assessments.isEmpty { Text("Add an assessment first (Assessments tab).").font(.caption).foregroundStyle(Theme.textSecondary) }
                        } else {
                            Text("Favours due reviews, weak skills and skills you haven’t touched lately.").font(.caption).foregroundStyle(Theme.textSecondary)
                        }
                        Picker("Time", selection: $minutes) { ForEach([10, 15, 25, 45, 60, 90], id: \.self) { Text("\($0) min").tag($0) } }.frame(maxWidth: 200)
                        DisclosureGroup("Constraints", isExpanded: $showConstraints) {
                            VStack(alignment: .leading, spacing: 6) {
                                Picker("Highest difficulty", selection: $maxDifficulty) { ForEach(1...5, id: \.self) { Text("\($0)").tag($0) } }.frame(maxWidth: 220)
                                Text("Only these topics (none checked = all in scope)").font(.caption).foregroundStyle(Theme.textSecondary)
                                ForEach(skills) { s in
                                    Toggle(s.name, isOn: Binding(get: { focus.contains(s.id) }, set: { if $0 { focus.insert(s.id) } else { focus.remove(s.id) } }))
                                }
                            }.padding(.top, 4)
                        }
                        HStack {
                            Button("Build plan", action: build).buttonStyle(.primary).disabled(mode == .cram && assessmentId == nil)
                            Button("Quick diagnostic") { diagnostic() }.help("A few short questions on skills with no evidence yet")
                        }
                    }
                }
                if let plan { planView(plan) }
                else {
                    EmptyStateView(symbol: "list.bullet.clipboard", title: "Build a plan", message: "Learn Anyway picks questions from your own evidence. It works offline and explains every suggestion.")
                        .frame(height: 220)
                }
            }.padding(20)
        }
        .task(id: model.revision) { load(); if SnapshotRunner.isActive, plan == nil { mode = .cram; build() } } // screenshot aid
        .onAppear {
            if let t = model.requestedCourseTab, t == "plan" { model.requestedCourseTab = nil }
        }
    }

    @ViewBuilder private func planView(_ plan: StudyPlan) -> some View {
        if !plan.notes.isEmpty {
            Card { VStack(alignment: .leading, spacing: 4) { ForEach(plan.notes, id: \.self) { Label($0, systemImage: "info.circle").font(.callout).foregroundStyle(Theme.attention) } } }
        }
        if plan.items.isEmpty {
            EmptyStateView(symbol: "tray", title: "Nothing to plan yet", message: "Add questions for these skills, loosen the constraints, or give it more time.").frame(height: 180)
        } else {
            let chosen = plan.items.filter { included.contains($0.id) }
            HStack {
                Text("\(chosen.count) of \(plan.items.count) selected · about \(Int(chosen.reduce(0) { $0 + $1.estimatedMinutes }.rounded())) min").foregroundStyle(Theme.textSecondary)
                Spacer()
                Button("Start session") {
                    model.startPlan(chosen, title: plan.assessmentName.map { "\(course.name) · \($0)" } ?? "\(course.name) · \(plan.mode == .cram ? "Cram" : "Mastery")",
                                    courseId: course.id, assessmentId: assessmentId, mode: plan.mode == .cram ? .cram : (plan.items.allSatisfy { $0.kind == .diagnostic } ? .diagnostic : .mastery))
                }.buttonStyle(.primary).disabled(chosen.isEmpty)
            }
            ForEach(plan.items) { item in
                Card {
                    HStack(alignment: .top, spacing: 10) {
                        Toggle("Include", isOn: Binding(get: { included.contains(item.id) }, set: { if $0 { included.insert(item.id) } else { included.remove(item.id) } }))
                            .labelsHidden().accessibilityLabel("Include \(item.title)")
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(spacing: 6) {
                                Text(item.title).font(.headline).lineLimit(1)
                                Badge(text: kindLabel(item.kind), color: kindColor(item.kind))
                                Badge(text: item.type.label, color: Theme.textSecondary)
                                Spacer()
                                Text("~\(Int(max(1, item.estimatedMinutes.rounded()))) min").font(.caption).foregroundStyle(Theme.textSecondary)
                            }
                            Text(item.reason).font(.callout).foregroundStyle(Theme.textSecondary)
                        }
                    }
                }.opacity(included.contains(item.id) ? 1 : 0.5)
            }
        }
    }

    func kindLabel(_ k: ItemKind) -> String { switch k { case .review: "Review"; case .repair: "Repair"; case .advance: "Advance"; case .diagnostic: "Quick check"; case .practice: "Practice" } }
    func kindColor(_ k: ItemKind) -> Color { switch k { case .review: Theme.mastery; case .repair: Theme.attention; case .diagnostic: Theme.accent; default: .secondary } }

    private func load() {
        assessments = (try? model.courses?.assessments(courseId: course.id)) ?? []
        skills = (try? model.courses?.skills(courseId: course.id)) ?? []
        dueCount = (try? model.reviews?.dueCount(courseId: course.id)) ?? 0
        if assessmentId == nil { assessmentId = assessments.first(where: { ($0.deadline ?? .distantPast) > Date() })?.id ?? assessments.first?.id }
        if assessments.isEmpty { mode = .mastery }
    }

    private func build() {
        var r = PlanRequest(courseId: course.id, assessmentId: mode == .cram ? assessmentId : nil, mode: mode, budgetMinutes: minutes)
        r.focusSkillIds = focus; r.maxDifficulty = maxDifficulty < 5 ? maxDifficulty : nil
        model.perform { plan = try model.planner?.plan(r); included = Set(plan?.items.map(\.id) ?? []) }
    }

    private func diagnostic() {
        model.perform { plan = try model.planner?.diagnostic(courseId: course.id, assessmentId: mode == .cram ? assessmentId : nil); included = Set(plan?.items.map(\.id) ?? []) }
    }
}

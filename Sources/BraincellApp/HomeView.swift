import GRDB
import SwiftUI
import BraincellCore

struct HomeView: View {
    @EnvironmentObject var model: AppModel
    @State private var topic = ""
    @State private var courseName = ""
    @State private var rec: Recommendation?
    @State private var dueCount = 0

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.xl) {
                PageHeader(title: model.courseList.isEmpty ? "Welcome to Braincell" : "What to study next", subtitle: "Everything works offline. No account or API key needed.")

                resumeCard
                adaptiveCards

                HStack(alignment: .top, spacing: Theme.Space.lg) {
                    Card {
                        VStack(alignment: .leading, spacing: Theme.Space.md) {
                            Label("Quick Cram", systemImage: "bolt.fill").font(Theme.cardTitle).foregroundStyle(Theme.attention)
                            Text("Start with just a topic. Turn it into a full course later without losing anything.")
                                .font(.callout).foregroundStyle(Theme.textSecondary)
                            TextField("e.g. Java iterators", text: $topic).onSubmit(startCram).accessibilityLabel("Quick Cram topic")
                            Button("Start Quick Cram", action: startCram).disabled(topic.trimmed.isEmpty)
                        }
                    }
                    Card {
                        VStack(alignment: .leading, spacing: Theme.Space.md) {
                            Label("Create Course", systemImage: "graduationcap.fill").font(Theme.cardTitle).foregroundStyle(Theme.accent)
                            Text("Add assessments, deadlines, materials and topics.").font(.callout).foregroundStyle(Theme.textSecondary)
                            TextField("e.g. COMP 211", text: $courseName).onSubmit(createCourse).accessibilityLabel("New course name")
                            Button("Create Course", action: createCourse).buttonStyle(.primary)
                                .disabled(courseName.trimmed.isEmpty)
                        }
                    }
                }

                if !model.courseList.isEmpty {
                    VStack(alignment: .leading, spacing: Theme.Space.md) {
                        Text("Your courses").font(Theme.sectionTitle)
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 250), spacing: Theme.Space.lg)], spacing: Theme.Space.lg) {
                            ForEach(model.courseList) { c in
                                Button { model.open(course: c) } label: { courseCard(c) }.buttonStyle(.plain)
                                    .accessibilityElement(children: .combine).accessibilityHint("Opens the course")
                            }
                        }
                    }
                }

                if !model.onboardingDismissed { checklist }

                HStack {
                    Image(systemName: "flask").foregroundStyle(Theme.textSecondary)
                    Text("Want to look around first?").foregroundStyle(Theme.textSecondary)
                    Button("Load Demo Workspace") { model.loadDemo() }.buttonStyle(.link)
                    Text("Adds a clearly labelled sample course. Delete it by archiving it.").font(.caption).foregroundStyle(Theme.textSecondary)
                }
            }
            .padding(Theme.Space.xxl)
            .frame(maxWidth: 980, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .task(id: model.revision) {
            // Planning reads a lot of data; keep it off the main thread so Home never stutters on big libraries.
            guard let planner = model.planner, let reviews = model.reviews else { return }
            let (r, n) = await Task.detached { (try? planner.recommendation(), (try? reviews.dueCount()) ?? 0) }.value
            rec = r; dueCount = n
        }
    }

    private func courseCard(_ c: Course) -> some View {
        let xp = try? model.progression?.courseXP(c.id)
        return Card {
            VStack(alignment: .leading, spacing: Theme.Space.md) {
                HStack {
                    Image(systemName: c.kind == .quickCram ? "bolt.fill" : "graduationcap.fill").foregroundStyle(c.kind == .quickCram ? Theme.attention : Theme.accent)
                        .frame(width: 36, height: 36).background((c.kind == .quickCram ? Theme.attention : Theme.accent).opacity(0.12), in: RoundedRectangle(cornerRadius: Theme.Radius.control))
                    Spacer()
                    Image(systemName: "chevron.right").font(.caption).foregroundStyle(Theme.textSecondary)
                }
                Text(c.name).font(Theme.cardTitle).lineLimit(2)
                HStack {
                    if c.kind == .quickCram { Badge(text: "Quick Cram", color: Theme.attention) }
                    if let xp { Badge(text: "Level \(xp.level) · \(xp.xp) XP", color: Theme.mastery) }
                }
            }
        }
    }

    @ViewBuilder private var adaptiveCards: some View {
        if dueCount > 0 {
            Card {
                HStack {
                    Label("\(dueCount) review\(dueCount == 1 ? "" : "s") due", systemImage: "arrow.triangle.2.circlepath").font(.headline).foregroundStyle(Theme.mastery)
                    Spacer()
                    Button("Review now") { model.startReviews() }.buttonStyle(.primary)
                }
            }
        }
        if let rec, !rec.plan.items.isEmpty {
            VStack(alignment: .leading, spacing: Theme.Space.sm) {
                Label("Suggested next", systemImage: "wand.and.stars").font(Theme.cardTitle).foregroundStyle(.white.opacity(0.85))
                Text(rec.headline).font(Theme.sectionTitle).foregroundStyle(.white)
                ForEach(rec.plan.items.prefix(3)) { Text("• \($0.title): \($0.reason)").font(.callout).foregroundStyle(.white.opacity(0.85)).lineLimit(2) }
                HStack {
                    Button("Start (\(rec.plan.items.count) questions)") {
                        model.startPlan(rec.plan.items, title: rec.headline, courseId: rec.course.id, assessmentId: rec.assessment?.id, mode: rec.plan.mode == .cram ? .cram : .mastery)
                    }.buttonStyle(.plain).font(.system(.body, design: .rounded, weight: .semibold)).foregroundStyle(Theme.accentHover)
                        .padding(.horizontal, 14).padding(.vertical, 7).background(.white, in: RoundedRectangle(cornerRadius: Theme.Radius.control))
                    Button("Adjust plan…") { model.selectedCourseID = rec.course.id; model.requestedCourseTab = "plan"; model.selection = .courses }
                        .buttonStyle(.plain).foregroundStyle(.white).underline()
                }.padding(.top, Theme.Space.xs)
                Text("Chosen from your own evidence, offline. Every suggestion has a reason.").font(.caption).foregroundStyle(.white.opacity(0.75))
            }
            .padding(Theme.Space.xl).frame(maxWidth: .infinity, alignment: .leading)
            .background(LinearGradient(colors: [Theme.accent, Theme.accentHover], startPoint: .topLeading, endPoint: .bottomTrailing), in: RoundedRectangle(cornerRadius: Theme.Radius.card))
            .environment(\.colorScheme, .dark)
        }
    }

    @ViewBuilder private var resumeCard: some View {
        if let s = model.resumableSession {
            Card {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Label("Continue your session", systemImage: "play.circle.fill").font(.headline).foregroundStyle(Theme.mastery)
                        Text(s.title).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Resume") { model.activeSessionID = s.id }.buttonStyle(.primary)
                }
            }
        }
    }

    private var checklist: some View {
        let st = model.onboarding
        let steps = [ChecklistStep(id: 1, title: "Create a course or start Quick Cram", done: st.course, target: .courses),
                     ChecklistStep(id: 2, title: "Import material or enter topics", done: st.material, target: .courses),
                     ChecklistStep(id: 3, title: "Prepare questions (AI Tasks, or load the demo)", done: st.questions, target: .aiTasks),
                     ChecklistStep(id: 4, title: "Complete your first session", done: st.session, target: .questionBank),
                     ChecklistStep(id: 5, title: "Review your progress", done: st.progress, target: .skills)]
        return Card {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("Getting started").font(.headline)
                    Spacer()
                    Button("Dismiss") { model.dismissOnboarding() }.buttonStyle(.link)
                }
                ForEach(steps) { s in
                    Button { model.selection = s.target } label: {
                        HStack(spacing: 8) {
                            Image(systemName: s.done ? "checkmark.circle.fill" : "circle").foregroundStyle(s.done ? Theme.mastery : .secondary)
                            Text(s.title).foregroundStyle(.primary)
                            Spacer()
                            Image(systemName: "chevron.right").font(.caption).foregroundStyle(.secondary)
                        }
                    }.buttonStyle(.plain).accessibilityElement(children: .combine).accessibilityHint(s.done ? "Done" : "Opens the screen for this step")
                }
            }
        }
    }

    private func startCram() { guard !topic.trimmed.isEmpty else { return }; model.startQuickCram(topic: topic); topic = "" }
    private func createCourse() { guard !courseName.trimmed.isEmpty else { return }; model.createCourse(name: courseName); courseName = "" }
}

struct ChecklistStep: Identifiable { let id: Int; let title: String; let done: Bool; let target: SidebarItem }

extension String { var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) } }

extension AppModel {
    var resumableSession: StudySession? { _ = revision; return try? practice?.resumableSession() }

    /// True when any document exists or a structured course has topics (Quick Cram's seed topic doesn't count).
    var hasMaterial: Bool {
        guard let db else { return false }
        _ = revision
        return (try? db.read { try Int.fetchOne($0, sql: "SELECT (SELECT COUNT(*) FROM documents) + (SELECT COUNT(*) FROM course_skills cs JOIN courses c ON c.id = cs.courseId WHERE c.kind = 'structured')") ?? 0 }).map { $0 > 0 } ?? false
    }
}

import SwiftUI
import Charts
import BraincellCore

/// Evidence-based history. It never predicts an exam grade: where evidence is thin it says so.
struct InsightsView: View {
    @EnvironmentObject var model: AppModel
    @State private var courseId: UUID?
    @State private var days: [StudyDay] = []
    @State private var forecast: [ForecastDay] = []
    @State private var exams: [ExamCoverage] = []
    @State private var skills: [Skill] = []
    @State private var skillId: UUID?
    @State private var trend: [TrendPoint] = []
    @State private var xp: [(day: Date, total: Int)] = []
    @State private var ledger: [XPEvent] = []
    @State private var milestones: [Milestone] = []
    @State private var timeline: [HistoryEntry] = []
    @State private var sessions: [SessionRow] = []
    @State private var attempts: [AttemptRow] = []
    @State private var focusMinutes = 0
    @State private var calibration: CalibrationReport?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Picker("Course", selection: $courseId) { ForEach(model.courseList) { Text($0.name).tag(UUID?.some($0.id)) } }.frame(maxWidth: 280)
                Spacer()
                Text("Based only on what you’ve answered. Learn Anyway doesn’t predict exam grades.").font(.caption).foregroundStyle(Theme.textSecondary)
            }.padding(12).controlStrip()
            if model.courseList.isEmpty {
                EmptyStateView(symbol: "chart.line.uptrend.xyaxis", title: "Not enough evidence yet", message: "Insights are built from your practice. Create a course and answer some questions to see your history here.")
            } else if sessions.isEmpty && attempts.isEmpty {
                EmptyStateView(symbol: "chart.line.uptrend.xyaxis", title: "Not enough evidence yet", message: "Complete a practice session and your study history, mastery trends, XP and mistakes will appear here.",
                               actionTitle: "Start practising") { model.selection = .courses }
            } else { content }
        }
        .task(id: model.revision) { load() }
        .onChange(of: courseId) { _, _ in skillId = nil; load() }
        .onChange(of: skillId) { _, _ in loadTrend() }
        .onAppear { try? model.settings?.set(.viewedProgress, true) }
    }

    private var content: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                examsCard
                HStack(alignment: .top, spacing: 16) { studyCard; reviewsCard }
                trendCard
                xpCard
                historyCard
                recentCard
                calibrationCard
            }.padding(20)
        }
    }

    // MARK: Cards

    private var examsCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 8) {
                Text("Exam coverage").font(.headline)
                if exams.isEmpty { Text("No assessments yet. Add one in the course to see coverage here.").foregroundStyle(Theme.textSecondary) }
                ForEach(exams) { e in
                    VStack(alignment: .leading, spacing: 3) {
                        HStack {
                            Text(e.assessment.name).font(.subheadline.weight(.semibold))
                            if e.assessment.isCumulative { Badge(text: "Cumulative", color: Theme.mastery) }
                            Spacer()
                            if let d = e.daysLeft { Text(d >= 0 ? "in \(d) day\(d == 1 ? "" : "s")" : "passed").font(.caption).foregroundStyle(d >= 0 && d <= 7 ? Theme.attention : .secondary) }
                        }
                        MeterBar(value: Double(e.progress.assessedSkillCount) / Double(max(1, e.progress.skillCount)), tint: Theme.mastery)
                            .accessibilityLabel("\(e.assessment.name) coverage").accessibilityValue("\(e.progress.assessedSkillCount) of \(e.progress.skillCount) topics assessed")
                        Text(e.summary).font(.caption).foregroundStyle(Theme.textSecondary)
                        Text("\(e.progress.attemptedQuestionCount) of \(e.progress.questionCount) questions attempted").font(.caption).foregroundStyle(Theme.textSecondary)
                    }.accessibilityElement(children: .contain)
                }
            }
        }
    }

    private var studyCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 8) {
                Text("Study time, last 30 days").font(.headline)
                let total = days.reduce(0) { $0 + $1.minutes }
                Text("\(Int(total.rounded())) min on answered questions · \(days.reduce(0) { $0 + $1.attempts }) answers" + (focusMinutes > 0 ? " · \(focusMinutes) min of focus timer" : ""))
                    .font(.caption).foregroundStyle(Theme.textSecondary)
                Chart(days, id: \.day) { BarMark(x: .value("Day", $0.day, unit: .day), y: .value("Minutes", $0.minutes)).foregroundStyle(Theme.accent) }
                    .frame(height: 140).chartYAxisLabel("min")
                    .accessibilityLabel("Study minutes per day for the last 30 days, \(Int(total.rounded())) minutes in total")
            }
        }
    }

    private var reviewsCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 8) {
                Text("Reviews due").font(.headline)
                if forecast.allSatisfy({ $0.due == 0 }) {
                    Label("No reviews due in the next week", systemImage: "checkmark.circle").foregroundStyle(Theme.textSecondary)
                } else {
                    Chart(forecast, id: \.day) { BarMark(x: .value("Day", $0.day, unit: .day), y: .value("Cards", $0.due)).foregroundStyle(Theme.mastery) }
                        .frame(height: 140).accessibilityLabel("Reviews due per day over the next week")
                    Text("Today includes anything overdue.").font(.caption).foregroundStyle(Theme.textSecondary)
                }
            }
        }
    }

    private var trendCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Skill changes over time").font(.headline)
                    Picker("Skill", selection: $skillId) { Text("Choose a skill").tag(UUID?.none); ForEach(skills) { Text($0.name).tag(UUID?.some($0.id)) } }.frame(maxWidth: 260)
                }
                let pts = trend.filter { $0.overall != nil }
                if skillId == nil { Text("Pick a skill to see how its estimate has moved.").foregroundStyle(Theme.textSecondary) }
                else if pts.count < 2 { Text("Not enough evidence yet: a trend needs at least two graded answers (\(pts.count) so far).").foregroundStyle(Theme.textSecondary) }
                else {
                    Chart(pts, id: \.at) { LineMark(x: .value("Date", $0.at), y: .value("Estimate", ($0.overall ?? 0) * 100)).foregroundStyle(Theme.mastery); PointMark(x: .value("Date", $0.at), y: .value("Estimate", ($0.overall ?? 0) * 100)).foregroundStyle(Theme.mastery) }
                        .chartYScale(domain: 0...100).frame(height: 160).chartYAxisLabel("est. %")
                        .accessibilityLabel("Estimated mastery over time, \(pts.count) points")
                    Text("Each point is one graded answer. Early points rest on little evidence.").font(.caption).foregroundStyle(Theme.textSecondary)
                }
            }
        }
    }

    private var calibrationCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 8) {
                Text("How well does the mastery estimate predict you?").font(.headline)
                if let r = calibration, let cur = r.current {
                    Text("Each answer is predicted from your earlier answers only, then compared with what you scored. \(r.predictions) predictions across \(r.skills) skills. Lower error is better.")
                        .font(.caption).foregroundStyle(Theme.textSecondary)
                    if !r.enoughData { Label("Fewer than \(CalibrationReport.minimumPredictions) predictions: too early to read anything into this, and no changes are suggested.", systemImage: "info.circle").font(.callout).foregroundStyle(Theme.textSecondary) }
                    HStack(spacing: 24) {
                        VStack(alignment: .leading) { Text("Estimator error").font(.caption).foregroundStyle(Theme.textSecondary); Text(String(format: "%.3f", cur.brier)).font(.title3.monospacedDigit()) }
                        if let b = r.baseline { VStack(alignment: .leading) { Text("Plain average").font(.caption).foregroundStyle(Theme.textSecondary); Text(String(format: "%.3f", b.brier)).font(.title3.monospacedDigit()) } }
                        if let bias = r.bias { VStack(alignment: .leading) { Text("Tendency").font(.caption).foregroundStyle(Theme.textSecondary); Text(abs(bias) < 0.05 ? "Balanced" : bias > 0 ? "Too optimistic" : "Too pessimistic").font(.title3) } }
                    }.accessibilityElement(children: .combine)
                    ForEach(r.bins, id: \.lower) { b in
                        Text("Predicted \(Int(b.meanPredicted * 100))% → scored \(Int(b.meanActual * 100))% (\(b.count) answers)").font(.callout.monospacedDigit())
                    }
                    if let s = r.suggestion { Label(s, systemImage: "lightbulb").font(.callout) }
                } else {
                    Text("Not enough data yet. This needs at least two answers on the same skill.").font(.callout).foregroundStyle(Theme.textSecondary)
                }
            }
        }
    }

    private var xpCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 8) {
                Text("XP and milestones").font(.headline)
                if let t = xp.last?.total { Text("\(t) XP (course level \(XPRules.level(forXP: t))). XP rewards effort and is separate from mastery.").font(.caption).foregroundStyle(Theme.textSecondary) }
                if xp.count >= 2 { Chart(xp, id: \.day) { LineMark(x: .value("Day", $0.day, unit: .day), y: .value("XP", $0.total)).foregroundStyle(Theme.accent) }.frame(height: 110).accessibilityLabel("Cumulative XP by day") }
                ForEach(milestones.prefix(6)) { m in Label(m.title, systemImage: "flag.fill").font(.callout) }
                DisclosureGroup("Ledger (every award and correction)") {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(ledger.prefix(30)) { e in
                            HStack {
                                Text(e.createdAt.formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundStyle(Theme.textSecondary).frame(width: 130, alignment: .leading)
                                Text(e.reason).lineLimit(1)
                                Spacer()
                                Text(e.amount > 0 ? "+\(e.amount)" : "\(e.amount)").monospacedDigit().foregroundStyle(e.kind == .correction ? Theme.attention : Theme.accent)
                            }.font(.callout).accessibilityElement(children: .combine)
                        }
                    }.padding(.top, 4)
                }
            }
        }
    }

    private var historyCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 8) {
                Text("Learning history").font(.headline)
                Text("Mistakes, notes and breakthroughs in one place. Observed from your answers, not guessed.").font(.caption).foregroundStyle(Theme.textSecondary)
                if timeline.isEmpty { Text("Nothing here yet.").foregroundStyle(Theme.textSecondary) }
                ForEach(timeline.prefix(25)) { e in
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: icon(e.kind)).foregroundStyle(color(e.kind)).frame(width: 20)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(e.title)
                            if !e.detail.isEmpty { Text(e.detail).font(.caption).foregroundStyle(Theme.textSecondary) }
                        }
                        Spacer()
                        Text(e.at.formatted(date: .abbreviated, time: .omitted)).font(.caption).foregroundStyle(Theme.textSecondary)
                    }.accessibilityElement(children: .combine)
                }
            }
        }
    }

    private var recentCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 8) {
                Text("Recent sessions").font(.headline)
                ForEach(sessions.prefix(6)) { s in
                    HStack {
                        VStack(alignment: .leading) { Text(s.session.title); Text(s.session.startedAt.formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundStyle(Theme.textSecondary) }
                        Spacer()
                        Text("\(s.answered)/\(s.total) answered").font(.callout)
                        Text("\(s.correct) correct\(s.pending > 0 ? " · \(s.pending) waiting" : "")").font(.caption).foregroundStyle(Theme.textSecondary)
                        Text("+\(s.xp) XP").font(.caption).foregroundStyle(Theme.accent)
                    }.accessibilityElement(children: .combine)
                }
                DisclosureGroup("Recent answers") {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(attempts.prefix(15)) { a in
                            HStack {
                                Text(a.title).lineLimit(1)
                                Spacer()
                                Text(verdict(a.evaluation)).font(.caption).foregroundStyle(Theme.textSecondary)
                                if a.attempt.hintsUsed > 0 { Image(systemName: "lightbulb").font(.caption).foregroundStyle(Theme.textSecondary).accessibilityLabel("\(a.attempt.hintsUsed) hints used") }
                            }.font(.callout).accessibilityElement(children: .combine)
                        }
                    }.padding(.top, 4)
                }
            }
        }
    }

    // MARK: Helpers

    private func verdict(_ e: Evaluation?) -> String {
        guard let e else { return "Waiting" }
        switch e.state {
        case .graded: return GradePanel.verdictText(e)
        case .pending, .evaluatorUnavailable: return "Waiting for grade"
        case .needsReview: return "Needs review"
        }
    }
    private func icon(_ k: HistoryKind) -> String { switch k { case .mistake: "arrow.triangle.2.circlepath"; case .reflection: "square.and.pencil"; case .breakthrough: "sparkles"; case .milestone: "flag.fill"; case .focus: "timer" } }
    private func color(_ k: HistoryKind) -> Color { switch k { case .mistake: Theme.attention; case .breakthrough, .milestone: Theme.mastery; default: Theme.accent } }

    /// Everything the screen shows, gathered off the main thread.
    struct Snapshot: Sendable {
        var days: [StudyDay] = [], forecast: [ForecastDay] = [], exams: [ExamCoverage] = [], skills: [Skill] = []
        var xp: [(day: Date, total: Int)] = [], ledger: [XPEvent] = [], milestones: [Milestone] = []
        var timeline: [HistoryEntry] = [], sessions: [SessionRow] = [], attempts: [AttemptRow] = [], focusMinutes = 0
        var calibration: CalibrationReport?
    }

    private func load() {
        if courseId == nil || !model.courseList.contains(where: { $0.id == courseId }) { courseId = model.selectedCourseID ?? model.courseList.first?.id }
        guard let c = courseId, let db = model.db else { return }
        Task {
            let snap: Snapshot = await Task.detached {
                let ins = InsightsService(db: db), pg = ProgressionService(db: db)
                var s = Snapshot()
                s.days = (try? ins.studyDays(courseId: c)) ?? []
                s.forecast = (try? ins.forecast(courseId: c)) ?? []
                s.exams = (try? ins.exams(courseId: c)) ?? []
                s.skills = (try? CourseService(db: db).skills(courseId: c)) ?? []
                s.xp = (try? ins.xpTrend(courseId: c)) ?? []
                s.ledger = (try? pg.ledger(courseId: c)) ?? []
                s.milestones = (try? pg.milestones(courseId: c)) ?? []
                s.timeline = (try? ins.timeline(courseId: c)) ?? []
                s.sessions = (try? ins.sessions(courseId: c)) ?? []
                s.attempts = (try? ins.attempts(courseId: c)) ?? []
                s.calibration = try? ins.calibration(courseId: c)
                s.focusMinutes = ((try? FocusService(db: db).focusSeconds(since: Date().addingTimeInterval(-30 * 86_400))) ?? 0) / 60
                return s
            }.value
            guard c == courseId else { return }                         // the learner switched courses while this loaded
            days = snap.days; forecast = snap.forecast; exams = snap.exams; skills = snap.skills; xp = snap.xp; ledger = snap.ledger
            milestones = snap.milestones; timeline = snap.timeline; sessions = snap.sessions; attempts = snap.attempts; focusMinutes = snap.focusMinutes; calibration = snap.calibration
            if SnapshotRunner.isActive, skillId == nil, let ins = model.db.map({ InsightsService(db: $0) }) {
                skillId = skills.first { s in ((try? ins.skillTrend(skillId: s.id))?.count ?? 0) >= 2 }?.id // screenshot aid
            }
            loadTrend()
        }
    }

    private func loadTrend() {
        guard let s = skillId, let ins = model.db.map({ InsightsService(db: $0) }) else { trend = []; return }
        trend = (try? ins.skillTrend(skillId: s)) ?? []
    }
}

import SwiftUI
import BraincellCore

struct PracticeSetupRequest: Identifiable { let id = UUID(); var courseId: UUID; var assessmentId: UUID? = nil; var skillIds: Set<UUID> = [] }

/// Choose what to practise: course/assessment, topics, count, difficulty, question types and mode. Study priority only changes how
/// questions are spread across topics; it is never presented as the real exam split.
struct PracticeSetupSheet: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let request: PracticeSetupRequest
    @State private var assessmentId: UUID?
    @State private var kind: PracticeKind = .mixed
    @State private var rows: [TopicRow] = []
    @State private var topics: Set<UUID> = []
    @State private var count = 10
    @State private var difficulty: PracticeDifficulty = .mixed
    @State private var types: Set<QuestionType> = []
    @State private var available: [PracticeCandidate] = []
    @State private var timed = false
    @State private var assessments: [Assessment] = []

    private var course: Course? { model.courseList.first { $0.id == request.courseId } }
    private var presentTypes: [QuestionType] { QuestionType.allCases.filter { t in available.contains { $0.type == t } } }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Start practice · \(course?.name ?? "")").font(.headline)
            Picker("Mode", selection: $kind) { ForEach(PracticeKind.allCases) { Text($0.rawValue).tag($0) } }.pickerStyle(.segmented).labelsHidden()
            Text(kind == .topic ? "Pick one or more topics." : kind == .mixed ? "A mix across the chosen topics, leaning toward higher-priority ones." : "A set across all in-scope topics" + (timed ? ", timed with no coaching interruptions." : "."))
                .font(.caption).foregroundStyle(Theme.textSecondary)
            HStack {
                Picker("Assessment", selection: $assessmentId) { Text("Whole course").tag(UUID?.none); ForEach(assessments) { Text($0.name).tag(UUID?.some($0.id)) } }.frame(maxWidth: 260)
                Stepper("Questions: \(count)", value: $count, in: 1...60)
                Picker("Difficulty", selection: $difficulty) { ForEach(PracticeDifficulty.allCases) { Text($0.rawValue).tag($0) } }.frame(maxWidth: 170)
            }
            if kind == .exam { Toggle("Timed (no coaching nudges)", isOn: $timed) }
            if !presentTypes.isEmpty {
                Text("Question types").font(.caption.weight(.semibold)).foregroundStyle(Theme.textSecondary)
                HStack { ForEach(presentTypes, id: \.self) { t in Toggle(t.label, isOn: Binding(get: { types.contains(t) }, set: { if $0 { types.insert(t) } else { types.remove(t) } })).toggleStyle(.button).controlSize(.small) } }
            }
            if kind != .exam {
                Text("Topics").font(.caption.weight(.semibold)).foregroundStyle(Theme.textSecondary)
                List(rows) { r in
                    Toggle(isOn: Binding(get: { topics.contains(r.id) }, set: { if $0 { topics.insert(r.id) } else { topics.remove(r.id) } })) {
                        HStack { Text(r.skill.name).padding(.leading, CGFloat(r.depth) * 14); Spacer(); Text("\(r.questionCount) q").font(.caption).foregroundStyle(Theme.textSecondary) }
                    }
                }.frame(minHeight: 140).listStyle(.bordered)
            }
            Text("\(matching) matching question(s) available.").font(.caption).foregroundStyle(matching == 0 ? Theme.attention : Theme.textSecondary)
            HStack { Spacer(); Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction); Button("Start") { start() }.buttonStyle(.primary).keyboardShortcut(.defaultAction).disabled(matching == 0 || (kind == .topic && topics.isEmpty)) }
        }
        .padding(Theme.Space.xl).frame(width: 600, height: 560).background(Theme.background)
        .onAppear { assessmentId = request.assessmentId; topics = request.skillIds; if !request.skillIds.isEmpty { kind = .topic }; load() }
        .onChange(of: assessmentId) { _, _ in load() }
    }

    private var chosenSkills: Set<UUID> { kind == .exam ? [] : topics }
    private var matching: Int { PracticeSelector.select(available, count: 10_000, skills: chosenSkills, weights: [:], difficulty: difficulty, types: types).count }

    private func load() {
        guard let cs = model.courses, let st = model.agentStore, let pr = model.practice else { return }
        assessments = (try? cs.assessments(courseId: request.courseId)) ?? []
        rows = (try? cs.topicRows(courseId: request.courseId, assessmentId: assessmentId, store: st))?.filter { $0.inScope } ?? []
        available = (try? pr.candidates(courseId: request.courseId, assessmentId: assessmentId)) ?? []
    }

    private func start() {
        let weights: [UUID: Double] = Dictionary(uniqueKeysWithValues: rows.compactMap { r -> (UUID, Double)? in
            switch r.weight { case .official(let p): (r.id, p); case .estimate(let p): p.map { (r.id, $0) }; default: nil }
        })
        let ids = PracticeSelector.select(available, count: count, skills: chosenSkills, weights: kind == .topic ? [:] : weights, difficulty: difficulty, types: types)
        let title = [course?.name, assessments.first { $0.id == assessmentId }?.name, kind.rawValue].compactMap { $0 }.joined(separator: " · ")
        model.perform {
            if kind == .exam { model.activeSessionID = try model.practice?.start(planned: ids.map { .init(questionId: $0, kind: .practice, reason: "Exam practice") }, title: title, courseId: request.courseId, assessmentId: assessmentId, mode: .free, timed: timed).id }
            else { model.activeSessionID = try model.practice?.start(questionIds: ids, title: title, courseId: request.courseId, assessmentId: assessmentId).id }
        }
        dismiss()
    }
}

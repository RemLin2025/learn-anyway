import SwiftUI
import GRDB
import BraincellCore

struct SkillsView: View {
    @EnvironmentObject var model: AppModel
    @State private var courseId: UUID?
    @State private var rows: [SkillTree.Row] = []
    @State private var masteries: [UUID: SkillMastery] = [:]
    @State private var xp: [UUID: XPSummary] = [:]
    @State private var selected: UUID?
    @State private var relations: [SkillRelation] = []
    @State private var allSkills: [Skill] = []
    @State private var asMap = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Picker("Course", selection: $courseId) {
                    ForEach(model.courseList) { Text($0.name).tag(UUID?.some($0.id)) }
                }.frame(maxWidth: 260)
                if let c = courseId, let s = try? model.progression?.courseXP(c) {
                    Badge(text: "Course level \(s.level) · \(s.xp) XP")
                }
                Spacer()
                Picker("View", selection: $asMap) { Label("List", systemImage: "list.bullet").tag(false); Label("Map", systemImage: "point.3.connected.trianglepath.dotted").tag(true) }
                    .pickerStyle(.segmented).labelsHidden().frame(width: 130)
            }.padding(12)
            Divider()
            if model.courseList.isEmpty {
                EmptyStateView(symbol: "point.3.connected.trianglepath.dotted", title: "No skills yet", message: "Create a course and add topics; mastery appears here as you practise.")
            } else if rows.isEmpty {
                EmptyStateView(symbol: "list.bullet.indent", title: "No topics in this course", message: "Add topics under Courses → Topics.")
            } else {
                HSplitView {
                    Group {
                    if asMap { SkillMapView(skills: allSkills, relations: relations, masteries: masteries, selected: $selected) }
                    else { List(rows, id: \.skill.id, selection: $selected) { r in
                        let m = masteries[r.skill.id], x = xp[r.skill.id]
                        HStack {
                            Text(r.skill.name).padding(.leading, CGFloat(r.depth) * 16)
                            Spacer()
                            Badge(text: "Lv \(x?.level ?? 1)", color: Theme.accent)
                            if let m, !m.isUnknown { Badge(text: m.confidence.label, color: color(m.confidence)) } else { Badge(text: "Unknown", color: .secondary) }
                        }.tag(r.skill.id).accessibilityElement(children: .combine)
                    } }
                    }.frame(minWidth: 300, idealWidth: 420)
                    Group {
                        if let id = selected, let r = rows.first(where: { $0.skill.id == id }), let m = masteries[id] {
                            SkillDetail(skill: r.skill, mastery: m, xp: xp[id] ?? XPSummary(xp: 0), courseId: courseId!).id("\(id)-\(model.revision)")
                        } else { EmptyStateView(symbol: "chart.bar.doc.horizontal", title: "Select a skill", message: "See what you’ve shown, how sure Braincell is, and what evidence backs it.") }
                    }.frame(minWidth: 380)
                }
            }
        }
        .task(id: model.revision) { load() }
        .onAppear { try? model.settings?.set(.viewedProgress, true); if model.snapshotMap { asMap = true } }
        .onChange(of: model.snapshotMap) { _, v in asMap = v }
        .onChange(of: courseId) { _, _ in selected = nil; load() }
    }

    private func color(_ c: ConfidenceLevel) -> Color { c == .strong ? Theme.mastery : (c == .moderate ? Theme.accent : Theme.attention) }

    private func load() {
        if courseId == nil || !model.courseList.contains(where: { $0.id == courseId }) { courseId = model.selectedCourseID ?? model.courseList.first?.id }
        guard let c = courseId, let cs = model.courses, let pg = model.progression else { rows = []; return }
        let skills = (try? cs.skills(courseId: c)) ?? []
        allSkills = skills; relations = (try? cs.relations(courseId: c)) ?? []
        rows = SkillTree.flatten(skills, relations: relations)
        masteries = (try? pg.masteries(courseId: c)) ?? [:]
        xp = Dictionary(uniqueKeysWithValues: skills.compactMap { s in (try? pg.skillXP(s.id)).map { (s.id, $0) } })
        if SnapshotRunner.isActive, selected == nil { selected = rows.first { masteries[$0.skill.id]?.isUnknown == false }?.skill.id } // screenshot aid
    }
}

struct SkillDetail: View {
    @EnvironmentObject var model: AppModel
    let skill: Skill
    let mastery: SkillMastery
    let xp: XPSummary
    let courseId: UUID

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text(skill.name).font(.title2.weight(.semibold))
                Card {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack { Label("Level \(xp.level)", systemImage: "sparkles").font(.headline).foregroundStyle(Theme.accent); Spacer(); Text("\(xp.xp) XP").foregroundStyle(.secondary) }
                        MeterBar(value: Double(xp.xpIntoLevel) / Double(max(1, xp.xpForNextLevel)), tint: Theme.accent)
                            .accessibilityLabel("Progress to next level").accessibilityValue("\(xp.xpIntoLevel) of \(xp.xpForNextLevel) XP")
                        Text("XP rewards effort and is separate from mastery below.").font(.caption).foregroundStyle(.secondary)
                    }
                }
                Card {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Text("Mastery").font(.headline)
                            Badge(text: mastery.isUnknown ? "Unknown" : mastery.confidence.label, color: mastery.isUnknown ? .secondary : Theme.mastery)
                        }
                        if mastery.isUnknown {
                            Text("Unknown — there’s no graded evidence for this skill yet. That doesn’t mean you don’t know it; it hasn’t been assessed.").font(.callout).foregroundStyle(.secondary)
                        } else {
                            if let o = mastery.overall {
                                HStack { MeterBar(value: o, tint: Theme.mastery); Text("≈ \(Int((o * 100).rounded()))%").monospacedDigit() }
                                    .accessibilityElement(children: .combine).accessibilityLabel("Estimated mastery about \(Int((o * 100).rounded())) percent, \(mastery.confidence.label) confidence")
                            }
                            Text(confidenceNote).font(.caption).foregroundStyle(.secondary)
                            if let q = mastery.evidenceQuality {
                                Text("Evidence quality: \(Int((q * 100).rounded()))% of the weight comes from verified or ChatGPT-graded answers; the rest is provisional or self-reviewed.")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        Divider()
                        ForEach(mastery.dimensions, id: \.dimension) { d in
                            HStack {
                                Text(d.dimension.label).frame(width: 170, alignment: .leading)
                                if let e = d.estimate {
                                    MeterBar(value: e, tint: Theme.mastery)
                                    Text("\(Int((e * 100).rounded()))%").monospacedDigit().frame(width: 40, alignment: .trailing)
                                    Badge(text: d.confidence.label, color: .secondary)
                                } else { Text("Not assessed").foregroundStyle(.secondary); Spacer() }
                            }.accessibilityElement(children: .combine)
                        }
                    }
                }
                evidence
                mistakes
                HStack {
                    Button { practice() } label: { Label("Practice this skill", systemImage: "play.fill") }.buttonStyle(.primary)
                    Button {
                        let weak = mastery.dimensions.filter { ($0.estimate ?? 0) < 0.6 }.map { $0.dimension.label.lowercased() }
                        model.generateRequest = GenerateRequest(courseId: courseId, skillIds: [skill.id],
                            notes: mastery.isUnknown ? "Create new questions for “\(skill.name)”." : "Create new questions for “\(skill.name)”, focusing on the weaker areas (\(weak.isEmpty ? "all four dimensions" : weak.joined(separator: ", "))).")
                    } label: { Label("Request new questions…", systemImage: "square.and.pencil") }
                }
            }.padding(20).frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder private var mistakes: some View {
        let ms = ((try? model.history?.mistakes(courseId: courseId, limit: 60)) ?? []).filter { $0.skillNames.contains(skill.name) }.prefix(4)
        if !ms.isEmpty {
            Card {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Recent mistakes").font(.headline)
                    Text("Observed from your answers. They’re information, not a verdict.").font(.caption).foregroundStyle(.secondary)
                    ForEach(Array(ms)) { m in
                        VStack(alignment: .leading, spacing: 2) {
                            HStack {
                                Text(m.title).lineLimit(1)
                                if m.timesMissed > 1 { Badge(text: "missed \(m.timesMissed)×", color: Theme.attention) }
                                if m.wasHighConfidence { Badge(text: "you felt sure", color: Theme.accent) }
                                Spacer()
                            }
                            if !m.responseSnippet.isEmpty { Text("You answered: \(m.responseSnippet)").font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                        }.accessibilityElement(children: .combine)
                    }
                }
            }
        }
    }

    private var confidenceNote: String {
        switch mastery.confidence {
        case .preliminary: "Early estimate from very little evidence. It will firm up as you answer more varied questions."
        case .moderate: "Moderate confidence: several answers support this."
        case .strong: "Strong confidence: plenty of varied, recent evidence."
        case .unknown: ""
        }
    }

    @ViewBuilder private var evidence: some View {
        let items = (try? model.progression?.evidence(skillId: skill.id)) ?? []
        if !items.isEmpty {
            Card {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Recent evidence (\(items.count))").font(.headline)
                    ForEach(items.prefix(8)) { e in
                        HStack {
                            Text((try? model.db?.read { try QuestionRevision.fetchOne($0, key: e.revisionId)?.title }) ?? "Question").lineLimit(1)
                            Spacer()
                            Text(e.dimension.label).font(.caption).foregroundStyle(.secondary)
                            Text("\(Int((e.score * 100).rounded()))%").monospacedDigit().foregroundStyle(e.score >= 0.8 ? Theme.mastery : Theme.attention)
                            if e.hintsUsed > 0 { Image(systemName: "lightbulb").foregroundStyle(.secondary).help("\(e.hintsUsed) hint(s) used") }
                        }.font(.callout).accessibilityElement(children: .combine)
                    }
                }
            }
        }
    }

    private func practice() {
        var f = QuestionFilter(); f.skillId = skill.id
        let ids = ((try? model.questions?.list(f)) ?? []).map(\.id)
        if ids.isEmpty { model.alertMessage = "No questions are tagged with “\(skill.name)” yet." }
        else { model.startPractice(questionIds: ids, title: skill.name, courseId: courseId) }
    }
}

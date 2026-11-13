import SwiftUI
import BraincellCore

/// Practice sets for one assessment: saved, reusable, and presentable in any compatible template. Everything here goes through `PracticeSetService`;
/// there is no second generation path.
struct PracticeSetsSection: View {
    @EnvironmentObject var model: AppModel
    let course: Course
    let assessment: Assessment?
    @State private var sets: [PracticeSet] = []
    @State private var showNew = false
    @State private var open: PracticeSet?

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.sm) {
            HStack {
                Text("Practice Sets").font(Theme.sectionTitle)
                Spacer()
                Button { model.courseTabRequest = "templates"; model.selectedCourseID = course.id } label: { Label("Templates", systemImage: "square.grid.2x2") }.buttonStyle(.secondary)
                Button { showNew = true } label: { Label("New Practice Set", systemImage: "plus") }.buttonStyle(.primary)
            }
            if sets.isEmpty {
                Text("No practice sets yet. Create one: saved questions are reused, and only what’s missing is generated.").font(.callout).foregroundStyle(Theme.textSecondary)
            } else {
                ScrollView {
                    VStack(spacing: 6) {
                        ForEach(sets) { s in
                            Button { open = s } label: { row(s) }.buttonStyle(.plain)
                        }
                    }
                }
            }
        }
        .padding(Theme.Space.lg)
        .task(id: "\(model.revision)\(assessment?.id.uuidString ?? "")") { load() }
        .onChange(of: model.openPracticeSetID) { _, id in
            if let id, let s = try? model.practiceSets?.practiceSet(id) { open = s; model.openPracticeSetID = nil }
        }
        .sheet(isPresented: $showNew) { NewPracticeSetSheet(course: course, assessment: assessment) { id in showNew = false; load(); open = try? model.practiceSets?.practiceSet(id) } }
        .sheet(item: $open) { PracticeSetDetailSheet(course: course, set: $0) }
    }

    private func load() { sets = ((try? model.practiceSets?.sets(courseId: course.id)) ?? []).filter { assessment == nil || $0.assessmentId == assessment?.id } }

    private func row(_ s: PracticeSet) -> some View {
        let it = (try? model.practiceSets?.items(setId: s.id)) ?? [], filled = it.filter { $0.questionId != nil }.count, reused = it.filter { $0.origin == "reused" }.count
        return HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(s.title).font(Theme.cardTitle)
                Text("\(s.createdAt.formatted(date: .abbreviated, time: .shortened)) · \(filled)/\(it.count) ready · \(reused) reused" + (s.fresh ? " · fresh" : "")).font(.caption).foregroundStyle(Theme.textSecondary)
            }
            Spacer()
            if filled < it.count { Badge(text: "\(it.count - filled) to generate", color: Theme.attention) }
            Image(systemName: "chevron.right").foregroundStyle(Theme.textSecondary)
        }.padding(10).background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.control)).overlay(RoundedRectangle(cornerRadius: Theme.Radius.control).strokeBorder(Theme.border)).contentShape(Rectangle())
    }
}

struct NewPracticeSetSheet: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let course: Course
    let assessment: Assessment?
    let created: (UUID) -> Void
    @State private var count = 10
    @State private var minD = 1
    @State private var maxD = 5
    @State private var format: QuestionType?
    @State private var fresh = false
    @State private var mode: GenerationMode = .similarReasoning
    @State private var skills: [Skill] = []
    @State private var chosen: Set<UUID> = []
    @State private var busy = false
    @State private var status = ""
    @State private var task: Task<Void, Never>?

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.md) {
            Text("New Practice Set").font(Theme.sectionTitle)
            Text(assessment.map { "For \($0.name)" } ?? "For \(course.name)").foregroundStyle(Theme.textSecondary)
            Stepper("Questions: \(count)", value: $count, in: 1...30)
            HStack { Stepper("Min difficulty: \(minD)", value: $minD, in: 1...maxD); Stepper("Max: \(maxD)", value: $maxD, in: minD...5) }
            FilterMenu(title: "Format", selection: $format, options: QuestionType.allCases.map { ($0, $0.rawValue.replacingOccurrences(of: "_", with: " ").capitalized) }, anyLabel: "Any format")
            FilterMenu(title: "Style", selection: Binding(get: { Optional(mode) }, set: { mode = $0 ?? .similarReasoning }), options: GenerationMode.allCases.map { ($0, $0.title) }, allowsAny: false)
            Toggle("Fresh questions only (never reuse questions already practised or in another set)", isOn: $fresh)
            if !skills.isEmpty {
                Text("Topics (optional)").font(.callout.weight(.semibold))
                ScrollView { VStack(alignment: .leading) { ForEach(skills) { s in Toggle(s.name, isOn: Binding(get: { chosen.contains(s.id) }, set: { if $0 { chosen.insert(s.id) } else { chosen.remove(s.id) } })) } } }.frame(maxHeight: 120)
            }
            Text("Compatible saved questions are reused first; only the missing ones are generated. This needs a configured model (Settings → AI); the manual ChatGPT bridge can’t fill practice sets.").font(.caption).foregroundStyle(Theme.textSecondary)
            if busy { HStack { ProgressView().controlSize(.small); Text(status) } }
            HStack { Spacer(); Button("Cancel") { task?.cancel(); dismiss() }.keyboardShortcut(.cancelAction); Button("Create") { create() }.buttonStyle(.primary).disabled(busy) }
        }
        .dialogSurface(width: 480)
        .onAppear { skills = ((try? model.courses?.skills(courseId: course.id)) ?? []).filter { $0.archivedAt == nil } }
    }

    private func create() {
        guard let svc = model.practiceSets, let gw = model.gateway else { return }
        busy = true; status = "Planning…"
        let params = GenerationParams(count: count, types: format.map { [$0] } ?? [], minDifficulty: minD, maxDifficulty: maxD, skillIds: Array(chosen), documentIds: [], mode: mode)
        let cid = course.id, aid = assessment?.id, fr = fresh
        task = Task {
            do {
                let p = try await Task.detached { try svc.prepare(courseId: cid, assessmentId: aid, params: params, fresh: fr) }.value
                if p.missing > 0 { status = "Generating \(p.missing) new question\(p.missing == 1 ? "" : "s")…"; _ = try await svc.generateMissing(setId: p.set.id, gateway: gw) }
                model.reload(); busy = false; created(p.set.id)
            } catch is CancellationError { busy = false }
            catch { model.alertMessage = error.localizedDescription + " The set was saved; open it to finish generating."; busy = false; model.reload(); dismiss() }
        }
    }
}

struct PracticeSetDetailSheet: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let course: Course?
    let set: PracticeSet
    var initialTemplateId: String? = nil
    @State private var items: [PracticeSetItem] = []
    @State private var specs: [UUID: PracticeSetService.SetQuestion] = [:]
    @State private var templates: [LearningTemplate] = []
    @State private var templateId = LearningTemplate.interactive.id
    @State private var working = false
    @State private var worksheet: Worksheet?

    private var template: LearningTemplate { templates.first { $0.id == templateId } ?? .interactive }
    private var compat: SetCompatibility? { model.templates?.compatibility(template: template, items: items.compactMap { i in i.questionId.flatMap { specs[$0] }.map { ($0.id, $0.spec, $0.topic) } }) }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.md) {
            HStack { Text(set.title).font(Theme.sectionTitle); Spacer(); Button("Done") { dismiss() }.keyboardShortcut(.cancelAction) }
            let missing = items.filter { $0.questionId == nil }.count
            if missing > 0 {
                HStack { Badge(text: "\(missing) not generated yet", color: Theme.attention)
                    Button(working ? "Generating…" : "Finish generating") { finish() }.disabled(working).buttonStyle(.secondary) }
            }
            HStack {
                FilterMenu(title: "Template", selection: Binding(get: { Optional(templateId) }, set: { templateId = $0 ?? templateId }), options: templates.map { ($0.id, $0.name) }, allowsAny: false)
                if let c = compat { Text("\(c.usable.count) of \(items.filter { $0.questionId != nil }.count) questions fit").font(.caption).foregroundStyle(Theme.textSecondary) }
                Spacer()
                if template.kind == .examWorksheet { Button { makeWorksheet() } label: { Label("Worksheet PDF", systemImage: "doc.richtext") }.buttonStyle(.primary).disabled(working || (compat?.usable.isEmpty ?? true)) }
                else { Button { model.startSetSession(setId: set.id, template: template); dismiss() } label: { Label("Practice", systemImage: "play.fill") }.buttonStyle(.primary).disabled(compat?.usable.isEmpty ?? true) }
            }
            if let c = compat, !c.skipped.isEmpty { DisclosureGroup("\(c.skipped.count) question(s) not shown in this template") { ForEach(c.skipped.indices, id: \.self) { Text(c.skipped[$0].reason).font(.caption).foregroundStyle(Theme.textSecondary) } }.font(.caption) }
            List(items.indices, id: \.self) { i in row(items[i]) }.frame(minHeight: 220)
        }
        .dialogSurface(width: 640)
        .onAppear { reload() }
        .sheet(item: $worksheet) { WorksheetSheet(worksheet: $0, title: set.title) }
    }

    @ViewBuilder private func row(_ it: PracticeSetItem) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text("\(it.position + 1).").monospacedDigit().foregroundStyle(Theme.textSecondary)
            if let q = it.questionId, let s = specs[q] {
                VStack(alignment: .leading, spacing: 2) {
                    Text(s.spec.title).font(.callout.weight(.medium))
                    Text("\(s.topic ?? "") · \(s.spec.type.rawValue.replacingOccurrences(of: "_", with: " ")) · difficulty \(s.spec.difficulty)").font(.caption).foregroundStyle(Theme.textSecondary)
                    if let v = try? model.practiceSets?.verification(questionId: q) { Text(v.text).font(.caption2).foregroundStyle(v.level == .recomputed ? Theme.mastery : v.level == .failed ? Theme.error : Theme.textSecondary) }
                }
                Spacer(); Badge(text: it.origin == "reused" ? "Reused" : "Generated", color: it.origin == "reused" ? Theme.accent : Theme.mastery)
            } else { Text("Not generated yet").foregroundStyle(Theme.attention); Spacer() }
        }
    }

    private func reload() {
        items = (try? model.practiceSets?.items(setId: set.id)) ?? []
        specs = Dictionary(uniqueKeysWithValues: ((try? model.practiceSets?.questions(setId: set.id)) ?? []).map { ($0.id, $0) })
        templates = (try? model.templates?.all(courseId: course?.id)) ?? LearningTemplate.builtIns
        if let t = initialTemplateId, templates.contains(where: { $0.id == t }) { templateId = t }
    }
    private func finish() {
        guard let svc = model.practiceSets, let gw = model.gateway else { return }
        working = true
        Task { do { _ = try await svc.generateMissing(setId: set.id, gateway: gw) } catch is CancellationError {} catch { model.alertMessage = error.localizedDescription }; working = false; reload(); model.reload() }
    }
    private func makeWorksheet() {
        guard let svc = model.worksheets else { return }
        working = true; let t = template, id = set.id
        Task {
            do { worksheet = try await Task.detached { try svc.generate(setId: id, template: t) }.value } catch { model.alertMessage = error.localizedDescription }
            working = false
        }
    }
}

extension Worksheet: @retroactive Hashable { public func hash(into h: inout Hasher) { h.combine(id) } }

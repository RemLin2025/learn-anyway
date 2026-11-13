import SwiftUI
import BraincellCore

/// Save / apply / delete named filters for one Library section. The filter type is the section's own (contextual); views live in `saved_views` by category.
struct SavedViewsMenu<F: Codable & Equatable>: View {
    @EnvironmentObject var model: AppModel
    let category: String
    let current: F
    let apply: (F) -> Void
    @State private var views: [SavedView] = []
    @State private var saving = false
    @State private var name = ""

    var body: some View {
        Menu {
            Button("Save Current View…") { name = ""; saving = true }
            if !views.isEmpty { Divider() }
            ForEach(views) { v in Button(v.name) { if let f = LibraryViews.filter(v, as: F.self) { apply(f) } } }
            if !views.isEmpty { Menu("Delete View") { ForEach(views) { v in Button(v.name, role: .destructive) { model.perform { try model.libraryViews?.delete(v.id) }; load() } } } }
        } label: { Label("Views", systemImage: "bookmark") }
        .menuStyle(.borderlessButton).fixedSize().accessibilityLabel("Saved views")
        .task(id: model.revision) { load() }
        .sheet(isPresented: $saving) { NameSheet(title: "Save View", prompt: "View name", text: $name, confirm: "Save") { model.perform { try model.libraryViews?.save(category: category, name: name, filter: current) }; load() } }
    }
    private func load() { views = (try? model.libraryViews?.views(category: category)) ?? [] }
}

struct MaterialsViewFilter: Codable, Equatable { var text = ""; var filter = "All"; var favoritesOnly = false; var sort = "Name"; var ascending = true }
struct SetsViewFilter: Codable, Equatable { var text = ""; var courseId: UUID?; var state = "All"; var favoritesOnly = false }
struct TemplatesViewFilter: Codable, Equatable { var text = ""; var origin = "All"; var favoritesOnly = false }

/// Everything starred, across files, questions, practice sets and templates, with a one-click unstar. Items open in the section that owns them.
struct LibraryFavoritesView: View {
    @EnvironmentObject var model: AppModel
    @State private var hits: [LibraryHit] = []

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.md) {
            Text("Favorites").font(Theme.pageTitle)
            if hits.isEmpty {
                EmptyStateView(symbol: "star", title: "No favorites yet", message: "Star files, questions, practice sets and templates to keep them here.")
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: Theme.Space.lg) {
                        ForEach(LibraryHit.Kind.allCases, id: \.self) { k in
                            let items = hits.filter { $0.kind == k }
                            if !items.isEmpty {
                                Text(k.title).font(Theme.cardTitle)
                                ForEach(items) { h in
                                    HStack {
                                        Button { model.openLibraryHit(h) } label: {
                                            HStack { VStack(alignment: .leading, spacing: 1) { Text(h.title).lineLimit(1); Text(h.subtitle).font(.caption).foregroundStyle(Theme.textSecondary) }; Spacer() }.contentShape(Rectangle())
                                        }.buttonStyle(.plain)
                                        Button { unstar(h) } label: { Image(systemName: "star.fill").foregroundStyle(Theme.attention).frame(width: 30, height: 28).contentShape(Rectangle()) }
                                            .buttonStyle(.plain).help("Remove from Favorites").accessibilityLabel("Remove \(h.title) from Favorites")
                                    }.padding(8).background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.control))
                                }
                            }
                        }
                    }
                }
            }
        }
        .padding(Theme.Space.lg)
        .task(id: model.revision) { hits = (try? model.librarySearch?.favorites()) ?? [] }
    }

    private func unstar(_ h: LibraryHit) {
        model.perform {
            switch h.kind {
            case .material: if let id = UUID(uuidString: h.key), let e = try model.library?.list(.root, { var q = LibraryQuery(); q.favoritesOnly = true; return q }()).first(where: { $0.id == id }) { try model.library?.setFavorite([e.ref], false) }
            case .question: try model.favorites?.set(.question, h.key, false)
            case .practiceSet: try model.favorites?.set(.practiceSet, h.key, false)
            case .template: try model.favorites?.set(.template, h.key, false)
            default: break
            }
        }
        model.reload()
    }
}

/// Every practice set, across courses, with contextual filters (course, state, favorites) and saved views.
struct LibraryPracticeSets: View {
    @EnvironmentObject var model: AppModel
    @State private var cards: [PracticeSetCard] = []
    @State private var favs: Set<String> = []
    @State private var f = SetsViewFilter()
    @State private var open: PracticeSet?
    @State private var editing: PracticeSet?
    @State private var confirmDelete: PracticeSet?

    private var shown: [PracticeSetCard] {
        cards.filter { c in
            (f.text.trimmed.isEmpty || LibrarySearchService.matches(f.text, in: c.practiceSet.title + " " + courseName(c.practiceSet)))
            && (f.courseId == nil || c.practiceSet.courseId == f.courseId)
            && (f.state == "All" || (f.state == "Not Started" && c.progress.state == .notStarted) || (f.state == "In Progress" && c.progress.state == .inProgress) || (f.state == "Completed" && c.progress.state == .completed))
            && (!f.favoritesOnly || favs.contains(c.id.uuidString))
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.md) {
            HStack(spacing: 8) {
                Text("Practice Sets").font(Theme.pageTitle); Spacer()
                SearchField(prompt: "Search practice sets", text: $f.text).frame(maxWidth: 240)
                FilterMenu(title: "Course", selection: $f.courseId, options: model.courseList.map { ($0.id, $0.name) })
                FilterMenu(title: "State", selection: Binding(get: { f.state == "All" ? nil : f.state }, set: { f.state = $0 ?? "All" }), options: ["Not Started", "In Progress", "Completed"].map { ($0, $0) })
                Toggle(isOn: $f.favoritesOnly) { Image(systemName: f.favoritesOnly ? "star.fill" : "star") }.toggleStyle(.button).help("Favorites only").accessibilityLabel("Favorites only")
                SavedViewsMenu(category: "practiceSets", current: f) { f = $0 }
            }
            if shown.isEmpty {
                EmptyStateView(symbol: "list.bullet.rectangle", title: cards.isEmpty ? "No practice sets yet" : "No practice sets match",
                               message: cards.isEmpty ? "Create one from a course’s Practice tab or the Prepare for an exam workflow. Saved questions are reused and only what’s missing is generated." : "Adjust or clear the filters.",
                               actionTitle: cards.isEmpty ? nil : "Clear Filters") { f = SetsViewFilter() }
            } else {
                ScrollView { VStack(spacing: 8) { ForEach(shown) { c in
                    PracticeSetCardView(card: c, favorite: favs.contains(c.id.uuidString), onStart: { start(c, $0) }, onEdit: { editing = c.practiceSet }, onOpen: { open = c.practiceSet },
                                        onDuplicate: { model.perform { try model.practiceSets?.duplicate(setId: c.id) }; load() }, onDelete: { confirmDelete = c.practiceSet }, onFavorite: { toggle(c) })
                } } }
            }
        }
        .padding(Theme.Space.lg)
        .task(id: model.revision) { load() }
        .onChange(of: model.openPracticeSetID) { _, _ in focus() }
        .sheet(item: $open) { s in PracticeSetDetailSheet(course: model.courseList.first { $0.id == s.courseId }, set: s) }
        .sheet(item: $editing, onDismiss: load) { s in if let c = model.courseList.first(where: { $0.id == s.courseId }) { PracticeSetEditorSheet(course: c, set: s) } }
        .confirmationDialog("Delete this practice set?", isPresented: Binding(get: { confirmDelete != nil }, set: { if !$0 { confirmDelete = nil } }), titleVisibility: .visible) {
            Button("Delete Set", role: .destructive) { if let s = confirmDelete { model.perform { try model.practiceSets?.delete(setId: s.id) }; load() }; confirmDelete = nil }
            Button("Cancel", role: .cancel) { confirmDelete = nil }
        } message: { Text("The questions and your past attempts are kept. Restore it from Library → Recently Deleted within seven days.") }
    }

    private func courseName(_ s: PracticeSet) -> String { model.courseList.first { $0.id == s.courseId }?.name ?? "" }
    private func start(_ c: PracticeSetCard, _ newAttempt: Bool) {
        let t = (try? model.templates?.template(c.progress.templateId ?? c.practiceSet.templateId ?? LearningTemplate.interactive.id)) ?? .interactive
        model.startSetSession(setId: c.id, template: t, newAttempt: newAttempt)
    }
    private func toggle(_ c: PracticeSetCard) { let on = !favs.contains(c.id.uuidString); model.perform { try model.favorites?.set(.practiceSet, c.id.uuidString, on) }; load() }
    private func focus() { if let id = model.openPracticeSetID, let s = cards.first(where: { $0.id == id })?.practiceSet { open = s; model.openPracticeSetID = nil } }
    private func load() {
        cards = ((try? model.practiceSets?.allSets()) ?? []).map { s in PracticeSetCard.make(s, model: model, assessments: (try? model.courses?.assessments(courseId: s.courseId)) ?? []) }
        favs = (try? model.favorites?.ids(.practiceSet)) ?? []
        focus()
    }
}

// MARK: Summarize notes

struct SummaryRequest: Identifiable { let id = UUID(); var courseId: UUID? }

/// Guided summarization: pick a course, see which materials already have a saved summary (no model call), choose what to summarize, and generate only what's missing.
struct NotesSummarySheet: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let request: SummaryRequest
    @State private var courseId: UUID?
    @State private var candidates: [SummaryCandidate] = []
    @State private var chosen: Set<UUID> = []
    @State private var busy = false
    @State private var status = ""
    @State private var error: String?
    @State private var report: SummaryReport?
    @State private var reading: NoteSummary?

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.md) {
            HStack { Text("Summarize notes").font(Theme.sectionTitle); Spacer(); Button("Close") { dismiss() }.keyboardShortcut(.cancelAction) }
            FilterMenu(title: "Course", selection: $courseId, options: model.courseList.map { ($0.id, $0.name) }, allowsAny: false)
            if candidates.isEmpty { Text("This course has no materials yet. Add notes or slides on its Materials tab.").foregroundStyle(Theme.textSecondary) }
            else {
                Text("Pick the materials to summarize. Ones that already have a saved summary are reused: no model call.").font(.caption).foregroundStyle(Theme.textSecondary)
                List(candidates) { c in row(c) }.frame(minHeight: 220)
            }
            let need = candidates.filter { chosen.contains($0.id) && { if case .needed = $0.state { return true } else { return false } }($0) }.count
            let reuse = candidates.filter { chosen.contains($0.id) && { if case .saved = $0.state { return true } else { return false } }($0) }.count
            HStack {
                Text(chosen.isEmpty ? "Nothing selected" : "\(need) to summarize · \(reuse) already saved").font(.caption).foregroundStyle(Theme.textSecondary)
                Spacer()
                Button { run() } label: { Label(chosen.isEmpty ? "Summarize" : (need == 0 ? "Open saved" : "Summarize \(need)"), systemImage: "sparkles") }.buttonStyle(.primary).disabled(chosen.isEmpty || busy)
            }
            if busy { HStack(spacing: 8) { ProgressView().controlSize(.small); Text(status).foregroundStyle(Theme.textSecondary) } }
            if let r = report { Text("\(r.generated) new summar\(r.generated == 1 ? "y" : "ies"), \(r.reused) reused, \(r.modelCalls) model call\(r.modelCalls == 1 ? "" : "s")." + (r.failed.isEmpty ? "" : " Not summarized: " + r.failed.joined(separator: "; "))).font(.caption).foregroundStyle(r.failed.isEmpty ? Theme.textSecondary : Theme.attention) }
            if let e = error { Label(e, systemImage: "exclamationmark.triangle").font(.callout).foregroundStyle(Theme.attention) }
        }
        .dialogSurface(width: 640)
        .onAppear { courseId = request.courseId ?? model.selectedCourseID ?? model.courseList.first?.id; load() }
        .onChange(of: courseId) { _, _ in chosen = []; report = nil; error = nil; load() }
        .sheet(item: $reading) { SummaryReader(summary: $0) }
    }

    @ViewBuilder private func row(_ c: SummaryCandidate) -> some View {
        HStack {
            switch c.state {
            case .saved(let s):
                Toggle(isOn: bind(c.id)) { VStack(alignment: .leading, spacing: 1) { Text(c.document.name).lineLimit(1); Text("Summary saved \(s.createdAt.formatted(date: .abbreviated, time: .omitted))" + (s.coverage == "full" ? "" : " · partial")).font(.caption).foregroundStyle(Theme.mastery) } }
                Spacer(); Button("Open") { reading = s }.buttonStyle(.borderless)
            case .needed(let n):
                Toggle(isOn: bind(c.id)) { VStack(alignment: .leading, spacing: 1) { Text(c.document.name).lineLimit(1); Text("Needs a summary · \(n.formatted()) characters" + (n > NoteSummaryService.maxCharacters ? " (long: only the first \(NoteSummaryService.maxCharacters.formatted()) are read)" : "")).font(.caption).foregroundStyle(Theme.textSecondary) } }
            case .unreadable(let why):
                VStack(alignment: .leading, spacing: 1) { Text(c.document.name).lineLimit(1).foregroundStyle(Theme.textSecondary); Text(why).font(.caption).foregroundStyle(Theme.attention) }
            }
        }.accessibilityElement(children: .combine)
    }
    private func bind(_ id: UUID) -> Binding<Bool> { Binding(get: { chosen.contains(id) }, set: { if $0 { chosen.insert(id) } else { chosen.remove(id) } }) }

    private func load() {
        guard let c = courseId else { candidates = []; return }
        candidates = (try? model.noteSummaries?.candidates(courseId: c)) ?? []
    }

    private func run() {
        guard let svc = model.noteSummaries else { return }
        let ids = candidates.filter { chosen.contains($0.id) }.map(\.id)
        busy = true; error = nil; report = nil; status = "Starting…"
        Task {
            do {
                let r = try await svc.summarize(documentIds: ids) { s in Task { @MainActor in status = s } }
                report = r; load(); model.reload()
                if r.generated == 0 && r.reused > 0 && r.failed.isEmpty, ids.count == 1, case .saved(let s)? = candidates.first(where: { $0.id == ids[0] })?.state { reading = s }
            } catch let f as TutorFailure { error = f.message } catch is CancellationError {} catch { self.error = error.localizedDescription }
            busy = false
        }
    }
}

struct SummaryReader: View {
    @Environment(\.dismiss) private var dismiss
    let summary: NoteSummary
    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.md) {
            HStack { VStack(alignment: .leading) { Text(summary.documentName).font(Theme.sectionTitle); Text("Summary saved \(summary.createdAt.formatted(date: .abbreviated, time: .shortened))" + (summary.coverage == "full" ? "" : " · " + summary.coverage)).font(.caption).foregroundStyle(Theme.textSecondary) }
                Spacer(); Button("Done") { dismiss() }.keyboardShortcut(.cancelAction) }
            ScrollView { RichText(text: summary.content).textSelection(.enabled) }
            Text("Generated from your notes by an AI model; check anything important against the source.").font(.caption).foregroundStyle(Theme.textSecondary)
        }.dialogSurface(width: 620)
    }
}

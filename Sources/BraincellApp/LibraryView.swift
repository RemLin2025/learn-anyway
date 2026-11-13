import SwiftUI
import BraincellCore

/// The Universal Library: files, questions, practice sets and templates in one place. Each section is a view over the existing data (nothing is copied),
/// so a question edited here is the same question a practice set or course shows.
enum LibrarySection: String, CaseIterable, Identifiable {
    case all = "All", courses = "Courses", materials = "Materials", questions = "Questions", practiceSets = "Practice Sets", templates = "Templates", favorites = "Favorites", recentlyDeleted = "Recently Deleted"
    var id: String { rawValue }
    var symbol: String {
        switch self {
        case .all: "square.grid.2x2"; case .courses: "graduationcap"; case .materials: "doc.on.doc"; case .questions: "rectangle.stack"
        case .practiceSets: "list.bullet.rectangle"; case .templates: "rectangle.3.group"; case .favorites: "star"; case .recentlyDeleted: "trash"
        }
    }
}

struct LibraryView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        HStack(spacing: 0) {
            rail
            Divider()
            content.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var rail: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 2) {
                Text("Library").font(Theme.cardTitle).padding(.horizontal, 10).padding(.bottom, 6)
                ForEach(LibrarySection.allCases) { s in
                    Button { model.librarySection = s } label: {
                        Label(s.rawValue, systemImage: s.symbol).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 10).padding(.vertical, 6)
                            .background(model.librarySection == s ? Theme.accent.opacity(0.14) : .clear, in: RoundedRectangle(cornerRadius: Theme.Radius.control))
                            .foregroundStyle(model.librarySection == s ? Theme.accent : Color.primary).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain).accessibilityAddTraits(model.librarySection == s ? .isSelected : [])
                    if s == .all || s == .templates { Divider().padding(.vertical, 4) }
                }
            }.padding(10)
        }
        .frame(width: 180).background(Theme.surface)
    }

    @ViewBuilder private var content: some View {
        switch model.librarySection {
        case .all: LibraryAllView().id("all")
        case .courses: LibraryBrowser(base: .root, initial: .filter(.folders), hidePills: true).id("courses")
        case .materials: LibraryBrowser(base: .root, hidePills: true).id("materials")
        case .favorites: LibraryBrowser(base: .root, initial: .favorites, hidePills: true).id("favorites")
        case .recentlyDeleted: LibraryBrowser(base: .root, initial: .deleted, hidePills: true).id("deleted")
        case .questions: QuestionBankView().id("questions")
        case .practiceSets: LibraryPracticeSets().id("sets")
        case .templates: TemplateGalleryView().id("templates")
        }
    }
}

/// Global search across every kind of Library content, plus a count overview when the search is empty.
struct LibraryAllView: View {
    @EnvironmentObject var model: AppModel
    @State private var text = ""
    @State private var result = LibrarySearchResult(hits: [], counts: [:])

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.md) {
            HStack { Text("All").font(Theme.pageTitle); Spacer(); SearchField(prompt: "Search courses, materials, questions, sets, templates", text: $text).frame(maxWidth: 380) }
            ScrollView {
                if text.trimmed.isEmpty { overview } else { results }
            }
        }
        .padding(Theme.Space.lg)
        .task(id: "\(text)|\(model.revision)") {
            try? await Task.sleep(nanoseconds: 200_000_000)
            if Task.isCancelled { return }
            result = (try? model.librarySearch?.search(text)) ?? LibrarySearchResult(hits: [], counts: [:])
        }
    }

    private var overview: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 200), spacing: Theme.Space.md)], spacing: Theme.Space.md) {
            ForEach(LibraryHit.Kind.allCases, id: \.self) { k in
                Button { model.librarySection = section(k) } label: {
                    Card(padding: 16) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("\(result.counts[k] ?? 0)").font(.title.weight(.semibold).monospacedDigit())
                            Text(k.title).foregroundStyle(Theme.textSecondary)
                        }
                    }.contentShape(Rectangle())
                }.buttonStyle(.plain).accessibilityElement(children: .combine)
            }
        }
    }

    @ViewBuilder private var results: some View {
        if result.hits.isEmpty { EmptyStateView(symbol: "magnifyingglass", title: "No matches", message: "Try fewer words, or check a specific section.", actionTitle: "Clear Search") { text = "" } }
        else {
            VStack(alignment: .leading, spacing: Theme.Space.lg) {
                ForEach(LibraryHit.Kind.allCases, id: \.self) { k in
                    let hits = result.hits(k)
                    if !hits.isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            HStack { Text(k.title).font(Theme.cardTitle); Text("\(result.counts[k] ?? hits.count)").foregroundStyle(Theme.textSecondary); Spacer()
                                if (result.counts[k] ?? 0) > hits.count { Button("See all") { open(hits[0], all: true) }.buttonStyle(.borderless) } }
                            ForEach(hits) { h in
                                Button { open(h, all: false) } label: {
                                    HStack { VStack(alignment: .leading, spacing: 1) { Text(h.title).lineLimit(1); Text(h.subtitle).font(.caption).foregroundStyle(Theme.textSecondary) }; Spacer(); Image(systemName: "chevron.right").foregroundStyle(Theme.textSecondary) }
                                        .padding(8).background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.control)).contentShape(Rectangle())
                                }.buttonStyle(.plain).accessibilityElement(children: .combine)
                            }
                        }
                    }
                }
            }
        }
    }

    private func section(_ k: LibraryHit.Kind) -> LibrarySection {
        switch k { case .course: .courses; case .material: .materials; case .question: .questions; case .practiceSet: .practiceSets; case .template: .templates }
    }

    /// Sends the learner to the section that owns the hit, focused on it where that section supports it.
    private func open(_ h: LibraryHit, all: Bool) {
        switch h.kind {
        case .course: if let c = h.courseId { model.selectedCourseID = c; model.selection = .courses }
        case .material: model.librarySearchSeed = text; model.librarySection = .materials
        case .question: model.questionFocus = all ? nil : UUID(uuidString: h.key); model.questionSearchSeed = all ? text : nil; model.librarySection = .questions
        case .practiceSet: model.openPracticeSetID = all ? nil : UUID(uuidString: h.key); model.librarySection = .practiceSets
        case .template: model.librarySection = .templates
        }
    }
}

/// Every practice set, across courses. The course Practice tab shows the same sets for one course.
struct LibraryPracticeSets: View {
    @EnvironmentObject var model: AppModel
    @State private var sets: [PracticeSet] = []
    @State private var text = ""
    @State private var open: PracticeSet?

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.md) {
            HStack { Text("Practice Sets").font(Theme.pageTitle); Spacer(); SearchField(prompt: "Search practice sets", text: $text).frame(maxWidth: 260) }
            let shown = sets.filter { text.trimmed.isEmpty || LibrarySearchService.matches(text, in: $0.title + " " + courseName($0)) }
            if shown.isEmpty {
                EmptyStateView(symbol: "list.bullet.rectangle", title: sets.isEmpty ? "No practice sets yet" : "No practice sets match", message: sets.isEmpty ? "Create one from a course’s Practice tab. Saved questions are reused and only what’s missing is generated." : "Clear the search to see them all.")
            } else {
                ScrollView { VStack(spacing: 6) { ForEach(shown) { s in
                    Button { open = s } label: {
                        HStack { VStack(alignment: .leading, spacing: 2) { Text(s.title).font(Theme.cardTitle); Text("\(courseName(s)) · \(s.createdAt.formatted(date: .abbreviated, time: .omitted))").font(.caption).foregroundStyle(Theme.textSecondary) }
                            Spacer(); Image(systemName: "chevron.right").foregroundStyle(Theme.textSecondary) }
                            .padding(10).background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.control)).overlay(RoundedRectangle(cornerRadius: Theme.Radius.control).strokeBorder(Theme.border)).contentShape(Rectangle())
                    }.buttonStyle(.plain)
                } } }
            }
        }
        .padding(Theme.Space.lg)
        .task(id: model.revision) { sets = (try? model.practiceSets?.allSets()) ?? []; focus() }
        .onChange(of: model.openPracticeSetID) { _, _ in focus() }
        .sheet(item: $open) { s in PracticeSetDetailSheet(course: model.courseList.first { $0.id == s.courseId }, set: s) }
    }
    private func courseName(_ s: PracticeSet) -> String { model.courseList.first { $0.id == s.courseId }?.name ?? "Course" }
    private func focus() { if let id = model.openPracticeSetID, let s = sets.first(where: { $0.id == id }) { open = s; model.openPracticeSetID = nil } }
}

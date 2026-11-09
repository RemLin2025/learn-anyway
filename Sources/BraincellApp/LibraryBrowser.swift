import SwiftUI
import UniformTypeIdentifiers
import BraincellCore

/// The one file browser. The Library page shows it at `.root`; a course's Materials tab shows it rooted at `.course(id)`.
/// Both read and write the same records, so a rename or move is instantly visible in both.
struct LibraryBrowser: View {
    @EnvironmentObject var model: AppModel
    let base: LibraryLocation
    var title: String?
    @State private var location: LibraryLocation
    @State private var entries: [LibraryEntry] = []
    @State private var crumbs: [LibraryCrumb] = []
    @State private var loaded = false
    @State private var query = LibraryQuery()
    @State private var searchText = ""
    @AppStorage("libraryLayout") private var layout = "grid"
    @State private var tab: Tab = .items
    @State private var selection: Set<UUID> = []
    @State private var importProgress: (Int, Int)?
    @State private var importTask: Task<Void, Never>?
    @State private var report: LibraryImportReport?
    @State private var notice: String?
    @State private var renaming: LibraryEntry?
    @State private var renameText = ""
    @State private var moving: [LibraryRef]?
    @State private var info: [(String, String)]?
    @State private var previewing: LibraryEntry?
    @State private var newFolder = false
    @State private var folderName = ""
    @State private var pasting = false
    @State private var pasteTitle = ""
    @State private var pasteText = ""
    @State private var deleting: [LibraryRef]?
    @State private var targeted = false

    enum Tab: Hashable { case items, deleted }
    enum Pill: Hashable { case filter(LibraryFilter), favorites, deleted }

    init(base: LibraryLocation, title: String? = nil) { self.base = base; self.title = title; _location = State(initialValue: base) }

    private var lib: LibraryService? { model.library }
    private var pill: Pill {
        get { tab == .deleted ? .deleted : query.favoritesOnly ? .favorites : .filter(query.filter) }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            pills
            if tab == .items { crumbBar }
            Divider().opacity(0).frame(height: Theme.Space.sm)
            content
        }
        .task(id: reloadKey) { await reload() }
        .task(id: searchText) { try? await Task.sleep(nanoseconds: 250_000_000); if !Task.isCancelled { query.text = searchText } }
        .dropDestination(for: URL.self, action: { urls, _ in startImport(urls); return true }, isTargeted: { targeted = $0 })
        .overlay { if targeted { RoundedRectangle(cornerRadius: Theme.Radius.card).strokeBorder(Theme.accent, style: StrokeStyle(lineWidth: 2, dash: [6])).background(Theme.accent.opacity(0.06)).padding(6).allowsHitTesting(false) } }
        .sheet(item: $previewing) { e in PreviewSheet(entry: e, url: lib?.fileURL(e)) }
        .sheet(isPresented: Binding(get: { moving != nil }, set: { if !$0 { moving = nil } })) { MoveSheet(refs: moving ?? [], base: base) { target in move(moving ?? [], to: target) } }
        .sheet(isPresented: Binding(get: { info != nil }, set: { if !$0 { info = nil } })) { InfoSheet(rows: info ?? []) }
        .sheet(isPresented: $newFolder) { NameSheet(title: "New Folder", prompt: "Folder name", text: $folderName, confirm: "Create") { act { try $0.createFolder(folderName, in: location) }; folderName = "" } }
        .sheet(item: $renaming) { e in NameSheet(title: "Rename", prompt: "Name", text: $renameText, confirm: "Rename") { act { try $0.rename(e.ref, to: renameText) } } }
        .sheet(isPresented: $pasting) { pasteSheet }
        .sheet(item: Binding(get: { report.flatMap { $0.failures.isEmpty ? nil : $0 }.map { ReportBox(report: $0) } }, set: { if $0 == nil { report = nil } })) { ReportSheet(report: $0.report) }
        .confirmationDialog(deleteTitle, isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }), titleVisibility: .visible) {
            Button("Move to Recently Deleted", role: .destructive) { if let d = deleting { act { try $0.softDelete(d) }; selection = [] }; deleting = nil }
            Button("Cancel", role: .cancel) { deleting = nil }
        } message: { Text("You can restore \((deleting?.count ?? 0) == 1 ? "it" : "them") from Recently Deleted for seven days. After that, \((deleting?.count ?? 0) == 1 ? "it is" : "they are") permanently deleted.") }
        .onChange(of: model.snapshotShowDeleted) { _, on in if SnapshotRunner.isActive, base == .root { tab = on ? .deleted : .items } }       // screenshot aids
        .onChange(of: model.snapshotLibrarySearch) { _, t in if let t, SnapshotRunner.isActive, base == .root { searchText = t } }
        .onAppear { if SnapshotRunner.isActive, let t = model.snapshotLibrarySearch, base == .root { searchText = t } }
        .focusable().focusEffectDisabled()
        .onKeyPress(.space) { if let e = selectedEntries.first, !e.isFolder { previewing = e; return .handled }; return .ignored }
        .onKeyPress(.return) { if let e = selectedEntries.first { open(e); return .handled }; return .ignored }
        .onDeleteCommand { if !selection.isEmpty { deleting = selectedEntries.filter { $0.kind != .courseFolder }.map(\.ref) } }
    }

    private var deleteTitle: String { let n = deleting?.count ?? 0; return n == 1 ? "Delete this item?" : "Delete \(n) items?" }
    private var selectedEntries: [LibraryEntry] { entries.filter { selection.contains($0.id) } }
    private var reloadKey: String { "\(location)|\(query.text)|\(query.filter)|\(query.favoritesOnly)|\(query.sort)|\(query.ascending)|\(model.revision)" }

    // MARK: Header

    private var header: some View {
        HStack(spacing: Theme.Space.md) {
            if let title { Text(title).font(Theme.pageTitle).lineLimit(1) }
            Spacer(minLength: Theme.Space.md)
            Menu {
                Picker("Sort by", selection: $query.sort) { ForEach(LibrarySort.allCases, id: \.self) { Text($0.rawValue).tag($0) } }
                Divider()
                Picker("Order", selection: $query.ascending) { Text("Ascending").tag(true); Text("Descending").tag(false) }
            } label: { Image(systemName: "line.3.horizontal.decrease") }.menuStyle(.borderlessButton).fixedSize().help("Sort").accessibilityLabel("Sort")
            HStack(spacing: 2) {
                layoutButton("grid", "square.grid.2x2", "Grid view"); layoutButton("list", "list.bullet", "List view")
            }.padding(3).background(Theme.elevated, in: RoundedRectangle(cornerRadius: Theme.Radius.control))
            SearchField(prompt: "Search library", text: $searchText).frame(minWidth: 160, idealWidth: 240, maxWidth: 280)
            Menu {
                Button { newFolder = true } label: { Label("New Folder", systemImage: "folder.badge.plus") }.disabled(tab == .deleted)
                Button { pickFiles() } label: { Label("Import Files…", systemImage: "square.and.arrow.down") }
                Button { pickFolder() } label: { Label("Import Folder…", systemImage: "folder") }
                Button { pasting = true } label: { Label("Paste Notes…", systemImage: "doc.on.clipboard") }
            } label: { Label("New", systemImage: "plus") }.menuStyle(.button).buttonStyle(.primary).fixedSize()
        }.padding(.horizontal, Theme.Space.lg).padding(.top, Theme.Space.md).padding(.bottom, Theme.Space.sm)
    }

    private func layoutButton(_ id: String, _ symbol: String, _ label: String) -> some View {
        Button { layout = id } label: { Image(systemName: symbol).frame(width: 28, height: 24).background(layout == id ? Theme.surface : .clear, in: RoundedRectangle(cornerRadius: 8)) }
            .buttonStyle(.plain).help(label).accessibilityLabel(label).accessibilityAddTraits(layout == id ? .isSelected : [])
    }

    private var pills: some View {
        PillTabs(selection: Binding(get: { pill }, set: { setPill($0) }), options: [.filter(.all), .filter(.documents), .filter(.images), .filter(.videos), .filter(.folders), .favorites, .deleted]) {
            switch $0 { case .filter(let f): f.rawValue; case .favorites: "Favorites"; case .deleted: "Recently Deleted" }
        }.padding(.horizontal, Theme.Space.lg)
    }

    private func setPill(_ p: Pill) {
        selection = []
        switch p {
        case .filter(let f): tab = .items; query.filter = f; query.favoritesOnly = false
        case .favorites: tab = .items; query.filter = .all; query.favoritesOnly = true
        case .deleted: tab = .deleted
        }
    }

    private var crumbBar: some View {
        let visible: [LibraryCrumb] = { if case .course(let c) = base, let i = crumbs.firstIndex(where: { $0.location == .course(c) }) { return Array(crumbs[i...]) }; return crumbs }()
        return HStack(spacing: 4) {
            ForEach(Array(visible.enumerated()), id: \.offset) { i, c in
                if i > 0 { Image(systemName: "chevron.right").font(.system(size: 9, weight: .bold)).foregroundStyle(Theme.textSecondary) }
                Button(c.name) { go(c.location) }.buttonStyle(.plain).font(.system(.callout, design: .rounded, weight: i == visible.count - 1 ? .semibold : .regular))
                    .foregroundStyle(i == visible.count - 1 ? Theme.textPrimary : Theme.textSecondary).disabled(i == visible.count - 1)
            }
            Spacer()
            if let p = importProgress {
                ProgressView(value: Double(p.0), total: Double(max(1, p.1))).frame(width: 90).controlSize(.small)
                Text("Importing \(p.0)/\(p.1)").font(Theme.meta).foregroundStyle(Theme.textSecondary)
                Button("Cancel") { importTask?.cancel() }.controlSize(.small)
            } else if let notice { Text(notice).font(Theme.meta).foregroundStyle(Theme.textSecondary).lineLimit(1) }
            if !query.text.isEmpty || query.filter != .all || query.favoritesOnly { Text("\(entries.count) result\(entries.count == 1 ? "" : "s")").font(Theme.meta).foregroundStyle(Theme.textSecondary) }
        }.padding(.horizontal, Theme.Space.lg).padding(.top, Theme.Space.md).frame(minHeight: 26)
    }

    // MARK: Content

    @ViewBuilder private var content: some View {
        if tab == .deleted { RecentlyDeletedView() }
        else if !loaded { ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity) }
        else if entries.isEmpty { empty }
        else if layout == "grid" { grid } else { list }
    }

    private var empty: some View {
        let filtering = !query.text.isEmpty || query.filter != .all || query.favoritesOnly
        return EmptyStateView(symbol: filtering ? "magnifyingglass" : "tray",
                              title: filtering ? "No matches" : (base == .root ? "Your Library is empty" : "No materials yet"),
                              message: filtering ? "Try a different search or filter." : "Drop files or folders here, or use New → Import. Documents, images, videos and other files are supported.",
                              actionTitle: filtering ? "Clear Filters" : "Import Files…") {
            if filtering { searchText = ""; query = LibraryQuery() } else { pickFiles() }
        }
    }

    private var grid: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 190, maximum: 260), spacing: Theme.Space.md)], spacing: Theme.Space.md) {
                ForEach(entries) { e in
                    LibraryCard(entry: e, url: lib?.fileURL(e), selected: selection.contains(e.id))
                        .onTapGesture(count: 2) { open(e) }
                        .onTapGesture { click(e) }
                        .contextMenu { menu(e) }
                }
            }.padding(Theme.Space.lg)
        }
        .background(Color.clear.contentShape(Rectangle()).onTapGesture { selection = [] })
    }

    private var list: some View {
        ScrollView {
            LazyVStack(spacing: 2) {
                ForEach(entries) { e in
                    LibraryRow(entry: e, selected: selection.contains(e.id))
                        .onTapGesture(count: 2) { open(e) }
                        .onTapGesture { click(e) }
                        .contextMenu { menu(e) }
                }
            }.padding(Theme.Space.lg)
        }
    }

    @ViewBuilder private func menu(_ e: LibraryEntry) -> some View {
        let targets = selection.contains(e.id) ? selectedEntries : [e]
        let refs = targets.map(\.ref)
        Button(e.isFolder ? "Open" : "Open with Default App") { open(e, external: true) }
        if !e.isFolder { Button("Preview") { previewing = e } }
        Divider()
        Button("Rename…") { renameText = e.name; renaming = e }.disabled(targets.count > 1)
        Button("Move…") { moving = refs.filter { $0.kind != .courseFolder } }.disabled(e.kind == .courseFolder)
        if e.kind != .courseFolder {
            let allFav = targets.allSatisfy(\.favorite)
            Button(allFav ? "Remove from Favorites" : "Add to Favorites") { act { try $0.setFavorite(refs, !allFav) } }
        }
        if !e.isFolder { Button("Reveal in Finder") { if let u = lib?.fileURL(e) { NSWorkspace.shared.activateFileViewerSelecting([u]) } }; Button("Get Info") { info = try? lib?.info(e.id) } }
        if e.kind != .courseFolder {
            Divider()
            Button("Delete", role: .destructive) { deleting = refs.filter { $0.kind != .courseFolder } }
        } else {
            Divider(); Button("Delete Course…", role: .destructive) { if let c = model.courseList.first(where: { $0.id == e.id }) { model.selection = .courses; model.selectedCourseID = c.id; model.askDeleteCourse = c.id } }
        }
    }

    private var pasteSheet: some View {
        VStack(alignment: .leading, spacing: Theme.Space.md) {
            Text("Paste Notes").font(Theme.sectionTitle)
            TextField("Title (optional)", text: $pasteTitle).accessibilityLabel("Title for pasted notes")
            TextEditor(text: $pasteText).font(.body).frame(minHeight: 220).fieldSurface()
            HStack { Spacer(); Button("Cancel") { pasting = false }.keyboardShortcut(.cancelAction)
                Button("Import") { importPasted() }.buttonStyle(.primary).keyboardShortcut(.defaultAction).disabled(pasteText.trimmed.isEmpty) }
        }.dialogSurface(width: 520)
    }

    // MARK: Actions

    private func click(_ e: LibraryEntry) {
        let mods = NSEvent.modifierFlags
        if mods.contains(.command) { if selection.contains(e.id) { selection.remove(e.id) } else { selection.insert(e.id) } }
        else if mods.contains(.shift), let last = entries.lastIndex(where: { selection.contains($0.id) }), let i = entries.firstIndex(of: e) {
            selection.formUnion(entries[min(last, i)...max(last, i)].map(\.id))
        } else { selection = [e.id] }
    }

    private func open(_ e: LibraryEntry, external: Bool = false) {
        switch e.kind {
        case .courseFolder: go(.course(e.id))
        case .folder: go(.folder(e.id))
        default: if external, let u = lib?.fileURL(e) { NSWorkspace.shared.open(u) } else { previewing = e }
        }
    }

    private func go(_ l: LibraryLocation) { selection = []; searchText = ""; query.text = ""; query.filter = .all; query.favoritesOnly = false; tab = .items; location = l }

    private func act(_ work: (LibraryService) throws -> Void) {
        guard let lib else { return }
        do { try work(lib) } catch { model.alertMessage = error.localizedDescription }
        model.reload()
    }

    private func move(_ refs: [LibraryRef], to target: LibraryLocation) { act { try $0.move(refs, to: target) }; selection = [] }

    private func reload() async {
        guard let lib else { return }
        let loc = location, q = query
        let r = await Task.detached { (try? lib.list(loc, q), try? lib.breadcrumbs(loc)) }.value
        if let es = r.0 { entries = es; selection = selection.filter { id in es.contains { $0.id == id } } } else if location != base { location = base }
        crumbs = r.1 ?? crumbs; loaded = true
    }

    private func pickFiles() {
        let p = NSOpenPanel(); p.canChooseFiles = true; p.canChooseDirectories = false; p.allowsMultipleSelection = true
        p.message = "Choose files to add"; p.prompt = "Import"
        if p.runModal() == .OK { startImport(p.urls) }
    }
    private func pickFolder() {
        let p = NSOpenPanel(); p.canChooseFiles = false; p.canChooseDirectories = true; p.allowsMultipleSelection = true
        p.message = "Choose folders to import. Nested folders are kept; symbolic links and hidden files are skipped."; p.prompt = "Import"
        if p.runModal() == .OK { startImport(p.urls) }
    }

    private func startImport(_ urls: [URL]) {
        guard let lib, importTask == nil else { return }
        let loc = location; notice = nil
        importProgress = (0, urls.count)
        importTask = Task.detached {
            let r = lib.importFiles(urls, into: loc) { done, total in Task { @MainActor in importProgress = (done, total) } }
            await MainActor.run {
                importProgress = nil; importTask = nil; notice = r.summary
                if !r.failures.isEmpty { report = r }
                model.reload()
            }
        }
    }

    private func importPasted() {
        guard let lib else { return }
        let (course, folder): (UUID?, UUID?) = {
            switch location { case .root: (nil, nil); case .course(let c): (c, nil); case .folder(let f): ((try? lib.db.read { try UUID.fetchOne($0, sql: "SELECT courseId FROM library_folders WHERE id = ?", arguments: [f]) }) ?? nil, f) }
        }()
        act { _ in _ = try DocumentService(db: lib.db, storage: lib.storage).importPasted(text: pasteText, title: pasteTitle, courseId: course, folderId: folder) }
        pasteText = ""; pasteTitle = ""; pasting = false
    }
}

import GRDB

private struct ReportBox: Identifiable { let id = UUID(); let report: LibraryImportReport }

private struct ReportSheet: View {
    @Environment(\.dismiss) private var dismiss
    let report: LibraryImportReport
    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.md) {
            Text("Import finished with problems").font(Theme.sectionTitle)
            Text(report.summary).foregroundStyle(Theme.textSecondary)
            List(report.failures) { f in VStack(alignment: .leading, spacing: 2) { Text(f.path).font(.system(.callout, design: .rounded, weight: .medium)); Text(f.message).font(Theme.meta).foregroundStyle(Theme.textSecondary) } }
                .scrollContentBackground(.hidden).background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.control)).frame(height: 220)
            Text("Everything else was imported. To retry the failed files, fix the problem and import them again.").font(Theme.meta).foregroundStyle(Theme.textSecondary)
            HStack { Spacer(); Button("Done") { dismiss() }.buttonStyle(.primary).keyboardShortcut(.defaultAction) }
        }.dialogSurface(width: 480)
    }
}

private struct PreviewSheet: View {
    @Environment(\.dismiss) private var dismiss
    let entry: LibraryEntry; let url: URL?
    var body: some View {
        VStack(spacing: 0) {
            HStack { Image(systemName: entry.kind.symbol).foregroundStyle(entry.kind.tint); Text(entry.name).font(Theme.cardTitle).lineLimit(1); Spacer()
                if let url { Button("Open") { NSWorkspace.shared.open(url) }; Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) } }
                Button("Done") { dismiss() }.buttonStyle(.primary).keyboardShortcut(.cancelAction) }.padding(Theme.Space.md)
            Divider()
            if let url { QuickLookPreview(url: url) } else { EmptyStateView(symbol: "questionmark.folder", title: "File not found", message: "The stored copy is missing.") }
        }.frame(minWidth: 640, minHeight: 520).background(Theme.background)
    }
}

private struct InfoSheet: View {
    @Environment(\.dismiss) private var dismiss
    let rows: [(String, String)]
    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.md) {
            Text("Get Info").font(Theme.sectionTitle)
            Grid(alignment: .leading, horizontalSpacing: Theme.Space.lg, verticalSpacing: 6) {
                ForEach(Array(rows.enumerated()), id: \.offset) { _, r in GridRow { Text(r.0).foregroundStyle(Theme.textSecondary); Text(r.1).textSelection(.enabled) } }
            }
            HStack { Spacer(); Button("Done") { dismiss() }.buttonStyle(.primary).keyboardShortcut(.defaultAction) }
        }.dialogSurface(width: 420)
    }
}

private struct MoveSheet: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let refs: [LibraryRef]; let base: LibraryLocation
    let choose: (LibraryLocation) -> Void
    @State private var dests: [LibraryDestination] = []
    @State private var pick: LibraryLocation?
    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.md) {
            Text("Move \(refs.count == 1 ? "1 item" : "\(refs.count) items") to…").font(Theme.sectionTitle)
            List(dests, selection: $pick) { d in
                Label(d.name, systemImage: d.location == .root ? "books.vertical" : { if case .course = d.location { return "graduationcap" }; return "folder" }())
                    .padding(.leading, CGFloat(d.depth) * 16).tag(Optional(d.location))
            }.scrollContentBackground(.hidden).background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.control)).frame(height: 280)
            Text("The file itself isn’t copied: it moves, so it appears in the new place in both Library and Materials. Moving a file to another course or the Library removes its assessment links.").font(Theme.meta).foregroundStyle(Theme.textSecondary)
            HStack { Spacer(); Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Move") { if let pick { choose(pick); dismiss() } }.buttonStyle(.primary).keyboardShortcut(.defaultAction).disabled(pick == nil) }
        }.dialogSurface(width: 440).task { dests = (try? model.library?.destinations()) ?? [] }
    }
}

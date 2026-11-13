import SwiftUI
import UniformTypeIdentifiers
import BraincellCore

struct ChatWorkspace: View {
    @ObservedObject var chat: ChatModel
    @EnvironmentObject var model: AppModel
    @AppStorage("chatPanelOpen") private var panelOpen = true
    @State private var width: CGFloat = 1000
    private var showPanel: Bool { panelOpen && width >= 760 }        // the history panel steps aside in narrow windows
    @State private var renaming: ChatConversation?
    @State private var renameText = ""
    @State private var deleting: ChatConversation?
    @State private var targeted = false

    var body: some View {
        HStack(spacing: 0) {
            if showPanel {
                ChatHistoryPanel(chat: chat, rename: { renameText = $0.title; renaming = $0 }, delete: { deleting = $0 })
                    .frame(width: 252).background(Theme.surface)
                    .overlay(alignment: .trailing) { Rectangle().fill(Theme.border).frame(width: 1) }
            }
            VStack(spacing: 0) {
                header
                if chat.isEmpty { emptyState } else { transcript; Composer(chat: chat, compact: true).frame(maxWidth: 760).padding(.horizontal, Theme.Space.lg).padding(.bottom, Theme.Space.md) }
            }
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        .dropDestination(for: URL.self, action: { urls, _ in chat.attachFiles(urls); return true }, isTargeted: { targeted = $0 })
        .overlay { if targeted { RoundedRectangle(cornerRadius: Theme.Radius.card).strokeBorder(Theme.accent, style: StrokeStyle(lineWidth: 2, dash: [6])).background(Theme.accent.opacity(0.06)).padding(8).allowsHitTesting(false) } }
        .sheet(item: $renaming) { c in NameSheet(title: "Rename Conversation", prompt: "Title", text: $renameText, confirm: "Rename") { chat.rename(c.id, renameText) } }
        .confirmationDialog("Delete “\(deleting?.title ?? "")”?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }), titleVisibility: .visible) {
            Button("Delete Conversation", role: .destructive) { if let d = deleting { chat.delete(d.id) }; deleting = nil }
            Button("Cancel", role: .cancel) { deleting = nil }
        } message: { Text("The messages are removed. Courses, questions and study plans the assistant created are kept.") }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: Theme.Space.md) {
            Button { panelOpen.toggle() } label: { Image(systemName: "sidebar.left").frame(width: 32, height: 32).contentShape(Rectangle()) }.buttonStyle(.plain)
                .foregroundStyle(Theme.textSecondary).help(showPanel ? "Hide conversations" : "Show conversations").accessibilityLabel(showPanel ? "Hide conversations" : "Show conversations")
            Text(chat.isEmpty ? "New chat" : (chat.currentId.flatMap { id in chat.conversations.first { $0.id == id }?.title } ?? "Chat")).font(.system(.headline, design: .rounded, weight: .semibold)).lineLimit(1)
            Spacer()
            if !showPanel { Button { chat.newChat() } label: { Label("New chat", systemImage: "square.and.pencil").labelStyle(.iconOnly).frame(width: 32, height: 32).contentShape(Rectangle()) }.buttonStyle(.plain).foregroundStyle(Theme.textSecondary).help("New chat").accessibilityLabel("New chat") }
        }.padding(.horizontal, Theme.Space.lg).padding(.vertical, Theme.Space.sm).frame(minHeight: 48)
            .overlay(alignment: .bottom) { Rectangle().fill(Theme.border).frame(height: 1) }
    }

    // MARK: Empty state

    private var emptyState: some View {
        VStack(spacing: Theme.Space.xl) {
            Spacer(minLength: Theme.Space.xl)
            VStack(spacing: Theme.Space.xs) {
                Text(Self.greeting).font(.system(.title3, design: .rounded, weight: .medium)).foregroundStyle(Theme.textSecondary)
                (Text("What would you like to ").foregroundStyle(Theme.textPrimary) + Text("learn today?").foregroundStyle(Theme.accent))
                    .font(.system(size: 30, weight: .semibold, design: .rounded)).multilineTextAlignment(.center)
            }.accessibilityElement(children: .combine)
            Composer(chat: chat, compact: false).frame(maxWidth: 720)
            SuggestionGrid(chat: chat).frame(maxWidth: 720)
            Spacer(minLength: Theme.Space.xl)
        }.padding(.horizontal, Theme.Space.xl).frame(maxWidth: .infinity)
    }
    private static var greeting: String {
        let h = Calendar.current.component(.hour, from: Date())
        return h < 5 ? "Good evening" : h < 12 ? "Good morning" : h < 18 ? "Good afternoon" : "Good evening"
    }

    // MARK: Transcript

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: Theme.Space.md) {
                    ForEach(chat.messages) { m in MessageRow(chat: chat, message: m).id(m.id) }
                    if chat.canRegenerate { Button { chat.regenerate() } label: { Label("Regenerate response", systemImage: "arrow.clockwise").font(Theme.meta).padding(.vertical, 4).contentShape(Rectangle()) }.buttonStyle(.plain).foregroundStyle(Theme.textSecondary).help("Answer the last message again. The earlier reply is kept, not deleted.") }
                    if chat.thinking { ThinkingRow(stage: chat.stage).id("thinking") }
                }.frame(maxWidth: 760, alignment: .leading).padding(.horizontal, Theme.Space.lg).padding(.vertical, Theme.Space.md).frame(maxWidth: .infinity)
            }
            .onChange(of: chat.messages.count) { _, _ in withAnimation(.easeOut(duration: 0.15)) { if chat.thinking { proxy.scrollTo("thinking", anchor: .bottom) } else if let last = chat.messages.last?.id { proxy.scrollTo(last, anchor: .bottom) } } }
            .onChange(of: chat.thinking) { _, on in if on { proxy.scrollTo("thinking", anchor: .bottom) } }
            .onAppear { if let last = chat.messages.last?.id { proxy.scrollTo(last, anchor: .bottom) } }
        }
    }
}

// MARK: Suggestions

struct SuggestionGrid: View {
    @ObservedObject var chat: ChatModel
    struct S: Identifiable { let id: String; let symbol: String; let title: String; let hint: String }
    static let all: [S] = [
        S(id: "plan", symbol: "calendar", title: "Prepare for an exam", hint: "Guided: materials, topics, study map, template, practice"),
        S(id: "practice", symbol: "checklist", title: "Generate practice questions", hint: "Make a practice set; saved questions are reused first"),
        S(id: "explain", symbol: "book", title: "Explain a concept", hint: "Starts a chat about a concept in your course"),
        S(id: "weak", symbol: "chart.line.uptrend.xyaxis", title: "Review my weaknesses", hint: "Practice the skills you’ve been missing, from your saved results"),
        S(id: "cram", symbol: "bolt", title: "Quick cram", hint: "A timed practice set from your saved questions"),
        S(id: "summary", symbol: "doc.text", title: "Summarize my notes", hint: "Starts a chat about summarizing your notes"),
    ]
    private func run(_ s: S) {
        let course = chat.app.courseList.first { $0.id == chat.app.selectedCourseID }?.name
        switch s.id {
        case "plan": chat.app.openExamPrep()
        case "practice": chat.app.openNewPracticeSet()
        case "weak": chat.app.reviewWeaknesses()
        case "cram": chat.app.quickCram()
        case "explain": chat.draft = "Explain a difficult concept from \(course ?? "my course") step by step: "
        default: chat.draft = "Summarize my notes\(course.map { " for \($0)" } ?? "") into the key points I should remember."
        }
    }
    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 190), spacing: Theme.Space.sm)], spacing: Theme.Space.sm) {
            ForEach(Self.all) { s in
                Button { run(s) } label: {
                    HStack(spacing: 8) {
                        Image(systemName: s.symbol).foregroundStyle(Theme.accent).frame(width: 18)
                        Text(s.title).font(.system(.callout, design: .rounded, weight: .medium)).lineLimit(1)
                        Spacer(minLength: 0)
                    }.padding(.horizontal, 14).frame(height: 38).frame(maxWidth: .infinity, alignment: .leading)
                    .background(Theme.surface, in: Capsule()).overlay(Capsule().strokeBorder(Theme.border)).contentShape(Capsule())
                }.buttonStyle(.plain).help(s.hint).accessibilityLabel(s.title).accessibilityHint(s.hint)
            }
        }
    }
}

// MARK: History panel

/// Left panel like a chat app's: search, New chat, and conversations grouped by when they were last used.
struct ChatHistoryPanel: View {
    @ObservedObject var chat: ChatModel
    let rename: (ChatConversation) -> Void
    let delete: (ChatConversation) -> Void

    private var groups: [(String, [ChatConversation])] {
        let cal = Calendar.current, now = Date()
        func bucket(_ d: Date) -> String {
            if cal.isDateInToday(d) { return "Today" }
            if cal.isDateInYesterday(d) { return "Yesterday" }
            if let w = cal.date(byAdding: .day, value: -7, to: cal.startOfDay(for: now)), d >= w { return "Previous 7 days" }
            return "Older"
        }
        let by = Dictionary(grouping: chat.conversations, by: { bucket($0.updatedAt) })
        return ["Today", "Yesterday", "Previous 7 days", "Older"].compactMap { k in by[k].map { (k, $0) } }
    }

    var body: some View {
        VStack(spacing: Theme.Space.md) {
            SearchField(prompt: "Search chats", text: $chat.historyQuery)
            Button { chat.newChat() } label: { Label("New chat", systemImage: "plus").frame(maxWidth: .infinity) }.buttonStyle(.primary).keyboardShortcut("n", modifiers: [.command, .shift])
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    if chat.conversations.isEmpty { Text(chat.historyQuery.trimmed.isEmpty ? "No conversations yet." : "No conversations match.").font(.callout).foregroundStyle(Theme.textSecondary).padding(.top, Theme.Space.lg).frame(maxWidth: .infinity) }
                    ForEach(groups, id: \.0) { g in
                        Text(g.0).font(Theme.meta).foregroundStyle(Theme.textSecondary).padding(.horizontal, Theme.Space.sm).padding(.top, Theme.Space.md).padding(.bottom, 2)
                        ForEach(g.1) { c in row(c) }
                    }
                }
            }
        }.padding(Theme.Space.md)
    }

    private func row(_ c: ChatConversation) -> some View {
        let selected = c.id == chat.currentId
        return Button { chat.open(c.id) } label: {
            Text(c.title).font(.system(.callout, design: .rounded, weight: selected ? .semibold : .regular)).lineLimit(1).truncationMode(.tail)
                .foregroundStyle(selected ? Theme.accent : Theme.textPrimary)
                .padding(.horizontal, Theme.Space.sm).frame(maxWidth: .infinity, minHeight: 34, alignment: .leading).contentShape(Rectangle())
                .background(selected ? Theme.accent.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: Theme.Radius.control))
        }.buttonStyle(.plain).help(c.title).accessibilityAddTraits(selected ? .isSelected : [])
        .contextMenu { Button("Rename…") { rename(c) }; Button("Delete…", role: .destructive) { delete(c) } }
    }
}

// MARK: Composer

struct Composer: View {
    @ObservedObject var chat: ChatModel
    @EnvironmentObject var model: AppModel
    let compact: Bool
    @FocusState private var focused: Bool
    @State private var showMath = false

    /// Appends at the end of the draft, wrapped in $…$ so it renders. (A SwiftUI selection binding crashed when the draft was cleared on send,
    /// so the chat composer does not track the caret; the practice answer fields do insert at the caret.)
    private func insertMath(_ latex: String) {
        let e = MathPalette.insert(latex, into: chat.draft, selection: NSRange(location: (chat.draft as NSString).length, length: 0), wrap: true)
        chat.draft = e.text
        focused = true
    }

    var body: some View {
        let res = chat.resolution
        VStack(spacing: Theme.Space.sm) {
            if res.primary == nil && !res.manual { setupBanner(res) }
            else if res.manual { banner("The Chat Assistant is set to the manual ChatGPT Bridge, which can’t run tools automatically. Choose an API-connected model.", symbol: "hand.raised") }
            if let n = chat.notice { banner(n, symbol: "exclamationmark.triangle", tint: Theme.attention) }
            VStack(alignment: .leading, spacing: Theme.Space.sm) {
                if !chat.attached.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) { HStack { ForEach(chat.attached, id: \.self) { u in
                        HStack(spacing: 4) { Image(systemName: "paperclip").font(.caption); Text(u.lastPathComponent).font(Theme.meta).lineLimit(1)
                            Button { chat.removeAttachment(u) } label: { Image(systemName: "xmark.circle.fill") }.buttonStyle(.plain).accessibilityLabel("Remove \(u.lastPathComponent)") }
                            .padding(.horizontal, 8).padding(.vertical, 4).background(Theme.elevated, in: Capsule()) } } }
                }
                TextField("Ask anything, create a study plan, or start learning...", text: $chat.draft, axis: .vertical)
                    .textFieldStyle(.plain).font(.system(size: 15)).lineLimit(1...8).focused($focused)
                    .onKeyPress(.return, phases: .down) { press in
                        if press.modifiers.contains(.shift) { chat.draft += "\n"; return .handled }
                        chat.send(); return .handled
                    }
                    .accessibilityLabel("Message")
                HStack(spacing: Theme.Space.md) {
                    Menu {
                        Button { chat.pickFiles() } label: { Label("Add files…", systemImage: "paperclip") }
                    } label: { Image(systemName: "plus").font(.system(size: 15, weight: .medium)) }.menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().help("Attach files").accessibilityLabel("Attach")
                    Menu {
                        Button("All courses") { chat.setCourse(nil) }
                        Divider()
                        ForEach(model.courseList) { c in Button(c.name) { chat.setCourse(c.id) } }
                    } label: { HStack(spacing: 4) { Image(systemName: "book"); Text(model.courseList.first { $0.id == chat.courseId }?.name ?? "All courses").lineLimit(1); Image(systemName: "chevron.down").font(.system(size: 9, weight: .bold)) }.font(.callout) }.menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().help("Course context")
                    Button { showMath.toggle() } label: { Image(systemName: "function").font(.system(size: 15, weight: .medium)) }.buttonStyle(.plain).help("Insert math (⇧⌘M)").accessibilityLabel("Insert math")
                        .keyboardShortcut("m", modifiers: [.command, .shift])
                        .popover(isPresented: $showMath, arrowEdge: .top) { MathPaletteView { insertMath($0) } }
                    Spacer()
                    modelMenu(res)
                    Button { chat.thinking ? chat.stop() : chat.send() } label: {
                        Image(systemName: chat.thinking ? "stop.fill" : "arrow.up").font(.system(size: 13, weight: .bold)).foregroundStyle(.white)
                            .frame(width: 30, height: 30).background((chat.draft.trimmed.isEmpty && chat.attached.isEmpty && !chat.thinking) ? Theme.accent.opacity(0.55) : Theme.accent, in: Circle())
                    }.buttonStyle(.plain).disabled(!chat.thinking && chat.draft.trimmed.isEmpty && chat.attached.isEmpty)
                        .accessibilityLabel(chat.thinking ? "Stop" : "Send").keyboardShortcut(.return, modifiers: .command)
                }.foregroundStyle(Theme.textSecondary)
            }
            .padding(Theme.Space.md + 2)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 22))
            .overlay(RoundedRectangle(cornerRadius: 22).strokeBorder(focused ? Theme.accent.opacity(0.6) : Theme.border, lineWidth: focused ? 1.5 : 1))
            if compact, let p = res.primary { Text(p.connection.spec?.isLocal == true ? "Runs on this Mac with \(p.model.displayName)." : "Messages and any course excerpts the assistant reads are sent to \(p.connection.name) (\(p.model.displayName)).").font(.system(size: 10.5)).foregroundStyle(Theme.textSecondary) }
        }
        .onAppear { focused = true }
    }

    private func modelMenu(_ res: Resolution) -> some View {
        Menu {
            Button("Use default model") { chat.chooseModel(connection: nil, model: nil) }
            Divider()
            if let cfg = model.aiConfig {
                ForEach(cfg.connections.filter { $0.enabled && $0.spec?.supports(.llm) == true }) { c in
                    Menu(c.name) { ForEach(cfg.models(c, .llm)) { m in Button(m.displayName) { chat.chooseModel(connection: c, model: m) } } }
                }
            }
            Divider()
            Button("Model Services…") { model.openSettings(.services) }
        } label: { HStack(spacing: 4) { Text(res.primary?.model.displayName ?? (res.manual ? "Manual bridge" : "No model")).lineLimit(1); Image(systemName: "chevron.down").font(.system(size: 9, weight: .bold)) }.font(.callout) }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().help("Model used for this assistant (Settings → AI Workflow → Chat Assistant)")
    }

    private func setupBanner(_ res: Resolution) -> some View {
        HStack(spacing: Theme.Space.sm) {
            Image(systemName: "exclamationmark.triangle").foregroundStyle(Theme.attention)
            Text(res.problem ?? "No AI model is configured for the assistant.").font(.callout).fixedSize(horizontal: false, vertical: true)
            Spacer()
            Button("Set up a model…") { model.openSettings(.plans) }.buttonStyle(.primary)
        }.padding(Theme.Space.md).background(Theme.attention.opacity(0.10), in: RoundedRectangle(cornerRadius: Theme.Radius.control)).overlay(RoundedRectangle(cornerRadius: Theme.Radius.control).strokeBorder(Theme.attention.opacity(0.35)))
    }
    private func banner(_ t: String, symbol: String, tint: Color = Theme.accent) -> some View {
        Label { Text(t).font(.callout).fixedSize(horizontal: false, vertical: true) } icon: { Image(systemName: symbol).foregroundStyle(tint) }
            .padding(Theme.Space.md).frame(maxWidth: .infinity, alignment: .leading).background(tint.opacity(0.10), in: RoundedRectangle(cornerRadius: Theme.Radius.control))
    }
}

struct ThinkingRow: View {
    var stage: String?
    var body: some View {
        HStack(spacing: 8) { ProgressView().controlSize(.small); Text((stage ?? "Working") + "…").font(.callout).foregroundStyle(Theme.textSecondary) }
            .accessibilityElement(children: .combine).accessibilityLabel("The assistant is working: \(stage ?? "starting")")
    }
}

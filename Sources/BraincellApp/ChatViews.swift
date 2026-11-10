import SwiftUI
import UniformTypeIdentifiers
import BraincellCore

struct ChatWorkspace: View {
    @ObservedObject var chat: ChatModel
    @EnvironmentObject var model: AppModel
    @State private var showHistory = false
    @State private var renaming: ChatConversation?
    @State private var renameText = ""
    @State private var deleting: ChatConversation?
    @State private var targeted = false

    var body: some View {
        VStack(spacing: 0) {
            header
            if chat.isEmpty { emptyState } else { transcript; Composer(chat: chat, compact: true).frame(maxWidth: 760).padding(.horizontal, Theme.Space.lg).padding(.bottom, Theme.Space.md) }
        }
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
            Image(systemName: "brain.head.profile").font(.system(size: 16, weight: .semibold)).foregroundStyle(Theme.accent).frame(width: 32, height: 32)
                .background(Theme.accent.opacity(0.14), in: RoundedRectangle(cornerRadius: 9)).accessibilityHidden(true)
            Text(chat.isEmpty ? "Learn Anyway" : (chat.currentId.flatMap { id in chat.conversations.first { $0.id == id }?.title } ?? "Chat")).font(.system(.title3, design: .rounded, weight: .semibold)).lineLimit(1)
            Spacer()
            Button { showHistory.toggle() } label: { Image(systemName: "clock.arrow.circlepath") }.buttonStyle(.plain).help("Conversation history").accessibilityLabel("Conversation history")
                .popover(isPresented: $showHistory, arrowEdge: .bottom) { history }
            Button { chat.newChat() } label: { Image(systemName: "square.and.pencil") }.buttonStyle(.plain).help("New chat (⌘N)").accessibilityLabel("New chat").keyboardShortcut("n", modifiers: [.command, .shift])
        }.padding(.horizontal, Theme.Space.lg).padding(.vertical, Theme.Space.md)
    }

    private var history: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Conversations").font(Theme.cardTitle).padding(Theme.Space.md)
            Divider()
            if chat.conversations.isEmpty { Text("No conversations yet.").foregroundStyle(Theme.textSecondary).padding(Theme.Space.lg) }
            else {
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(chat.conversations) { c in
                            Button { chat.open(c.id); showHistory = false } label: {
                                HStack { VStack(alignment: .leading, spacing: 2) { Text(c.title).lineLimit(1).font(.system(.body, design: .rounded, weight: c.id == chat.currentId ? .semibold : .regular))
                                    Text(c.updatedAt.formatted(date: .abbreviated, time: .shortened)).font(Theme.meta).foregroundStyle(Theme.textSecondary) }; Spacer() }
                                    .padding(.horizontal, Theme.Space.md).padding(.vertical, 6).contentShape(Rectangle())
                                    .background(c.id == chat.currentId ? Theme.accent.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: Theme.Radius.control))
                            }.buttonStyle(.plain)
                            .contextMenu { Button("Rename…") { renameText = c.title; renaming = c; showHistory = false }; Button("Delete…", role: .destructive) { deleting = c; showHistory = false } }
                        }
                    }.padding(Theme.Space.sm)
                }.frame(maxHeight: 340)
            }
        }.frame(width: 320)
    }

    // MARK: Empty state

    private var emptyState: some View {
        VStack(spacing: Theme.Space.lg) {
            Spacer(minLength: Theme.Space.xl)
            VStack(spacing: Theme.Space.sm) {
                Text("What would you like to learn today?").font(.system(size: 28, weight: .semibold, design: .rounded)).multilineTextAlignment(.center)
                Text("Your AI study assistant, connected to your courses and materials.").foregroundStyle(Theme.textSecondary).multilineTextAlignment(.center)
            }
            Composer(chat: chat, compact: false).frame(maxWidth: 720)
            SuggestionGrid(chat: chat).frame(maxWidth: 720)
            Text("Suggested prompts · Connected to your learning workspace").font(Theme.meta).foregroundStyle(Theme.textSecondary)
            Spacer(minLength: Theme.Space.xl)
        }.padding(.horizontal, Theme.Space.xl).frame(maxWidth: .infinity)
    }

    // MARK: Transcript

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: Theme.Space.md) {
                    ForEach(chat.messages) { m in MessageRow(chat: chat, message: m).id(m.id) }
                    if chat.thinking { ThinkingRow().id("thinking") }
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
    struct S: Identifiable { let id: String; let symbol: String; let title: String; let prompt: String }
    static let all: [S] = [
        S(id: "plan", symbol: "calendar", title: "Plan my midterm", prompt: "Help me prepare for an upcoming midterm using my course materials."),
        S(id: "practice", symbol: "checklist", title: "Generate practice questions", prompt: "Create practice problems based on my lecture notes."),
        S(id: "explain", symbol: "book", title: "Explain a concept", prompt: "Teach me a difficult topic step by step."),
        S(id: "weak", symbol: "chart.line.uptrend.xyaxis", title: "Review my weaknesses", prompt: "Analyze my performance and help me improve."),
        S(id: "cram", symbol: "bolt", title: "Quick cram", prompt: "I have one hour to study. Help me prioritize."),
    ]
    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), spacing: Theme.Space.sm)], spacing: Theme.Space.sm) {
            ForEach(Self.all) { s in
                Button { chat.draft = s.prompt } label: {
                    HStack(spacing: Theme.Space.sm) {
                        Image(systemName: s.symbol).foregroundStyle(Theme.accent).frame(width: 20)
                        VStack(alignment: .leading, spacing: 1) { Text(s.title).font(.system(.callout, design: .rounded, weight: .medium)); Text(s.prompt).font(.system(size: 10.5)).foregroundStyle(Theme.textSecondary).lineLimit(1) }
                        Spacer(minLength: 0)
                    }.padding(.horizontal, 12).padding(.vertical, 9).frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                    .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.control + 2))
                    .overlay(RoundedRectangle(cornerRadius: Theme.Radius.control + 2).strokeBorder(Theme.border))
                }.buttonStyle(.plain).accessibilityLabel(s.title).accessibilityHint("Fills the message box so you can edit it before sending")
            }
        }
    }
}

// MARK: Composer

struct Composer: View {
    @ObservedObject var chat: ChatModel
    @EnvironmentObject var model: AppModel
    let compact: Bool
    @FocusState private var focused: Bool

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
                    Spacer()
                    modelMenu(res)
                    Button { chat.thinking ? chat.stop() : chat.send() } label: {
                        Image(systemName: chat.thinking ? "stop.fill" : "arrow.up").font(.system(size: 13, weight: .bold)).foregroundStyle(.white)
                            .frame(width: 30, height: 30).background((chat.draft.trimmed.isEmpty && chat.attached.isEmpty && !chat.thinking) ? Theme.accent.opacity(0.4) : Theme.accent, in: Circle())
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
    var body: some View {
        HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Working…").font(.callout).foregroundStyle(Theme.textSecondary) }
            .accessibilityElement(children: .combine).accessibilityLabel("The assistant is working")
    }
}

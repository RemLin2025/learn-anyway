import SwiftUI
import BraincellCore

struct MessageRow: View {
    @ObservedObject var chat: ChatModel
    let message: ChatMessage

    var body: some View {
        switch (message.role, message.kind) {
        case (.user, _): UserBubble(text: message.content)
        case (.assistant, .approval): ApprovalCard(chat: chat, message: message)
        case (.assistant, .plan): PlanCard(chat: chat, message: message)
        case (.assistant, .preview): PreviewCard(chat: chat, message: message)
        case (.assistant, .actions): ChipRow(chat: chat, message: message)
        case (.assistant, _): AssistantText(text: message.content)
        case (.tool, _): ToolRow(message: message)
        case (_, .error): ErrorRow(chat: chat, text: message.content)
        default: Text(message.content).font(Theme.meta).foregroundStyle(Theme.textSecondary).frame(maxWidth: .infinity, alignment: .center)
        }
    }
}

struct UserBubble: View {
    let text: String
    var body: some View {
        HStack { Spacer(minLength: 60)
            Text(text).textSelection(.enabled).padding(.horizontal, 14).padding(.vertical, 9)
                .background(Theme.elevated, in: RoundedRectangle(cornerRadius: 18)) }
            .accessibilityLabel("You: \(text)")
    }
}

struct AssistantText: View {
    let text: String
    @State private var hover = false
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            MarkdownBlocks(text: text)
            HStack(spacing: 10) {
                Button { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string) } label: { Label("Copy", systemImage: "doc.on.doc").font(Theme.meta) }.buttonStyle(.plain)
                    .foregroundStyle(Theme.textSecondary).opacity(hover ? 1 : 0.35).accessibilityLabel("Copy message")
            }
        }.frame(maxWidth: .infinity, alignment: .leading).onHover { hover = $0 }.accessibilityElement(children: .contain)
    }
}

/// Block-level Markdown for replies: fenced code, headings, lists, paragraphs (with inline formatting and $$math$$ via RichText).
struct MarkdownBlocks: View {
    let text: String
    enum Block: Identifiable { case code(String, String), heading(Int, String), bullet(String), number(Int, String), para(String)
        var id: String { switch self { case .code(let l, let c): "c\(l)\(c.hashValue)"; case .heading(let n, let t): "h\(n)\(t)"; case .bullet(let t): "b\(t)"; case .number(let n, let t): "n\(n)\(t)"; case .para(let t): "p\(t)" } } }

    static func parse(_ s: String) -> [Block] {
        var out: [Block] = [], para: [String] = [], code: [String]? = nil, lang = ""
        func flush() { if !para.isEmpty { out.append(.para(para.joined(separator: "\n"))); para = [] } }
        for line in s.components(separatedBy: "\n") {
            if line.hasPrefix("```") { if let c = code { out.append(.code(lang, c.joined(separator: "\n"))); code = nil } else { flush(); code = []; lang = String(line.dropFirst(3)).trimmingCharacters(in: .whitespaces) }; continue }
            if code != nil { code!.append(line); continue }
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.isEmpty { flush() }
            else if let m = t.range(of: "^#{1,4} ", options: .regularExpression) { flush(); out.append(.heading(t[m].dropLast().count, String(t[m.upperBound...]))) }
            else if t.hasPrefix("- ") || t.hasPrefix("* ") { flush(); out.append(.bullet(String(t.dropFirst(2)))) }
            else if let m = t.range(of: "^[0-9]{1,3}[.)] ", options: .regularExpression) { flush(); out.append(.number(Int(t[..<t.index(before: t.index(before: m.upperBound))]) ?? 1, String(t[m.upperBound...]))) }
            else { para.append(t) }
        }
        if let c = code { out.append(.code(lang, c.joined(separator: "\n"))) }
        flush(); return out
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Self.parse(text)) { b in
                switch b {
                case .code(let l, let c): VStack(alignment: .leading, spacing: 4) {
                    if !l.isEmpty { Text(l).font(.system(size: 10, weight: .semibold)).foregroundStyle(Theme.textSecondary) }
                    ScrollView(.horizontal, showsIndicators: false) { Text(c).font(.system(.callout, design: .monospaced)).textSelection(.enabled).fixedSize() } }
                    .padding(10).frame(maxWidth: .infinity, alignment: .leading).background(Theme.elevated, in: RoundedRectangle(cornerRadius: Theme.Radius.control))
                case .heading(let n, let t): Text(t).font(.system(n <= 1 ? .title2 : n == 2 ? .title3 : .headline, design: .rounded, weight: .semibold)).padding(.top, 4)
                case .bullet(let t): HStack(alignment: .firstTextBaseline, spacing: 8) { Text("•"); RichText(text: t) }
                case .number(let n, let t): HStack(alignment: .firstTextBaseline, spacing: 8) { Text("\(n).").monospacedDigit(); RichText(text: t) }
                case .para(let t): RichText(text: t)
                }
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: Tool progress

struct ToolRow: View {
    let message: ChatMessage
    @State private var open = false
    private var info: [String: String] { (message.payload.flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) } as? [String: String]) ?? [:] }
    var body: some View {
        let status = info["status"] ?? "succeeded"
        VStack(alignment: .leading, spacing: 4) {
            Button { open.toggle() } label: {
                HStack(spacing: 6) {
                    Image(systemName: status == "succeeded" ? "checkmark.circle.fill" : status == "failed" ? "xmark.octagon.fill" : status == "declined" ? "minus.circle.fill" : "hourglass").foregroundStyle(status == "succeeded" ? Theme.mastery : status == "failed" ? Theme.error : Theme.textSecondary).font(.system(size: 11))
                    Text(info["tool"] ?? "tool").font(.system(size: 11, weight: .semibold, design: .monospaced))
                    Text("· " + (info["summary"] ?? "")).font(Theme.meta).lineLimit(1)
                    Spacer(minLength: 0); Image(systemName: open ? "chevron.up" : "chevron.down").font(.system(size: 9))
                }.foregroundStyle(Theme.textSecondary).contentShape(Rectangle())
            }.buttonStyle(.plain)
            if open { Text(message.content).font(.system(size: 11, design: .monospaced)).foregroundStyle(Theme.textSecondary).textSelection(.enabled).padding(8).frame(maxWidth: .infinity, alignment: .leading).background(Theme.elevated.opacity(0.6), in: RoundedRectangle(cornerRadius: 8)) }
        }.accessibilityElement(children: .combine).accessibilityLabel("Tool \(info["tool"] ?? ""): \(status). \(info["summary"] ?? "")")
    }
}

struct ErrorRow: View {
    @ObservedObject var chat: ChatModel
    let text: String
    var body: some View {
        HStack(alignment: .top, spacing: Theme.Space.sm) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Theme.error)
            Text(text).font(.callout).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            Button("Retry") { chat.retry() }.disabled(chat.thinking)
        }.padding(Theme.Space.md).background(Theme.error.opacity(0.10), in: RoundedRectangle(cornerRadius: Theme.Radius.control)).overlay(RoundedRectangle(cornerRadius: Theme.Radius.control).strokeBorder(Theme.error.opacity(0.35)))
    }
}

// MARK: Approvals

struct ApprovalCard: View {
    @ObservedObject var chat: ChatModel
    let message: ChatMessage
    private var info: [String: String] { (message.payload.flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) } as? [String: String]) ?? [:] }
    var body: some View {
        let status = info["status"] ?? "proposed", destructive = info["permission"] == "destructive"
        VStack(alignment: .leading, spacing: Theme.Space.sm) {
            HStack { Label(status == "proposed" ? (destructive ? "Confirm deletion" : "Approval needed") : status == "declined" ? "Declined" : "Approved", systemImage: destructive ? "trash" : (status == "proposed" ? "hand.raised" : status == "declined" ? "minus.circle" : "checkmark.circle")).font(Theme.cardTitle).foregroundStyle(destructive ? Theme.error : Theme.accent); Spacer()
                Text(status == "proposed" ? "Waiting for you" : status == "running" ? "Running…" : status == "succeeded" ? "Done" : status == "failed" ? "Failed" : "Declined").font(Theme.meta).foregroundStyle(status == "succeeded" ? Theme.mastery : status == "failed" ? Theme.error : Theme.textSecondary) }
            Text(message.content).fixedSize(horizontal: false, vertical: true)
            if status == "proposed", let id = info["actionId"].flatMap(UUID.init) {
                HStack {
                    Button(destructive ? "Delete" : "Approve") { chat.approve(id) }.buttonStyle(.primary).disabled(chat.thinking)
                    Button("Decline") { chat.decline(id) }.disabled(chat.thinking)
                }
            }
        }.padding(Theme.Space.md).background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.card))
            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.card).strokeBorder(destructive ? Theme.error.opacity(0.5) : Theme.accent.opacity(0.4)))
            .accessibilityElement(children: .contain)
    }
}

// MARK: Artifacts

struct ChipRow: View {
    @ObservedObject var chat: ChatModel
    let message: ChatMessage
    var body: some View {
        let chips = (message.payload.flatMap { try? JSONDecoder().decode([ActionChip].self, from: Data($0.utf8)) }) ?? []
        HStack(spacing: Theme.Space.sm) { ForEach(chips, id: \.self) { c in Button(c.label) { chat.perform(c) }.buttonStyle(.secondary) } }.frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct PlanCard: View {
    @ObservedObject var chat: ChatModel
    let message: ChatMessage
    @State private var expanded: Set<Int> = [0]
    private var planId: UUID? { (message.payload.flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) } as? [String: String])?["planId"].flatMap(UUID.init) }
    var body: some View {
        if let id = planId, let rec = try? chat.store.plan(id), let doc = AgentStore.decode(rec) {
            VStack(alignment: .leading, spacing: Theme.Space.sm) {
                HStack { Label(rec.title, systemImage: "calendar").font(Theme.cardTitle); Spacer()
                    if let due = rec.dueDate { Badge(text: "Exam " + due.formatted(date: .abbreviated, time: .omitted), color: Theme.attention) } }
                Text("\(doc.days.count) day(s) · \(doc.totalQuestions) scheduled question(s)" + (doc.topics.isEmpty ? "" : " · Topics: " + doc.topics.prefix(4).joined(separator: ", "))).font(Theme.meta).foregroundStyle(Theme.textSecondary)
                ForEach(doc.notes, id: \.self) { n in Label(n, systemImage: "info.circle").font(Theme.meta).foregroundStyle(Theme.attention).fixedSize(horizontal: false, vertical: true) }
                ForEach(Array(doc.days.enumerated()), id: \.offset) { i, day in
                    let done = day.items.filter { (try? chat.app.practice?.attempts(questionId: $0.questionId))?.isEmpty == false }.count
                    VStack(alignment: .leading, spacing: 4) {
                        Button { if expanded.contains(i) { expanded.remove(i) } else { expanded.insert(i) } } label: {
                            HStack { Text("Day \(i + 1) · \(day.label)").font(.system(.callout, design: .rounded, weight: .semibold)); Spacer()
                                Text(day.items.isEmpty ? "no questions" : "\(done)/\(day.items.count) done · \(day.minutes) min").font(Theme.meta).foregroundStyle(Theme.textSecondary)
                                Image(systemName: expanded.contains(i) ? "chevron.up" : "chevron.down").font(.system(size: 9)) }.contentShape(Rectangle()) }.buttonStyle(.plain)
                        if !day.items.isEmpty { MeterBar(value: Double(done) / Double(day.items.count), tint: Theme.mastery, height: 4) }
                        if expanded.contains(i) {
                            if !day.focus.isEmpty { Text("Focus: " + day.focus.joined(separator: ", ")).font(Theme.meta).foregroundStyle(Theme.textSecondary) }
                            ForEach(day.items) { it in Text("• \(it.title) — \(it.reason)").font(.system(size: 11.5)).foregroundStyle(Theme.textSecondary).lineLimit(2) }
                            if !day.note.isEmpty { Text(day.note).font(Theme.meta).foregroundStyle(Theme.accent) }
                            if !day.items.isEmpty { Button("Start this day’s practice") { chat.startPlanDay(planId: id, dayIndex: i) }.buttonStyle(.primary).controlSize(.small) }
                        }
                    }.padding(Theme.Space.sm).background(Theme.elevated.opacity(0.5), in: RoundedRectangle(cornerRadius: Theme.Radius.control))
                }
            }.padding(Theme.Space.md).background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.card)).overlay(RoundedRectangle(cornerRadius: Theme.Radius.card).strokeBorder(Theme.border))
        } else { Text("This study plan is no longer available.").font(Theme.meta).foregroundStyle(Theme.textSecondary) }
    }
}

struct PreviewCard: View {
    @ObservedObject var chat: ChatModel
    let message: ChatMessage
    private var actionId: UUID? { (message.payload.flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) } as? [String: String])?["actionId"].flatMap(UUID.init) }
    var body: some View {
        if let id = actionId, let act = try? chat.store.action(id), let data = act.result?.data(using: .utf8), let g = try? JSONDecoder().decode(AgentRegistry.GenerationResult.self, from: data) {
            let valid = g.items.filter(\.valid)
            VStack(alignment: .leading, spacing: Theme.Space.sm) {
                Label("Question preview", systemImage: "checklist").font(Theme.cardTitle)
                Text("\(valid.count) valid, \(g.items.count - valid.count) rejected by validation. Nothing is in your Question Bank until you save.").font(Theme.meta).foregroundStyle(Theme.textSecondary)
                ForEach(Array(g.items.enumerated()), id: \.offset) { _, it in
                    HStack(alignment: .top, spacing: 6) { Image(systemName: it.valid ? "checkmark.circle" : "xmark.circle").foregroundStyle(it.valid ? Theme.mastery : Theme.error).font(.system(size: 11))
                        VStack(alignment: .leading, spacing: 1) { Text(it.title).font(.callout).lineLimit(2); Text(it.valid ? "\(it.type) · difficulty \(it.difficulty)" : (it.issue ?? "Rejected")).font(Theme.meta).foregroundStyle(it.valid ? Theme.textSecondary : Theme.error) } }
                }
                if g.saved { Label(g.savedSummary ?? "Saved", systemImage: "checkmark.seal").font(.callout).foregroundStyle(Theme.mastery) }
                else if act.status == .declined { Label("Discarded", systemImage: "minus.circle").font(.callout).foregroundStyle(Theme.textSecondary) }
                else if !valid.isEmpty { HStack { Button("Save \(valid.count) question\(valid.count == 1 ? "" : "s")") { chat.savePreview(id) }.buttonStyle(.primary).disabled(chat.thinking); Button("Discard") { chat.discardPreview(id) } } }
            }.padding(Theme.Space.md).background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.card)).overlay(RoundedRectangle(cornerRadius: Theme.Radius.card).strokeBorder(Theme.border))
        }
    }
}

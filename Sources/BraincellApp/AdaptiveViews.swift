import SwiftUI
import AppKit
import BraincellCore

/// Optional, shown only for difficult questions, repeat misses or skills with two recent misses.
struct ConfidenceRow: View {
    @ObservedObject var pm: PracticeModel
    var body: some View {
        if pm.askConfidence, !pm.locked {
            HStack(spacing: 8) {
                Text("How sure are you? (optional)").font(.caption).foregroundStyle(.secondary)
                ForEach(1...3, id: \.self) { level in
                    Button(LearningHistoryService.confidenceLabel(level)) { pm.confidence = pm.confidence == level ? nil : level }
                        .buttonStyle(.bordered).controlSize(.small).tint(pm.confidence == level ? Theme.accent : nil)
                        .accessibilityAddTraits(pm.confidence == level ? .isSelected : [])
                }
            }
        }
    }
}

/// A dismissible suggestion. It never replaces, skips or reorders questions on its own.
struct CoachBanner: View {
    @ObservedObject var pm: PracticeModel
    @State private var note = ""
    @State private var saved = false

    var body: some View {
        if let s = pm.coachSuggestion {
            Card {
                VStack(alignment: .leading, spacing: 8) {
                    Label(s.title, systemImage: s.trigger == .breakthrough ? "sparkles" : "lightbulb").font(.headline)
                        .foregroundStyle(s.trigger == .breakthrough ? Theme.mastery : Theme.accent)
                    Text(s.message).font(.callout)
                    if !s.prerequisiteNames.isEmpty {
                        Text("Worth refreshing first: " + s.prerequisiteNames.joined(separator: ", ")).font(.callout.weight(.medium))
                    }
                    if s.offersReflection, !saved {
                        HStack {
                            TextField("A note to yourself (optional)", text: $note).textFieldStyle(.roundedBorder)
                            Button("Save note") { pm.addReflection(note); saved = true }.disabled(note.trimmed.isEmpty)
                        }
                    } else if saved { Label("Saved to your learning history", systemImage: "checkmark").font(.caption).foregroundStyle(Theme.mastery) }
                    HStack {
                        if s.trigger == .repeatedMistakes || s.trigger == .manyHints { Button("Take a break") { pm.dismissCoach(accepted: true); pm.togglePause() } }
                        Button("Dismiss") { pm.dismissCoach() }.keyboardShortcut(.escape, modifiers: [])
                    }
                }
            }
            .accessibilityElement(children: .contain)
        }
    }
}

struct StuckSheet: View {
    @EnvironmentObject var app: AppModel
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var pm: PracticeModel
    let kind: StuckKind
    @State private var guidance: StuckGuidance?
    @State private var tutor = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(kind.label).font(.headline)
            if let g = guidance {
                Text(g.message)
                if g.hasNextHint { Button("Show the next hint") { pm.revealHint(); refresh() } }
                if !g.prerequisites.isEmpty {
                    Divider()
                    Text("Related skills to refresh").font(.subheadline.weight(.semibold))
                    ForEach(g.prerequisites, id: \.skill.id) { p in
                        HStack {
                            Text(p.skill.name)
                            Badge(text: p.mastery.isUnknown ? "Not assessed" : "≈ \(Int(((p.mastery.overall ?? 0) * 100).rounded()))%", color: .secondary)
                            Spacer()
                            Button("Practise it") { practice(p.skill) }
                        }
                    }
                }
                Divider()
                Text("Still stuck? You can copy a help request to paste into ChatGPT yourself. You’ll see exactly what it contains first.").font(.caption).foregroundStyle(.secondary)
                HStack { Button("Prepare a help request…") { tutor = true }; Spacer(); Button("Close") { dismiss() }.keyboardShortcut(.cancelAction) }
            } else { ProgressView() }
        }
        .padding(20).frame(width: 460)
        .onAppear(perform: refresh)
        .sheet(isPresented: $tutor) { TutorSheet(pm: pm, kind: kind) }
    }

    private func refresh() { if let it = pm.item { guidance = try? app.stuck?.guidance(itemId: it.id, kind: kind) } }

    private func practice(_ s: Skill) {
        var f = QuestionFilter(); f.skillId = s.id
        let ids = ((try? app.questions?.list(f)) ?? []).map(\.id)
        if ids.isEmpty { app.alertMessage = "There are no questions for “\(s.name)” yet." }
        else if let c = pm.session?.courseId { dismiss(); pm.flush(); app.startPractice(questionIds: ids, title: s.name, courseId: c) }
    }
}

struct TutorSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var pm: PracticeModel
    let kind: StuckKind
    @State private var includeAttempt = true
    @State private var copied = false

    var body: some View {
        let built = pm.spec.map { TutorPrompt.build(spec: $0, response: pm.response, kind: kind, revealedHints: pm.hintsUsed, skillNames: pm.skills.map(\.name), includeResponse: includeAttempt) }
        VStack(alignment: .leading, spacing: 10) {
            Text("Help request for ChatGPT").font(.headline)
            if let built {
                Card { VStack(alignment: .leading, spacing: 3) { Text("This will be shared").font(.subheadline.weight(.semibold)); ForEach(built.disclosure, id: \.self) { Text("• " + $0).font(.callout) } } }
                Toggle("Include my attempt so far", isOn: $includeAttempt)
                TextEditor(text: .constant(built.text)).font(.system(.caption, design: .monospaced)).frame(minHeight: 180).border(.quaternary)
                if copied { Text("Copied. Paste it into ChatGPT yourself; Braincell doesn’t open it for you.").foregroundStyle(Theme.mastery) }
                HStack {
                    Spacer(); Button("Close") { dismiss() }.keyboardShortcut(.cancelAction)
                    Button("Copy to Clipboard") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(built.text, forType: .string); copied = true }.keyboardShortcut(.defaultAction)
                }
                Text("This is a one-off tutoring chat, so there is nothing to import back.").font(.caption).foregroundStyle(.secondary)
            }
        }.padding(20).frame(width: 560, height: 520)
    }
}

import SwiftUI
import BraincellCore

struct PracticeView: View {
    @EnvironmentObject var app: AppModel
    @StateObject private var pm: PracticeModel
    @Environment(\.scenePhase) private var scenePhase
    @State private var showCoach = true
    @State private var stuck: StuckKind?
    @State private var showWhy = false
    private let ticker = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    init(sessionID: UUID, app: AppModel) { _pm = StateObject(wrappedValue: PracticeModel(app: app, sessionID: sessionID)) }

    var body: some View {
        VStack(spacing: 0) {
            topBar
            Divider()
            if let summary = pm.summary { SummaryView(summary: summary, title: pm.session?.title ?? "", isDiagnostic: pm.session?.mode == .diagnostic, onReflect: pm.addReflection) { pm.exit() } }
            else if let spec = pm.spec {
                ZStack {
                    Group {
                        if pm.layout == .focus { focus(spec) } else { workspace(spec) }
                    }
                    .disabled(pm.paused)
                    if pm.paused { pausedOverlay }
                }
                Divider()
                bottomBar(spec)
            } else { EmptyStateView(symbol: "questionmark.circle", title: "Nothing to practice", message: "This session has no questions.") }
        }
        .background(Theme.background)
        .onReceive(ticker) { _ in pm.tick(active: scenePhase == .active) }
        .onChange(of: scenePhase) { _, p in if p != .active { pm.flush() } }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in pm.flush() }
        .onChange(of: app.snapshotIndex) { _, i in if let i { pm.enter(i) } }
        .onDisappear { pm.flush() }
        .sheet(item: $stuck) { StuckSheet(pm: pm, kind: $0) }
    }

    // MARK: Chrome

    private var topBar: some View {
        HStack(spacing: 12) {
            Button { pm.exit() } label: { Label("Exit", systemImage: "chevron.left") }
                .help("Leave the session. Your work is saved and you can resume it from Home.")
            Text(pm.session?.title ?? "Practice").font(Theme.cardTitle).lineLimit(1)
            Spacer()
            if !pm.items.isEmpty {
                Text("\(pm.index + 1) of \(pm.items.count)").font(.system(.callout, design: .rounded, weight: .medium)).monospacedDigit().foregroundStyle(Theme.textSecondary)
                MeterBar(value: Double(pm.items.filter { $0.status == .submitted }.count) / Double(max(1, pm.items.count)), tint: Theme.mastery).frame(width: 110)
                    .accessibilityLabel("Progress").accessibilityValue("\(pm.items.filter { $0.status == .submitted }.count) of \(pm.items.count) submitted")
            }
            FocusChip()
            Text(pm.examActive ? "\(Self.clock(pm.examRemaining)) left" : Self.clock(pm.seconds)).font(.system(.callout, design: .rounded)).monospacedDigit().foregroundStyle(pm.examActive && pm.examRemaining < 300 ? Theme.attention : Theme.textSecondary).help(pm.examActive ? "Exam time remaining" : "Active time on this question")
                .accessibilityLabel("Active time \(pm.seconds / 60) minutes \(pm.seconds % 60) seconds")
            Button { pm.togglePause() } label: { Image(systemName: pm.paused ? "play.fill" : "pause.fill") }
                .help(pm.paused ? "Resume" : "Pause the timer").accessibilityLabel(pm.paused ? "Resume" : "Pause")
            if pm.layout == .workspace {
                Button { showCoach.toggle() } label: { Image(systemName: "sidebar.right") }.help("Show or hide help").accessibilityLabel("Toggle help panel")
            }
            Button(pm.examActive ? "Submit Exam" : "Finish") { pm.finish() }.help(pm.examActive ? "Submit all saved answers and see your score" : "End the session and see a summary")
        }
        .padding(.horizontal, Theme.Space.xl).padding(.vertical, Theme.Space.md).background(Theme.surface)
    }

    private func bottomBar(_ spec: QuestionSpec) -> some View {
        HStack {
            Button { pm.go(-1) } label: { Label("Previous", systemImage: "arrow.left") }.disabled(pm.index == 0).keyboardShortcut("[", modifiers: .command)
            Button { pm.go(1) } label: { Label("Next", systemImage: "arrow.right") }.disabled(pm.isLast).keyboardShortcut("]", modifiers: .command)
            Spacer()
            if !pm.locked && pm.examActive {
                Button(pm.isLast ? "Save answer" : "Save & Next") { pm.submit() }.buttonStyle(.primary).keyboardShortcut(.return, modifiers: .command).disabled(pm.response.isEmpty)
            } else if !pm.locked {
                Menu("Stuck?") { ForEach(StuckKind.allCases) { k in Button(k.label) { stuck = k } } }.menuStyle(.borderlessButton).fixedSize()
                    .help("Get unstuck with prepared hints, related skills, or a help request you can send to ChatGPT yourself")
                Button("Hint (\(pm.hintsUsed)/\(spec.hints.count))") { pm.revealHint() }
                    .disabled(pm.hintsUsed >= spec.hints.count).keyboardShortcut("h", modifiers: [.command, .shift])
                Button("Skip") { pm.skip() }.keyboardShortcut("]", modifiers: [.command, .shift])
                    .help("Skip for now. Anything you wrote is kept.")
                Button(spec.type == .flashcard ? "Done" : "Submit") { pm.submit() }
                    .buttonStyle(.primary).keyboardShortcut(.return, modifiers: .command)
                    .disabled(pm.response.isEmpty || (spec.type == .flashcard && !pm.response.revealed))
            } else if pm.isLast {
                Button("Finish Session") { pm.finish() }.buttonStyle(.primary)
            } else {
                Button("Next Question") { pm.go(1) }.buttonStyle(.primary).keyboardShortcut(.return, modifiers: .command)
            }
        }
        .padding(.horizontal, Theme.Space.xl).padding(.vertical, Theme.Space.md).background(Theme.surface)
    }

    private var pausedOverlay: some View {
        VStack(spacing: 12) {
            Image(systemName: "pause.circle").font(.system(size: 40)).foregroundStyle(Theme.accent)
            Text("Paused").font(Theme.sectionTitle)
            Text("The timer is stopped and your work is saved.").foregroundStyle(Theme.textSecondary)
            Button("Resume") { pm.togglePause() }.buttonStyle(.primary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity).background(.regularMaterial)
    }

    static func clock(_ s: Int) -> String { String(format: "%d:%02d", s / 60, s % 60) }

    // MARK: Layouts

    private func focus(_ spec: QuestionSpec) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Card(padding: Theme.Space.xl) {
                    VStack(alignment: .leading, spacing: Theme.Space.lg) { header(spec); BlocksView(blocks: spec.content) }
                }
                AnswerView(spec: spec, response: $pm.response, locked: pm.locked, fontSize: CGFloat(app.codeFontSize), pm: pm, onSubmit: pm.submit)
                ConfidenceRow(pm: pm)
                if !pm.examActive { hints(spec) }
                if pm.locked { GradePanel(pm: pm, spec: spec); CoachBanner(pm: pm); ReferencePanel(spec: spec, response: pm.response, fontSize: CGFloat(app.codeFontSize)) }
            }
            .padding(32).frame(maxWidth: 740, alignment: .leading).frame(maxWidth: .infinity)
        }
    }

    private func workspace(_ spec: QuestionSpec) -> some View {
        HSplitView {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) { header(spec); BlocksView(blocks: spec.content) }
                    .padding(20).frame(maxWidth: .infinity, alignment: .leading)
            }.frame(minWidth: 260, idealWidth: 380)
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    AnswerView(spec: spec, response: $pm.response, locked: pm.locked, fontSize: CGFloat(app.codeFontSize), pm: pm, onSubmit: pm.submit)
                    ConfidenceRow(pm: pm)
                    if pm.locked { GradePanel(pm: pm, spec: spec); CoachBanner(pm: pm); ReferencePanel(spec: spec, response: pm.response, fontSize: CGFloat(app.codeFontSize)) }
                }.padding(20).frame(maxWidth: .infinity, alignment: .leading)
            }.frame(minWidth: 340, idealWidth: 520)
            if showCoach && !pm.examActive {
                ScrollView { VStack(alignment: .leading, spacing: 14) { coach(spec) }.padding(16).frame(maxWidth: .infinity, alignment: .leading) }
                    .frame(minWidth: 200, idealWidth: 240, maxWidth: 320).background(Theme.surface)
            }
        }
    }

    private func header(_ spec: QuestionSpec) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Badge(text: spec.type.label); Badge(text: "Difficulty \(spec.difficulty)/5", color: Theme.textSecondary)
                if let it = pm.item, it.kind != .practice {
                    Badge(text: it.kind == .diagnostic ? "Quick check" : it.kind.rawValue.capitalized, color: it.kind == .review ? Theme.mastery : (it.kind == .repair ? Theme.attention : Theme.accent))
                }
                if let it = pm.item, !it.reason.isEmpty {
                    Button { showWhy.toggle() } label: { Label("Why this question?", systemImage: "questionmark.circle") }.buttonStyle(.borderless).font(.caption)
                        .popover(isPresented: $showWhy) { Text(it.reason).padding(14).frame(width: 320, alignment: .leading) }
                }
            }
            Text(spec.title).font(Theme.sectionTitle)
        }
    }

    @ViewBuilder private func hints(_ spec: QuestionSpec) -> some View {
        if pm.hintsUsed > 0 {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(0..<min(pm.hintsUsed, spec.hints.count), id: \.self) { i in
                    Label { RichText(text: spec.hints[i]) } icon: { Image(systemName: "lightbulb").foregroundStyle(Theme.attention) }
                }
            }
        }
    }

    @ViewBuilder private func coach(_ spec: QuestionSpec) -> some View {
        Text("Help").font(Theme.cardTitle)
        Text("On demand. Using hints is recorded.").font(Theme.meta).foregroundStyle(Theme.textSecondary)
        if spec.hints.isEmpty { Text("No hints for this question.").foregroundStyle(Theme.textSecondary) }
        hints(spec)
        if !pm.locked, pm.hintsUsed < spec.hints.count { Button("Show hint \(pm.hintsUsed + 1) of \(spec.hints.count)") { pm.revealHint() } }
        if !spec.sources.isEmpty {
            Divider()
            Text("Sources").font(.subheadline.weight(.semibold))
            ForEach(Array(spec.sources.enumerated()), id: \.offset) { _, s in
                Text([s.document, s.page.map { "p.\($0)" }, s.note].compactMap { $0 }.joined(separator: " · ")).font(.caption)
            }
        }
        if !pm.skills.isEmpty {
            Divider()
            Text("Skills").font(.subheadline.weight(.semibold))
            ForEach(pm.skills) { Text($0.name).font(.caption) }
        }
    }
}

// MARK: Answer controls

struct AnswerView: View {
    let spec: QuestionSpec
    @Binding var response: PracticeResponse
    let locked: Bool
    let fontSize: CGFloat
    var pm: PracticeModel? = nil
    var onSubmit: () -> Void

    var body: some View {
        switch spec.type {
        case .flashcard: flashcard
        case .singleChoice, .multipleSelect: choices
        case .shortAnswer:
            if spec.evaluation.method == .symbolic {
                MathInputField(text: $response.text, locked: locked, fontSize: fontSize, minHeight: 44, label: "Your answer (math)") { if !response.isEmpty { onSubmit() } }
            } else {
                TextField("Your answer", text: $response.text).textFieldStyle(AppFieldStyle()).font(.title3).disabled(locked)
                    .onSubmit { if !response.isEmpty { onSubmit() } }.accessibilityLabel("Your answer")
            }
        case .numeric:
            HStack {
                TextField("Number (e.g. 3.5 or 7/2)", text: $response.text).textFieldStyle(AppFieldStyle()).font(.title3).frame(maxWidth: 260).disabled(locked)
                    .onSubmit { if !response.isEmpty { onSubmit() } }.accessibilityLabel("Numeric answer")
                if let u = spec.answer.unit, !u.isEmpty { Text(u).foregroundStyle(Theme.textSecondary) }
            }
        case .codeTracing:
            VStack(alignment: .leading, spacing: 6) {
                Text("What is the exact output?").font(.subheadline).foregroundStyle(Theme.textSecondary)
                TextEditor(text: $response.text).font(.system(size: fontSize, design: .monospaced)).frame(minHeight: 100).disabled(locked)
                    .fieldSurface().accessibilityLabel("Expected output")
            }
        case .coding: coding
        case .longForm, .derivationProof: written
        }
    }

    private var flashcard: some View {
        VStack(alignment: .leading, spacing: 12) {
            if response.revealed {
                Divider()
                BlocksView(blocks: spec.answer.back ?? [])
            } else {
                Button { response.revealed = true } label: { Label("Show answer", systemImage: "eye") }
                    .buttonStyle(.primary).keyboardShortcut(.space, modifiers: [])
                    .disabled(locked)
                Text("Try to recall it first. Space reveals the answer.").font(.caption).foregroundStyle(Theme.textSecondary)
            }
        }
    }

    private var choices: some View {
        let multi = spec.type == .multipleSelect
        return VStack(alignment: .leading, spacing: 8) {
            if multi { Text("Select all that apply").font(.subheadline).foregroundStyle(Theme.textSecondary) }
            ForEach(Array((spec.answer.choices ?? []).enumerated()), id: \.element.id) { i, c in
                let on = response.selected.contains(c.id)
                Button {
                    if multi { if on { response.selected.removeAll { $0 == c.id } } else { response.selected.append(c.id) } }
                    else { response.selected = [c.id] }
                } label: {
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: on ? (multi ? "checkmark.square.fill" : "largecircle.fill.circle") : (multi ? "square" : "circle"))
                            .foregroundStyle(on ? Theme.accent : .secondary)
                        RichText(text: c.text)
                        Spacer()
                        if i < 9 { Text("\(i + 1)").font(.caption).foregroundStyle(Theme.textSecondary) }
                    }
                    .padding(Theme.Space.md + 2).background(on ? Theme.accent.opacity(0.10) : Theme.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.control + 2))
                    .overlay(RoundedRectangle(cornerRadius: Theme.Radius.control + 2).strokeBorder(on ? Theme.accent : Theme.border, lineWidth: on ? 1.5 : 1))
                }
                .buttonStyle(.plain).disabled(locked)
                .keyboardShortcut(i < 9 ? KeyEquivalent(Character("\(i + 1)")) : .init("0"), modifiers: [])
                .accessibilityLabel(c.text).accessibilityValue(on ? "Selected" : "Not selected")
                .accessibilityAddTraits(on ? .isSelected : [])
            }
        }
    }

    private var coding: some View {
        VStack(alignment: .leading, spacing: 8) {
            CodeWorkspaceView(files: $response.files, isEditable: !locked, fontSize: fontSize).frame(minHeight: 280)
            if let pm { CodeRunPanel(pm: pm, spec: spec) }
            Text("Your files are saved automatically as you type.").font(.caption).foregroundStyle(Theme.textSecondary)
        }
    }

    private var written: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(spec.type == .derivationProof ? "Write your derivation or proof" : "Write your explanation").font(.subheadline).foregroundStyle(Theme.textSecondary)
            Text("Use Insert Math for symbols and templates, or type $…$ for inline math and $$…$$ for display math.").font(.caption).foregroundStyle(Theme.textSecondary)
            MathInputField(text: $response.text, prose: true, locked: locked, fontSize: fontSize, minHeight: 200, label: "Written answer")
        }
    }
}

/// Shown after submission: the reference answer and solution. The verdict itself comes from the grading panel, not from this reference.
struct ReferencePanel: View {
    let spec: QuestionSpec
    let response: PracticeResponse
    let fontSize: CGFloat

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Submitted — your attempt is saved and can’t be changed", systemImage: "lock.fill").font(.subheadline).foregroundStyle(Theme.textSecondary)
            Card {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Reference answer").font(.subheadline.weight(.semibold))
                    Text(summaryText).font(.callout)
                    if spec.type == .coding, let ref = spec.answer.referenceSolution, !ref.isEmpty {
                        CodeWorkspaceView(files: .constant([CodeFile(name: "reference", language: spec.answer.language ?? "python", content: ref)]), isEditable: false, fontSize: fontSize)
                            .frame(height: 200)
                    }
                    if !spec.solution.isEmpty { Divider(); Text("Solution").font(.subheadline.weight(.semibold)); BlocksView(blocks: spec.solution) }
                }
            }
        }
    }

    private var summaryText: String {
        let a = spec.answer
        switch spec.type {
        case .flashcard: return (a.back ?? []).map(\.plainText).joined(separator: " ")
        case .singleChoice, .multipleSelect:
            let correct = (a.choices ?? []).filter { (a.correctIds ?? []).contains($0.id) }.map(\.text)
            let chosen = (a.choices ?? []).filter { response.selected.contains($0.id) }.map(\.text)
            return "Reference: \(correct.joined(separator: "; ")). You selected: \(chosen.isEmpty ? "nothing" : chosen.joined(separator: "; "))."
        case .shortAnswer, .codeTracing: return "Accepted: " + ((a.accepted ?? []) + (a.expectedOutput.map { [$0] } ?? [])).joined(separator: " | ")
        case .numeric: return "Reference: \(a.value.map { String($0) } ?? "—") ± \(a.tolerance ?? 0) \(a.unit ?? "")"
        case .coding: return "Reference solution below."
        case .longForm, .derivationProof:
            return "Graded against: " + ((spec.evaluation.rubric ?? []).map { "\($0.criterion) (\(Int($0.points)))" }.joined(separator: "; "))
        }
    }
}

struct SummaryView: View {
    @EnvironmentObject var app: AppModel
    let summary: SessionResults
    let title: String
    var isDiagnostic = false
    var onReflect: (String) -> Void = { _ in }
    var done: () -> Void
    @State private var note = ""
    @State private var noteSaved = false

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                Image(systemName: "checkmark.seal").font(.system(size: 40)).foregroundStyle(Theme.mastery)
                Text("Session complete").font(.title.weight(.semibold))
                Text(title).foregroundStyle(Theme.textSecondary)
                HStack(spacing: 10) {
                    stat("Correct", summary.correct, Theme.mastery); stat("Partly", summary.partial, Theme.attention)
                    stat("Not quite", summary.incorrect, Theme.attention); stat("Waiting", summary.pending + summary.needsReview, .secondary)
                    stat("Skipped", summary.skipped + summary.unanswered, .secondary)
                }
                Card {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack { Label("+\(summary.xp) XP", systemImage: "sparkles").font(.headline).foregroundStyle(Theme.accent); Spacer()
                            Text("\(summary.hintsUsed) hint\(summary.hintsUsed == 1 ? "" : "s") · \(PracticeView.clock(summary.activeSeconds))").foregroundStyle(Theme.textSecondary) }
                        if summary.provisional > 0 {
                            Text("\(summary.provisional) grade\(summary.provisional == 1 ? " is" : "s are") provisional: the answer key isn’t verified, so they count for less and earn no correctness bonus. Mark a question Verified in the Question Bank to upgrade it.")
                                .font(.caption).foregroundStyle(Theme.textSecondary)
                        }
                        if summary.pending > 0 {
                            Divider()
                            Text("\(summary.pending) answer\(summary.pending == 1 ? " is" : "s are") waiting for a grade. They are not counted as wrong.").font(.callout)
                            Button("Grade pending answers with ChatGPT…") { app.showGradingSheet = true; app.selection = .aiTasks; done() }
                        }
                    }
                }.frame(maxWidth: 560)
                Card {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(summary.items) { it in
                            HStack(alignment: .firstTextBaseline) {
                                Text(it.title).lineLimit(1)
                                Spacer()
                                Text(verdict(it)).font(.caption).foregroundStyle(color(it))
                                if it.xp != 0 { Text("+\(it.xp)").font(.caption.monospacedDigit()).foregroundStyle(Theme.accent) }
                            }.accessibilityElement(children: .combine)
                        }
                    }
                }.frame(maxWidth: 560)
                if isDiagnostic {
                    Label("A short diagnostic gives early signals only. Skills stay Preliminary until you’ve answered more.", systemImage: "info.circle").font(.callout).foregroundStyle(Theme.textSecondary).frame(maxWidth: 560)
                }
                Card {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Anything to remember from this session? (optional)").font(.subheadline)
                        if noteSaved { Label("Saved to your learning history", systemImage: "checkmark").font(.caption).foregroundStyle(Theme.mastery) }
                        else {
                            HStack { TextField("A short note to your future self", text: $note).textFieldStyle(AppFieldStyle())
                                Button("Save") { onReflect(note); noteSaved = true }.disabled(note.trimmed.isEmpty) }
                        }
                    }
                }.frame(maxWidth: 560)
                Button("Done", action: done).buttonStyle(.primary).keyboardShortcut(.defaultAction)
            }
            .frame(maxWidth: .infinity).padding(32)
        }
    }

    private func stat(_ label: String, _ n: Int, _ color: Color) -> some View {
        VStack { Text("\(n)").font(.title2.weight(.semibold).monospacedDigit()).foregroundStyle(color); Text(label).font(.caption).foregroundStyle(Theme.textSecondary) }
            .frame(width: 84).padding(.vertical, 10).background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.control)).overlay(RoundedRectangle(cornerRadius: Theme.Radius.control).strokeBorder(Theme.border))
            .accessibilityElement(children: .combine)
    }

    private func verdict(_ it: ItemResult) -> String {
        switch it.item.status {
        case .skipped: return "Skipped"
        case .notStarted, .inProgress: return "Not answered"
        case .submitted:
            guard let e = it.evaluation else { return "Waiting" }
            switch e.state {
            case .pending, .evaluatorUnavailable: return "Waiting for grade"
            case .needsReview: return "Needs review"
            case .graded: return GradePanel.verdictText(e)
            }
        }
    }
    private func color(_ it: ItemResult) -> Color {
        guard let e = it.evaluation, e.state == .graded else { return .secondary }
        return (e.score ?? 0) >= 0.8 ? Theme.mastery : Theme.attention
    }
}

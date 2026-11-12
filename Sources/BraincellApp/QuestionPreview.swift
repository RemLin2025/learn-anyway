import SwiftUI
import BraincellCore

extension Readiness {
    var color: Color {
        switch self { case .verified: Theme.mastery; case .unverified: .secondary; case .needsReview: Theme.attention; case .invalid: .red }
    }
}

/// Native rendering of one content block. Markdown is limited to inline formatting and links are inert:
/// question content comes from untrusted AI output.
struct BlockView: View {
    let block: ContentBlock
    var body: some View {
        switch block.kind {
        case .markdown:
            MathContentView(text: block.text ?? "")
        case .code:
            VStack(alignment: .leading, spacing: 4) {
                if let l = block.language { Text(l.uppercased()).font(.caption2.weight(.semibold)).foregroundStyle(Theme.textSecondary) }
                Text(block.text ?? "").font(.system(.body, design: .monospaced)).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(10).background(Theme.elevated, in: RoundedRectangle(cornerRadius: 8))
            .accessibilityLabel("Code, \(block.language ?? "unknown language")")
        case .math:
            DisplayMath(latex: block.latex ?? "", boxed: MathMarkdown.shouldBox(block.latex ?? ""), size: 22)
        case .table:
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 4) {
                GridRow { ForEach(Array((block.headers ?? []).enumerated()), id: \.offset) { InlineContent(inlines: MathMarkdown.inline($1), size: 17, weight: .semibold) } }
                Divider()
                ForEach(Array((block.rows ?? []).enumerated()), id: \.offset) { _, row in
                    GridRow { ForEach(Array(row.enumerated()), id: \.offset) { InlineContent(inlines: MathMarkdown.inline($1), size: 16) } }
                }
            }
        case .image:
            Label(block.description ?? "Image", systemImage: "photo").foregroundStyle(Theme.textSecondary)
                .accessibilityLabel("Image: \(block.description ?? "")")
        }
    }

    static func markdown(_ s: String) -> AttributedString {
        (try? AttributedString(markdown: s, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(s)
    }
}

struct BlocksView: View {
    let blocks: [ContentBlock]
    var body: some View {
        VStack(alignment: .leading, spacing: 10) { ForEach(Array(blocks.enumerated()), id: \.offset) { BlockView(block: $1) } }
    }
}

struct QuestionPreview: View {
    @EnvironmentObject var model: AppModel
    let detail: QuestionDetail
    var onEdit: () -> Void
    @State private var reveal = false

    var body: some View {
        let q = detail.question, spec = detail.spec
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text(spec.title).font(.title2.weight(.semibold))
                HStack(spacing: 6) {
                    Badge(text: spec.type.label)
                    Badge(text: "Difficulty \(spec.difficulty)/5", color: Theme.textSecondary)
                    Badge(text: q.readiness.label, color: q.readiness.color)
                    if q.verificationSource == .user { Badge(text: "Verified by you", color: Theme.mastery) }
                }
                Text(spec.learningObjective).foregroundStyle(Theme.textSecondary)

                if !q.notes.isEmpty {
                    Card {
                        VStack(alignment: .leading, spacing: 4) {
                            Label("Needs review", systemImage: "exclamationmark.triangle").foregroundStyle(Theme.attention).font(.headline)
                            ForEach(q.notes, id: \.self) { Text("• " + $0).font(.callout) }
                        }
                    }
                }
                if let n = (try? model.evaluation?.affectedAttempts(questionId: q.id).count), n > 0 {
                    Card {
                        VStack(alignment: .leading, spacing: 6) {
                            Label("\(n) answer\(n == 1 ? " was" : "s were") graded against an older version", systemImage: "arrow.triangle.2.circlepath").foregroundStyle(Theme.attention).font(.headline)
                            Text("The answer or grading changed after they were submitted. Regrading adds a new grade and keeps the old one in history; XP is corrected in the ledger.").font(.caption)
                            Button("Regrade automatically graded answers") { model.perform { _ = try model.evaluation?.regradeQuestion(questionId: q.id) } }
                        }
                    }
                }
                if q.readiness == .unverified {
                    Text("Unverified: the answer hasn’t been independently confirmed, so it isn’t used for trusted automatic grading.")
                        .font(.caption).foregroundStyle(Theme.textSecondary)
                }

                BlocksView(blocks: spec.content)
                answerView(spec)

                DisclosureGroup("Answer & solution", isExpanded: $reveal) {
                    VStack(alignment: .leading, spacing: 10) {
                        Text(answerSummary(spec)).font(.callout.weight(.medium))
                        BlocksView(blocks: spec.solution)
                    }.padding(.top, 6)
                }
                if !spec.hints.isEmpty {
                    DisclosureGroup("Hints (\(spec.hints.count))") {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(Array(spec.hints.enumerated()), id: \.offset) { i, h in HStack(alignment: .top) { Text("\(i + 1)."); RichText(text: h) } }
                        }.padding(.top, 4)
                    }
                }
                if !spec.sources.isEmpty {
                    Text("Sources: " + spec.sources.map { [$0.document, $0.page.map { "p.\($0)" }].compactMap { $0 }.joined(separator: " ") }.joined(separator: "; "))
                        .font(.caption).foregroundStyle(Theme.textSecondary)
                }
                Divider()
                LabeledContent("Skills") { Text(detail.skills.isEmpty ? "None" : detail.skills.map(\.name).joined(separator: ", ")) }
                LabeledContent("Assessments") { Text(detail.assessments.isEmpty ? "None" : detail.assessments.map(\.name).joined(separator: ", ")) }
                LabeledContent("Revision") { Text("#\(detail.revision.number)") }
                HStack {
                    Button("Edit…", action: onEdit)
                    if q.readiness != .verified { Button("Mark Verified") { model.perform { try model.questions?.markVerified(q.id); _ = try model.evaluation?.regradeQuestion(questionId: q.id) } } }
                    if spec.evaluation.method == .codeTests {
                        Button("Verify Tests…") { Task { await verifyTests(q.id) } }
                            .help("Runs the reference solution against the question’s own tests in the sandbox")
                    }
                    Button("Generate Similar…") {
                        model.generateRequest = GenerateRequest(courseId: q.courseId, skillIds: detail.skills.map(\.id), notes: "Create variations similar to: “\(spec.title)”")
                    }
                    Button("Practice") { model.startPractice(questionIds: [q.id], title: spec.title, courseId: q.courseId) }
                }
            }
            .padding(20).frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func verifyTests(_ id: UUID) async {
        guard let db = model.db else { return }
        do {
            switch try await CodeVerificationService(db: db).verify(questionId: id, runner: model.codeRunner) {
            case .verified: model.alertMessage = "Verified: the reference solution passes every test."
            case .failed(let f): model.alertMessage = "The reference solution fails: \(f.joined(separator: "; ")). The question is marked Needs review."
            case .compileError(let m): model.alertMessage = "The reference solution doesn’t compile: \(m)"
            }
        } catch { model.alertMessage = error.localizedDescription }
        model.reload()
    }

    /// Non-interactive until the practice workspace (M4); shows what the learner will answer with.
    @ViewBuilder private func answerView(_ spec: QuestionSpec) -> some View {
        switch spec.type {
        case .singleChoice, .multipleSelect:
            VStack(alignment: .leading, spacing: 6) {
                ForEach(spec.answer.choices ?? [], id: \.id) { c in
                    Label(c.text, systemImage: spec.type == .singleChoice ? "circle" : "square").foregroundStyle(Theme.textSecondary)
                }
            }
        case .numeric: Label("Numeric answer\(spec.answer.unit.map { " (\($0))" } ?? "")", systemImage: "number").foregroundStyle(Theme.textSecondary)
        case .coding: Label("Code editor (\((spec.answer.language ?? "").capitalized)). Running tests isn’t available: Learn Anyway doesn’t execute code yet.", systemImage: "chevron.left.forwardslash.chevron.right").foregroundStyle(Theme.textSecondary)
        case .longForm, .derivationProof: Label("Written response, graded by rubric or self-review", systemImage: "text.alignleft").foregroundStyle(Theme.textSecondary)
        default: EmptyView()
        }
    }

    private func answerSummary(_ s: QuestionSpec) -> String {
        let a = s.answer
        switch s.type {
        case .flashcard: return "Back: " + (a.back ?? []).map(\.plainText).joined(separator: " ")
        case .singleChoice, .multipleSelect:
            let correct = (a.choices ?? []).filter { (a.correctIds ?? []).contains($0.id) }.map(\.text)
            return "Correct: " + correct.joined(separator: "; ")
        case .shortAnswer, .codeTracing: return "Accepted: " + ((a.accepted ?? []) + (a.expectedOutput.map { [$0] } ?? [])).joined(separator: " | ")
        case .numeric: return "Answer: \(a.value ?? 0) ± \(a.tolerance ?? 0) \(a.unit ?? "")"
        case .coding: return "Reference solution available below"
        case .longForm, .derivationProof: return "Graded against rubric (\(s.evaluation.rubric?.count ?? 0) criteria)"
        }
    }
}

// MARK: Editor

struct QuestionEditor: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let detail: QuestionDetail
    @State private var title = ""
    @State private var difficulty = 3
    @State private var objective = ""
    @State private var statement = ""
    @State private var solution = ""
    @State private var hints = ""
    @State private var accepted = ""
    @State private var value = ""
    @State private var tolerance = ""
    @State private var back = ""
    @State private var choices: [Choice] = []
    @State private var correct: Set<String> = []
    @State private var error: String?

    var body: some View {
        let spec = detail.spec
        VStack(alignment: .leading, spacing: 10) {
            Text("Edit question").font(.headline)
            Text("Saving creates revision #\(detail.revision.number + 1). Earlier attempts stay linked to the revision they answered.").font(.caption).foregroundStyle(Theme.textSecondary)
            ScrollView {
                Form {
                    TextField("Title", text: $title)
                    Stepper("Difficulty \(difficulty)", value: $difficulty, in: 1...5)
                    TextField("Learning objective", text: $objective)
                    LabeledContent("Statement") { TextEditor(text: $statement).frame(height: 90).fieldSurface() }
                    switch spec.type {
                    case .flashcard: LabeledContent("Back") { TextEditor(text: $back).frame(height: 60).fieldSurface() }
                    case .singleChoice, .multipleSelect:
                        ForEach(choices.indices, id: \.self) { i in
                            HStack {
                                Toggle("Correct", isOn: Binding(get: { correct.contains(choices[i].id) },
                                    set: { on in
                                        if spec.type == .singleChoice { correct = on ? [choices[i].id] : [] }
                                        else if on { correct.insert(choices[i].id) } else { correct.remove(choices[i].id) } })).labelsHidden()
                                TextField("Choice \(choices[i].id)", text: $choices[i].text)
                            }
                        }
                    case .shortAnswer, .codeTracing: LabeledContent("Accepted (one per line)") { TextEditor(text: $accepted).frame(height: 60).fieldSurface() }
                    case .numeric:
                        TextField("Value", text: $value); TextField("Tolerance", text: $tolerance)
                    default: EmptyView()
                    }
                    LabeledContent("Solution") { TextEditor(text: $solution).frame(height: 70).fieldSurface() }
                    LabeledContent("Hints (one per line)") { TextEditor(text: $hints).frame(height: 60).fieldSurface() }
                }.formStyle(.columns)
            }
            if let error { Text(error).foregroundStyle(.red).font(.callout) }
            HStack { Spacer(); Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save Revision", action: save).keyboardShortcut(.defaultAction) }
        }
        .padding(Theme.Space.xl).frame(width: 560, height: 560).background(Theme.background)
        .onAppear(perform: load)
    }

    private func load() {
        let s = detail.spec
        title = s.title; difficulty = s.difficulty; objective = s.learningObjective
        statement = s.content.first { $0.kind == .markdown }?.text ?? ""
        solution = s.solution.first { $0.kind == .markdown }?.text ?? ""
        hints = s.hints.joined(separator: "\n")
        accepted = (s.answer.accepted ?? []).joined(separator: "\n")
        value = s.answer.value.map { String($0) } ?? ""; tolerance = s.answer.tolerance.map { String($0) } ?? ""
        back = (s.answer.back ?? []).first { $0.kind == .markdown }?.text ?? ""
        choices = s.answer.choices ?? []; correct = Set(s.answer.correctIds ?? [])
    }

    /// Only the first markdown block of statement/solution/back is editable here; other blocks are preserved as-is.
    private func replaceFirstMarkdown(_ blocks: [ContentBlock], with text: String) -> [ContentBlock] {
        var b = blocks
        if let i = b.firstIndex(where: { $0.kind == .markdown }) { b[i].text = text }
        else if !text.isEmpty { b.insert(.markdown(text), at: 0) }
        return b
    }

    private func save() {
        var s = detail.spec
        s.title = title; s.difficulty = difficulty; s.learningObjective = objective
        s.content = replaceFirstMarkdown(s.content, with: statement)
        s.solution = replaceFirstMarkdown(s.solution, with: solution)
        s.hints = hints.split(separator: "\n").map { String($0) }.filter { !$0.trimmed.isEmpty }
        switch s.type {
        case .flashcard: s.answer.back = replaceFirstMarkdown(s.answer.back ?? [], with: back)
        case .singleChoice, .multipleSelect: s.answer.choices = choices; s.answer.correctIds = choices.map(\.id).filter { correct.contains($0) }
        case .shortAnswer, .codeTracing: s.answer.accepted = accepted.split(separator: "\n").map { String($0) }.filter { !$0.trimmed.isEmpty }
        case .numeric:
            guard let v = Double(value), let t = Double(tolerance.isEmpty ? "0" : tolerance) else { error = "Value and tolerance must be numbers."; return }
            s.answer.value = v; s.answer.tolerance = t
        default: break
        }
        do { try model.questions?.edit(questionId: detail.question.id, spec: s); model.reload(); dismiss() }
        catch { self.error = error.localizedDescription }
    }
}

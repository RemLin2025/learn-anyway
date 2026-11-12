import Foundation

/// A template-independent description of what to show, built from saved questions. Interactive views and the PDF writer both consume it, so changing
/// the template or the output never calls a model: the same stored questions are simply laid out differently.
public enum RenderBlock: Equatable, Sendable {
    case paragraph([MathInline])
    case heading([MathInline])
    case display(String, boxed: Bool)                  // LaTeX; laid out by `MathLayout`, never flattened into symbol text
    case code(String)
    case table(headers: [String], rows: [[String]])
    case list(ordered: Bool, items: [[MathInline]])
    case part(label: String, [MathInline])             // multi-part questions: (a), (b)…
    case image(String)                                 // alt text only; images are not embedded
}

public struct RenderChoice: Equatable, Sendable { public var label: String; public var id: String; public var text: [MathInline] }

public enum RenderAnswerArea: Equatable, Sendable {
    case none
    case lines(Int)
    case box(height: Double)
    case numeric(unit: String?)
    case choices(multiple: Bool)
    case flashcardBack
}

public struct RenderItem: Equatable, Sendable, Identifiable {
    public var id: UUID                                // question id
    public var number: Int
    public var title: String
    public var points: Double?
    public var topic: String?
    public var difficulty: Int
    public var type: QuestionType
    public var blocks: [RenderBlock]
    public var choices: [RenderChoice]
    public var answerArea: RenderAnswerArea
    public var hints: [String]
    public var solution: [RenderBlock]
    public var answerKey: String                       // short statement of the correct answer
    public var sources: [String]
}

public struct RenderDocument: Equatable, Sendable {
    public var title: String
    public var header: String
    public var instructions: String
    public var items: [RenderItem]
    public var skipped: [String]                       // questions the template can't present, with reasons
    public var totalPoints: Double?
    public var templateId: String
    public var layout: LearningTemplate.Layout
}

public enum RenderBuilder {
    /// Deterministic ordering: the same questions, template and seed always give the same sequence.
    static func order(_ items: [(UUID, QuestionSpec, String?)], by s: LearningTemplate.Sequencing) -> [(UUID, QuestionSpec, String?)] {
        switch s.order {
        case .planned: return items
        case .easyFirst: return items.enumerated().sorted { ($0.element.1.difficulty, $0.offset) < ($1.element.1.difficulty, $1.offset) }.map(\.element)
        case .hardFirst: return items.enumerated().sorted { ($1.element.1.difficulty, $0.offset) < ($0.element.1.difficulty, $1.offset) }.map(\.element)
        case .byTopic: return items.enumerated().sorted { (($0.element.2 ?? "~"), $0.offset) < (($1.element.2 ?? "~"), $1.offset) }.map(\.element)
        case .shuffled:
            var state = UInt64(truncatingIfNeeded: s.seed) &* 6364136223846793005 &+ 1442695040888963407
            var a = items
            if a.count > 1 { for i in stride(from: a.count - 1, to: 0, by: -1) { state = state &* 6364136223846793005 &+ 1442695040888963407; a.swapAt(i, Int((state >> 33) % UInt64(i + 1))) } }
            return a
        }
    }

    static func blocks(_ content: [ContentBlock]) -> [RenderBlock] {
        content.flatMap { b -> [RenderBlock] in
            switch b.kind {
            case .markdown: return (MathMarkdown.parse(b.text ?? "")).map(convert)
            case .math: return [.display(b.latex ?? "", boxed: false)]
            case .code: return [.code(b.text ?? "")]
            case .table: return [.table(headers: b.headers ?? [], rows: b.rows ?? [])]
            case .image: return [.image(b.description ?? "image")]
            }
        }
    }
    static func convert(_ m: MathBlock) -> RenderBlock {
        switch m {
        case .paragraph(let i): .paragraph(i); case .heading(let i): .heading(i); case .display(let l, let boxed): .display(l, boxed: boxed)
        case .code(_, let t): .code(t); case .list(let o, let it): .list(ordered: o, items: it); case .part(let l, let i): .part(label: l, i)
        }
    }

    /// The short statement of the right answer, shown only in solution files and after-attempt feedback.
    public static func answerKey(_ spec: QuestionSpec) -> String {
        let a = spec.answer
        switch spec.type {
        case .singleChoice, .multipleSelect:
            let cs = a.choices ?? []
            return (a.correctIds ?? []).compactMap { id in cs.firstIndex { $0.id == id }.map { "(\(Self.letter($0))) \(Latex.inlineConverted(cs[$0].text))" } }.joined(separator: "; ")
        case .numeric: return a.value.map { v in "\(Self.num(v))" + (a.tolerance.map { $0 > 0 ? " ± \(Self.num($0))" : "" } ?? "") + (a.unit.map { " \($0)" } ?? "") } ?? ""
        case .shortAnswer: return a.accepted?.first ?? a.expression ?? ""
        case .codeTracing: return a.expectedOutput ?? ""
        case .flashcard: return (a.back ?? []).map(\.plainText).joined(separator: " ")
        case .coding, .longForm, .derivationProof: return ""
        }
    }
    static func letter(_ i: Int) -> String { String(UnicodeScalar(UInt8(65 + i % 26))) }
    static func num(_ v: Double) -> String { v == v.rounded() && abs(v) < 1e12 ? String(Int(v)) : String(format: "%g", v) }

    public static func item(number: Int, id: UUID, spec: QuestionSpec, topic: String?, template t: LearningTemplate) -> RenderItem {
        var bl = blocks(spec.content)
        var choices: [RenderChoice] = []
        if spec.type == .singleChoice || spec.type == .multipleSelect {
            choices = (spec.answer.choices ?? []).enumerated().map { RenderChoice(label: letter($0.offset), id: $0.element.id, text: MathMarkdown.inline($0.element.text)) }
        }
        if spec.type == .flashcard, bl.isEmpty { bl = [.paragraph([.text(spec.title)])] }
        let space = t.layout.answerSpace.height
        let area: RenderAnswerArea
        switch spec.type {
        case .singleChoice: area = .choices(multiple: false)
        case .multipleSelect: area = .choices(multiple: true)
        case .numeric: area = .numeric(unit: spec.answer.unit)
        case .flashcard: area = .flashcardBack
        case .shortAnswer, .codeTracing: area = space == 0 ? .none : .lines(max(1, Int(space / 24)))
        case .longForm, .derivationProof, .coding: area = space == 0 ? .none : .box(height: space * 2)
        }
        var src: [String] = []
        if t.layout.showSourceRefs { src = spec.sources.map { [$0.document, $0.page.map { "p.\($0)" }, $0.note].compactMap { $0 }.joined(separator: ", ") }.filter { !$0.isEmpty } }
        return RenderItem(id: id, number: number, title: spec.title, points: t.scoring.mode == .points ? t.scoring.pointsPerQuestion : nil, topic: t.layout.showTopics ? topic : nil, difficulty: spec.difficulty, type: spec.type,
                          blocks: bl, choices: choices, answerArea: area, hints: spec.hints, solution: blocks(spec.solution), answerKey: answerKey(spec), sources: src)
    }

    /// Builds the document a template presents for saved questions. Skipped questions are reported, never silently dropped.
    public static func build(template t: LearningTemplate, title: String, questions: [(id: UUID, spec: QuestionSpec, topic: String?)]) -> RenderDocument {
        var ok: [(UUID, QuestionSpec, String?)] = [], skipped: [String] = []
        for q in questions {
            if !t.supports(q.spec.type) { skipped.append("“\(q.spec.title)”: \(q.spec.type.rawValue.replacingOccurrences(of: "_", with: " ")) questions aren’t part of \(t.name)."); continue }
            if !(t.difficulty.min...t.difficulty.max).contains(q.spec.difficulty) { skipped.append("“\(q.spec.title)”: difficulty \(q.spec.difficulty) is outside \(t.difficulty.min)–\(t.difficulty.max)."); continue }
            ok.append((q.id, q.spec, q.topic))
        }
        var ordered = order(ok, by: t.sequencing)
        if t.sequencing.maxQuestions > 0, ordered.count > t.sequencing.maxQuestions { skipped.append("\(ordered.count - t.sequencing.maxQuestions) question(s) beyond the template’s limit of \(t.sequencing.maxQuestions) were left out."); ordered = Array(ordered.prefix(t.sequencing.maxQuestions)) }
        let items = ordered.enumerated().map { item(number: $0.offset + 1, id: $0.element.0, spec: $0.element.1, topic: $0.element.2, template: t) }
        let total = t.scoring.mode == .points ? items.reduce(0) { $0 + ($1.points ?? 0) } : nil
        return RenderDocument(title: title, header: t.layout.header, instructions: t.layout.instructions, items: items, skipped: skipped, totalPoints: total, templateId: t.id, layout: t.layout)
    }
}

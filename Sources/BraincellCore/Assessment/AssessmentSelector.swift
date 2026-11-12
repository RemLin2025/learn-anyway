import Foundation
import GRDB

/// Why one passage was (or was not) chosen for an assessment. Stored with the request so a selection can be explained and audited.
public struct SelectionRecord: Codable, Equatable, Sendable {
    public var document: String
    public var page: Int?
    public var ordinal: Int
    public var score: Double
    public var reasons: [String]
    /// confirmed = the learner linked this material to the assessment; userProvided = matches scope the learner stated; inferred = matched by topic/keyword only.
    public var basis: ConfigBasis
    public var linked: Bool
}

public struct SelectionLog: Codable, Equatable, Sendable {
    public var records: [SelectionRecord]; public var skipped: [String]; public var limitations: [String]
}

public struct SelectionResult: Sendable {
    var extracts: [PromptInput.Extract]
    var truncated: Set<String>
    public var records: [SelectionRecord]
    public var skipped: [String]            // passages left out and why (e.g. only covers an excluded topic)
    public var limitations: [String]
}

/// Assessment-specific passage selection. Two assessments over the same documents get different excerpts because the score depends on that
/// assessment's linked materials, stated scope, excluded topics and analyzed practice problems. It never produces topic weights.
enum AssessmentSelector {
    struct Doc { var id: UUID; var title: String; var chunks: [DocumentChunk]; var linked: Bool }
    struct Input {
        var docs: [Doc]
        var includes: [String]; var includeBasis: ConfigBasis
        var excludes: [String]
        var topics: [String]                    // planned slot topics + the assessment's scoped topic names
        var sources: [SourceQuestionRow]        // analyzed practice problems (current, non-stale)
        var assessmentName: String
    }

    static func words(_ s: String) -> [String] { s.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init).filter { $0.count > 3 } }
    /// A term matches when its phrase appears, or every significant word of it does (so "Normal distributions" matches "the normal distribution").
    static func matches(_ term: String, in lower: String) -> Bool {
        let t = term.lowercased().trimmingCharacters(in: .whitespaces)
        if t.isEmpty { return false }
        if lower.contains(t) { return true }
        let w = words(t).map { String($0.prefix(max(4, $0.count - 1))) }      // crude stem: distributions ~ distribution
        return !w.isEmpty && w.allSatisfy { lower.contains($0) }
    }

    static func select(_ input: Input, budget: Int) -> SelectionResult {
        var skipped: [String] = [], limitations: [String] = []
        struct Cand { var doc: Int; var chunk: DocumentChunk; var score: Double; var reasons: [String]; var basis: ConfigBasis; var relevant: Bool }
        var cands: [Cand] = []
        for (di, doc) in input.docs.enumerated() {
            let docSources = input.sources.filter { $0.documentId == doc.id }
            for c in doc.chunks {
                let lower = c.text.lowercased()
                var score = 0.0, reasons: [String] = [], basis: ConfigBasis = .inferred, relevant = false
                let inc = input.includes.filter { matches($0, in: lower) }
                let top = input.topics.filter { matches($0, in: lower) }
                let exc = input.excludes.filter { matches($0, in: lower) }
                let onPage = docSources.filter { c.pageNumber != nil && $0.payload.pages.contains(c.pageNumber!) }
                let srcIn = onPage.filter { s in s.payload.topics.contains { t in input.includes.contains { $0.skillKey == t.skillKey } || input.topics.contains { $0.skillKey == t.skillKey } } }
                let srcExc = onPage.filter { s in !s.payload.topics.isEmpty && s.payload.topics.allSatisfy { t in input.excludes.contains { $0.skillKey == t.skillKey } } }
                let instr = ExtractSelector.instructionScore(c.text) >= 2
                if !inc.isEmpty { score += 3 * Double(min(inc.count, 3)); reasons.append("matches stated scope: " + inc.joined(separator: ", ")); basis = input.includeBasis; relevant = true }
                if !top.isEmpty { score += 2 * Double(min(top.count, 3)); reasons.append("mentions in-scope topic: " + top.prefix(3).joined(separator: ", ")); relevant = true }
                if !srcIn.isEmpty {
                    score += 4; relevant = true
                    reasons.append("analyzed practice problem " + srcIn.prefix(3).map(\.payload.locator).joined(separator: ", ") + (srcIn.contains { $0.payload.solution != nil } ? " with worked solution" : ""))
                    if srcIn.contains(where: { $0.payload.solution != nil }) { score += 1 }
                }
                if instr { score += 4; reasons.append("exam instructions or coverage statement"); relevant = true }
                if doc.linked { score += 1.5; reasons.append("linked to \(input.assessmentName)"); basis = .confirmed }
                // Exclusion only removes passages that are about the excluded topic and about nothing in scope; general or prerequisite text stays.
                if (!exc.isEmpty || (!srcExc.isEmpty && srcIn.isEmpty)) && inc.isEmpty && top.isEmpty && srcIn.isEmpty && !instr {
                    skipped.append("\(doc.title) p.\(c.pageNumber.map(String.init) ?? "?"): only covers excluded topic " + (exc.first ?? srcExc.first?.payload.topics.first ?? ""))
                    continue
                }
                if !relevant { reasons.append("general background (no topic match; kept as possible prerequisite)") }
                cands.append(Cand(doc: di, chunk: c, score: score, reasons: reasons, basis: basis, relevant: relevant))
            }
        }
        // Linked materials get a larger share of the budget, but every passage inside still competes on its own relevance.
        let weights = input.docs.map { $0.linked ? 2.0 : 1.0 }, wsum = weights.reduce(0, +)
        let quota = weights.map { Int(Double(budget) * $0 / max(wsum, 1)) }
        var chosen: [[Cand]] = Array(repeating: [], count: input.docs.count), used = Array(repeating: 0, count: input.docs.count)
        let ordered: [[Cand]] = input.docs.indices.map { i in
            let mine = cands.filter { $0.doc == i }
            let rel = mine.filter(\.relevant).sorted { ($0.score, -$0.chunk.ordinal) > ($1.score, -$1.chunk.ordinal) }
            let rest = mine.filter { !$0.relevant }                                       // general passages: an even sample, not the first pages only
            let step = max(1, rest.count / 6)
            return rel + stride(from: 0, to: rest.count, by: step).map { rest[$0] }
        }
        var take: [UUID: Int] = [:]                                     // characters granted to each chosen passage, granted in relevance order
        for i in input.docs.indices { for c in ordered[i] where used[i] < quota[i] { let n = min(c.chunk.text.count, quota[i] - used[i]); if !c.relevant && n < c.chunk.text.count { continue }; take[c.chunk.id] = n; chosen[i].append(c); used[i] += n } }
        // Budget a document did not need goes to the best remaining passages anywhere, still ranked by relevance; cut passages are topped up first.
        var left = budget - used.reduce(0, +)
        let rest = input.docs.indices.flatMap { i in ordered[i].filter { c in (take[c.chunk.id] ?? 0) < c.chunk.text.count } }.sorted { ($0.score, $1.chunk.ordinal) > ($1.score, $0.chunk.ordinal) }
        for c in rest where left > 0 {
            let n = min(c.chunk.text.count - (take[c.chunk.id] ?? 0), left)
            if !c.relevant && n < c.chunk.text.count - (take[c.chunk.id] ?? 0) { continue }       // background text is only worth sending whole
            if take[c.chunk.id] == nil { chosen[c.doc].append(c) }
            take[c.chunk.id, default: 0] += n; left -= n
        }
        var out: [PromptInput.Extract] = [], records: [SelectionRecord] = [], truncated = Set<String>()
        for i in input.docs.indices {
            let full = input.docs[i].chunks.reduce(0) { $0 + $1.text.count }
            var spent = 0
            for c in chosen[i].sorted(by: { $0.chunk.ordinal < $1.chunk.ordinal }) {
                let room = take[c.chunk.id] ?? 0
                guard room > 0 else { continue }
                out.append(.init(title: input.docs[i].title, page: c.chunk.pageNumber, text: String(c.chunk.text.prefix(room))))
                records.append(SelectionRecord(document: input.docs[i].title, page: c.chunk.pageNumber, ordinal: c.chunk.ordinal, score: c.score, reasons: c.reasons, basis: c.basis, linked: input.docs[i].linked))
                spent += room
            }
            if spent < full { truncated.insert(input.docs[i].title) }
        }
        if input.includes.isEmpty && !input.docs.contains(where: \.linked) { limitations.append("This assessment has no confirmed scope or linked materials, so relevance is inferred from topic names and instructions in the text.") }
        if !input.docs.isEmpty && !records.contains { $0.score > 0 } { limitations.append("No passage matched the assessment's topics; the excerpts are a general sample.") }
        return SelectionResult(extracts: out, truncated: truncated, records: records, skipped: skipped, limitations: limitations)
    }
}

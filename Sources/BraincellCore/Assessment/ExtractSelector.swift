import Foundation

/// Bounded, source-aware choice of passages for a request. Replaces "first document first, first chunks first": every document gets a share
/// of the budget, exam instructions and passages relevant to the planned topics come first, and the rest is an even sample of later pages.
enum ExtractSelector {
    static let instructionWords = ["exam", "midterm", "closed book", "closed notes", "points", "minutes", "covers", "coverage", "decimal places", "rounded", "multiple choice", "excluding", "not included", "scope"]

    static func instructionScore(_ t: String) -> Int { let l = t.lowercased(); return instructionWords.filter { l.contains($0) }.count }

    static func select(_ docs: [(title: String, chunks: [DocumentChunk])], queries: [String], budget: Int) -> (extracts: [PromptInput.Extract], truncated: Set<String>) {
        guard !docs.isEmpty else { return ([], []) }
        let query = queries.joined(separator: " ")
        var chosen: [[DocumentChunk]] = Array(repeating: [], count: docs.count), used = Array(repeating: 0, count: docs.count), full = Array(repeating: 0, count: docs.count)
        func pick(_ i: Int, quota: Int) {
            let chunks = docs[i].chunks; full[i] = chunks.reduce(0) { $0 + $1.text.count }
            var order: [DocumentChunk] = chunks.filter { instructionScore($0.text) >= 2 }.sorted { instructionScore($0.text) > instructionScore($1.text) }.prefix(2).map { $0 }
            order += SourceRetriever.rank(chunks, query: query, limit: 12, perDocument: 12)
            order += SourceRetriever.survey(chunks, limit: 12, perDocument: 12)
            order += chunks
            for c in order where used[i] < quota && !chosen[i].contains(where: { $0.id == c.id }) { chosen[i].append(c); used[i] += min(c.text.count, quota - used[i]) }
        }
        let share = max(1_200, budget / docs.count)
        for i in docs.indices { pick(i, quota: share) }
        // Leftover budget (small documents) goes to documents that were cut.
        var left = budget - docs.indices.reduce(0) { $0 + min(used[$1], share) }
        let cut = docs.indices.filter { full[$0] > used[$0] }
        if left > 0, !cut.isEmpty { for i in cut { pick(i, quota: used[i] + left / cut.count) }; left = 0 }
        var out: [PromptInput.Extract] = [], truncated = Set<String>()
        var remaining = budget
        for i in docs.indices {
            var spent = 0
            for c in chosen[i].sorted(by: { $0.ordinal < $1.ordinal }) {
                let room = min(remaining, max(0, (i < docs.count ? max(share, used[i]) : share) - spent))
                guard room > 0 else { break }
                let text = String(c.text.prefix(room))
                out.append(.init(title: docs[i].title, page: c.pageNumber, text: text)); spent += text.count; remaining -= text.count
                if text.count < c.text.count { truncated.insert(docs[i].title) }
            }
            if spent < full[i] { truncated.insert(docs[i].title) }
        }
        return (out, truncated)
    }
}

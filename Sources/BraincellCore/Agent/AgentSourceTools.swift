import Foundation
import GRDB

/// Retrieval over a course's extracted text. Pure functions so coverage behaviour is unit-tested.
public enum SourceRetriever {
    static let stop: Set<String> = ["the", "and", "for", "with", "that", "this", "from", "are", "was", "were", "you", "your", "how", "what", "why", "when", "which", "about", "into", "use", "using", "any", "can", "will", "not", "all"]
    public static func terms(_ q: String) -> [String] {
        q.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init).filter { $0.count >= 3 && !stop.contains($0) }
    }

    /// Ranks chunks by weighted term frequency (rare terms count more, long chunks aren't favoured), then picks results round-robin across
    /// documents so one long file can't crowd out the rest, and so material far from the start of a document is reachable.
    public static func rank(_ chunks: [DocumentChunk], query: String, limit: Int, perDocument: Int) -> [DocumentChunk] {
        let qt = terms(query)
        guard !qt.isEmpty else { return survey(chunks, limit: limit, perDocument: perDocument) }
        let lowered = chunks.map { $0.text.lowercased() }
        let n = Double(max(1, chunks.count))
        var idf: [String: Double] = [:]
        for t in Set(qt) { let df = Double(lowered.filter { $0.contains(t) }.count); idf[t] = log(1 + n / (1 + df)) }
        var scored: [(DocumentChunk, Double)] = []
        for (i, c) in chunks.enumerated() {
            var s = 0.0
            for t in qt {
                let tf = Double(lowered[i].components(separatedBy: t).count - 1)
                if tf > 0 { s += (1 + log(tf)) * (idf[t] ?? 1) }
            }
            if s > 0 { scored.append((c, s / sqrt(Double(max(200, c.text.count)) / 600))) }
        }
        scored.sort { $0.1 > $1.1 }
        var perDoc: [UUID: Int] = [:], out: [DocumentChunk] = []
        for (c, _) in scored where perDoc[c.documentId, default: 0] < perDocument { out.append(c); perDoc[c.documentId, default: 0] += 1; if out.count == limit { break } }
        return out
    }

    /// No query: evenly spaced chunks from every document (including its later pages), for building a first map of what the material covers.
    public static func survey(_ chunks: [DocumentChunk], limit: Int, perDocument: Int) -> [DocumentChunk] {
        let by = Dictionary(grouping: chunks, by: \.documentId).mapValues { $0.sorted { $0.ordinal < $1.ordinal } }
        let docs = by.keys.sorted { $0.uuidString < $1.uuidString }
        let per = max(1, min(perDocument, limit / max(1, docs.count)))
        var out: [DocumentChunk] = []
        for d in docs {
            let cs = by[d]!, k = min(per, cs.count)
            for j in 0..<k { out.append(cs[k == 1 ? 0 : j * (cs.count - 1) / (k - 1)]) }
        }
        return Array(out.prefix(limit))
    }
}

extension AgentRegistry {
    static let sourceTools: [ToolSpec] = [
        ToolSpec(name: "sources.status", summary: "Report which of a course's materials can actually be read: usable, partly extracted, scanned/unreadable, or not text. Call this first when preparing for an exam.",
                 params: [ToolParam("course", "string", "Course name or id", required: true), ToolParam("assessment", "string", "Assessment (optional): shows which files are mapped to it")], permission: .read, approval: false,
                 describe: { _, _ in "Check course material" }, run: sourceStatus),
        ToolSpec(name: "sources.search", summary: "Find the passages of a course's materials most relevant to a query, across ALL documents (not just their openings). Results carry document and page. With no query it samples every document evenly.",
                 params: [ToolParam("course", "string", "Course name or id", required: true), ToolParam("query", "string", "Topic, concept or question words (optional)"), ToolParam("assessment", "string", "Limit to files mapped to this assessment, when any are"), ToolParam("limit", "integer", "Default 8, max 20")], permission: .read, approval: false,
                 describe: { _, _ in "Search course sources" }, run: sourceSearch),
        ToolSpec(name: "studyMap.create", summary: "Save a source-grounded topic map and problem-structure analysis for an assessment. Every source reference is checked against the real documents; importance must say whether it is the instructor's (quoted evidence required) or your estimate. Research entries are not accepted (no web tool exists). Re-calling with the same title updates it.",
                 params: [ToolParam("course", "string", "Course name or id", required: true), ToolParam("assessment", "string", "Assessment (optional)"), ToolParam("title", "string", "Map title", required: true),
                          ToolParam("topics", "array", "[{name, objectives[], prerequisites[], sources[{document, page}], importance{level: high|medium|low|unknown, source: instructor|estimated|unknown, weightPercent (instructor only), evidence}}]"),
                          ToolParam("structures", "array", "[{source{document,page}, family, objective, givens[], unknowns[], assumptions[], method, prerequisites[], extraStep, commonMistakes[], difficulty 1-5}] for examples you actually read")],
                 permission: .write, approval: false, describe: { a, _ in "Save a study map for \(a.string("course") ?? "")" }, run: createMap),
        ToolSpec(name: "studyMap.get", summary: "Read back the saved topic map for a course.", params: [ToolParam("course", "string", "Course name or id", required: true)], permission: .read, approval: false,
                 describe: { _, _ in "Read the study map" }, run: getMap),
    ]

    // MARK: Status

    static func readableKinds(_ k: DocumentKind) -> Bool { k == .pdf || k == .text || k == .pasted }

    @Sendable static func sourceStatus(_ a: ToolArgs, _ c: AgentContext, _ info: ToolRunInfo) async throws -> ToolOutput {
        let course = try c.course(try a.require("course")); let asm = try c.assessment(a.string("assessment"), in: course)
        let docs = try c.docs.documents(courseId: course.id)
        let mapped: Set<UUID> = try asm.map { x in Set(try c.db.read { try DocumentAssessment.filter(Column("assessmentId") == x.id).fetchAll($0) }.map(\.documentId)) } ?? []
        guard !docs.isEmpty else {
            return ToolOutput(text: "\(course.name) has NO imported materials. Do not guess its content from the course name. Ask the learner to add lecture notes, slides or past papers (text-based PDF, Markdown or pasted text).", summary: "No materials",
                              chips: [ActionChip(label: "Add materials", action: "addFiles", courseId: course.id)])
        }
        var usable = 0, partial = 0, unreadable = 0, notText = 0, lines: [String] = []
        for d in docs {
            let chunks = try c.docs.chunks(documentId: d.id)
            let good = chunks.filter { !$0.isLowContent }.count
            let tag = mapped.contains(d.id) ? " [mapped to \(asm!.name)]" : ""
            let pages = d.pageCount.map { ", \($0) pages" } ?? ""
            switch (readableKinds(d.kind), d.extractionStatus) {
            case (true, .ok): usable += 1; lines.append("- USABLE: \(d.name) [id \(d.id.uuidString)]\(pages), \(good) readable passages\(tag)")
            case (true, .partial): partial += 1; lines.append("- PARTIAL: \(d.name) [id \(d.id.uuidString)]\(pages): \(d.lowContentPageCount) page(s) had little or no text (probably scanned images). Only \(good) passages are readable; the rest is unknown\(tag)")
            case (true, _): unreadable += 1; lines.append("- UNREADABLE: \(d.name) [id \(d.id.uuidString)]: no text could be extracted (probably a scan or protected file). OCR is not available in this build, so its contents are unknown\(tag)")
            default: notText += 1; lines.append("- NOT TEXT: \(d.name) [id \(d.id.uuidString)] (\(d.kind.rawValue)): images and video can’t be read in this build (no OCR or vision path)\(tag)")
            }
        }
        let anyUsable = usable + partial > 0
        var head = "\(course.name): \(docs.count) file(s) — \(usable) usable, \(partial) partly readable, \(unreadable) unreadable, \(notText) not text."
        if let asm { head += mapped.isEmpty ? " No files are mapped to “\(asm.name)”; its scope must come from the learner or the whole course." : " \(mapped.count) file(s) are mapped to “\(asm.name)”." }
        if !anyUsable { head += " NOTHING is readable, so do not describe course content. Tell the learner what is needed (text-based files, or the text pasted in) and offer to add materials." }
        return ToolOutput(text: head + "\n" + lines.joined(separator: "\n"), summary: anyUsable ? "\(usable + partial) readable of \(docs.count)" : "Nothing readable",
                          chips: anyUsable && unreadable + partial + notText == 0 ? [] : [ActionChip(label: "Add materials", action: "addFiles", courseId: course.id)])
    }

    // MARK: Search

    @Sendable static func sourceSearch(_ a: ToolArgs, _ c: AgentContext, _ info: ToolRunInfo) async throws -> ToolOutput {
        let course = try c.course(try a.require("course")); let asm = try c.assessment(a.string("assessment"), in: course)
        var docs = try c.docs.documents(courseId: course.id).filter { readableKinds($0.kind) && $0.extractionStatus != .failed }
        var scope = "all \(docs.count) readable document(s) of the course"
        if let asm {
            let ids = Set(try c.db.read { try DocumentAssessment.filter(Column("assessmentId") == asm.id).fetchAll($0) }.map(\.documentId))
            if !ids.isEmpty { docs = docs.filter { ids.contains($0.id) }; scope = "the \(docs.count) document(s) mapped to “\(asm.name)”" }
        }
        guard !docs.isEmpty else { throw ToolError.unavailable("\(course.name) has no readable material to search. Call sources.status, then ask the learner to add text-based files.") }
        let names = Dictionary(uniqueKeysWithValues: docs.map { ($0.id, $0.name) })
        var all: [DocumentChunk] = [], skipped = 0
        for d in docs { for ch in try c.docs.chunks(documentId: d.id) { if ch.isLowContent { skipped += 1 } else { all.append(ch) } } }
        let limit = min(20, max(1, a.int("limit") ?? 8))
        let query = a.string("query") ?? ""
        let hits = SourceRetriever.rank(all, query: query, limit: limit, perDocument: max(2, (limit + 1) / 2))
        let gaps = try c.docs.documents(courseId: course.id).filter { !readableKinds($0.kind) || $0.extractionStatus == .failed }.map(\.name)
        var out = "Searched \(all.count) readable passage(s) in \(scope)\(skipped > 0 ? "; \(skipped) low-text passage(s) skipped" : ""). "
        out += query.isEmpty ? "No query given, so this is an even sample across documents, not a complete reading." : "Showing the \(hits.count) best match(es) for “\(query)”; other passages exist that were not shown."
        if !gaps.isEmpty { out += "\nCOVERAGE GAP — not readable: " + gaps.joined(separator: ", ") + "." }
        if hits.isEmpty { return ToolOutput(text: out + "\nNo passage matched.", summary: "No matches", untrusted: false) }
        out += "\n" + hits.map { h in "[\(names[h.documentId] ?? "?") · \(h.pageNumber.map { "p.\($0)" } ?? "passage \(h.ordinal + 1)") · doc \(h.documentId.uuidString)]\n\(String(h.text.prefix(900)))" }.joined(separator: "\n\n")
        return ToolOutput(text: out, summary: "\(hits.count) passage(s) from \(Set(hits.map(\.documentId)).count) document(s)", untrusted: true)
    }

    // MARK: Study map

    /// Resolves a model-supplied document reference to a real document of this course and a page that exists. Anything else is rejected, never repaired.
    static func resolveRef(_ raw: Any?, docs: [Document], chunks: (UUID) -> [DocumentChunk]) -> (StudyMapDocument.SourceRef?, String?) {
        guard let o = raw as? [String: Any], let ref = (o["document"] as? String) ?? (o["documentId"] as? String) else { return (nil, "a source needs a document") }
        let n = AgentContext.norm(ref)
        let exactId = docs.first { $0.id.uuidString.lowercased() == ref.lowercased() }
        let matches = docs.filter { AgentContext.norm($0.name) == n || AgentContext.norm($0.title) == n }
        guard let d = exactId ?? (matches.count == 1 ? matches.first : nil) else { return (nil, "“\(ref)” is unavailable or ambiguous among the selected documents") }
        let page = (o["page"] as? Int) ?? (o["page"] as? Double).map(Int.init) ?? (o["page"] as? String).flatMap(Int.init)
        if let page {
            let ok = (d.pageCount.map { (1...max(1, $0)).contains(page) } ?? false) || chunks(d.id).contains { $0.pageNumber == page && !$0.isLowContent }
            guard ok else { return (nil, "page \(page) doesn’t exist in “\(d.name)”") }
            if !chunks(d.id).contains(where: { $0.pageNumber == page && !$0.isLowContent }) && d.kind == .pdf { return (nil, "page \(page) of “\(d.name)” has no readable text, so it can’t be cited") }
        }
        return (.init(documentId: d.id, documentName: d.name, page: page), nil)
    }

    static func squash(_ s: String) -> String { s.lowercased().split { !$0.isLetter && !$0.isNumber }.joined(separator: " ") }

    @Sendable static func createMap(_ a: ToolArgs, _ c: AgentContext, _ info: ToolRunInfo) async throws -> ToolOutput {
        let course = try c.course(try a.require("course")); let asm = try c.assessment(a.string("assessment"), in: course)
        let title = try a.require("title")
        let ids = a.strings("documentIds").compactMap(UUID.init(uuidString:))
        let docs = try ids.isEmpty ? c.docs.documents(courseId: course.id) : StudyPrep.selectedDocuments(ids, c)
        guard docs.contains(where: { readableKinds($0.kind) && $0.extractionStatus != .failed }) else {
            throw ToolError.unavailable("\(course.name) has no readable material, so a source-grounded map can’t be built. Ask the learner to add text-based files first.")
        }
        var cache: [UUID: [DocumentChunk]] = [:]
        func chunks(_ id: UUID) -> [DocumentChunk] { if let x = cache[id] { return x }; let v = (try? c.docs.chunks(documentId: id)) ?? []; cache[id] = v; return v }
        var warnings: [String] = []
        var topics: [StudyMapDocument.Topic] = []
        for (i, t) in a.objects("topics").prefix(40).enumerated() {
            guard let name = (t["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty else { warnings.append("Topic \(i + 1) had no name and was dropped."); continue }
            var refs: [StudyMapDocument.SourceRef] = []
            for r in (t["sources"] as? [Any]) ?? [] { let (ref, why) = resolveRef(r, docs: docs, chunks: chunks); if let ref { refs.append(ref) } else if let why { warnings.append("“\(name)”: dropped a source (\(why)).") } }
            if refs.isEmpty { warnings.append("“\(name)” has no verifiable source, so it is marked unsourced; treat it as unconfirmed coverage.") }
            let imp = t["importance"] as? [String: Any] ?? [:]
            var level = ((imp["level"] as? String) ?? "unknown").lowercased(); if !["high", "medium", "low", "unknown"].contains(level) { level = "unknown" }
            var src = StudyMapDocument.Importance.Source(rawValue: ((imp["source"] as? String) ?? "unknown").lowercased()) ?? .unknown
            var weight = (imp["weightPercent"] as? Double) ?? (imp["weightPercent"] as? Int).map(Double.init)
            let evidence = ((imp["evidence"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if src == .instructor {
                // An instructor weight must quote text that really appears in the cited documents; otherwise it is only an estimate.
                let hay = (refs.isEmpty ? docs.map(\.id) : refs.map(\.documentId)).flatMap { chunks($0) }.map { squash($0.text) }.joined(separator: " ")
                let q = squash(evidence)
                if q.count < 12 || !hay.contains(q) { src = .estimated; weight = nil; warnings.append("“\(name)”: the quoted instructor guidance wasn’t found in the cited material, so the importance is recorded as an estimate.") }
            }
            if src == .estimated, weight != nil { weight = nil; warnings.append("“\(name)”: an estimate can’t carry a percentage; it was removed.") }
            if src == .unknown { level = "unknown"; weight = nil }
            if let w = weight, !(0...100).contains(w) { weight = nil; warnings.append("“\(name)”: weight outside 0–100% was removed.") }
            if src == .estimated, evidence.isEmpty { level = "unknown"; src = .unknown; warnings.append("“\(name)”: no evidence for the estimate, so importance is unknown.") }
            topics.append(.init(name: name, objectives: Array(strings(t["objectives"]).prefix(8)), prerequisites: Array(strings(t["prerequisites"]).prefix(8)), sources: refs,
                                importance: .init(level: level, source: src, weightPercent: weight, evidence: String(evidence.prefix(400))),
                                parent: (t["parent"] as? String).flatMap { $0.isEmpty || $0 == name ? nil : $0 }))
        }
        var structures: [StudyMapDocument.Structure] = []
        for (i, s) in a.objects("structures").prefix(30).enumerated() {
            let (ref, why) = resolveRef(s["source"], docs: docs, chunks: chunks)
            guard let ref else { warnings.append("Problem analysis \(i + 1) was dropped (\(why ?? "no valid source")); analyses are only kept for examples that exist."); continue }
            let extra = ((s["extraStep"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines), family = ((s["family"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !extra.isEmpty, !family.isEmpty else { warnings.append("Problem analysis \(i + 1) needs a problem family and the distinguishing extra step; it was dropped."); continue }
            structures.append(.init(source: ref, family: family, objective: (s["objective"] as? String) ?? "", givens: strings(s["givens"]), unknowns: strings(s["unknowns"]), assumptions: strings(s["assumptions"]),
                                    method: (s["method"] as? String) ?? "", prerequisites: strings(s["prerequisites"]), extraStep: extra, commonMistakes: strings(s["commonMistakes"]),
                                    difficulty: min(5, max(1, (s["difficulty"] as? Int) ?? 3))))
        }
        guard !topics.isEmpty || !structures.isEmpty else { throw ToolError.invalid("Nothing valid to save. " + warnings.joined(separator: " ")) }
        let a2 = a.raw["research"] != nil
        let gaps = docs.filter { !readableKinds($0.kind) || $0.extractionStatus == .failed || $0.extractionStatus == .partial }.map { "\($0.name) (\($0.extractionStatus == .partial ? "partly readable" : "not readable"))" }
        let doc = StudyMapDocument(courseName: course.name, assessmentName: asm?.name, topics: topics, structures: structures,
                                   research: .init(status: "unavailable", note: a2 ? "Research entries were rejected: this build has no web search or fetch tool, so no external sources were consulted." : "No web search or fetch tool exists in this build, so no external research was done. Scope comes from the course material only."),
                                   warnings: warnings, coverageGaps: gaps)
        let now = c.now()
        // Native workspaces use a stable operation ID without creating an empty chat.
        let conversationId = try c.store.conversation(info.conversationId)?.id
        let rec = StudyMapRecord(id: UUID(), conversationId: conversationId, courseId: course.id, assessmentId: asm?.id, title: title, mapJSON: String(data: try JSONEncoder().encode(doc), encoding: .utf8) ?? "{}", createdAt: now, updatedAt: now)
        try c.store.saveMap(rec)
        let saved = try c.store.maps(courseId: course.id, conversationId: conversationId).first { $0.title == title && $0.conversationId == conversationId } ?? rec
        let unsourced = topics.filter { !$0.sourced }.count, inst = topics.filter { $0.importance.source == .instructor }.count, est = topics.filter { $0.importance.source == .estimated }.count
        var text: String = "Saved study map “\(title)”: \(topics.count) topic(s) (\(inst) with instructor-stated importance, \(est) AI-estimated, \(topics.count - inst - est) unknown"
        if unsourced > 0 { text += ", \(unsourced) unsourced" }
        text += ") and \(structures.count) analysed example problem(s). Research: unavailable (no web tool)."
        if !warnings.isEmpty { text += "\nChecks that changed your input:\n- " + warnings.joined(separator: "\n- ") }
        if !gaps.isEmpty { text += "\nCoverage gaps: " + gaps.joined(separator: ", ") + "." }
        return ToolOutput(text: text, summary: "\(topics.count) topics, \(structures.count) examples", mapId: saved.id)
    }

    @Sendable static func getMap(_ a: ToolArgs, _ c: AgentContext, _ info: ToolRunInfo) async throws -> ToolOutput {
        let course = try c.course(try a.require("course"))
        guard let rec = try c.store.maps(courseId: course.id, conversationId: info.conversationId).first ?? c.store.maps(courseId: course.id).first, let d = rec.document else {
            return ToolOutput(text: "No study map exists for \(course.name) yet.", summary: "No map")
        }
        return ToolOutput(text: "Study map “\(rec.title)”:\n" + mapSummary(d), summary: "\(d.topics.count) topics", mapId: rec.id)
    }

    static func strings(_ v: Any?) -> [String] { ((v as? [Any]) ?? []).compactMap { ($0 as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty } }

    /// Compact text used when the model reads a map back and when generation is steered by it.
    public static func mapSummary(_ d: StudyMapDocument) -> String {
        var s: String = d.topics.map { t -> String in
            let imp = t.importance.source == .instructor ? "instructor: \(t.importance.level)\(t.importance.weightPercent.map { " \(Int($0))%" } ?? "")" : t.importance.source == .estimated ? "AI estimate: \(t.importance.level)" : "importance unknown"
            return "- \(t.name) [\(imp)]\(t.sourced ? "" : " [UNSOURCED]")" + (t.sources.isEmpty ? "" : " sources: " + t.sources.map { "\($0.documentName)\($0.page.map { " p.\($0)" } ?? "")" }.joined(separator: "; "))
        }.joined(separator: "\n")
        if !d.structures.isEmpty { s += "\nProblem structures:\n" + d.structures.map { "- \($0.family) (\($0.source.documentName)\($0.source.page.map { " p.\($0)" } ?? "")): method \($0.method); extra step: \($0.extraStep)" }.joined(separator: "\n") }
        return s
    }
}

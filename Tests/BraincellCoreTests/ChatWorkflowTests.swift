import Testing
import Foundation
import GRDB
@testable import BraincellCore

/// Chat persistence, role-based requests, titles, edit/regenerate, recovery, and the source-grounded exam workflow.
/// The model is scripted; everything after it (tools, validation, database, import) is the real code. No network.
extension AgentTests {
    final class Events: @unchecked Sendable { private let l = NSLock(); private var a: [String] = []; func add(_ s: String) { l.withLock { a.append(s) } }; var all: [String] { l.withLock { a } } }

    func ask(_ e: E, _ text: String) async { await e.runner.send(e.conv, text: text) }
    /// Inserts a document row directly, for states a text import can't produce (scans, failed extraction).
    func insertDoc(_ e: E, _ course: Course, name: String, kind: DocumentKind = .pdf, status: ExtractionStatus, pages: Int? = nil, low: Int = 0) throws -> Document {
        let d = Document(id: UUID(), courseId: course.id, folderId: nil, title: name, originalFilename: name, name: name, storedPath: "x/\(name)", sha256: UUID().uuidString, byteCount: 10, kind: kind, pageCount: pages, extractionStatus: status, extractionMethod: "test", lowContentPageCount: low, importedAt: Date(), modifiedAt: Date(), favorite: false, deletedAt: nil, purgeAfter: nil, deletedWith: nil)
        try e.db.write { try d.insert($0) }; return d
    }
    func insertChunk(_ e: E, _ d: Document, _ i: Int, page: Int?, _ text: String, low: Bool = false) throws {
        try e.db.write { try DocumentChunk(id: UUID(), documentId: d.id, ordinal: i, pageNumber: page, text: text, isLowContent: low).insert($0) }
    }

    // MARK: Persistence and role-based requests

    @Test func threeTurnsStayInOneConversationWithOrderedRolesAndSeparateInstructions() async throws {
        let dir = try tempDir(); let url = dir.appendingPathComponent("c.sqlite")
        var conv = UUID()
        do {
            let e = try await env(dbURL: url) { _, _, n in "reply \(n)" }
            conv = e.conv
            for t in ["first question", "second question", "third question"] { await ask(e, t) }
            let roles = e.script.roles.value
            #expect(roles.count == 3)
            #expect(roles[0] == ["system", "user"])
            #expect(roles[2] == ["system", "user", "assistant", "user", "assistant", "user"])       // ordered history, strictly alternating
            #expect(!e.script.prompts[2].user.contains("RULES"))                                     // instructions live only in the system message
            #expect(e.script.prompts[2].system.contains("RULES"))
        }
        let store = AgentStore(db: try AppDatabase.open(at: url))                                    // relaunch
        let m = try store.messages(conv)
        #expect(m.filter { $0.role == .user }.map(\.content) == ["first question", "second question", "third question"])
        #expect(try m.filter { $0.role == .assistant }.count == 3 && (try store.conversations().count) == 1)   // one history entry, not one per message
    }

    @Test func toolCallsAndResultsKeepTheAssistantAndUserRolesAlternating() async throws {
        let e = try await env { _, _, n in n == 1 ? self.call("courses.list", [:]) : "Done." }
        await ask(e, "what courses do I have?")
        #expect(e.script.roles.value[1] == ["system", "user", "assistant", "user"])                   // user, tool call (assistant), tool result (user)
    }

    @Test func wireMessagesMergeAdjacentRolesAndNeverStartWithTheAssistant() {
        var req = LLMRequest(prompt: ""); req.messages = [LLMMessage(.assistant, "orphan"), LLMMessage(.user, "a"), LLMMessage(.user, "b"), LLMMessage(.assistant, "c")]
        let w = ProviderClient.wireMessages(req)
        #expect(w.map { $0["role"]! } == ["user", "assistant", "user", "assistant"])
        #expect(w[2]["content"] == "a\n\nb")
        #expect(ProviderClient.wireMessages(LLMRequest(prompt: "single")) == [["role": "user", "content": "single"]])    // existing callers unchanged
    }

    @Test func separateChatsNeverShareMessagesOrScope() async throws {
        let e = try await env { _, _, _ in "ok" }
        let a = try e.ctx.courses.createCourse(name: "AAA101"), b = try e.ctx.courses.createCourse(name: "BBB202")
        let other = try e.store.createConversation(courseId: b.id); try e.store.setCourse(e.conv, a.id)
        await ask(e, "secret-alpha question")
        await e.runner.send(other.id, text: "beta question")
        #expect(!e.script.prompts[1].user.contains("secret-alpha") && e.script.prompts[1].system.contains("BBB202") && !e.script.prompts[1].system.contains("selected the course “AAA101”"))
        #expect(try e.store.conversation(e.conv)?.courseId == a.id && (try e.store.conversation(other.id))?.courseId == b.id)
    }

    // MARK: Titles

    @Test func goalTitleReplacesNewChatAndFallbackIsDeterministic() {
        #expect(AgentRunner.fallbackTitle(from: "Help me prepare for my STAT435 midterm") == "STAT435 Midterm Preparation")
        #expect(AgentRunner.fallbackTitle(from: "can you explain eigenvalues to me please") == "Explain Eigenvalues")
        #expect(AgentRunner.fallbackTitle(from: "???") == "New chat")
        #expect(AgentRunner.cleanTitle("\"STAT435 Midterm Prep\"", prompt: "x") == "STAT435 Midterm Prep")
        #expect(AgentRunner.cleanTitle("this is a very long title that clearly rambles on and on past any limit", prompt: "x") == nil)
        #expect(AgentRunner.cleanTitle("Help me prepare", prompt: "help me prepare") == nil)                    // never just the prompt
    }

    @Test func modelTitleAppliesOnceAndNeverOverwritesARename() async throws {
        let e = try await env { sys, _, _ in sys.contains("concise title") ? "STAT435 Midterm Prep" : "Sure." }
        e.runner.generatesTitles = true
        await ask(e, "Help me prepare for my STAT435 midterm")
        #expect(try e.store.conversation(e.conv)?.title == "STAT435 Midterm Preparation")           // immediate fallback, before any model title
        await e.runner.generateTitle(e.conv)
        #expect(try e.store.conversation(e.conv)?.title == "STAT435 Midterm Prep")
        let titleCalls = { e.script.prompts.filter { $0.system.contains("concise title") }.count }
        await e.runner.generateTitle(e.conv); await ask(e, "another turn")
        try await Task.sleep(nanoseconds: 300_000_000)
        #expect(titleCalls() == 1, "a title is generated once, not on every turn")
        let e2 = try await env { sys, _, _ in sys.contains("concise title") ? "Model Title" : "Sure." }
        await e2.runner.send(e2.conv, text: "plan my week")
        try e2.store.rename(e2.conv, to: "My own name")
        await e2.runner.generateTitle(e2.conv); await e2.runner.send(e2.conv, text: "more")
        #expect(try e2.store.conversation(e2.conv)?.title == "My own name")
    }

    @Test func aFailedTitleRequestKeepsTheFallbackAndNeverBlocksTheReply() async throws {
        let e = try await env { sys, _, _ in sys.contains("concise title") ? "" : "Here is your answer." }       // empty body → malformed
        e.runner.generatesTitles = true
        await ask(e, "Help me prepare for my STAT435 midterm")
        await e.runner.generateTitle(e.conv)
        #expect(try e.store.conversation(e.conv)?.title == "STAT435 Midterm Preparation")
        #expect(try msgs(e).last?.content == "Here is your answer.")
    }

    // MARK: Search, edit, regenerate

    @Test func searchFindsByTitleAndMessageTextAndIgnoresArchivedMessages() async throws {
        let e = try await env { _, _, _ in "Use the chain rule for that." }
        await ask(e, "derivative of a composite function")
        let other = try e.store.createConversation(title: "Unrelated trip planning")
        _ = try e.store.append(other.id, role: .user, "flights to Lisbon")
        #expect(try e.store.search("chain rule").map(\.id) == [e.conv])
        #expect(try e.store.search("lisbon").map(\.id) == [other.id] && (try e.store.search("trip")).map(\.id) == [other.id])
        let first = try #require(try msgs(e).first { $0.role == .user })
        _ = try e.store.edit(first.id, newText: "integral of a rational function")
        #expect(try e.store.search("chain").isEmpty && (try e.store.search("rational")).map(\.id) == [e.conv])      // the archived reply no longer matches
        #expect(try e.store.search("").count == 2)
    }

    @Test func editingArchivesTheOldBranchSendsOnlyCurrentContextAndIsRecoverable() async throws {
        let e = try await env { _, user, n in user.contains("OLD-REPLY") ? "leak" : (n == 1 ? "OLD-REPLY" : "NEW-REPLY") }
        await ask(e, "original question"); await ask(e, "follow up")
        let first = try #require(try msgs(e).first { $0.role == .user })
        await e.runner.edit(first.id, text: "edited question")
        let last = e.script.prompts.last!
        #expect(last.user.contains("edited question") && !last.user.contains("original question") && !last.user.contains("OLD-REPLY") && !last.user.contains("follow up"))
        let visible = try msgs(e)
        #expect(visible.filter { $0.role == .user }.map(\.content) == ["edited question"])
        let all = try e.store.messages(e.conv, includeSuperseded: true)
        #expect(all.filter { $0.role == .user }.count == 3)                                          // nothing was deleted
        let edited = try #require(visible.first { $0.role == .user })
        #expect(try edited.editedFrom == first.id && (try e.store.replacedCount(by: edited.id)) >= 3)
        try e.store.restoreEdit(edited.id)                                                           // recover the earlier version
        #expect(try msgs(e).filter { $0.role == .user }.map(\.content) == ["original question", "follow up"])
    }

    @Test func editingDeclinesApprovalsThatBelongedToTheReplacedBranch() async throws {
        let e = try await env { _, _, n in n == 1 ? self.call("courses.create", ["name": "Ghost"]) : "ok" }
        await ask(e, "create a course Ghost")
        let pending = try #require(try pendingApproval(e))
        let first = try #require(try msgs(e).first { $0.role == .user })
        _ = try e.store.edit(first.id, newText: "never mind")
        #expect(try e.store.action(pending.id)?.status == .declined)
        await e.runner.approve(pending.id)                                                           // a stale approval can't run
        #expect(try e.ctx.courses.courses().isEmpty)
    }

    @Test func regenerateReplacesTheReplyWithoutDuplicatingTheUserMessage() async throws {
        let e = try await env { _, _, n in "answer \(n)" }
        await ask(e, "explain recursion")
        await e.runner.regenerate(e.conv)
        let m = try msgs(e)
        #expect(m.filter { $0.role == .user }.count == 1 && m.filter { $0.role == .assistant }.map(\.content) == ["answer 2"])
        #expect(try e.store.messages(e.conv, includeSuperseded: true).filter { $0.role == .assistant }.count == 2)   // the first reply is kept for recovery
        #expect(e.script.roles.value.last == ["system", "user"])
    }

    @Test func retryAfterAFailureDoesNotDuplicateTheUserMessageOrSavedQuestions() async throws {
        let e = try await env { _, _, n in n == 1 ? "" : "Recovered." }                                // first reply is malformed → error row
        await ask(e, "hello")
        #expect(try msgs(e).last?.kind == .error)
        await e.runner.retry(e.conv)
        let m = try msgs(e)
        #expect(m.filter { $0.role == .user }.count == 1 && m.last?.content == "Recovered." && !m.contains { $0.kind == .error })
    }

    // MARK: Recovery and stages

    @Test func relaunchReportsInterruptedWorkHonestly() async throws {
        let e = try await env { _, _, _ in "ok" }
        let stuck = try e.store.record(e.conv, key: "k", tool: "questions.generate", args: "{}", status: .running)
        let noReply = try e.store.createConversation(); _ = try e.store.append(noReply.id, role: .user, "is anyone there")
        let touched = try e.store.recoverInterrupted()
        #expect(Set(touched) == [e.conv, noReply.id])
        #expect(try e.store.action(stuck.id)?.status == .failed)
        #expect(try msgs(e).last?.kind == .error && (try msgs(e)).last!.content.contains("interrupted"))
        #expect(try e.store.messages(noReply.id).last?.kind == .error)
        #expect(try e.store.recoverInterrupted().isEmpty)                                            // idempotent: no second notice
    }

    @Test func workflowStagesAreReportedFromRealToolCalls() async throws {
        let e = try await env { _, _, n in n == 1 ? self.call("courses.list", [:]) : "Done." }
        let ev = Events()
        await e.runner.send(e.conv, text: "list my courses") { if case .stage(let s) = $0, let s { ev.add(s) } }
        #expect(ev.all == ["Waiting for the model", "Checking course material", "Waiting for the model"])
    }

    // MARK: Sources: status, retrieval, honesty

    @Test func sourceStatusDistinguishesUsablePartialScannedAndNonText() async throws {
        let e = try await env { _, _, _ in "ok" }
        let c = try e.ctx.courses.createCourse(name: "STAT435")
        let good = try insertDoc(e, c, name: "notes.pdf", status: .ok, pages: 10); try insertChunk(e, good, 0, page: 1, "real text")
        let part = try insertDoc(e, c, name: "mixed.pdf", status: .partial, pages: 8, low: 5); try insertChunk(e, part, 0, page: 1, "some text")
        _ = try insertDoc(e, c, name: "scan.pdf", status: .failed, pages: 6)
        _ = try insertDoc(e, c, name: "board.png", kind: .image, status: .notApplicable)
        let out = try await AgentRegistry.sourceStatus(ToolArgs(["course": "STAT435"]), e.ctx, ToolRunInfo(conversationId: e.conv, actionId: UUID()))
        #expect(out.text.contains("USABLE: notes.pdf") && out.text.contains("PARTIAL: mixed.pdf") && out.text.contains("UNREADABLE: scan.pdf") && out.text.contains("NOT TEXT: board.png"))
        #expect(out.text.contains("OCR is not available") && out.chips.contains { $0.action == "addFiles" })
    }

    @Test func missingMaterialAsksForImportInsteadOfInventingContent() async throws {
        let e = try await env { _, _, n in n == 1 ? self.call("sources.status", ["course": "STAT435"]) : "I can’t see any material yet. Please add your notes." }
        _ = try e.ctx.courses.createCourse(name: "STAT435")
        await ask(e, "Help me prepare for my STAT435 midterm")
        let t = try #require(try toolMessages(e).first)
        #expect(t.content.contains("NO imported materials") && t.content.contains("Do not guess"))
        #expect(try msgs(e).contains { $0.kind == .actions && ($0.payload ?? "").contains("addFiles") })
        await #expect(throws: ToolError.self) { _ = try await AgentRegistry.createMap(ToolArgs(["course": "STAT435", "title": "t", "topics": [["name": "x"]]]), e.ctx, ToolRunInfo(conversationId: e.conv, actionId: UUID())) }
    }

    @Test func retrievalFindsRelevantContentDeepInALargeDocumentAcrossFiles() async throws {
        let e = try await env { _, _, _ in "ok" }
        let c = try e.ctx.courses.createCourse(name: "STAT435")
        let big = try insertDoc(e, c, name: "textbook.pdf", status: .ok, pages: 300)
        for i in 0..<120 { try insertChunk(e, big, i, page: i + 1, "Chapter filler paragraph about general introduction and history number \(i). " + String(repeating: "lorem ipsum dolor sit amet ", count: 20)) }
        try insertChunk(e, big, 120, page: 301, "Maximum likelihood estimation: the likelihood function, score equations and Fisher information for the exponential family.")
        let slides = try insertDoc(e, c, name: "slides.pdf", status: .ok, pages: 12)
        for i in 0..<12 { try insertChunk(e, slides, i, page: i + 1, i == 11 ? "Slide 12 exam tips: bootstrap confidence intervals." : "Slide \(i + 1): sampling distributions of the mean.") }
        let out = try await AgentRegistry.sourceSearch(ToolArgs(["course": "STAT435", "query": "likelihood Fisher information", "limit": 5]), e.ctx, ToolRunInfo(conversationId: e.conv, actionId: UUID()))
        #expect(out.text.contains("textbook.pdf · p.301") && out.untrusted)
        #expect(out.text.contains("Searched 133 readable passage(s)"))
        let survey = try await AgentRegistry.sourceSearch(ToolArgs(["course": "STAT435", "limit": 6]), e.ctx, ToolRunInfo(conversationId: e.conv, actionId: UUID()))
        #expect(survey.text.contains("even sample") && survey.text.contains("p.301") || survey.text.contains("p.12"))            // later pages are sampled, not just openings
        #expect(survey.text.contains("textbook.pdf") && survey.text.contains("slides.pdf"))
    }

    @Test func retrievalRankingSpreadsAcrossDocumentsAndSkipsNothingSilently() {
        let d1 = UUID(), d2 = UUID()
        let cs = (0..<6).map { DocumentChunk(id: UUID(), documentId: d1, ordinal: $0, pageNumber: $0 + 1, text: "gradient descent convergence rate \($0)", isLowContent: false) }
            + [DocumentChunk(id: UUID(), documentId: d2, ordinal: 0, pageNumber: 1, text: "gradient descent step size", isLowContent: false)]
        let r = SourceRetriever.rank(cs, query: "gradient descent", limit: 4, perDocument: 2)
        #expect(r.count == 3 && r.filter { $0.documentId == d1 }.count == 2 && r.contains { $0.documentId == d2 })
        #expect(SourceRetriever.rank(cs, query: "zzzz", limit: 4, perDocument: 2).isEmpty)
    }

    @Test func scannedDocumentsContributeNoFabricatedContent() async throws {
        let e = try await env { _, _, _ in "ok" }
        let c = try e.ctx.courses.createCourse(name: "STAT435")
        _ = try insertDoc(e, c, name: "scan.pdf", status: .failed, pages: 6)
        await #expect(throws: ToolError.self) { _ = try await AgentRegistry.sourceSearch(ToolArgs(["course": "STAT435", "query": "anything"]), e.ctx, ToolRunInfo(conversationId: e.conv, actionId: UUID())) }
    }

    // MARK: Study map

    func mapEnv() async throws -> (E, Course, Document) {
        let e = try await env { _, _, _ in "ok" }
        let c = try e.ctx.courses.createCourse(name: "STAT435")
        let d = try insertDoc(e, c, name: "outline.pdf", status: .ok, pages: 5)
        try insertChunk(e, d, 0, page: 1, "The midterm covers Chapters 1 to 3. Chapter 2 is worth 40% of the exam grade.")
        try insertChunk(e, d, 1, page: 2, "Worked example: show that the estimator is unbiased, but first check that the sample is independent.")
        return (e, c, d)
    }
    func runMap(_ e: E, _ args: [String: Any]) async throws -> ToolOutput { try await AgentRegistry.createMap(ToolArgs(args), e.ctx, ToolRunInfo(conversationId: e.conv, actionId: UUID())) }

    @Test func studyMapKeepsOnlyVerifiableSourcesAndSeparatesInstructorWeightFromEstimates() async throws {
        let (e, c, _) = try await mapEnv()
        let out = try await runMap(e, ["course": "STAT435", "title": "Midterm map", "topics": [
            ["name": "Chapter 2 estimation", "objectives": ["Derive MLEs"], "prerequisites": ["Calculus"], "sources": [["document": "outline.pdf", "page": 1]],
             "importance": ["level": "high", "source": "instructor", "weightPercent": 40, "evidence": "Chapter 2 is worth 40% of the exam grade"]],
            ["name": "Bootstrap", "sources": [["document": "outline.pdf", "page": 2], ["document": "made-up.pdf", "page": 1], ["document": "outline.pdf", "page": 99]],
             "importance": ["level": "medium", "source": "estimated", "weightPercent": 15, "evidence": "Appears in two examples"]],
            ["name": "Invented weight", "sources": [["document": "outline.pdf", "page": 1]], "importance": ["level": "high", "source": "instructor", "weightPercent": 70, "evidence": "The professor said this is 70 percent of everything"]],
            ["name": "Nothing cited", "importance": ["level": "high", "source": "estimated"]],
        ]])
        let d = try #require(try e.store.maps(courseId: c.id).first?.document)
        let by = Dictionary(uniqueKeysWithValues: d.topics.map { ($0.name, $0) })
        #expect(by["Chapter 2 estimation"]?.importance.source == .instructor && by["Chapter 2 estimation"]?.importance.weightPercent == 40)
        #expect(by["Bootstrap"]?.importance.source == .estimated && by["Bootstrap"]?.importance.weightPercent == nil)       // estimates never carry a percentage
        #expect(by["Bootstrap"]?.sources.count == 1)                                                                          // fabricated document and nonexistent page dropped
        #expect(by["Invented weight"]?.importance.source == .estimated && by["Invented weight"]?.importance.weightPercent == nil)   // quote not found in the source → downgraded
        #expect(by["Nothing cited"]?.sourced == false && by["Nothing cited"]?.importance.source == .unknown && by["Nothing cited"]?.importance.level == "unknown")
        #expect(out.text.contains("1 with instructor-stated") && out.text.contains("unsourced") && out.mapId != nil)
        #expect(d.research.status == "unavailable")
    }

    @Test func problemAnalysesAreKeptOnlyForRealExamplesWithAnExtraStep() async throws {
        let (e, c, _) = try await mapEnv()
        _ = try await runMap(e, ["course": "STAT435", "title": "m", "structures": [
            ["source": ["document": "outline.pdf", "page": 2], "family": "Unbiasedness proof", "objective": "Prove E[θ̂]=θ", "givens": ["iid sample"], "unknowns": ["E[θ̂]"], "method": "linearity of expectation",
             "extraStep": "Check independence before factoring the expectation", "commonMistakes": ["assuming independence"], "difficulty": 3],
            ["source": ["document": "ghost.pdf", "page": 1], "family": "Imaginary", "extraStep": "none really"],
            ["source": ["document": "outline.pdf", "page": 2], "family": "No extra step"],
        ]])
        let d = try #require(try e.store.maps(courseId: c.id).first?.document)
        #expect(d.structures.count == 1 && d.structures[0].extraStep.contains("independence") && d.warnings.count == 2)
    }

    @Test func researchEntriesAreRejectedBecauseNoWebToolExists() async throws {
        let (e, c, _) = try await mapEnv()
        let out = try await runMap(e, ["course": "STAT435", "title": "m", "topics": [["name": "T", "sources": [["document": "outline.pdf", "page": 1]]]], "research": [["url": "https://example.com/fake", "title": "Fake"]]])
        let d = try #require(try e.store.maps(courseId: c.id).first?.document)
        #expect(try d.research.status == "unavailable" && d.research.note.contains("rejected") && !(try e.store.maps(courseId: c.id).first!.mapJSON.contains("example.com")))
        #expect(out.text.contains("Research: unavailable"))
    }

    @Test func savingTheSameMapTwiceUpdatesInsteadOfDuplicating() async throws {
        let (e, c, _) = try await mapEnv()
        let a: [String: Any] = ["course": "STAT435", "title": "Midterm map", "topics": [["name": "T1", "sources": [["document": "outline.pdf", "page": 1]]]]]
        _ = try await runMap(e, a); _ = try await runMap(e, a)
        var b = a; b["topics"] = [["name": "T1", "sources": [["document": "outline.pdf", "page": 1]]], ["name": "T2", "sources": [["document": "outline.pdf", "page": 2]]]]
        _ = try await runMap(e, b)
        let maps = try e.store.maps(courseId: c.id)
        #expect(maps.count == 1 && maps[0].document?.topics.count == 2)
    }

    @Test func generationIsSteeredByTheMapAndSaysAnswersAreNotVerified() async throws {
        let (e0, _, _) = try await mapEnv()
        let e = try await env { _, user, n in
            if user.contains("req-") { return Fx.envelope(self.requestId(user), Array(Fx.all.prefix(2))) }
            return n == 1 ? self.call("questions.generate", ["course": "STAT435", "count": 2]) : "Preview ready."
        }
        _ = e0
        let c = try e.ctx.courses.createCourse(name: "STAT435")
        let d = try insertDoc(e, c, name: "outline.pdf", status: .ok, pages: 5)
        try insertChunk(e, d, 0, page: 2, "Worked example: show that the estimator is unbiased, but first check that the sample is independent.")
        _ = try e.ctx.docs.importFile(at: try note(e, "t.txt", "Estimators and bias in detail for the midterm exam."), courseId: c.id)
        _ = try await AgentRegistry.createMap(ToolArgs(["course": "STAT435", "title": "m", "structures": [["source": ["document": "outline.pdf", "page": 2], "family": "Unbiasedness proof", "objective": "prove unbiasedness", "method": "linearity", "extraStep": "CHECK-INDEPENDENCE-FIRST"]]]), e.ctx, ToolRunInfo(conversationId: e.conv, actionId: UUID()))
        let ev = Events()
        await e.runner.send(e.conv, text: "make practice for STAT435") { if case .stage(let s) = $0, let s { ev.add(s) } }
        let a = try #require(try pendingApproval(e))
        await e.runner.approve(a.id) { if case .stage(let s) = $0, let s { ev.add(s) } }
        #expect(e.script.allText.contains("CHECK-INDEPENDENCE-FIRST") && e.script.allText.contains("distinguishing extra step"))
        #expect(try toolMessages(e).contains { $0.content.contains("NOT independently verified") })
        #expect(ev.all.contains("Generating practice") && ev.all.contains("Validating results") && ev.all.firstIndex(of: "Generating practice")! < ev.all.firstIndex(of: "Validating results")!)
    }

    // MARK: Migration

    @Test func newChatColumnsDefaultSafelyAndOldRowsKeepWorking() throws {
        let db = try AppDatabase.inMemory(); let s = AgentStore(db: db)
        let conv = try s.createConversation()
        #expect(try s.conversation(conv.id)?.titleLocked == false && (try s.conversation(conv.id))?.titleGenerated == false)
        let m = try s.append(conv.id, role: .user, "hi")
        #expect(try s.messages(conv.id).first?.id == m.id && m.supersededAt == nil)
        try s.delete(conv.id)
        #expect(try s.messages(conv.id, includeSuperseded: true).isEmpty)                            // delete removes the chat and its archived messages only
    }
}

import Foundation

public struct ExportFile: Sendable, Equatable {
    public var name: String
    public var content: String
}

/// What a request will disclose. Shown to the user before anything is copied or exported.
public struct RequestManifest: Codable, Sendable, Equatable {
    public struct DocumentEntry: Codable, Sendable, Equatable {
        public var title: String
        public var characters: Int
        public var truncated: Bool
    }
    public var requestId: String
    public var schemaVersion: String
    public var kind: BatchKind
    public var course: String
    public var assessment: String?
    public var expectedCount: Int
    public var questionTypes: [String]
    public var difficulty: String
    public var skills: [String]
    public var documents: [DocumentEntry]
    public var existingQuestionTitles: Int
    public var repairEntries: Int
    public var includesUserNotes: Bool
    /// Grading requests: how many of the learner's own answers are included.
    public var includedResponses: Int? = nil
    public var characterCount: Int
    public var recommendedTransfer: TransferMethod
    /// Generation planning: the mode, how many planned slots this request covers, and the local list of weaker topic names (names only).
    public var mode: String? = nil
    public var blueprintSlots: Int? = nil
    public var weakTopicTargets: [String]? = nil
    public var excludedTopics: [String]? = nil
    /// Fixed statements about what is *not* shared.
    public var excluded: [String]

    /// Disclosure when weak-topic names are included: still no attempts, answers or scores, but the topic names are derived from them.
    public static let excludedStatementsWithWeakTopics = [
        "No attempt history, answers or scores (only the names of your weaker topics, derived on this Mac)",
        "No private reflections or learning-history notes",
        "No files other than the document extracts listed above",
    ]
    public static let excludedStatements = [
        "No attempt history, answers or scores",
        "No private reflections or learning-history notes",
        "No files other than the document extracts listed above",
    ]
}

public struct RequestPackage: Sendable {
    /// Complete prompt for pasting into one chat message.
    public var singlePrompt: String
    /// Short message to send when attaching `files` instead.
    public var coverPrompt: String
    public var files: [ExportFile]
    public var manifest: RequestManifest
    public var recommended: TransferMethod { manifest.recommendedTransfer }
}

struct PromptInput {
    struct Extract { var title: String; var page: Int?; var text: String }
    struct RepairItem { var importId: String; var entryJSON: String; var issues: [String] }

    var kind: BatchKind
    var requestId: String
    var count: Int
    var params: GenerationParams
    var courseName: String
    var assessmentName: String?
    var skills: [String]
    var existingTitles: [String]
    var extracts: [Extract]
    var truncatedDocs: Set<String>
    var batchLabel: String
    var repair: [RepairItem] = []
    var alreadyHave: [String] = []
    var blueprint: String = ""
    var blueprintSlots = 0
    var mode: String?
    var weakTargets: [String] = []
    var excludedTopics: [String] = []
}

enum PromptBuilder {
    static let compactLimit = 12_000
    static let extractBudget = 20_000
    static let maxExistingTitles = 40

    static func build(_ i: PromptInput) -> RequestPackage {
        let instructions = instructionsText(i)
        let skills = "## Skills (use these exact names in each question's \"skills\" array)\n" + i.skills.map { "- \($0)" }.joined(separator: "\n")
        var existing = ""
        if !i.existingTitles.isEmpty {
            existing = "## Existing questions (do not duplicate these)\n" + i.existingTitles.map { "- \($0)" }.joined(separator: "\n")
        }
        if !i.alreadyHave.isEmpty {
            existing += (existing.isEmpty ? "" : "\n\n") + "## Already accepted from earlier in this task (do not repeat)\n" + i.alreadyHave.map { "- \($0)" }.joined(separator: "\n")
        }
        var docSections: [(String, String)] = []
        var byDoc: [String: [PromptInput.Extract]] = [:], order: [String] = []
        for e in i.extracts { if byDoc[e.title] == nil { order.append(e.title) }; byDoc[e.title, default: []].append(e) }
        for t in order {
            let body = byDoc[t]!.map { "[\(t)\($0.page.map { ", p.\($0)" } ?? "")]\n\($0.text)" }.joined(separator: "\n\n")
            docSections.append((t, "## Source extract: \(t)\n\n" + body))
        }
        let repair = i.repair.isEmpty ? "" : "## Questions to repair\n\n" + i.repair.map {
            "### \($0.importId)\nProblems:\n" + $0.issues.map { "- \($0)" }.joined(separator: "\n") + "\n\nOriginal JSON:\n```json\n\($0.entryJSON)\n```"
        }.joined(separator: "\n\n")

        var parts = [instructions, "## Response JSON schema\n```json\n\(ResponseSchema.json)\n```", skills]
        if !i.blueprint.isEmpty { parts.append(i.blueprint) }
        if !existing.isEmpty { parts.append(existing) }
        if !repair.isEmpty { parts.append(repair) }
        parts += docSections.map(\.1)
        let single = parts.joined(separator: "\n\n---\n\n")

        let transfer: TransferMethod = single.count <= compactLimit ? .clipboard : .file
        let manifest = RequestManifest(
            requestId: i.requestId, schemaVersion: QuestionSchema.version, kind: i.kind, course: i.courseName,
            assessment: i.assessmentName, expectedCount: i.count, questionTypes: i.params.types.map(\.rawValue),
            difficulty: "\(i.params.minDifficulty)–\(i.params.maxDifficulty)", skills: i.skills,
            documents: order.map { t in .init(title: t, characters: byDoc[t]!.reduce(0) { $0 + $1.text.count }, truncated: i.truncatedDocs.contains(t)) },
            existingQuestionTitles: i.existingTitles.count, repairEntries: i.repair.count,
            includesUserNotes: !i.params.notes.trimmingCharacters(in: .whitespaces).isEmpty,
            characterCount: single.count, recommendedTransfer: transfer, mode: i.mode, blueprintSlots: i.blueprintSlots == 0 ? nil : i.blueprintSlots,
            weakTopicTargets: i.weakTargets.isEmpty ? nil : i.weakTargets, excludedTopics: i.excludedTopics.isEmpty ? nil : i.excludedTopics,
            excluded: i.weakTargets.isEmpty ? RequestManifest.excludedStatements : RequestManifest.excludedStatementsWithWeakTopics)

        var files = [ExportFile(name: "instructions.md", content: instructions),
                     ExportFile(name: "response_schema.json", content: ResponseSchema.json),
                     ExportFile(name: "context_skills.md", content: skills)]
        if !i.blueprint.isEmpty { files.append(ExportFile(name: "context_blueprint.md", content: i.blueprint)) }
        if !existing.isEmpty { files.append(ExportFile(name: "context_existing_questions.md", content: existing)) }
        if !repair.isEmpty { files.append(ExportFile(name: "context_repair.md", content: repair)) }
        for (n, (t, body)) in docSections.enumerated() { files.append(ExportFile(name: "source_\(n + 1)_\(safeName(t)).md", content: body)) }
        let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        files.append(ExportFile(name: "manifest.json", content: (try? enc.encode(manifest)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"))

        let cover = """
        I'm attaching files for a Braincell request. Read instructions.md and follow it exactly. Reply with ONLY the JSON object described in response_schema.json (no commentary). The requestId to echo back is: \(i.requestId)
        """
        return RequestPackage(singlePrompt: single, coverPrompt: cover, files: files, manifest: manifest)
    }

    /// Filesystem-safe name: no separators, dots or traversal sequences.
    static func safeName(_ s: String) -> String {
        let cleaned = String(s.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) ? Character($0) : "-" }).prefix(40)
        return cleaned.isEmpty ? "doc" : String(cleaned)
    }

    private static func instructionsText(_ i: PromptInput) -> String {
        let what: String
        switch i.kind {
        case .generate: what = "Write \(i.count) new study questions."
        case .continue: what = "Write \(i.count) MORE study questions to complete an earlier request."
        case .repair: what = "Return corrected versions of the \(i.count) question(s) listed under “Questions to repair”, keeping each importId."
        case .grade, .topics: what = ""
        }
        let types = i.params.types.isEmpty ? "any mix of supported types" : i.params.types.map(\.rawValue).joined(separator: ", ")
        var s = """
        # Braincell request — \(i.batchLabel)

        You are helping build a study question bank for the course “\(i.courseName)”\(i.assessmentName.map { ", for the assessment “\($0)”" } ?? "").

        ## Task
        \(what)
        - Question types: \(types)
        - Difficulty: \(i.params.minDifficulty) (easy) to \(i.params.maxDifficulty) (hard), mixed unless the range is a single value
        - Base every question on the skills and source extracts below. Do not invent facts that contradict the sources.
        """
        let notes = i.params.notes.trimmingCharacters(in: .whitespacesAndNewlines)
        if !notes.isEmpty { s += "\n- Extra guidance from the student: \(notes)" }
        s += """


        ## Output rules
        1. Reply with ONE JSON object and nothing else (a ```json fence is fine). It must match the schema.
        2. `schemaVersion` must be "\(QuestionSchema.version)". `requestId` must be exactly "\(i.requestId)".
        3. Every question needs: importId (q1, q2, …), type, title, difficulty (1–5), learningObjective, content (blocks), answer, evaluation, hints (1–3 progressive hints, least revealing first), solution (blocks), skills (exact names from the list), assessments (names, optional), sources ({document, page}).
        4. Math and formatting (markdown blocks): write prose as Markdown. Put short notation inside sentences as inline math \\( ... \\), e.g. \\(X\\) and \\(Y\\). Put every longer or important formula on its own line as display math \\[ ... \\]; use \\begin{aligned} ... \\end{aligned} for multi-line derivations. Never write formulas as plain text (not `U=(X-E[X])/σ_X`; write \\[U=\\frac{X-\\mathbb{E}[X]}{\\sigma_X}\\]). Split the question into short paragraphs: context, definitions, conditions, then each part on its own line starting with **Part A.**, **Part B.** … Use fenced code blocks for code. Do not use HTML, scripts or links. Do not change what a formula means to make it fit. In the JSON text every backslash must be written twice (so \\\\\\\\frac in the JSON means \\\\frac).
        5. Code goes in `code` blocks with `language` python, c or java. Never rely on running code; give expected output yourself and double-check it by hand.
        6. Be certain the stated answers are correct. If you are unsure, pick a different question.

        ## `answer` and `evaluation` by type
        - flashcard: answer {"back":[blocks]}; evaluation {"method":"self_review"}
        - single_choice: answer {"choices":[{"id":"a","text":"…"},…],"correctIds":["a"]} (2–6 choices, exactly one correct); evaluation {"method":"choice"}
        - multiple_select: same, `correctIds` lists every correct id; evaluation {"method":"choice"}
        - short_answer: answer {"accepted":["…"],"caseSensitive":false}; evaluation {"method":"exact"} (or "self_review"). For an algebraic answer use answer {"expression":"(x+1)^2"}; evaluation {"method":"symbolic"} (polynomials/fractions with + - * / ^ and integer powers only; no functions, roots or pi)
        - numeric: answer {"value":12.5,"tolerance":0.01,"unit":"","verificationExpression":"25/2"}; evaluation {"method":"numeric"}. `verificationExpression` is optional arithmetic (numbers, + - * / ^, parentheses, pi) that re-derives `value`.
        - code_tracing: answer {"expectedOutput":"…","accepted":[]}; evaluation {"method":"exact"} (or "self_review")
        - coding (preferred): answer {"language":"python|c|java","starterCode":"…","referenceSolution":"…","tests":[{"name":"small case","input":"stdin text","expectedOutput":"exact stdout","hidden":false}]}; evaluation {"method":"code_tests"}. The program reads stdin and writes stdout; give 3–8 tests (some `hidden`: true); the referenceSolution MUST pass every test; it is checked automatically.
        - coding (when stdin/stdout tests don't fit): same answer without tests; evaluation {"method":"self_review"} or {"method":"ai_rubric","rubric":[…]}
        - long_form / derivation_proof: answer {}; evaluation {"method":"ai_rubric","rubric":[{"criterion":"…","points":2}]}; put the model answer in `solution`

        ## Reasoning metadata (schema v2, all optional but strongly preferred)
        - `solutionPlan`: {"interpretation","assumptions":[],"method","formulas":[],"steps":[{"description","skill","intermediateResult","commonError"}],"finalResult","pitfalls":[]} — an explicit, checkable solution a teacher could follow (not hidden reasoning). At least two steps.
        - `metadata.provenance`: {"slotId":"<slot id from the Blueprint>","topic","reasoningSkills":["verb phrase"],"primaryArchetype":"<archetype key>","secondaryArchetypes":[],"origin":"generated_variant","sourceRefs":[{"document","page","locator"}],"difficultyFactors":{"steps":0-3,"concepts":0-3,"methodSelection":0-3,"assumptions":0-3,"algebra":0-3,"conditioning":0-3,"generalization":0-3,"misconceptions":0-3,"rationale":""}}. Difficulty is an estimate from these factors; long wording or unpleasant arithmetic does not make a question harder.
        - Numeric single_choice with interval choices: add to `answer` `"intervals":[{"choiceId":"a","lower":0.1,"upper":0.2,"lowerClosed":true,"upperClosed":false}]` (null = unbounded; never use Infinity), `"exactResult"` (the unrounded number) and `"roundingDecimals"`. For supported problems add `"check"` so the app recomputes the result: {"kind":"jointPMF","op":"conditionalYgivenX","xs":[…],"ys":[…],"table":[[…]],"x":1,"y":2} or {"kind":"geometricMGF","op":"mgf|domainUpper|mean|variance","p":0.3,"t":0.1} or {"kind":"finitePMF","probs":[…]}.
        - Distractors must come from plausible misconceptions. A formula-recall question and a derivation question are different reasoning demands; label them honestly.

        Request ID: \(i.requestId)
        """
        return s
    }
}

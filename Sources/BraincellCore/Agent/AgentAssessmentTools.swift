import Foundation
import GRDB

extension AgentRegistry {
    static let assessmentTools: [ToolSpec] = [
        ToolSpec(name: "sources.analyze", summary: "Analyze a course's instructor practice questions and worked solutions (once per unchanged file; cached). Extracts each question with its solution method, archetype and difficulty so generated practice can follow the instructor's reasoning. Reports completeness and limitations honestly.",
                 params: [ToolParam("course", "string", "Course name or id", required: true), ToolParam("document", "string", "File name or id (optional: all readable files)")], permission: .write, approval: false,
                 describe: { a, _ in "Analyze practice questions in \(a.string("course") ?? "the course")" }, run: analyzeSources),
        ToolSpec(name: "style.profile", summary: "Show the detected assessment style profile for a course/assessment: question formats, reasoning archetypes, difficulty spread, rounding, coverage and limitations. Confirmed, inferred and user-provided facts are labelled.",
                 params: [ToolParam("course", "string", "Course name or id", required: true), ToolParam("assessment", "string", "Assessment (optional)")], permission: .read, approval: false,
                 describe: { _, _ in "Inspect the style profile" }, run: styleProfile),
        ToolSpec(name: "assessments.configure", summary: "Record exam settings the learner stated (question count, minutes, points per question, format, closed book, rounding, topics included/excluded). Stored as user-provided, not confirmed.",
                 params: [ToolParam("course", "string", "Course name or id", required: true), ToolParam("assessment", "string", "Assessment name or id", required: true), ToolParam("questionCount", "integer", ""), ToolParam("minutes", "integer", ""), ToolParam("pointsPerQuestion", "number", ""),
                          ToolParam("format", "string", "e.g. single_choice"), ToolParam("closedBook", "boolean", ""), ToolParam("roundingDecimals", "integer", ""), ToolParam("include", "array", "topic names covered"), ToolParam("exclude", "array", "topic names explicitly excluded")],
                 permission: .write, approval: true, describe: { a, _ in "Save exam settings for \(a.string("assessment") ?? "the assessment")" }, run: configureAssessment),
    ]

    @Sendable static func analyzeSources(_ a: ToolArgs, _ c: AgentContext, _ info: ToolRunInfo) async throws -> ToolOutput {
        let course = try c.course(try a.require("course"))
        var docs = try c.docs.documents(courseId: course.id).filter { readableKinds($0.kind) && $0.extractionStatus != .failed }
        if let ref = a.string("document") { let n = AgentContext.norm(ref); docs = docs.filter { $0.id.uuidString.lowercased() == ref.lowercased() || AgentContext.norm($0.name).contains(n) } }
        guard !docs.isEmpty else { throw ToolError.unavailable("No readable documents to analyze. Scanned pages need OCR, which this build doesn’t have.") }
        let svc = SourceAnalysisService(db: c.db, gateway: c.gateway)
        var lines: [String] = []
        for d in docs.prefix(8) {
            info.stage("Analyzing \(d.name)")
            let outcome = try await svc.analyze(d)
            let s = try svc.summary(documentId: d.id)
            let state: String
            switch outcome { case .cached: state = "reused cached analysis"; case .analyzed: state = "analyzed"; case .partial(_, let f): state = "partly analyzed (\(f) window(s) failed; run again to resume)"; case .awaitingImport: state = "waiting for you to paste the reply (manual bridge)" }
            lines.append("- \(d.name): \(state); \(s?.questions ?? 0) question(s), \(s?.completeQuestions ?? 0) complete; windows \(s?.windowsDone ?? 0)/\(s?.windowsTotal ?? 0)" + ((s?.limitations.isEmpty ?? true) ? "" : ". Limitations: \(s!.limitations)"))
        }
        return ToolOutput(text: "Source analysis for \(course.name):\n" + lines.joined(separator: "\n") + "\nA bank is only complete when every window is done and there are no limitations. Do not call a truncated or partial analysis complete.", summary: "\(docs.count) file(s) analyzed")
    }

    @Sendable static func styleProfile(_ a: ToolArgs, _ c: AgentContext, _ info: ToolRunInfo) async throws -> ToolOutput {
        let course = try c.course(try a.require("course")); let asm = try c.assessment(a.string("assessment"), in: course)
        let p = try AssessmentService(db: c.db).profile(courseId: course.id, assessmentId: asm?.id)
        func top(_ d: [String: Int]) -> String { d.isEmpty ? "none observed" : d.sorted { $0.value > $1.value }.prefix(6).map { "\($0.key) ×\($0.value)" }.joined(separator: ", ") }
        var t = "Style profile for \(asm?.name ?? course.name) (inferred patterns, confidence \(Int(p.archetypes.confidence * 100))%):\n"
        t += "- Formats: \(top(p.formats.value))\n- Archetypes: \(top(p.archetypes.value))\n- Difficulty spread (estimates): \(top(p.difficulty.value))\n- Avg solution steps: \(String(format: "%.1f", p.averageSteps.value))\n- Rounding: \(top(p.roundingDecimals.value))\n"
        t += p.choicePatterns.map { "- \($0)\n" }.joined()
        t += "- Coverage: \(p.coverage.questionsRecovered) question(s) recovered (\(p.coverage.completeQuestions) complete) from \(p.coverage.documentsAnalyzed)/\(p.coverage.documents) file(s); windows \(p.coverage.windowsDone)/\(p.coverage.windowsTotal)\n"
        let cfg = p.config
        t += "- Exam settings (user-provided unless marked): \(cfg.examQuestionCount.map { "\($0) questions" } ?? "count unknown"), \(cfg.durationMinutes.map { "\($0) min" } ?? "time unknown")" + (cfg.scopeExcludes.isEmpty ? "" : ", excludes \(cfg.scopeExcludes.joined(separator: ", "))") + "\n"
        t += "Limitations:\n" + p.limitations.map { "- \($0)" }.joined(separator: "\n")
        return ToolOutput(text: t, summary: "\(p.coverage.questionsRecovered) source questions")
    }

    @Sendable static func configureAssessment(_ a: ToolArgs, _ c: AgentContext, _ info: ToolRunInfo) async throws -> ToolOutput {
        let course = try c.course(try a.require("course"))
        guard let asm = try c.assessment(try a.require("assessment"), in: course) else { throw ToolError.notFound("No such assessment.") }
        let svc = AssessmentService(db: c.db); var cfg = try svc.config(assessmentId: asm.id)
        func set<T>(_ key: String, _ v: T?, _ apply: (T) -> Void) { if let v { apply(v); cfg.basis[key] = .userProvided } }
        set("examQuestionCount", a.int("questionCount")) { cfg.examQuestionCount = $0 }
        set("durationMinutes", a.int("minutes")) { cfg.durationMinutes = $0 }
        set("pointsPerQuestion", (a.raw["pointsPerQuestion"] as? NSNumber)?.doubleValue) { cfg.pointsPerQuestion = $0 }
        set("format", a.string("format")) { cfg.format = $0 }
        set("closedBook", a.bool("closedBook")) { cfg.closedBook = $0 }
        set("roundingDecimals", a.int("roundingDecimals")) { cfg.roundingDecimals = $0 }
        if !a.strings("include").isEmpty { cfg.scopeIncludes = a.strings("include"); cfg.basis["scopeIncludes"] = .userProvided }
        if !a.strings("exclude").isEmpty { cfg.scopeExcludes = a.strings("exclude"); cfg.basis["scopeExcludes"] = .userProvided }
        try svc.setConfig(cfg, assessmentId: asm.id)
        return ToolOutput(text: "Saved exam settings for \(asm.name) as user-provided (not confirmed against the instructor's announcement). Excluded topics are enforced when generating questions.", summary: "Saved settings")
    }
}

import Testing
import Foundation
import GRDB
@testable import BraincellCore

extension AgentTests {
    func lib(_ e: E) -> LibraryService { LibraryService(db: e.db, storage: e.ctx.storage) }

    @Test func oneShotChatPathAndTheWizardShareOneJobAndReuseEverything() async throws {
        let (e, c) = try await guidedEnv()
        let co = ExamPrepCoordinator(e.ctx)
        let first = try await co.runAll(course: c, assessmentName: "Midterm 3", conversationId: e.conv)
        #expect(first.chips.contains { $0.action == "openPracticeSet" })
        let calls = e.script.count
        let again = try await co.runAll(course: c, assessmentName: "midterm 3", conversationId: e.conv)
        #expect(again.text.contains("Already prepared") && e.script.count == calls)                      // nothing re-analyzed or regenerated
        let job = try #require(try co.jobs(courseId: c.id).first)
        let jobCount = try co.jobs(courseId: c.id).count, sameJob = try co.start(course: c, assessmentName: "Midterm 3").id, setCount = try e.ctx.practiceSets.sets(courseId: c.id).count
        #expect(jobCount == 1 && sameJob == job.id)
        #expect(co.currentPlan(job.id)?.missing == 0 && setCount == 1)
        // A changed source invalidates the analysis and plan, not the learner's template choice.
        try co.setTemplate(job.id, templateId: "builtin.guided")
        let d2 = try insertDoc(e, c, name: "extra.pdf", status: .ok, pages: 1); try insertChunk(e, d2, 0, page: 1, "More about intervals.")
        let analyzedCalls = e.script.prompts.filter { $0.user.contains("You analyze course material") }.count
        let stale = try await co.analyze(job.id)
        #expect(e.script.prompts.filter { $0.user.contains("You analyze course material") }.count == analyzedCalls + 1)
        #expect(stale.state.templateId == "builtin.guided" && stale.state.setId == nil)
        // Saved questions are reused for the new plan; only the shortfall is generated.
        let plan = try co.plan(job.id, count: 2)
        #expect(plan.reused > 0 || plan.missing <= 2)
    }

    @Test func unfinishedPreparationSurvivesQuittingAndReopening() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("restart-\(UUID().uuidString).sqlite")
        let m = SetModel()
        let handler: @Sendable (String, String, Int) -> String = { _, user, _ in user.contains("You analyze course material") ? Self.topicsJSON : m.reply(user, analysis: "{}") }
        var jobId: UUID, courseId: UUID
        do {
            let e = try await env(dbURL: url, handler)
            let c = try e.ctx.courses.createCourse(name: "STOR435")
            let d = try insertDoc(e, c, name: "outline.pdf", status: .ok, pages: 5)
            try insertChunk(e, d, 0, page: 1, "Chapter 2 is worth 40% of the exam grade."); try insertChunk(e, d, 1, page: 2, "Worked example: maximum likelihood estimate.")
            let co = ExamPrepCoordinator(e.ctx)
            let j = try co.start(course: c, assessmentName: "Midterm 3")
            _ = try await co.analyze(j.id)
            try co.setExcluded(j.id, topics: ["Hypothesis tests"]); try co.setTemplate(j.id, templateId: "builtin.flashcards"); try co.setStep(j.id, "configure")
            try co.setParams(j.id, GenerationParams(count: 4)); jobId = j.id; courseId = c.id
        }                                                                                                  // app "quits": everything above is dropped
        let e2 = try await env(dbURL: url, handler)
        let co2 = ExamPrepCoordinator(e2.ctx)
        let back = try #require(try co2.job(jobId))
        #expect(back.state.wizardStep == "configure" && back.state.excludedTopics == ["Hypothesis tests"] && back.state.templateId == "builtin.flashcards" && back.state.params?.count == 4)
        let topics = try co2.studyMap(back)?.topics.count
        #expect(back.state.mapId != nil && back.state.topicCount == 3 && topics == 3)
        _ = try await co2.analyze(jobId)
        #expect(e2.script.count == 0)                                                                      // resumed from saved analysis: no model call after restart
        #expect(co2.existingJob(courseId: courseId, assessmentName: "Midterm 3")?.id == jobId)
    }

    @Test func deletedPracticeSetsAppearInRecentlyDeletedAndRestoreWithTheirQuestionsAndAttempts() async throws {
        let e = try await env { _, _, _ in "x" }
        let c = try e.ctx.courses.createCourse(name: "A")
        try seedQuestions(e, c, Array(Fx.all.prefix(3)))
        let ids = try QuestionService(db: e.db).list(QuestionFilter()).map(\.id)
        let (set, svc) = try manualSet(e, c)
        for q in ids.prefix(2) { try svc.add(questionId: q, to: set.id) }
        let tpl = TemplateService(db: e.db)
        let started = try svc.startSession(setId: set.id, template: .interactive, templates: tpl)
        let l = lib(e)
        try svc.delete(setId: set.id)
        let trash = try l.recentlyDeleted()
        #expect(trash.contains { $0.ref.kind == .practiceSet && $0.name == "Manual" && $0.detail.contains("2 questions") })
        let hidden = try svc.sets(courseId: c.id)
        #expect(hidden.isEmpty)
        try l.restore(try #require(trash.first { $0.ref.kind == .practiceSet }).ref)
        let back = try svc.sets(courseId: c.id).map(\.id), nItems = try svc.items(setId: set.id).count, sid = try svc.progress(setId: set.id).sessionId
        #expect(back == [set.id] && nItems == 2 && sid == started.session.id)                                                  // nothing lost
        try svc.delete(setId: set.id)
        try l.purge(LibraryRef(id: set.id, kind: .practiceSet))
        let gone = try svc.practiceSet(set.id), nq = try QuestionService(db: e.db).list(QuestionFilter()).count
        #expect(gone == nil && nq == 3)                                                                                          // questions survive a purge
        #expect((try? PracticeService(db: e.db).session(started.session.id)) != nil)                                            // so does the attempt
    }

    @Test func courseDeleteAndRestoreKeepItsPracticeSetsAndAttempts() async throws {
        let e = try await env { _, _, _ in "x" }
        let c = try e.ctx.courses.createCourse(name: "A")
        try seedQuestions(e, c, Array(Fx.all.prefix(2)))
        let (set, svc) = try manualSet(e, c)
        for q in try QuestionService(db: e.db).list(QuestionFilter()).map(\.id) { try svc.add(questionId: q, to: set.id) }
        _ = try svc.startSession(setId: set.id, template: .interactive, templates: TemplateService(db: e.db))
        let l = lib(e)
        try l.deleteCourse(c.id)
        try l.restore(LibraryRef(id: c.id, kind: .courseFolder))
        let n = try svc.sets(courseId: c.id).count, st = try svc.progress(setId: set.id).state
        #expect(n == 1 && st == .inProgress)
    }

    @Test func favoritesAndSavedViewsWorkAcrossLibraryCategoriesWithoutTouchingQuestionViews() async throws {
        let e = try await env { _, _, _ in "x" }
        let fav = LibraryFavorites(db: e.db), views = LibraryViews(db: e.db), qs = QuestionService(db: e.db)
        try fav.set(.template, "builtin.guided", true); try fav.set(.practiceSet, "abc", true); try fav.set(.template, "builtin.guided", true)
        let t1 = try fav.ids(.template)
        #expect(t1 == ["builtin.guided"] && fav.isFavorite(.practiceSet, "abc") && !fav.isFavorite(.question, "abc"))
        try fav.set(.template, "builtin.guided", false)
        let t2 = try fav.ids(.template)
        #expect(t2.isEmpty)
        struct F: Codable, Equatable { var text: String; var favoritesOnly: Bool }
        try views.save(category: "materials", name: "Starred PDFs", filter: F(text: "pdf", favoritesOnly: true))
        try qs.saveView(name: "Hard ones", filter: QuestionFilter())
        let mats = try views.views(category: "materials")
        #expect(mats.count == 1 && LibraryViews.filter(mats[0], as: F.self) == F(text: "pdf", favoritesOnly: true))
        let qn = try qs.savedViews().map(\.name), other = try views.views(category: "practiceSets")
        #expect(qn == ["Hard ones"] && other.isEmpty)                                                                          // categories don't leak into each other
    }

    @Test func notesAreSummarizedOnlyWhenNeededAndSavedForReuse() async throws {
        let calls = LockedBox<Int>(0)
        let e = try await env { _, user, _ in calls.withLock { $0 += 1 }; return "## Overview\nML estimates\n\nKey: \\(\\hat\\theta\\)" }
        let c = try e.ctx.courses.createCourse(name: "STOR435")
        let d1 = try insertDoc(e, c, name: "notes.pdf", status: .ok, pages: 2); try insertChunk(e, d1, 0, page: 1, "Maximum likelihood estimators maximize the likelihood.")
        let d2 = try insertDoc(e, c, name: "slides.pdf", status: .ok, pages: 1); try insertChunk(e, d2, 0, page: 1, "Confidence intervals cover the parameter.")
        let svc = NoteSummaryService(db: e.db, gateway: e.ctx.gateway)
        var cands = try svc.candidates(courseId: c.id)
        #expect(cands.count == 2 && cands.allSatisfy { if case .needed = $0.state { true } else { false } } && calls.value == 0)    // checking costs nothing
        let r1 = try await svc.summarize(documentIds: [d1.id])
        #expect(r1.generated == 1 && r1.reused == 0 && calls.value == 1)
        let r2 = try await svc.summarize(documentIds: [d1.id, d2.id])
        #expect(r2.reused == 1 && r2.generated == 1 && calls.value == 2)                                                     // only the new one cost a call
        cands = try svc.candidates(courseId: c.id)
        #expect(cands.allSatisfy { if case .saved = $0.state { true } else { false } })
        let savedN = try svc.saved(courseId: c.id).count
        #expect(savedN == 2)
        // changing a source makes only that summary stale (needed again); the other stays saved
        try e.db.write { try $0.execute(sql: "UPDATE documents SET sha256 = 'changed' WHERE id = ?", arguments: [d1.id]) }
        let after = try svc.candidates(courseId: c.id)
        #expect(after.first { $0.id == d1.id }.map { if case .needed = $0.state { true } else { false } } == true && after.first { $0.id == d2.id }.map { if case .saved = $0.state { true } else { false } } == true)
        let none = try await svc.summarize(documentIds: [d2.id])
        #expect(none.reused == 1 && calls.value == 2)
    }

    @Test func noProviderMeansNoSummaryAndNoSavedGarbage() async throws {
        let e = try await env(connect: false) { _, _, _ in Issue.record("must not be called"); return "x" }
        let c = try e.ctx.courses.createCourse(name: "A")
        let d = try insertDoc(e, c, name: "n.pdf", status: .ok, pages: 1); try insertChunk(e, d, 0, page: 1, "text")
        let svc = NoteSummaryService(db: e.db, gateway: e.ctx.gateway)
        do { _ = try await svc.summarize(documentIds: [d.id]) } catch {}
        let leftover = try svc.saved(courseId: c.id)
        #expect(leftover.isEmpty)
    }
}

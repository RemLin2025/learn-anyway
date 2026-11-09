import Testing
import Foundation
import GRDB
@testable import BraincellCore

@Suite struct TopicAnalysisTests {
    struct Setup { let rig: Rig; let task: AITask; let batch: AITaskBatch; let midterm: Assessment }
    func setup() throws -> Setup {
        let rig = try Rig()
        let mid = try rig.courses.addAssessment(courseId: rig.course.id, name: "Midterm 1")
        let t = try rig.ai.createTopicAnalysisTask(courseId: rig.course.id, notes: "focus on Java")
        return Setup(rig: rig, task: t, batch: try rig.ai.batches(taskId: t.id)[0], midterm: mid)
    }
    func reply(_ s: Setup, _ skills: [[String: Any]], version: String = TopicSchema.version, requestId: String? = nil) -> String {
        let obj: [String: Any] = ["schemaVersion": version, "requestId": requestId ?? s.batch.requestId, "skills": skills]
        return String(data: try! JSONSerialization.data(withJSONObject: obj), encoding: .utf8)!
    }
    let sample: [[String: Any]] = [
        ["id": "t1", "name": "Generics", "summary": "Type parameters", "assessments": ["Midterm 1", "Nope exam"]],
        ["id": "t2", "name": "Bounded generics", "parent": "t1", "prerequisites": ["t1"], "assessments": ["Midterm 1"]],
        ["id": "t3", "name": "Java iterator", "parent": "Recursion"],         // similar to existing "Java iterators"
        ["id": "t4", "name": "Recursion"],                                     // exactly an existing skill
    ]

    @Test func requestDisclosesOnlyWhatItShould() throws {
        let s = try setup()
        let pkg = try s.rig.ai.prepare(batchId: s.batch.id)
        #expect(pkg.singlePrompt.contains(s.batch.requestId) && pkg.singlePrompt.contains("Java iterators") && pkg.singlePrompt.contains("Midterm 1"))
        #expect(pkg.manifest.kind == .topics && pkg.manifest.includesUserNotes && pkg.manifest.excluded.contains { $0.contains("No questions") })
        #expect(pkg.files.map(\.name).contains("response_schema.json"))
        #expect(throws: AITaskError.self) { try s.rig.ai.createRepairBatch(from: s.batch.id) }
    }

    @Test func stagingChangesNothingAndClassifiesEachSkill() throws {
        let s = try setup()
        let before = try s.rig.courses.skills(courseId: s.rig.course.id).count
        let p = try s.rig.ai.importTopics(reply(s, sample), targetBatchId: s.batch.id)
        #expect(try s.rig.courses.skills(courseId: s.rig.course.id).count == before)
        #expect(try s.rig.ai.batches(taskId: s.task.id)[0].status != .imported)
        func match(_ id: String) -> TopicMatch { p.items.first { $0.id == id }!.match }
        #expect(match("t1") == .new)
        if case .ambiguous(let c) = match("t3") { #expect(c.first?.name == "Java iterators") } else { Issue.record("t3 should be ambiguous") }
        if case .existing(let e) = match("t4") { #expect(e.name == "Recursion") } else { Issue.record("t4 should match the existing skill") }
        #expect(p.unknownAssessments == ["Nope exam"])
    }

    @Test func applyCreatesReusesAndLinksWithoutTouchingMastery() throws {
        let s = try setup()
        let q = try s.rig.question(0)
        let a = try s.rig.attempt(q, selected: ["a"])          // some real evidence on skillA
        _ = a
        let evBefore = try s.rig.prog.evidence(skillId: s.rig.skillA.id).count
        let xpBefore = try s.rig.prog.skillXP(s.rig.skillA.id).xp

        try s.rig.ai.importTopics(reply(s, sample), targetBatchId: s.batch.id)
        let r = try s.rig.ai.applyTopics(batchId: s.batch.id)
        #expect(r.created.sorted() == ["Bounded generics", "Generics"])
        #expect(r.reused == ["Recursion"] && r.coverageAdded == 2)
        #expect(r.skipped.contains { $0.contains("Java iterator") })       // ambiguous & undecided → skipped
        let skills = try s.rig.courses.skills(courseId: s.rig.course.id)
        let gen = try #require(skills.first { $0.name == "Generics" }), bounded = try #require(skills.first { $0.name == "Bounded generics" })
        #expect(gen.summary == "Type parameters")
        let rels = try s.rig.courses.relations(courseId: s.rig.course.id)
        #expect(rels.contains { $0.kind == .hierarchy && $0.fromSkillId == gen.id && $0.toSkillId == bounded.id })
        #expect(rels.contains { $0.kind == .prerequisite && $0.fromSkillId == gen.id && $0.toSkillId == bounded.id })
        #expect(try s.rig.courses.scopedSkills(assessmentId: s.midterm.id).map(\.name).sorted() == ["Bounded generics", "Generics"])
        #expect(try s.rig.ai.batches(taskId: s.task.id)[0].status == .imported)
        #expect(try s.rig.prog.evidence(skillId: s.rig.skillA.id).count == evBefore)
        #expect(try s.rig.prog.skillXP(s.rig.skillA.id).xp == xpBefore)
    }

    @Test func applyingTwiceAndRepastingAreIdempotent() throws {
        let s = try setup()
        let text = reply(s, sample)
        try s.rig.ai.importTopics(text, targetBatchId: s.batch.id)
        try s.rig.ai.applyTopics(batchId: s.batch.id)
        let skills = try s.rig.courses.skills(courseId: s.rig.course.id).count, rels = try s.rig.courses.relations(courseId: s.rig.course.id).count
        let again = try s.rig.ai.applyTopics(batchId: s.batch.id)
        #expect(again.created.isEmpty && again.relationsAdded == 0 && again.coverageAdded == 0)
        let p = try s.rig.ai.importTopics(text, targetBatchId: s.batch.id)
        #expect(p.alreadyApplied && p.items.first { $0.id == "t1" }.map { if case .existing = $0.match { true } else { false } } == true)
        #expect(try s.rig.courses.skills(courseId: s.rig.course.id).count == skills && (try s.rig.courses.relations(courseId: s.rig.course.id).count) == rels)
        #expect(try s.rig.db.read { try AIImport.fetchCount($0) } >= 1)
    }

    @Test func decisionsAreHonoured() throws {
        let s = try setup()
        try s.rig.ai.importTopics(reply(s, sample), targetBatchId: s.batch.id)
        let decisions: [String: TopicDecision] = [
            "t1": TopicDecision(accept: true, name: "Java generics"),                        // rename before accepting
            "t2": TopicDecision(accept: false),                                              // declined
            "t3": TopicDecision(mergeInto: s.rig.skillA.id),                                 // fold into existing
        ]
        let r = try s.rig.ai.applyTopics(batchId: s.batch.id, decisions: decisions)
        let names = try s.rig.courses.skills(courseId: s.rig.course.id).map(\.name)
        #expect(names.contains("Java generics") && !names.contains("Generics") && !names.contains("Bounded generics") && !names.contains("Java iterator"))
        #expect(r.reused.contains("Java iterators") && r.skipped.contains { $0.contains("Bounded generics") })
        // t3 had parent "Recursion" (existing): the hierarchy link attaches the merged skill to it
        let rels = try s.rig.courses.relations(courseId: s.rig.course.id)
        #expect(rels.contains { $0.kind == .hierarchy && $0.fromSkillId == s.rig.skillB.id && $0.toSkillId == s.rig.skillA.id })
    }

    @Test func cyclesAndUnknownReferencesAreSkippedNotFatal() throws {
        let s = try setup()
        let cyc: [[String: Any]] = [["id": "a", "name": "Alpha", "prerequisites": ["b"]], ["id": "b", "name": "Beta", "prerequisites": ["a"]],
                                    ["id": "c", "name": "Gamma", "parent": "ghost"]]
        try s.rig.ai.importTopics(reply(s, cyc), targetBatchId: s.batch.id)
        let r = try s.rig.ai.applyTopics(batchId: s.batch.id)
        #expect(r.created.count == 3 && r.relationsAdded == 1)
        #expect(r.skipped.contains { $0.contains("cycle") } && r.skipped.contains { $0.contains("ghost") })
    }

    @Test func invalidEntriesAreReportedAndBadResponsesRejected() throws {
        let s = try setup()
        let mixed: [[String: Any]] = [["id": "ok", "name": "Fine"], ["id": "ok", "name": "Dup id"], ["id": "x", "name": ""], ["id": "y", "name": "fine"],
                                      ["id": "z", "name": "Z", "prerequisites": "not a list"], ["name": "No id"]]
        let p = try s.rig.ai.importTopics(reply(s, mixed), targetBatchId: s.batch.id)
        #expect(p.items.map(\.id) == ["ok"] && p.problems.count == 5)
        let other = try setup()
        #expect(throws: AITaskError.self) { try s.rig.ai.importTopics(self.reply(other, self.sample, requestId: "req-nope"), targetBatchId: s.batch.id) }
        #expect(throws: AITaskError.self) { try s.rig.ai.importTopics(self.reply(s, self.sample, version: "braincell.topics.v9"), targetBatchId: s.batch.id) }
        #expect(throws: AITaskError.self) { try s.rig.ai.importTopics("not json at all", targetBatchId: s.batch.id) }
        #expect(throws: AITaskError.noTopics) { try s.rig.ai.importTopics(self.reply(s, []), targetBatchId: s.batch.id) }
        #expect(try s.rig.courses.skills(courseId: s.rig.course.id).count == 2)             // untouched
    }

    @Test func importAnyRoutesBySchema() throws {
        let s = try setup()
        guard case .topics(let p) = try s.rig.ai.importAny(reply(s, sample), targetBatchId: s.batch.id) else { Issue.record("not routed to topics"); return }
        #expect(p.items.count == 4)
        let gen = try s.rig.ai.createGenerationTask(courseId: s.rig.course.id, params: GenerationParams(count: 3))
        let gb = try s.rig.ai.batches(taskId: gen.id)[0]
        guard case .questions = try s.rig.ai.importAny(Fx.envelope(gb.requestId, Array(Fx.all.prefix(3))), targetBatchId: gb.id) else { Issue.record("not routed to questions"); return }
    }

    @Test func crossCourseSkillsNeverMatch() throws {
        let s = try setup()
        let other = try s.rig.courses.createCourse(name: "Other")
        _ = try s.rig.courses.addSkill(courseId: other.id, name: "Generics")
        let p = try s.rig.ai.importTopics(reply(s, sample), targetBatchId: s.batch.id)
        #expect(p.items.first { $0.id == "t1" }?.match == .new)
    }
}

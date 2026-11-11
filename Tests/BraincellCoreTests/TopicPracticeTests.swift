import Testing
import Foundation
import GRDB
@testable import BraincellCore

@Suite struct TopicPracticeTests {
    func cand(_ s: [UUID], _ d: Int, _ t: QuestionType = .shortAnswer) -> PracticeCandidate { PracticeCandidate(id: UUID(), skillIds: s, difficulty: d, type: t) }

    @Test func selectorCoversEveryTopicWeightsTheRestAndNeverRepeats() {
        let a = UUID(), b = UUID(), c = UUID()
        var all: [PracticeCandidate] = []
        for i in 0..<12 { all.append(cand([a], 1 + i % 5)); all.append(cand([b], 1 + i % 5)) }
        for _ in 0..<3 { all.append(cand([c], 3)) }
        let ids = PracticeSelector.select(all, count: 10, skills: [], weights: [a: 60, b: 30, c: 10], difficulty: .mixed, types: [])
        #expect(ids.count == 10 && Set(ids).count == 10)
        let by: (UUID) -> Int = { s in ids.filter { id in all.first { $0.id == id }!.skillIds.contains(s) }.count }
        #expect(by(a) >= 1 && by(b) >= 1 && by(c) >= 1)                                   // coverage of every relevant topic
        #expect(by(a) > by(b) && by(b) >= by(c))                                          // higher priority gets more
    }
    @Test func selectorHonoursTopicDifficultyAndTypeFilters() {
        let a = UUID(), b = UUID()
        let all = [cand([a], 1), cand([a], 4, .numeric), cand([b], 5), cand([a], 5, .numeric)]
        #expect(PracticeSelector.select(all, count: 9, skills: [a], weights: [:], difficulty: .hard, types: [.numeric]).count == 2)
        #expect(PracticeSelector.select(all, count: 9, skills: [b], weights: [:], difficulty: .easy, types: []).isEmpty)
        #expect(PracticeSelector.select(all, count: 0, skills: [], weights: [:], difficulty: .mixed, types: []).isEmpty)
    }

    @Test func topicRowsSeparateOfficialFromEstimatedAndNeverInventWeights() throws {
        let db = try AppDatabase.inMemory(); let cs = CourseService(db: db); let store = AgentStore(db: db)
        let c = try cs.createCourse(name: "STOR435"); let asm = try cs.addAssessment(courseId: c.id, name: "Midterm 3")
        let est = try cs.addSkill(courseId: c.id, name: "Estimation").skill, unk = try cs.addSkill(courseId: c.id, name: "Other").skill
        let child = try cs.addSkill(courseId: c.id, name: "MLE", parentId: est.id).skill
        func t(_ n: String, _ lvl: String, _ s: StudyMapDocument.Importance.Source, _ w: Double?) -> StudyMapDocument.Topic { .init(name: n, objectives: [], prerequisites: [], sources: [], importance: .init(level: lvl, source: s, weightPercent: w, evidence: "q")) }
        let doc = StudyMapDocument(courseName: "STOR435", assessmentName: "Midterm 3", topics: [t("Estimation", "high", .instructor, 40), t("MLE", "medium", .estimated, nil)], structures: [],
                                   research: .init(status: "unavailable", note: ""), warnings: [], coverageGaps: [])
        try store.saveMap(StudyMapRecord(id: UUID(), conversationId: nil, courseId: c.id, assessmentId: asm.id, title: "m", mapJSON: String(data: try JSONEncoder().encode(doc), encoding: .utf8)!, createdAt: Date(), updatedAt: Date()))
        try cs.addToScope(assessmentId: asm.id, skillId: est.id)
        var rows = try cs.topicRows(courseId: c.id, assessmentId: asm.id, store: store)
        func r(_ s: Skill) -> TopicRow { rows.first { $0.id == s.id }! }
        #expect(r(est).weight == .official(40) && r(est).hasChildren && r(child).depth == 1)
        if case .estimate = r(child).weight {} else { Issue.record("MLE should be an estimate") }
        #expect(r(unk).weight == .unknown && r(unk).inScope == false && r(est).inScope)
        try cs.setImportance(assessmentId: asm.id, skillId: unk.id, level: "high")                    // user override
        rows = try cs.topicRows(courseId: c.id, assessmentId: asm.id, store: store)
        #expect(r(unk).weight == .userSet && r(unk).inScope && r(unk).level == "high")
    }

    @Test func mergeMovesQuestionsAndScopeThenArchivesWithoutLosingAnything() throws {
        let db = try AppDatabase.inMemory(); let cs = CourseService(db: db); let qs = QuestionService(db: db)
        let c = try cs.createCourse(name: "X"); let asm = try cs.addAssessment(courseId: c.id, name: "M")
        let a = try cs.addSkill(courseId: c.id, name: "Confidence Intervals").skill, b = try cs.addSkill(courseId: c.id, name: "Interval Estimation").skill
        try cs.addToScope(assessmentId: asm.id, skillId: a.id)
        let t = AITaskService(db: db); let task = try t.createGenerationTask(courseId: c.id, params: GenerationParams(count: 2))
        let batch = try t.batches(taskId: task.id)[0]
        _ = try t.importResponse(Fx.envelope(batch.requestId, [Fx.base("short_answer", title: "Q1", answer: ["accepted": ["x"], "caseSensitive": false], method: "exact", skills: ["Confidence Intervals"])]), targetBatchId: batch.id)
        var f = QuestionFilter(); f.courseId = c.id
        let before = try qs.list(f).count
        let skillA = try cs.skills(courseId: c.id).first { $0.name == "Confidence Intervals" }!
        try cs.mergeSkills(from: skillA.id, into: b.id)
        f.skillId = b.id
        #expect(try qs.list(f).count == before && before == 1)                                       // question moved to the surviving topic
        #expect(try cs.skills(courseId: c.id).map(\.name) == ["Interval Estimation"])
        #expect(try cs.scopedSkills(assessmentId: asm.id).map(\.id) == [b.id])
        try cs.mergeSkills(from: b.id, into: b.id)                                                    // merging into itself is a no-op
        #expect(try cs.skills(courseId: c.id).count == 1)
    }

    @Test func practiceSessionAnswersAndProgressSurviveARestart() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString); try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("t.sqlite")
        var sid = UUID()
        do {
            let db = try AppDatabase.open(at: url); let cs = CourseService(db: db)
            let c = try cs.createCourse(name: "P")
            let t = AITaskService(db: db); let task = try t.createGenerationTask(courseId: c.id, params: GenerationParams(count: 3))
            let b = try t.batches(taskId: task.id)[0]
            _ = try t.importResponse(Fx.envelope(b.requestId, Array(Fx.all.prefix(3))), targetBatchId: b.id)
            let ps = PracticeService(db: db)
            let cands = try ps.candidates(courseId: c.id, assessmentId: nil)
            let ids = PracticeSelector.select(cands, count: 2, skills: [], weights: [:], difficulty: .mixed, types: [])
            #expect(ids.count == 2)
            let s = try ps.start(questionIds: ids, title: "Mixed", courseId: c.id)
            sid = s.id
            #expect(try db.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM session_items WHERE sessionId = ?", arguments: [sid]) } == 2)
        }
        let db2 = try AppDatabase.open(at: url)                                                       // "restart"
        #expect(try db2.read { try StudySession.fetchOne($0, key: sid) }?.title == "Mixed")
        #expect(try db2.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM session_items WHERE sessionId = ?", arguments: [sid]) } == 2)
    }
}

import Testing
import Foundation
import GRDB
@testable import BraincellCore

@Suite struct FocusTests {
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    func at(_ s: Double) -> Date { t0.addingTimeInterval(s) }

    @Test func activePausedAndCompletion() {
        var t = FocusTimer(kind: .work, plannedSeconds: 100, now: t0)
        t.tick(at(30)); #expect(t.activeSeconds == 30 && t.remainingSeconds == 70 && t.phase == .running)
        t.pause(at(40)); t.tick(at(100)); #expect(t.activeSeconds == 40 && t.pausedSeconds == 60 && t.phase == .paused)
        t.resume(at(100)); t.tick(at(150)); #expect(t.activeSeconds == 90)
        t.tick(at(1_000))                                                         // a long gap can't overshoot the plan
        #expect(t.phase == .finished && t.activeSeconds == 100 && t.remainingSeconds == 0)
        t.tick(at(2_000)); #expect(t.activeSeconds == 100 && t.pausedSeconds == 60)   // finished timers stop counting
    }

    @Test func sleepIsNotFocusButBackgroundingIs() {
        var t = FocusTimer(kind: .work, plannedSeconds: 3_600, now: t0)
        t.tick(at(600))                                                           // app in the background but awake: counts
        #expect(t.activeSeconds == 600)
        t.willSleep(at(600)); t.didWake(at(4_200))                                // lid closed for an hour
        #expect(t.activeSeconds == 600 && t.pausedSeconds == 3_600 && t.phase == .running)
        t.tick(at(4_260)); #expect(t.activeSeconds == 660)
    }

    @Test func stopAndRemainingNeverNegative() {
        var t = FocusTimer(kind: .shortBreak, plannedSeconds: 300, now: t0)
        t.tick(at(120)); t.stop(at(120))
        #expect(t.phase == .stopped && !t.isActive && t.activeSeconds == 120)
        t.resume(at(500)); #expect(t.phase == .stopped)
        #expect(FocusTimer(kind: .work, plannedSeconds: 0, now: t0).plannedSeconds == 1)
    }

    @Test func settingsAndCycle() {
        var s = FocusSettings()
        #expect(s.seconds(.work) == 1_500 && s.seconds(.shortBreak) == 300 && s.seconds(.longBreak) == 900)
        s.focusMinutes = 45; #expect(s.seconds(.work) == 2_700)
        s.focusMinutes = 9_999; #expect(s.seconds(.work) == 240 * 60)             // clamped
        #expect(FocusSettings.presets == [15, 25, 45])
        #expect([1, 2, 3, 4, 8].map { s.next(after: .work, completedFocusCount: $0) } == [.shortBreak, .shortBreak, .shortBreak, .longBreak, .longBreak])
        #expect(s.next(after: .shortBreak, completedFocusCount: 4) == .work && s.next(after: .longBreak, completedFocusCount: 4) == .work)
    }

    @Test func serviceRecordsHeartbeatsRecoversAndNeverCreatesLearningEvidence() throws {
        let dir = try tempDir(); let path = dir.appendingPathComponent("f.sqlite")
        let rig = try Rig(db: try AppDatabase.open(at: path))
        let svc = FocusService(db: rig.db)
        var timer = FocusTimer(kind: .work, plannedSeconds: 1_500, now: t0)
        let iv = try svc.begin(timer, courseId: rig.course.id)
        timer.tick(at(600)); try svc.save(iv.id, timer: timer, now: at(600))
        // App is quit here. On the next launch the open interval is closed as interrupted at its last heartbeat.
        let reopened = FocusService(db: try AppDatabase.open(at: path))
        #expect(try reopened.recoverInterrupted() == 1 && (try reopened.recoverInterrupted()) == 0)
        let got = try #require(try reopened.intervals().first)
        #expect(got.endState == "interrupted" && got.activeSeconds == 600 && got.endedAt == at(600))

        var done = FocusTimer(kind: .work, plannedSeconds: 60, now: t0)
        let iv2 = try reopened.begin(done); done.tick(at(61)); try reopened.save(iv2.id, timer: done, now: at(61))
        var brk = FocusTimer(kind: .shortBreak, plannedSeconds: 60, now: t0)
        let iv3 = try reopened.begin(brk); brk.tick(at(61)); try reopened.save(iv3.id, timer: brk, now: at(61))
        #expect(try reopened.intervals().filter { $0.endState == "completed" }.count == 2)
        #expect(try reopened.focusSeconds(since: t0.addingTimeInterval(-10)) == 660)    // work only: 600 + 60, the break is excluded
        #expect(try reopened.completedFocusCountToday(now: at(100)) == 1)
        // Focus time is a record, nothing more: no evidence, XP, or mastery.
        #expect(try rig.db.read { try LearningEvidence.fetchCount($0) + XPEvent.fetchCount($0) } == 0)
        #expect(try rig.prog.mastery(skillId: rig.skillA.id).isUnknown)
        // Saving after an interval ended changes nothing.
        done.tick(at(500)); try reopened.save(iv2.id, timer: done, now: at(500))
        #expect(try reopened.intervals().first { $0.id == iv2.id }?.updatedAt == at(61))
    }
}

@Suite struct InsightsTests {
    @Test func studyHistoryAttemptsSessionsForecastAndExams() throws {
        let rig = try Rig()
        let ins = InsightsService(db: rig.db)
        let fin = try rig.courses.addAssessment(courseId: rig.course.id, name: "Final", deadline: Date().addingTimeInterval(6 * 86_400 + 3_600), isCumulative: true)
        let q = try rig.numeric("N", skill: rig.skillA), sa = try rig.shortAnswer("S", skill: rig.skillA)
        // No evidence yet: honest wording, no grade predictions.
        let before = try ins.exams(courseId: rig.course.id)
        #expect(before.count == 1 && before[0].summary.contains("Not enough evidence") && before[0].daysLeft == 7)

        let s = try rig.practice.start(questionIds: [q.id, sa.id], title: "Mix", courseId: rig.course.id)
        let items = try rig.practice.items(sessionId: s.id)
        try rig.practice.addActiveSeconds(itemId: items[0].id, 90)
        var r1 = PracticeResponse(); r1.text = "14"; var r2 = PracticeResponse(); r2.text = "wrong"
        let a1 = try rig.practice.submit(itemId: items[0].id, response: r1), a2 = try rig.practice.submit(itemId: items[1].id, response: r2)
        _ = try rig.eval.evaluate(attemptId: a1.id); _ = try rig.eval.evaluate(attemptId: a2.id)

        let days = try ins.studyDays(courseId: rig.course.id, days: 7)
        #expect(days.count == 7 && days.last!.attempts == 2 && days.last!.minutes == 1.5 && days.dropLast().allSatisfy { $0.attempts == 0 })
        let rows = try ins.sessions(courseId: rig.course.id)
        #expect(rows.count == 1 && rows[0].answered == 2 && rows[0].graded == 2 && rows[0].correct == 1 && rows[0].xp > 0 && rows[0].minutes == 1.5)
        let att = try ins.attempts(courseId: rig.course.id)
        #expect(att.map(\.attempt.id) == [a2.id, a1.id] && att[1].evaluation?.isCorrect == true && att[1].xp > 0)
        let ex = try ins.exams(courseId: rig.course.id)[0]
        #expect(ex.progress.assessedSkillCount == 1 && ex.summary.contains("1 of 2") && !ex.summary.lowercased().contains("grade") && fin.id == ex.id)

        // The short answer is a reviewable card: it shows up in the due forecast once its interval elapses.
        let st = try #require(try rig.reviews.state(questionId: sa.id))
        let fc = try ins.forecast(courseId: rig.course.id, days: 3, now: st.due.addingTimeInterval(60))
        #expect(fc.count == 3 && fc[0].due == 1)
        #expect(try ins.forecast(courseId: rig.course.id, days: 3, now: st.due.addingTimeInterval(-3_600 * 24 * 40)).allSatisfy { $0.due == 0 })
    }

    @Test func trendsXPLedgerAndTimeline() throws {
        let rig = try Rig()
        let ins = InsightsService(db: rig.db)
        let q1 = try rig.numeric("First", skill: rig.skillA), q2 = try rig.numeric("Second", skill: rig.skillA)
        let a1 = try rig.answerNumeric(q1, correct: false)
        try rig.answerNumeric(q2, correct: true)                                   // success on a different question after a miss
        try rig.history.addReflection(courseId: rig.course.id, text: "Check the units", attemptId: a1.id)
        let trend = try ins.skillTrend(skillId: rig.skillA.id)
        #expect(trend.count == 2 && trend[0].overall == 0 && trend[1].overall! > 0 && trend[1].weight > trend[0].weight)
        let xp = try ins.xpTrend(courseId: rig.course.id)
        #expect(xp.last?.total == (try rig.prog.courseXP(rig.course.id).xp))
        let tl = try ins.timeline(courseId: rig.course.id)
        let kinds = Set(tl.map(\.kind))
        #expect(kinds.isSuperset(of: [.mistake, .reflection, .breakthrough, .milestone]))
        #expect(tl.map(\.at) == tl.map(\.at).sorted(by: >))
        #expect(tl.first { $0.kind == .reflection }?.detail == "Check the units")
        #expect(try rig.prog.mastery(skillId: rig.skillB.id).isUnknown && (try ins.skillTrend(skillId: rig.skillB.id)).isEmpty)
    }

    @Test func skillGraphLayout() throws {
        let rig = try Rig()
        let c = rig.course.id
        let java = try rig.courses.addSkill(courseId: c, name: "Java").skill
        let it = try rig.courses.addSkill(courseId: c, name: "Iterators", parentId: java.id).skill
        let gen = try rig.courses.addSkill(courseId: c, name: "Generics", parentId: java.id).skill
        let leaf = try rig.courses.addSkill(courseId: c, name: "Bounded types", parentId: gen.id).skill
        try rig.courses.addRelation(from: rig.skillB.id, to: it.id, kind: .prerequisite)
        let skills = try rig.courses.skills(courseId: c), rels = try rig.courses.relations(courseId: c)
        let g = SkillGraphLayout.layout(skills: skills, relations: rels)
        #expect(g.nodes.count == skills.count && Set(g.nodes.map(\.id)).count == skills.count)
        let byName = Dictionary(uniqueKeysWithValues: g.nodes.map { ($0.name, $0) })
        #expect(byName["Java"]!.depth == 0 && byName["Iterators"]!.depth == 1 && byName["Bounded types"]!.depth == 2)
        #expect(byName["Iterators"]!.x == SkillGraphLayout.columnWidth && byName["Bounded types"]!.x == 2 * SkillGraphLayout.columnWidth)
        #expect(Set(g.nodes.map(\.y)).count == g.nodes.count)                                 // no two nodes share a row
        #expect(g.edges.contains(SkillEdge(from: java.id, to: it.id, kind: .hierarchy)) && g.edges.contains(SkillEdge(from: rig.skillB.id, to: it.id, kind: .prerequisite)))
        #expect(SkillGraphLayout.layout(skills: skills, relations: rels).nodes == g.nodes)    // deterministic
        // Collapsing a branch hides its descendants and says so.
        let c1 = SkillGraphLayout.layout(skills: skills, relations: rels, collapsed: [gen.id])
        #expect(!c1.nodes.contains { $0.id == leaf.id } && c1.nodes.first { $0.id == gen.id }!.hasHiddenChildren)
        #expect(!c1.edges.contains { $0.to == leaf.id })
        let c2 = SkillGraphLayout.layout(skills: skills, relations: rels, collapsed: [java.id])
        #expect(Set(c2.nodes.map(\.name)) == ["Java", "Java iterators", "Recursion"])
    }
}

@Suite struct BackupTests {
    struct World { let rig: Rig; let storage: ManagedStorage; let dir: URL; let doc: Document; let q: Question; let attempt: Attempt }

    func world() throws -> World {
        let dir = try tempDir()
        let storage = ManagedStorage(root: dir.appendingPathComponent("storage"))
        let rig = try Rig(db: try AppDatabase.open(at: dir.appendingPathComponent("live.sqlite")))
        let docs = DocumentService(db: rig.db, storage: storage)
        let pdf = dir.appendingPathComponent("lecture.pdf"); makePDF(pages: ["Iterators produce elements lazily one at a time"], at: pdf)
        let doc = try docs.importFile(at: pdf, courseId: rig.course.id).document
        let q = try rig.numeric("Backed up", skill: rig.skillA)
        let a = try rig.answerNumeric(q, correct: true)
        let fc = try rig.shortAnswer("Card", skill: rig.skillA); _ = try rig.eval.evaluate(attemptId: try rig.attempt(fc, text: "hasNext").id)
        return World(rig: rig, storage: storage, dir: dir, doc: doc, q: q, attempt: a)
    }

    func snapshot(_ db: AppDatabase) throws -> [String: Int] {
        try db.read { d in
            var r: [String: Int] = [:]
            for t in ["courses", "skills", "documents", "document_chunks", "questions", "question_revisions", "attempts", "evaluations", "learning_evidence", "xp_events", "review_states", "milestones", "skill_estimates"] {
                r[t] = try Int.fetchOne(d, sql: "SELECT COUNT(*) FROM \(t)")
            }
            r["xpSum"] = try Int.fetchOne(d, sql: "SELECT COALESCE(SUM(amount),0) FROM xp_events")
            return r
        }
    }

    @Test func roundTripRestoresEverythingIntoAFreshInstall() throws {
        let w = try world()
        let backup = try BackupService(db: w.rig.db, storage: w.storage).create(in: w.dir.appendingPathComponent("backups"))
        let m = backup.manifest
        #expect(m.format == 1 && m.counts["questions"] == 2 && m.counts["attempts"] == 2 && m.files.count == 1 && m.missingFiles.isEmpty)
        #expect(m.files[0].path == w.doc.storedPath && m.files[0].sha256 == w.doc.sha256 && m.database.bytes > 0)
        #expect(!(try String(contentsOf: backup.url.appendingPathComponent("manifest.json"), encoding: .utf8)).lowercased().contains("password"))

        let fresh = try AppDatabase.open(at: w.dir.appendingPathComponent("fresh.sqlite"))
        let freshStorage = ManagedStorage(root: w.dir.appendingPathComponent("fresh-storage"))
        try FileManager.default.createDirectory(at: freshStorage.root, withIntermediateDirectories: true)
        let restored = try BackupService(db: fresh, storage: freshStorage).restore(from: backup.url, safetyBackupIn: nil)
        #expect(restored.database == m.database && restored.files == m.files && restored.counts == m.counts && restored.migrations == m.migrations)
        #expect(try snapshot(fresh) == (try snapshot(w.rig.db)))
        let prog = ProgressionService(db: fresh)
        #expect(try prog.courseXP(w.rig.course.id) == (try w.rig.prog.courseXP(w.rig.course.id)))
        #expect(try prog.mastery(skillId: w.rig.skillA.id).overall == (try w.rig.prog.mastery(skillId: w.rig.skillA.id).overall))
        #expect(try EvaluationService(db: fresh).result(attemptId: w.attempt.id)?.evaluation.score == 1)
        #expect(try ReviewService(db: fresh).logs(questionId: try fresh.read { try Question.filter(Column("type") == QuestionType.shortAnswer).fetchOne($0)!.id }).count == 1)
        // The original PDF came back byte for byte, and the DB's integrity triggers survived.
        let orig = try Data(contentsOf: w.storage.url(forStoredPath: w.doc.storedPath)), back = try Data(contentsOf: freshStorage.url(forStoredPath: w.doc.storedPath))
        #expect(orig == back)
        #expect(throws: DatabaseError.self) { try fresh.write { try $0.execute(sql: "UPDATE attempts SET response = '{}'") } }
        #expect(try fresh.read { try Int.fetchOne($0, sql: "PRAGMA foreign_keys") } == 1)            // still enforced after the swap
        #expect(try QuestionService(db: fresh).list().count == 2)
    }

    @Test func restoreReplacesCurrentDataAfterASafetyBackup() throws {
        let w = try world()
        let svc = BackupService(db: w.rig.db, storage: w.storage)
        let backup = try svc.create(in: w.dir.appendingPathComponent("b"))
        // Later work that the restore will discard…
        _ = try w.rig.courses.createCourse(name: "Created after the backup")
        #expect(try w.rig.courses.courses().count == 2)
        let safety = w.dir.appendingPathComponent("safety")
        try svc.restore(from: backup.url, safetyBackupIn: safety)
        #expect(try w.rig.courses.courses().count == 1)
        // …but a safety copy of it was kept and can be restored.
        let copies = try FileManager.default.contentsOfDirectory(at: safety, includingPropertiesForKeys: nil)
        #expect(copies.count == 1)
        try svc.restore(from: copies[0], safetyBackupIn: nil)
        #expect(try w.rig.courses.courses().map(\.name).contains("Created after the backup"))
    }

    @Test func damagedOrMaliciousBackupsAreRejectedBeforeAnythingChanges() throws {
        let w = try world()
        let svc = BackupService(db: w.rig.db, storage: w.storage)
        let before = try snapshot(w.rig.db)
        func fresh() throws -> URL {
            let r = try svc.create(in: w.dir.appendingPathComponent("bad-\(UUID().uuidString.prefix(6))")); return r.url
        }
        func edit(_ url: URL, _ f: (inout BackupManifest) -> Void) throws {
            let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
            var m = try dec.decode(BackupManifest.self, from: Data(contentsOf: url.appendingPathComponent("manifest.json"))); f(&m)
            let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601
            try enc.encode(m).write(to: url.appendingPathComponent("manifest.json"))
        }
        func rejected(_ url: URL, _ err: BackupError) throws {
            #expect(throws: err) { try svc.restore(from: url, safetyBackupIn: nil) }
            #expect(try snapshot(w.rig.db) == before)                                              // live data untouched
        }
        // tampered database / document
        var u = try fresh()
        try Data("tamper".utf8).write(to: u.appendingPathComponent("database.sqlite"))
        try rejected(u, .hashMismatch("database.sqlite"))
        u = try fresh()
        try Data("tamper".utf8).write(to: u.appendingPathComponent(w.doc.storedPath))
        try rejected(u, .hashMismatch(w.doc.storedPath))
        // path traversal, absolute paths, hidden files, outside Documents/
        for bad in ["Documents/../../evil.txt", "/etc/passwd", "Documents/x/../y", "Documents/.hidden/a", "other/file.txt", "Documents/a\\b/c"] {
            u = try fresh()
            try edit(u) { $0.files.append(.init(path: bad, sha256: "00", bytes: 0)) }
            try rejected(u, .unsafePath(bad))
        }
        // symlink posing as a document
        u = try fresh()
        let link = u.appendingPathComponent(w.doc.storedPath)
        try FileManager.default.removeItem(at: link)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: w.dir.appendingPathComponent("lecture.pdf"))
        try rejected(u, .unsafePath(w.doc.storedPath))
        // missing file, newer schema, wrong format, not a backup, garbage manifest
        u = try fresh(); try FileManager.default.removeItem(at: u.appendingPathComponent(w.doc.storedPath))
        try rejected(u, .missingFile(w.doc.storedPath))
        u = try fresh(); try edit(u) { $0.migrations.append("v99_from_the_future") }
        try rejected(u, .newerThanApp)
        u = try fresh(); try edit(u) { $0.format = 7 }
        try rejected(u, .unsupportedFormat(7))
        try rejected(w.dir, .notABackup)
        u = try fresh(); try Data("{ nope".utf8).write(to: u.appendingPathComponent("manifest.json"))
        try rejected(u, .notABackup)
        // nothing was left behind in managed storage
        #expect(!(try FileManager.default.contentsOfDirectory(atPath: w.storage.root.path)).contains { $0.hasPrefix(".restore-staging") })
    }

    @Test func missingOriginalsAreReportedNotFatalAndBackupsNeverHalfExist() throws {
        let w = try world()
        try FileManager.default.removeItem(at: w.storage.url(forStoredPath: w.doc.storedPath))
        let b = try BackupService(db: w.rig.db, storage: w.storage).create(in: w.dir.appendingPathComponent("m"))
        #expect(b.manifest.missingFiles == [w.doc.storedPath] && b.manifest.files.isEmpty)
        // A failure part-way leaves no folder behind (unsafe stored path aborts the backup).
        try w.rig.db.write { try $0.execute(sql: "UPDATE documents SET storedPath = '../escape'") }
        let parent = w.dir.appendingPathComponent("n")
        #expect(throws: BackupError.unsafePath("../escape")) { try BackupService(db: w.rig.db, storage: w.storage).create(in: parent) }
        #expect((try? FileManager.default.contentsOfDirectory(atPath: parent.path))?.isEmpty ?? true)
    }

    /// A backup made by an older release (schema v1–v6, no review/focus tables) restores and is migrated forward.
    @Test func olderSchemaBackupRestoresAndMigratesForward() throws {
        let dir = try tempDir()
        let backup = dir.appendingPathComponent("old.braincellbackup")
        try FileManager.default.createDirectory(at: backup, withIntermediateDirectories: true)
        // Build a genuine v6 database holding a course and a skill.
        let oldPath = backup.appendingPathComponent("database.sqlite")
        let old = try DatabaseQueue(path: oldPath.path, configuration: AppDatabase.configuration)
        try AppDatabase.migrator.migrate(old, upTo: "v6_progression")
        let course = Course(id: UUID(), name: "Written by an old release", kind: .structured, createdAt: Date(), archivedAt: nil)
        try old.write { try course.insert($0) }
        #expect(try old.read { try !$0.tableExists("review_states") && !$0.tableExists("focus_intervals") && $0.tableExists("evaluations") })
        try old.writeWithoutTransaction { try $0.execute(sql: "PRAGMA journal_mode = DELETE") }
        try old.close()
        let known = AppDatabase.migrator.migrations
        let upTo = Array(known.prefix(through: known.firstIndex(of: "v6_progression")!))
        let manifest = BackupManifest(format: 1, createdAt: Date(), app: "Braincell 0.0.1", migrations: upTo,
                                      database: try BackupService.entry(oldPath, path: "database.sqlite"), files: [], missingFiles: [], counts: [:])
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601
        try enc.encode(manifest).write(to: backup.appendingPathComponent("manifest.json"))

        // Restore into a current (v9) installation that already holds unrelated data.
        let storage = ManagedStorage(root: dir.appendingPathComponent("storage"))
        try FileManager.default.createDirectory(at: storage.root, withIntermediateDirectories: true)
        let live = try AppDatabase.open(at: dir.appendingPathComponent("live.sqlite"))
        _ = try CourseService(db: live).createCourse(name: "Current data to be replaced")
        try BackupService(db: live, storage: storage).restore(from: backup, safetyBackupIn: dir.appendingPathComponent("safety"))

        #expect(try CourseService(db: live).courses().map(\.name) == ["Written by an old release"])
        #expect(try live.read { try Set(AppDatabase.migrator.appliedIdentifiers($0)) } == Set(known))      // brought fully up to date
        #expect(try live.read { try $0.tableExists("review_states") && $0.tableExists("focus_intervals") && $0.tableExists("ai_batch_attempts") })
        // …and the new tables are usable straight away.
        let t = FocusTimer(kind: .work, plannedSeconds: 60, now: Date())
        _ = try FocusService(db: live).begin(t)
        #expect(try FocusService(db: live).intervals().count == 1)
        #expect(try live.read { try Int.fetchOne($0, sql: "PRAGMA foreign_keys") } == 1)
        // The safety copy of what was replaced is itself a valid backup.
        let safety = try FileManager.default.contentsOfDirectory(at: dir.appendingPathComponent("safety"), includingPropertiesForKeys: nil)
        #expect(safety.count == 1 && (try? BackupService.validate(at: safety[0])) != nil)
    }
}

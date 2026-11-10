import Foundation
import GRDB

/// Owns the SQLite connection and the migration history. Foreign keys are enforced.
public final class AppDatabase: Sendable {
    public let writer: any DatabaseWriter

    public init(_ writer: any DatabaseWriter) throws {
        self.writer = writer
        try Self.migrator.migrate(writer)
    }

    public static func open(at url: URL) throws -> AppDatabase {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        return try AppDatabase(DatabasePool(path: url.path, configuration: configuration))
    }

    public static func inMemory() throws -> AppDatabase {
        try AppDatabase(DatabaseQueue(configuration: configuration))
    }

    static var configuration: Configuration {
        var c = Configuration()
        c.foreignKeysEnabled = true
        return c
    }

    public func read<T>(_ block: (Database) throws -> T) throws -> T { try writer.read(block) }
    public func write<T>(_ block: (Database) throws -> T) throws -> T { try writer.write(block) }

    /// Migrations are append-only. Never edit a shipped migration; add a new one.
    /// `upTo` lets tests exercise upgrade paths.
    static func migrator(upTo: String? = nil) -> DatabaseMigrator {
        var m = DatabaseMigrator()

        m.registerMigration("v1_foundation") { db in
            try db.create(table: "settings") { t in
                t.primaryKey("key", .text)
                t.column("value", .text).notNull()
                t.column("updatedAt", .datetime).notNull()
            }
            try db.create(table: "courses") { t in
                t.primaryKey("id", .blob)
                t.column("name", .text).notNull().check { length($0) > 0 }
                t.column("kind", .text).notNull().check { ["structured", "quickCram"].contains($0) }
                t.column("createdAt", .datetime).notNull()
                t.column("archivedAt", .datetime)
            }
            try db.create(table: "assessments") { t in
                t.primaryKey("id", .blob)
                t.belongsTo("course", inTable: "courses", onDelete: .cascade).notNull()
                t.column("name", .text).notNull().check { length($0) > 0 }
                t.column("kind", .text).notNull()
                t.column("deadline", .datetime)
                t.column("isCumulative", .boolean).notNull().defaults(to: false)
                t.column("importance", .double).check { $0 == nil || ($0 >= 0 && $0 <= 1) }
                t.column("importanceSource", .text).notNull().defaults(to: "unset")
                t.column("sortOrder", .integer).notNull().defaults(to: 0)
                t.column("createdAt", .datetime).notNull()
            }

            try db.create(table: "skills") { t in
                t.primaryKey("id", .blob)
                t.column("name", .text).notNull().check { length($0) > 0 }
                t.column("normalizedName", .text).notNull()
                t.column("summary", .text).notNull().defaults(to: "")
                t.column("createdAt", .datetime).notNull()
                t.column("archivedAt", .datetime)
            }
            try db.create(index: "skills_on_normalizedName", on: "skills", columns: ["normalizedName"])

            try db.create(table: "course_skills") { t in
                t.column("courseId", .blob).notNull().references("courses", onDelete: .cascade)
                t.column("skillId", .blob).notNull().references("skills", onDelete: .cascade)
                t.primaryKey(["courseId", "skillId"])
            }
            try db.create(index: "course_skills_on_skillId", on: "course_skills", columns: ["skillId"])

            try db.create(table: "assessment_skills") { t in
                t.column("assessmentId", .blob).notNull().references("assessments", onDelete: .cascade)
                t.column("skillId", .blob).notNull().references("skills", onDelete: .cascade)
                t.column("importance", .double).check { $0 == nil || ($0 >= 0 && $0 <= 1) }
                t.column("importanceSource", .text).notNull().defaults(to: "unset")
                t.primaryKey(["assessmentId", "skillId"])
            }
            try db.create(index: "assessment_skills_on_skillId", on: "assessment_skills", columns: ["skillId"])

            try db.create(table: "skill_relations") { t in
                t.primaryKey("id", .blob)
                t.column("fromSkillId", .blob).notNull().references("skills", onDelete: .cascade)
                t.column("toSkillId", .blob).notNull().references("skills", onDelete: .cascade)
                t.column("kind", .text).notNull().check { ["hierarchy", "prerequisite", "related"].contains($0) }
                t.check(Column("fromSkillId") != Column("toSkillId"))
                t.uniqueKey(["fromSkillId", "toSkillId", "kind"])
            }
            try db.create(index: "skill_relations_on_toSkillId", on: "skill_relations", columns: ["toSkillId"])
        }

        m.registerMigration("v2_materials") { db in
            try db.create(table: "documents") { t in
                t.primaryKey("id", .blob)
                t.column("courseId", .blob).notNull().references("courses", onDelete: .cascade)
                t.column("title", .text).notNull()
                t.column("originalFilename", .text).notNull()
                t.column("storedPath", .text).notNull()
                t.column("sha256", .text).notNull()
                t.column("byteCount", .integer).notNull()
                t.column("kind", .text).notNull()
                t.column("pageCount", .integer)
                t.column("extractionStatus", .text).notNull()
                t.column("extractionMethod", .text).notNull()
                t.column("lowContentPageCount", .integer).notNull().defaults(to: 0)
                t.column("importedAt", .datetime).notNull()
                // Re-importing identical bytes into the same course is a no-op.
                t.uniqueKey(["courseId", "sha256"])
            }
            try db.create(table: "document_chunks") { t in
                t.primaryKey("id", .blob)
                t.column("documentId", .blob).notNull().references("documents", onDelete: .cascade)
                t.column("ordinal", .integer).notNull()
                t.column("pageNumber", .integer)
                t.column("text", .text).notNull()
                t.column("isLowContent", .boolean).notNull().defaults(to: false)
                t.uniqueKey(["documentId", "ordinal"])
            }
            try db.create(table: "document_assessments") { t in
                t.column("documentId", .blob).notNull().references("documents", onDelete: .cascade)
                t.column("assessmentId", .blob).notNull().references("assessments", onDelete: .cascade)
                t.primaryKey(["documentId", "assessmentId"])
            }
        }
        m.registerMigration("v3_questions") { db in
            try db.create(table: "question_families") { t in
                t.primaryKey("id", .blob)
                t.column("title", .text).notNull()
                t.column("createdAt", .datetime).notNull()
            }
            try db.create(table: "questions") { t in
                t.primaryKey("id", .blob)
                t.belongsTo("course", inTable: "courses", onDelete: .cascade).notNull()
                t.column("familyId", .blob).references("question_families", onDelete: .setNull)
                t.column("currentRevisionId", .blob).notNull() // no FK: revision is inserted right after the question
                t.column("type", .text).notNull()
                t.column("readiness", .text).notNull().check { ["verified", "unverified", "needsReview"].contains($0) }
                t.column("verificationSource", .text).notNull().defaults(to: "none")
                t.column("reviewNotes", .text).notNull().defaults(to: "[]")
                t.column("archivedAt", .datetime)
                t.column("createdAt", .datetime).notNull()
            }
            try db.create(index: "questions_on_familyId", on: "questions", columns: ["familyId"])
            try db.create(table: "question_revisions") { t in
                t.primaryKey("id", .blob)
                t.column("questionId", .blob).notNull().references("questions", onDelete: .cascade)
                t.column("number", .integer).notNull()
                t.column("title", .text).notNull()
                t.column("difficulty", .integer).notNull().check { $0 >= 1 && $0 <= 5 }
                t.column("learningObjective", .text).notNull()
                t.column("payload", .text).notNull()
                t.column("contentHash", .text).notNull()
                t.column("origin", .text).notNull()
                t.column("aiImportId", .blob) // provenance only; ai_imports may be pruned independently
                t.column("createdAt", .datetime).notNull()
                t.uniqueKey(["questionId", "number"])
            }
            try db.create(index: "question_revisions_on_contentHash", on: "question_revisions", columns: ["contentHash"])
            // Historical attempts point at revisions, so a revision's content must never change.
            try db.execute(sql: """
                CREATE TRIGGER question_revisions_immutable BEFORE UPDATE ON question_revisions
                BEGIN SELECT RAISE(ABORT, 'question revisions are immutable'); END
                """)
            try db.create(table: "question_skills") { t in
                t.column("questionId", .blob).notNull().references("questions", onDelete: .cascade)
                t.column("skillId", .blob).notNull().references("skills", onDelete: .cascade)
                t.primaryKey(["questionId", "skillId"])
            }
            try db.create(index: "question_skills_on_skillId", on: "question_skills", columns: ["skillId"])
            try db.create(table: "question_assessments") { t in
                t.column("questionId", .blob).notNull().references("questions", onDelete: .cascade)
                t.column("assessmentId", .blob).notNull().references("assessments", onDelete: .cascade)
                t.primaryKey(["questionId", "assessmentId"])
            }
            try db.create(index: "question_assessments_on_assessmentId", on: "question_assessments", columns: ["assessmentId"])
            try db.create(table: "saved_views") { t in
                t.primaryKey("id", .blob)
                t.column("name", .text).notNull()
                t.column("filterJSON", .text).notNull()
                t.column("createdAt", .datetime).notNull()
            }
        }

        m.registerMigration("v4_ai_bridge") { db in
            try db.create(table: "ai_tasks") { t in
                t.primaryKey("id", .blob)
                t.column("kind", .text).notNull()
                t.belongsTo("course", inTable: "courses", onDelete: .cascade).notNull()
                t.column("assessmentId", .blob).references("assessments", onDelete: .setNull)
                t.column("title", .text).notNull()
                t.column("params", .text).notNull()
                t.column("createdAt", .datetime).notNull()
            }
            try db.create(table: "ai_task_batches") { t in
                t.primaryKey("id", .blob)
                t.belongsTo("task", inTable: "ai_tasks", onDelete: .cascade).notNull()
                t.column("parentBatchId", .blob).references("ai_task_batches", onDelete: .setNull)
                t.column("ordinal", .integer).notNull()
                t.column("kind", .text).notNull()
                t.column("requestId", .text).notNull().unique()
                t.column("expectedCount", .integer).notNull()
                t.column("requestText", .text).notNull().defaults(to: "")
                t.column("manifest", .text).notNull().defaults(to: "{}")
                t.column("transferMethod", .text)
                t.column("status", .text).notNull()
                t.column("exportedAt", .datetime)
                t.column("createdAt", .datetime).notNull()
            }
            try db.create(index: "ai_task_batches_on_parentBatchId", on: "ai_task_batches", columns: ["parentBatchId"])
            try db.create(table: "ai_imports") { t in
                t.primaryKey("id", .blob)
                t.column("batchId", .blob).references("ai_task_batches", onDelete: .setNull)
                t.column("responseHash", .text).notNull()
                t.column("rawResponse", .text).notNull()
                t.column("outcome", .text).notNull()
                t.column("returnedCount", .integer).notNull().defaults(to: 0)
                t.column("acceptedCount", .integer).notNull().defaults(to: 0)
                t.column("duplicateCount", .integer).notNull().defaults(to: 0)
                t.column("rejectedCount", .integer).notNull().defaults(to: 0)
                t.column("issues", .text).notNull().defaults(to: "[]")
                t.column("rejectedEntries", .text).notNull().defaults(to: "[]")
                t.column("createdAt", .datetime).notNull()
            }
            try db.create(index: "ai_imports_on_batchId", on: "ai_imports", columns: ["batchId"])
            // The same response can be pasted any number of times but only imported once.
            try db.create(index: "ai_imports_unique_imported", on: "ai_imports", columns: ["responseHash"], unique: true,
                          condition: Column("outcome") == "imported")
        }
        m.registerMigration("v5_practice") { db in
            try db.create(table: "study_sessions") { t in
                t.primaryKey("id", .blob)
                t.column("courseId", .blob).references("courses", onDelete: .cascade)
                t.column("assessmentId", .blob).references("assessments", onDelete: .setNull)
                t.column("title", .text).notNull()
                t.column("status", .text).notNull()
                t.column("currentOrdinal", .integer).notNull().defaults(to: 0)
                t.column("startedAt", .datetime).notNull()
                t.column("updatedAt", .datetime).notNull()
                t.column("completedAt", .datetime)
            }
            try db.create(table: "session_items") { t in
                t.primaryKey("id", .blob)
                t.column("sessionId", .blob).notNull().references("study_sessions", onDelete: .cascade)
                t.column("ordinal", .integer).notNull()
                t.column("questionId", .blob).notNull().references("questions", onDelete: .restrict)
                t.column("revisionId", .blob).notNull().references("question_revisions", onDelete: .restrict)
                t.column("status", .text).notNull()
                t.column("hintsUsed", .integer).notNull().defaults(to: 0)
                t.column("activeSeconds", .integer).notNull().defaults(to: 0)
                t.uniqueKey(["sessionId", "ordinal"])
            }
            try db.create(index: "session_items_on_questionId", on: "session_items", columns: ["questionId"])
            try db.create(table: "attempt_drafts") { t in
                t.primaryKey("sessionItemId", .blob).references("session_items", onDelete: .cascade)
                t.column("response", .text).notNull()
                t.column("updatedAt", .datetime).notNull()
            }
            try db.create(table: "attempts") { t in
                t.primaryKey("id", .blob)
                // One submission per planned item; the item row is the identity of "this try".
                t.column("sessionItemId", .blob).notNull().unique().references("session_items", onDelete: .restrict)
                t.column("questionId", .blob).notNull().references("questions", onDelete: .restrict)
                t.column("revisionId", .blob).notNull().references("question_revisions", onDelete: .restrict)
                t.column("response", .text).notNull()
                t.column("hintsUsed", .integer).notNull()
                t.column("activeSeconds", .integer).notNull()
                t.column("submittedAt", .datetime).notNull()
            }
            try db.create(index: "attempts_on_questionId", on: "attempts", columns: ["questionId"])
            try db.execute(sql: """
                CREATE TRIGGER attempts_immutable BEFORE UPDATE ON attempts
                BEGIN SELECT RAISE(ABORT, 'attempts are immutable'); END
                """)
        }
        m.registerMigration("v6_progression") { db in
            try db.create(table: "evaluations") { t in
                t.primaryKey("id", .blob)
                t.column("attemptId", .blob).notNull().references("attempts", onDelete: .restrict)
                t.column("revisionId", .blob).notNull().references("question_revisions", onDelete: .restrict)
                t.column("method", .text).notNull()
                t.column("source", .text).notNull()
                t.column("state", .text).notNull()
                t.column("score", .double).check { $0 == nil || ($0 >= 0 && $0 <= 1) }
                t.column("trust", .text).notNull()
                t.column("feedback", .text).notNull().defaults(to: "")
                t.column("detail", .text).notNull().defaults(to: "{}")
                t.column("reason", .text).notNull().defaults(to: "")
                t.column("supersedesId", .blob).references("evaluations", onDelete: .restrict)
                t.column("supersededAt", .datetime)
                t.column("batchId", .blob) // AI grading batch, provenance only
                t.column("createdAt", .datetime).notNull()
            }
            // Exactly one current evaluation per attempt; older ones stay as history.
            try db.create(index: "evaluations_one_active", on: "evaluations", columns: ["attemptId"], unique: true,
                          condition: Column("supersededAt") == nil)
            try db.create(index: "evaluations_on_attemptId", on: "evaluations", columns: ["attemptId"])

            try db.create(table: "learning_evidence") { t in
                t.primaryKey("id", .blob)
                t.column("evaluationId", .blob).notNull().references("evaluations", onDelete: .restrict)
                t.column("attemptId", .blob).notNull().references("attempts", onDelete: .restrict)
                t.column("questionId", .blob).notNull().references("questions", onDelete: .restrict)
                t.column("revisionId", .blob).notNull().references("question_revisions", onDelete: .restrict)
                t.column("skillId", .blob).notNull().references("skills", onDelete: .restrict)
                t.column("courseId", .blob).notNull().references("courses", onDelete: .restrict)
                t.column("dimension", .text).notNull()
                t.column("score", .double).notNull().check { $0 >= 0 && $0 <= 1 }
                t.column("difficulty", .integer).notNull()
                t.column("hintsUsed", .integer).notNull()
                t.column("attemptNumber", .integer).notNull()
                t.column("trust", .text).notNull()
                t.column("occurredAt", .datetime).notNull()
                t.column("supersededAt", .datetime)
                t.uniqueKey(["evaluationId", "skillId"])
            }
            try db.create(index: "learning_evidence_on_skillId", on: "learning_evidence", columns: ["skillId"])
            try db.create(index: "learning_evidence_on_questionId", on: "learning_evidence", columns: ["questionId"])

            try db.create(table: "xp_events") { t in
                t.primaryKey("id", .blob)
                t.column("eventKey", .text).notNull().unique()
                t.column("subject", .text).notNull()
                t.column("courseId", .blob).notNull().references("courses", onDelete: .restrict)
                t.column("attemptId", .blob).references("attempts", onDelete: .restrict)
                t.column("kind", .text).notNull()
                t.column("reason", .text).notNull()
                t.column("amount", .integer).notNull()
                t.column("createdAt", .datetime).notNull()
            }
            try db.create(index: "xp_events_on_subject", on: "xp_events", columns: ["subject"])
            try db.create(index: "xp_events_on_courseId", on: "xp_events", columns: ["courseId"])
            try db.create(table: "xp_event_skills") { t in
                t.column("eventId", .blob).notNull().references("xp_events", onDelete: .cascade)
                t.column("skillId", .blob).notNull().references("skills", onDelete: .restrict)
                t.column("amount", .integer).notNull()
                t.primaryKey(["eventId", "skillId"])
            }
            try db.create(index: "xp_event_skills_on_skillId", on: "xp_event_skills", columns: ["skillId"])

            try db.create(table: "skill_estimates") { t in
                t.primaryKey("id", .blob)
                t.column("skillId", .blob).notNull().references("skills", onDelete: .restrict)
                t.column("computedAt", .datetime).notNull()
                t.column("dimensions", .text).notNull()
                t.column("overall", .double)
                t.column("overallWeight", .double).notNull()
                t.column("evidenceCount", .integer).notNull()
                t.column("estimatorVersion", .text).notNull()
                t.column("causeEvaluationId", .blob)
            }
            try db.create(index: "skill_estimates_on_skillId", on: "skill_estimates", columns: ["skillId", "computedAt"])

            try db.create(table: "milestones") { t in
                t.primaryKey("id", .blob)
                t.column("key", .text).notNull().unique()
                t.column("title", .text).notNull()
                t.column("courseId", .blob).references("courses", onDelete: .restrict)
                t.column("skillId", .blob).references("skills", onDelete: .restrict)
                t.column("achievedAt", .datetime).notNull()
            }
        }

        m.registerMigration("v7_ai_grading") { db in
            // Which attempts a grading batch asks ChatGPT to grade. Responses may only grade these.
            try db.create(table: "ai_batch_attempts") { t in
                t.column("batchId", .blob).notNull().references("ai_task_batches", onDelete: .cascade)
                t.column("attemptId", .blob).notNull().references("attempts", onDelete: .restrict)
                t.primaryKey(["batchId", "attemptId"])
            }
        }
        m.registerMigration("v8_adaptive") { db in
            try db.create(table: "review_states") { t in
                t.primaryKey("questionId", .blob).references("questions", onDelete: .cascade)
                t.column("state", .integer).notNull()
                t.column("step", .integer)
                t.column("stability", .double)
                t.column("difficulty", .double)
                t.column("due", .datetime).notNull()
                t.column("lastReview", .datetime)
                t.column("reps", .integer).notNull().defaults(to: 0)
                t.column("lapses", .integer).notNull().defaults(to: 0)
                t.column("schedulerVersion", .text).notNull()
                t.column("parameters", .text).notNull()
                t.column("updatedAt", .datetime).notNull()
            }
            try db.create(index: "review_states_on_due", on: "review_states", columns: ["due"])
            try db.create(table: "review_logs") { t in
                t.primaryKey("id", .blob)
                t.column("questionId", .blob).notNull().references("questions", onDelete: .cascade)
                // One review per graded attempt: replays and regrades never schedule twice.
                t.column("attemptId", .blob).notNull().unique().references("attempts", onDelete: .restrict)
                t.column("rating", .integer).notNull().check { $0 >= 1 && $0 <= 4 }
                t.column("reviewedAt", .datetime).notNull()
                t.column("stateBefore", .integer)
                t.column("stateAfter", .integer).notNull()
                t.column("stabilityAfter", .double)
                t.column("difficultyAfter", .double)
                t.column("dueAfter", .datetime).notNull()
                t.column("schedulerVersion", .text).notNull()
            }
            try db.create(index: "review_logs_on_questionId", on: "review_logs", columns: ["questionId", "reviewedAt"])

            try db.create(table: "learning_reflections") { t in
                t.primaryKey("id", .blob)
                t.column("courseId", .blob).notNull().references("courses", onDelete: .cascade)
                t.column("sessionId", .blob).references("study_sessions", onDelete: .setNull)
                t.column("attemptId", .blob).references("attempts", onDelete: .restrict)
                t.column("skillId", .blob).references("skills", onDelete: .setNull)
                t.column("kind", .text).notNull()           // confidence | reflection
                t.column("level", .integer)                  // confidence 1 guessing … 3 sure
                t.column("text", .text).notNull().defaults(to: "")
                t.column("createdAt", .datetime).notNull()
            }
            try db.create(index: "learning_reflections_on_attemptId", on: "learning_reflections", columns: ["attemptId"])
            try db.create(index: "learning_reflections_on_courseId", on: "learning_reflections", columns: ["courseId", "createdAt"])

            try db.create(table: "coach_events") { t in
                t.primaryKey("id", .blob)
                t.column("sessionId", .blob).notNull().references("study_sessions", onDelete: .cascade)
                t.column("trigger", .text).notNull()
                t.column("subject", .text).notNull().defaults(to: "")
                t.column("message", .text).notNull()
                t.column("shownAt", .datetime).notNull()
                t.column("dismissedAt", .datetime)
                t.column("accepted", .boolean)
            }
            try db.create(index: "coach_events_on_sessionId", on: "coach_events", columns: ["sessionId", "shownAt"])

            try db.alter(table: "study_sessions") { t in
                t.add(column: "mode", .text).notNull().defaults(to: "free")
                t.add(column: "timed", .boolean).notNull().defaults(to: false)
            }
            try db.alter(table: "session_items") { t in
                t.add(column: "kind", .text).notNull().defaults(to: "practice")
                t.add(column: "reason", .text).notNull().defaults(to: "")
            }
        }
        m.registerMigration("v9_focus") { db in
            try db.create(table: "focus_intervals") { t in
                t.primaryKey("id", .blob)
                t.column("kind", .text).notNull().check { ["work", "shortBreak", "longBreak"].contains($0) }
                t.column("plannedSeconds", .integer).notNull().check { $0 > 0 }
                t.column("activeSeconds", .integer).notNull().defaults(to: 0)
                t.column("pausedSeconds", .integer).notNull().defaults(to: 0)
                t.column("startedAt", .datetime).notNull()
                t.column("updatedAt", .datetime).notNull()
                t.column("endedAt", .datetime)
                t.column("endState", .text)            // completed | stopped | interrupted
                t.column("sessionId", .blob).references("study_sessions", onDelete: .setNull)
                t.column("courseId", .blob).references("courses", onDelete: .setNull)
            }
            try db.create(index: "focus_intervals_on_startedAt", on: "focus_intervals", columns: ["startedAt"])
        }
        m.registerMigration("v10_indexes") { db in
            // Found by the scale test: per-attempt XP lookups and date-range scans were table scans.
            try db.create(index: "xp_events_on_attemptId", on: "xp_events", columns: ["attemptId"])
            try db.create(index: "attempts_on_submittedAt", on: "attempts", columns: ["submittedAt"])
            try db.create(index: "evaluations_on_state_active", on: "evaluations", columns: ["state"], condition: Column("supersededAt") == nil)
        }
        m.registerMigration("v11_ai_gateway") { db in
            try db.create(table: "ai_connections") { t in
                t.column("id", .blob).primaryKey()
                t.column("providerId", .text).notNull()
                t.column("name", .text).notNull()
                t.column("baseURL", .text)
                t.column("enabled", .boolean).notNull().defaults(to: true)
                t.column("status", .text).notNull().defaults(to: "configured")
                t.column("lastCheckedAt", .datetime)
                t.column("createdAt", .datetime).notNull()
            }
            try db.create(table: "ai_models") { t in
                t.column("id", .blob).primaryKey()
                t.column("connectionId", .blob).notNull().references("ai_connections", onDelete: .cascade)
                t.column("modelId", .text).notNull()
                t.column("displayName", .text).notNull()
                t.column("capability", .text).notNull()
                t.column("source", .text).notNull()            // discovered | manual
                t.column("inputPricePerM", .double)            // USD per million tokens; nil = unknown
                t.column("outputPricePerM", .double)
                t.column("health", .text).notNull().defaults(to: "untested")   // untested | ready | failed
                t.column("createdAt", .datetime).notNull()
                t.uniqueKey(["connectionId", "modelId", "capability"])
            }
            try db.create(table: "ai_capability_defaults") { t in
                t.column("capability", .text).primaryKey()
                t.column("connectionId", .blob).notNull().references("ai_connections", onDelete: .cascade)
                t.column("modelId", .text).notNull()
            }
            try db.create(table: "ai_task_routes") { t in
                t.column("task", .text).primaryKey()
                t.column("inherit", .boolean).notNull().defaults(to: true)
                t.column("connectionId", .blob).references("ai_connections", onDelete: .setNull)
                t.column("modelId", .text)
                t.column("fallbackConnectionId", .blob).references("ai_connections", onDelete: .setNull)
                t.column("fallbackModelId", .text)
                t.column("maxRetries", .integer).notNull().defaults(to: 1)
                t.column("manualBridge", .boolean).notNull().defaults(to: false)
                t.column("instruction", .text)
                t.column("temperature", .double)
                t.column("maxTokens", .integer)
                t.column("timeoutSeconds", .integer).notNull().defaults(to: 120)
                t.column("updatedAt", .datetime).notNull()
            }
            try db.create(table: "ai_requests") { t in
                t.column("id", .blob).primaryKey()
                t.column("ts", .datetime).notNull()
                t.column("connectionId", .blob)                // no FK: history survives removing a provider
                t.column("providerId", .text).notNull()
                t.column("modelId", .text).notNull()
                t.column("capability", .text).notNull()
                t.column("task", .text).notNull()
                t.column("courseId", .blob)
                t.column("status", .text).notNull()            // success | failed | blocked
                t.column("latencyMs", .integer).notNull()
                t.column("inputTokens", .integer)
                t.column("outputTokens", .integer)
                t.column("cachedTokens", .integer)
                t.column("costMicros", .integer)               // USD millionths; nil = unknown
                t.column("costBasis", .text).notNull()         // estimated | local | unknown
                t.column("errorCategory", .text)
            }
            try db.create(index: "ai_requests_on_ts", on: "ai_requests", columns: ["ts"])
            try db.create(table: "ai_workflow_layout") { t in
                t.column("task", .text).primaryKey()
                t.column("x", .double).notNull()
                t.column("y", .double).notNull()
            }
        }
        m.registerMigration("v12_library") { db in
            // Soft deletion for courses. Study history keeps ON DELETE RESTRICT, so a purge never touches it: it removes materials and folders only.
            try db.execute(sql: "ALTER TABLE courses ADD COLUMN deletedAt DATETIME")
            try db.execute(sql: "ALTER TABLE courses ADD COLUMN purgeAfter DATETIME")
            try db.execute(sql: "ALTER TABLE courses ADD COLUMN archivedByDelete BOOLEAN NOT NULL DEFAULT 0")
            try db.execute(sql: "ALTER TABLE courses ADD COLUMN purgedAt DATETIME")
            try db.create(table: "library_folders") { t in
                t.primaryKey("id", .blob)
                t.column("parentId", .blob).references("library_folders", onDelete: .cascade)
                t.column("courseId", .blob).references("courses", onDelete: .cascade)   // nil = global Library folder
                t.column("name", .text).notNull()
                t.column("favorite", .boolean).notNull().defaults(to: false)
                t.column("createdAt", .datetime).notNull()
                t.column("modifiedAt", .datetime).notNull()
                t.column("deletedAt", .datetime)
                t.column("purgeAfter", .datetime)
                t.column("deletedWith", .blob)                                          // id of the folder deletion that hid this row
            }
            try db.create(index: "library_folders_on_parent", on: "library_folders", columns: ["parentId"])
            try db.create(index: "library_folders_on_course", on: "library_folders", columns: ["courseId"])
            // documents: courseId becomes optional (global Library files) and files gain folder/favorite/deletion fields.
            // SQLite can't relax NOT NULL in place, so rebuild the table; ids and every column are copied, children keep pointing at "documents".
            try db.create(table: "documents_new") { t in
                t.primaryKey("id", .blob)
                t.column("courseId", .blob).references("courses", onDelete: .cascade)
                t.column("folderId", .blob).references("library_folders", onDelete: .setNull)
                t.column("title", .text).notNull()
                t.column("originalFilename", .text).notNull()
                t.column("name", .text).notNull()
                t.column("storedPath", .text).notNull()
                t.column("sha256", .text).notNull()
                t.column("byteCount", .integer).notNull()
                t.column("kind", .text).notNull()
                t.column("pageCount", .integer)
                t.column("extractionStatus", .text).notNull()
                t.column("extractionMethod", .text).notNull()
                t.column("lowContentPageCount", .integer).notNull().defaults(to: 0)
                t.column("importedAt", .datetime).notNull()
                t.column("modifiedAt", .datetime).notNull()
                t.column("favorite", .boolean).notNull().defaults(to: false)
                t.column("deletedAt", .datetime)
                t.column("purgeAfter", .datetime)
                t.column("deletedWith", .blob)
            }
            try db.execute(sql: """
                INSERT INTO documents_new (id, courseId, folderId, title, originalFilename, name, storedPath, sha256, byteCount, kind, pageCount,
                                           extractionStatus, extractionMethod, lowContentPageCount, importedAt, modifiedAt, favorite)
                SELECT id, courseId, NULL, title, originalFilename, originalFilename, storedPath, sha256, byteCount, kind, pageCount,
                       extractionStatus, extractionMethod, lowContentPageCount, importedAt, importedAt, 0 FROM documents
                """)
            try db.drop(table: "documents")
            try db.rename(table: "documents_new", to: "documents")
            try db.create(index: "documents_on_course_folder", on: "documents", columns: ["courseId", "folderId"])
            try db.create(index: "documents_on_folder", on: "documents", columns: ["folderId"])
            try db.create(index: "documents_on_sha", on: "documents", columns: ["sha256"])
        }
        m.registerMigration("v13_agent_chat") { db in
            try db.create(table: "chat_conversations") { t in
                t.primaryKey("id", .blob)
                t.column("title", .text).notNull()
                t.column("courseId", .blob).references("courses", onDelete: .setNull)
                t.column("createdAt", .datetime).notNull()
                t.column("updatedAt", .datetime).notNull()
            }
            try db.create(table: "chat_messages") { t in
                t.primaryKey("id", .blob)
                t.column("conversationId", .blob).notNull().references("chat_conversations", onDelete: .cascade)
                t.column("ordinal", .integer).notNull()
                t.column("role", .text).notNull()                 // user | assistant | tool | notice
                t.column("kind", .text).notNull().defaults(to: "text")   // text | tool | approval | plan | preview | actions | error
                t.column("content", .text).notNull()
                t.column("payload", .text)                        // JSON for rich kinds
                t.column("createdAt", .datetime).notNull()
                t.uniqueKey(["conversationId", "ordinal"])
            }
            // One row per tool call. The (conversation, key) uniqueness is what makes a repeated model call a no-op.
            try db.create(table: "agent_actions") { t in
                t.primaryKey("id", .blob)
                t.column("conversationId", .blob).notNull().references("chat_conversations", onDelete: .cascade)
                t.column("key", .text).notNull()
                t.column("tool", .text).notNull()
                t.column("args", .text).notNull()
                t.column("status", .text).notNull()               // proposed | running | succeeded | failed | declined
                t.column("result", .text)
                t.column("createdAt", .datetime).notNull()
                t.column("updatedAt", .datetime).notNull()
                t.uniqueKey(["conversationId", "key"])
            }
            try db.create(table: "study_plans") { t in
                t.primaryKey("id", .blob)
                t.column("conversationId", .blob).references("chat_conversations", onDelete: .setNull)
                t.column("courseId", .blob).notNull().references("courses", onDelete: .cascade)
                t.column("assessmentId", .blob).references("assessments", onDelete: .setNull)
                t.column("title", .text).notNull()
                t.column("dueDate", .datetime)
                t.column("planJSON", .text).notNull()
                t.column("createdAt", .datetime).notNull()
                t.column("updatedAt", .datetime).notNull()
            }
            try db.create(index: "chat_messages_on_conv", on: "chat_messages", columns: ["conversationId", "ordinal"])
            try db.create(index: "study_plans_on_course", on: "study_plans", columns: ["courseId", "updatedAt"])
        }
        m.registerMigration("v14_model_price_overrides") { db in
            try db.alter(table: "ai_models") { t in
                t.add(column: "customInputPricePerM", .double)
                t.add(column: "customOutputPricePerM", .double)
                t.add(column: "pricedAt", .datetime)
            }
        }
        m.registerMigration("v15_chat_workflow") { db in
            try db.alter(table: "chat_conversations") { t in
                t.add(column: "titleLocked", .boolean).notNull().defaults(to: false)       // the learner renamed it: never overwrite
                t.add(column: "titleGenerated", .boolean).notNull().defaults(to: false)    // a model title was already applied: never regenerate
            }
            try db.alter(table: "chat_messages") { t in
                t.add(column: "supersededAt", .datetime)                                    // set when an edit or regenerate replaced this message; kept for recovery
                t.add(column: "supersededBy", .blob)
                t.add(column: "editedFrom", .blob)
            }
            try db.create(table: "study_maps") { t in
                t.primaryKey("id", .blob)
                t.column("conversationId", .blob).references("chat_conversations", onDelete: .setNull)
                t.column("courseId", .blob).notNull().references("courses", onDelete: .cascade)
                t.column("assessmentId", .blob).references("assessments", onDelete: .setNull)
                t.column("title", .text).notNull()
                t.column("mapJSON", .text).notNull()
                t.column("createdAt", .datetime).notNull()
                t.column("updatedAt", .datetime).notNull()
            }
            try db.create(index: "study_maps_on_course", on: "study_maps", columns: ["courseId", "updatedAt"])
        }
        return m
    }

    static var migrator: DatabaseMigrator { migrator() }
}

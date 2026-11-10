import Foundation
import GRDB

public struct ChatConversation: Codable, Identifiable, Hashable, Sendable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "chat_conversations"
    public var id: UUID
    public var title: String
    public var courseId: UUID?
    public var createdAt: Date
    public var updatedAt: Date
    public var titleLocked: Bool = false
    public var titleGenerated: Bool = false
}

public enum ChatRole: String, Codable, Sendable { case user, assistant, tool, notice }
public enum ChatKind: String, Codable, Sendable { case text, tool, approval, plan, preview, actions, error, call, map }

public struct ChatMessage: Codable, Identifiable, Hashable, Sendable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "chat_messages"
    public var id: UUID
    public var conversationId: UUID
    public var ordinal: Int
    public var role: ChatRole
    public var kind: ChatKind
    public var content: String
    public var payload: String?
    public var createdAt: Date
    /// Set when an edit or "regenerate" replaced this message. It stays in the database (recoverable) but is never shown or sent to the model.
    public var supersededAt: Date? = nil
    public var supersededBy: UUID? = nil
    public var editedFrom: UUID? = nil
}

public enum ActionStatus: String, Codable, Sendable { case proposed, running, succeeded, failed, declined }

public struct AgentAction: Codable, Identifiable, Hashable, Sendable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "agent_actions"
    public var id: UUID
    public var conversationId: UUID
    public var key: String
    public var tool: String
    public var args: String
    public var status: ActionStatus
    public var result: String?
    public var createdAt: Date
    public var updatedAt: Date
}

public struct StudyPlanRecord: Codable, Identifiable, Hashable, Sendable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "study_plans"
    public var id: UUID
    public var conversationId: UUID?
    public var courseId: UUID
    public var assessmentId: UUID?
    public var title: String
    public var dueDate: Date?
    public var planJSON: String
    public var createdAt: Date
    public var updatedAt: Date
}

/// A study plan is a persisted learning artifact (not a page): days of real questions chosen by the existing planner.
public struct StudyPlanDocument: Codable, Sendable, Equatable {
    public struct Item: Codable, Sendable, Equatable, Identifiable {
        public var questionId: UUID; public var title: String; public var type: String; public var minutes: Double; public var reason: String
        public var id: UUID { questionId }
    }
    public struct Day: Codable, Sendable, Equatable, Identifiable {
        public var date: Date; public var label: String; public var minutes: Int; public var focus: [String]; public var items: [Item]; public var note: String
        public var id: Date { date }
    }
    public var courseName: String
    public var assessmentName: String?
    public var days: [Day]
    public var notes: [String]
    public var topics: [String]
    public var totalQuestions: Int { days.reduce(0) { $0 + $1.items.count } }
}

public struct AgentStore: Sendable {
    public let db: AppDatabase
    let now: @Sendable () -> Date
    public init(db: AppDatabase, now: @escaping @Sendable () -> Date = { Date() }) { self.db = db; self.now = now }

    // MARK: Conversations

    @discardableResult
    public func createConversation(title: String = "New chat", courseId: UUID? = nil) throws -> ChatConversation {
        let t = now(); let c = ChatConversation(id: UUID(), title: title, courseId: courseId, createdAt: t, updatedAt: t)
        try db.write { try c.insert($0) }; return c
    }
    public func conversations() throws -> [ChatConversation] { try db.read { try ChatConversation.order(Column("updatedAt").desc).fetchAll($0) } }
    public func conversation(_ id: UUID) throws -> ChatConversation? { try db.read { try ChatConversation.fetchOne($0, key: id) } }
    /// A learner rename. It locks the title: automatic titling never overwrites it.
    public func rename(_ id: UUID, to title: String) throws {
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        try db.write { try $0.execute(sql: "UPDATE chat_conversations SET title = ?, titleLocked = 1 WHERE id = ?", arguments: [String(t.prefix(120)), id]) }
    }
    /// Applies an automatic title. Returns false (and changes nothing) if the learner renamed the chat or a generated title was already applied.
    @discardableResult
    public func setAutoTitle(_ id: UUID, _ title: String, generated: Bool) throws -> Bool {
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return false }
        return try db.write { d in
            try d.execute(sql: "UPDATE chat_conversations SET title = ?, titleGenerated = ? WHERE id = ? AND titleLocked = 0 AND titleGenerated = 0", arguments: [String(t.prefix(120)), generated, id])
            return d.changesCount > 0
        }
    }
    /// Conversations whose title or visible messages contain every word of `text` (case-insensitive), newest first.
    public func search(_ text: String) throws -> [ChatConversation] {
        let terms = text.lowercased().split(separator: " ").map(String.init).filter { !$0.isEmpty }
        guard !terms.isEmpty else { return try conversations() }
        return try db.read { d in
            try ChatConversation.order(Column("updatedAt").desc).fetchAll(d).filter { c in
                let body = (try? String.fetchAll(d, sql: "SELECT content FROM chat_messages WHERE conversationId = ? AND supersededAt IS NULL AND kind IN ('text') AND role IN ('user','assistant')", arguments: [c.id]).joined(separator: " ")) ?? ""
                let hay = (c.title + " " + body).lowercased()
                return terms.allSatisfy { hay.contains($0) }
            }
        }
    }
    public func setCourse(_ id: UUID, _ course: UUID?) throws { try db.write { try $0.execute(sql: "UPDATE chat_conversations SET courseId = ? WHERE id = ?", arguments: [course, id]) } }
    /// Deletes the conversation and its messages and tool records. Questions, courses and study plans it created are kept.
    public func delete(_ id: UUID) throws { try db.write { _ = try ChatConversation.deleteOne($0, key: id) } }

    // MARK: Messages

    @discardableResult
    public func append(_ conv: UUID, role: ChatRole, kind: ChatKind = .text, _ content: String, payload: String? = nil) throws -> ChatMessage {
        try db.write { d in
            let n = (try Int.fetchOne(d, sql: "SELECT COALESCE(MAX(ordinal), -1) + 1 FROM chat_messages WHERE conversationId = ?", arguments: [conv])) ?? 0
            let m = ChatMessage(id: UUID(), conversationId: conv, ordinal: n, role: role, kind: kind, content: content, payload: payload, createdAt: now())
            try m.insert(d)
            try d.execute(sql: "UPDATE chat_conversations SET updatedAt = ? WHERE id = ?", arguments: [now(), conv])
            return m
        }
    }
    /// Visible messages in order. Superseded ones (replaced by an edit or regenerate) are excluded unless asked for.
    public func messages(_ conv: UUID, includeSuperseded: Bool = false) throws -> [ChatMessage] {
        try db.read { d in
            var q = ChatMessage.filter(Column("conversationId") == conv)
            if !includeSuperseded { q = q.filter(Column("supersededAt") == nil) }
            return try q.order(Column("ordinal")).fetchAll(d)
        }
    }

    // MARK: Edit, regenerate and recovery

    /// Edit policy: the edited message and everything after it are marked superseded (kept, hidden, never sent to the model), and the new text is
    /// appended as the current user message. Pending approvals in the replaced range are declined so they can't run later. Nothing is deleted.
    @discardableResult
    public func edit(_ messageId: UUID, newText: String) throws -> ChatMessage? {
        let t = newText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, let m = try db.read({ try ChatMessage.fetchOne($0, key: messageId) }), m.role == .user, m.supersededAt == nil else { return nil }
        let new = try append(m.conversationId, role: .user, t)
        try db.write { d in
            try d.execute(sql: "UPDATE chat_messages SET supersededAt = ?, supersededBy = ? WHERE conversationId = ? AND ordinal >= ? AND id != ? AND supersededAt IS NULL", arguments: [now(), new.id, m.conversationId, m.ordinal, new.id])
            try d.execute(sql: "UPDATE chat_messages SET editedFrom = ? WHERE id = ?", arguments: [m.id, new.id])
            try Self.declineProposed(d, m.conversationId, since: m.ordinal, now: now())
        }
        return try db.read { try ChatMessage.fetchOne($0, key: new.id) }
    }
    /// Brings back the version replaced by an edit (and what followed it), and supersedes the edit and anything after.
    public func restoreEdit(_ newMessageId: UUID) throws {
        try db.write { d in
            guard let n = try ChatMessage.fetchOne(d, key: newMessageId), let from = n.editedFrom else { return }
            let old = try ChatMessage.filter(Column("supersededBy") == newMessageId).fetchAll(d)
            guard !old.isEmpty else { return }
            try d.execute(sql: "UPDATE chat_messages SET supersededAt = ?, supersededBy = NULL WHERE conversationId = ? AND ordinal >= ? AND supersededAt IS NULL", arguments: [now(), n.conversationId, n.ordinal])
            try d.execute(sql: "UPDATE chat_messages SET supersededAt = NULL, supersededBy = NULL WHERE supersededBy = ?", arguments: [newMessageId])
            _ = from
        }
    }
    /// How many hidden messages an edit replaced (for the "restore" notice).
    public func replacedCount(by messageId: UUID) throws -> Int { try db.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM chat_messages WHERE supersededBy = ?", arguments: [messageId]) ?? 0 } }

    /// Regenerate: hides the assistant/tool messages after the last user message so the model answers again. The user message is not duplicated.
    @discardableResult
    public func supersedeLastReply(_ conv: UUID) throws -> Int {
        try db.write { d in
            guard let lastUser = try Int.fetchOne(d, sql: "SELECT MAX(ordinal) FROM chat_messages WHERE conversationId = ? AND role = 'user' AND supersededAt IS NULL", arguments: [conv]) else { return 0 }
            try Self.declineProposed(d, conv, since: lastUser, now: now())
            try d.execute(sql: "UPDATE chat_messages SET supersededAt = ? WHERE conversationId = ? AND ordinal > ? AND supersededAt IS NULL", arguments: [now(), conv, lastUser])
            return d.changesCount
        }
    }
    private static func declineProposed(_ d: Database, _ conv: UUID, since ordinal: Int, now: Date) throws {
        try d.execute(sql: "UPDATE agent_actions SET status = 'declined', result = 'Superseded by an edit before the learner approved it.', updatedAt = ? WHERE conversationId = ? AND status = 'proposed'", arguments: [now, conv])
    }

    /// After a quit or crash: actions still marked running can never finish, and a conversation that ends on a user message got no reply.
    /// Both are reported honestly so the learner can press Retry. Returns the conversations that were touched.
    @discardableResult
    public func recoverInterrupted() throws -> [UUID] {
        var touched = Set<UUID>()
        let stuck = try db.read { try AgentAction.filter(Column("status") == "running").fetchAll($0) }
        for a in stuck {
            try setStatus(a.id, .failed, result: "Interrupted: Learn Anyway closed before this finished. Nothing partial was saved.")
            _ = try append(a.conversationId, role: .notice, kind: .error, "“\(a.tool)” was interrupted when the app closed. Nothing partial was saved. Press Retry to continue.")
            touched.insert(a.conversationId)
        }
        for c in try conversations() where !touched.contains(c.id) {
            if let last = try messages(c.id).last, last.role == .user {
                _ = try append(c.id, role: .notice, kind: .error, "This request was interrupted before a reply arrived. Press Retry to continue.")
                touched.insert(c.id)
            }
        }
        return Array(touched)
    }

    // MARK: Study maps

    public func saveMap(_ r: StudyMapRecord) throws {
        try db.write { d in
            if let ex = try StudyMapRecord.filter(Column("courseId") == r.courseId && Column("title") == r.title && Column("conversationId") == r.conversationId).fetchOne(d) {
                var u = r; u.id = ex.id; u.createdAt = ex.createdAt; u.updatedAt = now(); try u.update(d)
            } else { try r.insert(d) }
        }
    }
    public func map(_ id: UUID) throws -> StudyMapRecord? { try db.read { try StudyMapRecord.fetchOne($0, key: id) } }
    public func maps(courseId: UUID, conversationId: UUID? = nil) throws -> [StudyMapRecord] {
        try db.read { d in
            var q = StudyMapRecord.filter(Column("courseId") == courseId)
            if let conversationId { q = q.filter(Column("conversationId") == conversationId) }
            return try q.order(Column("updatedAt").desc).fetchAll(d)
        }
    }
    public func updateMessage(_ id: UUID, content: String? = nil, payload: String? = nil) throws {
        try db.write { d in
            if let content { try d.execute(sql: "UPDATE chat_messages SET content = ? WHERE id = ?", arguments: [content, id]) }
            if let payload { try d.execute(sql: "UPDATE chat_messages SET payload = ? WHERE id = ?", arguments: [payload, id]) }
        }
    }
    public func deleteMessage(_ id: UUID) throws { try db.write { _ = try ChatMessage.deleteOne($0, key: id) } }

    // MARK: Actions (idempotent tool calls)

    public func action(_ conv: UUID, key: String) throws -> AgentAction? { try db.read { try AgentAction.filter(Column("conversationId") == conv && Column("key") == key).fetchOne($0) } }
    public func action(_ id: UUID) throws -> AgentAction? { try db.read { try AgentAction.fetchOne($0, key: id) } }
    public func record(_ conv: UUID, key: String, tool: String, args: String, status: ActionStatus, result: String? = nil) throws -> AgentAction {
        try db.write { d in
            let a = AgentAction(id: UUID(), conversationId: conv, key: key, tool: tool, args: args, status: status, result: result, createdAt: now(), updatedAt: now())
            try a.insert(d); return a
        }
    }
    public func setStatus(_ id: UUID, _ status: ActionStatus, result: String? = nil) throws {
        try db.write { try $0.execute(sql: "UPDATE agent_actions SET status = ?, result = COALESCE(?, result), updatedAt = ? WHERE id = ?", arguments: [status.rawValue, result, now(), id]) }
    }

    // MARK: Study plans

    public func plans(courseId: UUID? = nil) throws -> [StudyPlanRecord] {
        try db.read { d in
            var q = StudyPlanRecord.order(Column("updatedAt").desc)
            if let courseId { q = q.filter(Column("courseId") == courseId) }
            return try q.fetchAll(d)
        }
    }
    public func plan(_ id: UUID) throws -> StudyPlanRecord? { try db.read { try StudyPlanRecord.fetchOne($0, key: id) } }
    public static func decode(_ p: StudyPlanRecord) -> StudyPlanDocument? {
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        return try? dec.decode(StudyPlanDocument.self, from: Data(p.planJSON.utf8))
    }
}

public struct StudyMapRecord: Codable, Identifiable, Hashable, Sendable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "study_maps"
    public var id: UUID
    public var conversationId: UUID?
    public var courseId: UUID
    public var assessmentId: UUID?
    public var title: String
    public var mapJSON: String
    public var createdAt: Date
    public var updatedAt: Date
    public var document: StudyMapDocument? { try? JSONDecoder().decode(StudyMapDocument.self, from: Data(mapJSON.utf8)) }
}

/// A source-grounded topic map and problem-structure analysis. Every source reference was checked against the course's real documents when it
/// was saved, importance always says where it came from, and the research stage records what was actually possible.
public struct StudyMapDocument: Codable, Sendable, Equatable {
    public struct SourceRef: Codable, Sendable, Equatable, Hashable { public var documentId: UUID; public var documentName: String; public var page: Int? }
    public struct Importance: Codable, Sendable, Equatable {
        public enum Source: String, Codable, Sendable { case instructor, estimated, unknown }
        public var level: String                  // high | medium | low | unknown
        public var source: Source
        public var weightPercent: Double?         // only ever set when source == .instructor
        public var evidence: String               // quoted guidance, marks, repetition…; required for instructor and estimated
    }
    public struct Topic: Codable, Sendable, Equatable, Identifiable {
        public var name: String; public var objectives: [String]; public var prerequisites: [String]
        public var sources: [SourceRef]; public var importance: Importance
        public var id: String { name }
        public var sourced: Bool { !sources.isEmpty }
    }
    public struct Structure: Codable, Sendable, Equatable, Identifiable {
        public var source: SourceRef; public var family: String; public var objective: String
        public var givens: [String]; public var unknowns: [String]; public var assumptions: [String]
        public var method: String; public var prerequisites: [String]; public var extraStep: String
        public var commonMistakes: [String]; public var difficulty: Int
        public var id: String { "\(source.documentId)-\(source.page ?? 0)-\(family)" }
    }
    public struct Research: Codable, Sendable, Equatable { public var status: String; public var note: String }
    public var courseName: String
    public var assessmentName: String?
    public var topics: [Topic]
    public var structures: [Structure]
    public var research: Research
    public var warnings: [String]
    /// Documents that could not be read, so the map covers less than the course.
    public var coverageGaps: [String]
}

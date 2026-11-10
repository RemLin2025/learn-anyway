import Foundation
import GRDB

public struct ChatConversation: Codable, Identifiable, Hashable, Sendable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "chat_conversations"
    public var id: UUID
    public var title: String
    public var courseId: UUID?
    public var createdAt: Date
    public var updatedAt: Date
}

public enum ChatRole: String, Codable, Sendable { case user, assistant, tool, notice }
public enum ChatKind: String, Codable, Sendable { case text, tool, approval, plan, preview, actions, error }

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
    public func rename(_ id: UUID, to title: String) throws {
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        try db.write { try $0.execute(sql: "UPDATE chat_conversations SET title = ? WHERE id = ?", arguments: [String(t.prefix(120)), id]) }
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
    public func messages(_ conv: UUID) throws -> [ChatMessage] { try db.read { try ChatMessage.filter(Column("conversationId") == conv).order(Column("ordinal")).fetchAll($0) } }
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

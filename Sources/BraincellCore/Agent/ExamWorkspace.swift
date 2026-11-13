import Foundation
import GRDB

/// Assessment-specific references and editable findings; files remain in the Library.
public struct ExamMaterial: Codable, Sendable, Equatable, Identifiable {
    public enum Relevance: String, Codable, Sendable, CaseIterable {
        case confirmed = "Confirmed exam material", likely = "Likely relevant", supplementary = "Supplementary"
    }
    public enum Kind: String, Codable, Sendable, CaseIterable {
        case notes = "Lecture notes", practice = "Practice exam", solutions = "Practice solutions", homework = "Homework", textbook = "Textbook", announcement = "Exam announcement", reference = "Reference material"
    }
    public var id: UUID
    public var relevance: Relevance = .supplementary
    public var kind: Kind = .reference
    public init(id: UUID) { self.id = id }
}

public struct ExamWorkspace: Codable, Sendable {
    public var assessmentId: UUID
    public var conversationId = UUID()
    public var instructions = ""
    public var materials: [ExamMaterial] = []
    public var proposal: StudyMapDocument?
    public var excluded: Set<Int> = []
    public var approved = false
    public var count = 10
    public var step = 1
    public init(assessmentId: UUID) { self.assessmentId = assessmentId }

    public static func load(assessmentId: UUID, _ db: AppDatabase) throws -> Self {
        let raw = try db.read { try String.fetchOne($0, sql: "SELECT payload FROM exam_workspaces WHERE assessmentId = ?", arguments: [assessmentId]) }
        return try raw.map { try JSONDecoder().decode(Self.self, from: Data($0.utf8)) } ?? Self(assessmentId: assessmentId)
    }
    public func save(_ db: AppDatabase) throws {
        let payload = String(decoding: try JSONEncoder().encode(self), as: UTF8.self)
        try db.write { d in
            try d.execute(sql: "INSERT INTO exam_workspaces(assessmentId,payload) VALUES (?,?) ON CONFLICT(assessmentId) DO UPDATE SET payload=excluded.payload", arguments: [assessmentId, payload])
            // Only this assessment's references are replaced. Other assessments keep theirs.
            try d.execute(sql: "DELETE FROM document_assessments WHERE assessmentId = ?", arguments: [assessmentId])
            for m in materials { try DocumentAssessment(documentId: m.id, assessmentId: assessmentId).insert(d) }
        }
    }
    public mutating func invalidate() { approved = false; proposal = nil; excluded = []; step = 1 }
    public static func missingTopic(_ name: String) -> StudyMapDocument.Topic {
        .init(name: name, objectives: [], prerequisites: [], sources: [], importance: .init(level: "unknown", source: .unknown, weightPercent: nil, evidence: "Added by learner; exam weighting unknown."))
    }
    /// Only approval commits the edited map to the generation input; excluded topics never enter the generation scope.
    public mutating func approve(_ c: AgentContext, courseId: UUID) throws {
        guard var proposal else { throw ToolError.invalid("Analyze your materials first.") }
        proposal.topics = proposal.topics.enumerated().filter { !excluded.contains($0.offset) }.map(\.element)
        guard !proposal.topics.isEmpty, proposal.topics.allSatisfy({ !$0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }), Set(proposal.topics.map { AgentContext.norm($0.name) }).count == proposal.topics.count else { throw ToolError.invalid("Include at least one topic and give each topic a unique name.") }
        let names = Set(proposal.topics.map(\.name))
        for i in proposal.topics.indices where proposal.topics[i].parent.map({ !names.contains($0) }) == true { proposal.topics[i].parent = nil }
        guard var job = try StudyPrep.jobs(courseId: courseId, c.db).first(where: { $0.conversationId == conversationId }), let id = job.state.mapId, var record = try c.store.map(id) else { throw ToolError.invalid("The saved study map is unavailable. Analyze again.") }
        let current = try StudyPrep.selectedDocuments(materials.map(\.id), c)
        let readable = current.filter { ($0.kind == .pdf || $0.kind == .text || $0.kind == .pasted) && $0.extractionStatus != .failed && $0.extractionStatus != .notApplicable && ((try? c.docs.chunks(documentId: $0.id).contains { !$0.isLowContent && !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) == true) }
        guard job.state.fingerprint == QuestionHashing.sha256(StudyPrep.fingerprint(readable) + analysisInstructions) else { throw ToolError.invalid("Materials changed. Analyze again before approving.") }
        let updatedJSON = String(decoding: try JSONEncoder().encode(proposal), as: UTF8.self)
        if updatedJSON != record.mapJSON {
            var state = job.state
            state.taskId = nil; state.doneBatches = []; state.accepted = 0; state.duplicates = 0; state.rejected = 0
            try StudyPrep.save(&job, state, c, stage: .weightAnalysis, status: .paused)
        }
        record.mapJSON = String(decoding: try JSONEncoder().encode(proposal), as: UTF8.self); record.updatedAt = c.now()
        try c.db.write { try record.update($0) }
        approved = true; step = 3; try save(c.db)
    }
    /// Stable input signature includes relevance and type so changing scope invalidates cached findings.
    public var analysisInstructions: String {
        instructions + "\nSelected material classifications supplied by the learner (confirmed labels are learner assertions, not verified instructor evidence):\n" + materials.sorted { $0.id.uuidString < $1.id.uuidString }.map { "\($0.id): \($0.kind.rawValue), \($0.relevance.rawValue)" }.joined(separator: "\n")
    }
}

extension StudyPrep {
    public static func availableDocuments(_ c: AgentContext) throws -> [Document] {
        try c.db.read { try Document.filter(Column("deletedAt") == nil).filter(sql: LibraryService.liveCourse).order(Column("name")).fetchAll($0) }
    }
    static func selectedDocuments(_ ids: [UUID], _ c: AgentContext) throws -> [Document] {
        let wanted = Set(ids)
        let found = try availableDocuments(c).filter { wanted.contains($0.id) }
        guard found.count == wanted.count else { throw ToolError.unavailable("A selected document was deleted or is unavailable. Review your materials.") }
        return found
    }
}

import GRDB
import SwiftUI
import BraincellCore

/// Home is the Learn Anyway study assistant: a persistent chat that can act in the app through tools.
/// The old dashboard cards (resume, reviews, suggested next, quick cram, create course, course grid) were removed from here;
/// their screens (Courses, Question Bank, practice) and services are unchanged and the assistant can open them.
struct HomeView: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        if let chat = model.chat { ChatWorkspace(chat: chat) }
        else { EmptyStateView(symbol: "exclamationmark.triangle", title: "Chat unavailable", message: "The database couldn’t be opened.") }
    }
}

struct ChecklistStep: Identifiable { let id: Int; let title: String; let done: Bool; let target: SidebarItem }

extension String { var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) } }

extension AppModel {
    var resumableSession: StudySession? { _ = revision; return try? practice?.resumableSession() }

    /// True when any document exists or a structured course has topics (Quick Cram's seed topic doesn't count).
    var hasMaterial: Bool {
        guard let db else { return false }
        _ = revision
        return (try? db.read { try Int.fetchOne($0, sql: "SELECT (SELECT COUNT(*) FROM documents) + (SELECT COUNT(*) FROM course_skills cs JOIN courses c ON c.id = cs.courseId WHERE c.kind = 'structured')") ?? 0 }).map { $0 > 0 } ?? false
    }
}

import SwiftUI

struct RootView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        Group {
            if let sid = model.activeSessionID {
                VStack(spacing: 0) { FocusEndBanner(); PracticeView(sessionID: sid, app: model).id(sid) }
            } else { library }
        }
        .buttonStyle(.secondary)
        .textFieldStyle(AppFieldStyle())
        .tint(Theme.accent)
        .foregroundStyle(Theme.textPrimary)
    }

    private var library: some View {
        HStack(spacing: 0) {
            SidebarView()
            Group {
                switch model.selection ?? .home {
                case .home: HomeView()
                case .courses: CoursesView()
                case .questionBank: QuestionBankView()
                case .aiTasks: AITaskCenterView()
                case .skills: SkillsView()
                case .insights: InsightsView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Theme.background)
            .toolbar { FocusToolbarButton() }
        }
    }
}

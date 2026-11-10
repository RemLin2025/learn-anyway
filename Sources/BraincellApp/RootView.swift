import SwiftUI

struct RootView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        Group {
            if let sid = model.activeSessionID {
                VStack(spacing: 0) { FocusEndBanner(); PracticeView(sessionID: sid, app: model).id(sid) }
            } else { library }
        }
        .sheet(item: $model.practiceSetup) { PracticeSetupSheet(request: $0) }
        .buttonStyle(.secondary)
        .textFieldStyle(AppFieldStyle())
        .tint(Theme.accent)
        .foregroundStyle(Theme.textPrimary)
        .safeAreaInset(edge: .bottom, spacing: 0) { UpdateBanner(u: model.updater) }
        .task { if !SnapshotRunner.isActive, model.updater.checkOnLaunch { model.updater.check() } }
        .onChange(of: model.snapshotOpenSettings) { _, on in if on { model.openSettings() } }
    }

    private var library: some View {
        HStack(spacing: 0) {
            SidebarView()
            Group {
                if model.settingsOpen { SettingsView() } else {
                switch model.selection ?? .home {
                case .home: HomeView()
                case .courses: CoursesView()
                case .library: LibraryView()
                case .questionBank: QuestionBankView()
                case .aiTasks: AITaskCenterView()
                case .skills: SkillsView()
                case .insights: InsightsView()
                }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .scrollContentBackground(.hidden)
            .background(Theme.background)
            .toolbar { FocusToolbarButton() }
            .navigationTitle(model.settingsOpen ? "Settings" : (model.selection ?? .home).rawValue)
        }
    }
}

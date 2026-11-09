import SwiftUI
import AppKit
import BraincellCore

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular) // lets the unbundled binary behave as a normal app too
        NSApp.activate(ignoringOtherApps: true)
        if SnapshotRunner.isActive {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                NSLog("snapshot: windows=%@", NSApp.windows.map { "\($0.className) visible=\($0.isVisible) frame=\($0.frame)" }.joined(separator: " | "))
            }
        }
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

@main
struct BraincellApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var model: AppModel
    @StateObject private var focus: FocusModel

    init() {
        let m = AppModel()
        _model = StateObject(wrappedValue: m)
        _focus = StateObject(wrappedValue: FocusModel(app: m))
    }

    var body: some Scene {
        WindowGroup("Braincell") {
            Group {
                if let err = model.startupError {
                    EmptyStateView(symbol: "exclamationmark.triangle", title: "Braincell can’t start", message: err)
                } else {
                    RootView()
                }
            }
            .environmentObject(model)
            .environmentObject(focus)
            .onAppear { if SnapshotRunner.isActive { Task { @MainActor in await SnapshotRunner.run(model) } } }
            .preferredColorScheme(model.appearance.colorScheme)
            .frame(minWidth: 900, minHeight: 560)
            .alert("Braincell", isPresented: Binding(get: { model.alertMessage != nil }, set: { if !$0 { model.alertMessage = nil } })) {
                Button("OK") { model.alertMessage = nil }
            } message: { Text(model.alertMessage ?? "") }
        }
        .defaultSize(width: 1100, height: 720)

        .commands {
            CommandMenu("Go") {
                ForEach(Array(SidebarItem.allCases.enumerated()), id: \.element) { i, item in
                    Button(item.rawValue) { model.activeSessionID = nil; model.selection = item }.keyboardShortcut(KeyEquivalent(Character("\(i + 1)")), modifiers: .command)
                }
            }
            CommandMenu("Focus") {
                Button("Start Focus Interval") { focus.start(.work) }.keyboardShortcut("f", modifiers: [.command, .option]).disabled(focus.timer != nil)
                Button(focus.isPaused ? "Resume" : "Pause") { focus.isPaused ? focus.resume() : focus.pause() }.keyboardShortcut("p", modifiers: [.command, .option]).disabled(focus.timer == nil)
                Button("Stop") { focus.stop() }.disabled(focus.timer == nil)
            }
        }

        // MenuBarExtra writes this binding on every update; only forward real changes or the scene body loops forever.
        MenuBarExtra(isInserted: Binding(get: { focus.showMenuBar }, set: { if $0 != focus.showMenuBar { focus.showMenuBar = $0 } })) {
            FocusMenuBarContent().environmentObject(focus)
        } label: {
            Label(focus.timer == nil ? "Braincell" : focus.remainingText, systemImage: "timer")
        }

        Settings {
            SettingsView().environmentObject(model).environmentObject(focus).preferredColorScheme(model.appearance.colorScheme)
        }
    }
}

extension AppearanceSetting {
    var colorScheme: ColorScheme? {
        switch self { case .system: nil; case .light: .light; case .dark: .dark }
    }
    var label: String { rawValue.capitalized }
}

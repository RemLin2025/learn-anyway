import SwiftUI
import BraincellCore

/// Toolbar utility: available everywhere, with or without a course or practice session.
struct FocusToolbarButton: View {
    @EnvironmentObject var focus: FocusModel
    @State private var show = false
    var body: some View {
        Button { show.toggle() } label: {
            Label(focus.timer == nil ? "Focus" : focus.remainingText, systemImage: focus.isPaused ? "pause.circle" : "timer")
                .monospacedDigit()
        }
        .help("Focus timer (Pomodoro)")
        .accessibilityLabel(focus.timer == nil ? "Focus timer" : "Focus timer, \(focus.remainingText) remaining")
        .popover(isPresented: $show) { FocusPopover().environmentObject(focus) }
        .onChange(of: focus.endedKind) { _, k in if k != nil { show = true } }
    }
}

struct FocusPopover: View {
    @EnvironmentObject var focus: FocusModel
    @State private var custom = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let t = focus.timer {
                VStack(spacing: 6) {
                    Text(t.kind.label).font(.caption).foregroundStyle(.secondary)
                    Text(focus.remainingText).font(.system(size: 40, weight: .semibold, design: .rounded)).monospacedDigit()
                        .accessibilityLabel("\(focus.remainingText) remaining")
                    MeterBar(value: t.activeSeconds / t.plannedSeconds, tint: t.kind == .work ? Theme.accent : Theme.mastery)
                    if focus.isPaused { Text("Paused").foregroundStyle(Theme.attention) }
                }.frame(maxWidth: .infinity)
                HStack {
                    if focus.isPaused { Button("Resume") { focus.resume() } } else { Button("Pause") { focus.pause() } }
                    Button("Stop") { focus.stop() }
                }
            } else {
                if let k = focus.endedKind {
                    Card {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(k == .work ? "Focus interval finished" : "Break over").font(.headline)
                            Text(k == .work ? "Nothing was submitted or discarded." : "Ready for another round?").font(.caption).foregroundStyle(.secondary)
                            HStack {
                                if k == .work { Button("Start break") { focus.start(focus.settings.next(after: .work, completedFocusCount: focus.completedToday)) } }
                                Button(k == .work ? "Not now" : "Start focus") { if k == .work { focus.dismissEnd() } else { focus.start(.work) } }
                            }
                        }
                    }
                }
                Text("Focus").font(.headline)
                HStack {
                    ForEach(FocusSettings.presets, id: \.self) { m in
                        Button("\(m) min") { focus.settings.focusMinutes = m; focus.saveSettings(); focus.start(.work) }
                            .buttonStyle(.secondary)
                            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.control).strokeBorder(Theme.accent, lineWidth: focus.settings.focusMinutes == m ? 2 : 0))
                    }
                    Button("Custom…") { custom.toggle() }
                }
                if custom {
                    Stepper("Focus: \(focus.settings.focusMinutes) min", value: $focus.settings.focusMinutes, in: 1...240).onChange(of: focus.settings.focusMinutes) { _, _ in focus.saveSettings() }
                    Button("Start") { focus.start(.work) }
                }
                Divider()
                Stepper("Short break: \(focus.settings.shortBreakMinutes) min", value: $focus.settings.shortBreakMinutes, in: 1...60).onChange(of: focus.settings.shortBreakMinutes) { _, _ in focus.saveSettings() }
                Stepper("Long break: \(focus.settings.longBreakMinutes) min", value: $focus.settings.longBreakMinutes, in: 1...90).onChange(of: focus.settings.longBreakMinutes) { _, _ in focus.saveSettings() }
            }
            Divider()
            Toggle("Notify when an interval ends", isOn: $focus.notifyOnEnd).help("Asks macOS for permission the first time")
            Toggle("Show timer in the menu bar", isOn: $focus.showMenuBar)
            Text("\(focus.completedToday) focus interval\(focus.completedToday == 1 ? "" : "s") completed today. Focus time is only a record: it never changes mastery.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(16).frame(width: 320)
    }
}

/// Shown inside practice when an interval ends mid-question. Never submits or discards anything.
struct FocusEndBanner: View {
    @EnvironmentObject var focus: FocusModel
    var body: some View {
        if focus.endedKind == .work {
            HStack(spacing: 10) {
                Image(systemName: "timer").foregroundStyle(Theme.accent)
                Text("Focus interval finished.").font(.callout.weight(.medium))
                Spacer()
                Button("Finish this question") { focus.dismissEnd() }
                Button("Take a break now") { focus.takeBreak() }.buttonStyle(.primary)
            }
            .padding(.horizontal, 16).padding(.vertical, 8).background(Theme.accent.opacity(0.12))
            .accessibilityElement(children: .contain)
        }
    }
}

struct FocusChip: View {
    @EnvironmentObject var focus: FocusModel
    var body: some View {
        if let t = focus.timer {
            HStack(spacing: 4) {
                Image(systemName: t.kind == .work ? "timer" : "cup.and.saucer")
                Text(focus.remainingText).monospacedDigit()
            }.font(.caption).padding(.horizontal, 8).padding(.vertical, 3).background(Theme.elevated, in: Capsule())
            .accessibilityLabel("\(t.kind.label), \(focus.remainingText) remaining")
        }
    }
}

struct FocusMenuBarContent: View {
    @EnvironmentObject var focus: FocusModel
    var body: some View {
        if let t = focus.timer {
            Text("\(t.kind.label): \(focus.remainingText) left")
            if focus.isPaused { Button("Resume") { focus.resume() } } else { Button("Pause") { focus.pause() } }
            Button("Stop") { focus.stop() }
        } else {
            Button("Start 25-minute focus") { focus.settings.focusMinutes = 25; focus.start(.work) }
            Button("Start focus (\(focus.settings.focusMinutes) min)") { focus.start(.work) }
        }
        Divider()
        Button("Open Braincell") { NSApp.activate(ignoringOtherApps: true); NSApp.windows.first?.makeKeyAndOrderFront(nil) }
    }
}

import SwiftUI
import AppKit

extension Color {
    /// Adaptive semantic color: resolves per effective appearance, so views never branch on color scheme.
    init(light: UInt32, dark: UInt32) {
        self.init(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            return NSColor(hex: isDark ? dark : light)
        })
    }
    init(hex: UInt32) { self.init(nsColor: NSColor(hex: hex)) }
}

extension NSColor {
    convenience init(hex: UInt32) {
        self.init(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    }
}

/// Design tokens. Use these, never raw hex values or magic numbers, in feature views.
enum Theme {
    // Colors
    static let background = Color(light: 0xF7F8FA, dark: 0x111318)
    static let surface = Color(light: 0xFFFFFF, dark: 0x1C2028)
    static let elevated = Color(light: 0xEEEFF3, dark: 0x292E39)
    static let border = Color(light: 0xE9EAED, dark: 0x2C313B)
    static let textPrimary = Color(light: 0x202124, dark: 0xECEDEF)
    static let textSecondary = Color(light: 0x777B85, dark: 0x9A9EA8)
    static let accent = Color(light: 0x7468E8, dark: 0x9286F7)
    static let accentHover = Color(light: 0x6256D6, dark: 0xA195F9)
    static let mastery = Color(light: 0x1E9B72, dark: 0x4FC4AD)          // success, readable as text on white
    static let attention = Color(light: 0xB9792C, dark: 0xE7B363)        // warning, readable as text on white
    static let warningFill = Color(light: 0xF2B45A, dark: 0xE7B363)
    static let error = Color(light: 0xD6505A, dark: 0xEE858C)
    // The sidebar is dark in both appearances.
    static let sidebar = Color(hex: 0x202120)
    static let sidebarHover = Color.white.opacity(0.07)
    static let sidebarSelected = Color.white.opacity(0.12)
    static let sidebarText = Color(hex: 0xA9ACA9)

    /// 4-point spacing scale.
    enum Space { static let xs: CGFloat = 4, sm: CGFloat = 8, md: CGFloat = 12, lg: CGFloat = 16, xl: CGFloat = 24, xxl: CGFloat = 32 }
    enum Radius { static let control: CGFloat = 10, card: CGFloat = 16 }

    // Rounded type that scales with Dynamic Type.
    static let pageTitle = Font.system(.largeTitle, design: .rounded, weight: .bold)
    static let sectionTitle = Font.system(.title3, design: .rounded, weight: .semibold)
    static let cardTitle = Font.system(.headline, design: .rounded, weight: .semibold)
    static let meta = Font.system(.caption, design: .rounded)
}

/// Animation that collapses to none when the user asked for Reduce Motion.
extension View {
    func motion<V: Equatable>(_ a: Animation = .easeOut(duration: 0.18), value: V) -> some View { modifier(MotionModifier(animation: a, value: value)) }
}
private struct MotionModifier<V: Equatable>: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduce
    let animation: Animation; let value: V
    func body(content: Content) -> some View { content.animation(reduce ? nil : animation, value: value) }
}

// MARK: Surfaces

struct Card<Content: View>: View {
    var padding: CGFloat = 20
    @ViewBuilder var content: Content
    var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.card))
            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.card).strokeBorder(Theme.border))
            .shadow(color: .black.opacity(0.04), radius: 8, y: 2)
    }
}

/// Page title + optional description + trailing actions. Every top-level screen starts with one.
struct PageHeader<Trailing: View>: View {
    let title: String
    var subtitle: String?
    @ViewBuilder var trailing: Trailing
    var body: some View {
        HStack(alignment: .top, spacing: Theme.Space.lg) {
            VStack(alignment: .leading, spacing: Theme.Space.xs) {
                Text(title).font(Theme.pageTitle).foregroundStyle(Theme.textPrimary).accessibilityAddTraits(.isHeader)
                if let subtitle { Text(subtitle).foregroundStyle(Theme.textSecondary) }
            }
            Spacer(minLength: 0)
            trailing
        }
    }
}
extension PageHeader where Trailing == EmptyView {
    init(title: String, subtitle: String? = nil) { self.init(title: title, subtitle: subtitle) { EmptyView() } }
}

struct EmptyStateView: View {
    let symbol: String
    let title: String
    let message: String
    var actionTitle: String?
    var action: (() -> Void)?

    var body: some View {
        VStack(spacing: Theme.Space.md) {
            Image(systemName: symbol).font(.system(size: 28, weight: .medium)).foregroundStyle(Theme.accent)
                .frame(width: 64, height: 64).background(Theme.accent.opacity(0.12), in: Circle()).accessibilityHidden(true)
            Text(title).font(Theme.sectionTitle)
            Text(message).foregroundStyle(Theme.textSecondary).multilineTextAlignment(.center).frame(maxWidth: 380)
            if let actionTitle, let action { Button(actionTitle, action: action).buttonStyle(.primary) }
        }
        .padding(Theme.Space.xxl)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
    }
}

struct Badge: View {
    let text: String
    var color: Color = Theme.accent
    var body: some View {
        Text(text).font(.system(.caption, design: .rounded, weight: .medium)).padding(.horizontal, 8).padding(.vertical, 3)
            .background(color.opacity(0.14), in: Capsule()).foregroundStyle(color)
    }
}

/// A linear meter drawn from design tokens. Unlike AppKit's ProgressView it honours our tint in light and dark.
struct MeterBar: View {
    var value: Double          // 0…1
    var tint: Color = Theme.accent
    var height: CGFloat = 8
    var body: some View {
        let v = min(1, max(0, value))
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.elevated)
                Capsule().fill(tint).frame(width: max(v > 0 ? height : 0, g.size.width * CGFloat(v)))
            }
        }
        .frame(height: height)
        .motion(.easeOut(duration: 0.4), value: v)
        .accessibilityElement(children: .ignore)
        .accessibilityValue("\(Int((v * 100).rounded())) percent")
    }
}

/// Circular stat for dashboards: a ring with a value in the middle.
struct RingMeter: View {
    var value: Double
    var tint: Color = Theme.accent
    var label: String
    var body: some View {
        let v = min(1, max(0, value))
        ZStack {
            Circle().stroke(Theme.elevated, lineWidth: 7)
            Circle().trim(from: 0, to: v).stroke(tint, style: StrokeStyle(lineWidth: 7, lineCap: .round)).rotationEffect(.degrees(-90))
            Text(label).font(.system(.callout, design: .rounded, weight: .semibold)).monospacedDigit()
        }
        .motion(.easeOut(duration: 0.4), value: v)
        .accessibilityElement(children: .ignore).accessibilityLabel(label)
    }
}

// MARK: Buttons and fields

/// Filled violet button with hover and press feedback.
struct PrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View { Styled(configuration: configuration) }
    struct Styled: View {
        let configuration: Configuration
        @Environment(\.isEnabled) private var enabled
        @State private var hover = false
        var body: some View {
            configuration.label
                .font(.system(.body, design: .rounded, weight: .semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 14).padding(.vertical, 7)
                .background(configuration.isPressed || hover ? Theme.accentHover : Theme.accent, in: RoundedRectangle(cornerRadius: Theme.Radius.control))
                .opacity(enabled ? 1 : 0.4)
                .scaleEffect(configuration.isPressed ? 0.98 : 1)
                .onHover { hover = $0 }
                .motion(value: hover)
        }
    }
}

/// Outlined white button for everything that isn't the main action.
struct SecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View { Styled(configuration: configuration) }
    struct Styled: View {
        let configuration: Configuration
        @Environment(\.isEnabled) private var enabled
        @State private var hover = false
        var body: some View {
            configuration.label
                .font(.system(.body, design: .rounded, weight: .medium))
                .foregroundStyle(Theme.textPrimary)
                .padding(.horizontal, 12).padding(.vertical, 6)
                .background(configuration.isPressed ? Theme.elevated : (hover ? Theme.background : Theme.surface), in: RoundedRectangle(cornerRadius: Theme.Radius.control))
                .overlay(RoundedRectangle(cornerRadius: Theme.Radius.control).strokeBorder(Theme.border))
                .opacity(enabled ? 1 : 0.45)
                .onHover { hover = $0 }
                .motion(value: hover)
        }
    }
}

extension ButtonStyle where Self == PrimaryButtonStyle { static var primary: PrimaryButtonStyle { PrimaryButtonStyle() } }
extension ButtonStyle where Self == SecondaryButtonStyle { static var secondary: SecondaryButtonStyle { SecondaryButtonStyle() } }

/// Rounded, bordered text input. Applied once at the window root, so every TextField gets it.
struct AppFieldStyle: TextFieldStyle {
    func _body(configuration: TextField<Self._Label>) -> some View {
        configuration
            .textFieldStyle(.plain)
            .padding(.horizontal, 10).padding(.vertical, 7)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.control))
            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.control).strokeBorder(Theme.border))
    }
}

/// Multi-line text areas (TextEditor) get the same rounded, bordered look as TextField.
extension View {
    func fieldSurface() -> some View {
        scrollContentBackground(.hidden).padding(6)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.control))
            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.control).strokeBorder(Theme.border))
    }
    /// Sheet chrome: generous padding on the light page background. Apply to a sheet's root view.
    func dialogSurface(width: CGFloat? = nil) -> some View {
        padding(Theme.Space.xl).frame(width: width).background(Theme.background)
    }
}

/// Search box with a leading magnifier and a clear button.
struct SearchField: View {
    let prompt: String
    @Binding var text: String
    var body: some View {
        HStack(spacing: Theme.Space.sm) {
            Image(systemName: "magnifyingglass").foregroundStyle(Theme.textSecondary).accessibilityHidden(true)
            TextField(prompt, text: $text).textFieldStyle(.plain).accessibilityLabel(prompt)
            if !text.isEmpty {
                Button { text = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(Theme.textSecondary) }
                    .buttonStyle(.plain).accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 7)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.control))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.control).strokeBorder(Theme.border))
    }
}

/// Icon + title + optional trailing detail used by list panes (courses, assessments, topics).
struct ListRowLabel: View {
    let title: String
    var symbol: String?
    var tint: Color = Theme.accent
    var body: some View {
        HStack(spacing: Theme.Space.md) {
            if let symbol {
                Image(systemName: symbol).font(.system(size: 13, weight: .semibold)).foregroundStyle(tint)
                    .frame(width: 28, height: 28).background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 8)).accessibilityHidden(true)
            }
            Text(title).font(.system(.body, design: .rounded, weight: .medium)).lineLimit(2)
        }.padding(.vertical, 2)
    }
}

// MARK: Sidebar

/// Dark navigation rail. Collapses to icons only. Navigation state lives in AppModel.selection, so the Go menu
/// shortcuts keep working.
struct SidebarView: View {
    @EnvironmentObject var model: AppModel
    @AppStorage("sidebarCollapsed") private var collapsed = false

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.xs) {
            HStack(spacing: Theme.Space.sm) {
                Image(systemName: "brain.head.profile").font(.system(size: 18, weight: .semibold)).foregroundStyle(.white)
                    .frame(width: 32, height: 32).background(Theme.accent, in: RoundedRectangle(cornerRadius: 9)).accessibilityHidden(true)
                if !collapsed { Text("Learn Anyway").font(.system(.title3, design: .rounded, weight: .bold)).foregroundStyle(.white) }
            }
            .padding(.bottom, Theme.Space.lg).padding(.top, Theme.Space.xs).padding(.leading, 2)
            .accessibilityElement(children: .combine).accessibilityLabel("Learn Anyway")

            ForEach(SidebarItem.allCases) { item in
                SidebarRow(title: item.rawValue, symbol: item.symbol, collapsed: collapsed, selected: (model.selection ?? .home) == item) { model.selection = item }
            }
            Spacer()
            SettingsLink { SidebarLabel(title: "Settings", symbol: "gearshape", collapsed: collapsed, selected: false, hover: false) }
                .buttonStyle(.plain).help("Settings")
            SidebarRow(title: collapsed ? "Expand sidebar" : "Collapse", symbol: collapsed ? "sidebar.right" : "sidebar.left", collapsed: collapsed, selected: false) { collapsed.toggle() }
        }
        .padding(Theme.Space.md)
        .frame(width: collapsed ? 64 : 208)
        .frame(maxHeight: .infinity)
        .background(Theme.sidebar)
        .motion(.easeOut(duration: 0.2), value: collapsed)
        .environment(\.colorScheme, .dark)
        .accessibilityElement(children: .contain).accessibilityLabel("Sidebar")
    }
}

private struct SidebarLabel: View {
    let title: String; let symbol: String; let collapsed: Bool; let selected: Bool; let hover: Bool
    var body: some View {
        HStack(spacing: Theme.Space.md) {
            Image(systemName: symbol).font(.system(size: 15, weight: .medium)).frame(width: 20)
            if !collapsed { Text(title).font(.system(.body, design: .rounded, weight: selected ? .semibold : .regular)); Spacer(minLength: 0) }
        }
        .foregroundStyle(selected ? Color.white : Theme.sidebarText)
        .padding(.horizontal, Theme.Space.md).padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: collapsed ? .center : .leading)
        .background(selected ? Theme.sidebarSelected : (hover ? Theme.sidebarHover : .clear), in: RoundedRectangle(cornerRadius: Theme.Radius.control))
        .contentShape(Rectangle())
    }
}

private struct SidebarRow: View {
    let title: String; let symbol: String; let collapsed: Bool; let selected: Bool; let action: () -> Void
    @State private var hover = false
    var body: some View {
        Button(action: action) { SidebarLabel(title: title, symbol: symbol, collapsed: collapsed, selected: selected, hover: hover) }
            .buttonStyle(.plain).onHover { hover = $0 }.motion(value: hover)
            .help(title).accessibilityLabel(title).accessibilityAddTraits(selected ? .isSelected : [])
    }
}

// MARK: Panels and segmented control

extension View {
    /// Left-hand list pane: white surface, no native list background, hairline on the trailing edge.
    func sidePanel() -> some View {
        scrollContentBackground(.hidden).listStyle(.plain).background(Theme.surface)
            .overlay(alignment: .trailing) { Rectangle().fill(Theme.border).frame(width: 1) }
    }
    /// Toolbar strip above content (filters, pickers): surface background with a hairline below.
    func controlStrip() -> some View {
        background(Theme.surface).overlay(alignment: .bottom) { Rectangle().fill(Theme.border).frame(height: 1) }
    }
}

/// Pill-style segmented control. Each option is a real button, so VoiceOver and keyboard focus behave normally.
struct SegmentedControl<T: Hashable>: View {
    @Binding var selection: T
    let options: [T]
    let label: (T) -> String
    var body: some View {
        HStack(spacing: 2) {
            ForEach(options, id: \.self) { o in
                Button { selection = o } label: {
                    Text(label(o)).font(.system(.callout, design: .rounded, weight: selection == o ? .semibold : .regular))
                        .foregroundStyle(selection == o ? Theme.textPrimary : Theme.textSecondary)
                        .padding(.horizontal, 12).padding(.vertical, 5)
                        .background(selection == o ? Theme.surface : .clear, in: RoundedRectangle(cornerRadius: Theme.Radius.control - 3))
                        .shadow(color: .black.opacity(selection == o ? 0.08 : 0), radius: 2, y: 1)
                }
                .buttonStyle(.plain).accessibilityAddTraits(selection == o ? .isSelected : [])
            }
        }
        .padding(3).background(Theme.elevated, in: RoundedRectangle(cornerRadius: Theme.Radius.control))
        .motion(value: selection).accessibilityElement(children: .contain)
    }
}

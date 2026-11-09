import SwiftUI
import BraincellCore

/// Shared building blocks for the four AI settings pages.
struct AIPage<Content: View>: View {
    let title: String
    var subtitle: String?
    /// A one-line title bar for tool-like pages that need the room (the workflow canvas).
    var compact = false
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(compact ? .system(.title2, design: .rounded, weight: .bold) : Theme.pageTitle).accessibilityAddTraits(.isHeader)
                if let subtitle, !compact { Text(subtitle).foregroundStyle(Theme.textSecondary) }
            }.padding(.horizontal, Theme.Space.xl).padding(.vertical, compact ? Theme.Space.md : Theme.Space.lg).frame(maxWidth: .infinity, alignment: .leading)
            Divider()
            content.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

struct StatusDot: View {
    let color: Color; let text: String
    var body: some View {
        HStack(spacing: 5) { Circle().fill(color).frame(width: 7, height: 7).accessibilityHidden(true); Text(text).font(Theme.meta).foregroundStyle(Theme.textSecondary) }
            .accessibilityElement(children: .combine)
    }
}

struct Notice: View {
    let text: String; var tint: Color = Theme.accent; var symbol = "info.circle"
    var body: some View {
        Label { Text(text).fixedSize(horizontal: false, vertical: true) } icon: { Image(systemName: symbol) }
            .font(.callout).padding(Theme.Space.md).frame(maxWidth: .infinity, alignment: .leading)
            .background(tint.opacity(0.10), in: RoundedRectangle(cornerRadius: Theme.Radius.control))
            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.control).strokeBorder(tint.opacity(0.35)))
    }
}

/// API key entry with show/hide. The key is held only in memory until saved to the Keychain.
struct SecretField: View {
    let prompt: String
    @Binding var text: String
    @State private var shown = false
    var body: some View {
        HStack(spacing: 6) {
            Group { if shown { TextField(prompt, text: $text) } else { SecureField(prompt, text: $text) } }
                .textFieldStyle(.plain).accessibilityLabel(prompt)
            Button { shown.toggle() } label: { Image(systemName: shown ? "eye.slash" : "eye").foregroundStyle(Theme.textSecondary) }
                .buttonStyle(.plain).accessibilityLabel(shown ? "Hide key" : "Show key")
        }
        .padding(.horizontal, 10).padding(.vertical, 7)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.control))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.control).strokeBorder(Theme.border))
    }
}

struct ProviderIcon: View {
    let symbol: String; var size: CGFloat = 34
    var body: some View {
        Image(systemName: symbol).font(.system(size: size * 0.45, weight: .semibold)).foregroundStyle(Theme.accent)
            .frame(width: size, height: size).background(Theme.accent.opacity(0.12), in: RoundedRectangle(cornerRadius: size * 0.3)).accessibilityHidden(true)
    }
}

enum ModelBadge {
    static func text(_ m: AIModelRecord, local: Bool) -> (String, Color) {
        if local { return ("Local", Theme.accent) }
        switch m.health { case .ready: return ("Ready", Theme.mastery); case .failed: return ("Failed test", Theme.error); case .untested: return ("Untested", Theme.textSecondary) }
    }
}

import SwiftUI
import BraincellCore

/// Items waiting out their seven-day recovery period. Restoring is one click; deleting now takes two confirmations.
struct RecentlyDeletedView: View {
    @EnvironmentObject var model: AppModel
    @State private var items: [DeletedItem] = []
    @State private var asking: DeletedItem?
    @State private var sure: DeletedItem?
    @State private var error: String?

    var body: some View {
        Group {
            if items.isEmpty {
                EmptyStateView(symbol: "trash", title: "Nothing recently deleted", message: "Deleted courses, folders and files stay here for seven days so you can restore them.")
            } else {
                ScrollView {
                    VStack(spacing: Theme.Space.sm) {
                        Text("Items are permanently deleted after seven days. Study history for a deleted course is kept.").font(Theme.meta).foregroundStyle(Theme.textSecondary).frame(maxWidth: .infinity, alignment: .leading)
                        if let error { Text(error).font(.callout).foregroundStyle(Theme.error).frame(maxWidth: .infinity, alignment: .leading) }
                        ForEach(items) { item in
                            HStack(spacing: Theme.Space.md) {
                                Image(systemName: item.ref.kind.symbol).foregroundStyle(item.ref.kind.tint).frame(width: 26).accessibilityHidden(true)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(item.name).font(.system(.body, design: .rounded, weight: .medium)).lineLimit(1)
                                    Text("\(item.detail) · deleted \(item.deletedAt.formatted(date: .abbreviated, time: .shortened))").font(Theme.meta).foregroundStyle(Theme.textSecondary)
                                }
                                Spacer()
                                VStack(alignment: .trailing, spacing: 2) {
                                    Text("Expires \(item.purgeAfter.formatted(date: .abbreviated, time: .omitted))").font(Theme.meta).foregroundStyle(Theme.attention)
                                    Text(Self.remaining(item.purgeAfter)).font(.system(size: 10)).foregroundStyle(Theme.textSecondary)
                                }
                                Button("Restore") { restore(item) }.buttonStyle(.primary)
                                Button("Delete Now…", role: .destructive) { asking = item }
                            }
                            .padding(Theme.Space.md).background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.control + 2))
                            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.control + 2).strokeBorder(Theme.border))
                            .accessibilityElement(children: .contain)
                        }
                    }.padding(Theme.Space.lg)
                }
            }
        }
        .task(id: model.revision) { load() }
        .confirmationDialog("Delete “\(asking?.name ?? "")” permanently?", isPresented: Binding(get: { asking != nil }, set: { if !$0 { asking = nil } }), titleVisibility: .visible) {
            Button("Delete Permanently…", role: .destructive) { sure = asking; asking = nil }
            Button("Cancel", role: .cancel) { asking = nil }
        } message: { Text("Skips the seven-day recovery period.") }
        .alert("This can’t be undone", isPresented: Binding(get: { sure != nil }, set: { if !$0 { sure = nil } })) {
            Button("Delete Forever", role: .destructive) { if let s = sure { purge(s) }; sure = nil }
            Button("Cancel", role: .cancel) { sure = nil }
        } message: { Text("“\(sure?.name ?? "")” and its stored files will be removed immediately and can’t be restored.") }
    }

    static func remaining(_ d: Date) -> String {
        let days = Int((d.timeIntervalSince(Date()) / 86400).rounded(.up))
        return days <= 1 ? "less than a day left" : "\(days) days left"
    }
    private func load() { items = (try? model.library?.recentlyDeleted()) ?? [] }
    private func restore(_ i: DeletedItem) { error = nil; do { try model.library?.restore(i.ref) } catch { self.error = error.localizedDescription }; model.reload() }
    private func purge(_ i: DeletedItem) { error = nil; do { try model.library?.purge(i.ref) } catch { self.error = error.localizedDescription }; model.reload() }
}

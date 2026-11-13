import SwiftUI
import AppKit
import QuickLookThumbnailing
import QuickLookUI
import BraincellCore

/// Asynchronous, bounded thumbnail cache. Thumbnails come from Quick Look (so a 2 GB video is never read into memory by us),
/// are requested only for cards that are actually on screen, and are evicted by count and byte cost.
@MainActor
final class ThumbnailCache {
    static let shared = ThumbnailCache()
    private let cache = NSCache<NSString, NSImage>()
    private struct Box: @unchecked Sendable { let image: NSImage? }          // NSImage isn't Sendable; it only crosses back to the main actor once
    private var inflight: [String: Task<Box, Never>] = [:]
    init() { cache.countLimit = 500; cache.totalCostLimit = 96 * 1024 * 1024 }

    func image(for url: URL, side: CGFloat, scale: CGFloat) async -> NSImage? {
        let key = "\(url.path)|\(Int(side))" as NSString
        if let hit = cache.object(forKey: key) { return hit }
        if let t = inflight[key as String] { return await t.value.image }
        let t = Task<Box, Never> {
            let req = QLThumbnailGenerator.Request(fileAt: url, size: CGSize(width: side, height: side), scale: scale, representationTypes: .thumbnail)
            guard let rep = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: req) else { return Box(image: nil) }
            return Box(image: rep.nsImage)
        }
        inflight[key as String] = t
        let img = await t.value.image
        inflight[key as String] = nil
        if let img { cache.setObject(img, forKey: key, cost: Int(img.size.width * img.size.height * 4)) }
        return img
    }
}

/// Native Quick Look for any file Quick Look understands; unsupported types show Quick Look's own generic preview.
struct QuickLookPreview: NSViewRepresentable {
    let url: URL
    func makeNSView(context: Context) -> QLPreviewView {
        let v = QLPreviewView(frame: .zero, style: .normal)!
        v.previewItem = url as NSURL; return v
    }
    func updateNSView(_ v: QLPreviewView, context: Context) { v.previewItem = url as NSURL }
    static func dismantleNSView(_ v: QLPreviewView, coordinator: ()) { v.close() }
}

extension LibraryKind {
    var symbol: String {
        switch self {
        case .courseFolder: "graduationcap.fill"; case .folder: "folder.fill"; case .pdf: "doc.richtext.fill"
        case .text: "doc.text.fill"; case .image: "photo.fill"; case .video: "film.fill"; case .other: "doc.fill"; case .practiceSet: "list.bullet.rectangle"
        }
    }
    var tint: Color {
        switch self {
        case .courseFolder: Theme.accent; case .folder: Theme.accent; case .pdf: Theme.error; case .text: Color(hex: 0x4C8DF6)
        case .image: Theme.mastery; case .video: Theme.attention; case .other: Theme.textSecondary; case .practiceSet: Theme.accent
        }
    }
}

/// A file or folder tile: title bar, then a preview area (thumbnail when Quick Look can make one, an icon otherwise).
struct LibraryCard: View {
    let entry: LibraryEntry
    let url: URL?
    let selected: Bool
    @State private var thumb: NSImage?
    @State private var hover = false
    @Environment(\.displayScale) private var scale

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: entry.kind.symbol).foregroundStyle(entry.kind.tint).font(.system(size: 13)).accessibilityHidden(true)
                Text(entry.name).font(.system(.callout, design: .rounded, weight: .medium)).lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 0)
                if entry.favorite { Image(systemName: "star.fill").font(.system(size: 11)).foregroundStyle(Theme.attention).accessibilityLabel("Favorite") }
            }.padding(.horizontal, 12).frame(height: 38)
            Divider().opacity(0.6)
            ZStack {
                if let thumb { Image(nsImage: thumb).resizable().scaledToFit().clipShape(RoundedRectangle(cornerRadius: 6)).padding(10) }
                else {
                    VStack(spacing: 6) {
                        Image(systemName: entry.kind.symbol).font(.system(size: entry.isFolder ? 40 : 34, weight: .regular)).foregroundStyle(entry.kind.tint.opacity(0.85))
                        if entry.isFolder { Text("\(entry.childCount) item\(entry.childCount == 1 ? "" : "s")").font(Theme.meta).foregroundStyle(Theme.textSecondary) }
                        else if entry.kind == .pdf || entry.kind == .other { Text(entry.kind.label.uppercased()).font(.system(size: 10, weight: .bold)).foregroundStyle(entry.kind.tint) }
                    }
                }
            }.frame(maxWidth: .infinity).frame(height: 132)
        }
        .background(selected ? Theme.accent.opacity(0.10) : (hover ? Theme.elevated : Theme.surface), in: RoundedRectangle(cornerRadius: Theme.Radius.card))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.card).strokeBorder(selected ? Theme.accent : Theme.border, lineWidth: selected ? 2 : 1))
        .onHover { hover = $0 }
        .task(id: url) {
            guard !entry.isFolder, let url else { return }
            thumb = await ThumbnailCache.shared.image(for: url, side: 220, scale: scale)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(entry.name), \(entry.kind.label)\(entry.isFolder ? ", \(entry.childCount) items" : "")\(entry.favorite ? ", favorite" : "")")
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }
}

struct LibraryRow: View {
    let entry: LibraryEntry
    let selected: Bool
    @State private var hover = false
    var body: some View {
        HStack(spacing: Theme.Space.md) {
            Image(systemName: entry.kind.symbol).foregroundStyle(entry.kind.tint).frame(width: 26).accessibilityHidden(true)
            Text(entry.name).font(.system(.body, design: .rounded, weight: .medium)).lineLimit(1).truncationMode(.middle)
            if entry.favorite { Image(systemName: "star.fill").font(.caption).foregroundStyle(Theme.attention) }
            Spacer(minLength: 8)
            Text(entry.isFolder ? "\(entry.childCount) item\(entry.childCount == 1 ? "" : "s")" : ByteCountFormatter.string(fromByteCount: Int64(entry.byteCount), countStyle: .file))
                .font(Theme.meta).foregroundStyle(Theme.textSecondary).frame(width: 80, alignment: .trailing)
            Text(entry.kind.label).font(Theme.meta).foregroundStyle(Theme.textSecondary).frame(width: 60, alignment: .leading)
            Text(entry.addedAt.formatted(date: .abbreviated, time: .omitted)).font(Theme.meta).foregroundStyle(Theme.textSecondary).frame(width: 100, alignment: .trailing)
        }
        .padding(.horizontal, Theme.Space.md).frame(height: 40)
        .background(selected ? Theme.accent.opacity(0.12) : (hover ? Theme.elevated.opacity(0.6) : .clear), in: RoundedRectangle(cornerRadius: Theme.Radius.control))
        .contentShape(Rectangle()).onHover { hover = $0 }
        .accessibilityElement(children: .combine).accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }
}

/// Pill tabs like the reference's "Suggested / Favorites / Folders / Images / All" row.
struct PillTabs<T: Hashable>: View {
    @Binding var selection: T
    let options: [T]
    let label: (T) -> String
    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                ForEach(options, id: \.self) { o in
                    Button { selection = o } label: {
                        Text(label(o)).font(.system(.callout, design: .rounded, weight: selection == o ? .semibold : .regular)).lineLimit(1).fixedSize()
                            .foregroundStyle(selection == o ? Theme.textPrimary : Theme.textSecondary).padding(.horizontal, 16).padding(.vertical, 8)
                            .background(selection == o ? Theme.elevated : .clear, in: Capsule()).contentShape(Capsule())
                    }.buttonStyle(.plain).accessibilityAddTraits(selection == o ? .isSelected : [])
                }
            }
        }
    }
}

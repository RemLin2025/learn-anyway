import SwiftUI
import AppKit
import BraincellCore

/// Native code editor on AppKit's text system (NSTextView): line numbers, syntax highlighting, auto-indent,
/// bracket matching, undo/redo, find bar, configurable font, read-only mode. See ADR-015 for why no third-party editor.
final class CodeEditorController: ObservableObject {
    weak var textView: NSTextView?
    func showFind() {
        guard let tv = textView else { return }
        tv.window?.makeFirstResponder(tv)
        let item = NSMenuItem(); item.tag = Int(NSFindPanelAction.showFindPanel.rawValue)
        tv.performFindPanelAction(item)
    }
}

struct CodeEditorView: NSViewRepresentable {
    @Binding var text: String
    var language: CodeLanguage
    var fontSize: CGFloat
    var isEditable: Bool
    var controller: CodeEditorController?

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true; scroll.hasHorizontalScroller = false; scroll.drawsBackground = true
        let tv = NSTextView()
        tv.isRichText = false; tv.allowsUndo = true; tv.usesFindBar = true; tv.isIncrementalSearchingEnabled = true
        // Code must never be "corrected": no smart quotes/dashes/replacements/spell-fixing.
        tv.isAutomaticQuoteSubstitutionEnabled = false; tv.isAutomaticDashSubstitutionEnabled = false
        tv.isAutomaticTextReplacementEnabled = false; tv.isAutomaticSpellingCorrectionEnabled = false
        tv.isAutomaticLinkDetectionEnabled = false; tv.isContinuousSpellCheckingEnabled = false
        tv.isVerticallyResizable = true; tv.isHorizontallyResizable = false
        tv.autoresizingMask = [.width]
        tv.textContainer?.widthTracksTextView = true
        tv.textContainerInset = NSSize(width: 6, height: 8)
        tv.backgroundColor = NSColor(name: nil) { $0.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? NSColor(hex: 0x1C2028) : NSColor(hex: 0xFFFFFF) }
        tv.delegate = context.coordinator
        scroll.documentView = tv
        scroll.verticalRulerView = LineNumberRuler(scrollView: scroll, orientation: .verticalRuler)
        scroll.hasVerticalRuler = true; scroll.rulersVisible = true
        context.coordinator.textView = tv
        controller?.textView = tv
        tv.string = text
        apply(to: tv, context: context)
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let tv = scroll.documentView as? NSTextView else { return }
        controller?.textView = tv
        if tv.string != text {
            let sel = tv.selectedRange()
            tv.string = text
            tv.setSelectedRange(NSRange(location: min(sel.location, (text as NSString).length), length: 0))
        }
        apply(to: tv, context: context)
        scroll.verticalRulerView?.needsDisplay = true
    }

    private func apply(to tv: NSTextView, context: Context) {
        tv.isEditable = isEditable
        let font = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
        if tv.font != font { tv.font = font }
        tv.textColor = .labelColor
        tv.insertionPointColor = .controlAccentColor
        context.coordinator.rehighlight()
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: CodeEditorView
        weak var textView: NSTextView?
        init(_ p: CodeEditorView) { parent = p }

        func textDidChange(_ n: Notification) {
            guard let tv = textView else { return }
            if parent.text != tv.string { parent.text = tv.string }
            rehighlight()
            tv.enclosingScrollView?.verticalRulerView?.needsDisplay = true
        }

        func textViewDidChangeSelection(_ n: Notification) { highlightBrackets() }

        func textView(_ tv: NSTextView, doCommandBy sel: Selector) -> Bool {
            let lang = parent.language
            if sel == #selector(NSResponder.insertNewline(_:)) {
                let r = tv.selectedRange()
                let (ins, caret) = AutoIndent.newline(in: tv.string, caret: r.location, language: lang)
                tv.insertText(ins, replacementRange: r)
                tv.setSelectedRange(NSRange(location: r.location + caret, length: 0))
                return true
            }
            if sel == #selector(NSResponder.insertTab(_:)) { tv.insertText(AutoIndent.unit, replacementRange: tv.selectedRange()); return true }
            return false
        }

        static func color(_ k: TokenKind) -> NSColor {
            switch k {
            case .keyword: .systemPurple
            case .string: .systemRed
            case .comment: .systemGray
            case .number: .systemTeal
            case .preprocessor: .systemOrange
            }
        }

        /// Temporary attributes: they never enter the undo stack or the stored text.
        func rehighlight() {
            guard let tv = textView, let lm = tv.layoutManager else { return }
            let full = NSRange(location: 0, length: (tv.string as NSString).length)
            lm.removeTemporaryAttribute(.foregroundColor, forCharacterRange: full)
            for t in SyntaxHighlighter.tokens(tv.string, language: parent.language) {
                lm.addTemporaryAttribute(.foregroundColor, value: Self.color(t.kind), forCharacterRange: NSRange(location: t.location, length: t.length))
            }
            highlightBrackets()
        }

        func highlightBrackets() {
            guard let tv = textView, let lm = tv.layoutManager else { return }
            let full = NSRange(location: 0, length: (tv.string as NSString).length)
            lm.removeTemporaryAttribute(.backgroundColor, forCharacterRange: full)
            guard let (a, b) = BracketMatcher.match(in: tv.string, caret: tv.selectedRange().location, language: parent.language) else { return }
            for p in [a, b] { lm.addTemporaryAttribute(.backgroundColor, value: NSColor.controlAccentColor.withAlphaComponent(0.3), forCharacterRange: NSRange(location: p, length: 1)) }
        }
    }
}

final class LineNumberRuler: NSRulerView {
    override init(scrollView: NSScrollView?, orientation: NSRulerView.Orientation) {
        super.init(scrollView: scrollView, orientation: orientation)
        clientView = scrollView?.documentView
        ruleThickness = 40
    }
    required init(coder: NSCoder) { fatalError() }

    override func drawHashMarksAndLabels(in rect: NSRect) {
        guard let tv = clientView as? NSTextView, let lm = tv.layoutManager, let tc = tv.textContainer, let sv = scrollView else { return }
        NSColor.secondaryLabelColor.withAlphaComponent(0.06).setFill(); rect.fill()
        let visible = sv.contentView.bounds
        let glyphs = lm.glyphRange(forBoundingRect: visible, in: tc)
        let chars = lm.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
        let ns = tv.string as NSString
        var line = 1
        ns.enumerateSubstrings(in: NSRange(location: 0, length: chars.location), options: [.byLines, .substringNotRequired]) { _, _, _, _ in line += 1 }
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedDigitSystemFont(ofSize: max(9, (tv.font?.pointSize ?? 12) - 2), weight: .regular),
                                                    .foregroundColor: NSColor.secondaryLabelColor]
        var idx = chars.location
        repeat {
            let lr = ns.lineRange(for: NSRange(location: min(idx, ns.length), length: 0))
            var y: CGFloat
            if ns.length == 0 || lr.location >= ns.length {
                y = lm.extraLineFragmentRect.minY
                if ns.length == 0 { y = 0 }
            } else {
                y = lm.lineFragmentRect(forGlyphAt: lm.glyphIndexForCharacter(at: lr.location), effectiveRange: nil).minY
            }
            let p = convert(NSPoint(x: 0, y: y + tv.textContainerOrigin.y), from: tv)
            let s = "\(line)" as NSString
            let w = s.size(withAttributes: attrs).width
            s.draw(at: NSPoint(x: ruleThickness - w - 6, y: p.y), withAttributes: attrs)
            line += 1
            if lr.length == 0 { break }
            idx = NSMaxRange(lr)
        } while idx <= NSMaxRange(chars) && idx < ns.length + 1
    }
}

/// A set of files (usually one) with tabs when there are several. The data model is multi-file from the start.
struct CodeWorkspaceView: View {
    @Binding var files: [CodeFile]
    var isEditable: Bool = true
    var fontSize: CGFloat
    @State private var selected = 0
    @StateObject private var controller = CodeEditorController()

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                if files.count > 1 {
                    Picker("File", selection: $selected) { ForEach(files.indices, id: \.self) { Text(files[$0].name).tag($0) } }
                        .pickerStyle(.segmented).labelsHidden().frame(maxWidth: 360)
                } else if let f = files.first { Label(f.name, systemImage: "doc.plaintext").font(.callout).foregroundStyle(.secondary) }
                Spacer()
                if !isEditable { Badge(text: "Read-only", color: .secondary) }
                Button { controller.showFind() } label: { Label("Find", systemImage: "magnifyingglass") }.buttonStyle(.borderless)
                    .help("Find in file (⌘F)")
            }.padding(.horizontal, 10).padding(.vertical, 6)
            Divider()
            if files.indices.contains(selected) {
                CodeEditorView(text: Binding(get: { files[selected].content }, set: { files[selected].content = $0 }),
                               language: CodeLanguage(name: files[selected].language) ?? .python, fontSize: fontSize,
                               isEditable: isEditable, controller: controller)
                    .accessibilityLabel("Code editor, \(files[selected].name)")
            }
        }
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.primary.opacity(0.1)))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

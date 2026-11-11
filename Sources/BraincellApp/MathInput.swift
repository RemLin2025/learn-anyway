import SwiftUI
import AppKit
import BraincellCore

/// Bridges the SwiftUI toolbar to the NSTextView so palette clicks insert at the caret (replacing any selection) through the text
/// system's own undo stack, and focus goes back to the editor afterwards.
@MainActor final class MathInputController: ObservableObject {
    weak var textView: NSTextView?

    func insert(_ latex: String, wrap: Bool) {
        guard let tv = textView else { return }
        let before = tv.string, sel = tv.selectedRange()
        let edit = MathPalette.insert(latex, into: before, selection: sel, wrap: wrap)
        let tail = (before as NSString).length - NSMaxRange(sel)
        let newLen = (edit.text as NSString).length
        let piece = (edit.text as NSString).substring(with: NSRange(location: sel.location, length: newLen - tail - sel.location))
        if tv.shouldChangeText(in: sel, replacementString: piece) {
            tv.textStorage?.replaceCharacters(in: sel, with: piece)
            tv.didChangeText()                       // registers undo and updates the SwiftUI binding
        }
        tv.setSelectedRange(edit.selection)
        tv.window?.makeFirstResponder(tv)
    }
    func undo() { textView?.undoManager?.undo() }
    func redo() { textView?.undoManager?.redo() }
    func focus() { if let tv = textView { tv.window?.makeFirstResponder(tv) } }
}

private struct MathTextView: NSViewRepresentable {
    @Binding var text: String
    let controller: MathInputController
    var fontSize: CGFloat
    var locked: Bool
    var onSubmit: (() -> Void)?

    func makeNSView(context: Context) -> NSScrollView {
        let sv = NSTextView.scrollableTextView()
        let tv = sv.documentView as! NSTextView
        tv.delegate = context.coordinator
        tv.allowsUndo = true; tv.isRichText = false
        tv.isAutomaticQuoteSubstitutionEnabled = false; tv.isAutomaticDashSubstitutionEnabled = false; tv.isAutomaticTextReplacementEnabled = false
        tv.font = .monospacedSystemFont(ofSize: fontSize, weight: .regular)
        tv.textContainerInset = NSSize(width: 6, height: 6)
        tv.drawsBackground = false
        tv.setAccessibilityLabel("Answer")
        sv.drawsBackground = false; sv.hasVerticalScroller = true
        controller.textView = tv
        tv.string = text
        return sv
    }
    func updateNSView(_ sv: NSScrollView, context: Context) {
        let tv = sv.documentView as! NSTextView
        context.coordinator.parent = self
        if tv.string != text { let r = tv.selectedRange(); tv.string = text; tv.setSelectedRange(NSRange(location: min(r.location, (text as NSString).length), length: 0)) }
        tv.isEditable = !locked
        controller.textView = tv
    }
    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: MathTextView
        init(_ p: MathTextView) { parent = p }
        func textDidChange(_ n: Notification) { if let tv = n.object as? NSTextView { parent.text = tv.string } }
        func textView(_ tv: NSTextView, doCommandBy sel: Selector) -> Bool {
            // Tab walks the ▢ slots of an inserted template; Return submits single-line answers.
            if sel == #selector(NSResponder.insertTab(_:)), let r = MathPalette.nextPlaceholder(in: tv.string, after: NSMaxRange(tv.selectedRange())) { tv.setSelectedRange(r); return true }
            if sel == #selector(NSResponder.insertNewline(_:)), let submit = parent.onSubmit { submit(); return true }
            return false
        }
    }
}

/// An answer field with an Insert Math palette. `prose` = the answer is text with `$…$` math inside; otherwise the whole answer is math (LaTeX source).
struct MathInputField: View {
    @Binding var text: String
    var prose = false
    var locked = false
    var fontSize: CGFloat = 15
    var minHeight: CGFloat = 70
    var label = "Your answer"
    var onSubmit: (() -> Void)? = nil
    @StateObject private var ctl = MathInputController()
    @State private var showPalette = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Button { showPalette.toggle() } label: { Label("Insert Math", systemImage: "function") }
                    .keyboardShortcut("m", modifiers: [.command, .shift]).disabled(locked).help("Insert a symbol or template at the cursor (⇧⌘M)")
                    .popover(isPresented: $showPalette, arrowEdge: .bottom) {
                        MathPaletteView { ctl.insert($0, wrap: prose) }
                            .onDisappear { ctl.focus() }
                    }
                Button { ctl.undo() } label: { Image(systemName: "arrow.uturn.backward") }.disabled(locked).help("Undo (⌘Z)").accessibilityLabel("Undo")
                Button { ctl.redo() } label: { Image(systemName: "arrow.uturn.forward") }.disabled(locked).help("Redo (⇧⌘Z)").accessibilityLabel("Redo")
                Spacer()
                if MathPalette.hasPlaceholders(text) { Text("Tab moves to the next ▢").font(.caption).foregroundStyle(Theme.textSecondary) }
            }.controlSize(.small)
            MathTextView(text: $text, controller: ctl, fontSize: fontSize, locked: locked, onSubmit: onSubmit)
                .frame(minHeight: minHeight).fieldSurface().accessibilityLabel(label)
            preview
        }
    }

    @ViewBuilder private var preview: some View {
        if !text.trimmed.isEmpty {
            if prose { Card { RichText(text: text) } }
            else if (try? Latex.parse(text)) != nil { HStack { Text("Preview").font(.caption.weight(.semibold)).foregroundStyle(Theme.textSecondary); MathView(latex: text, size: 20) } }
            else { Text("Preview unavailable: this uses notation Learn Anyway can’t typeset. Your input is kept as written.").font(.caption).foregroundStyle(Theme.textSecondary) }
        }
    }
}

/// Floating, searchable, categorized palette.
struct MathPaletteView: View {
    var onPick: (String) -> Void
    @State private var query = ""
    @State private var category = MathPalette.categories[0].title

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("Search symbols (e.g. integral, sigma)", text: $query).textFieldStyle(.roundedBorder).accessibilityLabel("Search math symbols")
            if query.trimmed.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 4) {
                        ForEach(MathPalette.categories) { c in
                            Button(c.title) { category = c.title }.buttonStyle(.plain).padding(.horizontal, 8).padding(.vertical, 3)
                                .background(category == c.title ? Theme.accent.opacity(0.2) : Color.clear, in: Capsule())
                                .accessibilityAddTraits(category == c.title ? .isSelected : [])
                        }
                    }
                }
            }
            let items = query.trimmed.isEmpty ? (MathPalette.categories.first { $0.title == category }?.items ?? []) : MathPalette.search(query)
            ScrollView {
                if items.isEmpty { Text("No matches").foregroundStyle(Theme.textSecondary).padding() }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 56), spacing: 6)], spacing: 6) {
                    ForEach(items) { it in
                        Button { onPick(it.latex) } label: {
                            Group { if it.isTemplate, (try? Latex.parse(it.latex)) != nil { MathView(latex: it.latex, size: 13) } else { Text(it.label).font(.system(size: 16, design: .serif)) } }
                                .frame(maxWidth: .infinity, minHeight: 34)
                        }
                        .buttonStyle(.bordered).help(it.name).accessibilityLabel(it.name)
                    }
                }
            }.frame(height: 220)
        }.padding(12).frame(width: 340)
    }
}

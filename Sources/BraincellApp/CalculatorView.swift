import SwiftUI
import AppKit
import BraincellCore

/// A basic scientific calculator in its own floating, non-modal window: drag it anywhere, keep working in the app behind it, close it with the ✕.
@MainActor
final class CalculatorPanel {
    static let shared = CalculatorPanel()
    private var panel: NSPanel?

    func toggle(model: AppModel) {
        if let p = panel, p.isVisible { p.close(); return }
        let p = panel ?? makePanel(model)
        panel = p
        p.orderFrontRegardless()
    }

    private func makePanel(_ model: AppModel) -> NSPanel {
        let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 300, height: 420), styleMask: [.titled, .closable, .utilityWindow, .resizable], backing: .buffered, defer: false)
        p.title = "Calculator"
        p.isFloatingPanel = true                 // stays above the practice window
        p.hidesOnDeactivate = false
        p.becomesKeyOnlyIfNeeded = false
        p.isReleasedWhenClosed = false
        p.isMovableByWindowBackground = true
        p.contentView = NSHostingView(rootView: CalculatorRoot(model: model))
        p.setFrameAutosaveName("LearnAnywayCalculator")
        if !p.setFrameUsingName("LearnAnywayCalculator") { p.center() }
        return p
    }
}

/// The panel lives outside the main window, so it applies the app's theme and appearance setting itself.
struct CalculatorRoot: View {
    @ObservedObject var model: AppModel
    var body: some View {
        CalculatorView().buttonStyle(.secondary).textFieldStyle(.plain).foregroundStyle(Theme.textPrimary).tint(Theme.accent)
            .background(Theme.background).preferredColorScheme(model.appearance.colorScheme)
    }
}

struct CalculatorView: View {
    @State private var expr = ""
    @State private var result = ""
    @State private var degrees = true
    @State private var ans = 0.0
    @State private var error: String?
    @FocusState private var focused: Bool

    private let rows: [[(String, String)]] = [
        [("sin", "sin("), ("cos", "cos("), ("tan", "tan("), ("(", "("), (")", ")")],
        [("ln", "ln("), ("log", "log("), ("√", "sqrt("), ("x²", "^2"), ("xʸ", "^")],
        [("e", "e"), ("π", "pi"), ("n!", "!"), ("1/x", "1/("), ("÷", "÷")],
        [("7", "7"), ("8", "8"), ("9", "9"), ("%", "%"), ("×", "×")],
        [("4", "4"), ("5", "5"), ("6", "6"), ("Ans", "ans"), ("−", "−")],
        [("1", "1"), ("2", "2"), ("3", "3"), ("⌫", "⌫"), ("+", "+")],
        [("0", "0"), (".", "."), ("±", "±"), ("C", "C"), ("=", "=")],
    ]

    var body: some View {
        VStack(spacing: 8) {
            VStack(alignment: .trailing, spacing: 2) {
                TextField("0", text: $expr).textFieldStyle(.plain).font(.system(size: 18, design: .monospaced)).multilineTextAlignment(.trailing).focused($focused)
                    .onSubmit(equals).accessibilityLabel("Expression")
                Text(error ?? result).font(.system(size: 26, weight: .semibold, design: .rounded)).foregroundStyle(error == nil ? Color.primary : Theme.attention)
                    .lineLimit(1).minimumScaleFactor(0.5).frame(maxWidth: .infinity, alignment: .trailing).textSelection(.enabled).accessibilityLabel(error ?? "Result \(result)")
            }
            .padding(10).background(Theme.surface, in: RoundedRectangle(cornerRadius: 8))
            Picker("", selection: $degrees) { Text("Degrees").tag(true); Text("Radians").tag(false) }.pickerStyle(.segmented).labelsHidden().controlSize(.small)
            Grid(horizontalSpacing: 6, verticalSpacing: 6) {
                ForEach(rows.indices, id: \.self) { r in
                    GridRow { ForEach(rows[r].indices, id: \.self) { c in key(rows[r][c].0, rows[r][c].1) } }
                }
            }
        }
        .padding(12).frame(minWidth: 280, minHeight: 400)
        .onAppear { focused = true }
    }

    private func key(_ label: String, _ token: String) -> some View {
        Button { press(token) } label: { Text(label).font(.system(size: 15, weight: token == "=" ? .bold : .regular, design: .rounded)).frame(maxWidth: .infinity, minHeight: 34) }
            .tint(token == "=" ? Theme.accent : nil).accessibilityLabel(label)
    }

    private func press(_ t: String) {
        error = nil
        switch t {
        case "C": expr = ""; result = ""
        case "⌫": if !expr.isEmpty { expr.removeLast() }
        case "=": equals()
        case "±": expr = expr.hasPrefix("-(") && expr.hasSuffix(")") ? String(expr.dropFirst(2).dropLast()) : (expr.isEmpty ? "-" : "-(" + expr + ")")
        default: expr += t
        }
        focused = true
    }

    private func equals() {
        guard !expr.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        switch Calculator.evaluate(expr, degrees: degrees, ans: ans) {
        case .success(let v): ans = v; result = Calculator.format(v); error = nil
        case .failure(let e): switch e { case .syntax(let m): error = "Check the expression: \(m)"; case .domain(let m): error = m }
        }
    }
}

extension QuestionSpec {
    /// Questions where a calculator is plausibly useful: numeric answers, or content that contains math.
    var isMathy: Bool {
        if type == .numeric { return true }
        return content.contains { b in
            if b.kind == .math { return true }
            let t = b.text ?? ""; return t.contains("\\(") || t.contains("\\[") || t.contains("$")
        }
    }
}

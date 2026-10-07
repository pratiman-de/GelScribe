import AppKit
import GelKit
import SwiftUI

/// Size for a ladder tick. Pre-filled with the next size in the ladder's list — a guess you confirm with Return,
/// or replace by typing or picking another size.
struct TickEditor: View {
    let initial: Double?
    let isGuess: Bool
    let suggestion: Double?
    let ladderSizes: [Double]
    let unit: String
    let onCommit: (Double?) -> Void
    let onSkip: () -> Void
    let onDelete: () -> Void

    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Band size").font(.headline)
                if isGuess {
                    Text("guessed").font(.caption.weight(.semibold)).foregroundStyle(.yellow)
                        .padding(.horizontal, 6).padding(.vertical, 1)
                        .overlay(Capsule().strokeBorder(Color.yellow.opacity(0.7), style: StrokeStyle(lineWidth: 1, dash: [3, 2])))
                        .help("Assigned in order from the ladder list. Press Return to confirm, or pick the right size.")
                }
            }
            HStack(spacing: 8) {
                TextField("size", text: $text)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .rounded).monospacedDigit())
                    .frame(width: 96)
                    .focused($focused)
                    .onSubmit(commit)
                Text(unit).foregroundStyle(.secondary)
            }
            if !ladderSizes.isEmpty {
                LazyVGrid(columns: Array(repeating: GridItem(.fixed(46), spacing: 6), count: 5), alignment: .leading, spacing: 6) {
                    ForEach(ladderSizes, id: \.self) { s in
                        Button(FigureLayoutEngine.formatSize(s)) {
                            text = FigureLayoutEngine.formatSize(s)
                            commit()
                        }
                        .buttonStyle(ChipStyle(highlighted: s == (initial ?? suggestion)))
                    }
                }
            }
            HStack {
                Button("Not a ladder band", action: onSkip)
                    .buttonStyle(.borderless)
                    .help("Keep the mark but give it no size (dye front, artifact)")
                Spacer()
                Button(role: .destructive, action: onDelete) { Image(systemName: "trash") }
                    .buttonStyle(.borderless).foregroundStyle(.red).help("Delete tick")
                Button("Done", action: commit).keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(width: 296)
        .onAppear {
            text = (initial ?? suggestion).map(FigureLayoutEngine.formatSize) ?? ""
            focused = true
        }
    }

    private func commit() {
        let t = text.replacingOccurrences(of: ",", with: ".").trimmingCharacters(in: .whitespaces)
        onCommit(t.isEmpty ? nil : Double(t))
    }
}

/// Name for a band at the gel edge, such as the protein it is.
struct NameEditor: View {
    let initial: BandAnnotation
    let recent: [String]
    let size: Double
    let onCommit: (String, AnnotationMarker) -> Void
    let onSize: (Double) -> Void
    let onDelete: () -> Void
    /// Takes a name off the recent list (right-click a name).
    var onForget: (String) -> Void = { _ in }

    @State private var text = ""
    @State private var shown: [String] = []
    @State private var marker: AnnotationMarker = .arrow
    @State private var pt: Double = 7

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Band name").font(.headline)
            LabelField(text: $text, placeholder: "Name") { onCommit(text, marker) }
                .help("Return to finish · ⌘↩ starts a new line")
            Picker("Marker", selection: $marker) {
                Text("Arrow").tag(AnnotationMarker.arrow)
                Text("Tick").tag(AnnotationMarker.tick)
                Text("Bracket").tag(AnnotationMarker.bracket)
                Text("Text").tag(AnnotationMarker.none)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .controlSize(.small)
            .frame(maxWidth: .infinity)
            .help("Marker beside the name: arrow, short tick, bracket (spans y to y2) or text only")
            EditorRow("Size") { SizeStepper(value: $pt) { onSize($0) } }
            if !shown.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Recent").font(.caption).foregroundStyle(.secondary)
                    FlowRow(items: shown) { name in
                        Button(name) { text = name; onCommit(name, marker) }
                            .buttonStyle(ChipStyle(highlighted: false))
                            .help("Right-click to remove it from the recent names")
                            .contextMenu {
                                Button("Remove from Recent Names") { shown.removeAll { $0 == name }; onForget(name) }
                            }
                    }
                }
            }
            Divider()
            HStack {
                Button(role: .destructive, action: onDelete) { Label("Delete", systemImage: "trash") }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.red)
                Spacer()
                Button("Done") { onCommit(text, marker) }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(PrimaryButtonStyle())
            }
        }
        .padding(16)
        .frame(width: EditorLayout.width + 32)
        .onAppear {
            text = initial.text
            marker = initial.marker
            pt = size
            shown = recent
        }
    }
}

struct TextEditorPopover: View {
    let title: String
    let initial: String
    /// Size of this label and what the stepper changes ("this label" or the whole kind).
    let size: Double
    let sizeScope: String
    let onCommit: (String) -> Void
    let onSize: (Double) -> Void
    @State private var text = ""
    @State private var pt: Double = 7

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.headline)
            LabelField(text: $text) { onCommit(text) }
                .help("Return to finish · ⌘↩ starts a new line")
            EditorRow("Size") { SizeStepper(value: $pt) { onSize($0) } }
            Text("The size changes \(sizeScope). ⌘↩ starts a new line.").font(.caption).foregroundStyle(.secondary)
            Divider()
            HStack {
                Spacer()
                Button("Done") { onCommit(text) }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(PrimaryButtonStyle())
            }
        }
        .padding(16)
        .frame(width: EditorLayout.width + 32)
        .onAppear { text = initial; pt = size }
    }
}

/// "− 7 pt +" in one rounded box, so the number and its unit read as one value: half-point steps, typing allowed.
struct SizeStepper: View {
    @Binding var value: Double
    var onChange: (Double) -> Void

    var body: some View {
        HStack(spacing: 0) {
            step("minus", -0.5, help: "Smaller")
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                TextField("", value: Binding(get: { value }, set: { set($0) }), format: .number.precision(.fractionLength(0...1)))
                    .textFieldStyle(.plain)
                    .multilineTextAlignment(.trailing)
                    .font(.system(.body, design: .rounded).monospacedDigit())
                    .frame(width: 30)
                Text("pt").font(.callout).foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }
            .frame(width: 54)
            step("plus", 0.5, help: "Bigger")
        }
        .padding(.horizontal, 2)
        .frame(height: 24)
        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color.ink.opacity(0.07)))
        .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(Color.ink.opacity(0.13), lineWidth: 1))
    }

    private func step(_ symbol: String, _ delta: Double, help: String) -> some View {
        Button { set(value + delta) } label: {
            Image(systemName: symbol)
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(.secondary)
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }

    private func set(_ v: Double) {
        let x = min(max((v * 2).rounded() / 2, 3), 48)
        value = x
        onChange(x)
    }
}

/// Content width of the canvas editors (band name, label text).
enum EditorLayout { static let width: CGFloat = 264 }

/// "Size   [control]" with the label in a fixed column, so editor rows line up.
struct EditorRow<Control: View>: View {
    let title: String
    @ViewBuilder let control: Control
    init(_ title: String, @ViewBuilder control: () -> Control) { self.title = title; self.control = control() }
    var body: some View {
        HStack(spacing: 10) {
            Text(title).foregroundStyle(.secondary).frame(width: 48, alignment: .leading)
            control
            Spacer(minLength: 0)
        }
    }
}

struct ChipStyle: ButtonStyle {
    let highlighted: Bool
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .semibold, design: .rounded).monospacedDigit())
            .padding(.horizontal, 8)
            .frame(minWidth: 46, minHeight: 24)
            .background(
                Capsule().fill(highlighted ? Color.accentColor : Color.ink.opacity(configuration.isPressed ? 0.22 : 0.1))
            )
            .foregroundStyle(highlighted ? Color.white : Color.primary)
    }
}

/// Wrapping row of chips.
struct FlowRow<Item: Hashable, Content: View>: View {
    let items: [Item]
    @ViewBuilder let content: (Item) -> Content
    var body: some View {
        FlowLayout(spacing: 6) { ForEach(items, id: \.self) { content($0) } }
    }
}

struct FlowLayout: Layout {
    var spacing: CGFloat = 6
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxW = proposal.width ?? 280
        var x: CGFloat = 0, y: CGFloat = 0, rowH: CGFloat = 0, widest: CGFloat = 0
        for s in subviews {
            let sz = s.sizeThatFits(.unspecified)
            if x > 0 && x + sz.width > maxW { x = 0; y += rowH + spacing; rowH = 0 }
            x += sz.width + spacing
            rowH = max(rowH, sz.height)
            widest = max(widest, x - spacing)
        }
        return CGSize(width: min(maxW, widest), height: y + rowH)
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowH: CGFloat = 0
        for s in subviews {
            let sz = s.sizeThatFits(.unspecified)
            if x > bounds.minX && x + sz.width > bounds.maxX { x = bounds.minX; y += rowH + spacing; rowH = 0 }
            s.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(sz))
            x += sz.width + spacing
            rowH = max(rowH, sz.height)
        }
    }
}

/// An angle in degrees: type a value, or click in and press ↑ ↓ to change it a little at a time (⇧ for more). What's
/// typed or stepped to is kept inside `range` and to two decimals, and the field shows what was kept.
/// AppKit underneath, because the field editor would otherwise take the arrow keys to move the caret.
struct AngleField: NSViewRepresentable {
    let value: Double
    var range: ClosedRange<Double> = -45...45
    var step = 0.1
    var bigStep = 1.0
    var toolTip = "Click, then ↑ ↓ to turn 0.1° (⇧ 1°). Positive turns counter-clockwise."
    let onChange: (Double) -> Void

    func makeNSView(context: Context) -> NSTextField {
        let f = NSTextField(string: Self.format(value))
        f.bezelStyle = .roundedBezel
        f.alignment = .center
        f.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        f.delegate = context.coordinator
        f.toolTip = toolTip
        return f
    }

    func updateNSView(_ f: NSTextField, context: Context) {
        context.coordinator.parent = self
        f.isEnabled = context.environment.isEnabled
        f.toolTip = toolTip
        let s = Self.format(value)
        if f.currentEditor() == nil, f.stringValue != s { f.stringValue = s }   // never under the user's typing
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    /// Up to two decimals, a dot always: "0", "-2.3", "-2.35".
    static func format(_ v: Double) -> String {
        guard abs(v) >= 0.005 else { return "0" }
        var s = String(format: "%.2f", v)
        while s.hasSuffix("0") { s.removeLast() }
        if s.hasSuffix(".") { s.removeLast() }
        return s
    }

    /// A number (not "nan" or "inf"), a comma or a dot for the decimals, a real minus sign too, the degree sign left off.
    static func parse(_ s: String) -> Double? {
        Double(s.replacingOccurrences(of: ",", with: ".").replacingOccurrences(of: "−", with: "-")
            .replacingOccurrences(of: "°", with: "").trimmingCharacters(in: .whitespaces)).flatMap { $0.isFinite ? $0 : nil }
    }

    /// `v` inside the range, to two decimals.
    func kept(_ v: Double) -> Double { min(max((v * 100).rounded() / 100, range.lowerBound), range.upperBound) }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: AngleField
        init(_ parent: AngleField) { self.parent = parent }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            let step: Double
            switch selector {
            case #selector(NSResponder.moveUp(_:)): step = parent.step
            case #selector(NSResponder.moveDown(_:)): step = -parent.step
            case #selector(NSResponder.moveUpAndModifySelection(_:)): step = parent.bigStep
            case #selector(NSResponder.moveDownAndModifySelection(_:)): step = -parent.bigStep
            default: return false
            }
            // step from what the field shows: the model may not have caught up between fast presses
            let base = AngleField.parse(textView.string) ?? parent.value
            let v = parent.kept(base + step)
            textView.string = AngleField.format(v)
            textView.selectAll(nil)
            parent.onChange(v)
            return true
        }

        func controlTextDidEndEditing(_ note: Notification) {
            guard let f = note.object as? NSTextField else { return }
            guard let typed = AngleField.parse(f.stringValue) else { f.stringValue = AngleField.format(parent.value); return }
            let v = parent.kept(typed)
            f.stringValue = AngleField.format(v)   // what was kept, which may not be what was typed (60 in a 0 to 45 field)
            if v != parent.value { parent.onChange(v) }
        }
    }
}

/// A label's text, focused and selected when it appears. Return finishes; ⌘↩ (or ⌥↩) puts a line break in the label.
struct LabelField: NSViewRepresentable {
    @Binding var text: String
    var placeholder = ""
    var onSubmit: () -> Void = {}

    func makeNSView(context: Context) -> NSTextField {
        let f = Field(string: text)
        f.placeholderString = placeholder
        f.bezelStyle = .roundedBezel
        f.usesSingleLineMode = false
        f.cell?.wraps = true
        f.cell?.isScrollable = false
        f.lineBreakMode = .byWordWrapping
        f.font = .systemFont(ofSize: NSFont.systemFontSize)
        f.delegate = context.coordinator
        return f
    }

    func updateNSView(_ f: NSTextField, context: Context) {
        context.coordinator.parent = self
        if f.currentEditor() == nil, f.stringValue != text { f.stringValue = text }
    }

    /// Grows a line at a time as the label gets more.
    func sizeThatFits(_ proposal: ProposedViewSize, nsView f: NSTextField, context: Context) -> CGSize? {
        let w = proposal.width ?? EditorLayout.width
        let lines = max(1, context.coordinator.parent.text.components(separatedBy: "\n").count)
        let lh = ceil((f.font ?? .systemFont(ofSize: NSFont.systemFontSize)).boundingRectForFont.height)
        return CGSize(width: w, height: CGFloat(lines) * lh + 6)
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Field: NSTextField {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window != nil { DispatchQueue.main.async { self.window?.makeFirstResponder(self) } }
        }

        // ⌘↩ arrives as a key equivalent, before the text gets it
        override func performKeyEquivalent(with e: NSEvent) -> Bool {
            if let editor = currentEditor() as? NSTextView, e.type == .keyDown, e.keyCode == 36 || e.keyCode == 76,
               e.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command {
                editor.insertNewlineIgnoringFieldEditor(nil)
                return true
            }
            return super.performKeyEquivalent(with: e)
        }
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: LabelField
        init(_ parent: LabelField) { self.parent = parent }

        func controlTextDidChange(_ n: Notification) {
            guard let f = n.object as? NSTextField else { return }
            parent.text = (f.currentEditor() as? NSTextView)?.string ?? f.stringValue
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy sel: Selector) -> Bool {
            guard sel == #selector(NSResponder.insertNewline(_:)) else { return false }   // ⌥↩ still inserts a line break
            parent.text = textView.string
            parent.onSubmit()
            return true
        }
    }
}

import AppKit
import Observation
import SwiftUI

// Keyboard shortcuts the user can change (Settings → Shortcuts). Tools are single keys on the canvas; commands
// are menu shortcuts and need ⌘ or ⌃ so they never fire while typing.

/// A key with modifiers, as the user set it.
struct KeyCombo: Codable, Hashable {
    /// One character, unshifted and lowercased: "e", "=", "'", "0".
    var key: String
    var command = false, shift = false, option = false, control = false

    init(_ key: String, command: Bool = false, shift: Bool = false, option: Bool = false, control: Bool = false) {
        self.key = key; self.command = command; self.shift = shift; self.option = option; self.control = control
    }

    /// From a key press; nil for keys a shortcut can't use (space, arrows, function keys…).
    init?(event e: NSEvent) {
        guard let ch = e.characters(byApplyingModifiers: [])?.lowercased(), ch.count == 1, let c = ch.first,
              c.isASCII, !c.isWhitespace, c.isLetter || c.isNumber || c.isPunctuation || c.isSymbol else { return nil }
        let f = e.modifierFlags
        self.init(ch, command: f.contains(.command), shift: f.contains(.shift), option: f.contains(.option),
                  control: f.contains(.control))
    }

    /// A menu item's shortcut; an uppercase key equivalent means ⇧.
    init?(menuItem it: NSMenuItem) {
        guard it.keyEquivalent.count == 1, let ch = it.keyEquivalent.first else { return nil }
        let f = it.keyEquivalentModifierMask
        self.init(String(ch).lowercased(), command: f.contains(.command), shift: f.contains(.shift) || ch.isUppercase,
                  option: f.contains(.option), control: f.contains(.control))
    }

    var hasMenuModifier: Bool { command || control }

    var keyboardShortcut: KeyboardShortcut {
        var m: EventModifiers = []
        if command { m.insert(.command) }
        if shift { m.insert(.shift) }
        if option { m.insert(.option) }
        if control { m.insert(.control) }
        return KeyboardShortcut(KeyEquivalent(Character(key)), modifiers: m)
    }

    /// "⌃⌥⇧⌘E", the way macOS menus write it.
    var display: String {
        (control ? "⌃" : "") + (option ? "⌥" : "") + (shift ? "⇧" : "") + (command ? "⌘" : "") + (key == "-" ? "−" : key.uppercased())
    }
}

enum ShortcutID: String, CaseIterable, Identifiable {
    case toolSelect, toolLanes, toolLadder, toolNames, toolCrop, toolStraighten, toolPan
    case exportPDF, exportTIFF, exportPNG, exportSVG, copyFigure
    case newGelWithLabels, copyLabels, pasteLabels, pasteLabelsAndPositions
    case biggerText, smallerText
    case zoomFit, zoomActual, zoomIn, zoomOut, toggleGuides, toggleInspector, brightnessContrast

    var id: String { rawValue }

    var tool: Tool? {
        switch self {
        case .toolSelect: .select
        case .toolLanes: .lanes
        case .toolLadder: .ladder
        case .toolNames: .names
        case .toolCrop: .crop
        case .toolStraighten: .straighten
        case .toolPan: .pan
        default: nil
        }
    }

    static func forTool(_ t: Tool) -> ShortcutID { allCases.first { $0.tool == t }! }

    var section: String {
        switch self {
        case _ where tool != nil: "Tools (a single key on the canvas)"
        case .exportPDF, .exportTIFF, .exportPNG, .exportSVG, .copyFigure: "Export"
        case .newGelWithLabels, .copyLabels, .pasteLabels, .pasteLabelsAndPositions: "Labels"
        case .biggerText, .smallerText: "Text"
        default: "View"
        }
    }

    var title: String {
        if let t = tool { return t.title }
        switch self {
        case .exportPDF: return "Export PDF…"
        case .exportTIFF: return "Export TIFF…"
        case .exportPNG: return "Export PNG…"
        case .exportSVG: return "Export SVG…"
        case .copyFigure: return "Copy Figure"
        case .newGelWithLabels: return "New Gel with These Labels…"
        case .copyLabels: return "Copy Labels"
        case .pasteLabels: return "Paste Labels"
        case .pasteLabelsAndPositions: return "Paste Labels and Positions"
        case .biggerText: return "Bigger Text"
        case .smallerText: return "Smaller Text"
        case .zoomFit: return "Zoom to Fit"
        case .zoomActual: return "Actual Pixels"
        case .zoomIn: return "Zoom In"
        case .zoomOut: return "Zoom Out"
        case .toggleGuides: return "Show or Hide Guides"
        case .brightnessContrast: return "Brightness & Contrast…"
        case .toggleInspector: return "Show or Hide Inspector"
        default: return rawValue
        }
    }

    var defaultCombo: KeyCombo? {
        if let t = tool { return KeyCombo(String(t.key)) }
        switch self {
        case .exportPDF: return KeyCombo("e", command: true)
        case .copyFigure: return KeyCombo("c", command: true, shift: true)
        case .newGelWithLabels: return KeyCombo("n", command: true, shift: true)
        case .copyLabels: return KeyCombo("c", command: true, option: true)
        case .pasteLabels: return KeyCombo("v", command: true, option: true)
        case .pasteLabelsAndPositions: return KeyCombo("v", command: true, shift: true, option: true)
        case .biggerText: return KeyCombo("=", command: true, shift: true)
        case .smallerText: return KeyCombo("-", command: true, shift: true)
        case .zoomFit: return KeyCombo("0", command: true)
        case .zoomActual: return KeyCombo("1", command: true)
        case .zoomIn: return KeyCombo("+", command: true)
        case .zoomOut: return KeyCombo("-", command: true)
        case .toggleGuides: return KeyCombo("'", command: true)
        case .toggleInspector: return KeyCombo("i", command: true, option: true)
        case .brightnessContrast: return KeyCombo("b", command: true, shift: true)
        default: return nil
        }
    }
}

/// The shortcuts in use: the defaults, with the user's changes on top. Saved in the app's settings.
@Observable
final class ShortcutStore {
    static let shared = ShortcutStore()
    private static let defaultsKey = "shortcuts"

    /// The user's changes; a nil value means "no shortcut".
    private var changes: [String: KeyCombo?]

    private init() {
        let data = UserDefaults.standard.data(forKey: Self.defaultsKey)
        changes = data.flatMap { try? JSONDecoder().decode([String: KeyCombo?].self, from: $0) } ?? [:]
    }

    func combo(_ id: ShortcutID) -> KeyCombo? {
        if let change = changes[id.rawValue] { return change }
        return id.defaultCombo
    }

    func shortcut(_ id: ShortcutID) -> KeyboardShortcut? { combo(id)?.keyboardShortcut }

    func isChanged(_ id: ShortcutID) -> Bool { changes[id.rawValue] != nil }

    /// The tool a bare key on the canvas switches to.
    func tool(forKey key: Character) -> Tool? {
        let k = String(key).lowercased()
        return ShortcutID.allCases.first { $0.tool != nil && combo($0).map { $0.key == k && !$0.hasMenuModifier && !$0.option } == true }?.tool
    }

    func toolKey(_ t: Tool) -> String { combo(.forTool(t))?.display ?? "" }

    /// Sets a shortcut; another command that had the same keys loses them. Returns that command, if any.
    @discardableResult
    func set(_ id: ShortcutID, _ combo: KeyCombo?) -> ShortcutID? {
        var displaced: ShortcutID?
        if let combo {
            for other in ShortcutID.allCases where other != id && self.combo(other) == combo {
                changes[other.rawValue] = .some(nil)
                displaced = other
            }
        }
        changes[id.rawValue] = combo == id.defaultCombo ? nil : .some(combo)
        if let d = displaced, d.defaultCombo == nil { changes[d.rawValue] = nil }   // "none" is its default anyway
        changed()
        return displaced
    }

    /// The title of a menu command outside this list (Save, Close, Quit…) that already uses `combo`. Two menu items
    /// with the same keys means only the first works, so the recorder refuses these.
    func builtInUse(of combo: KeyCombo) -> String? {
        guard !ShortcutID.allCases.contains(where: { self.combo($0) == combo }) else { return nil }   // ours: set() moves it
        func find(_ m: NSMenu) -> String? {
            for it in m.items {
                if KeyCombo(menuItem: it) == combo { return it.title }
                if let sub = it.submenu, let t = find(sub) { return t }
            }
            return nil
        }
        return NSApp.mainMenu.flatMap(find)
    }

    func reset(_ id: ShortcutID) { changes[id.rawValue] = nil; changed() }
    func resetAll() { changes = [:]; changed() }
    var anyChanged: Bool { !changes.isEmpty }

    private func changed() {
        UserDefaults.standard.set(try? JSONEncoder().encode(changes), forKey: Self.defaultsKey)
        // SwiftUI refreshes a menu's key equivalents only when the menu opens, so until then the old keys would
        // still work and the new ones wouldn't. Refresh them once SwiftUI has rebuilt the commands.
        Task {
            try? await Task.sleep(for: .milliseconds(100))
            NSApp.mainMenu.map(Self.refresh)
        }
    }

    private static func refresh(_ m: NSMenu) {
        m.delegate?.menuNeedsUpdate?(m)
        m.items.compactMap(\.submenu).forEach(refresh)
    }
}

// MARK: - Settings → Shortcuts

struct ShortcutsSettings: View {
    @State private var store = ShortcutStore.shared
    @State private var note: String?

    private var sections: [(String, [ShortcutID])] {
        var out: [(String, [ShortcutID])] = []
        for id in ShortcutID.allCases {
            if let i = out.firstIndex(where: { $0.0 == id.section }) { out[i].1.append(id) } else { out.append((id.section, [id])) }
        }
        return out
    }

    var body: some View {
        Form {
            Section {
                Text("Click a shortcut, then press the new keys. Delete clears it, Esc cancels. Tools take a single key; menu commands need ⌘ or ⌃.")
                    .font(.callout).foregroundStyle(.secondary)
                if let note { Text(note).font(.callout).foregroundStyle(.orange) }
            }
            ForEach(sections, id: \.0) { title, ids in
                Section(title) {
                    ForEach(ids) { id in
                        HStack {
                            Text(id.title)
                            Spacer()
                            if store.isChanged(id) {
                                Button { store.reset(id); note = nil } label: { Image(systemName: "arrow.uturn.backward") }
                                    .buttonStyle(.borderless).foregroundStyle(.secondary)
                                    .help("Back to \(id.defaultCombo?.display ?? "none")")
                            }
                            ShortcutRecorder(id: id, store: store) { note = $0 }
                        }
                    }
                }
            }
            Section {
                HStack {
                    Spacer()
                    Button("Reset All to Defaults") { store.resetAll(); note = nil }.disabled(!store.anyChanged)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 620, height: 560)
    }
}

/// Shows a shortcut; click it and press keys to change it.
struct ShortcutRecorder: View {
    let id: ShortcutID
    let store: ShortcutStore
    let onNote: (String?) -> Void
    @State private var recording = false
    @State private var monitor: Any?

    var body: some View {
        Button { recording ? stop() : start() } label: {
            Text(recording ? "Press keys…" : (store.combo(id)?.display ?? "None"))
                .font(.system(.body, design: .rounded).monospacedDigit())
                .foregroundStyle(recording ? Color.accentColor : store.combo(id) == nil ? Color.secondary : Color.primary)
                .frame(minWidth: 96)
        }
        .onDisappear { stop() }
    }

    private func start() {
        recording = true
        onNote(nil)
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { e in
            switch e.keyCode {
            case 53: stop(); return nil                                   // esc: keep it
            case 51, 117: store.set(id, nil); stop(); return nil          // delete: no shortcut
            default: break
            }
            guard let combo = KeyCombo(event: e) else { NSSound.beep(); return nil }
            if id.tool != nil {
                guard !combo.hasMenuModifier, !combo.option, !combo.shift else {
                    onNote("Tools take a single key without ⌘, ⌃, ⌥ or ⇧."); NSSound.beep(); return nil
                }
            } else if !combo.hasMenuModifier {
                onNote("Menu commands need ⌘ or ⌃ with the key, so typing never triggers them."); NSSound.beep(); return nil
            } else if let taken = store.builtInUse(of: combo) {
                onNote("\(combo.display) is already \(taken) in the menus; pick other keys."); NSSound.beep(); return nil
            }
            if let moved = store.set(id, combo) { onNote("\(combo.display) was \(moved.title)'s shortcut; that one has none now.") }
            stop()
            return nil
        }
    }

    private func stop() {
        recording = false
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }
}

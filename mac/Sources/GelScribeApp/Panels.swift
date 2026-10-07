import GelKit
import SwiftUI
import UniformTypeIdentifiers

/// The app's main action buttons, drawn like a selected segment ("Left" in Placement): a flat accent fill with
/// semibold white text. macOS's glass-prominent style puts thinner text on a glossy fill that reads worse.
struct PrimaryButtonStyle: ButtonStyle {
    var large = false
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.controlSize) private var controlSize
    func makeBody(configuration: Configuration) -> some View {
        let small = controlSize == .small || controlSize == .mini
        let font: CGFloat = large ? 15 : small ? 11 : 13
        let shape = RoundedRectangle(cornerRadius: large ? 9 : small ? 5 : 7, style: .continuous)
        return configuration.label
            .font(.system(size: font, weight: .semibold))
            .foregroundStyle(isEnabled ? Color.white : Color.secondary)
            .padding(.horizontal, large ? 16 : small ? 8 : 12)
            .padding(.vertical, large ? 8 : small ? 3 : 5)
            .background(shape.fill(isEnabled ? Color.accentColor.opacity(configuration.isPressed ? 0.8 : 1) : Color.ink.opacity(0.08)))
            .contentShape(shape)
    }
}

// MARK: - Tool palette (floating, left)

struct ToolPalette: View {
    @Bindable var ws: Workspace
    @State private var showSizes = false

    var body: some View {
        VStack(spacing: 6) {
            ForEach([Tool.select, .lanes, .ladder, .names, .crop, .straighten, .pan]) { t in
                let off = t == .lanes && ws.lanesToolOff   // the lane dividers are set on the gel that has them
                ToolButton(symbol: t.symbol, selected: ws.tool == t, help: off ? ws.lanesToolNote : "\(t.title) (\(ShortcutStore.shared.toolKey(t)))") {
                    ws.tool = t
                }
                .disabled(off)
                .opacity(off ? 0.4 : 1)
            }
            Divider().frame(width: 28).padding(.vertical, 4)
            ToolButton(symbol: "textformat.size", selected: showSizes, help: "Text sizes") { showSizes.toggle() }
                .popover(isPresented: $showSizes, arrowEdge: .trailing) {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Text size").font(.headline)
                        TextSizeControls(ws: ws, document: ws.document)
                    }
                    .padding(16)
                    .frame(width: 300)
                }
            ToolButton(symbol: "scope", selected: ws.snapping, help: "Snap to band centers (hold ⌥ to place freely)") {
                ws.snapping.toggle()
            }
            ToolButton(symbol: "circle.lefthalf.filled", selected: false,
                       help: "Brightness & Contrast (\(ShortcutStore.shared.combo(.brightnessContrast)?.display ?? "no shortcut"))") {
                ws.showBrightnessContrast()
            }
            ToolButton(symbol: ws.showGuides ? "eye" : "eye.slash", selected: false, help: "Show or hide guides (⌘')") {
                ws.showGuides.toggle()
            }
        }
        .padding(8)
        .panelGlass(in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
}

struct ToolButton: View {
    let symbol: String
    let selected: Bool
    let help: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .medium))
                .frame(width: 36, height: 36)
                .foregroundStyle(selected ? Color.white : Color.primary.opacity(hovering ? 1 : 0.8))
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(selected ? Color.accentColor : Color.ink.opacity(hovering ? 0.09 : 0))
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
        .onHover { hovering = $0 }
    }
}

// MARK: - Status pill (floating, bottom)

struct StatusPill: View {
    @Bindable var ws: Workspace
    let lanes: Int

    var body: some View {
        VStack(spacing: 8) {
            // a gel whose image can't be read is missing from the figure: said here, wherever the user is working
            if let why = ws.unreadableGel {
                Label { Text(verbatim: why) } icon: { Image(systemName: "exclamationmark.triangle.fill") }
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Color.orange)
                    .lineLimit(2)
                    .padding(.horizontal, 14).padding(.vertical, 7)
                    .panelGlass(in: Capsule())
            }
            pill
        }
    }

    private var pill: some View {
        HStack(spacing: 14) {
            if let note = ws.llmNote {
                Label("LLM · \(note)", systemImage: "sparkle")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
                    .transition(.opacity)
            } else if ws.placingUnit {
                Label("Place \(ws.project.ladder?.unit ?? "kDa")", systemImage: "arrow.up.and.down")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
                Text("Click at the height where it should sit · Esc cancels")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            } else if let note = ws.toolNote {
                Label { Text(verbatim: note) } icon: { Image(systemName: "exclamationmark.triangle.fill") }
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Color.orange)
                    .lineLimit(1)
            } else {
                Label(ws.tool.title, systemImage: ws.tool.symbol)
                    .font(.system(size: 12, weight: .semibold))
                Text(ws.tool == .crop && ws.activeStrip != nil ? "Drag edges or corners · Return keeps it · Esc puts it back" : ws.tool.hint)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Divider().frame(height: 14)
            if LLMAccess.shared.listeningPort != nil {
                HStack(spacing: 5) {
                    Circle().fill(Color.green).frame(width: 6, height: 6)
                    Text("LLM").font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
                }
                .help("LLM access is on (Settings ⌘,). Every LLM change is one undo step.")
            }
            Text("\(lanes) lane\(lanes == 1 ? "" : "s")")
                .font(.system(size: 12, weight: .medium).monospacedDigit())
                .foregroundStyle(.secondary)
            HStack(spacing: 2) {
                Button { ws.zoomRequest = .zoomOut } label: { Image(systemName: "minus") }
                Button { ws.zoomRequest = .fit } label: { Image(systemName: "arrow.up.left.and.down.right.magnifyingglass") }
                    .help("Zoom to fit (⌘0)")
                Button { ws.zoomRequest = .zoomIn } label: { Image(systemName: "plus") }
            }
            .buttonStyle(.borderless)
            .font(.system(size: 12, weight: .semibold))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 9)
        .panelGlass(in: Capsule())
    }
}

// MARK: - Drop zone (new document)

struct DropZone: View {
    /// The images dropped or chosen, in order; more than one stacks into one figure.
    let onImages: ([URL]) -> Void
    @State private var targeted = false

    var body: some View {
        VStack(spacing: 18) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .interpolation(.high)
                .frame(width: 112, height: 112)
            VStack(spacing: 6) {
                Text("Drop a gel/blot image").font(.title2.weight(.semibold))
                Text("PNG, TIFF or JPEG. Source files are never modified.\nDrop more than one to stack them in one figure.")
                    .multilineTextAlignment(.center)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Button {
                let panel = NSOpenPanel()
                panel.allowedContentTypes = [.png, .tiff, .jpeg, .image]
                panel.allowsMultipleSelection = true
                if panel.runModal() == .OK, !panel.urls.isEmpty { onImages(panel.urls) }
            } label: {
                Label("Choose Image…", systemImage: "folder").padding(.horizontal, 6)
            }
            .buttonStyle(PrimaryButtonStyle(large: true))
            .keyboardShortcut("o", modifiers: [.command, .shift])
        }
        .padding(48)
        .frame(width: 520)
        .panelGlass(in: RoundedRectangle(cornerRadius: 28, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .strokeBorder(style: StrokeStyle(lineWidth: 2, dash: [8, 6]))
                .foregroundStyle(targeted ? Color.accentColor : Color.ink.opacity(0.12))
                .padding(10)
        )
        .dropDestination(for: URL.self) { urls, _ in
            guard !urls.isEmpty else { return false }
            onImages(urls)
            return true
        } isTargeted: { targeted = $0 }
    }
}

// MARK: - Inspector (floating, right)

struct Inspector: View {
    @Bindable var ws: Workspace
    @ObservedObject var document: GelDocument
    @State private var scroll = ScrollPosition(edge: .top)

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 4) {
                ForEach(InspectorTab.allCases) { tab in
                    Button { ws.chooseTab(tab) } label: {
                        Image(systemName: tab.symbol)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(Color.ink)   // left to the glass, they turned white on the light look
                            .frame(width: 44, height: 28)
                            .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(ws.inspectorTab == tab ? Color.ink.opacity(0.14) : .clear))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(tab.title)
                }
            }
            .padding(8)
            Divider().opacity(0.5)
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    switch ws.inspectorTab {
                    case .labels: LabelsPanel(ws: ws, document: document)
                    case .ladder: LadderPanel(ws: ws, document: document)
                    case .names: NamesPanel(ws: ws, document: document)
                    case .figure: FigurePanel(ws: ws, document: document)
                    case .export: ExportPanel(ws: ws, document: document)
                    }
                }
                .padding(16)
                .frame(width: 312, alignment: .leading)
            }
            .scrollPosition($scroll)
            .scrollIndicators(.automatic)
            .clipped()
            .onChange(of: ws.revealStrict) {   // the toolbar's Original pixels badge: the switch is at the top
                DispatchQueue.main.async { withAnimation { scroll.scrollTo(edge: .top) } }
            }
            .onChange(of: ws.revealContrast) {
                DispatchQueue.main.async { withAnimation { scroll.scrollTo(id: BrightnessContrastPanel.anchor, anchor: .top) } }
            }
            .onAppear {   // testing hook: --inspector-scroll Y shows the inspector scrolled down Y points
                if let y = LaunchOptions.shared.value("--inspector-scroll").flatMap(Double.init) {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1) { scroll.scrollTo(y: y) }
                }
            }
        }
        .frame(width: 312)
        .panelGlass(in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }
}

struct PanelSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title.uppercased())
                .font(.system(size: 10.5, weight: .semibold))
                .kerning(0.6)
                .foregroundStyle(.secondary)
            content
        }
    }
}

struct TextSizeControls: View {
    @Bindable var ws: Workspace
    @ObservedObject var document: GelDocument

    var body: some View {
        let st = document.project.style
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text("All text").fontWeight(.semibold)
                Spacer()
                Button { ws.scaleAllText(by: -0.5) } label: { Image(systemName: "textformat.size.smaller") }
                    .help("Everything smaller (⌘⇧−)")
                Button { ws.scaleAllText(by: 0.5) } label: { Image(systemName: "textformat.size.larger") }
                    .help("Everything bigger (⌘⇧=)")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            ForEach(TextKind.allCases) { kind in
                HStack {
                    Text(kind.title)
                    Spacer()
                    SizeStepper(value: .constant(st.size(for: kind))) { ws.setSize($0, for: kind) }
                }
            }
            Text("Click one label on the figure to size just that label.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

struct LabelsPanel: View {
    @Bindable var ws: Workspace
    @ObservedObject var document: GelDocument
    @FocusState private var typingLabels: Bool

    var body: some View {
        let p = document.project
        if case .text(let role)? = ws.selection {
            let kind = TextKind(role: role)
            let own = role.sizeKey.flatMap { p.style.textSizes[$0] } != nil
            PanelSection(title: "Selected label") {
                HStack {
                    Text("“\(ws.text(for: role))”").fontWeight(.semibold).lineLimit(1)
                    Spacer()
                    SizeStepper(value: .constant(p.style.size(for: role))) { ws.setSize($0, forLabel: role) }
                }
                HStack {
                    Text(role.sizeKey == nil ? "Sizes with all \(kind.title.lowercased())"
                         : own ? "Its own size" : "Follows \(kind.title.lowercased())")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    if role.sizeKey != nil {
                        Button("Match \(kind.title.lowercased())") { ws.resetSize(forLabel: role) }
                            .controlSize(.small).disabled(!own)
                    }
                }
            }
        }
        PanelSection(title: "Lanes") {
            HStack {
                Text("\(p.laneCount) lanes").font(.title3.weight(.semibold).monospacedDigit())
                Text("from \(p.lanes.dividers.count) divider\(p.lanes.dividers.count == 1 ? "" : "s")").foregroundStyle(.secondary)
                Spacer()
            }
            Toggle("Count the edges as lanes", isOn: Binding(
                get: { document.project.lanes.outerLanes },
                set: { v in ws.edit("Outer Lanes") { $0.lanes.outerLanes = v; $0.syncLaneCenters(imageWidth: ws.imageWidth, imageHeight: ws.imageHeight) } }))
                .help("The strips before the first and after the last divider are lanes too")
            HStack {
                Button("Lane tool") { ws.tool = .lanes }
                Spacer()
                Button("Clear dividers", role: .destructive) { ws.clearDividers() }
                    .disabled(p.lanes.dividers.isEmpty)
            }
            .controlSize(.small)
        }

        PanelSection(title: "Quick labels") {
            // two-way: typing here relabels the lanes as you go, and labels changed anywhere else show up here
            TextField("µM: Ladder|0{L|P}|50{L|P}|…", text: Binding(get: { ws.quickLabels }, set: { v in
                guard v != ws.quickLabels else { return }
                ws.quickLabels = v
                if typingLabels { ws.quickLabelsTyped() }
            }), axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .font(.system(.body, design: .monospaced))
                .lineLimit(1...4)
                .focused($typingLabels)
                .onSubmit { ws.finishQuickLabels() }
                .onChange(of: typingLabels) { _, typing in if !typing { ws.finishQuickLabels() } }
                .onChange(of: ws.laneLabelShorthand) { _, s in if !typingLabels, ws.quickLabels != s { ws.quickLabels = s } }
                .onAppear { if !typingLabels { ws.quickLabels = ws.laneLabelShorthand } }
            Text("One label per lane, separated by |. Braces put lanes under a label: 0{L|P} is 0 over L and P. "
                 + "Braces nest for more rows: WT{0{L|P}|50{L|P}}. Row titles go first: µM: … (or Strain, µM: … from the top). "
                 + "\\n starts a new line inside a label. The lanes follow as you type.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("Copy") { ws.copyLaneLabels() }
                    .help("Copy this gel's lane labels as one line, to paste into the next gel")
                    .disabled(ws.laneLabelShorthand.isEmpty)
                Button("Paste") { ws.pasteLaneLabels() }
                    .help("Paste lane labels copied from another gel, and apply them")
                Spacer()
            }
            .controlSize(.small)
            // the lane labels' angle: one for the figure, so long labels needn't overlap
            let angleHelp = "Turns the lane labels so long ones don't overlap."
            HStack(spacing: 6) {
                Text("Angle").frame(width: 44, alignment: .leading)
                AngleField(value: p.labelAngle, range: -360...360, step: 1, bigStep: 5, toolTip: angleHelp) { ws.setLabelAngle($0) }
                    .frame(width: 56)
                Text("°").foregroundStyle(.secondary)
                Spacer(minLength: 4)
                ForEach([0.0, 45, 90], id: \.self) { a in
                    Button("\(Int(a))°") { ws.setLabelAngle(a) }
                }
            }
            .controlSize(.small)
            .disabled(!ws.hasLaneLabels)
            .help(angleHelp)
            if let err = ws.lastError { Text(err).font(.caption).foregroundStyle(.orange).lineLimit(3) }
            let labelCount = QuickLabels.laneCount(in: ws.laneLabelShorthand)
            if p.laneCount == 0 {
                Text(labelCount > 0
                     ? "\(labelCount) lane labels ready. Place the lane dividers (L) and each label appears on its lane."
                     : "You can type the labels before or after placing the lanes.")
                    .font(.caption).foregroundStyle(.secondary)
            } else if labelCount > 0 && labelCount != p.laneCount {
                Label("\(labelCount) labels for \(p.laneCount) lanes", systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.orange)
            }
        }

        if p.laneCount > 0 {
            PanelSection(title: "Rows, top to bottom") {
                ForEach(Array(p.rows.enumerated().reversed()), id: \.element.id) { i, row in
                    RowCard(ws: ws, document: document, index: i, row: row, laneCount: p.laneCount)
                }
                Menu {
                    Button("Group Row (numbers over lanes, e.g. 0 · 125)") { ws.addRow(.groups) }
                    Button("Lane Labels Row (one per lane, e.g. L · P)") { ws.addRow(.lanes) }
                } label: {
                    Label("Add Row", systemImage: "plus")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                if p.rows.isEmpty {
                    Text("Or type all lanes in Quick labels above: “50{L|P}” puts 50 over two lanes, L and P.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        if p.laneCount > 0 {
            // always here once there are lanes; typing the first label creates the row
            PanelSection(title: "Lane labels") {
                LazyVGrid(columns: [GridItem(.fixed(22)), GridItem(.flexible())], spacing: 6) {
                    ForEach(1...p.laneCount, id: \.self) { lane in
                        Text("\(lane)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        TextField("lane \(lane)", text: Binding(
                            get: {
                                guard let r = document.project.rows.firstIndex(where: { $0.type == .lanes }) else { return "" }
                                let l = document.project.rows[r].labels
                                return lane <= l.count ? l[lane - 1] : ""
                            },
                            set: { v in ws.setLaneLabel(lane: lane, v) }))
                            .textFieldStyle(.roundedBorder)
                    }
                }
            }
        }

        PanelSection(title: "Title") {
            TextField("e.g. RPS6", text: Binding(get: { document.project.title ?? "" },
                                                set: { v in ws.edit("Title") { $0.title = v.isEmpty ? nil : v } }))
                .textFieldStyle(.roundedBorder)
        }

        PanelSection(title: "Text size") {
            TextSizeControls(ws: ws, document: document)
        }

        PanelSection(title: "Reuse on another gel") {
            Text("Labels, row titles, title, band names, ladder settings and text sizes. Lane dividers and ladder ticks belong to each image, and so do the names on gels other than the one with the lanes.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("Copy Labels") { ws.copyScheme() }.help("⌥⌘C, then Paste Labels (⌥⌘V) in the other gel's window")
                Button("Paste Labels") { ws.pasteScheme(positions: false) }.help("⌥⌘V · with positions: ⌥⇧⌘V")
            }
            .controlSize(.small)
            Text("New gel with these labels: File menu, ⇧⌘N.").font(.caption).foregroundStyle(.secondary)
        }
    }
}

/// One label row. Group rows list their groups with text and lane span.
struct RowCard: View {
    @Bindable var ws: Workspace
    @ObservedObject var document: GelDocument
    let index: Int
    let row: LabelRow
    let laneCount: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 8) {
                Image(systemName: row.type == .groups ? "rectangle.split.2x1" : "textformat.abc")
                    .foregroundStyle(.secondary).frame(width: 18)
                    .help(row.type == .groups ? "Group row: text centered over a span of lanes" : "Lane labels row: one label per lane")
                TextField(row.type == .groups ? "Row title, e.g. µM" : "Row title", text: Binding(
                    get: { document.project.rows.indices.contains(index) ? (document.project.rows[index].name ?? "") : "" },
                    set: { v in ws.edit("Row Title") { if $0.rows.indices.contains(index) { $0.rows[index].name = v } } }))
                    .textFieldStyle(.roundedBorder)
                Button { ws.deleteRow(index) } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.borderless).foregroundStyle(.secondary).help("Delete this row")
            }
            if row.type == .groups {
                ForEach(Array(row.groups.enumerated()), id: \.element.id) { g, grp in
                    HStack(spacing: 5) {
                        TextField("text", text: Binding(get: { grp.text }, set: { ws.updateGroup(row: index, group: g, text: $0) }))
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 62)
                        Text("lanes").font(.caption).foregroundStyle(.secondary)
                        Stepper(value: Binding(get: { grp.first }, set: { ws.updateGroup(row: index, group: g, first: $0) }),
                                in: 1...max(1, laneCount)) { Text("\(grp.first)").monospacedDigit().lineLimit(1).fixedSize() }
                        Text("–").foregroundStyle(.secondary)
                        Stepper(value: Binding(get: { grp.last }, set: { ws.updateGroup(row: index, group: g, last: $0) }),
                                in: 1...max(1, laneCount)) { Text("\(grp.last)").monospacedDigit().lineLimit(1).fixedSize() }
                        Spacer(minLength: 0)
                        Button { ws.deleteGroup(row: index, group: g) } label: { Image(systemName: "minus.circle") }
                            .buttonStyle(.borderless).foregroundStyle(.secondary)
                    }
                    .controlSize(.small)
                }
                HStack {
                    Button { ws.addGroup(row: index) } label: { Label("Add group", systemImage: "plus.circle") }
                        .buttonStyle(.borderless)
                    Spacer()
                    Toggle("Underline", isOn: Binding(get: { row.underline }, set: { ws.setUnderline(row: index, $0) }))
                        .toggleStyle(.checkbox)
                }
                .controlSize(.small)
                // this row's group labels turn about the middle of their lanes, the underline staying flat under them
                let angleHelp = "Turns this row's group labels so long ones don't overlap. The underline stays flat."
                HStack(spacing: 6) {
                    Text("Angle").frame(width: 44, alignment: .leading)
                    AngleField(value: row.rotation, range: -360...360, step: 1, bigStep: 5, toolTip: angleHelp) { ws.setRowAngle(row: index, $0) }
                        .frame(width: 56)
                    Text("°").foregroundStyle(.secondary)
                    Spacer(minLength: 4)
                    ForEach([0.0, 45, 90], id: \.self) { a in
                        Button("\(Int(a))°") { ws.setRowAngle(row: index, a) }
                    }
                }
                .controlSize(.small)
                .help(angleHelp)
            } else {
                Text("Edit these under Lane labels below, or click a label on the figure.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.ink.opacity(0.05)))
    }
}

struct LadderPanel: View {
    @Bindable var ws: Workspace
    @ObservedObject var document: GelDocument
    @State private var sizesText = ""
    @State private var saving = false
    @State private var saveName = ""

    private func fmt(_ v: [Double]) -> String { v.map(FigureLayoutEngine.formatSize).joined(separator: ", ") }

    /// "N ticks for M ladder sizes." wherever the count doesn't match the list, for each group of gels that carries one
    /// ladder on (the others have a ladder of their own). Skipped ticks and ticks hidden by a crop don't count.
    private func tickCountNotes(_ p: GelProject, _ bands: [LadderBand]) -> [String] {
        let sizes = ws.ladderSizes
        guard !sizes.isEmpty else { return [] }
        let groups = p.ladderGroups
        return groups.compactMap { gels in
            let count = bands.filter { !$0.ignore && p.isInFigure(strip: $0.strip, y: $0.y) && gels.contains($0.strip) }.count
            guard count != sizes.count, count > 0 || groups.count == 1 else { return nil }
            let places = gels.map { p.position(of: $0) + 1 }
            let who = groups.count == 1 ? "" : (places.count == 1 ? "Gel \(places[0]): " : "Gels \(places.min()!) to \(places.max()!): ")
            return "\(who)\(count) ticks for \(sizes.count) ladder sizes."
        }
    }

    /// The gel & buffer note, its "Vendor datasheet" linked to the preset's source.
    private func datasheetNote(_ pr: LadderPreset) -> AttributedString {
        var note = AttributedString("Prestained bands run at different apparent sizes on each gel and buffer. Check ")
        var link = AttributedString("Vendor datasheet")
        if !pr.source.isEmpty, let url = URL(string: pr.source) { link.link = url }
        note += link
        note += AttributedString(".")
        return note
    }

    var body: some View {
        let p = document.project
        let presets = LadderLibrary.all()
        let unit = p.ladder?.unit ?? ws.preset?.unit ?? "kDa"
        PanelSection(title: "Ladder") {
            Picker("Preset", selection: Binding(get: { ws.presetID }, set: { ws.choosePreset($0) })) {
                Section("Protein") { ForEach(presets.filter { $0.unit == "kDa" && $0.builtin }) { Text($0.displayName).tag($0.id) } }
                Section("DNA") { ForEach(presets.filter { $0.unit == "bp" && $0.builtin }) { Text($0.displayName).tag($0.id) } }
                let mine = presets.filter { !$0.builtin }
                if !mine.isEmpty { Section("Mine") { ForEach(mine) { Text($0.name).tag($0.id) } } }
            }
            .labelsHidden()
            .help(ws.preset?.displayName ?? "")
            if let pr = ws.preset, !pr.systems.isEmpty {
                Text("Gel & buffer").font(.caption).foregroundStyle(.secondary)
                Picker("Gel & buffer", selection: Binding(get: { ws.system?.id ?? pr.systems[0].id }, set: { ws.chooseSystem($0) })) {
                    Section("Tris-glycine") { ForEach(pr.systems.filter { $0.id.hasPrefix("tg") }) { Text($0.name).tag($0.id) } }
                    Section("NuPAGE Bis-Tris") { ForEach(pr.systems.filter { $0.id.hasPrefix("bt") }) { Text($0.name).tag($0.id) } }
                    Section("NuPAGE Tris-acetate") { ForEach(pr.systems.filter { $0.id.hasPrefix("ta") }) { Text($0.name).tag($0.id) } }
                }
                .labelsHidden()
                Text(datasheetNote(pr))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Text("Sizes, largest first (\(unit)). Edit them to match your ladder").font(.caption).foregroundStyle(.secondary)
            TextField("250, 130, 100, …", text: $sizesText, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .font(.system(.body, design: .monospaced))
                .lineLimit(1...4)
                .onSubmit { ws.setLadderSizes(sizesText) }
            HStack {
                Button("Use these sizes") { ws.setLadderSizes(sizesText) }
                    .disabled(GelOps.parseSizes(sizesText) == ws.ladderSizes)
                Spacer()
                Button("Save as my ladder…") { saveName = ""; saving = true }
            }
            .controlSize(.small)
            if let pr = ws.preset, !pr.notes.isEmpty { Text(pr.notes).font(.caption).foregroundStyle(.secondary) }
            if let pr = ws.preset, pr.systems.isEmpty, let url = URL(string: pr.source), !pr.source.isEmpty {
                Link("Vendor datasheet", destination: url).font(.caption)   // with gel systems it's in the note above
            }
        }
        .onAppear { sizesText = fmt(ws.ladderSizes) }
        .onChange(of: ws.ladderSizes) { _, v in sizesText = fmt(v) }
        .alert("Save ladder", isPresented: $saving) {
            TextField("Name", text: $saveName)
            Button("Save") { ws.saveCustomLadder(name: saveName) }
            Button("Cancel", role: .cancel) {}
        } message: { Text(fmt(ws.ladderSizes) + " " + unit) }

        PanelSection(title: "Placement") {
            HStack {
                Picker("Side", selection: Binding(get: { document.project.ladder?.side ?? .left },
                                                  set: { v in ws.edit("Ladder Side") { if $0.ladder == nil { $0.ladder = Ladder() }; $0.ladder!.side = v } })) {
                    Text("Left").tag(LadderSide.left)
                    Text("Right").tag(LadderSide.right)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                TextField("Unit", text: Binding(get: { document.project.ladder?.unit ?? ws.preset?.unit ?? "kDa" },
                                                set: { v in ws.edit("Ladder Unit") { if $0.ladder == nil { $0.ladder = Ladder() }; $0.ladder!.unit = v } }))
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 64)
            }
            HStack {
                Text("Text size").font(.callout).foregroundStyle(.secondary)
                Spacer()
                SizeStepper(value: .constant(document.project.style.size(for: TextKind.ladder))) { ws.setSize($0, for: .ladder) }
            }
            HStack {
                Text("\(unit) label").font(.callout).foregroundStyle(.secondary)
                Spacer()
                Button(ws.placingUnit ? "Click on the figure…" : "Place…") {
                    ws.placingUnit.toggle()
                    if ws.placingUnit, ws.tool.usesFullImage { ws.tool = .select }   // it's placed on the figure
                }
                .help("Then click on the figure at the height where the \(unit) label should sit")
                Button("Automatic") { ws.setUnitY(nil) }
                    .disabled(document.project.ladder?.unitY == nil)
                    .help("Back above the top of the gel")
            }
            .controlSize(.small)
            
        }

        PanelSection(title: "Ticks, top to bottom") {
            let bands = (p.ladder?.bands ?? []).sorted { p.stackKey($0.strip, $0.y) < p.stackKey($1.strip, $1.y) }   // top to bottom through the gels
            if ws.tool == .ladder {
                Label("Click each ladder band on the gel, top first", systemImage: "hand.point.up.left")
                    .font(.callout.weight(.medium)).foregroundStyle(Color.accentColor)
            } else {
                Button { ws.tool = .ladder } label: {
                    Label("Mark Ladder Bands", systemImage: "ruler").frame(maxWidth: .infinity)
                }
                .buttonStyle(PrimaryButtonStyle())
                .help("Switches to the ladder tool (K)")
            }
            if bands.isEmpty {
                Text("Each click suggests the next size in the list; press Return to accept or pick another. Skip bands that aren't ladder proteins, like the dye front.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if p.strips.isEmpty {
                ForEach(bands) { b in TickRow(ws: ws, band: b, sizes: ws.ladderSizes, unit: unit, hidden: !p.isInFigure(strip: b.strip, y: b.y)) }
            } else {
                // each gel's ticks under its name, top to bottom; y in that gel's own pixels
                ForEach(p.stackOrder, id: \.self) { k in
                    let part = bands.filter { $0.strip == k }
                    if !part.isEmpty {
                        Text(ws.gelName(k)).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        ForEach(part) { b in TickRow(ws: ws, band: b, sizes: ws.ladderSizes, unit: unit, hidden: !p.isInFigure(strip: b.strip, y: b.y)) }
                    }
                }
            }
            if !bands.isEmpty {
                HStack {
                    Button("Assign top-down") { ws.assignTopDown() }
                        .help("Give the ladder's sizes, in order, to the ticks that aren't skipped. A gel with its own ladder starts again from the top, and ticks hidden by a crop keep theirs. Marked as guesses until confirmed.")
                    Spacer()
                    Button("Confirm all") { ws.confirmTicks() }
                        .disabled(!bands.contains { $0.auto })
                }
                .controlSize(.small)
                if bands.contains(where: { $0.auto }) {
                    Label("Dashed sizes are guesses. Check each against your ladder, then confirm.", systemImage: "questionmark.circle")
                        .font(.caption).foregroundStyle(.yellow)
                }
                ForEach(tickCountNotes(p, bands), id: \.self) { note in
                    Text(note).font(.caption).foregroundStyle(.orange)
                }
                ForEach(p.ladderWarnings, id: \.self) { w in
                    Label(w, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange)
                }
            }
        }
    }
}

struct TickRow: View {
    let ws: Workspace
    let band: LadderBand
    let sizes: [Double]
    let unit: String
    /// Outside the rows its gel shows in the figure (a later crop): it keeps its size but isn't in the figure.
    var hidden = false

    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(ws.selection == .tick(band.id) ? Color.yellow : Color.yellow.opacity(0.45)).frame(width: 7, height: 7)
            Text("y \(Int(band.y))").font(.caption.monospacedDigit()).foregroundStyle(.secondary).frame(width: 44, alignment: .leading)
            if band.ignore {
                Text("skipped").font(.callout).foregroundStyle(.secondary).frame(width: 70, alignment: .leading)
            } else {
                TextField("size", text: Binding(
                    get: { band.size.map(FigureLayoutEngine.formatSize) ?? "" },
                    set: { v in ws.setTick(band.id, size: Double(v.replacingOccurrences(of: ",", with: "."))) }))
                    .textFieldStyle(.roundedBorder)
                    .font(.body.monospacedDigit())
                    .frame(width: 70)
                    .overlay(band.auto ? RoundedRectangle(cornerRadius: 5).strokeBorder(Color.yellow.opacity(0.8), style: StrokeStyle(lineWidth: 1, dash: [3, 2])) : nil)
                    .help(band.auto ? "Guessed from the ladder list. Type or pick the right size to confirm." : "")
            }
            if hidden {
                Image(systemName: "eye.slash").foregroundStyle(.secondary)
                    .help("Outside the crop, so it isn't in the figure and doesn't take a size from Assign top-down. It keeps its own size.")
            }
            Menu {
                ForEach(sizes, id: \.self) { s in
                    Button("\(FigureLayoutEngine.formatSize(s)) \(unit)") { ws.setTick(band.id, size: s, ignore: false) }
                }
                Divider()
                Button(band.ignore ? "Is a ladder band" : "Not a ladder band (skip)") { ws.setTick(band.id, size: nil, ignore: !band.ignore) }
                Button("Delete Tick", role: .destructive) { ws.deleteTick(band.id) }
            } label: { Image(systemName: "chevron.up.chevron.down") }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
        .onTapGesture { ws.selection = .tick(band.id) }
    }
}

struct NamesPanel: View {
    @Bindable var ws: Workspace
    @ObservedObject var document: GelDocument

    var body: some View {
        let list = document.project.annotations
        PanelSection(title: "Band names") {
            if ws.tool == .names {
                Label("Click a band next to the edge", systemImage: "hand.point.up.left")
                    .font(.callout.weight(.medium)).foregroundStyle(Color.accentColor)
            } else {
                Button { ws.tool = .names } label: {
                    Label("Name a Band", systemImage: "tag").frame(maxWidth: .infinity)
                }
                .buttonStyle(PrimaryButtonStyle())
                .help("Switches to the band-name tool (N)")
            }
            if list.isEmpty {
                Text("Click the band in the lane next to the edge, then type its name.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            ForEach(Array(list.enumerated()), id: \.element.id) { i, a in
                VStack(alignment: .leading, spacing: 6) {
                    if !document.project.strips.isEmpty {
                        Text(ws.gelName(a.strip)).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    }
                    HStack {
                        TextField("name", text: Binding(get: { a.text }, set: { v in ws.updateName(a.id) { $0.text = v } }))
                            .textFieldStyle(.roundedBorder)
                            .onSubmit { ws.rememberName(of: a.id) }
                        Button { ws.deleteName(a.id) } label: { Image(systemName: "xmark.circle.fill") }
                            .buttonStyle(.borderless).foregroundStyle(.secondary)
                    }
                    Picker("Marker", selection: Binding(get: { a.marker }, set: { v in ws.updateName(a.id) { $0.marker = v } })) {
                        Text("Arrow").tag(AnnotationMarker.arrow)
                        Text("Tick").tag(AnnotationMarker.tick)
                        Text("Bracket").tag(AnnotationMarker.bracket)
                        Text("Text").tag(AnnotationMarker.none)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .controlSize(.small)
                    HStack {
                        Picker("Side", selection: Binding(get: { a.side }, set: { v in ws.updateName(a.id) { $0.side = v } })) {
                            Text("Left").tag(LadderSide.left); Text("Right").tag(LadderSide.right)
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .controlSize(.small)
                        .fixedSize()
                        Spacer()
                        Toggle(isOn: Binding(get: { a.italic }, set: { v in ws.updateName(a.id) { $0.italic = v } })) {
                            Image(systemName: "italic")
                        }
                        .toggleStyle(.button)
                        .controlSize(.small)
                        .help("Italic (gene names)")
                    }
                    HStack {
                        Text("Size").font(.callout).foregroundStyle(.secondary)
                        Spacer()
                        SizeStepper(value: .constant(document.project.style.size(for: FigureRole.annotation(i)))) {
                            ws.setSize($0, forLabel: .annotation(i))
                        }
                    }
                }
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.ink.opacity(ws.selection == .name(a.id) ? 0.1 : 0.04)))
                .onTapGesture { ws.selection = .name(a.id) }
            }
        }
    }
}

struct FigurePanel: View {
    @Bindable var ws: Workspace
    @ObservedObject var document: GelDocument
    private static let keepsText = "The figure carries the original values, bit depth and color space, never resampled. Rotation and fill are off, crop only selects pixels, and brightness & contrast change the screen only."
    private static let adjustedText = "Rotation, fill, and brightness & contrast change the exported pixels, and exports record exactly what was done."
    private static let fonts = ["Arial", "Helvetica", "Helvetica Neue", "Avenir Next", "Myriad Pro", "Calibri", "Times New Roman"]
        .filter { NSFontManager.shared.availableFontFamilies.contains($0) }

    var body: some View {
        let p = document.project
        // with strips, the sections that act on one piece say which
        let piece = p.strips.isEmpty ? "" : " · " + ws.activeName
        let keeps = ws.activeStrict
        PanelSection(title: "Original image") {
            if p.strips.isEmpty {
                // one gel: the one switch
                Toggle(isOn: Binding(get: { ws.activeStrict }, set: { v in ws.setStrict(v) })) {
                    Label("Keep original pixels", systemImage: keeps ? "lock.fill" : "lock.open")
                }
                .help("A scan keeps its original values, bit depth and color space, or is adjusted.")
                Text(keeps ? Self.keepsText : Self.adjustedText).font(.caption).foregroundStyle(.secondary)
            } else {
                // several gels: every gel's own switch, in stack order, whichever one is chosen
                let problem = ws.strictProblemDetail
                Text("Keep original pixels").font(.callout.weight(.semibold))
                ForEach(Array(p.stackOrder.enumerated()), id: \.offset) { n, k in
                    let on = p.isStrict(gel: k), chosen = ws.activeStrip == k
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 6) {
                            HStack(spacing: 6) {
                                Image(systemName: on ? "lock.fill" : "lock.open").foregroundStyle(.secondary).frame(width: 16)
                                Text("Gel \(n + 1)").font(.callout.weight(.semibold))
                                if k == nil {
                                    Text("LANES").font(.system(size: 9, weight: .bold)).kerning(0.4)
                                        .padding(.horizontal, 5).padding(.vertical, 2)
                                        .background(Capsule().fill(Color.accentColor.opacity(0.28)))
                                        .help("Its lane dividers are the ones every gel uses")
                                }
                                Spacer(minLength: 4)
                            }
                            .contentShape(Rectangle())
                            .onTapGesture { ws.chooseGel(k) }   // a click on the name chooses the gel
                            Toggle("Keep original pixels, Gel \(n + 1)", isOn: Binding(get: { p.isStrict(gel: k) }, set: { ws.setStrict($0, gel: k) }))
                                .toggleStyle(.switch).labelsHidden().controlSize(.small)
                                .help("Keep original pixels for Gel \(n + 1). A gel scanned at a slightly different size needs it off to be stretched into line.")
                        }
                        // what concerns this gel, under its row: what the switch means for the chosen gel, that a gel that keeps its
                        // pixels is lined up by whole pixels, and why the gels that keep theirs can't be exported untouched
                        if chosen { Text(on ? Self.keepsText : Self.adjustedText).font(.caption).foregroundStyle(.secondary) }
                        if on, k != nil {
                            Text("Lined up by whole pixels, never stretched. Turn it off to stretch this gel into line.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        if let problem, problem.gel == k {
                            Text("Can't export untouched: \(problem.text). Turn off Keep original pixels for a gel to export.")
                                .font(.caption).foregroundStyle(.orange)
                        }
                    }
                    .padding(.horizontal, 8).padding(.vertical, 5)
                    .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(chosen ? Color.accentColor.opacity(0.18) : Color.ink.opacity(0.05)))
                }
                Text("Each gel has its own setting. The gels that keep their pixels must be stored the same way (bit depth, color).")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }

        GelsPanel(ws: ws, document: document)

        PanelSection(title: "Brightness & Contrast" + piece) {
            BrightnessContrastPanel(ws: ws, document: document)
        }
        .id(BrightnessContrastPanel.anchor)

        PanelSection(title: "Rotate" + piece) {
            let angle = ws.activeRotation
            HStack {
                Button { ws.tool = .straighten } label: { Label("Straighten…", systemImage: "level") }
                    .help("Drag along a band row or a lane edge; the image turns to level it (R)")
                Spacer()
                Button("Reset") { ws.setRotation(0) }.disabled(angle == 0 || keeps)
            }
            .controlSize(.small)
            HStack(spacing: 6) {
                Text("Angle").frame(width: 64, alignment: .leading)
                // positive turns counter-clockwise, so the counter-clockwise icon adds
                Button { ws.setRotation(angle + 0.1) } label: { Image(systemName: "rotate.left") }.buttonStyle(.borderless)
                    .help("Turn 0.1° counter-clockwise")
                AngleField(value: angle) { ws.setRotation($0) }
                    .frame(width: 60)
                Text("°").foregroundStyle(.secondary)
                Button { ws.setRotation(angle - 0.1) } label: { Image(systemName: "rotate.right") }.buttonStyle(.borderless)
                    .help("Turn 0.1° clockwise")
            }
            .disabled(keeps)
            Slider(value: Binding(get: { ws.activeRotation }, set: { ws.setRotation(($0 * 10).rounded() / 10) }), in: -10...10)
                .disabled(keeps)
            if keeps {
                Text("Off while this gel keeps its original pixels, because rotating resamples it. Straighten asks before turning that off.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            HStack(spacing: 6) {
                Text("Turn").frame(width: 64, alignment: .leading)
                Button { ws.turnActive(by: 3) } label: { Image(systemName: "rotate.left.fill") }.buttonStyle(.borderless)
                    .help("A quarter turn counter-clockwise. Lossless; this gel's crop, ticks and names start over")
                Button("180°") { ws.turnActive(by: 2) }.controlSize(.small)
                    .help("Half a turn, for a scan made upside down. Lossless; ticks and names turn with it")
                Button { ws.turnActive(by: 1) } label: { Image(systemName: "rotate.right.fill") }.buttonStyle(.borderless)
                    .help("A quarter turn clockwise. Lossless; this gel's crop, ticks and names start over")
            }
        }

        PanelSection(title: "Fill") {
            Picker("Fill", selection: Binding(get: { document.project.fillMode }, set: { ws.setFill($0) })) {
                Text("Match gel").tag(FillMode.background)
                Text("White").tag(FillMode.white)
                Text("Custom").tag(FillMode.custom)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            HStack(spacing: 8) {
                let v = p.fillMode == .custom ? p.fillValue : p.fillMode == .white ? 1 : Double(ws.measuredBackground ?? 255) / 255
                RoundedRectangle(cornerRadius: 4).fill(Color(white: v)).frame(width: 22, height: 16)
                    .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Color.ink.opacity(0.25)))
                if p.fillMode == .custom {
                    Slider(value: Binding(get: { document.project.fillValue * 255 }, set: { ws.setFill(.custom, value: ($0 / 255 * 1000).rounded() / 1000) }), in: 0...255)
                    Text("\(Int((p.fillValue * 255).rounded()))").font(.caption.monospacedDigit()).frame(width: 30)
                } else {
                    Text(p.fillMode == .white ? "Pure white (255)" : "Measured gel background (\(ws.measuredBackground ?? 0) of 255)")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                }
            }
            Toggle("Also paint the old gray wedges", isOn: Binding(get: { document.project.fillPadding }, set: { v in ws.edit("Wedge Fill") { $0.fillPadding = v } }))
                .help("Flat wedges left by an earlier rotation in the source file")
            Text("Paints the corners a rotation uncovers. Detection always ignores them.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .disabled(ws.pixelsKept == .all)

        Toggle("Bands are dark on light", isOn: Binding(get: { ws.activeDisplay.bandsDark }, set: { v in
            if let k = ws.activeStrip { ws.edit("Band Polarity") { $0.strips[k - 1].display.bandsDark = v } }
            else { ws.edit("Band Polarity") { $0.display.bandsDark = v } }
        }))
            .help("Used for snapping and lining gels up only")

        PanelSection(title: "Crop" + piece) {
            if ws.activeStrip != nil, ws.activeStripRect == nil {
                Text(ws.activeProblem ?? "This gel isn't in the figure.").font(.caption).foregroundStyle(.orange)
            } else if ws.activeStrip != nil, let r = ws.activeStripRect {
                HStack {
                    Button("Edit Crop") { ws.tool = .crop }
                    Button("Reset") { ws.resetCrop() }
                }
                .controlSize(.small)
                let own = p.strips[ws.activeStrip! - 1].left != nil || p.strips[ws.activeStrip! - 1].right != nil
                Text("Columns \(Int(r.x0))–\(Int(r.x1))\(own ? "" : ", following \(ws.gelName(nil))'s crop"), rows \(Int(r.y0))–\(Int(r.y1)) of \(ws.activeSize.width) × \(ws.activeSize.height) px. Return keeps the crop, Esc puts it back.")
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            } else {
                HStack {
                    Button("Edit Crop") { ws.tool = .crop }
                    Button("Fit to Lanes") {
                        ws.edit("Crop to Lanes") { $0.crop = GelOps.suggestCrop($0, imageWidth: ws.imageWidth, imageHeight: ws.imageHeight)
                            $0.syncLaneCenters(imageWidth: ws.imageWidth, imageHeight: ws.imageHeight) }
                    }
                    Button("Reset") { ws.resetCrop() }
                }
                .controlSize(.small)
                let c = ws.crop
                Text("\(Int(c.width)) × \(Int(c.height)) px from (\(Int(c.x0)), \(Int(c.y0)))").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
        }

        PanelSection(title: "Font") {
            Picker("Font", selection: Binding(get: { document.project.style.font }, set: { v in ws.edit("Font") { $0.style.font = v } })) {
                ForEach(Self.fonts.contains(p.style.font) ? Self.fonts : Self.fonts + [p.style.font], id: \.self) { Text($0).tag($0) }
            }
            .labelsHidden()
            Text("Sizes are on the Aa tab and the text-size button in the tool palette.")
                .font(.caption).foregroundStyle(.secondary)
        }

        PanelSection(title: "Layout") {
            LabeledSlider(title: "Gel width", value: binding(\.style.gelWidthIn, "Gel Width"), range: 1...8, step: 0.1, format: "%.1f in")
            LabeledSlider(title: "Lines", value: binding(\.style.lineWidthPt, "Line Width"), range: 0.25...2, step: 0.05, format: "%.2f pt")
            LabeledSlider(title: "Ticks", value: binding(\.style.tickLenPt, "Tick Length"), range: 1...8, step: 0.5, format: "%.1f pt")
            Toggle("Border around the gel", isOn: Binding(get: { document.project.style.border }, set: { v in ws.edit("Border") { $0.style.border = v } }))
        }
    }

    private func binding(_ kp: WritableKeyPath<GelProject, Double>, _ name: String) -> Binding<Double> {
        Binding(get: { document.project[keyPath: kp] }, set: { v in ws.edit(name) { $0[keyPath: kp] = v } })
    }
}

/// The gels in the figure, top to bottom: which one the Figure tab acts on, adding, ordering and removing gels, and
/// lining each one's lanes up under the lanes of the gel that has them.
struct GelsPanel: View {
    @Bindable var ws: Workspace
    @ObservedObject var document: GelDocument

    var body: some View {
        let p = document.project
        PanelSection(title: "Gels") {
            if p.strips.isEmpty {
                HStack {
                    Text(p.image).font(.callout).lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Button("Add Gel…") { ws.chooseGelImages() }.controlSize(.small)
                        .help("Another gel, or the other pieces of a cut membrane, to stack under this one")
                }
                Text("More gels go under this one, each with a line above it, and share its lanes and labels.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                let order = p.stackOrder
                VStack(spacing: 3) {
                    ForEach(Array(order.enumerated()), id: \.offset) { n, k in
                        let image = k.map { p.strips[$0 - 1].image } ?? p.image
                        GelRow(ws: ws, place: n, strip: k, image: image, chosen: ws.activeStrip == k,
                               problem: k == nil ? ws.mainProblem : ws.stripProblems[image])
                    }
                }
                let place = p.position(of: ws.activeStrip), last = order.count - 1
                HStack {
                    Button("Add Gel…") { ws.chooseGelImages() }
                        .help("More gels, or the other pieces of a cut membrane, at the bottom of the stack")
                    Spacer()
                    Button { ws.moveGel(from: place, to: place - 1) } label: { Image(systemName: "arrow.up") }
                        .disabled(place == 0)
                        .help("Move \(ws.activeName) up")
                    Button { ws.moveGel(from: place, to: place + 1) } label: { Image(systemName: "arrow.down") }
                        .disabled(place == last)
                        .help("Move \(ws.activeName) down")
                    if ws.activeStrip != nil {
                        Button("Remove", role: .destructive) { ws.removeActiveGel() }
                            .help("Take \(ws.activeName) out of the figure, with its ticks and names")
                    }
                }
                .controlSize(.small)
                Toggle("Own ladder", isOn: Binding(get: { p.hasOwnLadder(ws.activeStrip) }, set: { ws.setOwnLadder($0) }))
                    .toggleStyle(.checkbox)
                    .controlSize(.small)
                    .disabled(place == 0)   // the top gel starts the ladder
                    .help("Its ladder sizes start again from the top instead of carrying on from the gel above.")
                VStack(alignment: .leading, spacing: 6) {
                    Text("Line between gels:").font(.callout)
                    HStack(spacing: 8) {
                        // black or white by a click, or any color by its hex (neither segment is chosen for another color)
                        Picker("Line between gels", selection: Binding<SeparatorColor?>(
                            get: { p.separatorColor == .black || p.separatorColor == .white ? p.separatorColor : nil },
                            set: { if let c = $0 { ws.setSeparatorColor(c) } })) {
                            Text("Black").tag(Optional(SeparatorColor.black))
                            Text("White").tag(Optional(SeparatorColor.white))
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .fixedSize()
                        SeparatorHexField(color: p.separatorColor) { ws.setSeparatorColor($0) }
                        Spacer(minLength: 0)
                    }
                    .controlSize(.small)
                    Text("Gray figures use the color's brightness.").font(.caption).foregroundStyle(.secondary)
                    // how thick: its own, or (not set) the Lines width under Layout, which it then shows
                    HStack(spacing: 6) {
                        let thickness = Binding(get: { p.effectiveSeparatorWidth }, set: { ws.setSeparatorWidth($0) })
                        Text("Thickness").font(.callout)
                        TextField("", value: thickness, format: .number.precision(.fractionLength(0...2)))
                            .frame(width: 50).multilineTextAlignment(.trailing)
                        Text("pt").foregroundStyle(.secondary)
                        Stepper("Thickness", value: thickness, in: GelProject.separatorWidths, step: 0.25).labelsHidden()
                        Spacer(minLength: 4)
                        Button("Match lines") { ws.setSeparatorWidth(nil) }
                            .disabled(p.separatorWidth == nil)
                            .help("Make the line as thick as the figure's other lines again (Lines, under Layout), and follow them")
                    }
                    .controlSize(.small)
                    .help("How thick the line between gels is, 0.25 to 10 points. Until you set it, it is as thick as the Lines width.")
                }
                .help("The line between stacked gels, in the figure and in every export")
                Text("Click a gel to work on it, here or in the figure (Select tool). Double-click one to see it on its own. Drag one up or down to change the order.")
                    .font(.caption).foregroundStyle(.secondary)
                if let k = ws.activeStrip, k <= p.strips.count {
                    alignment(p, k)
                } else {
                    HStack {
                        Button("Auto-align All") { ws.autoAlignAll() }
                            .help("Lines every other gel up under this gel's lane dividers, wherever this gel sits")
                        Spacer()
                        Button { ws.nudgeActiveStrip(by: -1) } label: { Image(systemName: "arrow.left") }
                            .help("Move the gel 1 px left, with its lane dividers, labels, ticks and names (← with nothing selected; ⇧ for 10 px)")
                        Button { ws.nudgeActiveStrip(by: 1) } label: { Image(systemName: "arrow.right") }
                            .help("Move the gel 1 px right (→ with nothing selected; ⇧ for 10 px)")
                    }
                    .controlSize(.small)
                    HStack(spacing: 6) {
                        Text("Shift")
                        TextField("", value: Binding(get: { ws.activeShift }, set: { ws.setShift($0) }), format: .number.precision(.fractionLength(0)))
                            .frame(width: 64).multilineTextAlignment(.trailing)
                            .help("x in this gel = x in the figure + shift. Moves this gel with its lane dividers, labels, ticks and names; no other gel moves.")
                        Text("px").foregroundStyle(.secondary)
                        Spacer()
                    }
                    Text(ws.alignNote ?? "This gel's lane dividers are the ones every gel uses. Drag any gel sideways in the figure (Select tool) to line the edges up, or choose another gel to line it up on its own.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    /// Lining gel `k` up: Auto-align, nudging, and the shift and stretch as numbers.
    @ViewBuilder private func alignment(_ p: GelProject, _ k: Int) -> some View {
        let size = ws.activeSize
        if let why = ws.activeProblem {
            Text(why).font(.caption).foregroundStyle(.orange)
        } else {
            Text("\(p.strips[k - 1].image) · \(size.width) × \(size.height) px")
                .font(.caption.monospacedDigit()).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
        }
        HStack {
            Button("Auto-align") { ws.autoAlign() }
                .help("Finds this gel's lanes and lines them up under the lane dividers")
            Spacer()
            Button { ws.nudgeActiveStrip(by: -1) } label: { Image(systemName: "arrow.left") }
                .help("Move the gel 1 px left (← with nothing selected; ⇧ for 10 px)")
            Button { ws.nudgeActiveStrip(by: 1) } label: { Image(systemName: "arrow.right") }
                .help("Move the gel 1 px right (→ with nothing selected; ⇧ for 10 px)")
        }
        .controlSize(.small)
        HStack(spacing: 6) {
            let a = p.effectiveAlignment(k)
            Text("Shift")
            TextField("", value: Binding(get: { a.shift }, set: { ws.setShift($0) }),
                      format: .number.precision(.fractionLength(0...2)))
                .frame(width: 64).multilineTextAlignment(.trailing)
                .help("x in this gel = stretch × x in the figure + shift. No other gel moves.")
            Text("px").foregroundStyle(.secondary)
            Spacer()
            Text("Stretch")
            TextField("", value: Binding(get: { ((a.scale - 1) * 10000).rounded() / 100 }, set: { ws.setScale(1 + $0 / 100) }),
                      format: .number.precision(.fractionLength(0...2)))
                .frame(width: 52).multilineTextAlignment(.trailing)
                .disabled(ws.activeStrict)
                .help("How much wider this gel's lanes are than \(ws.gelName(nil))'s, in percent")
            Text("%").foregroundStyle(.secondary)
        }
        Text(ws.alignNote ?? "Drag the gel sideways in the figure (Select tool), or Auto-align, until its lanes sit between the dividers.")
            .font(.caption).foregroundStyle(.secondary)
        if ws.activeStrict {
            Text("Stretch needs Keep original pixels off for this gel: stretching resamples it.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

/// The line between gels as #RRGGBB, to type: RRGGBB and #RGB are fine too. It shows the color as it was normalized, and goes back to
/// what it was when what's typed isn't a color.
struct SeparatorHexField: View {
    let color: SeparatorColor
    let commit: (SeparatorColor) -> Void
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        TextField("#000000", text: $text)
            .textFieldStyle(.roundedBorder)
            .font(.system(.callout, design: .monospaced))
            .frame(width: 80)
            .focused($focused)
            .onSubmit(apply)
            .onChange(of: focused) { _, now in if !now { apply() } }
            .onChange(of: color, initial: true) { _, c in if !focused { text = c.hex } }
            .help("The color of the line as #RRGGBB (RRGGBB and #RGB work too). Gray figures use its brightness.")
    }

    private func apply() {
        if let c = SeparatorColor(parsing: text) { commit(c); text = c.hex } else { text = color.hex }
    }
}

/// One gel in the Gels list: a click chooses it, a drag onto another row moves it to that place.
struct GelRow: View {
    let ws: Workspace
    let place: Int
    let strip: Int?
    let image: String
    let chosen: Bool
    /// Why this gel's image can't be used, if it can't.
    var problem: String?
    @State private var target = false

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "line.3.horizontal").foregroundStyle(.tertiary)
            Text("Gel \(place + 1)").font(.callout.weight(.semibold))
            Text(image).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 4)
            if let problem {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange).help(problem)
            }
            if strip == nil {
                Text("LANES").font(.system(size: 9, weight: .bold)).kerning(0.4)
                    .padding(.horizontal, 5).padding(.vertical, 2)
                    .background(Capsule().fill(Color.accentColor.opacity(0.28)))
                    .help("Its lane dividers are the ones every gel uses")
            }
        }
        .padding(.horizontal, 8).padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 7, style: .continuous)
            .fill(chosen ? Color.accentColor.opacity(0.24) : Color.ink.opacity(target ? 0.14 : 0.05)))
        .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous)
            .strokeBorder(Color.accentColor.opacity(target ? 0.9 : 0), lineWidth: 1.5))
        .contentShape(Rectangle())
        .onTapGesture { ws.chooseGel(strip) }
        .simultaneousGesture(TapGesture(count: 2).onEnded { ws.showGel(strip) })   // a double-click: that gel on its own
        .draggable(GelPlace(place: place, window: ws.id)) {
            Text("Gel \(place + 1)").font(.callout.weight(.semibold)).padding(6)
        }
        .dropDestination(for: GelPlace.self) { items, _ in
            // only a row of this window's own list moves a gel here
            guard let item = items.first, item.window == ws.id, item.place != place else { return false }
            ws.moveGel(from: item.place, to: place)
            return true
        } isTargeted: { target = $0 }
    }
}

/// A gel's place in the stack, dragged within the Gels list.
nonisolated struct GelPlace: Codable, Transferable {
    var place: Int
    /// The window whose list it came from.
    var window: UUID
    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .gelPlace)
    }
}

extension UTType {
    /// Only ever dragged inside the app, so nothing else takes the drop.
    nonisolated static let gelPlace = UTType(exportedAs: "local.gelscribe.gel-place")
}

/// Brightness & contrast as in ImageJ: the display range in the file's own values over a histogram of the gel, with
/// Auto, Reset and the range ImageJ saved. While Strict is on it changes the screen only.
struct BrightnessContrastPanel: View {
    static let anchor = "brightness-contrast"
    @Bindable var ws: Workspace
    @ObservedObject var document: GelDocument

    var body: some View {
        if let stats = ws.gelStats {
            let d = ws.activeDisplay, s = ws.valueScale
            let data = stats.range                       // gray, dark to bright
            // the file's own values, low to high (reversed from gray in a white-is-zero file)
            let a = s.value(data.lowerBound), z = s.value(data.upperBound)
            let lo = min(a, z), hi = max(a, z)
            let r = d.range(in: s)
            let axis = min(lo, r.min)...max(hi, r.max, min(lo, r.min) + 1 / s.maxValue)
            VStack(alignment: .leading, spacing: 8) {
                Histogram(counts: s.inverted ? stats.counts.reversed() : stats.counts, values: lo...hi, axis: axis,
                          display: d, scale: s)
                    .frame(height: 70)
                HStack {
                    Text(s.format(axis.lowerBound))
                    Spacer()
                    Text(s.format(axis.upperBound))
                }
                .font(.caption2.monospacedDigit()).foregroundStyle(.secondary)

                RangeRow(title: "Minimum", value: r.min, range: axis, scale: s) { v, live in
                    ws.changeContrast(live: live) { $0.setRange(min: v, max: max(r.max, v + 1 / s.maxValue), in: s) }
                } end: { ws.endContrastChange() }
                RangeRow(title: "Maximum", value: r.max, range: axis, scale: s) { v, live in
                    ws.changeContrast(live: live) { $0.setRange(min: min(r.min, v - 1 / s.maxValue), max: v, in: s) }
                } end: { ws.endContrastChange() }
                DragSlider(title: "Brightness", value: d.brightness(data: data), range: -1...1) { v, live in
                    ws.changeContrast(live: live) { $0.setBrightness(v, data: data) }
                } end: { ws.endContrastChange() }
                DragSlider(title: "Contrast", value: d.contrast(data: data), range: -1...1) { v, live in
                    ws.changeContrast(live: live) { $0.setContrast(v, data: data) }
                } end: { ws.endContrastChange() }

                HStack(spacing: 6) {
                    Button("Auto") { ws.autoContrast() }
                        .help("The darkest 0.1% of the gel to black, the brightest 0.1% to white")
                    Button("Reset") { ws.resetContrast() }
                        .help(s.maxValue > 255 ? "The gel's darkest to brightest value, as ImageJ resets 16-bit images" : "The full 0–255 scale")
                    if let ij = ws.imageJRange {
                        Button("ImageJ \(s.format(ij.lowerBound))–\(s.format(ij.upperBound))") { ws.useImageJRange() }
                            .help("The display range ImageJ saved in this file")
                    }
                }
                .controlSize(.small)

                DragSlider(title: "Gamma", value: d.gamma, range: 0.3...3, format: "%.2f") { v, live in
                    ws.changeContrast(live: live) { $0.gamma = v }
                } end: { ws.endContrastChange() }
                Toggle("Invert", isOn: Binding(get: { ws.activeDisplay.invert },
                                               set: { v in ws.changeContrast { $0.invert = v } }))

                if ws.enhanceView, ws.activeStrip == nil {
                    HStack {
                        Text("Auto contrast from an earlier version is on.").font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button("Turn Off") { ws.enhanceView = false }.controlSize(.small)
                    }
                }
                if ws.activeStrict {
                    Text("On screen only, like ImageJ before Apply: exports keep the original values.")
                        .font(.caption).foregroundStyle(.secondary)
                    Button("Use in Exports…") { ws.requestContrastForExport() }
                        .controlSize(.small)
                        .disabled(d.isIdentity)
                        .help("Turns off Keep original pixels for this gel so exports show this range; each file records it")
                } else {
                    Text("Exports use this range (display range \(ws.displayRangeText)), and each file records it.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }
}

/// The gel's histogram on the file's value axis, with the current mapping drawn over it like ImageJ's.
struct Histogram: View {
    let counts: [Int]
    /// The values the counts span (the gel's lowest to highest) and the axis drawn.
    let values: ClosedRange<Double>
    let axis: ClosedRange<Double>
    let display: DisplaySettings
    let scale: ValueScale

    var body: some View {
        Canvas { ctx, size in
            let span = max(axis.upperBound - axis.lowerBound, 1e-9)
            func x(_ v: Double) -> CGFloat { CGFloat((v - axis.lowerBound) / span) * size.width }
            let top = log1p(Double(counts.max() ?? 1))
            let step = (values.upperBound - values.lowerBound) / Double(max(counts.count, 1))
            var bars = Path()
            for (i, c) in counts.enumerated() where c > 0 {
                let x0 = x(values.lowerBound + Double(i) * step), x1 = x(values.lowerBound + Double(i + 1) * step)
                let h = CGFloat(log1p(Double(c)) / top) * size.height
                bars.addRect(CGRect(x: x0, y: size.height - h, width: max(1, x1 - x0), height: h))
            }
            ctx.fill(bars, with: .color(Color.ink.opacity(0.45)))
            // brightness on screen across the axis: the display mapping, gamma and invert included
            var line = Path()
            for k in 0...96 {
                let v = axis.lowerBound + span * Double(k) / 96
                var g = (scale.gray(v) - display.black) / max(display.white - display.black, 1e-9)
                g = min(1, max(0, g))
                if display.gamma != 1 { g = pow(g, 1 / display.gamma) }
                if display.invert { g = 1 - g }
                let p = CGPoint(x: x(v), y: (1 - CGFloat(g)) * size.height)
                if k == 0 { line.move(to: p) } else { line.addLine(to: p) }
            }
            ctx.stroke(line, with: .color(.accentColor), lineWidth: 1.5)
        }
        .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color.inset))
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
    }
}

/// A slider plus a typed value in the file's own numbers. `change(value, live)`: live while dragging, then `end`.
struct RangeRow: View {
    let title: String
    let value: Double
    let range: ClosedRange<Double>
    let scale: ValueScale
    let change: (Double, Bool) -> Void
    let end: () -> Void
    @State private var dragging = false

    var body: some View {
        HStack(spacing: 8) {
            Text(title).lineLimit(1).frame(width: 74, alignment: .leading)
            Slider(value: Binding(get: { min(max(value, range.lowerBound), range.upperBound) },
                                  set: { change($0.rounded(scale.maxValue > 1 ? .toNearestOrEven : .towardZero), dragging) }),
                   in: range) { editing in
                dragging = editing
                if !editing { end() }
            }
            TextField("", value: Binding(get: { value.rounded() == value || scale.maxValue <= 1 ? value : value.rounded() },
                                         set: { change($0, false) }),
                      format: .number.grouping(.never).precision(.fractionLength(0...(scale.maxValue > 1 ? 0 : 3))))
                .multilineTextAlignment(.trailing)
                .font(.caption.monospacedDigit())
                .frame(width: 58)
        }
    }
}

/// A slider whose drag is one undo step: `change(value, live)` while dragging, then `end`.
struct DragSlider: View {
    let title: String
    let value: Double
    let range: ClosedRange<Double>
    var format = "%+.2f"
    let change: (Double, Bool) -> Void
    let end: () -> Void
    @State private var dragging = false

    var body: some View {
        HStack(spacing: 8) {
            Text(title).lineLimit(1).frame(width: 74, alignment: .leading)
            Slider(value: Binding(get: { min(max(value, range.lowerBound), range.upperBound) }, set: { change($0, dragging) }),
                   in: range) { editing in
                dragging = editing
                if !editing { end() }
            }
            Text(String(format: format, value)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                .frame(width: 58, alignment: .trailing)
        }
    }
}

struct LabeledSlider: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    let format: String
    var body: some View {
        HStack(spacing: 8) {
            Text(title).frame(width: 64, alignment: .leading)
            Slider(value: $value, in: range, step: step)
            Text(String(format: format, value)).font(.caption.monospacedDigit()).foregroundStyle(.secondary).frame(width: 52, alignment: .trailing)
        }
    }
}

struct ExportPanel: View {
    @Bindable var ws: Workspace
    @ObservedObject var document: GelDocument

    var body: some View {
        let base = ((document.project.title?.isEmpty == false ? document.project.title! : document.project.image) as NSString).deletingPathExtension
        PanelSection(title: "Export") {
            if let why = ws.unreadableGel {
                Label { Text(verbatim: why) } icon: { Image(systemName: "exclamationmark.triangle.fill") }
                    .font(.caption).foregroundStyle(.orange)
            }
            ExportRow(title: "PDF", detail: "Vector text, gel embedded losslessly") { ws.export(.pdf, suggestedName: base + ".pdf") }
            let resampled = ws.resampledExportDPI
            ExportRow(title: "TIFF", detail: resampled.map { "\(Int($0)) dpi, LZW, gel resampled" } ?? "Native \(ws.nativeDPI) dpi, LZW, gel pixels 1:1") {
                ws.export(.tiff, suggestedName: base + ".tiff")
            }
            ExportRow(title: "PNG", detail: resampled.map { "\(Int($0)) dpi, gel resampled" } ?? "Native \(ws.nativeDPI) dpi, gel pixels 1:1") {
                ws.export(.png, suggestedName: base + ".png")
            }
            ExportRow(title: "SVG", detail: "Editable text, gel as lossless PNG") { ws.export(.svg, suggestedName: base + ".svg") }
            Button { ws.copyFigure() } label: { Label("Copy Figure", systemImage: "doc.on.doc").frame(maxWidth: .infinity) }
                .buttonStyle(.glass)
                .keyboardShortcut("c", modifiers: [.command, .shift])
        }
        PanelSection(title: "Provenance") {
            Text(ws.exportInfo.description)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
            Toggle("Include file names in exported files", isOn: Binding(get: { document.project.exportFileNames },
                                                                         set: { ws.setExportFileNames($0) }))
                .help("File names can identify samples or people. The SHA-256 fingerprints stay either way.")
            // every piece against the fingerprint taken when it was imported
            let p = document.project
            let checks = [(ws.gelName(nil), ws.source?.sha256, p.imageSHA256)]
                + p.strips.indices.map { (ws.gelName($0 + 1), ws.stripWorking($0 + 1)?.source.sha256, p.strips[$0].imageSHA256) }
            let known = checks.filter { $0.2 != nil }   // a gel that can't be read has no fingerprint now: it doesn't match
            if !known.isEmpty {
                let bad = known.filter { $0.1 != $0.2 }.map(\.0)
                let text = checks.count == 1
                    ? (bad.isEmpty ? "Image matches its import fingerprint" : "Image differs from its import fingerprint")
                    : (bad.isEmpty ? "Every image matches its import fingerprint"
                                   : bad.joined(separator: ", ") + (bad.count == 1 ? " differs" : " differ") + " from the import fingerprint")
                Label(text, systemImage: bad.isEmpty ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(bad.isEmpty ? .green : .orange)
            }
        }
    }
}

struct ExportRow: View {
    let title: String
    let detail: String
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack {
                Text(title).font(.system(size: 13, weight: .semibold)).frame(width: 44, alignment: .leading)
                Text(detail).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Image(systemName: "square.and.arrow.up").foregroundStyle(.secondary)
            }
            .padding(.vertical, 8).padding(.horizontal, 10)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.ink.opacity(0.06)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

import GelKit
import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @ObservedObject var document: GelDocument
    let fileURL: URL?
    @State private var ws: Workspace
    @Environment(\.undoManager) private var undoManager
    @Environment(\.openSettings) private var openSettings
    @AppStorage(AppAppearance.key) private var appearance: AppAppearance = .dark

    init(document: GelDocument, fileURL: URL?) {
        self.document = document
        self.fileURL = fileURL
        _ws = State(initialValue: Workspace(document: document))
    }

    var body: some View {
        ZStack {
            Color(nsColor: Chrome.backdrop).ignoresSafeArea()
            if document.hasImage {
                CanvasView(workspace: ws, project: document.project, tool: ws.tool, selection: ws.selection,
                           showGuides: ws.showGuides, enhanceView: ws.enhanceView, inspectorVisible: ws.inspectorVisible,
                           zoomRequest: ws.zoomRequest, activeStrip: ws.activeStrip, stripSizes: ws.stripSizes, showsGel: ws.showsGel)
                    .ignoresSafeArea()
                HStack(alignment: .top) {
                    ToolPalette(ws: ws).padding(.leading, 14).padding(.top, 14)
                    Spacer()
                    if ws.inspectorVisible {
                        Inspector(ws: ws, document: document)
                            .padding(.trailing, 14).padding(.vertical, 14)
                            .transition(.move(edge: .trailing).combined(with: .opacity))
                    }
                }
                // with two gels or more: the figure or one gel on its own, centered above the canvas area
                if !document.project.strips.isEmpty {
                    VStack {
                        HStack {
                            Spacer(minLength: 0)
                            GelSwitcher(ws: ws)
                            Spacer(minLength: 0)
                        }
                        .padding(.leading, 76)
                        .padding(.trailing, ws.inspectorVisible ? 340 : 14)
                        .padding(.top, 14)
                        Spacer()
                    }
                }
                // centered under the canvas area, never under the inspector
                VStack {
                    Spacer()
                    HStack {
                        Spacer(minLength: 0)
                        StatusPill(ws: ws, lanes: document.project.laneCount)
                        Spacer(minLength: 0)
                    }
                    .padding(.leading, 76)
                    .padding(.trailing, ws.inspectorVisible ? 340 : 14)
                    .padding(.bottom, 16)
                }
            } else {
                DropZone { urls in adopt(urls) }
            }
        }
        .preferredColorScheme(appearance.colorScheme)
        .toolbar {
            if document.hasImage {
                ToolbarItem(placement: .primaryAction) {
                    StrictBadge(kept: ws.pixelsKept) { ws.inspectorTab = .figure; ws.inspectorVisible = true; ws.revealStrict += 1 }
                }
                ToolbarSpacer(.fixed, placement: .primaryAction)
            }
            ToolbarItemGroup(placement: .primaryAction) {
                Button { ws.copyFigure() } label: { Label("Copy Figure", systemImage: "doc.on.doc") }
                    .help("Copy the figure as PDF + PNG (⇧⌘C)")
                    .disabled(!document.hasImage)
                Menu {
                    Button("PDF…") { ws.export(.pdf, suggestedName: exportName + ".pdf") }
                    Button("TIFF…") { ws.export(.tiff, suggestedName: exportName + ".tiff") }
                    Button("PNG…") { ws.export(.png, suggestedName: exportName + ".png") }
                    Button("SVG…") { ws.export(.svg, suggestedName: exportName + ".svg") }
                } label: { Label("Export", systemImage: "square.and.arrow.up") }
                    .disabled(!document.hasImage)
            }
            ToolbarSpacer(.fixed, placement: .primaryAction)
            ToolbarItem(placement: .primaryAction) {
                Button { withAnimation(.snappy) { ws.inspectorVisible.toggle() } } label: { Label("Inspector", systemImage: "sidebar.right") }
                    .help("Show or hide the inspector (⌥⌘I)")
            }
        }
        .alert("Use brightness & contrast in exports?", isPresented: $ws.pendingContrastExport) {
            Button("Turn Off Keep Original Pixels") { ws.applyContrastForExport() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(verbatim: "Exports will show \(ws.project.strips.isEmpty ? "the gel" : ws.activeName) at display range \(ws.displayRangeText) instead of its original values, like ImageJ's Apply. Each file records the range, and your original file stays untouched. With Keep original pixels off you can also rotate and fill.")
        }
        .alert("Turn off Keep original pixels to straighten?", isPresented: Binding(get: { ws.pendingStraighten != nil },
                                                                                   set: { if !$0 { ws.pendingStraighten = nil } })) {
            Button("Turn Off and Rotate \(String(format: "%+.2f°", ws.pendingStraighten ?? 0))") { ws.confirmStraighten() }
            Button("Cancel", role: .cancel) { ws.pendingStraighten = nil }
        } message: {
            Text("Rotating resamples the gel, so the exported pixels will no longer be the originals. The exports record the rotation, and your original file stays untouched." + (ws.activeDisplay.isIdentity ? "" : " Brightness & contrast will reach exports too."))
        }
        .alert(ws.problem?.title ?? "", isPresented: Binding(get: { ws.problem != nil }, set: { if !$0 { ws.problem = nil } })) {
            Button("OK", role: .cancel) { ws.problem = nil }
        } message: {
            Text(verbatim: ws.problem?.message ?? "")
        }
        .alert("A gel's image has changed", isPresented: Binding(get: { ws.pendingChangedExport != nil },
                                                                 set: { if !$0 { ws.pendingChangedExport = nil } })) {
            Button("Export Anyway") { ws.confirmChangedExport() }
            Button("Cancel", role: .cancel) { ws.pendingChangedExport = nil }
        } message: {
            Text(verbatim: ws.pendingChangedExport?.message ?? "")
        }
        .alert("Resample the gel for PNG and TIFF?", isPresented: Binding(get: { ws.pendingExportDPI != nil },
                                                                         set: { if !$0 { ws.pendingExportDPI = nil } })) {
            Button(String("Use \(Int(ws.pendingExportDPI ?? 0)) dpi")) { if let d = ws.pendingExportDPI { ws.setExportDPI(d) } }
            Button("Keep Native", role: .cancel) { ws.pendingExportDPI = nil }
        } message: {
            Text(verbatim: "At \(Int(ws.pendingExportDPI ?? 0)) dpi the gel's pixels are recalculated, so PNG and TIFF exports won't carry the original values (native is \(ws.nativeDPI) dpi). Your original file, PDF and SVG are unaffected, and each PNG or TIFF records the resampling.")
        }
        .focusedSceneValue(\.workspace, ws)
        .onAppear {
            ws.undoManager = undoManager
            ws.fileURL = fileURL
            AppRegistry.shared.register(ws)
            LaunchOptions.shared.apply(to: ws)
            if LaunchOptions.shared.openSettingsRequested {
                LaunchOptions.shared.openSettingsRequested = false
                openSettings()
            }
        }
        .onDisappear { AppRegistry.shared.unregister(ws) }
        .onChange(of: undoManager) { _, u in ws.undoManager = u }
        .onChange(of: document.project) { _, _ in ws.refreshCaches() }   // cheap unless pixels changed
        .onChange(of: fileURL) { _, u in ws.fileURL = u }
    }

    private var exportName: String {
        ((document.project.title?.isEmpty == false ? document.project.title! : document.project.image) as NSString).deletingPathExtension
    }

    /// The first image starts the project; any others are stacked under it as more gels, in order.
    private func adopt(_ urls: [URL]) {
        guard let url = urls.first else { return }
        do {
            let data = try Data(contentsOf: url)
            try document.adopt(imageData: data, name: url.lastPathComponent, undoManager: undoManager)
            ws.refreshCaches()
            if urls.count > 1 {
                ws.addGels(Array(urls.dropFirst()))
                ws.activeStrip = nil   // lanes first, on the gel that has them
            }
            ws.tool = .lanes
            ws.zoomRequest = .fit
        } catch {
            NSAlert(error: error).runModal()   // not an image, or 32-bit floating point: says why
        }
    }
}

struct StrictBadge: View {
    let kept: Workspace.PixelsKept
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: kept == .all ? "lock.fill" : kept == .some ? "lock.open.fill" : "slider.horizontal.3")
                    .foregroundStyle(kept == .all ? Color.green : Color.orange)
                Text(kept == .all ? "Original pixels" : kept == .some ? "Mixed" : "Adjusted pixels")
                    .foregroundStyle(.primary)
            }
            .font(.system(size: 12, weight: .medium))
            .padding(.horizontal, 4)
        }
        .help(kept == .all ? "Exports carry the original pixels, untouched"
              : kept == .some ? "Some gels keep their original pixels; the others' adjustments go into exports (each gel has its own switch)"
              : "Keep original pixels is off: exports include your adjustments")
    }
}

/// "Figure | Gel 1 | Gel 2 …": the stacked figure, or one gel on its own, numbered from the top as in the Gels list. Shown
/// with two gels or more. Choosing a gel makes it the chosen gel.
struct GelSwitcher: View {
    @Bindable var ws: Workspace

    var body: some View {
        // one glass pill like the other floating controls; with more gels than the width allows, the segments scroll sideways in it
        ViewThatFits(in: .horizontal) {
            segments
            ScrollView(.horizontal, showsIndicators: false) { segments }
        }
        .padding(4)
        .panelGlass(in: Capsule())
        .help("The stacked figure, or one gel on its own (double-click a gel to open it). Lane dividers are set on the gel marked lanes.")
    }

    private var segments: some View {
        let order = ws.project.stackOrder
        // the chosen view filled with the accent colour
        return HStack(spacing: 2) {
            segment(selected: !ws.showsGel, action: { ws.showFigure() }) { Text("Figure") }
            ForEach(Array(order.enumerated()), id: \.offset) { n, k in
                segment(selected: ws.showsGel && ws.activeStrip == k, action: { ws.showGel(k) }) {
                    HStack(spacing: 5) {
                        Text(verbatim: "Gel \(n + 1)")
                        if k == nil {   // the gel with the lanes, tagged as in the Gels list
                            Text("LANES").font(.system(size: 8.5, weight: .bold)).tracking(0.4)
                                .padding(.horizontal, 4).padding(.vertical, 1)
                                .overlay(RoundedRectangle(cornerRadius: 3).stroke(lineWidth: 0.8).opacity(0.6))
                        }
                    }
                }
            }
        }
    }

    private func segment<L: View>(selected: Bool, action: @escaping () -> Void, @ViewBuilder label: () -> L) -> some View {
        Button(action: action) {
            label()
                .lineLimit(1).fixedSize()
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(selected ? Color.white : Color.primary.opacity(0.75))
                .padding(.horizontal, 12).padding(.vertical, 5)
                .background(Capsule().fill(selected ? Color.accentColor : Color.clear))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - focus plumbing for menu commands

struct WorkspaceKey: FocusedValueKey { typealias Value = Workspace }
extension FocusedValues {
    var workspace: Workspace? {
        get { self[WorkspaceKey.self] }
        set { self[WorkspaceKey.self] = newValue }
    }
}

struct AppCommands: Commands {
    @FocusedValue(\.workspace) private var ws
    @Environment(\.newDocument) private var newDocument
    @Environment(\.openSettings) private var openSettings
    @AppStorage(AppAppearance.key) private var appearance: AppAppearance = .dark
    private let keys = ShortcutStore.shared

    var body: some Commands {
        let _ = ImageOpener.shared.ready(newDocument)
        CommandGroup(replacing: .appInfo) {
            // the standard About window (name, version and copyright from Info.plist, Credits.rtf under them),
            // without the build number in parentheses: "Version 0.1.1"
            Button("About GelScribe") { NSApp.orderFrontStandardAboutPanel(options: [.version: ""]) }
            Button("Check for Updates…") { UpdateNotice.shared.checkNow() }
        }
        CommandGroup(after: .newItem) {
            Button("New Gel with These Labels…") { newGelWithLabels() }
                .keyboardShortcut(keys.shortcut(.newGelWithLabels))
                .disabled(ws?.imageReady != true)
            Divider()
            Button("Add Gel…") { ws?.chooseGelImages() }   // more gels, or a cut membrane's other pieces, below
                .disabled(ws?.imageReady != true)
        }
        CommandGroup(after: .pasteboard) {
            Divider()
            Button("Copy Labels") { ws?.copyScheme() }
                .keyboardShortcut(keys.shortcut(.copyLabels))
                .disabled(ws?.imageReady != true)
            Button("Paste Labels") { ws?.pasteScheme(positions: false) }
                .keyboardShortcut(keys.shortcut(.pasteLabels))
                .disabled(ws?.imageReady != true)
            Button("Paste Labels and Positions") { ws?.pasteScheme(positions: true) }
                .keyboardShortcut(keys.shortcut(.pasteLabelsAndPositions))
                .disabled(ws?.imageReady != true)
            Button("Copy Lane Labels") { ws?.copyLaneLabels() }
                .disabled(ws?.imageReady != true)
            Button("Paste Lane Labels") { ws?.pasteLaneLabels() }
                .disabled(ws?.imageReady != true)
        }
        CommandMenu("Export") {
            Group {
                Button("PDF…") { export(.pdf, "pdf") }.keyboardShortcut(keys.shortcut(.exportPDF))
                Button("TIFF…") { export(.tiff, "tiff") }.keyboardShortcut(keys.shortcut(.exportTIFF))
                Button("PNG…") { export(.png, "png") }.keyboardShortcut(keys.shortcut(.exportPNG))
                Button("SVG…") { export(.svg, "svg") }.keyboardShortcut(keys.shortcut(.exportSVG))
                Divider()
                Button("Copy Figure") { ws?.copyFigure() }.keyboardShortcut(keys.shortcut(.copyFigure))
                Divider()
                Picker("PNG and TIFF Resolution", selection: Binding(get: { ws?.resampledExportDPI ?? 0 },
                                                                     set: { ws?.requestExportDPI($0 == 0 ? nil : $0) })) {
                    Text(nativeResolutionTitle).tag(0.0)
                    ForEach(resolutions, id: \.self) { Text(verbatim: "\(Int($0)) dpi (gel resampled)").tag($0) }
                }
            }
            .disabled(ws?.imageReady != true)
        }
        CommandGroup(replacing: .help) {}   // GelScribe has no help book: no Help menu
        CommandMenu("Format") {
            Button("Bigger Text") { ws?.bumpText(0.5) }.keyboardShortcut(keys.shortcut(.biggerText))
            Button("Smaller Text") { ws?.bumpText(-0.5) }.keyboardShortcut(keys.shortcut(.smallerText))
            Text("Acts on the selected label, or all text when none is selected")
        }
        CommandMenu("Tools") {
            ForEach(Tool.allCases) { t in
                Button("\(t.title)    \(keys.toolKey(t))") { ws?.tool = t }
            }
            Divider()
            Toggle("Snap to Band Centers", isOn: Binding(get: { ws?.snapping ?? true }, set: { ws?.snapping = $0 }))
            Button("Brightness & Contrast…") { ws?.showBrightnessContrast() }
                .keyboardShortcut(keys.shortcut(.brightnessContrast))
                .disabled(ws?.imageReady != true)
            Divider()
            Button("LLM Access…") {   // Settings, on its LLM tab
                SettingsNavigation.shared.tab = "llm"
                openSettings()
            }
        }
        CommandGroup(after: .toolbar) {
            Button("Zoom to Fit") { ws?.zoomRequest = .fit }.keyboardShortcut(keys.shortcut(.zoomFit))
            Button("Actual Pixels") { ws?.zoomRequest = .actual }.keyboardShortcut(keys.shortcut(.zoomActual))
            Button("Zoom In") { ws?.zoomRequest = .zoomIn }.keyboardShortcut(keys.shortcut(.zoomIn))
            Button("Zoom Out") { ws?.zoomRequest = .zoomOut }.keyboardShortcut(keys.shortcut(.zoomOut))
            Divider()
            Button((ws?.showGuides ?? true) ? "Hide Guides" : "Show Guides") { ws?.showGuides.toggle() }
                .keyboardShortcut(keys.shortcut(.toggleGuides))
            Button((ws?.inspectorVisible ?? true) ? "Hide Inspector" : "Show Inspector") { ws?.inspectorVisible.toggle() }
                .keyboardShortcut(keys.shortcut(.toggleInspector))
            Divider()
            Picker("Appearance", selection: Binding(get: { appearance }, set: { appearance = $0; AppAppearance.apply($0) })) {
                ForEach(AppAppearance.allCases) { Text($0.title).tag($0) }
            }
        }
    }

    /// Resolutions offered for PNG/TIFF besides native (one equal to native is native), plus one set elsewhere
    /// (e.g. the command line).
    private var resolutions: [Double] {
        let native = ws?.layout.map(FigureRenderer.nativeDPI)
        var r = [300.0, 600, 1200].filter { d in native.map { abs(d - $0) > 0.5 } ?? true }
        if let d = ws?.resampledExportDPI, !r.contains(d) { r.append(d); r.sort() }
        return r
    }

    private var nativeResolutionTitle: String {
        guard let l = ws?.layout else { return "Native (gel pixels 1:1)" }
        return "Native, \(Int(FigureRenderer.nativeDPI(l).rounded())) dpi (gel pixels 1:1)"
    }

    /// Pick the next gel's image; it opens as a new project with this one's labels, titles, names and ladder.
    private func newGelWithLabels() {
        guard let ws else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.png, .tiff, .jpeg, .image]
        panel.message = "Choose the next gel image. It gets this project's labels, titles, band names and ladder."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let pkg = try ws.packageForNewGel(imageURL: url)
            newDocument { GelDocument(package: pkg) }
        } catch {
            NSAlert(error: error).runModal()
        }
    }

    private func export(_ type: UTType, _ ext: String) {
        guard let ws else { return }
        let p = ws.project
        let base = ((p.title?.isEmpty == false ? p.title! : p.image) as NSString).deletingPathExtension
        ws.export(type, suggestedName: base + "." + ext)
    }
}

// MARK: - launch options (testing hooks)

/// `--tool lanes|ladder|names|crop|select`, `--tab …`, `--gel N [--gel-view]`, `--auto-align`, `--inspector-scroll Y`,
/// `--hide-guides`, `--edit tick:N|name:N|label:TEXT`, `--settings [shortcuts|llm]`, `--snapshot PATH [--quit]`: testing hooks
/// (the snapshot renders the window to a PNG after launch; `--gel` chooses the gel the Figure tab acts on, counted from the
/// top, and `--gel-view` shows it on its own; `--auto-align` clicks Auto-align for the chosen gel once the images are in;
/// `--edit` opens the editor of a ladder tick, band name or label, as a click would).
final class LaunchOptions {
    static let shared = LaunchOptions()
    /// The arguments, and those in the environment variable GELSCRIBE_ARGS (macOS reads a bare word after the options, like
    /// `select`, as a document to open, so a test run can pass them there instead).
    private let args = ProcessInfo.processInfo.arguments +
        (ProcessInfo.processInfo.environment["GELSCRIBE_ARGS"]?.split(separator: " ").map(String.init) ?? [])
    private var done = false
    var openSettingsRequested = false

    func value(_ flag: String) -> String? {
        guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
        return args[i + 1]
    }

    func apply(to ws: Workspace) {
        // tool/tab go to every window (macOS may restore other documents first); the rest happens once
        if let t = value("--tool").flatMap(Tool.init(rawValue:)) { ws.tool = t }
        if let tab = value("--tab").flatMap(InspectorTab.init(rawValue:)) { ws.inspectorTab = tab }
        if args.contains("--hide-guides") { ws.showGuides = false }
        if let n = value("--gel").flatMap(Int.init), case let order = ws.project.stackOrder, n >= 1, n <= order.count {
            ws.activeStrip = order[n - 1]
        }
        if args.contains("--gel-view") { ws.showGel(ws.activeStrip) }   // that gel on its own (two gels or more)
        guard !done else { return }
        done = true
        if args.contains("--settings") { openSettingsRequested = true }
        if args.contains("--auto-align") {   // as a click on Auto-align would, for the chosen gel (once the images are in)
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { ws.autoAlign() }
        }
        if let path = value("--snapshot") {
            let quit = args.contains("--quit")
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                Self.snapshot(to: URL(fileURLWithPath: path))
                if quit { NSApp.terminate(nil) }
            }
        }
    }

    static func snapshot(to url: URL) {
        guard let win = NSApp.windows.first(where: { $0.isVisible && $0.contentView != nil }),
              let view = win.contentView?.superview ?? win.contentView,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
    }
}

import AppKit
import GelKit
import Observation
import SwiftUI
import UniformTypeIdentifiers

enum Tool: String, CaseIterable, Identifiable {
    case select, lanes, ladder, names, crop, straighten, pan
    var id: String { rawValue }

    var title: String {
        switch self {
        case .select: "Select"
        case .lanes: "Lane Dividers"
        case .ladder: "Ladder Ticks"
        case .names: "Band Names"
        case .crop: "Crop"
        case .straighten: "Straighten"
        case .pan: "Pan"
        }
    }
    /// Crop and straighten work on the whole image; the other tools on the figure.
    var usesFullImage: Bool { self == .crop || self == .straighten }
    var symbol: String {
        switch self {
        case .select: "cursorarrow"
        case .lanes: "rectangle.split.3x1"
        case .ladder: "ruler"
        case .names: "tag"
        case .crop: "crop"
        case .straighten: "angle"   // not "level": it looks like the ladder tool's ruler
        case .pan: "hand.raised"
        }
    }
    var key: Character {
        switch self {
        case .select: "v"
        case .lanes: "l"
        case .ladder: "k"
        case .names: "n"
        case .crop: "c"
        case .straighten: "r"
        case .pan: "h"
        }
    }
    var hint: String {
        switch self {
        case .select: "Click a label to edit · drag to move"
        case .lanes: "Click between lanes · drag an end to tilt · ⌥-click to delete"
        case .ladder: "Click a ladder band · snaps to its center (⌥ = free)"
        case .names: "Click a band to name it · snaps to its center (⌥ = free)"
        case .crop: "Drag edges or corners · Return when done"
        case .straighten: "Drag along a band row or a lane edge · the image turns to level it"
        case .pan: "Drag to move · pinch or ⌘-scroll to zoom"
        }
    }
}

enum InspectorTab: String, CaseIterable, Identifiable {
    case labels, ladder, names, figure, export
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
    var symbol: String {
        switch self {
        case .labels: "textformat"
        case .ladder: "ruler"
        case .names: "tag"
        case .figure: "slider.horizontal.3"
        case .export: "square.and.arrow.up"
        }
    }
}

enum Selection: Equatable {
    case divider(UUID)
    case tick(UUID)
    case name(UUID)
    /// A label in the figure, selected to change its size.
    case text(FigureRole)
}

@Observable
final class Workspace {
    let document: GelDocument
    var undoManager: UndoManager?
    let id = UUID()
    let openedAt = Date()
    var fileURL: URL?
    /// Last change an LLM made here, shown briefly in the status pill.
    var llmNote: String?

    func noteLLM(_ action: String) {
        llmNote = action
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(4))
            if self?.llmNote == action { self?.llmNote = nil }
        }
    }

    var tool: Tool = .lanes {
        didSet {
            if tool == .lanes, lanesToolOff {   // the lane dividers are set on the gel that has them: the tool stays as it was
                tool = oldValue == .lanes ? .select : oldValue
                sayAboutTool(lanesToolNote)
                return
            }
            if tool == .crop { rememberCrop() } else if oldValue == .crop { cropBackup = nil }
            switch tool {
            case .lanes: inspectorTab = .labels
            case .ladder: inspectorTab = .ladder
            case .names: inspectorTab = .names
            case .crop: inspectorTab = .figure   // the crop section lives there
            case .straighten: inspectorTab = .figure; inspectorVisible = true   // Strict and the angle live there
            case .select, .pan: break
            }
        }
    }

    /// Why a tool can't be used right now, shown in the status pill for a few seconds.
    var toolNote: String?
    private func sayAboutTool(_ note: String) {
        toolNote = note
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(4))
            if self?.toolNote == note { self?.toolNote = nil }
        }
    }

    /// A click on an inspector tab: the tool follows, as the tab follows the tool. Figure and Export have no tool of
    /// their own, so they go to Select (a stray click can't add a tick), unless you're cropping, straightening or
    /// panning.
    func chooseTab(_ tab: InspectorTab) {
        switch tab {
        case .labels: tool = .lanes
        case .ladder: tool = .ladder
        case .names: tool = .names
        case .figure: if ![.crop, .straighten, .pan].contains(tool) { tool = .select }
        case .export: if tool != .pan { tool = .select }
        }
        inspectorTab = tab
    }
    var selection: Selection?
    var snapping = true
    /// The gel the Figure tab, crop and straighten work on: nil = the one with the lanes, else its number in
    /// `project.strips` (the names people see count from the top: `gelName`). Remembered by the gel's image file name, so
    /// it stays the same gel when gels change places (undo and redo too). Choosing a gel clears the alignment note.
    var activeStrip: Int? {
        get { chosenImage.flatMap { name in project.strips.firstIndex { $0.image == name }.map { $0 + 1 } } }
        set {
            let before = activeStrip
            chosenImage = newValue.flatMap { $0 >= 1 && $0 <= project.strips.count ? project.strips[$0 - 1].image : nil }
            alignNote = nil
            if activeStrip != before, showsGel { gelShownChanged() }   // a gel view shows the chosen gel: it follows
            if tool == .crop { rememberCrop() }
        }
    }
    private var chosenImage: String?

    // MARK: the figure and one gel on its own (view state, never saved)

    /// The canvas shows the chosen gel on its own instead of the stacked figure. Only with two gels or more.
    private var gelViewOn = false
    var showsGel: Bool { gelViewOn && !project.strips.isEmpty }
    /// The gel on view is one of the stacked ones (the gel with the lanes shows as a figure of its own, like a single gel).
    var viewsOtherGel: Bool { showsGel && activeStrip != nil }
    /// The lane dividers belong to the gel with the lanes, so they can't be set while another gel is on view.
    var lanesToolOff: Bool { viewsOtherGel }
    var lanesToolNote: String { "Lane dividers are set on \(gelName(nil)), the gel with the lanes." }

    /// Which gel is on view (nil = the figure), and which was when the view last changed.
    private var viewedKey: String? { showsGel ? (activeStrip.map { "gel \($0)" } ?? "lanes") : nil }
    @ObservationIgnored private var lastViewed: String?

    /// The switcher's "Figure": the stacked figure again. The chosen gel stays chosen.
    func showFigure() {
        guard gelViewOn else { return }
        gelViewOn = false
        selection = nil
        zoomRequest = .fit
    }

    /// The switcher's "Gel N", or a double-click on a gel: chooses it and shows it on its own (nil = the gel with the lanes).
    func showGel(_ k: Int?) {
        guard project.strips.isEmpty == false, k == nil || (k! >= 1 && k! <= project.strips.count) else { return }
        let wasShowing = showsGel
        activeStrip = k   // a gel view that was showing follows by itself
        gelViewOn = true
        if !wasShowing { gelShownChanged() }
    }

    /// A click on a gel in the Gels list: it becomes the chosen gel, and a gel view moves to it (the figure stays the figure).
    func chooseGel(_ k: Int?) {
        guard k == nil || (k! >= 1 && k! <= project.strips.count) else { return }
        activeStrip = k
    }

    private func gelShownChanged() {
        lastViewed = viewedKey
        if lanesToolOff, tool == .lanes { tool = .select }
        selection = nil
        zoomRequest = .fit
    }
    /// What the last Auto-align found, shown under the gel's alignment controls.
    var alignNote: String?
    /// Auto levels on screen only; never reaches an export. Remembered in the project.
    var enhanceView: Bool {
        get { document.project.viewEnhance }
        set { edit(newValue ? "Enhance View" : "Normal View") { $0.viewEnhance = newValue } }
    }
    /// Waiting for the user to agree to turning Strict off so brightness & contrast go into exports.
    var pendingContrastExport = false
    /// Bumped to scroll the inspector to Brightness & Contrast.
    var revealContrast = 0
    /// Bumped to scroll the Figure tab to its top, where the Original image switch is.
    var revealStrict = 0
    var showGuides = true
    var inspectorVisible = true
    var inspectorTab: InspectorTab = .labels
    /// The ladder in use; new projects start with the last one chosen.
    var presetID: String = UserDefaults.standard.string(forKey: "lastLadderPreset") ?? "thermo-pageruler-prestained"
    var quickLabels = ""
    /// Waiting for a click that puts the ladder's unit label ("kDa") at that height.
    var placingUnit = false
    var zoomRequest: ZoomRequest?
    var recentNames: [String] = UserDefaults.standard.stringArray(forKey: "recentNames") ?? []
    /// What Quick labels has to say about the text typed (a warning, or why it was refused), shown under the field.
    var lastError: String?

    /// Something the user needs to be told wherever they are (an export that failed, a gel that couldn't be added): shown
    /// as an alert on the window.
    struct Problem: Equatable {
        var title: String
        var message: String
    }
    var problem: Problem?

    enum ZoomRequest: Equatable { case fit, actual, zoomIn, zoomOut }

    init(document: GelDocument) {
        self.document = document
        defer { refreshCaches() }
        if let name = document.project.ladder?.name,
           let p = LadderLibrary.all().first(where: { $0.displayName == name }) { presetID = p.id }
        quickLabels = QuickLabels.shorthand(document.project)
    }

    var project: GelProject { document.project }

    // MARK: derived images (cached)

    /// Image facts the inspector shows; updated whenever the caches rebuild.
    private(set) var imageWidth = 0
    private(set) var imageHeight = 0
    private(set) var measuredBackground: Int?
    /// Why the gel with the lanes can't be shown ("Gel 1's image (file) can't be read."), nil when it can.
    private(set) var mainProblem: String?

    @ObservationIgnored private var imageKey: Int?
    @ObservationIgnored private var viewKey: String?
    @ObservationIgnored private(set) var source: SourceImage?
    @ObservationIgnored private(set) var working: WorkingImage? {
        didSet { if imageReady != (working != nil) { imageReady = working != nil } }
    }
    /// Whether the gel's image is decoded: what menu commands check, since `working` itself isn't observed.
    private(set) var imageReady = false
    @ObservationIgnored private(set) var dark: GrayImage?
    @ObservationIgnored private(set) var displayFull: CGImage?

    /// Rebuilds decode/analysis caches only when the image or a pixel-affecting setting changed.
    func refreshCaches() {
        if gelViewOn, project.strips.isEmpty { gelViewOn = false }   // the gels are gone (removed, or an undo): the figure is all there is
        // the gel on view changed without being asked (an undo took the gel away): the new one is shown to fit
        if viewedKey != lastViewed, viewedKey != nil { gelShownChanged() } else { lastViewed = viewedKey }
        guard let data = document.imageData else {
            source = nil; working = nil; dark = nil; displayFull = nil; imageKey = nil; viewKey = nil
            if imageWidth != 0 { imageWidth = 0; imageHeight = 0; measuredBackground = nil }
            if mainProblem != nil { mainProblem = nil }
            stripCache = [:]; stripFailures = [:]
            if !stripSizes.isEmpty { stripSizes = [] }
            if !stripProblems.isEmpty { stripProblems = [:] }
            return
        }
        let p = project
        var h = Hasher()
        h.combine(data.count); h.combine(data.prefix(64)); h.combine(p.strict); h.combine(p.rotateDeg); h.combine(p.fillPadding)
        h.combine(p.fillMode); h.combine(p.fillValue); h.combine(p.turn); h.combine(p.display.bandsDark)   // the snapping map follows it
        let key = h.finalize()
        if key != imageKey {
            do {
                if source == nil || source!.data.count != data.count || imageKey == nil {
                    source = try GelPackage(project: p, imageData: data).decodeMain()
                }
                working = WorkingImage(source: source!, project: p)
                dark = working!.darkness(bandsDark: p.display.bandsDark)
                imageKey = key
                viewKey = nil
                let w = working!
                let bg = Int((Double(w.background) * 255).rounded())
                if imageWidth != w.width { imageWidth = w.width }
                if imageHeight != w.height { imageHeight = w.height }
                if measuredBackground != bg { measuredBackground = bg }
                if mainProblem != nil { mainProblem = nil }
            } catch {
                if mainProblem != error.localizedDescription { mainProblem = error.localizedDescription }
                refreshStripCaches(p)   // the other gels are there all the same
                return
            }
        }
        let d = p.display
        let vk = "\(key)|\(enhanceView)|\(d.black)|\(d.white)|\(d.gamma)|\(d.invert)"
        if vk != viewKey, let working {
            displayFull = working.viewImage(project: p, enhance: enhanceView)
            viewKey = vk
        }
        refreshStripCaches(p)
    }

    // MARK: stacked gels (pieces of a cut membrane, or more gels of the same samples)

    private struct PieceCache {
        var key: Int
        var source: SourceImage
        var working: WorkingImage
        var dark: GrayImage
        var viewKey = ""
        var view: CGImage?
    }
    /// By image file name, so removing a strip doesn't muddle the others.
    @ObservationIgnored private var stripCache: [String: PieceCache] = [:]
    /// The settings a strip's image failed to decode with, and why, so it isn't tried again on every redraw.
    @ObservationIgnored private var stripFailures: [String: (key: Int, message: String)] = [:]
    /// Each strip's working-image size, in strip order, nil for a gel that can't be read, so no gel's number ever moves to
    /// another gel (what the layout needs; observed, so the canvas follows).
    private(set) var stripSizes: [CGSize?] = []
    /// Why a gel's image can't be used, by its file name (observed, so the panels and the status pill follow).
    private(set) var stripProblems: [String: String] = [:]

    private func refreshStripCaches(_ p: GelProject) {
        var sizes: [CGSize?] = []
        var problems: [String: String] = [:]
        var package: GelPackage?   // made only when a gel has to be decoded
        for (i, s) in p.strips.enumerated() {
            guard let data = document.stripData(i + 1) else {   // no picture stored for this gel
                problems[s.image] = p.unreadableMessage(strip: i + 1)
                sizes.append(nil)
                continue
            }
            var h = Hasher()
            h.combine(data.count); h.combine(data.prefix(64)); h.combine(p.isStrict(gel: i + 1)); h.combine(s.rotateDeg); h.combine(s.turn)
            h.combine(p.fillPadding); h.combine(p.fillMode); h.combine(p.fillValue); h.combine(s.display.bandsDark)
            let key = h.finalize()
            var c = stripCache[s.image]
            if c?.key != key {
                if let failed = stripFailures[s.image], failed.key == key {
                    problems[s.image] = failed.message
                    sizes.append(nil)
                    continue
                }
                do {
                    let kept = c.flatMap { $0.source.data == data ? $0.source : nil }   // only its settings changed
                    let source: SourceImage
                    if let kept { source = kept } else {
                        package = package ?? document.imageData.map { GelPackage(project: p, imageData: $0, stripImages: document.stripImages) }
                        guard let package else { throw GelKitError.unreadableImage }
                        source = try package.decodeStrip(i + 1)   // fails with "Gel N's image (file) can't be read."
                    }
                    let w = WorkingImage(source: source, project: p.stripProject(i + 1))
                    c = PieceCache(key: key, source: source, working: w, dark: w.darkness(bandsDark: s.display.bandsDark))
                } catch {
                    stripFailures[s.image] = (key, error.localizedDescription)
                    stripCache[s.image] = nil
                    problems[s.image] = error.localizedDescription
                    sizes.append(nil)
                    continue
                }
            }
            guard var cache = c else { sizes.append(nil); continue }
            let d = s.display
            let vk = "\(key)|\(d.black)|\(d.white)|\(d.gamma)|\(d.invert)"
            if vk != cache.viewKey {
                cache.view = cache.working.viewImage(project: p.stripProject(i + 1), enhance: false)
                cache.viewKey = vk
            }
            stripCache[s.image] = cache
            sizes.append(CGSize(width: cache.working.width, height: cache.working.height))
        }
        let names = Set(p.strips.map(\.image))
        stripCache = stripCache.filter { names.contains($0.key) }
        stripFailures = stripFailures.filter { names.contains($0.key) }
        if sizes != stripSizes { stripSizes = sizes }
        if problems != stripProblems { stripProblems = problems }
    }

    /// Strip `k`'s cached images (1-based), if it decoded.
    func stripWorking(_ k: Int) -> WorkingImage? {
        k >= 1 && k <= project.strips.count ? stripCache[project.strips[k - 1].image]?.working : nil
    }
    func stripDark(_ k: Int) -> GrayImage? {
        k >= 1 && k <= project.strips.count ? stripCache[project.strips[k - 1].image]?.dark : nil
    }
    func stripView(_ k: Int) -> CGImage? {
        k >= 1 && k <= project.strips.count ? stripCache[project.strips[k - 1].image]?.view : nil
    }
    /// Every gel's working image by its number, nil for one that can't be read: no gel's picture takes another's place.
    var stripWorkingList: [WorkingImage?] { project.strips.indices.map { stripWorking($0 + 1) } }

    /// Why the chosen gel's image can't be used, if it can't.
    var activeProblem: String? {
        guard let k = activeStrip else { return mainProblem }
        return stripProblems[project.strips[k - 1].image]
    }

    /// Why the figure can't be made because a gel's image can't be read: "Gel N's image (file) can't be read." for the one
    /// nearest the top (N counted from the top). Nil when every gel is there.
    var unreadableGel: String? {
        var missing: [Int?] = project.strips.indices.map { $0 + 1 }.filter { stripProblems[project.strips[$0 - 1].image] != nil }
        if mainProblem != nil { missing.append(nil) }
        guard let first = missing.min(by: { project.position(of: $0) < project.position(of: $1) }) else { return nil }
        if let k = first { return stripProblems[project.strips[k - 1].image] }
        return mainProblem
    }

    /// Where each piece sits in the figure.
    var stack: StackGeometry {
        StackGeometry(project: project, mainWidth: imageWidth, mainHeight: imageHeight, stripSizes: stripSizeList)
    }

    /// Figure row of a mark in its own piece (nil when that piece isn't in the figure).
    func figureY(strip: Int?, y: Double) -> Double? { stack.figureY(strip: strip, y: y, inside: false) }

    /// The active piece: its working image, view, darkness map, size and brightness & contrast.
    var activeWorking: WorkingImage? { activeStrip.map { stripWorking($0) } ?? working }
    var activeView: CGImage? { activeStrip.map { stripView($0) } ?? displayFull }
    var activeDark: GrayImage? { activeStrip.map { stripDark($0) } ?? dark }
    /// The active gel's working-image size; 0 × 0 while that gel can't be read.
    var activeSize: (width: Int, height: Int) { gelSize(activeStrip) ?? (0, 0) }
    var activeDisplay: DisplaySettings { activeStrip.map { project.strips[$0 - 1].display } ?? project.display }
    var activeRotation: Double { activeStrip.map { project.strips[$0 - 1].rotateDeg } ?? project.rotateDeg }
    var activeName: String { project.strips.isEmpty ? "Image" : gelName(activeStrip) }

    /// A gel's name: its place in the stack, counted from the top (nil = the gel with the lanes).
    func gelName(_ strip: Int?) -> String { "Gel \(project.position(of: strip) + 1)" }

    /// The active gel's crop: the columns and rows of its own working image that go into the figure. A gel with no columns of its
    /// own shows those under the lanes gel's crop, so that is where the crop tool's side handles start.
    var activeStripRect: PixelRect? {
        guard let k = activeStrip, stack.piece(strip: k) != nil, let size = gelSize(k) else { return nil }
        let c = project.keptColumns(strip: k, width: size.width, mainWidth: imageWidth, mainHeight: imageHeight)
        let r = project.strips[k - 1].usedRows(height: size.height)
        return PixelRect(x0: c.left, y0: r.top, x1: c.right, y1: r.bottom)
    }

    /// Snapping in whichever piece holds figure point (x, y): that piece, y in its own pixels, and y in the figure. The row
    /// stays inside what that piece shows of its gel, so a mark never ends up where the figure doesn't draw it.
    func snapInFigure(x: Double, y: Double, free: Bool) -> (strip: Int?, y: Double, figureY: Double) {
        let g = stack
        guard g.hasStrips, let piece = g.piece(atFigureY: y), let k = piece.strip else {
            let sy = snappedY(x: x, y: y, free: free)
            return (nil, sy, sy)
        }
        let ly = snapped(in: piece, x: x, figureY: y, free: free)
        return (k, ly, piece.toFigure(x: 0, y: ly).y)
    }

    /// Row `fy` of the figure in a strip's own pixels, kept inside the strip, snapped to a band there.
    private func snapped(in piece: StackGeometry.Piece, x: Double, figureY fy: Double, free: Bool) -> Double {
        let local = piece.toPiece(x: x, y: min(max(fy, piece.top), piece.bottom - 1))
        let w = (project.lanes.width > 0 ? project.lanes.width : 100) * piece.scale
        return markRow(strip: piece.strip, x: local.x, y: local.y, laneWidth: w, free: free)
    }

    /// A gel's working-image size (strip nil = the gel with the lanes), if it's there.
    func gelSize(_ strip: Int?) -> (width: Int, height: Int)? {
        guard let k = strip else { return working == nil ? nil : (imageWidth, imageHeight) }
        guard k >= 1, k <= stripSizes.count, let size = stripSizes[k - 1] else { return nil }
        return (Int(size.width), Int(size.height))
    }

    /// Every gel's size by its number, nil for one that can't be read (what GelKit's stacking takes).
    private var stripSizeList: [(width: Int, height: Int)?] {
        stripSizes.map { $0.map { (width: Int($0.width), height: Int($0.height)) } }
    }

    /// `y` (in gel `strip`'s own pixels) moved inside the rows that gel shows in the figure: a tick or name belongs to its gel.
    func clampedY(_ y: Double, strip: Int?) -> Double {
        guard let size = gelSize(strip) else { return y }
        return project.clampY(y, strip: strip, width: size.width, height: size.height)
    }

    /// Row `y` of a gel kept inside the rows it shows in the figure and snapped to the centre of a band at column `x` (that
    /// gel's own pixels), unless snapping is off or `free`. A band outside those rows doesn't count, so snapping can't carry
    /// a mark out of its gel.
    private func markRow(strip: Int?, x: Double, y: Double, laneWidth: Double, free: Bool) -> Double {
        let at = clampedY(y, strip: strip)
        let map = strip == nil ? dark : stripDark(strip!)
        guard snapping, !free, let size = gelSize(strip), let map else { return at.rounded() }
        let rows = project.figureRows(strip: strip, width: size.width, height: size.height)
        let band = Detect.snapBand(in: map, x: x, y: at, laneWidth: laneWidth, rows: rows)
        return clampedY((band ?? at).rounded(), strip: strip)
    }

    /// A gel's stretch in the figure; 1 for the gel with the lanes (`k` nil), which isn't stretched.
    func stripScale(_ k: Int?) -> Double { k.map { project.effectiveAlignment($0).scale } ?? 1 }

    /// Where a gel sits sideways: the Shift field's number (`k` nil = the gel with the lanes, in whole pixels).
    func gelShift(_ k: Int?) -> Double { k.map { project.effectiveAlignment($0).shift } ?? project.effectiveMainShift }
    var activeShift: Double { gelShift(activeStrip) }

    /// Puts gel `k` (nil = the gel with the lanes) at shift `v`: whole pixels for the lanes gel and for a gel that keeps its original
    /// pixels, hundredths of a pixel for the others. No other gel's place changes.
    private static func place(_ p: inout GelProject, gel k: Int?, at v: Double) {
        guard v.isFinite else { return }
        let limit = 1_000_000.0
        if let k {
            p.strips[k - 1].shift = min(max(p.isStrict(gel: k) ? v.rounded() : (v * 100).rounded() / 100, -limit), limit)
        } else {
            p.mainShift = min(max(v.rounded(), -limit), limit)
        }
    }

    /// Live, while a gel is dragged sideways (`k` nil = the gel with the lanes).
    func liveStripShift(_ k: Int?, _ v: Double) {
        guard k == nil || (k! >= 1 && k! <= project.strips.count) else { return }
        live("Line Up Gel") { p in Self.place(&p, gel: k, at: v) }
    }

    /// Moves the chosen gel's picture `dx` figure pixels to the right (left when negative); the lanes gel takes its lane dividers, labels,
    /// ticks and names along, and no other gel moves.
    func nudgeActiveStrip(by dx: Double) {
        let k = activeStrip
        let s = stripScale(k)
        edit("Nudge Gel") { p in
            Self.place(&p, gel: k, at: (k.map { p.strips[$0 - 1].shift } ?? p.effectiveMainShift) - s * dx)
        }
    }

    /// Adds a gel at the bottom of the stack, chooses it, and lines it up under the lanes if there are any yet. An image that
    /// can't be added (not an image, or 32-bit floating point) is told to the user in an alert.
    @discardableResult
    func addGel(imageData data: Data, name: String) -> Int? {
        do { return try addGelOrThrow(imageData: data, name: name) } catch {
            problem = Problem(title: "Can't add the gel", message: "\(name): \(error.localizedDescription)")
            return nil
        }
    }

    @discardableResult
    private func addGelOrThrow(imageData data: Data, name: String) throws -> Int {
        let k = try document.addStrip(imageData: data, name: name, undoManager: undoManager)
        refreshCaches()
        activeStrip = k
        inspectorTab = .figure
        inspectorVisible = true
        if project.lanes.centers.count >= 2 { autoAlign() } else {
            alignNote = "Place the lane dividers on \(gelName(nil)), then Auto-align lines this gel up."
        }
        return k
    }

    /// Adds each image as a gel at the bottom, in order. The ones that can't be added are told together, by reason.
    func addGels(_ urls: [URL]) {
        var reasons: [String] = [], files: [String: [String]] = [:]   // why, in order, and the files each reason is for
        for url in urls {
            do { try addGelOrThrow(imageData: try Data(contentsOf: url), name: url.lastPathComponent) } catch {
                let why = error.localizedDescription
                if files[why] == nil { reasons.append(why) }
                files[why, default: []].append(url.lastPathComponent)
            }
        }
        guard !reasons.isEmpty else { return }
        let failed = files.values.reduce(0) { $0 + $1.count }
        problem = Problem(title: failed == 1 ? "Can't add the gel" : "Can't add some of the gels",
                          message: reasons.map { "\(files[$0]!.joined(separator: ", ")): \($0)" }.joined(separator: "\n"))
    }

    func chooseGelImages() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.png, .tiff, .jpeg, .image]
        panel.allowsMultipleSelection = true
        panel.message = "Choose the gels to stack under this one, top first"
        guard panel.runModal() == .OK else { return }
        addGels(panel.urls)
    }

    /// Takes the chosen gel out, with its ticks and names; the gel that takes its place is chosen next.
    func removeActiveGel() {
        guard let k = activeStrip else { return }
        let place = project.position(of: k)
        document.removeStrip(k, undoManager: undoManager)
        refreshCaches()
        let order = project.stackOrder
        activeStrip = order[min(place, order.count - 1)]
        alignNote = nil
    }

    /// Moves a gel from place `from` to place `to` in the stack (from 0 at the top). The chosen gel stays chosen, through
    /// undo and redo too (`activeStrip` follows the gel, not its number).
    func moveGel(from: Int, to: Int) {
        edit("Move Gel") { p in GelOps.moveGel(&p, from: from, to: to) }
        refreshCaches()
    }

    /// Lines every stacked gel up under the lanes, in one step. A gel whose lanes can't be found, or don't fit, is left as it
    /// is, and the note says which and why.
    func autoAlignAll() {
        guard project.lanes.centers.count >= 2 else { alignNote = "Place the lane dividers on \(gelName(nil)) first."; return }
        var found: [Int: StripAlign.Result] = [:], refused: [String] = [], advice: [String] = []
        for k in project.strips.indices.map({ $0 + 1 }) {
            let fit = alignment(project, strip: k)
            if let r = fit?.outcome.result { found[k] = r; if let n = fit?.note { advice.append(n) } }
            else { refused.append(refusalNote(fit?.outcome, strip: k)) }
        }
        if !found.isEmpty {
            // the fit is to the lanes wherever the lanes gel sits; a gel's shift is its place in the figure
            edit("Auto-align Gels") { p in
                for (k, r) in found { p.strips[k - 1].shift = p.shiftToStore(laneShift: r.shift, scale: r.scale); p.strips[k - 1].scale = r.scale }
            }
        }
        var parts: [String] = []
        if let worst = found.values.map(\.worst).max() {
            parts.append("Lined up \(found.count) gel\(found.count == 1 ? "" : "s"); the worst lane is \(FigureLayoutEngine.formatSize(worst)) px off.")
        }
        let said = parts + advice + refused
        alignNote = said.isEmpty ? nil : said.joined(separator: " ")
    }

    /// Turns the active piece by quarter turns; a half turn keeps its marks, a quarter turn clears them. Its lanes now
    /// run the other way, so the strips it moves are lined up again in the same step.
    func turnActive(by q: Int) {
        let k = activeStrip
        guard let size = gelSize(k) else { return }   // a gel that can't be read has no picture to turn
        var turned = project
        GelOps.turn(&turned, strip: k, by: q, width: size.width, height: size.height)
        var found: [Int: StripAlign.Result] = [:], refused: [Int: String] = [:]
        for j in k.map({ [$0] }) ?? turned.strips.indices.map({ $0 + 1 }) {
            guard let fit = alignment(turned, strip: j) else { continue }
            if let a = fit.outcome.result { found[j] = a } else { refused[j] = refusalNote(fit.outcome, strip: j) }
        }
        edit(q % 2 == 0 ? "Turn 180°" : "Turn 90°") { p in
            GelOps.turn(&p, strip: k, by: q, width: size.width, height: size.height)
            for (j, a) in found { p.strips[j - 1].shift = p.shiftToStore(laneShift: a.shift, scale: a.scale); p.strips[j - 1].scale = a.scale }
        }
        if let k {
            alignNote = found[k].map { note($0, strip: k) } ?? refused[k]
        } else {
            alignNote = refused.isEmpty ? nil : refused.sorted { $0.key < $1.key }.map(\.value).joined(separator: " ")
        }
    }

    /// Strip `k` lined up under the lanes of project `p` (as it is, or as an edit is about to make it), from the strip's
    /// decoded image, with its own Keep original pixels in mind. Nil when there are no lanes yet or the strip's image isn't
    /// there; otherwise the outcome, which says why when it found no fit (`StripAlign.refusal`), and the note about a gel
    /// that keeps its pixels and would fit better stretched (`StripAlign.fit`).
    private func alignment(_ p: GelProject, strip k: Int) -> (outcome: StripAlign.Outcome, note: String?)? {
        guard k >= 1, k <= p.strips.count, p.lanes.centers.count >= 2,
              let src = stripCache[p.strips[k - 1].image]?.source else { return nil }
        let s = p.strips[k - 1]
        let w = WorkingImage(source: src, project: p.stripProject(k))
        return StripAlign.fit(mainCenters: p.lanes.centers, strip: w, bandsDark: s.display.bandsDark,
                              rows: s.rowRange(height: w.height), keepsOriginal: p.isStrict(gel: k), gelNumber: p.position(of: k) + 1)
    }

    /// What to tell the user when gel `k` couldn't be lined up: why its lanes were refused, or that its image isn't there.
    private func refusalNote(_ outcome: StripAlign.Outcome?, strip k: Int) -> String {
        guard let outcome else { return stripProblems[project.strips[k - 1].image] ?? project.unreadableMessage(strip: k) }
        return StripAlign.refusal(outcome, gelNumber: project.position(of: k) + 1, strict: project.isStrict(gel: k)) ?? ""
    }

    /// How well gel `k` lines up, for the note under its alignment controls.
    private func note(_ r: StripAlign.Result, strip k: Int) -> String {
        let lanes = r.pitch > 0 ? String(format: " (%.0f%% of a lane)", r.worst / r.pitch * 100) : ""
        return "Lanes line up within \(FigureLayoutEngine.formatSize(r.worst)) px\(lanes)" +
            (project.isStrict(gel: k) ? "; keeping original pixels allows a shift only." :
                (r.scale != 1 ? String(format: "; stretched %.2f%%.", (r.scale - 1) * 100) : "."))
    }

    /// The Shift field: the chosen gel's place sideways, the gel with the lanes' too.
    func setShift(_ v: Double) {
        let k = activeStrip
        edit("Line Up Gel") { p in Self.place(&p, gel: k, at: v) }
    }

    func setScale(_ v: Double) {
        guard let k = activeStrip, !project.isStrict(gel: k) else { return }
        edit("Stretch Gel") { p in p.strips[k - 1].scale = min(max((v * 10000).rounded() / 10000, 0.5), 2) }
    }

    /// Finds the active strip's lanes and lines them up under the main image's (a whole-pixel shift only while that gel keeps
    /// its original pixels). When it can't trust a fit it changes nothing, and the note says why.
    func autoAlign() {
        guard let k = activeStrip else { return }
        guard project.lanes.centers.count >= 2 else { alignNote = "Place the lane dividers on \(gelName(nil)) first."; return }
        let fit = alignment(project, strip: k)
        guard let r = fit?.outcome.result else { alignNote = refusalNote(fit?.outcome, strip: k); return }
        edit("Auto-align Gel") { p in p.strips[k - 1].shift = p.shiftToStore(laneShift: r.shift, scale: r.scale); p.strips[k - 1].scale = r.scale }
        alignNote = note(r, strip: k) + (fit?.note.map { " " + $0 } ?? "")
    }

    /// Live, while the active gel's crop is dragged in the crop view. It stays inside the gel and at least 8 pixels each way, as
    /// the crop of the gel with the lanes does; a drag that starts and stays beyond an edge of the gel has nothing to take, so
    /// the gel keeps the crop it had.
    func liveStripCrop(_ r: PixelRect) {
        guard let k = activeStrip, activeSize.width > 0, activeSize.height > 0 else { return }
        let w = Double(activeSize.width), h = Double(activeSize.height)
        func clamp(_ v: Double, _ limit: Double) -> Double { min(max(v, 0), limit) }
        let l = clamp(min(r.x0, r.x1), w), rt = clamp(max(r.x0, r.x1), w), t = clamp(min(r.y0, r.y1), h), b = clamp(max(r.y0, r.y1), h)
        guard l < rt, t < b else { return }
        let now = activeStripRect, own = project.strips[k - 1].left != nil || project.strips[k - 1].right != nil
        let left = max(0, min(l, rt - 8)).rounded(), right = min(w, max(rt, l + 8)).rounded()
        live("Gel Crop") { p in
            GelOps.setStripCrop(&p, strip: k, left: left, top: max(0, min(t, b - 8)).rounded(), right: right,
                                bottom: min(h, max(b, t + 8)).rounded(), width: activeSize.width, height: activeSize.height)
            // dragging only the rows leaves a gel that follows the lanes gel's crop following it
            if !own, let now, left == now.x0, right == now.x1 { p.strips[k - 1].left = nil; p.strips[k - 1].right = nil }
        }
    }

    /// The chosen stacked gel's crop when the Crop tool began (or when the gel was chosen in it), for Esc to put back. The gel with
    /// the lanes isn't kept: its crop is made as you drag, and Esc just leaves.
    @ObservationIgnored private var cropBackup: (image: String, left: Double?, right: Double?, top: Double?, bottom: Double?)?
    private func rememberCrop() {
        guard tool == .crop, let k = activeStrip, k <= project.strips.count else { cropBackup = nil; return }
        let s = project.strips[k - 1]
        cropBackup = (s.image, s.left, s.right, s.top, s.bottom)
    }

    /// Esc in the Crop tool: the stacked gel's crop goes back to what it was when the tool began (one undo step), and the tool
    /// is left. Return leaves it with the crop as dragged.
    func cancelCrop() {
        if let b = cropBackup, let i = project.strips.firstIndex(where: { $0.image == b.image }) {
            let s = project.strips[i]
            if (s.left, s.right, s.top, s.bottom) != (b.left, b.right, b.top, b.bottom) {
                edit("Cancel Crop") { p in (p.strips[i].left, p.strips[i].right, p.strips[i].top, p.strips[i].bottom) = (b.left, b.right, b.top, b.bottom) }
            }
        }
        cropBackup = nil
        tool = .select
    }

    var layout: FigureLayout? {
        guard working != nil else { return nil }
        return FigureLayoutEngine.layout(project, imageWidth: imageWidth, imageHeight: imageHeight, stack: stack)
    }

    var geometry: LaneGeometry? { GelOps.geometry(project, imageWidth: imageWidth, imageHeight: imageHeight) }

    // What the canvas shows: the stacked figure, or (a gel view of the gel with the lanes) that gel as a figure of its own,
    // its marks only, as if it were the only gel. The stacked gel on view is drawn whole (see CanvasView).
    private var lanesGelAlone: Bool { showsGel && activeStrip == nil }
    var shownStack: StackGeometry {
        lanesGelAlone ? StackGeometry(project: project, mainWidth: imageWidth, mainHeight: imageHeight, stripSizes: []) : stack
    }
    var shownLayout: FigureLayout? {
        guard lanesGelAlone else { return layout }
        return working == nil ? nil : FigureLayoutEngine.layout(project, imageWidth: imageWidth, imageHeight: imageHeight)
    }
    var shownImage: CGImage? {
        guard lanesGelAlone, let full = displayFull else { return displayCropped }
        let r = crop
        return full.cropping(to: CGRect(x: r.x0, y: r.y0, width: r.width, height: r.height))
    }

    /// Row `y` of gel `strip` (nil = the gel with the lanes) in its own pixels, snapped to a band at its column `x` (also its
    /// own pixels) unless snapping is off or `free`; kept inside the rows the figure shows of it.
    func snapInGel(strip: Int?, x: Double, y: Double, free: Bool) -> Double {
        let scale = strip.map { project.effectiveAlignment($0).scale } ?? 1
        return markRow(strip: strip, x: x, y: y, laneWidth: (project.lanes.width > 0 ? project.lanes.width : 100) * scale, free: free)
    }

    var crop: PixelRect { project.effectiveCrop(width: imageWidth, height: imageHeight) }

    @ObservationIgnored private var composedKey: String?
    @ObservationIgnored private var composed: CGImage?

    /// The gel as shown in the figure on screen (cropped; strips stacked). Identical to the export unless "enhance
    /// view" is on.
    var displayCropped: CGImage? {
        guard let full = displayFull else { return nil }
        let g = stack
        guard g.hasStrips else {
            let r = crop
            return full.cropping(to: CGRect(x: r.x0, y: r.y0, width: r.width, height: r.height))
        }
        let key = "\(viewKey ?? "")|\(project.strips.map { stripCache[$0.image]?.viewKey ?? "" })|\(g)"
        if key != composedKey {
            composed = StripStack.viewImage(views: [full] + project.strips.indices.map { stripView($0 + 1) }, stack: g)
            composedKey = key
        }
        return composed
    }

    // MARK: edits

    func edit(_ name: String, _ change: (inout GelProject) -> Void) {
        if typingQuickLabels { finishQuickLabels(normalize: false) }   // close the typing run first: clean undo
        document.edit(name, undoManager: undoManager, change)
    }
    func live(_ name: String? = nil, _ change: (inout GelProject) -> Void) { document.live(name, change) }
    func endGesture(_ name: String) { document.endGesture(name, undoManager: undoManager) }

    private func sync(_ p: inout GelProject) { p.syncLaneCenters(imageWidth: imageWidth, imageHeight: imageHeight) }

    // dividers
    @discardableResult
    func addDivider(x: Double, y: Double) -> UUID {
        let d = LaneDivider(x: x, dotY: y)
        edit("Add Lane Divider") { p in
            p.lanes.dividers.append(d)
            p.lanes.dividers.sort { ($0.xTop + $0.xBottom) < ($1.xTop + $1.xBottom) }
            sync(&p)
        }
        return d.id
    }

    enum DividerDrag { case move(dx: Double, dotY: Double), top(x: Double), bottom(x: Double) }

    /// Live divider drag. Dragging one end keeps the other *visible* end (at the crop's top/bottom row) in place.
    func dragDivider(_ id: UUID, from start: LaneDivider, _ drag: DividerDrag) {
        let H = Double(imageHeight)
        let yA = crop.y0, yB = crop.y1
        live("Move Lane Divider") { p in
            guard let i = p.lanes.dividers.firstIndex(where: { $0.id == id }) else { return }
            var d = start
            d.id = id
            switch drag {
            case .move(let dx, let dotY):
                d.xTop += dx; d.xBottom += dx; d.dotY = dotY
            case .top(let x):
                (d.xTop, d.xBottom) = Self.line(xA: x, yA: yA, xB: start.x(atY: yB, height: H), yB: yB, height: H)
            case .bottom(let x):
                (d.xTop, d.xBottom) = Self.line(xA: start.x(atY: yA, height: H), yA: yA, xB: x, yB: yB, height: H)
            }
            p.lanes.dividers[i] = d
            sync(&p)
        }
    }

    /// Image-top and image-bottom x of the straight line through (xA, yA) and (xB, yB).
    static func line(xA: Double, yA: Double, xB: Double, yB: Double, height H: Double) -> (Double, Double) {
        let m = abs(yB - yA) < 1e-6 ? 0 : (xB - xA) / (yB - yA)
        return (xA - m * yA, xA + m * (H - yA))
    }

    func deleteDivider(_ id: UUID) {
        edit("Delete Lane Divider") { p in p.lanes.dividers.removeAll { $0.id == id }; sync(&p) }
        if selection == .divider(id) { selection = nil }
    }

    func clearDividers() {
        edit("Clear Lane Dividers") { p in p.lanes.dividers.removeAll(); p.lanes.centers.removeAll() }
        selection = nil
    }

    // ladder ticks
    var preset: LadderPreset? { LadderLibrary.all().first { $0.id == presetID } }

    /// Row `y` of the gel with the lanes, inside its crop, snapped to a band at column `x`.
    func snappedY(x: Double, y: Double, free: Bool) -> Double {
        markRow(strip: nil, x: x, y: y, laneWidth: project.lanes.width > 0 ? project.lanes.width : 100, free: free)
    }

    /// A tick at `y` in its piece's own pixels (`strip` nil = the main image); `x` is the figure x clicked.
    @discardableResult
    func addTick(x: Double, y rawY: Double, strip: Int? = nil) -> UUID {
        let y = clampedY(rawY, strip: strip)
        let lane = geometry?.lane(atX: x, y: strip == nil ? y : crop.y0)
        let size = suggestedSize(forY: y, strip: strip)
        var newID = UUID()
        edit("Add Ladder Tick") { p in
            if let id = GelOps.addTick(&p, y: y, size: size, auto: true, lane: lane, gelCenterX: (crop.x0 + crop.x1) / 2, strip: strip) { newID = id }
            if let pr = preset, p.ladder?.name == nil {
                p.ladder?.name = pr.displayName; p.ladder?.unit = pr.unit
                if p.ladder?.sizes == nil {
                    let sys = pr.system(named: UserDefaults.standard.string(forKey: "lastGelSystem")) ?? pr.systems.first
                    p.ladder?.sizes = sys?.sizes ?? pr.sizes
                    p.ladder?.system = sys?.name
                }
            }
        }
        return newID
    }

    /// A size the user chose, so it's no longer a guess. Something that isn't a size (zero, negative, not a number) is no size.
    func setTick(_ id: UUID, size: Double?, ignore: Bool? = nil) {
        let size = size.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
        edit("Set Band Size") { p in
            guard let i = p.ladder?.bands.firstIndex(where: { $0.id == id }) else { return }
            p.ladder!.bands[i].size = size
            p.ladder!.bands[i].auto = false
            if let ignore {
                p.ladder!.bands[i].ignore = ignore
                if ignore { p.ladder!.bands[i].size = nil }
            }
        }
    }

    func confirmTicks() {
        edit("Confirm Band Sizes") { p in
            guard p.ladder != nil else { return }
            for i in p.ladder!.bands.indices { p.ladder!.bands[i].auto = false }
        }
    }

    /// The ladder's own size list (editable); in a fresh project, the preset's sizes for the gel system used last.
    var ladderSizes: [Double] {
        if let s = project.ladder?.sizes { return s }
        guard let pr = preset else { return [] }
        let key = project.ladder?.system ?? UserDefaults.standard.string(forKey: "lastGelSystem")
        return (pr.system(named: key) ?? pr.systems.first)?.sizes ?? pr.sizes
    }

    /// The preset with the size list this window shows (the gel system chosen), for the GelOps calls that take a preset.
    private var presetWithSizes: LadderPreset? {
        guard var pr = preset else { return nil }
        pr.sizes = ladderSizes
        return pr
    }

    /// The size a new tick at `y` (in its piece) would get: rank from the top in the ladder's list, through the gels that
    /// carry one ladder on from gel to gel, ticks hidden by a crop left out. A guess.
    func suggestedSize(forY y: Double, strip: Int? = nil) -> Double? {
        GelOps.suggestedSize(project, forY: y, strip: strip, preset: presetWithSizes)
    }

    func setLadderSizes(_ text: String) {
        let sizes = GelOps.parseSizes(text)
        edit("Edit Ladder Sizes") { p in
            if p.ladder == nil { p.ladder = Ladder(unit: preset?.unit ?? "kDa") }
            p.ladder!.sizes = sizes.isEmpty ? nil : sizes
            if let pr = preset, sizes != pr.sizes { p.ladder!.name = "Custom (from \(pr.displayName))" }
        }
    }

    /// Switches the size list to a preset's (its first gel system when it has several). Existing ticks keep their
    /// sizes until you assign again.
    func choosePreset(_ id: String) {
        presetID = id
        UserDefaults.standard.set(id, forKey: "lastLadderPreset")
        guard let pr = preset else { return }
        let lastSystem = UserDefaults.standard.string(forKey: "lastGelSystem")
        edit("Choose Ladder") { p in
            if p.ladder == nil { p.ladder = Ladder() }
            p.ladder!.name = pr.displayName
            p.ladder!.unit = pr.unit
            let sys = pr.system(named: p.ladder!.system) ?? pr.system(named: lastSystem) ?? pr.systems.first
            p.ladder!.sizes = sys?.sizes ?? pr.sizes
            p.ladder!.system = sys?.name
        }
    }

    /// The gel system the ladder's sizes are for, if the preset has any.
    var system: LadderSystem? { preset?.system(named: project.ladder?.system) }

    /// Apparent sizes for another gel/buffer. Ticks are relabelled band for band.
    func chooseSystem(_ id: String) {
        guard let pr = preset, let sys = pr.systems.first(where: { $0.id == id }) else { return }
        UserDefaults.standard.set(sys.name, forKey: "lastGelSystem")
        edit("Gel & Buffer") { p in GelOps.applySystem(&p, preset: pr, system: sys) }
    }

    /// Guesses sizes top-down from the ladder's list (each marked auto until confirmed).
    func assignTopDown() {
        let sizes = ladderSizes
        edit("Assign Sizes Top-Down") { p in p.assignLadder(sizes: sizes) }
    }

    /// Gives the chosen gel its own ladder (its sizes start again from the top of the list), or has it carry on from the
    /// gel above again. When that changes how the gels are grouped, the sizes are assigned top-down again, as guesses.
    func setOwnLadder(_ own: Bool) {
        let k = activeStrip
        edit(own ? "Own Ladder" : "Ladder From Gel Above") { p in
            GelOps.setOwnLadder(&p, strip: k, own, preset: presetWithSizes)
        }
    }

    func saveCustomLadder(name: String) {
        let sizes = ladderSizes
        guard !sizes.isEmpty, !name.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        var mine = LadderLibrary.loadUser()
        let id = "user-" + name.lowercased().map { $0.isLetter || $0.isNumber ? $0 : "-" }.reduce("") { $0 + String($1) }
        mine.removeAll { $0.id == id }
        mine.append(LadderPreset(id: id, name: name, vendor: "Mine", catalog: "", unit: project.ladder?.unit ?? "kDa",
                                 sizes: sizes, notes: "Saved from a GelScribe project"))
        do {
            try LadderLibrary.saveUser(mine)
            presetID = id
            edit("Name Ladder") { p in p.ladder?.name = name }
        } catch { problem = Problem(title: "Can't save the ladder", message: error.localizedDescription) }
    }

    // text sizes
    func setSize(_ v: Double, for kind: TextKind) { edit("Text Size") { $0.style.setSize(v, for: kind) } }
    func setSize(_ v: Double, forLabel role: FigureRole) { edit("Label Size") { $0.style.setSize(v, forLabel: role) } }
    func resetSize(forLabel role: FigureRole) {
        guard let k = role.sizeKey else { return }
        edit("Label Size") { $0.style.textSizes[k] = nil }
    }
    func scaleAllText(by delta: Double) { edit(delta > 0 ? "Bigger Text" : "Smaller Text") { $0.style.scaleAll(by: delta) } }

    /// ⌘⇧= / ⌘⇧−: the selected label, or everything when nothing is selected.
    func bumpText(_ delta: Double) {
        if case .text(let role)? = selection {
            setSize(project.style.size(for: role) + delta, forLabel: role)
        } else {
            scaleAllText(by: delta)
        }
    }

    func moveTick(_ id: UUID, y: Double) {
        guard let band = project.ladder?.bands.first(where: { $0.id == id }) else { return }
        let y = clampedY(y, strip: band.strip)
        live("Move Ladder Tick") { p in
            guard let i = p.ladder?.bands.firstIndex(where: { $0.id == id }) else { return }
            p.ladder!.bands[i].y = y
        }
    }

    /// Live, while a tick is dragged to figure row `fy`, snapping at figure column `x`: it stays in its own piece.
    func dragTick(_ id: UUID, x: Double, figureY fy: Double, free: Bool) {
        guard let b = project.ladder?.bands.first(where: { $0.id == id }) else { return }
        guard let k = b.strip else { moveTick(id, y: snappedY(x: x, y: fy, free: free)); return }
        guard let piece = stack.piece(strip: k) else { return }
        moveTick(id, y: snapped(in: piece, x: x, figureY: fy, free: free))
    }

    func deleteTick(_ id: UUID) {
        edit("Delete Ladder Tick") { p in p.ladder?.bands.removeAll { $0.id == id } }
        if selection == .tick(id) { selection = nil }
    }

    /// Puts the unit label ("kDa") on row `y` of gel `strip` (nil = the one with the lanes), in that gel's own pixels, or
    /// back above the gel with nil. The label goes with its gel.
    func setUnitY(_ y: Double?, strip: Int? = nil) {
        edit(y == nil ? "Automatic Unit Label" : "Place Unit Label") { p in
            if p.ladder == nil, y != nil { p.ladder = Ladder(unit: preset?.unit ?? "kDa") }
            GelOps.setUnitY(&p, y: y, strip: strip)
        }
    }

    /// The gel under figure row `fy`, and that row in its own pixels (kept inside the rows it shows).
    private func gelRow(atFigureY fy: Double) -> (strip: Int?, y: Double)? {
        guard let piece = stack.piece(atFigureY: fy) else { return nil }
        return (piece.strip, clampedY(piece.toPiece(x: 0, y: fy).y, strip: piece.strip).rounded())
    }

    /// A click at figure row `fy` places the unit label on the gel under it.
    func placeUnit(atFigureY fy: Double) {
        guard let at = gelRow(atFigureY: fy) else { return }
        setUnitY(at.y, strip: at.strip)
    }

    /// Live, during a drag of the unit label to figure row `fy`: it goes to the gel under the pointer.
    func moveUnit(toFigureY fy: Double) {
        guard let at = gelRow(atFigureY: fy) else { return }
        live("Move Unit Label") { p in
            if p.ladder == nil { p.ladder = Ladder() }
            GelOps.setUnitY(&p, y: at.y, strip: at.strip)
        }
    }

    func applyPresetToTicks() {
        guard let preset else { return }
        edit("Apply \(preset.name)") { p in GelOps.applyPreset(&p, preset) }
    }

    // names
    /// A name at `y` in its piece's own pixels (`strip` nil = the main image).
    @discardableResult
    func addName(y: Double, text: String = "", strip: Int? = nil) -> UUID {
        let side: LadderSide = project.ladder?.side == .right ? .left : .right
        let a = BandAnnotation(y: clampedY(y, strip: strip), text: text, marker: .arrow, side: side, strip: strip)
        edit("Add Band Name") { p in p.annotations.append(a) }
        return a.id
    }

    func updateName(_ id: UUID, _ change: (inout BandAnnotation) -> Void) {
        edit("Edit Band Name") { p in
            guard let i = p.annotations.firstIndex(where: { $0.id == id }) else { return }
            change(&p.annotations[i])
        }
    }

    /// Adds a finished name to the recent list (called on commit, never per keystroke).
    func rememberName(of id: UUID) {
        if let t = project.annotations.first(where: { $0.id == id })?.text.trimmingCharacters(in: .whitespaces), !t.isEmpty {
            remember(name: t)
        }
    }

    func moveName(_ id: UUID, y: Double) {
        guard let a = project.annotations.first(where: { $0.id == id }) else { return }
        let y = clampedY(y, strip: a.strip)
        live("Move Band Name") { p in
            guard let i = p.annotations.firstIndex(where: { $0.id == id }) else { return }
            p.annotations[i].y = y
        }
    }

    /// Live, while a name is dragged to figure row `fy`, snapping at figure column `x`: it stays in its own piece.
    func dragName(_ id: UUID, x: Double, figureY fy: Double, free: Bool) {
        guard let a = project.annotations.first(where: { $0.id == id }) else { return }
        guard let k = a.strip else { moveName(id, y: snappedY(x: x, y: fy, free: free)); return }
        guard let piece = stack.piece(strip: k) else { return }
        moveName(id, y: snapped(in: piece, x: x, figureY: fy, free: free))
    }

    func deleteName(_ id: UUID) {
        edit("Delete Band Name") { p in
            guard let k = p.annotations.firstIndex(where: { $0.id == id }) else { return }
            GelOps.removeAnnotation(&p, at: k)   // single-name sizes are keyed by position: the names after it keep their own
        }
        if selection == .name(id) { selection = nil }
    }

    /// Takes a name off the recent list (a typo, a protein you're done with).
    func forget(name: String) {
        recentNames.removeAll { $0 == name }
        UserDefaults.standard.set(recentNames, forKey: "recentNames")
    }

    private func remember(name: String) {
        // a finished name replaces any partial versions of it
        recentNames.removeAll { $0 == name || (name.hasPrefix($0) && $0.count < name.count) }
        recentNames.insert(name, at: 0)
        recentNames = Array(recentNames.prefix(10))
        UserDefaults.standard.set(recentNames, forKey: "recentNames")
    }

    // rotation & fill (not strict: rotating resamples the gel)
    /// A straighten waiting for the user to agree to turning Strict off.
    var pendingStraighten: Double?

    func setRotation(_ degrees: Double) {
        let d = min(max(degrees, -45), 45)
        guard let size = gelSize(activeStrip) else { return }   // a gel that can't be read has no picture to turn
        if let k = activeStrip {
            edit("Rotate Gel") { p in GelOps.setStripRotation(&p, strip: k, degrees: d, width: size.width, height: size.height) }
            return
        }
        edit("Rotate") { p in GelOps.setRotation(&p, degrees: d, imageWidth: size.width, imageHeight: size.height) }
    }

    /// Whether the chosen gel (the one on view, in a gel view) keeps its original pixels.
    var activeStrict: Bool { project.isStrict(gel: activeStrip) }

    /// How many of the gels keep their original pixels, for the toolbar's badge: all, none, or some.
    enum PixelsKept { case all, none, some }
    var pixelsKept: PixelsKept {
        let each = [project.isStrict(gel: nil)] + project.strips.indices.map { project.isStrict(gel: $0 + 1) }
        return each.allSatisfy { $0 } ? .all : each.contains(true) ? .some : .none
    }
    /// Some gel keeps its original pixels (so resampling the export, or anything else that changes them, asks first).
    var anyKeepsOriginal: Bool { pixelsKept != .none }

    /// Keep original pixels on or off for the chosen gel (each gel has its own). The marks of a gel that can't be read (no
    /// size known) stay where they are when it changes.
    func setStrict(_ on: Bool) { setStrict(on, gel: activeStrip) }

    func setStrict(_ on: Bool, gel k: Int?) {
        let sizes = stripSizeList
        edit(on ? "Keep Original Pixels" : "Adjust Pixels") { p in
            // each gel has its own switch: the gels of an older project that follow the lanes gel keep what they were doing
            if k == nil { for i in p.strips.indices where p.strips[i].strict == nil { p.strips[i].strict = p.strict } }
            GelOps.setStrict(&p, on, gel: k, imageWidth: imageWidth, imageHeight: imageHeight, stripSizes: sizes)
        }
    }

    /// The line between stacked gels: black, white or a color.
    func setSeparatorColor(_ color: SeparatorColor) {
        guard project.separatorColor != color else { return }
        edit("Line Between Gels") { $0.separatorColor = color }
    }

    func setSeparatorWhite(_ white: Bool) { setSeparatorColor(white ? .white : .black) }

    /// How thick the line between stacked gels is, in points (0.25 to 10); nil goes back to the thickness of the figure's other lines,
    /// which it then follows. Something that isn't a number changes nothing.
    func setSeparatorWidth(_ pt: Double?) {
        var width: Double?
        if let pt {
            guard pt.isFinite else { return }
            width = min(max(pt, GelProject.separatorWidths.lowerBound), GelProject.separatorWidths.upperBound)
        }
        guard project.separatorWidth != width else { return }
        edit("Line Thickness") { $0.separatorWidth = width }
    }

    /// Levels the line a→b (image pixels). On a gel that keeps its original pixels this first asks to turn that off.
    func straighten(from a: CGPoint, to b: CGPoint) {
        guard hypot(b.x - a.x, b.y - a.y) > 20 else { return }
        let delta = GelOps.levelingAngle(from: (Double(a.x), Double(a.y)), to: (Double(b.x), Double(b.y)))
        guard abs(delta) >= 0.01 else { return }
        if activeStrict { pendingStraighten = delta; return }
        setRotation(activeRotation + delta)
    }

    func confirmStraighten() {
        guard let d = pendingStraighten else { return }
        pendingStraighten = nil
        let k = activeStrip
        guard let size = gelSize(k) else { return }
        let sizes = stripSizeList
        edit("Straighten") { p in
            GelOps.setStrict(&p, false, gel: k, imageWidth: imageWidth, imageHeight: imageHeight, stripSizes: sizes)
            if let k {
                GelOps.setStripRotation(&p, strip: k, degrees: p.strips[k - 1].rotateDeg + d, width: size.width, height: size.height)
            } else {
                GelOps.setRotation(&p, degrees: p.rotateDeg + d, imageWidth: size.width, imageHeight: size.height)
            }
        }
    }

    // MARK: brightness & contrast (ImageJ's display range: on screen only while Strict is on)

    /// How the active piece's file stores its values, so the range can be shown in its own numbers.
    var valueScale: ValueScale { activeWorking?.source.scale ?? ValueScale(maxValue: 255) }
    var imageJRange: ClosedRange<Double>? { activeWorking?.source.imageJRange }

    @ObservationIgnored private var statsKey: String?
    @ObservationIgnored private var statsCache: GelStats?
    /// The active piece's values inside what the figure shows of it, kept until its pixels or crop change.
    var gelStats: GelStats? {
        guard let w = activeWorking else { return nil }
        let c = activeStripRect ?? crop
        let pieceKey = activeStrip.map { "\($0)|\(stripCache[project.strips[$0 - 1].image]?.key ?? 0)" } ?? "main|\(imageKey ?? 0)"
        let key = "\(pieceKey)|\(c.x0),\(c.y0),\(c.x1),\(c.y1)"
        if key != statsKey { statsCache = w.gelStats(crop: c); statsKey = key }
        return statsCache
    }

    /// "5–503 of 65535"
    var displayRangeText: String {
        let s = valueScale, r = activeDisplay.range(in: s)
        return "\(s.format(r.min))–\(s.format(r.max)) of \(s.format(s.maxValue))"
    }

    /// One brightness & contrast change. `live` follows a slider drag on screen; `endContrastChange()` then makes
    /// the drag one undo step.
    func changeContrast(live: Bool = false, _ change: (inout DisplaySettings) -> Void) {
        let k = activeStrip
        func apply(_ p: inout GelProject) {
            if let k { change(&p.strips[k - 1].display) } else { change(&p.display); p.viewEnhance = false }
        }
        if live { self.live("Brightness & Contrast", apply) } else { edit("Brightness & Contrast", apply) }
    }

    func endContrastChange() { endGesture("Brightness & Contrast") }

    /// The darkest 0.1% of the gel to black and the brightest 0.1% to white.
    func autoContrast() {
        guard let s = gelStats else { return }
        changeContrast { $0.black = s.auto.lowerBound; $0.white = s.auto.upperBound }
    }

    /// As ImageJ's Reset: a 16-bit image's darkest to brightest value, the full scale for 8-bit.
    func resetContrast() {
        guard let s = gelStats else { return }
        let wide = (activeWorking?.source.bitsPerComponent ?? 8) > 8
        changeContrast { d in
            d.black = wide ? s.range.lowerBound : 0
            d.white = wide ? s.range.upperBound : 1
            d.gamma = 1
        }
    }

    func useImageJRange() {
        guard let r = imageJRange else { return }
        let s = valueScale
        changeContrast { $0.setRange(min: r.lowerBound, max: r.upperBound, in: s) }
    }

    /// Brightness & Contrast in the inspector (palette button, Tools menu).
    func showBrightnessContrast() {
        inspectorVisible = true
        inspectorTab = .figure
        revealContrast += 1
    }

    func requestContrastForExport() {
        if activeStrict { pendingContrastExport = true }
    }

    /// Exports use brightness & contrast from now on, like ImageJ's Apply: Keep original pixels goes off for the chosen gel,
    /// the file records it.
    func applyContrastForExport() {
        pendingContrastExport = false
        setStrict(false)
    }

    func setFill(_ mode: FillMode, value: Double? = nil) {
        edit("Fill") { p in
            p.fillMode = mode
            if let value { p.fillValue = min(max(value, 0), 1) }
        }
    }


    // crop
    func liveCrop(_ r: PixelRect) {
        live("Crop") { p in p.crop = r.normalized(width: imageWidth, height: imageHeight); sync(&p) }
    }

    func resetCrop() {
        if let k = activeStrip {
            edit("Reset Gel Crop") { p in
                p.strips[k - 1].top = nil; p.strips[k - 1].bottom = nil; p.strips[k - 1].left = nil; p.strips[k - 1].right = nil
            }
            return
        }
        edit("Reset Crop") { p in p.crop = nil; sync(&p) }
    }

    // labels
    @ObservationIgnored private var typingQuickLabels = false
    @ObservationIgnored private var quickPause: Task<Void, Never>?

    /// Typing in Quick labels: the lanes follow every keystroke, and each pause (or leaving the field) is one undo
    /// step. What's typed is the whole truth, row titles included.
    func quickLabelsTyped() {
        typingQuickLabels = true
        live("Set Lane Labels") { p in
            let result = GelOps.applyQuickLabels(&p, text: quickLabels, keepTitles: false)
            if result.error == nil {   // a text that is refused (nested too deep) changes nothing
                p.style.textSizes = p.style.textSizes.filter { !$0.key.hasPrefix("lane.") && !$0.key.hasPrefix("group.") && !$0.key.hasPrefix("rowname.") }
            }
        }
        lastError = nil   // warnings wait for a pause: half-typed braces aren't mistakes
        quickPause?.cancel()
        quickPause = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            self?.finishQuickLabels(normalize: false)
        }
    }

    /// Ends a typing run: one undo step and any warnings; `normalize` (leaving the field) shows the text as the
    /// labels now read.
    func finishQuickLabels(normalize: Bool = true) {
        quickPause?.cancel()
        quickPause = nil
        if typingQuickLabels {
            typingQuickLabels = false
            endGesture("Set Lane Labels")
            var probe = project
            lastError = GelOps.applyQuickLabels(&probe, text: quickLabels, keepTitles: false).warnings.first
        }
        if normalize { quickLabels = laneLabelShorthand }
    }

    func applyQuickLabels() {
        var result: QuickLabels.Result?
        edit("Set Lane Labels") { p in
            result = GelOps.applyQuickLabels(&p, text: quickLabels)
            if result?.error == nil {   // a text that is refused (nested too deep) changes nothing
                p.style.textSizes = p.style.textSizes.filter { !$0.key.hasPrefix("lane.") && !$0.key.hasPrefix("group.") && !$0.key.hasPrefix("rowname.") }
            }
        }
        if let error = result?.error {
            problem = Problem(title: "Can't use these labels", message: error)
            lastError = nil
        } else {
            lastError = result?.warnings.first
        }
        quickLabels = laneLabelShorthand
    }

    func setText(_ role: FigureRole, _ value: String) {
        edit("Edit Label") { p in
            switch role {
            case .title: p.title = value
            case .rowName(let r): if r < p.rows.count { p.rows[r].name = value }
            case .laneLabel(let r, let lane):
                guard r < p.rows.count else { return }
                if p.rows[r].labels.count < lane { p.rows[r].labels += Array(repeating: "", count: lane - p.rows[r].labels.count) }
                p.rows[r].labels[lane - 1] = value
            case .groupLabel(let r, let g): if r < p.rows.count, g < p.rows[r].groups.count { p.rows[r].groups[g].text = value }
            case .ladderLabel(let b):
                if let b2 = p.ladder?.bands.indices, b2.contains(b) { p.ladder!.bands[b].size = Double(value.replacingOccurrences(of: ",", with: ".")) }
            case .ladderUnit: p.ladder?.unit = value
            case .annotation(let i): if i < p.annotations.count { p.annotations[i].text = value }
            }
        }
    }

    // label rows and groups (the "0 / 125 …" row over the L / P row)

    func addRow(_ kind: RowKind) {
        edit(kind == .groups ? "Add Group Row" : "Add Lane Row") { p in
            switch kind {
            case .lanes:
                // a new row stands at the figure's one label angle
                let row = LabelRow(type: .lanes, labels: Array(repeating: "", count: p.laneCount), rotation: p.labelAngle)
                // the first lane row goes right above the gel; more go on top
                if p.rows.contains(where: { $0.type == .lanes }) { p.rows.append(row) } else { p.rows.insert(row, at: 0) }
            case .groups:
                p.rows.append(LabelRow(type: .groups, groups: []))
            }
        }
    }

    func deleteRow(_ r: Int) {
        edit("Delete Row") { p in
            guard p.rows.indices.contains(r) else { return }
            p.rows.remove(at: r)
            // single-label sizes are keyed by row: drop this row's, shift the ones above it down
            var out: [String: Double] = [:]
            for (key, v) in p.style.textSizes {
                let parts = key.split(separator: ".")
                // the count first: a damaged key like "" or "." has no parts at all
                guard parts.count >= 2, ["lane", "group", "rowname"].contains(String(parts[0])), let row = Int(parts[1]) else { out[key] = v; continue }
                if row == r { continue }
                var q = parts.map(String.init)
                q[1] = String(row > r ? row - 1 : row)
                out[q.joined(separator: ".")] = v
            }
            p.style.textSizes = out
        }
    }

    func addGroup(row r: Int) {
        edit("Add Group") { p in
            guard p.rows.indices.contains(r) else { return }
            let n = max(1, p.laneCount)
            let first = min((p.rows[r].groups.map(\.last).max() ?? 0) + 1, n)
            p.rows[r].groups.append(LabelGroup(text: "", lanes: Array(first...min(first + 1, n))))
        }
    }

    /// Text and span of one group; the span is clamped to the lanes and kept in order.
    func updateGroup(row r: Int, group g: Int, text: String? = nil, first: Int? = nil, last: Int? = nil) {
        edit("Edit Group") { p in
            guard p.rows.indices.contains(r), p.rows[r].groups.indices.contains(g) else { return }
            var grp = p.rows[r].groups[g]
            if let text { grp.text = text }
            let n = max(1, p.laneCount)
            var a = min(max(first ?? grp.first, 1), n), b = min(max(last ?? grp.last, 1), n)
            if a > b { if first != nil { b = a } else { a = b } }
            grp.lanes = Array(a...b)
            p.rows[r].groups[g] = grp
        }
    }

    func deleteGroup(row r: Int, group g: Int) {
        edit("Delete Group") { p in
            guard p.rows.indices.contains(r), p.rows[r].groups.indices.contains(g) else { return }
            p.rows[r].groups.remove(at: g)
            var out: [String: Double] = [:]
            for (key, v) in p.style.textSizes {
                let parts = key.split(separator: ".").map(String.init)
                guard parts.count == 3, parts[0] == "group", Int(parts[1]) == r, let j = Int(parts[2]) else { out[key] = v; continue }
                if j == g { continue }
                out["group.\(r).\(j > g ? j - 1 : j)"] = v
            }
            p.style.textSizes = out
        }
    }

    func setUnderline(row r: Int, _ on: Bool) {
        edit("Underline") { p in if p.rows.indices.contains(r) { p.rows[r].underline = on } }
    }

    /// Stands the group labels of row `r` at `degrees` (0 flat, 90 straight up, any angle to 360). Each group row has its own.
    func setRowAngle(row r: Int, _ degrees: Double) {
        edit("Group Label Angle") { p in GelOps.setRowAngle(&p, row: r, degrees) }
    }

    /// Label for a lane in the row nearest the gel, creating that row if the project has none.
    func setLaneLabel(lane: Int, _ value: String) {
        edit("Edit Lane Label") { p in
            if !p.rows.contains(where: { $0.type == .lanes }) {
                // the per-lane row sits right above the gel, under any group rows
                p.rows.insert(LabelRow(type: .lanes, labels: Array(repeating: "", count: p.laneCount)), at: 0)
            }
            guard let r = p.rows.firstIndex(where: { $0.type == .lanes }) else { return }
            if p.rows[r].labels.count < lane { p.rows[r].labels += Array(repeating: "", count: lane - p.rows[r].labels.count) }
            p.rows[r].labels[lane - 1] = value
        }
    }

    func text(for role: FigureRole) -> String {
        let p = project
        switch role {
        case .title: return p.title ?? ""
        case .rowName(let r): return r < p.rows.count ? (p.rows[r].name ?? "") : ""
        case .laneLabel(let r, let lane): return r < p.rows.count && lane <= p.rows[r].labels.count ? p.rows[r].labels[lane - 1] : ""
        case .groupLabel(let r, let g): return r < p.rows.count && g < p.rows[r].groups.count ? p.rows[r].groups[g].text : ""
        case .ladderLabel(let b): return (p.ladder?.bands.indices.contains(b) ?? false) ? p.ladder!.bands[b].size.map(FigureLayoutEngine.formatSize) ?? "" : ""
        case .ladderUnit: return p.ladder?.unit ?? "kDa"
        case .annotation(let i): return i < p.annotations.count ? p.annotations[i].text : ""
        }
    }

    // MARK: lane labels as one line of shorthand

    /// "µM: Ladder|0{L|P}|…" for the current project.
    var laneLabelShorthand: String { QuickLabels.shorthand(project) }

    /// Whether there are lane labels to turn: a row of them.
    var hasLaneLabels: Bool { project.rows.contains { $0.type == .lanes } }

    /// Stands the lane labels at `degrees` (0 flat, 90 straight up, clamped to that), the one angle of every row of them.
    /// One undo step; nothing changes without lane labels.
    func setLabelAngle(_ degrees: Double) {
        edit("Label Angle") { p in GelOps.setLabelAngle(&p, degrees) }
    }

    func copyLaneLabels() {
        let text = laneLabelShorthand
        guard !text.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    /// Takes lane labels from the clipboard: shorthand text, or the label rows of copied labels.
    func pasteLaneLabels() {
        let pb = NSPasteboard.general
        if let data = pb.data(forType: Self.schemeType), let scheme = try? LabelScheme.decode(data) {
            edit("Paste Lane Labels") { p in
                p.rows = scheme.rows
                p.style.textSizes = p.style.textSizes.filter { !$0.key.hasPrefix("lane.") && !$0.key.hasPrefix("group.") && !$0.key.hasPrefix("rowname.") }
            }
            quickLabels = laneLabelShorthand
        } else if let text = pb.string(forType: .string), !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            quickLabels = text.trimmingCharacters(in: .whitespacesAndNewlines)
            applyQuickLabels()
        } else {
            problem = Problem(title: "Nothing to paste", message: "Copy lane labels from a gel first.")
        }
    }

    // MARK: reuse the naming scheme on another gel

    static let schemeType = NSPasteboard.PasteboardType(LabelScheme.pasteboardType)

    func copyScheme() {
        guard let data = try? LabelScheme(from: project, positions: true).encoded() else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setData(data, forType: Self.schemeType)
        pb.setString(String(decoding: data, as: UTF8.self), forType: .string)
    }

    var canPasteScheme: Bool { NSPasteboard.general.data(forType: Self.schemeType) != nil }

    /// Pastes labels, titles, names, ladder settings and type; with `positions`, also dividers, crop, ticks and the unit
    /// label's place. Only the gel with the lanes' marks travel (see `LabelScheme`).
    func pasteScheme(positions: Bool) {
        guard let data = NSPasteboard.general.data(forType: Self.schemeType),
              var scheme = try? LabelScheme.decode(data) else {
            problem = Problem(title: "Nothing to paste", message: "Copy labels from a gel first.")
            return
        }
        if !positions { scheme.lanes = nil; scheme.crop = nil; scheme.ladder?.bands = []; scheme.ladder?.unitY = nil; scheme.ladder?.unitStrip = nil }
        edit(positions ? "Paste Labels and Positions" : "Paste Labels") { p in
            scheme.apply(to: &p, imageWidth: imageWidth, imageHeight: imageHeight)
        }
        if let name = project.ladder?.name, let pr = LadderLibrary.all().first(where: { $0.displayName == name }) { presetID = pr.id }
    }

    /// A new project for another image carrying this one's naming scheme (no image-specific positions).
    func packageForNewGel(imageURL: URL) throws -> GelPackage {
        var pkg = try GelPackage.create(imageURL: imageURL)
        let src = try SourceImage(data: pkg.imageData)
        LabelScheme(from: project, positions: false).apply(to: &pkg.project, imageWidth: src.width, imageHeight: src.height)
        return pkg
    }

    // MARK: export

    /// Resolution of a native PNG/TIFF (gel pixels 1:1), rounded.
    var nativeDPI: Int { layout.map { Int(FigureRenderer.nativeDPI($0).rounded()) } ?? 0 }

    /// Waiting for the user to agree that PNG/TIFF at this resolution resample the gel (a gel that keeps its original pixels).
    var pendingExportDPI: Double?

    /// The PNG/TIFF resolution when it resamples the gel; nil when exports are native.
    var resampledExportDPI: Double? { layout.flatMap { FigureRenderer.resampleDPI(project.style.exportDPI, $0) } }

    /// PNG/TIFF resolution: nil = native. Other values resample the gel, so a gel that keeps its original pixels asks first.
    func requestExportDPI(_ dpi: Double?) {
        guard let dpi, let l = layout, FigureRenderer.resampleDPI(dpi, l) != nil else { return setExportDPI(nil) }   // native
        if anyKeepsOriginal, resampledExportDPI != dpi { pendingExportDPI = dpi } else { setExportDPI(dpi) }
    }

    /// Whether exported files carry each gel's file name (the Export tab's checkbox). Undoable.
    func setExportFileNames(_ on: Bool) {
        edit(on ? "Include File Names" : "Leave Out File Names") { $0.exportFileNames = on }
    }

    func setExportDPI(_ dpi: Double?) {
        pendingExportDPI = nil
        edit(dpi == nil ? "Native Resolution" : "Export Resolution") { $0.style.exportDPI = dpi }
    }

    /// The whole figure, strips included, as it exports. A gel that can't be read is missing from it, and then the figure
    /// can't be exported (`unreadableGel`).
    var figure: StackedFigure? {
        guard let working else { return nil }
        return StackedFigure(project: project, main: working, strips: stripWorkingList)
    }

    var exportInfo: ExportInfo {
        let list = stripWorkingList
        return ExportInfo.for(project, sourceSHA256: source?.sha256, scale: source?.scale,
                              strips: list.map { (sha256: $0?.source.sha256, scale: $0?.source.scale) },
                              size: working.map { (width: $0.width, height: $0.height) }, stripSizes: stripSizeList,
                              convertedTo: working.flatMap { StripStack.conversion(main: $0, strips: list, project: project, stack: stack) })
    }

    /// Why the gels that keep their original pixels can't be exported untouched (they must be stored alike), if they can't.
    var strictProblem: String? {
        guard let w = working else { return nil }
        return StripStack.strictProblem(project: project, main: w.source.cgImage, strips: stripWorkingList.map { $0?.source.cgImage }) { gelName($0) }
    }

    /// `strictProblem` with the gel (its number in `project.strips`) it is said of, so it can be shown under that gel's switch.
    var strictProblemDetail: (gel: Int, text: String)? {
        guard let w = working else { return nil }
        return StripStack.strictProblemDetail(project: project, main: w.source.cgImage, strips: stripWorkingList.map { $0?.source.cgImage }) { gelName($0) }
            .map { ($0.strip, $0.message) }
    }

    /// Why the figure can't be exported at all, found before anything is made: a gel's image that can't be read, or Strict with gels
    /// that can't be stacked untouched.
    private var exportBlocker: String? {
        if let why = unreadableGel { return why }
        guard let fig = figure else { return "Nothing to export yet." }
        if let why = fig.unreadableGel { return why }
        if let problem = fig.strictProblem {
            return "The gels that keep their original pixels must be stored the same way, but \(problem). Turn off Keep original pixels for a gel to export."
        }
        return nil
    }

    /// The figure as `type`, or why it can't be made (`exportBlocker`, or a picture or file too large to make).
    private func figureData(_ type: UTType) -> (data: Data?, why: String?) {
        if let why = exportBlocker { return (nil, why) }
        guard let data = figure?.export(type) else { return (nil, StackedFigure.tooLargeMessage) }
        return (data, nil)
    }

    /// A gel whose image no longer matches the fingerprint taken when it was added: the figure shows a picture other than the
    /// one that was imported, so the user is asked before it leaves the app (copied or exported). "Export Anyway" goes ahead.
    struct PendingExport: Equatable {
        enum Action: Equatable { case copy, export(UTType, String) }
        var message: String
        var action: Action
    }
    var pendingChangedExport: PendingExport?

    /// "Warning: Gel N's image (FILE) has changed since it was added; its SHA-256 no longer matches." for each such gel.
    var changedImageWarnings: [String] { figure?.changedImageWarnings ?? [] }

    /// Sets the question up (true) when a gel's image changed. A problem that stops the export comes first: it is told instead.
    private func askAboutChangedImages(_ action: PendingExport.Action) -> Bool {
        guard exportBlocker == nil else { return false }
        let lines = changedImageWarnings
        guard !lines.isEmpty else { return false }
        pendingChangedExport = PendingExport(message: lines.joined(separator: "\n"), action: action)
        return true
    }

    func confirmChangedExport() {
        guard let pending = pendingChangedExport else { return }
        pendingChangedExport = nil
        Task {   // once the alert has gone, so a save panel doesn't open under it
            switch pending.action {
            case .copy: copyFigure(confirmed: true)
            case .export(let type, let name): export(type, suggestedName: name, confirmed: true)
            }
        }
    }

    /// The figure as `type`. When it can't be made, an alert says why (wherever the user is) and the result is nil.
    func exportData(_ type: UTType, doing action: String = "export") -> Data? {
        let made = figureData(type)
        if let why = made.why { problem = Problem(title: "Can't \(action)", message: why) }
        return made.data
    }

    func copyFigure(confirmed: Bool = false) {
        if !confirmed, askAboutChangedImages(.copy) { return }
        guard let pdf = exportData(.pdf, doing: "copy the figure") else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setData(pdf, forType: .pdf)
        if let png = figureData(.png).data { pb.setData(png, forType: .png) }
    }

    func export(_ type: UTType, suggestedName: String, confirmed: Bool = false) {
        if !confirmed, askAboutChangedImages(.export(type, suggestedName)) { return }
        guard let data = exportData(type) else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [type]
        panel.nameFieldStringValue = suggestedName
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try data.write(to: url, options: .atomic) } catch {
            problem = Problem(title: "Can't save the file", message: error.localizedDescription)
        }
    }
}

extension FigureLayout {
    /// The first text whose own box holds `point` (figure points), allowing `slack` around it. Text at an angle is tested
    /// against its rotated box (`FigureText.contains`), not the axis-aligned bounds around it, so a click or the pointer
    /// beside a slanted label, between two of them, isn't taken for one.
    func text(at point: CGPoint, slack: CGSize = .zero) -> FigureText? {
        texts.first { t in
            // the box lies inside the bounds, so beyond them (and the slack) is no hit: the cheap test first
            guard t.bounds.insetBy(dx: -slack.width, dy: -slack.height).contains(point) else { return false }
            if t.rotation == 0 { return true }   // flat text: its box is its bounds
            if t.contains(point) { return true }
            // a little forgiving, as the flat test is: a point just to either side of, or above or below, the box
            return [CGSize(width: slack.width, height: 0), CGSize(width: -slack.width, height: 0),
                    CGSize(width: 0, height: slack.height), CGSize(width: 0, height: -slack.height)]
                .contains { t.contains(CGPoint(x: point.x + $0.width, y: point.y + $0.height)) }
        }
    }
}

import Foundation
import GelKit
import GelMCP
import GelService
import UniformTypeIdentifiers

// gelscribe — headless GelScribe. Everything goes to stderr except requested output, so `mcp` mode stays clean.
// Exit status: 0 done, 1 failed, 2 a mistake in how the command was typed.

let usageText = """
usage:
  gelscribe new IMAGE [-o OUT.gelscribe]      make a project around an image (original copied byte-for-byte); never over an existing one
  gelscribe render PROJECT [-o STEM] [--formats pdf,png,tiff,svg] [--dpi N|native]   (other than native resamples the gel)
  gelscribe edit PROJECT [--dividers X,X,…] [--auto-lanes N] [--labels "µM: ladder|0{L|P}|50{L|P}|…"]
                [--row-name µM] [--preset ID] [--system GEL] [--ticks Y,Y,…] [--no-snap] [--name TEXT@Y[:arrow|tick|bracket|none]]…
                [--title T] [--crop X0,Y0,X1,Y1|fit]   with --gel N: that gel's own crop (columns and rows in its own pixels)
                [--strict on|off]   keep original pixels: for the gel with the lanes, or for gel N with --gel N (each gel has its own;
                                      a gel that doesn't is stretched, rotated and takes its brightness & contrast into exports)
                [--separator black|white|#RRGGBB]   the colour of the line between stacked gels (a gray figure takes its brightness)
                [--separator-width PT]   how thick that line is, 0.25 to 10 points (without it, as thick as the figure's lines)
                [--label-angle DEG]   stand the lane labels at an angle: 0 flat, 90 straight up, any angle to 360; other text stays flat
                [--group-angle DEG]   the same for every row of group labels (the labels over several lanes); underlines stay flat
                [--rotate DEG] [--fill background|white|0-255]   (rotation and fill need --strict off for that gel)
                [--scheme-from PROJECT [--with-positions]]      reuse another gel's labels, names, ladder, type
                [--turn 90|180|270]   (a lossless quarter or half turn, for a scan made the wrong way round)
                [--add-gel IMAGE]…    another gel (or piece of a cut membrane), stacked at the bottom with a line above; it
                                      starts with --strict off, so --align auto can stretch it into line
                [--remove-gel N] [--order N,N,…]   take gel N out; stack the gels in this order (numbers from the top)
                [--shift PX]          where the gel with the lanes sits sideways in the figure (whole pixels; its lane dividers, labels,
                                      ticks and names go with it, and no other gel moves); with --gel N, where gel N sits
                [--gel N [--rows Y0,Y1] [--scale S] [--align auto]]   gel N, counted from the top: its rows, and lining
                                      its lanes up wherever the gel with the lanes sits; --crop, --shift, --ticks, --name, --rotate,
                                      --turn and --strict then apply to it
                [--own-ladder on|off]   the gel's ladder sizes start again from the top instead of carrying on from the
                                      gel above (the gel with the lanes, or gel N with --gel N)
                [--file-names on|off]   whether exported files carry each gel's file name (off: the SHA-256 fingerprints stay)
  gelscribe detect IMAGE [--lanes N]          suggest lanes and ladder bands (JSON)
  gelscribe presets                           list ladder presets
  gelscribe mcp                               MCP server on stdin/stdout, working on project files
  gelscribe verify PROJECT                    check the images still match their recorded SHA-256, and can be read
  gelscribe help                              this text

Positions are image pixels from the top-left corner, x to the right and y down (in the turned and rotated image).

"""

func fail(_ msg: String) -> Never {
    FileHandle.standardError.write(Data("gelscribe: \(msg)\n".utf8))
    exit(1)
}

/// A mistake in how the command was typed: say so, show the usage, status 2.
func usageError(_ msg: String) -> Never {
    FileHandle.standardError.write(Data("gelscribe: \(msg)\n\n\(usageText)".utf8))
    exit(2)
}

func usage() -> Never {
    FileHandle.standardError.write(Data(usageText.utf8))
    exit(2)
}

func say(_ text: String) { FileHandle.standardError.write(Data("\(text)\n".utf8)) }
func warn(_ text: String) { say("warning: \(text)") }

// MARK: arguments

/// The words after the command. An option takes the next word as its value, even one that starts with - (`--rotate -2.5`),
/// and options can come before or after the file, in any order.
struct CLIArgs {
    var words: [String]
    init(_ words: [String]) { self.words = words }

    mutating func option(_ name: String) -> String? {
        guard let i = words.firstIndex(of: name) else { return nil }
        guard i + 1 < words.count else { usageError("\(name) needs a value") }
        let value = words[i + 1]
        words.removeSubrange(i...(i + 1))
        if words.contains(name) { usageError("\(name) is given more than once") }
        return value
    }

    mutating func options(_ name: String) -> [String] {
        var out: [String] = []
        while let i = words.firstIndex(of: name) {
            guard i + 1 < words.count else { usageError("\(name) needs a value") }
            out.append(words[i + 1])
            words.removeSubrange(i...(i + 1))
        }
        return out
    }

    mutating func flag(_ name: String) -> Bool {
        let found = words.contains(name)
        words.removeAll { $0 == name }
        return found
    }

    /// The one file the command works on, once its options are out.
    mutating func file(_ what: String) -> String {
        for w in words where w.hasPrefix("-") && w.count > 1 { usageError("unknown option \(w)") }
        guard let first = words.first else { usageError("which \(what)?") }
        if words.count > 1 { usageError("one \(what) at a time (also got \(words[1]))") }
        return first
    }

    func nothingElse() {
        for w in words where w.hasPrefix("-") && w.count > 1 { usageError("unknown option \(w)") }
        if let w = words.first { usageError("unexpected \(w)") }
    }
}

/// A finite number, or the one-line error.
func number(_ text: String, _ message: String) -> Double {
    guard let v = Double(text.trimmingCharacters(in: .whitespaces)), v.isFinite, abs(v) <= 1e9 else { fail(message) }
    return v
}

/// Numbers separated by commas (blank entries skipped).
func numbers(_ text: String, _ message: String) -> [Double] {
    text.split(separator: ",").filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.map { number(String($0), message) }
}

func whole(_ text: String, _ message: String) -> Int {
    guard let v = Int(text.trimmingCharacters(in: .whitespaces)), abs(v) <= 1_000_000_000 else { fail(message) }
    return v
}

func onOff(_ text: String, _ message: String) -> Bool {
    switch text.lowercased() {
    case "on": return true
    case "off": return false
    default: fail(message)
    }
}

/// A position or size in pixels is never beyond this, either way.
let farthest = 1_000_000.0

func requireFile(_ path: String, _ what: String) {
    guard FileManager.default.fileExists(atPath: path) else { fail("\(path): no such \(what)") }
}

/// TEXT@Y[:marker], split at the last @ so a name may contain one.
func parseName(_ text: String) -> (text: String, y: Double, marker: AnnotationMarker) {
    guard let at = text.lastIndex(of: "@") else { fail("--name wants TEXT@Y") }
    let rest = text[text.index(after: at)...].split(separator: ":")
    guard let first = rest.first else { fail("--name wants TEXT@Y") }
    let y = number(String(first), "--name wants TEXT@Y")
    var marker = AnnotationMarker.arrow
    if rest.count > 1 {
        guard let m = AnnotationMarker(rawValue: String(rest[1]).lowercased()) else {
            fail("--name: the marker is arrow, tick, bracket or none, not \(rest[1])")
        }
        marker = m
    }
    return (String(text[..<at]), y, marker)
}

// MARK: commands

func runNew(_ words: [String]) throws {
    var a = CLIArgs(words)
    let out = a.option("-o")
    let img = a.file("IMAGE")
    requireFile(img, "image")
    let url = URL(fileURLWithPath: img)
    let dest = URL(fileURLWithPath: out ?? url.deletingPathExtension().path + "." + GelPackage.fileExtension)
    // never over an existing project: it would lose its lanes, labels and ticks
    let fm = FileManager.default
    if fm.fileExists(atPath: dest.path) {
        var isDir: ObjCBool = false
        fm.fileExists(atPath: dest.path, isDirectory: &isDir)
        if !isDir.boolValue || fm.fileExists(atPath: dest.appendingPathComponent(GelPackage.projectFileName).path) {
            fail("\(dest.path) already exists; choose another name with -o")
        }
    }
    let pkg = try GelPackage.create(imageURL: url)
    try pkg.write(to: dest)
    print(dest.path)
}

func runRender(_ words: [String]) throws {
    var a = CLIArgs(words)
    let stem = a.option("-o")
    let formatsText = a.option("--formats")
    let dpiText = a.option("--dpi")
    let path = a.file("PROJECT")
    // every value is checked before anything is read or written
    var formats: [String] = []
    for f in (formatsText ?? "pdf,png,svg").split(separator: ",").map({ $0.trimmingCharacters(in: .whitespaces).lowercased() }) where !f.isEmpty {
        guard ["pdf", "png", "tiff", "tif", "svg"].contains(f) else { fail("unknown format \(f) (pdf, png, tiff or svg)") }
        if !formats.contains(f) { formats.append(f) }
    }
    guard !formats.isEmpty else { fail("--formats is empty") }
    var native = false
    var asked: Double?
    if let t = dpiText {
        if t.lowercased() == "native" { native = true } else {
            let v = number(t, "--dpi wants a number or native")
            guard (1...10_000).contains(v) else { fail("--dpi wants a number from 1 to 10000, or native") }
            asked = v
        }
    }
    requireFile(path, "project")
    let url = URL(fileURLWithPath: path)
    let pkg = try GelPackage.read(from: url)
    let work = WorkingImage(source: try pkg.decodeMain(), project: pkg.project)
    let fig = StackedFigure(project: pkg.project, main: work, strips: try StackedFigure.stripImages(pkg))
    if let problem = fig.strictProblem {
        fail("The gels that keep their original pixels must be stored the same way, but \(problem). Turn it off for a gel (edit --strict off --gel N) to export it.")
    }
    let base = stem.map { URL(fileURLWithPath: $0) } ?? url.deletingPathExtension().appendingPathExtension("figure")
    let targets = formats.map { base.appendingPathExtension($0) }
    // before anything is written: not into the project, and never over one of its original images
    let folder = GelPackage.isFolder(url) ? url.resolvingSymlinksInPath().path.lowercased() + "/" : nil
    let originals = [pkg.imageData] + pkg.project.strips.compactMap { pkg.stripImages[$0.image] }
    for dest in targets {
        let d = dest.resolvingSymlinksInPath()
        if let folder, d.path.lowercased().hasPrefix(folder) { fail("won't write \(dest.path) inside the project") }
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: d.path, isDirectory: &isDir) {
            if isDir.boolValue { fail("\(dest.path) is a folder") }
            if let existing = try? Data(contentsOf: d, options: .mappedIfSafe), originals.contains(existing) {
                fail("won't overwrite \(dest.path): it's an original image")
            }
        }
    }
    // a gel's image that no longer matches its fingerprint: the export goes ahead, the note starts with the same lines
    for line in fig.changedImageWarnings { say(line) }
    let layout = fig.layout
    guard let gel = fig.gel else { fail(StackedFigure.tooLargeMessage) }   // too large, or no drawing context: never blank space
    let info = fig.info()
    let dpi = FigureRenderer.resampleDPI(native ? nil : (asked ?? pkg.project.style.exportDPI), layout)
    let rasterInfo = fig.info(resampledDPI: dpi)
    if let dpi, formats.contains(where: { ["png", "tiff", "tif"].contains($0) }) {
        say("PNG/TIFF at \(Int(dpi)) dpi: the gel is resampled (native is \(Int(FigureRenderer.nativeDPI(layout).rounded())) dpi)")
    }
    for (f, dest) in zip(formats, targets) {
        let data: Data?
        switch f {
        case "pdf": data = FigureRenderer.pdf(layout, gel: gel, info: info)
        case "png": data = FigureRenderer.rasterData(layout, gel: gel, type: .png, info: rasterInfo, dpi: dpi)
        case "tiff", "tif": data = FigureRenderer.rasterData(layout, gel: gel, type: .tiff, info: rasterInfo, dpi: dpi)
        default: data = Data(FigureRenderer.svg(layout, gel: gel, info: info).utf8)
        }
        guard let data, !data.isEmpty else { fail(StackedFigure.tooLargeMessage) }
        try data.write(to: dest, options: .atomic)
        print(dest.path)
    }
}

func runEdit(_ words: [String]) throws {
    var a = CLIArgs(words)
    let dividersText = a.option("--dividers")
    let autoLanesText = a.option("--auto-lanes")
    let labelsText = a.option("--labels")
    let rowName = a.option("--row-name")
    let labelAngleText = a.option("--label-angle")
    let groupAngleText = a.option("--group-angle")
    let presetID = a.option("--preset")
    let systemKey = a.option("--system")
    let ticksText = a.option("--ticks")
    let titleText = a.option("--title")
    let cropText = a.option("--crop")
    let strictText = a.option("--strict")
    let separatorText = a.option("--separator")
    let separatorWidthText = a.option("--separator-width")
    let schemeFrom = a.option("--scheme-from")
    let withPositions = a.flag("--with-positions")
    let rotateText = a.option("--rotate")
    let fillText = a.option("--fill")
    let nameTexts = a.options("--name")
    let snap = !a.flag("--no-snap")
    let newGels = a.options("--add-gel")
    let removeText = a.option("--remove-gel")
    let orderText = a.option("--order")
    let gelText = a.option("--gel")
    let turnText = a.option("--turn")
    let rowsText = a.option("--rows")
    let shiftText = a.option("--shift")
    let scaleText = a.option("--scale")
    let alignText = a.option("--align")
    let ownLadderText = a.option("--own-ladder")
    let fileNamesText = a.option("--file-names")
    let path = a.file("PROJECT")
    if withPositions && schemeFrom == nil { usageError("--with-positions goes with --scheme-from") }

    // --- every value checked before the project is read or changed, so a mistake leaves it as it was
    let strictOn = strictText.map { onOff($0, "--strict wants on or off") }
    let separatorColor = separatorText.map { t -> SeparatorColor in
        guard let c = SeparatorColor(parsing: t) else { fail("--separator wants black, white or a color like #ff3300") }
        return c
    }
    let separatorWidth = separatorWidthText.map { t -> Double in
        let v = number(t, "--separator-width wants points from 0.25 to 10, e.g. --separator-width 2")
        guard GelProject.separatorWidths.contains(v) else { fail("--separator-width wants points from 0.25 to 10, e.g. --separator-width 2") }
        return v
    }
    let ownLadderOn = ownLadderText.map { onOff($0, "--own-ladder wants on or off") }
    let fileNamesOn = fileNamesText.map { onOff($0, "--file-names wants on or off") }
    let degrees = rotateText.map { t -> Double in
        let v = number(t, "--rotate wants degrees, e.g. --rotate -2.4")
        guard abs(v) <= 180 else { fail("--rotate wants degrees from -180 to 180, e.g. --rotate -2.4") }
        return v
    }
    var fillMode: FillMode?
    var fillLevel = 0.0
    if let t = fillText {
        switch t.lowercased() {
        case "background": fillMode = .background
        case "white": fillMode = .white
        default:
            guard let v = Double(t.trimmingCharacters(in: .whitespaces)), (0...255).contains(v) else { fail("--fill wants background, white or 0-255") }
            fillMode = .custom
            fillLevel = v / 255
        }
    }
    let laneCount = autoLanesText.map { t -> Int in
        let n = whole(t, "--auto-lanes wants the number of lanes")
        guard (2...4096).contains(n) else { fail("--auto-lanes wants 2 lanes or more") }
        return n
    }
    var cropBox: [Double]?
    var cropFit = false
    if let t = cropText {
        if t.lowercased() == "fit" { cropFit = true } else {
            let v = numbers(t, "--crop wants X0,Y0,X1,Y1 or fit")
            guard v.count == 4 else { fail("--crop wants X0,Y0,X1,Y1 or fit") }
            cropBox = v
        }
    }
    let labelAngle = labelAngleText.map { t -> Double in
        let v = number(t, "--label-angle wants an angle in degrees, e.g. --label-angle 45")
        guard v.isFinite else { fail("--label-angle wants an angle in degrees, e.g. --label-angle 45") }
        return v
    }
    let groupAngle = groupAngleText.map { t -> Double in
        let v = number(t, "--group-angle wants an angle in degrees, e.g. --group-angle 45")
        guard v.isFinite else { fail("--group-angle wants an angle in degrees, e.g. --group-angle 45") }
        return v
    }
    let dividerXs = dividersText.map { numbers($0, "--dividers wants x positions like 95,165,240") }
    let tickYs = ticksText.map { numbers($0, "--ticks wants rows like 60,110,170") } ?? []
    let preset = presetID.map { id -> LadderPreset in
        guard !id.trimmingCharacters(in: .whitespaces).isEmpty, let p = LadderLibrary.find(id) else {
            fail("unknown preset \(id); see `gelscribe presets`")
        }
        return p
    }
    let marks = nameTexts.map(parseName)
    let quarter = turnText.map { t -> Int in
        let d = whole(t, "--turn wants 90, 180 or 270")
        guard [90, 180, 270].contains(d) else { fail("--turn wants 90, 180 or 270") }
        return d / 90
    }
    let removeN = removeText.map { whole($0, "--remove-gel wants a gel number (1 is the top one)") }
    let gelN = gelText.map { whole($0, "--gel wants a gel number (1 is the top one)") }
    let order = orderText.map { t in
        t.split(separator: ",").filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            .map { whole(String($0), "--order wants gel numbers, e.g. 2,1") }
    }
    let rowsPair = rowsText.map { t -> [Double] in
        let v = numbers(t, "--rows wants Y0,Y1")
        guard v.count == 2 else { fail("--rows wants Y0,Y1") }
        return v
    }
    let shift = shiftText.map { t -> Double in
        let v = number(t, "--shift wants pixels")
        guard abs(v) <= farthest else { fail("--shift wants pixels") }
        return v
    }
    let stretch = scaleText.map { t -> Double in
        let v = number(t, "--scale wants a number from 0.5 to 2, e.g. 1.02")
        guard (0.5...2).contains(v) else { fail("--scale wants a number from 0.5 to 2, e.g. 1.02") }
        return v
    }
    if let t = alignText, t.lowercased() != "auto" { fail("--align wants auto") }
    let align = alignText != nil
    for f in newGels { requireFile(f, "image") }
    if let from = schemeFrom { requireFile(from, "project") }

    // --- the project
    requireFile(path, "project")
    let url = URL(fileURLWithPath: path)
    let isFolder = GelPackage.isFolder(url)
    if !newGels.isEmpty && !isFolder { fail("Gels can only be added to a .gelscribe project.") }
    var pkg = try GelPackage.read(from: url)
    for f in newGels {
        let u = URL(fileURLWithPath: f)
        try pkg.addStrip(imageData: Data(contentsOf: u), imageName: u.lastPathComponent)
    }
    /// Gel `n`, counted from the top, as a strip number; nil = the gel with the lanes.
    func gel(_ n: Int) -> Int? {
        let stack = pkg.project.stackOrder
        guard n >= 1, n <= stack.count else { fail("there's no gel \(n): the figure has \(stack.count)") }
        return stack[n - 1]
    }
    var removedImage: String?
    if let n = removeN {
        guard let k = gel(n) else { fail("gel \(n) has the lanes every gel uses, so it can't be taken out") }
        removedImage = pkg.removeStrip(k)   // nil when another gel still uses that file name
    }
    if let order {
        let n = pkg.project.stackOrder.count
        guard order.count == n, Set(order) == Set(1...n) else { fail("--order wants each gel number from 1 to \(n) once, top first") }
        GelOps.reorder(&pkg.project, order.map { $0 - 1 })
    }
    let strip = gelN.flatMap(gel)
    if cropFit, let n = gelN, strip != nil { fail("--crop fit is for the gel with the lanes; give gel \(n) its crop as X0,Y0,X1,Y1") }
    if rowsPair != nil || stretch != nil || align {
        guard let n = gelN else { fail("--rows, --scale and --align are for one of the stacked gels: say which with --gel N") }
        if strip == nil { fail("gel \(n) has the lanes, so it isn't lined up with anything; crop it with --crop, or move it with --shift") }
    }

    // sizes are the turned images' (a quarter turn swaps them), never the file's own. A gel's picture is asked for only by the
    // options that need it, so one gel that can't be read stops those ("Gel N's image (file) can't be read."), not a --title or --labels
    var decodedMain: SourceImage?
    func mainImage() throws -> SourceImage {
        if let m = decodedMain { return m }
        let m = try pkg.decodeMain()
        decodedMain = m
        return m
    }
    func mainSize() throws -> (width: Int, height: Int) {
        if let s = GelPackage.pixelSize(of: pkg.imageData) { return pkg.project.workingSize(width: s.width, height: s.height) }
        let s = try mainImage()
        return pkg.project.workingSize(width: s.width, height: s.height)
    }
    func stripSize(_ k: Int) throws -> (width: Int, height: Int) {
        if let d = pkg.stripData(k), let s = GelPackage.pixelSize(of: d) {
            return pkg.project.stripProject(k).workingSize(width: s.width, height: s.height)
        }
        let s = try pkg.decodeStrip(k)
        return pkg.project.stripProject(k).workingSize(width: s.width, height: s.height)
    }
    if let q = quarter {
        if let k = strip {
            let s = try stripSize(k)
            GelOps.turn(&pkg.project, strip: k, by: q, width: s.width, height: s.height)
        } else {
            let s = try mainSize()
            GelOps.turn(&pkg.project, strip: nil, by: q, width: s.width, height: s.height)
        }
    }
    func allStripSizes() throws -> [(width: Int, height: Int)] { try pkg.project.strips.indices.map { try stripSize($0 + 1) } }

    if let separatorColor { pkg.project.separatorColor = separatorColor }
    if let separatorWidth { pkg.project.separatorWidth = separatorWidth }
    // Strict first: what rotation, scaling and fill may do depends on it, whatever order they were typed in. With --gel N it's
    // that gel's own setting (the gel with the lanes' when N is that gel)
    if let on = strictOn {
        let size = try mainSize()
        GelOps.setStrict(&pkg.project, on, gel: strip, imageWidth: size.width, imageHeight: size.height, stripSizes: try allStripSizes())
    }
    if let on = fileNamesOn { pkg.project.exportFileNames = on }
    if let d = degrees {
        guard !pkg.project.isStrict(gel: strip) else {
            fail("--rotate needs --strict off" + (strip == nil ? "" : " for this gel (--strict off --gel \(gelN ?? 0))") + " (rotating resamples the gel)")
        }
        if let k = strip {
            let size = try stripSize(k)
            GelOps.setStripRotation(&pkg.project, strip: k, degrees: d, width: size.width, height: size.height)
        } else {
            let size = try mainSize()
            GelOps.setRotation(&pkg.project, degrees: d, imageWidth: size.width, imageHeight: size.height)
        }
    }
    if let k = strip {
        if let v = cropBox {   // gel N's own crop: its columns and rows, in its own pixels (--rows below can still set the rows)
            let size = try stripSize(k)
            guard GelOps.setStripCrop(&pkg.project, strip: k, left: v[0], top: v[1], right: v[2], bottom: v[3], width: size.width, height: size.height)
            else { fail(GelOps.cropMessage(width: size.width, height: size.height)) }
        }
        if let r = rowsPair {
            let h = try stripSize(k).height
            guard GelOps.setStripRows(&pkg.project, strip: k, top: r[0], bottom: r[1], height: h) else { fail(GelOps.rowsMessage(height: h)) }
        }
        if let shift { pkg.project.strips[k - 1].shift = shift }   // its place in the figure
        if let stretch {
            guard !pkg.project.isStrict(gel: k) || stretch == 1 else {
                fail("--scale needs --strict off for this gel (--strict off --gel \(gelN ?? 0)): stretching resamples the gel")
            }
            pkg.project.strips[k - 1].scale = stretch
        }
    }
    if let shift, strip == nil { pkg.project.mainShift = shift.rounded() }   // the gel with the lanes, whole pixels
    if let fillMode {
        pkg.project.fillMode = fillMode
        if fillMode == .custom { pkg.project.fillValue = fillLevel }
    }
    if let from = schemeFrom {
        let other = try GelPackage.read(from: URL(fileURLWithPath: from))
        let (W, H) = try mainSize()
        LabelScheme(from: other.project, positions: withPositions).apply(to: &pkg.project, imageWidth: W, imageHeight: H)
    }
    if let v = cropBox, strip == nil {
        let (W, H) = try mainSize()
        pkg.project.crop = PixelRect(x0: v[0], y0: v[1], x1: v[2], y1: v[3]).normalized(width: W, height: H)
    }
    if let xs = dividerXs {
        let (W, H) = try mainSize()
        for x in xs where x < 0 || x > Double(W) { fail("--dividers wants positions inside the gel, from 0 to \(W)") }
        GelOps.setDividers(&pkg.project, xs: xs, imageWidth: W, imageHeight: H)
    } else if let n = laneCount {
        let work = WorkingImage(source: try mainImage(), project: pkg.project)
        if GelOps.autoDividers(&pkg.project, work, count: n).centers.count < 2 {
            warn("couldn't find \(n) lanes; place them with --dividers")
        }
    }
    if let labelsText {
        let r = GelOps.applyQuickLabels(&pkg.project, text: labelsText, groupRowName: rowName)
        if let e = r.error { fail(e) }
        for w in r.warnings { warn(w) }
    } else if let rowName {
        // the row of group labels nearest the lanes, as --labels names it
        guard let i = pkg.project.rows.firstIndex(where: { $0.type == .groups }) else {
            fail("--row-name needs a row of group labels; type them with --labels")
        }
        pkg.project.rows[i].name = rowName.isEmpty ? nil : rowName
    }

    if let labelAngle, !GelOps.setLabelAngle(&pkg.project, labelAngle) {
        warn("there are no lane labels yet, so the angle wasn't stored; type them with --labels")
    }
    if let groupAngle {
        let groupRows = pkg.project.rows.indices.filter { pkg.project.rows[$0].type == .groups }
        for i in groupRows { GelOps.setRowAngle(&pkg.project, row: i, groupAngle) }
        if groupRows.isEmpty { warn("there are no group labels yet, so the angle wasn't stored; type them with --labels") }
    }

    // gel N's working image, after its turn and rotation, for lining up, ticks and names (decoded when one of them needs it)
    var stripWorkCache: WorkingImage?
    func stripWorking(_ k: Int) throws -> WorkingImage {
        if let w = stripWorkCache { return w }
        let w = WorkingImage(source: try pkg.decodeStrip(k), project: pkg.project.stripProject(k))
        stripWorkCache = w
        return w
    }
    if align, let k = strip, let n = gelN {
        let sw = try stripWorking(k)
        guard pkg.project.lanes.centers.count >= 2 else { fail("couldn't line gel \(n) up: place the lane dividers first, then try again") }
        let s = pkg.project.strips[k - 1]
        let keeps = pkg.project.isStrict(gel: k)
        let (outcome, note) = StripAlign.fit(mainCenters: pkg.project.lanes.centers, strip: sw, bandsDark: s.display.bandsDark,
                                             rows: s.rowRange(height: sw.height), keepsOriginal: keeps, gelNumber: n)
        guard case .aligned(let r) = outcome else {
            fail(StripAlign.refusal(outcome, gelNumber: n, strict: keeps) ?? "couldn't line gel \(n) up")
        }
        // the fit is to the lanes wherever the gel with the lanes sits; a gel's shift is its place in the figure
        pkg.project.strips[k - 1].shift = pkg.project.shiftToStore(laneShift: r.shift, scale: r.scale)
        pkg.project.strips[k - 1].scale = r.scale
        let f = FigureLayoutEngine.formatSize
        say("gel \(n): shift \(f(pkg.project.strips[k - 1].shift)) px, scale \(f(r.scale)); the worst lane is \(f(r.worst)) px off")
        if let note { say(note) }
    }
    if let on = ownLadderOn { GelOps.setOwnLadder(&pkg.project, strip: strip, on) }

    // ticks and names belong to one gel: inside its image, and moved into the rows the figure shows of it
    func gelSize() throws -> (Int, Int) {
        let s = try strip.map(stripSize) ?? mainSize()
        return (s.width, s.height)
    }
    func insideGel(_ y: Double, _ what: String) throws -> Double {
        let (gw, gh) = try gelSize()
        guard y >= 0, y <= Double(gh) else { fail("\(what) wants rows inside the gel, from 0 to \(gh)") }
        let moved = pkg.project.clampY(y, strip: strip, width: gw, height: gh)
        if abs(moved - y) > 0.5 { warn("row \(FigureLayoutEngine.formatSize(y)) is outside what the figure shows of the gel; moved to \(FigureLayoutEngine.formatSize(moved))") }
        return moved
    }
    if !tickYs.isEmpty {
        let wanted = try tickYs.map { try insideGel($0, "--ticks") }
        let (gw, gh) = try gelSize()
        let (W, H) = try mainSize()
        let lane = pkg.project.ladder?.lane ?? 1
        let centers = pkg.project.lanes.centers
        let canSnap = snap && lane >= 1 && lane <= centers.count
        if snap && !canSnap { warn("no lanes yet, so the ticks weren't snapped to bands") }
        var dark: GrayImage?, cx = 0.0, laneWidth = pkg.project.lanes.width
        if canSnap {
            if let k = strip {
                let sw = try stripWorking(k)
                dark = sw.darkness(bandsDark: pkg.project.strips[k - 1].display.bandsDark)
                cx = GelOps.laneX(pkg.project, lane: lane, strip: k) ?? 0
                laneWidth *= pkg.project.effectiveAlignment(k).scale
            } else {
                dark = WorkingImage(source: try mainImage(), project: pkg.project).darkness(bandsDark: pkg.project.display.bandsDark)
                cx = centers[lane - 1]
            }
        }
        let c = pkg.project.effectiveCrop(width: W, height: H)
        let shown = pkg.project.figureRows(strip: strip, width: gw, height: gh)
        // top down, so each tick takes the next size from the ladder's list, as a guess (with --preset they're all sized below)
        for y0 in wanted.sorted() {
            var y = y0
            if let dark, let s = Detect.snapBand(in: dark, x: cx, y: y, laneWidth: laneWidth, rows: shown) { y = s }   // only a band the figure shows
            y = pkg.project.clampY(y, strip: strip, width: gw, height: gh)
            let size = preset == nil ? GelOps.suggestedSize(pkg.project, forY: y, strip: strip, preset: nil) : nil
            GelOps.addTick(&pkg.project, y: y, size: size, auto: true, lane: lane, gelCenterX: (c.x0 + c.x1) / 2, strip: strip)
        }
    }
    if let preset {
        if let key = systemKey {
            guard let sys = preset.system(named: key) else {
                fail("\(preset.name) has no gel system matching \(key): " + preset.systems.map(\.name).joined(separator: "; "))
            }
            if pkg.project.ladder == nil { pkg.project.ladder = Ladder() }   // before any tick, so the system isn't lost
            pkg.project.ladder!.system = sys.name
        }
        GelOps.applyPreset(&pkg.project, preset)
    } else if let key = systemKey {
        // another gel system for the preset the project already has
        guard let name = pkg.project.ladder?.name, let current = LadderLibrary.all().first(where: { $0.displayName == name }) else {
            fail("--system goes with --preset (this project has no ladder preset yet)")
        }
        guard let sys = current.system(named: key) else {
            fail("\(current.name) has no gel system matching \(key): " + current.systems.map(\.name).joined(separator: "; "))
        }
        GelOps.applySystem(&pkg.project, preset: current, system: sys)
    }
    for m in marks {
        let before = pkg.project.annotations.count
        GelOps.addAnnotation(&pkg.project, text: m.text, y: try insideGel(m.y, "--name"), marker: m.marker)
        if let k = strip, pkg.project.annotations.count > before { pkg.project.annotations[pkg.project.annotations.count - 1].strip = k }
    }
    if let titleText { pkg.project.title = titleText.isEmpty ? nil : titleText }
    if cropFit {
        let (W, H) = try mainSize()
        pkg.project.crop = GelOps.suggestCrop(pkg.project, imageWidth: W, imageHeight: H)
    }
    // (a main image whose size can't be read has nothing to sync to; no option that needs the size got this far without it)
    if let size = try? mainSize() { pkg.project.syncLaneCenters(imageWidth: size.width, imageHeight: size.height) }

    let changed = [dividersText, autoLanesText, labelsText, rowName, labelAngleText, groupAngleText, presetID, systemKey, ticksText, titleText, cropText,
                   strictText, separatorText, separatorWidthText, schemeFrom, rotateText, fillText, removeText, orderText, turnText, rowsText, shiftText, scaleText,
                   alignText, ownLadderText, fileNamesText].contains { $0 != nil } || !nameTexts.isEmpty || !newGels.isEmpty
    if changed {
        if isFolder {
            try pkg.write(to: url)
            // the copy GelScribe made of a gel that was taken out (the original file elsewhere is untouched)
            // (only inside a .gelscribe package: a plain folder with a project.json in it keeps all its files)
            if let name = removedImage { GelPackage.deleteRemovedCopy(named: name, in: url) }
        } else {
            try GelProject.encoder().encode(pkg.project).write(to: url, options: .atomic)   // a bare config next to its image
        }
    }
    let n = pkg.project.strips.count
    func plural(_ n: Int, _ word: String) -> String { "\(n) \(word)" + (n == 1 ? "" : "s") }   // "1 name", "2 names"
    print("\(plural(pkg.project.laneCount, "lane")), \(plural(pkg.project.ladder?.bands.count ?? 0, "tick")), \(plural(pkg.project.annotations.count, "name"))" +
          (n > 0 ? ", \(plural(n + 1, "gel"))" : ""))
}

func runDetect(_ words: [String]) throws {
    var a = CLIArgs(words)
    let lanesText = a.option("--lanes")
    let img = a.file("IMAGE")
    var count: Int?
    if let t = lanesText {
        let n = whole(t, "--lanes wants the number of lanes")
        guard (2...4096).contains(n) else { fail("--lanes wants 2 lanes or more") }
        count = n
    }
    requireFile(img, "image")
    let src = try SourceImage(data: Data(contentsOf: URL(fileURLWithPath: img)))
    let work = WorkingImage(source: src, project: GelProject(image: img))
    let dark = work.darkness(bandsDark: true)
    let fit = Detect.lanes(in: dark, count: count)
    let bands = fit.centers.first.map { Detect.bands(in: dark, center: $0, width: fit.width) } ?? []
    let out: [String: Any] = [
        "image": img, "width": work.width, "height": work.height, "pitch": fit.pitch, "lane_width": fit.width,
        "lane_centers": fit.centers,
        "lane1_bands": bands.map { ["y": $0.y, "fwhm": $0.fwhm, "prominence": $0.prominence] },
    ]
    let data = try JSONSerialization.data(withJSONObject: out, options: [.prettyPrinted, .sortedKeys])
    print(String(decoding: data, as: UTF8.self))
}

func runVerify(_ words: [String]) throws {
    var a = CLIArgs(words)
    let path = a.file("PROJECT")
    requireFile(path, "project")
    let pkg = try GelPackage.read(from: URL(fileURLWithPath: path))
    // every gel must open: "Gel N's image (file) can't be read."
    _ = try pkg.decodeMain()
    for k in pkg.project.strips.indices { _ = try pkg.decodeStrip(k + 1) }
    var changed: [String] = []
    let checks = [(pkg.project.image, pkg.imageIntact)] + pkg.project.strips.indices.map { (pkg.project.strips[$0].image, pkg.stripIntact($0 + 1)) }
    for (name, intact) in checks {
        switch intact {
        case true?: print("intact: \(name) matches its recorded SHA-256")
        case false?: changed.append(name)
        case nil: print("no hash recorded for \(name)")
        }
    }
    if !changed.isEmpty { fail("CHANGED: \(changed.joined(separator: ", ")) no longer match\(changed.count == 1 ? "es" : "") the recorded SHA-256") }
}

// MARK: main

let allWords = Array(CommandLine.arguments.dropFirst())
guard let cmd = allWords.first else { usage() }
let rest = Array(allWords.dropFirst())

do {
    switch cmd {
    case "new": try runNew(rest)
    case "render": try runRender(rest)
    case "edit": try runEdit(rest)
    case "detect": try runDetect(rest)
    case "verify": try runVerify(rest)

    case "mcp":
        CLIArgs(rest).nothingElse()
        // stdout carries protocol messages only; everything else goes to stderr
        let host = FileProjectHost()
        let server = MCPServer(name: "gelscribe", version: "0.1", instructions: GelTools.instructions,
                               tools: GelTools.make(host: host))
        await MCPStdio.run(server)

    case "presets":
        CLIArgs(rest).nothingElse()
        for p in LadderLibrary.all() {
            print("\(p.id)\t\(p.displayName)\t\(p.unit)\t\(p.sizes.map { FigureLayoutEngine.formatSize($0) }.joined(separator: " "))")
            for s in p.systems {
                print("  \(s.id)\t\(s.name)\t\(s.sizes.map { FigureLayoutEngine.formatSize($0) }.joined(separator: " "))")
            }
        }

    case "help", "-h", "--help":
        print(usageText, terminator: "")

    default:
        usageError("unknown command \(cmd)")
    }
} catch {
    fail(error.localizedDescription)
}

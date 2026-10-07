import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import GelKit

// Tests for the audit fixes: data safety, wrong figures, own ladder, unit label, float refusal, provenance.

/// The project's docs folder (tutorial images), found from this file.
let docsURL = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("docs")
func docImage(_ name: String) throws -> Data { try Data(contentsOf: docsURL.appendingPathComponent(name)) }
let hasDocs = FileManager.default.fileExists(atPath: docsURL.appendingPathComponent("bottom-piece.png").path)

/// An 8-bit gray PNG: `lanes` dark lanes with a band at each of `bandRows`, on a light background. With `noiseSeed` the
/// picture is only noise (±20 levels around `base`), the same for the same seed.
func gelPNG(width: Int, height: Int, lanes: [Double] = [], bandRows: [Int] = [], base: UInt8 = 230,
                    noiseSeed: UInt32? = nil) -> Data {
    var px = [UInt8](repeating: base, count: width * height)
    var seed = noiseSeed ?? 0
    for y in 0..<height {
        for x in 0..<width {
            var v = Double(base)
            for c in lanes where abs(Double(x) - c) < 26 {
                let across = exp(-pow((Double(x) - c) / 10, 2) / 2)
                for r in bandRows { v -= 170 * across * exp(-pow(Double(y - r) / 4, 2) / 2) }
            }
            if noiseSeed != nil {
                seed = seed &* 1_664_525 &+ 1_013_904_223
                v = Double(base) + Double(Int(seed >> 16) % 41 - 20)
            }
            px[y * width + x] = UInt8(max(0, min(255, v.rounded())))
        }
    }
    return pngData(CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: width,
                           space: CGColorSpace(name: CGColorSpace.genericGrayGamma2_2)!,
                           bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                           provider: CGDataProvider(data: Data(px) as CFData)!, decode: nil, shouldInterpolate: false,
                           intent: .defaultIntent)!)
}

func pngData(_ img: CGImage) -> Data {
    let out = NSMutableData()
    let dest = CGImageDestinationCreateWithData(out, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, img, nil)
    CGImageDestinationFinalize(dest)
    return out as Data
}

/// The gel with the lanes (620×160, eight lanes) and one stacked gel (700×220), as a package.
private func twoGelPackage() throws -> GelPackage {
    let c = (0..<8).map { 60 + 70 * Double($0) }
    var pkg = try GelPackage.create(imageData: gelPNG(width: 620, height: 160, lanes: c, bandRows: [60, 110]), imageName: "main.png")
    GelOps.setDividers(&pkg.project, xs: zip(c, c.dropFirst()).map { ($0 + $1) / 2 }, imageWidth: 620, imageHeight: 160)
    try pkg.addStrip(imageData: gelPNG(width: 700, height: 220, lanes: c.map { $0 + 37 }, bandRows: [90]), imageName: "other.png")
    return pkg
}

func tempFolder(_ name: String = "t") -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("gelscribe-\(name)-\(UUID().uuidString)")
}

@Suite struct AutoAlignRefusal {
    private func contrast(_ name: String, lanes: Int, rows: ClosedRange<Double>? = nil) throws -> StripAlign.Contrast {
        let w = WorkingImage(source: try SourceImage(data: try docImage(name)), project: GelProject(image: name))
        let f = try #require(StripAlign.find(lanes: lanes, in: w, bandsDark: true, rows: rows))
        return try #require(StripAlign.laneContrast(col: f.col, centers: f.centers, pitch: f.pitch))
    }

    // the shared decision's reference values as (spread, modulation), docs images, darkness with bands dark; the Python
    // version measures the same
    @Test(.enabled(if: hasDocs, "needs docs/")) func topPieceContrast() throws {
        let c = try contrast("top-piece.png", lanes: 13)
        #expect(abs(c.spread - 0.408) < 0.01 && abs(c.modulation - 0.632) < 0.01, "\(c)")
        #expect(c.spread >= StripAlign.minimumContrast && c.modulation >= StripAlign.minimumModulation)
        #expect(StripAlign.minimumContrast == 0.08 && StripAlign.minimumModulation == 0.08)
    }
    @Test(.enabled(if: hasDocs, "needs docs/")) func bottomPieceContrastKeepsTheTutorialAligning() throws {
        let whole = try contrast("bottom-piece.png", lanes: 13), rows = try contrast("bottom-piece.png", lanes: 13, rows: 35...337)
        #expect(abs(whole.spread - 0.855) < 0.01 && abs(whole.modulation - 0.780) < 0.01, "\(whole)")
        #expect(abs(rows.spread - 0.562) < 0.01 && abs(rows.modulation - 0.868) < 0.01, "\(rows)")
        for c in [whole, rows] { #expect(c.spread >= StripAlign.minimumContrast && c.modulation >= StripAlign.minimumModulation) }
    }

    @Test func theTwoContrastsAreMeasuredAsSpecified() throws {
        // lane windows (columns 15…25, 45…55, 75…85) at 100, everything else 20: lane 100, gap 20, 5th and 95th percentile 20 and 100
        var col = [Double](repeating: 20, count: 100)
        for c in [20, 50, 80] { for i in (c - 5)...(c + 5) { col[i] = 100 } }
        let c = try #require(StripAlign.laneContrast(col: col, centers: [20, 50, 80], pitch: 30))
        #expect(c.spread == 1 && abs(c.modulation - 2.0 / 3.0) < 1e-12)
        // nothing to measure: no signal at all (lane + gap isn't above zero), or no spread (a flat profile)
        #expect(StripAlign.laneContrast(col: [Double](repeating: 0, count: 100), centers: [20, 50, 80], pitch: 30) == nil)
        #expect(StripAlign.laneContrast(col: [Double](repeating: 7, count: 100), centers: [20, 50, 80], pitch: 30) == nil)
        // lanes weaker than the gaps score below zero on both
        let weak = col.map { 120 - $0 }
        let w = try #require(StripAlign.laneContrast(col: weak, centers: [20, 50, 80], pitch: 30))
        #expect(w.spread < 0 && w.modulation < 0)
    }

    private let centers = (0..<8).map { 60 + 70 * Double($0) }
    private func working(_ data: Data) throws -> WorkingImage {
        WorkingImage(source: try SourceImage(data: data), project: GelProject(image: "x.png"))
    }

    @Test func blankAndNoisyGelsAreRefused() throws {
        // white noise scores below the threshold nearly always (these seeds: 0.02, 0.035); a blank gel has no spread at all
        let gels = [gelPNG(width: 700, height: 220)] + [UInt32(1), 2].map { gelPNG(width: 700, height: 220, noiseSeed: $0) }
        for data in gels {
            let w = try working(data)
            let outcome = StripAlign.attempt(mainCenters: centers, strip: w, bandsDark: true, allowScale: true)
            #expect(outcome == .noLanes && outcome.result == nil)
        }
        #expect(StripAlign.refusal(.noLanes, gelNumber: 2, strict: true) == "Couldn't find Gel 2's lanes. Line it up by hand.")
    }

    @Test func noiseThatPassesTheSpreadTestIsRefusedByTheModulationTest() throws {
        // about one gel of pure noise in ten gets over the 0.08 spread threshold, as this one does (0.134); its modulation
        // depth is tiny (the tutorial's lanes score 0.63 and up), so it still isn't taken for lanes
        let w = try working(gelPNG(width: 700, height: 220, noiseSeed: 5))
        let found = try #require(StripAlign.find(lanes: 8, in: w, bandsDark: true, rows: nil))
        let c = try #require(StripAlign.laneContrast(col: found.col, centers: found.centers, pitch: found.pitch))
        #expect(c.spread >= StripAlign.minimumContrast && c.modulation < 0.05, "\(c)")
        #expect(StripAlign.attempt(mainCenters: centers, strip: w, bandsDark: true, allowScale: true) == .noLanes)
    }

    @Test func aRealGelStillLinesUpAndAMismatchedOneIsRefused() throws {
        let stripLanes = centers.map { 1.3 * $0 + 10 }   // lanes 30% further apart
        let w = try working(gelPNG(width: 800, height: 220, lanes: stripLanes, bandRows: [90]))
        // free to stretch: lined up
        let free = StripAlign.attempt(mainCenters: centers, strip: w, bandsDark: true, allowScale: true)
        guard case .aligned(let r) = free else { Issue.record("not aligned: \(free)"); return }
        #expect(abs(r.scale - 1.3) < 0.03)
        // Strict can only shift: the far lanes end up more than half a lane out, which is refused (and says so)
        let strict = StripAlign.attempt(mainCenters: centers, strip: w, bandsDark: true, allowScale: false)
        guard case .offBy(let off) = strict else { Issue.record("not refused: \(strict)"); return }
        #expect(off.worst > 0.5 * 70)
        #expect(StripAlign.refusal(strict, gelNumber: 3, strict: true) ==
                "Gel 3's lanes don't line up with the lanes gel's. Line it up by hand or turn off Keep original pixels for Gel 3 to let it stretch.")
        #expect(StripAlign.refusal(strict, gelNumber: 3, strict: false) == "Gel 3's lanes don't line up with the lanes gel's. Line it up by hand.")
        #expect(StripAlign.refusal(free, gelNumber: 3, strict: false) == nil)
    }
}

@Suite struct ImageNames {
    private let img = gelPNG(width: 80, height: 40)

    @Test func gelNamesNeverDifferOnlyInCapitals() throws {
        var pkg = try GelPackage.create(imageData: img, imageName: "Blot.png")
        try pkg.addStrip(imageData: img, imageName: "blot.png")
        try pkg.addStrip(imageData: img, imageName: "BLOT.PNG")
        try pkg.addStrip(imageData: img, imageName: "Project.JSON")
        #expect(pkg.project.strips.map(\.image) == ["blot_1.png", "BLOT_2.PNG", "gel.png"])
        #expect(Set(([pkg.project.image] + pkg.project.strips.map(\.image)).map(GelPackage.nameKey)).count == 4)
    }

    @Test func aCopyIsDeletedOnlyWhenNoGelUsesItsName() throws {
        var pkg = try GelPackage.create(imageData: img, imageName: "a.png")
        try pkg.addStrip(imageData: img, imageName: "b.png")
        pkg.project.strips.append(GelStrip(image: "B.PNG"))   // a project edited by hand: two gels on one file
        pkg.stripImages["B.PNG"] = img
        let first = pkg.removeStrip(1)
        #expect(first == nil && pkg.stripImages["b.png"] != nil)       // the other gel still needs it
        let second = pkg.removeStrip(1)
        #expect(second == "B.PNG" && pkg.stripImages["B.PNG"] == nil)   // now nobody does
        pkg.project.strips.append(GelStrip(image: "A.png"))   // the main image's own file
        let third = pkg.removeStrip(1)
        #expect(third == nil)
    }

    @Test func writingChecksEverythingFirstAndLeavesNothingBehind() throws {
        let dir = tempFolder().appendingPathExtension("gelscribe")
        defer { try? FileManager.default.removeItem(at: dir) }
        let first = try GelPackage.create(imageData: img, imageName: "Blot.png")
        try first.write(to: dir)
        let before = try Data(contentsOf: dir.appendingPathComponent("project.json"))
        // a different project that wants a gel called blot.png: the folder already holds Blot.png
        var second = try GelPackage.create(imageData: gelPNG(width: 60, height: 60), imageName: "other.png")
        second.project.strips = [GelStrip(image: "blot.png")]
        second.stripImages["blot.png"] = img
        #expect(throws: GelKitError.self) { try second.write(to: dir) }
        #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("other.png").path))   // nothing half-written
        #expect(try Data(contentsOf: dir.appendingPathComponent("project.json")) == before)
        // and a different image under the main image's own name is refused too
        let impostor = try GelPackage.create(imageData: gelPNG(width: 60, height: 60), imageName: "Blot.png")
        #expect(throws: GelKitError.self) { try impostor.write(to: dir) }
        #expect(try first.imageData == Data(contentsOf: dir.appendingPathComponent("Blot.png")))
    }

    @Test func projectExtensionsCountInAnyCase() {
        #expect(GelPackage.isProjectPath(URL(fileURLWithPath: "/x/Blot.GelScribe")) && GelPackage.isProjectPath(URL(fileURLWithPath: "/x/a.gelscribe")))
        #expect(!GelPackage.isProjectPath(URL(fileURLWithPath: "/x/project.json")))
    }
}

@Suite struct UnreadableGels {
    @Test func aMissingGelNeverLetsAnotherTakeItsPlaceAndNothingIsExported() throws {
        var pkg = try twoGelPackage()
        try pkg.addStrip(imageData: gelPNG(width: 620, height: 100, base: 60), imageName: "dark.png")   // gel 3, all 60
        let main = WorkingImage(source: try SourceImage(data: pkg.imageData), project: pkg.project)
        let dark = WorkingImage(source: try pkg.decodeStrip(2), project: pkg.project.stripProject(2))
        // gel 2 (other.png) can't be read: its place stays empty and gel 3 still shows its own picture
        let stack = StackGeometry(project: pkg.project, mainWidth: 620, mainHeight: 160,
                                  stripSizes: [nil, (width: dark.width, height: dark.height)])
        #expect(stack.piece(strip: 1) == nil && stack.piece(strip: 2) != nil)
        let gel = try #require(StripStack.figureImage(main: main, strips: [nil, dark], project: pkg.project, stack: stack))
        let piece = try #require(stack.piece(strip: 2))
        let row = RawPixels(gel).region(x: 10, y: Int(piece.top - stack.crop.y0) + 5, w: 4, h: 1, channels: 1)
        #expect(row.allSatisfy { $0 == 60 }, "\(row)")
        // a figure that has a gel missing says which, and isn't exported
        let fig = StackedFigure(project: pkg.project, main: main, strips: [])
        #expect(fig.unreadableGel == "Gel 2's image (other.png) can't be read.")
        #expect(fig.export(.pdf) == nil && fig.export(.png) == nil)
        #expect(pkg.project.unreadableMessage(strip: 2) == "Gel 3's image (dark.png) can't be read." && pkg.project.unreadableMessage(strip: nil) == "Gel 1's image (main.png) can't be read.")
        // reading the gels of a package names the one that fails
        var broken = pkg
        broken.stripImages["other.png"] = Data("nope".utf8)
        #expect(throws: GelKitError.self) { try StackedFigure.stripImages(broken) }
        do { _ = try StackedFigure.stripImages(broken) } catch { #expect(error.localizedDescription == "Gel 2's image (other.png) can't be read.") }
    }
}

@Suite struct StripRows {
    @Test func rowsAreClampedOrRefused() {
        var p = GelProject(image: "a.png")
        p.strips = [GelStrip(image: "b.png")]
        let clamped = GelOps.setStripRows(&p, strip: 1, top: -20, bottom: 500, height: 220)
        #expect(clamped && p.strips[0].top == 0 && p.strips[0].bottom == 220)
        let ok = GelOps.setStripRows(&p, strip: 1, top: 10.5, bottom: 150, height: 220)
        #expect(ok)
        for (t, b) in [(150.0, 10.0), (100, 100), (300, 400), (.nan, 50), (5, .infinity), (-9, -3)] {
            let accepted = GelOps.setStripRows(&p, strip: 1, top: t, bottom: b, height: 220)
            #expect(!accepted, "\(t),\(b)")
        }
        #expect(p.strips[0].top == 10.5 && p.strips[0].bottom == 150)   // refusals changed nothing
        #expect(GelOps.rowsMessage(height: 220) == "Rows must be top,bottom with top < bottom, inside 0–220.")
    }

    @Test func nothingTrapsOnRowsThatAreBackwardsOrNotNumbers() {
        for (t, b) in [(150.0, 10.0), (.nan, 5), (5, .nan), (.infinity, -.infinity), (-50, 9e300), (219.9, 220)] as [(Double, Double)] {
            let s = GelStrip(image: "b.png", top: t, bottom: b)
            let r = s.usedRows(height: 220), range = s.rowRange(height: 220)
            #expect(r.top >= 0 && r.top < r.bottom && r.bottom <= 220 && range.lowerBound < range.upperBound, "\(t),\(b)")
            var p = GelProject(image: "a.png")
            p.strips = [s]
            let g = StackGeometry(project: p, mainWidth: 300, mainHeight: 100, stripSizes: [(width: 400, height: 220)])
            #expect(g.pieces.count == 2 && g.pieces[0].top < g.pieces[0].bottom)
        }
        #expect(GelStrip(image: "b.png").usedRows(height: 220) == (0, 220))
    }

    @Test func loadingPutsInvalidRowsBackToTheWholeGel() throws {
        var p = GelProject(image: "a.png")
        p.strips = [GelStrip(image: "b.png", top: 150, bottom: 10), GelStrip(image: "c.png", top: -4, bottom: 90), GelStrip(image: "d.png", top: 20, bottom: 90)]
        let back = try JSONDecoder().decode(GelProject.self, from: try GelProject.encoder().encode(p))
        #expect(back.strips.map(\.top) == [nil, nil, 20] && back.strips.map(\.bottom) == [nil, nil, 90])
        // rows past the gel's own height are caught when the package is read, where the image sizes are known
        var pkg = try GelPackage.create(imageData: gelPNG(width: 100, height: 60), imageName: "a.png")
        try pkg.addStrip(imageData: gelPNG(width: 100, height: 60), imageName: "b.png")
        pkg.project.strips[0].top = 10; pkg.project.strips[0].bottom = 5000
        let dir = tempFolder().appendingPathExtension("gelscribe")
        defer { try? FileManager.default.removeItem(at: dir) }
        try pkg.write(to: dir)
        let read = try GelPackage.read(from: dir)
        #expect(read.project.strips[0].top == nil && read.project.strips[0].bottom == nil)
    }

    @Test func aQuarterTurnedGelUsesItsTurnedSize() {
        var p = GelProject(image: "a.png")
        #expect(p.workingSize(width: 160, height: 620) == (160, 620))
        p.turn = 3
        #expect(p.workingSize(width: 160, height: 620) == (620, 160))
        p.turn = 2
        #expect(p.workingSize(width: 160, height: 620) == (160, 620))
    }
}

@Suite struct PoisonedProjects {
    private static let poisoned = """
    {"image":"a.png","crop":[0,0,1e300,50],"turn":-7,"main_position":-9,"rotate_deg":1e300,"fill_value":5,
     "lanes":{"centers":[1e300],"width":-5,"dividers":[{"x_top":1e300,"x_bottom":2,"dot_y":1},{"x_top":100,"x_bottom":100,"dot_y":5}]},
     "display":{"gamma":-1,"black":1e300,"white":2},
     "rows":[{"type":"groups","groups":[{"text":"g","lanes":[-5,1000000000]}]}],
     "ladder":{"lane":-3,"sizes":[250,1e300],"unit_y":1e300,
        "bands":[{"y":1e300,"size":5},{"y":20,"size":-1},{"y":30,"size":1e300},{"y":40,"size":9,"strip":-2}]},
     "annotations":[{"y":1e300,"text":"x"},{"y":10,"text":"ok"}],
     "style":{"gel_width_in":1e300,"size":-5,"title_size":1e300,"export_dpi":1e300,"line_width_pt":1e300},
     "strips":[{"image":"b.png","shift":1e300,"scale":-3,"top":-5,"bottom":1e300,"turn":99,"rotate_deg":-1e300}]}
    """

    private func check(_ p: GelProject) {
        #expect(p.crop == nil && p.turn == 1 && p.rotateDeg == 360 && p.fillValue == 1)
        #expect(p.lanes.centers.isEmpty && p.lanes.width == 100 && p.lanes.dividers.count == 1)
        #expect(p.display.gamma == 0.01 && p.display.black == 10 && p.display.white == 2)
        #expect(p.rows[0].groups[0].lanes == [1, 4096])
        #expect(p.ladder!.lane == 1 && p.ladder!.sizes == [250] && p.ladder!.unitY == nil)
        #expect(p.ladder!.bands.map(\.y) == [20, 30] && p.ladder!.bands.allSatisfy { $0.size == nil })   // the sane rows stay, their sizes don't
        #expect(p.annotations.map(\.text) == ["ok"])
        #expect(p.style.gelWidthIn == 100 && p.style.size == 1 && p.style.titleSize == 200 && p.style.exportDPI == nil && p.style.lineWidthPt == 50)
        let s = p.strips[0]
        #expect(s.shift == 1_000_000 && s.scale == 0.5 && s.top == nil && s.bottom == nil && s.turn == 3 && s.rotateDeg == -360)
    }

    @Test func absurdNumbersLoadSanitizedAndRenderWithoutTrapping() throws {
        let p = try JSONDecoder().decode(GelProject.self, from: Data(Self.poisoned.utf8))
        check(p)
        let layout = FigureLayoutEngine.layout(p, imageWidth: 200, imageHeight: 100)
        _ = FigureRenderer.pdf(layout, gel: nil, info: ExportInfo(title: "", description: ""))
        _ = FigureRenderer.raster(layout, gel: nil)
        _ = ExportInfo.for(p, sourceSHA256: nil, size: (200, 100))
    }

    /// Replaces some numbers of a decoded JSON tree by absurd ones, the same way every run.
    private struct Poisoner: RandomNumberGenerator {
        var state: UInt64 = 20_261_005
        mutating func next() -> UInt64 { state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407; return state }
        mutating func poison(_ v: Any, rate: Double) -> Any {
            let weird: [Any] = [1e300, -1e300, 1e19, -1e19, 9e15, -1, 0, -7, 1e-300, 4097, 1_000_001, 1e9, 99, 1e15]
            if let d = v as? [String: Any] {   // keys in order: dictionaries come in a different order every run
                return Dictionary(uniqueKeysWithValues: d.keys.sorted().map { ($0, poison(d[$0]!, rate: rate)) })
            }
            if let a = v as? [Any] { return a.map { poison($0, rate: rate) } }
            if let n = v as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID(), Double.random(in: 0...1, using: &self) < rate {
                return weird.randomElement(using: &self)!
            }
            return v
        }
    }

    @Test func randomlyPoisonedProjectsLoadAndExportWithoutTrapping() throws {
        var pkg = try twoGelPackage()
        pkg.project.ladder = Ladder(lane: 1, name: "x", sizes: [250, 130, 100, 70, 55])
        for (y, s) in [(30.0, nil), (90, nil), (40, 1), (70, 1)] as [(Double, Int?)] { GelOps.addTick(&pkg.project, y: y, size: nil, lane: 1, gelCenterX: 300, strip: s) }
        pkg.project.assignLadder(sizes: [250, 130, 100, 70])
        _ = GelOps.applyQuickLabels(&pkg.project, text: "µM: ladder|0{L|P}|125{L|P}|250{L|P}")
        pkg.project.annotations = [BandAnnotation(y: 50, y2: 80, text: "A", marker: .bracket), BandAnnotation(y: 30, text: "B", strip: 1)]
        pkg.project.style.textSizes = ["name.0": 9, "name.1": 8]
        pkg.project.strips[0].top = 20; pkg.project.strips[0].bottom = 200
        pkg.project.ladder?.unitY = 30; pkg.project.ladder?.unitStrip = 1
        let base = try JSONSerialization.jsonObject(with: try GelProject.encoder().encode(pkg.project))
        var rng = Poisoner()
        var loaded = 0
        for round in 0..<16 {
            let data = try JSONSerialization.data(withJSONObject: rng.poison(base, rate: [0.01, 0.03, 0.08, 0.3][round % 4]))
            guard let p = try? GelProject.decoder().decode(GelProject.self, from: data), p.strips.count == 2 - 1 else { continue }
            loaded += 1
            var q = pkg
            q.project = p
            q.normalize()
            let work = WorkingImage(source: try q.decodeMain(), project: q.project)
            let fig = StackedFigure(project: q.project, main: work, strips: try StackedFigure.stripImages(q))
            _ = (fig.layout, fig.gel, fig.info(resampledDPI: 300), fig.strictProblem)
            for type in [UTType.pdf, .png, .svg] { _ = fig.export(type) }
            _ = fig.export(.png, dpi: 1e9)
            _ = (QuickLabels.shorthand(q.project), q.project.ladderWarnings)
            var edited = q.project
            edited.assignLadder(sizes: [250, 130, 100])
            GelOps.turn(&edited, strip: nil, by: 2, width: 620, height: 160)
            GelOps.setRotation(&edited, degrees: 2, imageWidth: 620, imageHeight: 160)
            var target = q.project
            LabelScheme(from: q.project, positions: true).apply(to: &target, imageWidth: 620, imageHeight: 160)
        }
        #expect(loaded >= 3, "only \(loaded) of the poisoned files loaded")   // enough got through to be a real test
    }

    @Test func nanAndInfinityTokensLoadToo() throws {
        let text = "{\"image\":\"a.png\",\"crop\":[0,0,NaN,Infinity],\"lanes\":{\"centers\":[NaN],\"width\":Infinity},\"ladder\":{\"bands\":[{\"y\":NaN,\"size\":Infinity},{\"y\":3,\"size\":NaN}]}}"
        let p = try GelProject.decoder().decode(GelProject.self, from: Data(text.utf8))
        #expect(p.crop == nil && p.lanes.centers.isEmpty && p.lanes.width == 100)
        #expect(p.ladder!.bands.map(\.y) == [3] && p.ladder!.bands[0].size == nil)
    }

    @Test func inMemoryNonNumbersAreSanitizedToo() {
        var p = GelProject(image: "a.png")
        p.crop = PixelRect(x0: .nan, y0: 0, x1: 10, y1: .infinity)
        p.display.gamma = .nan
        p.style.size = .nan
        p.ladder = Ladder(bands: [LadderBand(y: .infinity, size: 3)])
        let changed = p.sanitize()
        #expect(changed && p.crop == nil && p.display.gamma == 1 && p.style.size == 7 && p.ladder!.bands.isEmpty)
        let again = p.sanitize()
        #expect(!again)   // and a second time changes nothing
        #expect(PixelRect(x0: .nan, y0: 5, x1: 40, y1: .nan).normalized(width: 100, height: 50).y1 == 50)
        #expect(FigureLayoutEngine.formatSize(1e19) != "" && FigureLayoutEngine.formatSize(.nan) == "nan")
        #expect(Double.nan.safeInt == 0 && Double.infinity.safeInt > 1_000_000_000)
    }

    @Test func theModelsOwnEditsRefuseNonNumbers() {
        var p = GelProject(image: "a.png")
        GelOps.addTick(&p, y: .nan, size: 5, lane: 1, gelCenterX: 50)
        GelOps.addTick(&p, y: 1e300, size: 5, lane: 1, gelCenterX: 50)
        GelOps.addTick(&p, y: 10, size: 1e19, lane: 1, gelCenterX: 50)
        GelOps.addAnnotation(&p, text: "x", y: .infinity)
        GelOps.addDivider(&p, x: .nan, y: 3, imageWidth: 100, imageHeight: 100)
        #expect(p.ladder == nil && p.annotations.isEmpty && p.lanes.dividers.isEmpty)
        #expect(GelOps.parseSizes("250 inf nan 1e300 100") == [250, 100])
    }
}

@Suite struct LabelNesting {
    @Test func deepBracesAreRefusedNotParsed() {
        let deep = String(repeating: "A{", count: 100_000) + "x"
        let r = QuickLabels.parse(deep)
        #expect(r.items.isEmpty && r.error != nil && r.warnings == [r.error!])
        var p = GelProject(image: "a.png")
        GelOps.setDividers(&p, xs: [100, 200], imageWidth: 300, imageHeight: 100)
        _ = GelOps.applyQuickLabels(&p, text: "L|P|Q")
        let before = p.rows
        let result = GelOps.applyQuickLabels(&p, text: deep)
        #expect(result.error != nil && !result.warnings.isEmpty && p.rows == before)   // the labels stay as they were
        let open = String(repeating: "{", count: QuickLabels.maxDepth) + "x" + String(repeating: "}", count: QuickLabels.maxDepth)
        #expect(QuickLabels.parse(open).error == nil)   // exactly the limit still parses
        #expect(QuickLabels.parse(String(repeating: "{", count: QuickLabels.maxDepth + 1) + "x").error != nil)
    }
}

@Suite struct DetectionGuards {
    @Test func detectionSurvivesBadInput() {
        let tiny = GrayImage(width: 10, height: 30, pixels: [Float](repeating: 0.2, count: 300))
        #expect(Detect.lanes(in: tiny).centers.isEmpty && Detect.lanes(in: tiny, count: 3).centers.isEmpty)
        let img = GrayImage(width: 200, height: 100, pixels: [Float](repeating: 0, count: 20_000))
        for c in [-5, -1, 0, 1, Int.max] { #expect(Detect.lanes(in: img, count: c).centers.isEmpty, "count \(c)") }
        for y in [Double.nan, .infinity, -.infinity, 1e300, -1e300] {
            #expect(Detect.snapBand(in: img, x: 50, y: y, laneWidth: 30) == nil)
        }
        #expect(Detect.snapBand(in: img, x: .nan, y: 5, laneWidth: 30) == nil && Detect.snapBand(in: img, x: 5, y: 5, laneWidth: .infinity) == nil)
        #expect(Detect.bands(in: img, center: .infinity, width: 10).isEmpty && Detect.bands(in: img, center: 50, width: .nan).isEmpty)
    }
}

@Suite struct StrictProfiles {
    private func space(_ tweak: UInt8) -> CGColorSpace {
        var d = CGColorSpace(name: CGColorSpace.genericGrayGamma2_2)!.copyICCData()! as Data
        d[d.count - 3] = d[d.count - 3] &+ tweak   // another profile with no name of its own
        return CGColorSpace(iccData: d as CFData)!
    }
    private func image(_ s: CGColorSpace) -> CGImage {
        CGImage(width: 4, height: 4, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: 4, space: s,
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                provider: CGDataProvider(data: Data(repeating: 100, count: 16) as CFData)!, decode: nil, shouldInterpolate: false,
                intent: .defaultIntent)!
    }

    @Test func strictComparesTheProfilesDataNotJustTheirNames() {
        let a = image(space(1)), a2 = image(space(1)), b = image(space(7))
        #expect(a.colorSpace?.name == nil && b.colorSpace?.name == nil)   // both nameless: the old check saw no difference
        #expect(StripStack.strictMismatch(main: a, strip: b)?.contains("the color profile differs") == true)
        #expect(StripStack.strictMismatch(main: a, strip: a2) == nil)
        #expect(StripStack.strictProblem(main: a, strips: [a2, b]) { "Gel \($0)" } ==
                "Gel 2 is stored differently from the gel with the lanes (8-bit gray in both, but the color profile differs)")
    }

    /// The message says what differs: an alpha channel, floating point, the profile (not "another color profile" for everything).
    @Test func strictSaysWhatActuallyDiffers() throws {
        let srgb = try #require(CGColorSpace(name: CGColorSpace.sRGB)), gray = try #require(CGColorSpace(name: CGColorSpace.genericGrayGamma2_2))
        func rgb(_ alpha: CGImageAlphaInfo) throws -> CGImage {
            try #require(CGImage(width: 4, height: 4, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: 16, space: srgb,
                                 bitmapInfo: CGBitmapInfo(rawValue: alpha.rawValue), provider: CGDataProvider(data: Data(repeating: 9, count: 64) as CFData)!,
                                 decode: nil, shouldInterpolate: false, intent: .defaultIntent))
        }
        func wide(float: Bool) throws -> CGImage {
            let info = CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue | (float ? CGBitmapInfo.floatComponents.rawValue : 0) | CGBitmapInfo.byteOrder32Little.rawValue)
            return try #require(CGImage(width: 4, height: 4, bitsPerComponent: 32, bitsPerPixel: 32, bytesPerRow: 16, space: gray, bitmapInfo: info,
                                        provider: CGDataProvider(data: Data(repeating: 0, count: 64) as CFData)!, decode: nil, shouldInterpolate: false,
                                        intent: .defaultIntent))
        }
        #expect(StripStack.strictMismatch(main: try rgb(.noneSkipLast), strip: try rgb(.premultipliedLast))
                == "is stored differently from the gel with the lanes (8-bit RGB in both, but the alpha channel differs)")
        #expect(StripStack.strictMismatch(main: try wide(float: false), strip: try wide(float: true))
                == "is stored differently from the gel with the lanes (32-bit gray in both, but the floating-point format differs)")
    }
}

/// Gels with the lanes (place 0), then strips 1 and 2 (c.png, d.png): two ticks on each, nothing sized yet.
private func threeGels() -> GelProject {
    var p = GelProject(image: "a.png")
    p.strips = [GelStrip(image: "c.png"), GelStrip(image: "d.png")]
    p.ladder = Ladder(sizes: [250, 130, 100, 70, 55, 40])
    for strip in [nil, 1, 2] as [Int?] {
        for y in [20.0, 60] { GelOps.addTick(&p, y: y, size: nil, lane: 1, gelCenterX: 100, strip: strip) }
    }
    p.assignLadder(sizes: [250, 130, 100, 70, 55, 40])
    return p
}

private func sizes(_ p: GelProject, strip: Int?) -> [Double?] { p.ladder!.bands.filter { $0.strip == strip }.map(\.size) }

@Suite struct OwnLadder {
    @Test func theTopGelAndEveryGelWithItsOwnLadderStartAGroup() {
        var p = threeGels()
        #expect(p.ladderGroups == [[nil, 1, 2]])
        p.strips[1].ownLadder = true
        #expect(p.ladderGroups == [[nil, 1], [2]] && p.ladderGroup(of: 2) == 1 && p.ladderGroup(of: 1) == 0)
        p.ownLadder = true   // the top gel starts one anyway
        #expect(p.ladderGroups == [[nil, 1], [2]])
        p.mainPosition = 2   // the lanes gel at the bottom now: strip 1, strip 2, then it
        #expect(p.stackOrder == [1, 2, nil] && p.ladderGroups == [[1], [2], [nil]])   // strip 2 and the lanes gel each have their own
    }

    @Test func sizesStartAgainInEachGroupAndTheWarningsAndSuggestionsFollow() {
        var p = threeGels()
        #expect(sizes(p, strip: nil) == [250, 130] && sizes(p, strip: 1) == [100, 70] && sizes(p, strip: 2) == [55, 40])
        #expect(p.ladderWarnings.isEmpty)
        #expect(GelOps.suggestedSize(p, forY: 5, strip: 2, preset: nil) == 55)   // behind four ticks of the one ladder
        p.strips[1].ownLadder = true
        p.assignLadder(sizes: [250, 130, 100, 70, 55, 40])
        #expect(sizes(p, strip: 1) == [100, 70] && sizes(p, strip: 2) == [250, 130])
        #expect(p.ladderWarnings.isEmpty)   // 250 under 70 is fine across groups
        #expect(GelOps.suggestedSize(p, forY: 5, strip: 2, preset: nil) == 250 && GelOps.suggestedSize(p, forY: 40, strip: 2, preset: nil) == 130)
        #expect(GelOps.suggestedSize(p, forY: 5, strip: 1, preset: nil) == 100)
        // but within one group the sizes must shrink
        p.ladder!.bands[p.ladder!.bands.firstIndex { $0.strip == 2 && $0.y == 60 }!].size = 300
        #expect(p.ladderWarnings.count == 1 && p.ladderWarnings[0] == "300 sits below 250. Sizes should shrink down the lane.")
    }

    @Test func settingOrClearingItReassignsTheSizes() {
        var p = threeGels()
        GelOps.setOwnLadder(&p, strip: 2, true)
        #expect(p.strips[1].ownLadder && sizes(p, strip: 2) == [250, 130] && sizes(p, strip: 1) == [100, 70])
        GelOps.setOwnLadder(&p, strip: 2, false)
        #expect(!p.strips[1].ownLadder && sizes(p, strip: 2) == [55, 40])
        // the top gel starts its group either way: nothing changes, so nothing is re-guessed (a confirmed size stays)
        p.ladder!.bands[0].size = 999
        GelOps.setOwnLadder(&p, strip: nil, true)
        #expect(p.ownLadder && p.ladder!.bands[0].size == 999)
        // no ladder chosen yet: only the flag
        var bare = GelProject(image: "a.png")
        bare.strips = [GelStrip(image: "c.png")]
        GelOps.setOwnLadder(&bare, strip: 1, true)
        #expect(bare.strips[0].ownLadder && bare.ladder == nil)
    }

    @Test func itIsSavedOnlyWhenOnAndFollowsItsGel() throws {
        var p = threeGels()
        func keys(_ q: GelProject) throws -> (top: Bool, strips: [Bool]) {
            let o = try #require(JSONSerialization.jsonObject(with: try GelProject.encoder().encode(q)) as? [String: Any])
            return (o["own_ladder"] != nil, (o["strips"] as! [[String: Any]]).map { $0["own_ladder"] != nil })
        }
        let none = try keys(p)
        #expect(!none.top && none.strips == [false, false])   // nothing written when off
        p.strips[1].ownLadder = true
        p.ownLadder = true
        let on = try keys(p)
        #expect(on.top && on.strips == [false, true])
        #expect(try JSONDecoder().decode(GelProject.self, from: try GelProject.encoder().encode(p)) == p)
        // reordering moves the flag with its gel; removing the gel takes it away
        GelOps.moveGel(&p, from: 2, to: 0)   // d.png to the top
        #expect(p.strips.map(\.image) == ["d.png", "c.png"] && p.strips.map(\.ownLadder) == [true, false] && p.ownLadder)
        GelOps.removeStrip(&p, 1)
        #expect(p.strips.map(\.image) == ["c.png"] && !p.strips[0].ownLadder)
    }
}

@Suite struct HiddenTicks {
    @Test func aCropTakesTicksOutOfTheLadderButTheyKeepTheirSize() {
        var p = GelProject(image: "a.png")
        p.crop = PixelRect(x0: 0, y0: 100, x1: 300, y1: 400)
        p.ladder = Ladder(sizes: [250, 130, 100],
                          bands: [LadderBand(y: 50, size: 10), LadderBand(y: 150), LadderBand(y: 250), LadderBand(y: 350)])
        #expect(!p.isInFigure(strip: nil, y: 50) && p.isInFigure(strip: nil, y: 100) && p.isInFigure(strip: nil, y: 400))
        #expect(p.ladderWarnings.isEmpty)   // 10 above 250 would be a warning if the hidden tick counted (it has no size to compare: unset ones skip)
        p.assignLadder(sizes: [250, 130, 100])
        #expect(p.ladder!.bands.map(\.size) == [10, 250, 130, 100])   // the hidden tick took none and kept its own
        #expect(p.ladderWarnings.isEmpty)
        #expect(GelOps.suggestedSize(p, forY: 300, preset: nil) == 100)   // two visible ticks above, not three
        p.ladder!.bands[0].size = 500   // a hidden tick can't make the others wrong
        #expect(p.ladderWarnings.isEmpty)
    }

    @Test func aStripsRowsDecideWhichOfItsTicksCount() {
        var p = GelProject(image: "a.png")
        p.strips = [GelStrip(image: "b.png", top: 40, bottom: 160)]
        #expect(p.isInFigure(strip: 1, y: 40) && p.isInFigure(strip: 1, y: 160) && !p.isInFigure(strip: 1, y: 20) && !p.isInFigure(strip: 1, y: 170))
        #expect(!p.isInFigure(strip: 3, y: 50) && !p.isInFigure(strip: 1, y: .nan))   // no such gel, not a position
        // the clamp helpers the app uses: the rows the figure shows of each gel
        #expect(p.figureRows(strip: 1, width: 300, height: 220) == 40...160)
        #expect(p.clampY(500, strip: 1, width: 300, height: 220) == 160 && p.clampY(-5, strip: 1, width: 300, height: 220) == 40)
        p.crop = PixelRect(x0: 0, y0: 20, x1: 300, y1: 90)
        #expect(p.figureRows(strip: nil, width: 300, height: 100) == 20...90 && p.clampY(95, strip: nil, width: 300, height: 100) == 90)
    }
}

@Suite struct NamesAndSchemes {
    private func project() -> GelProject {
        var p = GelProject(image: "a.png")
        p.strips = [GelStrip(image: "c.png")]
        p.annotations = [BandAnnotation(y: 10, text: "A"), BandAnnotation(y: 20, text: "B", strip: 1),
                         BandAnnotation(y: 30, text: "C"), BandAnnotation(y: 40, text: "D", strip: 1)]
        p.style.textSizes = ["name.0": 7, "name.1": 8, "name.2": 9, "name.3": 10, "lane.0.1": 12]
        return p
    }

    @Test func singleNameSizesFollowTheirNamesWhenOthersGo() {
        var removed = project()
        GelOps.removeStrip(&removed, 1)   // B and D go with their gel
        #expect(removed.annotations.map(\.text) == ["A", "C"] && removed.style.textSizes == ["name.0": 7, "name.1": 9, "lane.0.1": 12])
        var turned = project()
        GelOps.turn(&turned, strip: 1, by: 1, width: 300, height: 100)   // a quarter turn clears that gel's names
        #expect(turned.style.textSizes == removed.style.textSizes)
        var one = project()
        GelOps.removeAnnotation(&one, at: 0)
        #expect(one.annotations.map(\.text) == ["B", "C", "D"] && one.style.textSizes == ["name.0": 8, "name.1": 9, "name.2": 10, "lane.0.1": 12])
    }

    @Test func marksOnGelsThatDontExistAreDroppedOnLoad() throws {
        var p = project()
        p.annotations.append(BandAnnotation(y: 50, text: "E", strip: 4))
        p.ladder = Ladder(bands: [LadderBand(y: 10, size: 5, strip: 3), LadderBand(y: 20, size: 4, strip: 1),
                                  LadderBand(y: 30, size: 3, strip: 0), LadderBand(y: 40, size: 2)])
        let back = try JSONDecoder().decode(GelProject.self, from: try GelProject.encoder().encode(p))
        #expect(back.ladder!.bands.map(\.y) == [20, 40] && back.annotations.map(\.text) == ["A", "B", "C", "D"])
        // the sizes of the names that stayed are unchanged; a dropped one takes its size with it
        var q = project()
        q.annotations[1].strip = 2
        let again = try JSONDecoder().decode(GelProject.self, from: try GelProject.encoder().encode(q))
        #expect(again.annotations.map(\.text) == ["A", "C", "D"] && again.style.textSizes["name.1"] == 9 && again.style.textSizes["name.2"] == 10)
    }

    @Test func reorderingNeverGivesAnOrphanMarkToTheGelWithTheLanes() {
        var p = project()
        p.annotations.append(BandAnnotation(y: 50, text: "stray", strip: 5))   // not possible after a load; in memory it could be
        p.ladder = Ladder(bands: [LadderBand(y: 10, size: 5, strip: 5), LadderBand(y: 20, size: 4, strip: 1), LadderBand(y: 30, size: 3)])
        GelOps.reorder(&p, [1, 0])
        #expect(p.annotations.map(\.text) == ["A", "B", "C", "D"] && p.annotations.map(\.strip) == [nil, 1, nil, 1])
        #expect(p.ladder!.bands.map(\.y) == [20, 30])
    }

    @Test func schemesCarryOnlyTheLanesGelsMarksAndNeverTheResolution() throws {
        var a = project()
        a.style.exportDPI = 600
        a.ladder = Ladder(bands: [LadderBand(y: 10, size: 50), LadderBand(y: 20, size: 40, strip: 1)], unitY: 15, unitStrip: 1)
        let withPositions = LabelScheme(from: a, positions: true)
        #expect(withPositions.annotations.map(\.text) == ["A", "C"] && withPositions.style.exportDPI == nil)
        #expect(withPositions.style.textSizes == ["name.0": 7, "name.1": 9, "lane.0.1": 12])
        #expect(withPositions.ladder!.bands.map(\.size) == [50] && withPositions.ladder!.unitY == nil && withPositions.ladder!.unitStrip == nil)
        // applied to a project with its own gel and resolution: those stay, so do the other gel's names and their sizes
        var b = GelProject(image: "b.png")
        b.strips = [GelStrip(image: "e.png")]
        b.style.exportDPI = 300
        b.annotations = [BandAnnotation(y: 5, text: "mine", strip: 1)]
        b.style.textSizes = ["name.0": 8]
        b.ladder = Ladder(bands: [LadderBand(y: 33, size: 7, strip: 1)], unitY: 12, unitStrip: 1)
        withPositions.apply(to: &b, imageWidth: 620, imageHeight: 160)
        #expect(b.style.exportDPI == 300)
        #expect(b.annotations.map(\.text) == ["A", "C", "mine"] && b.annotations[2].strip == 1)
        #expect(b.style.textSizes["name.0"] == 7 && b.style.textSizes["name.1"] == 9 && b.style.textSizes["name.2"] == 8)
        #expect(b.ladder!.bands.map(\.strip) == [nil, 1] && b.ladder!.bands.map(\.size) == [50, 7])
        #expect(b.ladder!.unitY == 12 && b.ladder!.unitStrip == 1)   // its own placement on its own gel
        // a scheme pasted from an older version still carrying gel numbers and a resolution loses both
        var old = withPositions
        old.annotations.append(BandAnnotation(y: 1, text: "stray", strip: 1))
        old.style.exportDPI = 600
        old.ladder!.bands.append(LadderBand(y: 99, size: 1, strip: 1))
        let pasted = try LabelScheme.decode(try old.encoded())
        #expect(pasted.annotations.map(\.text) == ["A", "C"] && pasted.style.exportDPI == nil && pasted.ladder!.bands.map(\.size) == [50])
    }
}

@Suite struct UnitLabelOnItsGel {
    private func project() -> GelProject {
        var p = threeGels()
        GelOps.setUnitY(&p, y: 40, strip: 2)   // beside gel 3 of the figure
        return p
    }

    @Test func itIsSavedWithItsGelAndOnlyWhenNotTheLanesGels() throws {
        func ladder(_ p: GelProject) throws -> [String: Any] {
            let o = try #require(JSONSerialization.jsonObject(with: try GelProject.encoder().encode(p)) as? [String: Any])
            return o["ladder"] as! [String: Any]
        }
        var p = project()
        let on = try ladder(p)
        #expect(on["unit_y"] as? Double == 40 && on["unit_strip"] as? Int == 2)
        #expect(try JSONDecoder().decode(GelProject.self, from: try GelProject.encoder().encode(p)) == p)
        GelOps.setUnitY(&p, y: 40, strip: nil)
        let lanes = try ladder(p)
        #expect(lanes["unit_y"] as? Double == 40 && lanes["unit_strip"] == nil)
        GelOps.setUnitY(&p, y: nil, strip: nil)
        #expect(p.ladder!.unitY == nil && p.ladder!.unitStrip == nil)
    }

    @Test func itMovesWithItsGelAndGoesWhenItDoes() {
        var moved = project()
        GelOps.moveGel(&moved, from: 2, to: 0)   // gel d.png to the top: it is strip 1 now
        #expect(moved.ladder!.unitStrip == 1 && moved.ladder!.unitY == 40)
        var removed = project()
        GelOps.removeStrip(&removed, 2)
        #expect(removed.ladder!.unitY == nil && removed.ladder!.unitStrip == nil)
        var other = project()
        GelOps.removeStrip(&other, 1)   // another gel goes: d.png becomes strip 1 and keeps the label
        #expect(other.ladder!.unitStrip == 1 && other.ladder!.unitY == 40)
        var quarter = project()
        GelOps.turn(&quarter, strip: 2, by: 1, width: 300, height: 220)
        #expect(quarter.ladder!.unitY == nil && quarter.ladder!.unitStrip == nil)
        var half = project()
        GelOps.turn(&half, strip: 2, by: 2, width: 300, height: 220)
        #expect(half.ladder!.unitY == 179 && half.ladder!.unitStrip == 2)   // 220 - 1 - 40
        var elsewhere = project()
        GelOps.turn(&elsewhere, strip: 1, by: 1, width: 300, height: 220)   // a different gel
        #expect(elsewhere.ladder!.unitY == 40)
        var lanesGel = project()
        GelOps.turn(&lanesGel, strip: nil, by: 1, width: 300, height: 100)
        #expect(lanesGel.ladder!.unitY == 40 && lanesGel.ladder!.unitStrip == 2)   // the label is on gel 2's rows, not the lanes gel's
    }

    @Test func theLabelSitsBesideItsOwnGelsRow() {
        var p = GelProject(image: "a.png")
        p.lanes.centers = [50, 150]
        p.strips = [GelStrip(image: "b.png")]
        p.ladder = Ladder(lane: 1, bands: [LadderBand(y: 50, size: 70)])
        GelOps.setUnitY(&p, y: 100, strip: 1)
        let stack = StackGeometry(project: p, mainWidth: 200, mainHeight: 160, stripSizes: [(width: 200, height: 220)])
        let layout = FigureLayoutEngine.layout(p, imageWidth: 200, imageHeight: 160, stack: stack)
        let unit = layout.texts.first { $0.role == .ladderUnit }!
        let figureRow = stack.piece(strip: 1)!.toFigure(x: 0, y: 100).y
        #expect(abs(unit.bounds.midY - layout.point(x: 0, y: figureRow).y) < 2)
        // on a gel the figure doesn't show, it goes back to the automatic place above the gel
        p.strips[0].top = 150
        let hidden = FigureLayoutEngine.layout(p, imageWidth: 200, imageHeight: 160,
                                               stack: StackGeometry(project: p, mainWidth: 200, mainHeight: 160, stripSizes: [(width: 200, height: 220)]))
        #expect(hidden.texts.first { $0.role == .ladderUnit }!.bounds.maxY < hidden.gelRect.minY)
    }
}

@Suite struct FloatImages {
    private func floatTIFF() -> Data {
        let px = [Float](repeating: 0.5, count: 16 * 16)
        let img = CGImage(width: 16, height: 16, bitsPerComponent: 32, bitsPerPixel: 32, bytesPerRow: 64,
                          space: CGColorSpace(name: CGColorSpace.genericGrayGamma2_2)!,
                          bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue | CGBitmapInfo.floatComponents.rawValue | CGBitmapInfo.byteOrder32Little.rawValue),
                          provider: CGDataProvider(data: Data(bytes: px, count: px.count * 4) as CFData)!, decode: nil,
                          shouldInterpolate: false, intent: .defaultIntent)!
        let out = NSMutableData()
        let dest = CGImageDestinationCreateWithData(out, UTType.tiff.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, img, nil)
        CGImageDestinationFinalize(dest)
        return out as Data
    }
    private let message = "This image has 32-bit floating-point values, which GelScribe doesn't support. Export it from your scanner's software as a 16-bit TIFF and open that."

    @Test func floatingPointImagesAreRefusedWhenOpenedOrAdded() throws {
        let data = floatTIFF()
        func failure(_ body: () throws -> Void) -> String? { do { try body(); return nil } catch { return error.localizedDescription } }
        #expect(failure { _ = try SourceImage(data: data) } == message)
        #expect(failure { _ = try GelPackage.create(imageData: data, imageName: "f.tif") } == message)
        var pkg = try GelPackage.create(imageData: gelPNG(width: 40, height: 40), imageName: "a.png")
        #expect(failure { try pkg.addStrip(imageData: data, imageName: "f.tif") } == message)
        #expect(pkg.project.strips.isEmpty)   // and nothing was added
    }
}

@Suite struct Provenance {
    @Test func theNoteSaysTheCropAndRowsThatWereUsedAndEachGelsGammaAndInvert() throws {
        var p = GelProject(image: "main.png", strict: false)
        p.crop = PixelRect(x0: 10.7, y0: 20.6, x1: 500.2, y1: 150.6)
        p.strips = [GelStrip(image: "other.png", top: 10.6, bottom: 150.4)]
        p.strips[0].display.gamma = 2
        p.strips[0].display.invert = true
        let info = ExportInfo.for(p, sourceSHA256: "aa", strips: [(sha256: "bb", scale: nil)], size: (width: 620, height: 160),
                                  stripSizes: [(width: 700, height: 220)]).description
        #expect(info.contains("crop 10,20,501,151"), "\(info)")   // what the export took: whole pixels, rounded outward
        #expect(info.contains("rows 11–150"), "\(info)")
        #expect(info.contains("gamma 2.0") && info.contains("inverted"), "\(info)")
        // a gel with the default gamma and no invert says neither; Strict doesn't apply them, so it doesn't either
        p.strips[0].display = DisplaySettings()
        let plain = ExportInfo.for(p, sourceSHA256: "aa", size: (620, 160), stripSizes: [(700, 220)]).description
        #expect(!(plain.components(separatedBy: "2. other.png").last ?? "").contains("gamma"))   // the gel's own part says neither
        p.strips[0].display.gamma = 2
        p.strict = true
        #expect(!ExportInfo.for(p, sourceSHA256: "aa", size: (620, 160), stripSizes: [(700, 220)]).description.contains("gamma"))
        // rows not set: the whole gel is named
        p.strips[0].top = nil; p.strips[0].bottom = nil
        #expect(ExportInfo.for(p, sourceSHA256: "aa", size: (620, 160), stripSizes: [(700, 220)]).description.contains("rows 0–220"))
    }
}

// MARK: lane labels at an angle

@Suite struct LabelAngle {
    private static let plain = "Ladder|first sample|second sample|third sample|last sample name"
    private static let grouped = "Ladder|DMSO control{first sample|second sample}|Drug 125{third sample|last sample name}"
    /// Labels of several lines, under groups.
    private static let multiLine = "Ladder|DMSO{first\\nsample|second sample}|Drug 125{third\\nsample\\nmore|last}"
    /// Five lanes (centres about 50, 150, 250, 350, 450 of a 500 px gel) with a group row over the lane labels and a title.
    private func project(angle: Double, labels: String = LabelAngle.grouped, laneRowTitle: String? = nil) -> GelProject {
        var p = GelProject(image: "a.png")
        GelOps.setDividers(&p, xs: [100, 200, 300, 400], imageWidth: 500, imageHeight: 200)
        _ = GelOps.applyQuickLabels(&p, text: labels)
        p.title = "Title"
        p.rows[0].name = laneRowTitle
        GelOps.setLabelAngle(&p, angle)
        return p
    }
    private func layout(_ p: GelProject) -> FigureLayout { FigureLayoutEngine.layout(p, imageWidth: 500, imageHeight: 200) }
    private func laneTexts(_ l: FigureLayout) -> [FigureText] { l.texts.filter { if case .laneLabel = $0.role { true } else { false } } }
    private func groupTexts(_ l: FigureLayout) -> [FigureText] { l.texts.filter { if case .groupLabel = $0.role { true } else { false } } }
    private let angles = [10.0, 30, 45, 60, 80, 90]

    @Test func modelClampsLoadsAndRoundTrips() throws {
        var p = GelProject(image: "a.png")
        p.rows = [LabelRow(type: .lanes, labels: ["a", "b"]), LabelRow(type: .groups, groups: [LabelGroup(text: "g", lanes: [1, 2])]),
                  LabelRow(type: .lanes, labels: ["c"])]
        #expect(p.labelAngle == 0)
        let set = GelOps.setLabelAngle(&p, 45)
        #expect(set && p.rows.map(\.rotation) == [45, 0, 45] && p.labelAngle == 45)   // every row of lane labels, never the group row
        let back = try JSONDecoder().decode(GelProject.self, from: try GelProject.encoder().encode(p))
        #expect(back == p && back.labelAngle == 45)
        for (given, stored) in [(120.0, 120.0), (-5, 355), (90, 90), (0.5, 0.5), (400, 40), (360, 0)] {
            GelOps.setLabelAngle(&p, given)
            #expect(p.labelAngle == stored, "\(given)")
        }
        GelOps.setLabelAngle(&p, 30)
        let notANumber = GelOps.setLabelAngle(&p, .nan)
        #expect(!notANumber && p.labelAngle == 30)   // not a number: nothing changes
        var none = GelProject(image: "b.png")
        let nowhere = GelOps.setLabelAngle(&none, 45)
        #expect(!nowhere && none.labelAngle == 0)   // no lane labels yet
        // an angle outside the range is brought into it when a project is read
        let text = "{\"image\":\"a.png\",\"rows\":[{\"type\":\"lanes\",\"labels\":[\"a\"],\"rotation\":200},{\"type\":\"lanes\",\"labels\":[\"b\"],\"rotation\":-30}]}"
        let read = try JSONDecoder().decode(GelProject.self, from: Data(text.utf8))
        #expect(read.rows.map(\.rotation) == [200, 330])
        let flat = String(decoding: try GelProject.encoder().encode(GelProject(image: "c.png")), as: UTF8.self)
        #expect(!flat.contains("\"rotation\""))
    }

    @Test func retypingTheLabelsKeepsTheAngle() {
        var p = project(angle: 60)
        _ = GelOps.applyQuickLabels(&p, text: "Strain: ladder|WT{0{L|P}|50{L|P}}")
        #expect(p.labelAngle == 60 && p.rows.filter { $0.type == .lanes }.allSatisfy { $0.rotation == 60 })
    }

    @Test func angleZeroStaysFlatAndCentredOnTheLane() {
        let p = project(angle: 0)
        let l = layout(p)
        for (i, t) in laneTexts(l).enumerated() {
            #expect(t.rotation == 0 && t.align == .center)
            #expect(abs(t.bounds.midX - l.point(x: p.lanes.centers[i], y: 0).x) < 0.01)
        }
    }

    @Test func theRowsAboveKeepTheirNormalGapAboveTheHighestCorner() throws {
        // from the highest corner of any lane label up to the group row's underline: the same at every angle
        func gap(_ angle: Double, _ labels: String) throws -> Double {
            let l = layout(project(angle: angle, labels: labels))
            let top = try #require(laneTexts(l).map(\.bounds.minY).min())
            let underline = try #require(l.lines.first?.points.first?.y)
            return top - underline
        }
        for labels in [Self.grouped, Self.multiLine] {
            let flat = try gap(0, labels)
            #expect(abs(flat - (GelProject().style.rowGapPt + 1.2)) < 1e-6)   // the usual gap, plus the underline's own rise
            for a in angles {
                let g = try gap(a, labels)
                #expect(abs(g - flat) < 1e-6, "\(a)°: \(g) against \(flat)")
            }
        }
        // the group labels and the title move up with it: their distances from the underline and from each other are the same
        let flatLayout = layout(project(angle: 0))
        let flatGroup = try #require(groupTexts(flatLayout).first), flatTitle = try #require(flatLayout.texts.first { $0.role == .title })
        for a in angles {
            let l = layout(project(angle: a))
            let group = try #require(groupTexts(l).first), title = try #require(l.texts.first { $0.role == .title })
            let underline = try #require(l.lines.first?.points.first?.y), flatUnderline = try #require(flatLayout.lines.first?.points.first?.y)
            #expect(abs((group.bounds.maxY - underline) - (flatGroup.bounds.maxY - flatUnderline)) < 1e-6, "\(a)°")
            #expect(abs((group.bounds.minY - title.bounds.maxY) - (flatGroup.bounds.minY - flatTitle.bounds.maxY)) < 1e-6, "\(a)°")
        }
    }

    @Test func theLowestPointSitsWhereHorizontalDescendersDo() {
        // measured up from the gel, every label's lowest corner is where a flat label's descenders end: one line or several
        func rise(_ p: GelProject) -> [Double] {
            let l = layout(p)
            return laneTexts(l).map { l.gelRect.minY - $0.bounds.maxY }
        }
        for labels in [Self.plain, "Ladder|first\\nsample|second sample|third\\nsample\\nmore|last"] {
            let flat = rise(project(angle: 0, labels: labels))
            for a in angles {
                let tilted = rise(project(angle: a, labels: labels))
                #expect(zip(flat, tilted).allSatisfy { abs($0 - $1) < 1e-6 }, "\(a)°: \(tilted) against \(flat)")
            }
        }
    }

    @Test func theRightEndAndTheLeftSideStayInsideTheFigure() throws {
        let long = "A very long first label|second sample|third|fourth|a very long label on the last lane that runs far past the gel"
        for a in [15.0, 30, 45, 90] {
            let l = layout(project(angle: a, labels: long))
            let page = CGRect(origin: .zero, size: l.size)
            for t in l.texts { #expect(page.contains(t.bounds), "\(a)°: \(t.string) \(t.bounds) outside \(page)") }
            #expect(l.texts.allSatisfy { $0.bounds.minX >= 2.2 - 1e-6 && $0.bounds.minY >= 2.2 - 1e-6 && $0.bounds.maxX <= l.size.width - 2.2 + 1e-6 })
        }
        // a label that runs past the gel's right edge widens the figure
        let l = layout(project(angle: 30, labels: long))
        #expect(l.size.width > l.gelRect.maxX + 20)
        let last = try #require(laneTexts(l).last)
        #expect(last.bounds.maxX > l.gelRect.maxX)
    }

    @Test func atNinetyDegreesTheLabelIsCentredOnTheLane() {
        for labels in [Self.plain, "Ladder|first\\nsample|two\\nlines|a|b"] {
            let p = project(angle: 90, labels: labels)
            let l = layout(p)
            for (i, t) in laneTexts(l).enumerated() {
                let cap = Typesetter.metrics(t.font).capHeight
                #expect(t.rotation == 90 && t.align == .left)
                // the text's middle line (half a cap height above its baseline, the baseline being to the right) runs through the lane's centre
                #expect(abs((t.origin.x - cap / 2) - l.point(x: p.lanes.centers[i], y: 0).x) < 1e-6, "lane \(i + 1)")
            }
        }
    }

    @Test func aTiltedLabelStartsAtItsLanesCentreAndRises() {
        let p = project(angle: 45)
        let l = layout(p)
        for (i, t) in laneTexts(l).enumerated() {
            let cap = Typesetter.metrics(t.font).capHeight
            let x = l.point(x: p.lanes.centers[i], y: 0).x
            // O = A + (c/2)(sin t, cos t): the anchor A, where the label starts, is on the lane's centre
            #expect(abs((t.origin.x - cap / 2 * sin(45 * .pi / 180)) - x) < 1e-6 && t.rotation == 45 && t.align == .left)
        }
    }

    @Test func aClickIsTestedAgainstTheRotatedBox() throws {
        let l = layout(project(angle: 45))
        let t = try #require(laneTexts(l).first { $0.string == "first sample" })
        // the box is a rotated rectangle inside the axis-aligned bounds, and its middle is in it
        let corners = t.box
        #expect(corners.count == 4 && corners.allSatisfy { t.bounds.insetBy(dx: -1e-6, dy: -1e-6).contains($0) })
        let middle = CGPoint(x: corners.map(\.x).reduce(0, +) / 4, y: corners.map(\.y).reduce(0, +) / 4)
        #expect(t.contains(middle) && t.contains(t.origin))
        // the corners of the bounds around a rising label are empty: a click there misses it
        #expect(!t.contains(CGPoint(x: t.bounds.minX + 0.5, y: t.bounds.minY + 0.5)))
        #expect(!t.contains(CGPoint(x: t.bounds.maxX - 0.5, y: t.bounds.maxY - 0.5)))
        // flat text: the box is its bounds
        let flat = try #require(laneTexts(layout(project(angle: 0))).first)
        #expect(flat.contains(CGPoint(x: flat.bounds.midX, y: flat.bounds.midY)) && !flat.contains(CGPoint(x: flat.bounds.minX - 1, y: flat.bounds.midY)))
        #expect(flat.box.map(\.x).min().map { abs($0 - flat.bounds.minX) < 1e-6 } == true)
    }

    @Test func theRowTitleStaysFlatLeftOfTheRowsLeftmostPoint() throws {
        let flat = layout(project(angle: 0, laneRowTitle: "ID")), tilted = layout(project(angle: 45, laneRowTitle: "ID"))
        let title = try #require(tilted.texts.first { $0.role == .rowName(row: 0) })
        let flatTitle = try #require(flat.texts.first { $0.role == .rowName(row: 0) })
        #expect(title.rotation == 0 && title.align == .right)
        let leftmost = try #require(laneTexts(tilted).map(\.bounds.minX).min())
        #expect(abs(title.origin.x - (leftmost - 3.5)) < 1e-6)
        // on the baseline a flat lane label would have
        #expect(abs((tilted.gelRect.minY - title.origin.y) - (flat.gelRect.minY - flatTitle.origin.y)) < 1e-6)
    }
}

// MARK: group labels at an angle

@Suite struct GroupLabelAngle {
    /// Five lanes (centres 50, 150, 250, 350, 450 of a 500 px gel): a row of group labels on the gel, over lanes 2–3 and 4–5, with
    /// a row of lane labels above it and a title.
    private func project(angle: Double, underline: Bool = true, rowTitle: String? = nil) -> GelProject {
        var p = GelProject(image: "a.png")
        GelOps.setDividers(&p, xs: [100, 200, 300, 400], imageWidth: 500, imageHeight: 200)
        p.rows = [LabelRow(type: .groups, name: rowTitle, groups: [LabelGroup(text: "DMSO control", lanes: [2, 3]), LabelGroup(text: "Drug 125", lanes: [4, 5])],
                           rotation: angle, underline: underline),
                  LabelRow(type: .lanes, labels: ["a", "b", "c", "d", "e"])]
        p.title = "Title"
        return p
    }
    private func layout(_ p: GelProject) -> FigureLayout { FigureLayoutEngine.layout(p, imageWidth: 500, imageHeight: 200) }
    private func groups(_ l: FigureLayout) -> [FigureText] { l.texts.filter { if case .groupLabel = $0.role { true } else { false } } }
    private func lanes(_ l: FigureLayout) -> [FigureText] { l.texts.filter { if case .laneLabel = $0.role { true } else { false } } }
    private let angles = [10.0, 45, 90, 135, 180, 225, 270, 315]

    @Test func eachGroupRowKeepsItsOwnAngleInTheFile() throws {
        var p = GelProject(image: "a.png")
        p.rows = [LabelRow(type: .groups, groups: [LabelGroup(text: "g", lanes: [1, 2])]), LabelRow(type: .lanes, labels: ["a", "b"]),
                  LabelRow(type: .groups, groups: [LabelGroup(text: "h", lanes: [1, 2])])]
        #expect(GelOps.setRowAngle(&p, row: 0, 45) && GelOps.setRowAngle(&p, row: 2, -90))
        #expect(p.rows.map(\.rotation) == [45, 0, 270] && p.labelAngle == 0)   // each its own; the lane labels' angle is another thing
        let json = try GelProject.encoder().encode(p)
        let rows = try #require((try JSONSerialization.jsonObject(with: json) as? [String: Any])?["rows"] as? [[String: Any]])
        #expect(rows[0]["rotation"] as? Double == 45 && rows[1]["rotation"] == nil && rows[2]["rotation"] as? Double == 270)
        #expect(try JSONDecoder().decode(GelProject.self, from: json) == p)
        // 0 ..< 360 whatever is typed or was in the file; not a number, a lane row and no such row change nothing
        for (given, stored) in [(405.0, 45.0), (-45, 315), (360, 0), (720.5, 0.5)] {
            GelOps.setRowAngle(&p, row: 0, given)
            #expect(p.rows[0].rotation == stored, "\(given)")
        }
        let before = p
        #expect(!GelOps.setRowAngle(&p, row: 0, .nan) && !GelOps.setRowAngle(&p, row: 1, 30) && !GelOps.setRowAngle(&p, row: 3, 30) && p == before)
        let text = #"{"image":"a.png","rows":[{"type":"groups","groups":[{"text":"g","lanes":[1,2]}],"rotation":-30},{"type":"groups","groups":[],"rotation":NaN}]}"#
        let read = try GelProject.decoder().decode(GelProject.self, from: Data(text.utf8))
        #expect(read.rows.map(\.rotation) == [330, 0])
        // the lane labels' angle still stands on lane rows only
        GelOps.setLabelAngle(&p, 60)
        #expect(p.rows.map(\.rotation) == [0.5, 60, 270])
    }

    @Test func retypingTheLabelsKeepsEachGroupRowsAngle() {
        var p = project(angle: 0)
        _ = GelOps.applyQuickLabels(&p, text: "Strain: ladder|WT{0{L|P}|50{L|P}}")   // two group rows: WT over 0 and 50
        let groupRows = p.rows.indices.filter { p.rows[$0].type == .groups }
        #expect(groupRows.count == 2)
        GelOps.setRowAngle(&p, row: groupRows[0], 45)
        GelOps.setRowAngle(&p, row: groupRows[1], 90)
        _ = GelOps.applyQuickLabels(&p, text: "Strain: ladder|WT{0{L|P}|50{L|P}|100{L|P}}")
        #expect(p.rows.filter { $0.type == .groups }.map(\.rotation) == [45, 90])
        _ = GelOps.applyQuickLabels(&p, text: "ladder|WT{L|P}")   // a row less: the first one's angle stays
        #expect(p.rows.filter { $0.type == .groups }.map(\.rotation) == [45])
    }

    @Test func angleZeroIsAsBefore() {
        let l = layout(project(angle: 0))
        for t in groups(l) { #expect(t.rotation == 0 && t.align == .center) }
        let spans = [200.0, 400]   // the middle of lanes 2–3 and of lanes 4–5
        for (t, x) in zip(groups(l), spans) { #expect(abs(t.bounds.midX - l.point(x: x, y: 0).x) < 0.01) }
    }

    @Test func theLowestPointSitsWhereTheFlatTextEndsAboveTheUnderline() {
        // measured up from the gel, the lowest corner of every group label is where flat group text ends: its descenders, the
        // underline's rise above the gel included
        func rise(_ p: GelProject) -> [Double] { let l = layout(p); return groups(l).map { l.gelRect.minY - $0.bounds.maxY } }
        for underline in [true, false] {
            let flat = rise(project(angle: 0, underline: underline))
            #expect(flat.allSatisfy { abs($0 - (underline ? 4.5 : 2.0)) < 1e-6 }, "\(flat)")
            for a in angles {
                let turned = rise(project(angle: a, underline: underline))
                #expect(zip(flat, turned).allSatisfy { abs($0 - $1) < 1e-6 }, "\(a)°: \(turned) against \(flat)")
            }
        }
    }

    @Test func theUnderlineStaysFlatUnderTheSpan() throws {
        let flat = layout(project(angle: 0)).lines.map { $0.points.map { [$0.x, $0.y] } }
        for a in angles {
            let l = layout(project(angle: a))
            #expect(l.lines.count == 2 && l.lines.allSatisfy { Set($0.points.map(\.y)).count == 1 }, "\(a)°")
            // the same line, in the same place under the span, relative to the gel
            let shift = l.gelRect.minX - layout(project(angle: 0)).gelRect.minX
            #expect(zip(flat, l.lines).allSatisfy { f, line in zip(f, line.points).allSatisfy { abs($0[0] + shift - $1.x) < 1e-6 } }, "\(a)°")
        }
    }

    @Test func theRowsAboveKeepTheirNormalGapAboveTheHighestCorner() throws {
        // from the highest corner of a group label up to the bottom of the lane labels above: the row gap, at every angle
        for a in [0.0] + angles {
            let l = layout(project(angle: a))
            let top = try #require(groups(l).map(\.bounds.minY).min()), bottom = try #require(lanes(l).map(\.bounds.maxY).max())
            #expect(abs((top - bottom) - GelProject().style.rowGapPt) < 1e-6, "\(a)°: \(top - bottom)")
        }
        // and the figure grows to take a tall rotated label in
        #expect(layout(project(angle: 90)).size.height > layout(project(angle: 0)).size.height)
    }

    @Test func theEndNearestTheGelSitsOverTheMiddleOfTheSpan() throws {
        let spans = [200.0, 400]
        for (angle, side) in [(90.0, 1.0), (270, -1)] {
            let l = layout(project(angle: angle))
            for (t, x) in zip(groups(l), spans) {
                let cap = Typesetter.metrics(t.font).capHeight
                // the text's middle line (half a cap height from its baseline) runs through the span's middle
                #expect(t.rotation == angle && t.align == .left && abs((t.origin.x - side * cap / 2) - l.point(x: x, y: 0).x) < 1e-6, "\(angle)°")
            }
        }
        let l = layout(project(angle: 45))
        for (t, x) in zip(groups(l), spans) {
            let cap = Typesetter.metrics(t.font).capHeight
            #expect(abs((t.origin.x - cap / 2 * sin(45 * .pi / 180)) - l.point(x: x, y: 0).x) < 1e-6)
        }
    }

    @Test func boundsAtNinetyAndTwoSeventyAreTheTextTurnedOnItsSide() throws {
        for a in [90.0, 270] {
            let l = layout(project(angle: a))
            let page = CGRect(origin: .zero, size: l.size)
            for t in groups(l) {
                let m = Typesetter.metrics(t.font), w = Typesetter.width(t.string, t.font)
                #expect(abs(t.bounds.width - (m.ascent + m.descent)) < 1e-6 && abs(t.bounds.height - w) < 1e-6, "\(a)°: \(t.bounds)")
                #expect(page.contains(t.bounds), "\(a)°: \(t.bounds) outside \(page)")
            }
        }
        for a in [30.0, 45, 135, 180, 225, 315] {
            let l = layout(project(angle: a))
            for t in groups(l) {
                #expect(CGRect(origin: .zero, size: l.size).contains(t.bounds) && t.box.count == 4, "\(a)°")
                #expect(t.box.allSatisfy { t.bounds.insetBy(dx: -1e-6, dy: -1e-6).contains($0) }, "\(a)°")
            }
        }
    }

    @Test func aClickIsTestedAgainstTheRotatedBox() throws {
        let l = layout(project(angle: 45))
        let t = try #require(groups(l).first)
        let middle = CGPoint(x: t.box.map(\.x).reduce(0, +) / 4, y: t.box.map(\.y).reduce(0, +) / 4)
        #expect(t.contains(middle))
        // the corners of the bounds around a rising label are empty: a click there misses it
        #expect(!t.contains(CGPoint(x: t.bounds.minX + 0.5, y: t.bounds.minY + 0.5)))
        #expect(!t.contains(CGPoint(x: t.bounds.maxX - 0.5, y: t.bounds.maxY - 0.5)))
    }

    @Test func theRowTitleStaysFlatOnTheBaselineFlatGroupTextHas() throws {
        let flat = layout(project(angle: 0, rowTitle: "µM")), turned = layout(project(angle: 45, rowTitle: "µM"))
        let title = try #require(turned.texts.first { $0.role == .rowName(row: 0) })
        let flatTitle = try #require(flat.texts.first { $0.role == .rowName(row: 0) })
        #expect(title.rotation == 0 && title.align == .right)
        // left of the row's leftmost point: its turned labels and its underlines
        let left = try #require((groups(turned).map(\.bounds.minX) + turned.lines.compactMap { $0.points.map(\.x).min() }).min())
        #expect(abs(title.origin.x - (left - 3.5)) < 1e-6)
        // on the baseline a flat group label would have
        #expect(abs((turned.gelRect.minY - title.origin.y) - (flat.gelRect.minY - flatTitle.origin.y)) < 1e-6)
    }
}

// MARK: the command-line tool

/// The built tool, when there is one (`swift build` puts it next to the tests). The CLI tests are skipped without it.
private final class ProductsLocator {}
private let gelscribeBinary: URL? = {
    let mac = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    // next to the test bundle (wherever the build was put, a --scratch-path included), else in the package's own .build
    let built = Bundle(for: ProductsLocator.self).bundleURL.deletingLastPathComponent().appendingPathComponent("gelscribe")
    return ([built] + [".build/debug/gelscribe", ".build/arm64-apple-macosx/debug/gelscribe", ".build/x86_64-apple-macosx/debug/gelscribe"]
        .map { mac.appendingPathComponent($0) }).first { FileManager.default.isExecutableFile(atPath: $0.path) }
}()
let hasCLI = gelscribeBinary != nil

struct Ran {
    var status: Int32
    var crashed: Bool
    var out: String
    var err: String
}

func gelscribe(_ args: [String], in dir: URL) throws -> Ran {
    let p = Process()
    p.executableURL = gelscribeBinary
    p.arguments = args
    p.currentDirectoryURL = dir
    let o = Pipe(), e = Pipe()
    p.standardOutput = o
    p.standardError = e
    try p.run()
    let out = o.fileHandleForReading.readDataToEndOfFile(), err = e.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return Ran(status: p.terminationStatus, crashed: p.terminationReason == .uncaughtSignal,
               out: String(decoding: out, as: UTF8.self), err: String(decoding: err, as: UTF8.self))
}

/// A folder with synthetic gels in it (`gel.png`: 620×160 with eight lanes; `other.png`: 700×220), removed afterwards.
final class Bench {
    let dir = tempFolder("cli")
    init() throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let c = (0..<8).map { 60 + 70 * Double($0) }
        try gelPNG(width: 620, height: 160, lanes: c, bandRows: [60, 110]).write(to: file("gel.png"))
        try gelPNG(width: 700, height: 220, lanes: c.map { $0 + 37 }, bandRows: [90]).write(to: file("other.png"))
    }
    deinit { try? FileManager.default.removeItem(at: dir) }
    func file(_ name: String) -> URL { dir.appendingPathComponent(name) }
    @discardableResult func run(_ args: String...) throws -> Ran { try gelscribe(args, in: dir) }
    @discardableResult func run(_ args: [String]) throws -> Ran { try gelscribe(args, in: dir) }
    /// A project's `project.json` as a dictionary.
    func json(_ project: String) throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: Data(contentsOf: file(project).appendingPathComponent("project.json"))) as? [String: Any])
    }
    func projectBytes(_ project: String) throws -> Data { try Data(contentsOf: file(project).appendingPathComponent("project.json")) }
    /// A project with the gel with the lanes and, as gel 2, `other.png`.
    func twoGels(_ name: String = "P.gelscribe") throws {
        try run("new", "gel.png", "-o", name)
        let r = try run("edit", name, "--add-gel", "other.png")
        #expect(r.status == 0, "\(r.err)")
    }
}

@Suite(.enabled(if: hasCLI, "needs the built gelscribe")) struct CommandLineTool {
    @Test func newNeverReplacesAnExistingProject() throws {
        let b = try Bench()
        let first = try b.run("new", "gel.png", "-o", "P.gelscribe")
        #expect(first.status == 0)
        try b.run("edit", "P.gelscribe", "--title", "kept")
        let before = try b.projectBytes("P.gelscribe")
        try gelPNG(width: 300, height: 100).write(to: b.file("gel.png"))   // the image changed meanwhile
        let again = try b.run("new", "gel.png", "-o", "P.gelscribe")
        #expect(again.status == 1 && again.err.contains("already exists") && !again.crashed)
        #expect(try b.projectBytes("P.gelscribe") == before)
        #expect(try b.run("verify", "P.gelscribe").status == 0)   // still the image it was made with
    }

    @Test func optionsAreCheckedStrictlyAndNothingChangesOnAMistake() throws {
        let b = try Bench()
        try b.twoGels()
        let before = try b.projectBytes("P.gelscribe")
        let unknown = try b.run("edit", "P.gelscribe", "--bogus", "3")
        #expect(unknown.status == 2 && unknown.err.contains("unknown option --bogus"))
        #expect(try b.run("edit", "P.gelscribe", "--strict").status == 2)   // no value
        for bad in [["--strict", "maybe"], ["--strict", "yes"], ["--ticks", "nan"], ["--ticks", "inf"], ["--ticks", "1e300"], ["--ticks", "-5"],
                    ["--ticks", "9999"], ["--gel", "2", "--rows", "nan,3"], ["--gel", "2", "--rows", "150,10"], ["--gel", "2", "--scale", "0"],
                    ["--gel", "2", "--scale", "nan"], ["--gel", "2", "--shift", "inf"], ["--auto-lanes", "-1"], ["--auto-lanes", "2.5"],
                    ["--turn", "45"], ["--dividers", "95;165"], ["--dividers", "5000"], ["--crop", "1,2,x,4"], ["--fill", "300"],
                    ["--rotate", "nan"], ["--name", "x@nan"], ["--gel", "9", "--ticks", "5"], ["--order", "2,x"], ["--own-ladder", "maybe"]] {
            let r = try b.run(["edit", "P.gelscribe"] + bad)
            #expect(r.status == 1 && !r.crashed && !r.err.isEmpty && r.err.split(separator: "\n").count == 1, "\(bad): \(r.err)")
        }
        #expect(try b.projectBytes("P.gelscribe") == before)
        let off = try b.run("edit", "P.gelscribe", "--strict", "OFF")
        #expect(off.status == 0)
        #expect(try b.json("P.gelscribe")["strict"] as? Bool == false)
        let on = try b.run("edit", "P.gelscribe", "--strict", "On")
        let strictAgain = try b.json("P.gelscribe")["strict"] as? Bool
        #expect(on.status == 0 && strictAgain == true)
    }

    @Test func theOrderOfOptionsDoesNotMatter() throws {
        let b = try Bench()
        try b.twoGels("A.gelscribe")
        try b.twoGels("B.gelscribe")
        #expect(try b.run("edit", "A.gelscribe", "--strict", "off", "--gel", "2", "--scale", "1.02").status == 0)
        #expect(try b.run("edit", "B.gelscribe", "--gel", "2", "--scale", "1.02", "--strict", "off").status == 0)
        for name in ["A.gelscribe", "B.gelscribe"] {
            let o = try b.json(name), strip = (o["strips"] as! [[String: Any]])[0]
            // --strict with --gel 2 is gel 2's own setting; the gel with the lanes keeps its own
            #expect(strip["strict"] as? Bool == false && strip["scale"] as? Double == 1.02 && o["strict"] as? Bool == true, "\(name)")
        }
        // a gel that keeps its original pixels still refuses a stretch, whatever the order
        try b.twoGels("C.gelscribe")
        #expect(try b.run("edit", "C.gelscribe", "--gel", "2", "--scale", "1.02", "--strict", "on").status == 1)
        #expect(try b.run("edit", "C.gelscribe", "--strict", "on", "--gel", "2", "--scale", "1.02").status == 1)
    }

    @Test func gelsOnlyGoIntoProjectFolders() throws {
        let b = try Bench()
        try "{\"image\": \"gel.png\"}".write(to: b.file("config.json"), atomically: true, encoding: .utf8)
        let r = try b.run("edit", "config.json", "--add-gel", "other.png")
        #expect(r.status == 1 && r.err.contains("Gels can only be added to a .gelscribe project."))
        #expect(try String(contentsOf: b.file("config.json"), encoding: .utf8) == "{\"image\": \"gel.png\"}")
        // a bare config can still be edited, and nothing but its json is written
        #expect(try b.run("edit", "config.json", "--title", "t").status == 0)
        #expect(try String(contentsOf: b.file("config.json"), encoding: .utf8).contains("\"title\" : \"t\""))
    }

    @Test func formatsAreAllCheckedBeforeAnythingIsWritten() throws {
        let b = try Bench()
        try b.run("new", "gel.png", "-o", "P.gelscribe")
        let r = try b.run("render", "P.gelscribe", "--formats", "pdf,jpg", "-o", "fig")
        #expect(r.status == 1 && r.err.contains("unknown format jpg"))
        #expect(!FileManager.default.fileExists(atPath: b.file("fig.pdf").path))
        let ok = try b.run("render", "P.gelscribe", "--formats", "PDF,svg", "-o", "fig")
        #expect(ok.status == 0 && FileManager.default.fileExists(atPath: b.file("fig.pdf").path) && FileManager.default.fileExists(atPath: b.file("fig.svg").path))
        // never over the project's own image
        let over = try b.run("render", "P.gelscribe", "--formats", "png", "-o", "gel")
        #expect(over.status == 1 && over.err.contains("original image"))
        #expect(try Data(contentsOf: b.file("gel.png")) == (try GelPackage.read(from: b.file("P.gelscribe")).imageData))
    }

    @Test func projectNamesCountInAnyLetterCase() throws {
        let b = try Bench()
        #expect(try b.run("new", "gel.png", "-o", "Q.GelScribe").status == 0)
        let r = try b.run("edit", "Q.GelScribe", "--title", "t")
        let title = try b.json("Q.GelScribe")["title"] as? String
        #expect(r.status == 0 && title == "t")
        #expect(try b.run("new", "gel.png", "-o", "plain").status == 0)   // no extension at all: still a folder the tool can edit
        let plain = try b.run("edit", "plain", "--title", "u")
        let plainTitle = try b.json("plain")["title"] as? String
        #expect(plain.status == 0 && plainTitle == "u")
    }

    @Test func anUnreadableGelStopsRenderAndVerifyAndSaysWhich() throws {
        let b = try Bench()
        try b.twoGels()
        try Data("not an image".utf8).write(to: b.file("P.gelscribe/other.png"))
        for cmd in ["render", "verify"] {
            let r = try b.run(cmd, "P.gelscribe")
            #expect(r.status == 1 && r.err.contains("Gel 2's image (other.png) can't be read."), "\(cmd): \(r.err)")
        }
        #expect(try b.run("edit", "P.gelscribe", "--remove-gel", "2").status == 0)   // and it can be taken out
    }

    @Test func aQuarterTurnedGelIsMeasuredInItsTurnedSize() throws {
        let b = try Bench()
        try gelPNG(width: 160, height: 620, lanes: [50, 110], bandRows: [100, 300]).write(to: b.file("tall.png"))   // 620×160 once turned
        try b.run("new", "tall.png", "-o", "T.gelscribe")
        #expect(try b.run("edit", "T.gelscribe", "--turn", "270").status == 0)
        // lanes (so the ticks sit off the rotation centre), then ticks
        #expect(try b.run("edit", "T.gelscribe", "--dividers", "100,200,300,400", "--ticks", "60,110", "--no-snap").status == 0)
        let turned = try GelProject.decoder().decode(GelProject.self, from: b.projectBytes("T.gelscribe"))
        #expect(turned.turn == 3 && turned.ladder!.bands.map(\.y) == [60, 110])
        #expect(try b.run("edit", "T.gelscribe", "--strict", "off", "--rotate", "1.5").status == 0)
        let after = try GelProject.decoder().decode(GelProject.self, from: b.projectBytes("T.gelscribe"))
        var right = turned, wrong = turned
        for (q, w, h) in [(0, 620, 160), (1, 160, 620)] {
            var t = q == 0 ? right : wrong
            GelOps.setStrict(&t, false, imageWidth: w, imageHeight: h)
            GelOps.setRotation(&t, degrees: 1.5, imageWidth: w, imageHeight: h)
            if q == 0 { right = t } else { wrong = t }
        }
        #expect(after.ladder!.bands.map(\.y) == right.ladder!.bands.map(\.y))
        #expect(right.ladder!.bands.map(\.y) != wrong.ladder!.bands.map(\.y))   // the two sizes really do differ here
    }

    @Test func aSchemeWithPositionsIsFittedToTheTurnedImage() throws {
        let b = try Bench()
        try b.run("new", "gel.png", "-o", "A.gelscribe")   // 620×160
        try b.run("edit", "A.gelscribe", "--crop", "10,20,600,150", "--dividers", "95,165,235")
        try gelPNG(width: 160, height: 620).write(to: b.file("tall.png"))   // 620×160 once turned
        try b.run("new", "tall.png", "-o", "B.gelscribe")
        try b.run("edit", "B.gelscribe", "--turn", "270")
        #expect(try b.run("edit", "B.gelscribe", "--scheme-from", "A.gelscribe", "--with-positions").status == 0)
        #expect(try b.json("B.gelscribe")["crop"] as? [Double] == [10, 20, 600, 150])   // not squeezed into the unturned 160 wide
    }

    @Test func labelAngleIsCheckedStoredAndListedInHelp() throws {
        let b = try Bench()
        let help = try b.run("help")
        #expect(help.out.contains("--label-angle DEG"))
        try b.run("new", "gel.png", "-o", "P.gelscribe")
        try b.run("edit", "P.gelscribe", "--dividers", "95,165,235,305,375,445,515")
        let before = try b.projectBytes("P.gelscribe")
        let noLabels = try b.run("edit", "P.gelscribe", "--label-angle", "45")   // nothing to stand at an angle yet
        #expect(noLabels.status == 0 && noLabels.err.contains("no lane labels yet"))
        for bad in ["nan", "inf", "x", ""] {
            let r = try b.run("edit", "P.gelscribe", "--label-angle", bad)
            #expect(r.status == 1 && !r.crashed && r.err.split(separator: "\n").count == 1, "--label-angle \(bad): \(r.err)")
        }
        #expect(try b.projectBytes("P.gelscribe") == before)
        func rotations() throws -> [Double] {
            (try b.json("P.gelscribe")["rows"] as! [[String: Any]]).compactMap { $0["type"] as? String == "lanes" ? ($0["rotation"] as? Double ?? 0) : nil }
        }
        // typed in the same command, then kept when the labels are typed again, then back to flat
        let together = try b.run("edit", "P.gelscribe", "--label-angle", "45", "--labels", "µM: ladder|0{L|P}|50{L|P}|100{L|P}")
        let afterTogether = try rotations()
        #expect(together.status == 0 && afterTogether == [45])
        let retyped = try b.run("edit", "P.gelscribe", "--labels", "ladder|WT{L|P}")
        let afterRetyped = try rotations()
        #expect(retyped.status == 0 && afterRetyped == [45])
        let flat = try b.run("edit", "P.gelscribe", "--label-angle", "0")
        let afterFlat = try rotations()
        #expect(flat.status == 0 && afterFlat == [0])
        let drawn = try b.run("render", "P.gelscribe", "--formats", "svg", "-o", "fig")
        #expect(drawn.status == 0)
    }

    @Test func groupLabelAngleIsCheckedStoredAndListedInHelp() throws {
        let b = try Bench()
        #expect(try b.run("help").out.contains("--group-angle DEG"))
        try b.run("new", "gel.png", "-o", "P.gelscribe")
        try b.run("edit", "P.gelscribe", "--dividers", "95,165,235,305,375,445,515")
        let before = try b.projectBytes("P.gelscribe")
        let none = try b.run("edit", "P.gelscribe", "--group-angle", "45")   // no group labels to turn yet
        #expect(none.status == 0 && none.err.contains("no group labels yet"))
        for bad in ["nan", "inf", "x", ""] {
            let r = try b.run("edit", "P.gelscribe", "--group-angle", bad)
            #expect(r.status == 1 && !r.crashed && r.err.split(separator: "\n").count == 1, "--group-angle \(bad): \(r.err)")
        }
        #expect(try b.projectBytes("P.gelscribe") == before)
        func rotations(_ type: String) throws -> [Double] {
            (try b.json("P.gelscribe")["rows"] as! [[String: Any]]).compactMap { $0["type"] as? String == type ? ($0["rotation"] as? Double ?? 0) : nil }
        }
        // typed in the same command: every group row, and not the lane labels (which --label-angle sets)
        let together = try b.run("edit", "P.gelscribe", "--group-angle", "45", "--labels", "Strain, µM: ladder|WT{0{L|P}|50{L|P}}")
        var groupRows = try rotations("groups"), laneRows = try rotations("lanes")
        #expect(together.status == 0 && groupRows == [45, 45] && laneRows == [0], "\(together.err)")
        // a negative angle is brought into 0 to 360, and the labels typed again keep it
        #expect(try b.run("edit", "P.gelscribe", "--group-angle", "-90").status == 0)
        groupRows = try rotations("groups")
        #expect(groupRows == [270, 270])
        #expect(try b.run("edit", "P.gelscribe", "--label-angle", "30").status == 0)
        groupRows = try rotations("groups"); laneRows = try rotations("lanes")
        #expect(groupRows == [270, 270] && laneRows == [30])
        #expect(try b.run("edit", "P.gelscribe", "--labels", "Strain, µM: ladder|WT{0{L|P}|50{L|P}|100{L|P}}").status == 0)
        groupRows = try rotations("groups")
        #expect(groupRows == [270, 270])
        #expect(try b.run("edit", "P.gelscribe", "--group-angle", "0").status == 0)
        groupRows = try rotations("groups")
        let flatRows = (try b.json("P.gelscribe")["rows"] as! [[String: Any]]).filter { $0["type"] as? String == "groups" }
        #expect(groupRows == [0, 0] && flatRows.allSatisfy { $0["rotation"] == nil })
        let drawn = try b.run("render", "P.gelscribe", "--formats", "svg", "-o", "fig")
        #expect(drawn.status == 0)
    }

    @Test func helpListsOwnLadderAndOwnLadderIsPerGel() throws {
        let b = try Bench()
        let h = try b.run("help")
        #expect(h.status == 0 && h.out.contains("--own-ladder on|off"))
        try b.twoGels()
        #expect(try b.run("edit", "P.gelscribe", "--gel", "2", "--own-ladder", "on").status == 0)
        let json = try b.json("P.gelscribe")
        let strips = json["strips"] as! [[String: Any]]
        #expect(strips[0]["own_ladder"] as? Bool == true && json["own_ladder"] == nil)
        #expect(try b.run("edit", "P.gelscribe", "--own-ladder", "on").status == 0)   // without --gel: the gel with the lanes
        #expect(try b.json("P.gelscribe")["own_ladder"] as? Bool == true)
        #expect(try b.run("edit", "P.gelscribe", "--own-ladder", "off", "--gel", "2", "--own-ladder", "off").status == 2)   // twice
        #expect(try b.run("edit", "P.gelscribe", "--gel", "2", "--own-ladder", "off").status == 0)
        #expect((try b.json("P.gelscribe")["strips"] as! [[String: Any]])[0]["own_ladder"] == nil)
    }

    @Test func autoAlignRefusesABlankGelAndNothingIsSaved() throws {
        let b = try Bench()
        try gelPNG(width: 700, height: 220).write(to: b.file("blank.png"))
        try b.run("new", "gel.png", "-o", "P.gelscribe")
        try b.run("edit", "P.gelscribe", "--dividers", "95,165,235,305,375,445,515", "--add-gel", "blank.png")
        let before = try b.projectBytes("P.gelscribe")
        let r = try b.run("edit", "P.gelscribe", "--gel", "2", "--align", "auto")
        #expect(r.status == 1 && r.err.contains("Couldn't find Gel 2's lanes. Line it up by hand."), "\(r.err)")
        #expect(try b.projectBytes("P.gelscribe") == before)
        // lanes that are there still line up
        try b.run("edit", "P.gelscribe", "--remove-gel", "2", "--add-gel", "other.png")
        let ok = try b.run("edit", "P.gelscribe", "--gel", "2", "--align", "auto")
        #expect(ok.status == 0, "\(ok.err)")
    }

    @Test func eachGelHasItsOwnStrictAndTheLineHasAColor() throws {
        let b = try Bench()
        try b.twoGels()
        func strict() throws -> (lanes: Bool?, gel2: Bool?) {
            let o = try b.json("P.gelscribe")
            return (o["strict"] as? Bool, (o["strips"] as! [[String: Any]])[0]["strict"] as? Bool)
        }
        // a gel added from the command line starts with Keep original pixels off, the lanes gel keeps the project's setting
        #expect(try strict() == (true, false))
        // --strict with --gel N is that gel's own setting; without --gel it's the lanes gel's
        #expect(try b.run("edit", "P.gelscribe", "--gel", "2", "--strict", "on").status == 0)
        #expect(try strict() == (true, true))
        #expect(try b.run("edit", "P.gelscribe", "--strict", "off").status == 0)
        #expect(try strict() == (false, true))
        #expect(try b.run("edit", "P.gelscribe", "--gel", "1", "--strict", "on").status == 0)   // gel 1 has the lanes
        #expect(try strict() == (true, true))
        // the line between gels: black when it isn't in the file
        #expect(try b.json("P.gelscribe")["separator"] == nil)
        #expect(try b.run("edit", "P.gelscribe", "--separator", "WHITE").status == 0)
        #expect(try b.json("P.gelscribe")["separator"] as? String == "white")
        let before = try b.projectBytes("P.gelscribe")
        let bad = try b.run("edit", "P.gelscribe", "--separator", "red")
        #expect(bad.status == 1 && !bad.crashed && bad.err.contains("--separator wants black, white or a color like #ff3300"))
        #expect(try b.projectBytes("P.gelscribe") == before)
        #expect(try b.run("edit", "P.gelscribe", "--separator", "black").status == 0)
        #expect(try b.json("P.gelscribe")["separator"] == nil)
        let help = try b.run("help")
        #expect(help.out.contains("--separator black|white|#RRGGBB") && help.out.contains("--separator-width PT"))
        #expect(help.out.contains("--gel N") && help.out.contains("--strict on|off"))
    }

    @Test func autoAlignSaysWhenAGelThatKeepsItsPixelsWouldFitBetterStretched() throws {
        let b = try Bench()
        let c = (0..<8).map { 60 + 70 * Double($0) }
        try gelPNG(width: 700, height: 220, lanes: c.map { 1.1 * $0 + 37 }, bandRows: [90]).write(to: b.file("wide.png"))
        try b.run("new", "gel.png", "-o", "P.gelscribe")
        try b.run("edit", "P.gelscribe", "--dividers", "95,165,235,305,375,445,515", "--add-gel", "wide.png")
        // the new gel may stretch, so it's stretched into line with nothing to say
        let free = try b.run("edit", "P.gelscribe", "--gel", "2", "--align", "auto")
        let scale = ((try b.json("P.gelscribe")["strips"] as! [[String: Any]])[0]["scale"] as? Double) ?? 0
        #expect(free.status == 0 && abs(scale - 1.1) < 0.02 && !free.err.contains("Keep original pixels"), "\(free.err)")
        // keeping its pixels: a whole-pixel shift, and the note says how far off that leaves it
        let kept = try b.run("edit", "P.gelscribe", "--gel", "2", "--strict", "on", "--align", "auto")
        #expect(kept.status == 0 && kept.err.contains("Gel 2's lanes are 10") && kept.err.contains("farther apart") &&
                kept.err.contains("Turn off Keep original pixels for Gel 2 to stretch it."), "\(kept.err)")
        #expect(((try b.json("P.gelscribe")["strips"] as! [[String: Any]])[0]["scale"] as? Double) == 1)
    }

    @Test func eachGelHasItsOwnCropFromTheCommandLine() throws {
        let b = try Bench()
        try b.twoGels()   // the gel with the lanes is 620 × 160, gel 2 is 700 × 220
        func strip() throws -> [String: Any] { (try b.json("P.gelscribe")["strips"] as! [[String: Any]])[0] }
        func lanesCrop() throws -> PixelRect? { try GelPackage.read(from: b.file("P.gelscribe")).project.crop }
        // --crop with --gel N sets all four of that gel's edges, in its own pixels; the lanes gel's crop isn't touched
        let r = try b.run("edit", "P.gelscribe", "--gel", "2", "--crop", "30,20,650,200")
        #expect(r.status == 0, "\(r.err)")
        var s = try strip()
        #expect(s["left"] as? Double == 30 && s["top"] as? Double == 20 && s["right"] as? Double == 650 && s["bottom"] as? Double == 200)
        #expect(try lanesCrop() == nil)
        // --rows still works, and leaves the columns
        #expect(try b.run("edit", "P.gelscribe", "--gel", "2", "--rows", "40,140").status == 0)
        s = try strip()
        #expect(s["top"] as? Double == 40 && s["bottom"] as? Double == 140 && s["left"] as? Double == 30 && s["right"] as? Double == 650)
        // both in one command: the crop first, then the rows
        #expect(try b.run("edit", "P.gelscribe", "--gel", "2", "--rows", "50,60", "--crop", "10,10,300,100").status == 0)
        s = try strip()
        #expect(s["left"] as? Double == 10 && s["right"] as? Double == 300 && s["top"] as? Double == 50 && s["bottom"] as? Double == 60)
        // values past the image are clamped to it, as rows are
        #expect(try b.run("edit", "P.gelscribe", "--gel", "2", "--crop", "-5,0,9999,9999").status == 0)
        s = try strip()
        #expect(s["left"] as? Double == 0 && s["right"] as? Double == 700 && s["bottom"] as? Double == 220)
        // mistakes say so and change nothing
        let before = try b.projectBytes("P.gelscribe")
        for bad in ["300,20,100,200", "30,200,650,20", "50,50,50,90", "1,2,3", "a,b,c,d"] {
            let e = try b.run("edit", "P.gelscribe", "--gel", "2", "--crop", bad)
            #expect(e.status == 1 && !e.crashed && !e.err.isEmpty, "\(bad): \(e.err)")
        }
        let fit = try b.run("edit", "P.gelscribe", "--gel", "2", "--crop", "fit")
        #expect(fit.status == 1 && fit.err.contains("--crop fit is for the gel with the lanes"), "\(fit.err)")
        #expect(try b.projectBytes("P.gelscribe") == before)
        // without --gel, or naming the gel with the lanes, --crop is the lanes gel's crop, as before
        #expect(try b.run("edit", "P.gelscribe", "--crop", "10,10,600,150").status == 0)
        #expect(try lanesCrop() == PixelRect(x0: 10, y0: 10, x1: 600, y1: 150))
        #expect(try b.run("edit", "P.gelscribe", "--gel", "1", "--crop", "20,20,500,100").status == 0)
        #expect(try lanesCrop() == PixelRect(x0: 20, y0: 20, x1: 500, y1: 100))
        #expect(try strip()["left"] as? Double == 0)
        let help = try b.run("help")
        #expect(help.out.contains("--crop X0,Y0,X1,Y1|fit]   with --gel N: that gel's own crop"))
    }

    @Test func theGelWithTheLanesMovesSidewaysWithShift() throws {
        let b = try Bench()
        try b.twoGels()
        try b.run("edit", "P.gelscribe", "--dividers", "95,165,235,305,375,445,515")
        func state() throws -> (main: Double?, gel2: Double) {
            let o = try b.json("P.gelscribe")
            return (o["main_shift"] as? Double, (o["strips"] as! [[String: Any]])[0]["shift"] as! Double)
        }
        #expect(try b.run("edit", "P.gelscribe", "--gel", "2", "--align", "auto").status == 0)
        let lined = try state()
        #expect(lined.main == nil)   // where it was: nothing in the file
        // --shift with no --gel moves the gel with the lanes, in whole pixels, and no other gel moves
        #expect(try b.run("edit", "P.gelscribe", "--shift", "20.4").status == 0)
        var now = try state()
        #expect(now.main == 20 && now.gel2 == lined.gel2)
        // --gel naming the gel with the lanes is the same, and --gel 2 is gel 2's own place
        #expect(try b.run("edit", "P.gelscribe", "--gel", "1", "--shift", "-12").status == 0)
        now = try state()
        #expect(now.main == -12 && now.gel2 == lined.gel2)
        #expect(try b.run("edit", "P.gelscribe", "--gel", "2", "--shift", "5").status == 0)
        now = try state()
        #expect(now.main == -12 && now.gel2 == 5)
        // Auto-align lines gel 2 up with the lanes where gel 1 now sits: its place in the figure moves by gel 1's
        #expect(try b.run("edit", "P.gelscribe", "--shift", "30").status == 0)
        let aligned = try b.run("edit", "P.gelscribe", "--gel", "2", "--align", "auto")
        now = try state()
        #expect(aligned.status == 0 && now.main == 30 && abs(now.gel2 - (lined.gel2 + 30)) < 0.2, "\(now) from \(lined): \(aligned.err)")
        // the other options stay for stacked gels, a number that isn't one changes nothing, and 0 puts it back
        for bad in [["--rows", "10,20"], ["--scale", "1.01"], ["--align", "auto"]] {
            let r = try b.run(["edit", "P.gelscribe"] + bad)
            #expect(r.status == 1 && r.err.contains("for one of the stacked gels"), "\(bad): \(r.err)")
        }
        let before = try b.projectBytes("P.gelscribe")
        for bad in ["nan", "x", ""] { #expect(try b.run("edit", "P.gelscribe", "--shift", bad).status == 1, "--shift \(bad)") }
        #expect(try b.projectBytes("P.gelscribe") == before)
        #expect(try b.run("edit", "P.gelscribe", "--shift", "0").status == 0)
        #expect(try state().main == nil)
        #expect(try b.run("help").out.contains("--shift PX"))
    }

    @Test func theLineBetweenGelsTakesAColorAndAThickness() throws {
        let b = try Bench()
        try b.twoGels()
        func json() throws -> [String: Any] { try b.json("P.gelscribe") }
        // any #RRGGBB, with or without the #, in the short form, whatever the case: stored as #rrggbb
        for (given, stored) in [("#ff3300", "#ff3300"), ("FF3300", "#ff3300"), ("f30", "#ff3300"), ("#F30", "#ff3300"), ("#1A2B3C", "#1a2b3c")] {
            #expect(try b.run("edit", "P.gelscribe", "--separator", given).status == 0, "\(given)")
            #expect(try json()["separator"] as? String == stored, "\(given)")
        }
        #expect(try b.run("edit", "P.gelscribe", "--separator", "white").status == 0)
        #expect(try json()["separator"] as? String == "white")
        #expect(try b.run("edit", "P.gelscribe", "--separator", "#000000").status == 0)   // black by its number
        #expect(try json()["separator"] == nil)
        // a mistake says so and changes nothing
        let before = try b.projectBytes("P.gelscribe")
        for bad in ["#ff33", "#ff33001", "gg0000", "#", "", "red"] {
            let r = try b.run("edit", "P.gelscribe", "--separator", bad)
            #expect(r.status == 1 && !r.crashed && r.err.split(separator: "\n").count == 1, "--separator \(bad): \(r.err)")
        }
        #expect(try b.projectBytes("P.gelscribe") == before)
        // the thickness, 0.25 to 10 points; without one the line is as thick as the figure's lines and nothing is stored
        #expect(try json()["separator_width"] == nil)
        #expect(try b.run("edit", "P.gelscribe", "--separator-width", "2").status == 0)
        #expect(try json()["separator_width"] as? Double == 2)
        #expect(try b.run("edit", "P.gelscribe", "--separator-width", "0.25").status == 0)
        #expect(try json()["separator_width"] as? Double == 0.25)
        let kept = try b.projectBytes("P.gelscribe")
        for bad in ["0.2", "10.5", "0", "-1", "nan", "x", ""] {
            let r = try b.run("edit", "P.gelscribe", "--separator-width", bad)
            #expect(r.status == 1 && !r.crashed && r.err.contains("--separator-width wants points from 0.25 to 10"), "--separator-width \(bad): \(r.err)")
        }
        #expect(try b.projectBytes("P.gelscribe") == kept)
        // both in one command, and the figure is drawn with them: the note names the color
        #expect(try b.run("edit", "P.gelscribe", "--separator", "#ff3300", "--separator-width", "10").status == 0)
        let drawn = try b.run("render", "P.gelscribe", "--formats", "svg", "-o", "fig")
        #expect(drawn.status == 0)
        let svg = try String(contentsOf: b.file("fig.svg"), encoding: .utf8)
        #expect(svg.contains("with a #ff3300 line between each"), "the SVG's note")
    }

    @Test func ticksStayInsideTheirGelAndRowsAreValid() throws {
        let b = try Bench()
        try b.twoGels()
        try b.run("edit", "P.gelscribe", "--crop", "0,40,620,120")
        let r = try b.run("edit", "P.gelscribe", "--ticks", "10,100", "--no-snap")
        #expect(r.status == 0 && r.err.contains("moved to 40"), "\(r.err)")
        let bands = (try b.json("P.gelscribe")["ladder"] as! [String: Any])["bands"] as! [[String: Any]]
        #expect(bands.compactMap { $0["y"] as? Double } == [40, 100])
        #expect(try b.run("edit", "P.gelscribe", "--gel", "2", "--rows", "30,200").status == 0)
        let rows = (try b.json("P.gelscribe")["strips"] as! [[String: Any]])[0]
        #expect(rows["top"] as? Double == 30 && rows["bottom"] as? Double == 200)
        let bad = try b.run("edit", "P.gelscribe", "--gel", "2", "--rows", "150,10")
        #expect(bad.status == 1 && bad.err.contains("Rows must be top,bottom with top < bottom, inside 0–220."))
        // a project.json with backwards rows (edited by hand) loads with the whole gel and lines up without crashing
        var o = try b.json("P.gelscribe")
        var strips = o["strips"] as! [[String: Any]]
        strips[0]["top"] = 150; strips[0]["bottom"] = 10
        o["strips"] = strips
        try JSONSerialization.data(withJSONObject: o).write(to: b.file("P.gelscribe/project.json"))
        let loaded = try b.run("edit", "P.gelscribe", "--dividers", "95,165,235,305,375,445,515", "--gel", "2", "--align", "auto")
        #expect(!loaded.crashed, "\(loaded.err)")
        let fixed = (try b.json("P.gelscribe")["strips"] as! [[String: Any]])[0]
        #expect(fixed["top"] == nil && fixed["bottom"] == nil)
    }

    @Test func detectSurvivesTinyImagesAndBadCounts() throws {
        let b = try Bench()
        try gelPNG(width: 10, height: 30).write(to: b.file("tiny.png"))
        let tiny = try b.run("detect", "tiny.png")
        #expect(tiny.status == 0 && !tiny.crashed)
        for count in ["-2", "0", "1", "x", "99999"] {
            let r = try b.run("detect", "gel.png", "--lanes", count)
            #expect(r.status == 1 && !r.crashed, "--lanes \(count)")
        }
        #expect(try b.run("edit", "tiny.png", "--auto-lanes", "3").status == 1)   // not a project
    }

    @Test func floatingPointImagesAreRefusedByTheTool() throws {
        let b = try Bench()
        let px = [Float](repeating: 0.5, count: 256)
        let img = CGImage(width: 16, height: 16, bitsPerComponent: 32, bitsPerPixel: 32, bytesPerRow: 64,
                          space: CGColorSpace(name: CGColorSpace.genericGrayGamma2_2)!,
                          bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue | CGBitmapInfo.floatComponents.rawValue | CGBitmapInfo.byteOrder32Little.rawValue),
                          provider: CGDataProvider(data: Data(bytes: px, count: 1024) as CFData)!, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
        let out = NSMutableData()
        let dest = CGImageDestinationCreateWithData(out, UTType.tiff.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, img, nil)
        CGImageDestinationFinalize(dest)
        try (out as Data).write(to: b.file("f.tif"))
        let message = "This image has 32-bit floating-point values, which GelScribe doesn't support. Export it from your scanner's software as a 16-bit TIFF and open that."
        let made = try b.run("new", "f.tif", "-o", "F.gelscribe")
        #expect(made.status == 1 && made.err.contains(message) && !FileManager.default.fileExists(atPath: b.file("F.gelscribe").path))
        try b.run("new", "gel.png", "-o", "P.gelscribe")
        let added = try b.run("edit", "P.gelscribe", "--add-gel", "f.tif")
        #expect(added.status == 1 && added.err.contains(message))
        #expect(try b.run("detect", "f.tif").err.contains(message))
    }
}

@Test func cmykImagesAreRefusedWithAMessage() throws {
    let space = try #require(CGColorSpace(name: CGColorSpace.genericCMYK))
    let ctx = try #require(CGContext(data: nil, width: 40, height: 30, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                     bitmapInfo: CGImageAlphaInfo.none.rawValue))
    ctx.setFillColor(try #require(CGColor(colorSpace: space, components: [0, 0, 0, 0.5, 1])))
    ctx.fill(CGRect(x: 0, y: 0, width: 40, height: 30))
    let data = NSMutableData()
    let dest = try #require(CGImageDestinationCreateWithData(data, UTType.tiff.identifier as CFString, 1, nil))
    CGImageDestinationAddImage(dest, try #require(ctx.makeImage()), nil)
    #expect(CGImageDestinationFinalize(dest))
    #expect { try SourceImage(data: data as Data) } throws: { e in
        guard case .cmykImage = e as? GelKitError else { return false }
        return e.localizedDescription.contains("Convert it to RGB")
    }
}

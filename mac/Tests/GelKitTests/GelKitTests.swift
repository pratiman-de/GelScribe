import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import GelKit

/// An example gel (8-bit RGB PNG with rotation wedges) in TestData. It isn't in the public repository, so the tests
/// that need it are skipped when it's missing.
let fixtureURL = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    .deletingLastPathComponent().appendingPathComponent("TestData/gel.png")
let hasFixture = FileManager.default.fileExists(atPath: fixtureURL.path)

/// Raw pixel rows of an image, exactly as decoded (no color conversion).
struct RawPixels {
    let width: Int, height: Int, bytesPerPixel: Int, bytesPerRow: Int, bits: Int
    let littleEndian: Bool
    let data: Data
    init(_ img: CGImage) {
        width = img.width; height = img.height; bits = img.bitsPerComponent
        bytesPerPixel = img.bitsPerPixel / 8; bytesPerRow = img.bytesPerRow
        // 16-bit samples are big-endian unless the image says otherwise (PNG always is)
        let order = img.bitmapInfo.rawValue & CGBitmapInfo.byteOrderMask.rawValue
        littleEndian = order == CGBitmapInfo.byteOrder16Little.rawValue
        data = img.dataProvider!.data! as Data
    }
    /// Pixel values of a rectangle, `channels` components per pixel (skip bytes dropped).
    func region(x: Int, y: Int, w: Int, h: Int, channels: Int) -> [UInt16] {
        var out: [UInt16] = []
        out.reserveCapacity(w * h * channels)
        let bpc = bits / 8
        data.withUnsafeBytes { raw in
            for row in y..<(y + h) {
                for col in x..<(x + w) {
                    let base = row * bytesPerRow + col * bytesPerPixel
                    for c in 0..<channels {
                        if bpc == 2 {
                            let v = raw.loadUnaligned(fromByteOffset: base + 2 * c, as: UInt16.self)
                            out.append(littleEndian ? UInt16(littleEndian: v) : UInt16(bigEndian: v))
                        } else {
                            out.append(UInt16(raw[base + c]))
                        }
                    }
                }
            }
        }
        return out
    }
}

func decode(_ data: Data) -> CGImage {
    let src = CGImageSourceCreateWithData(data as CFData, nil)!
    return CGImageSourceCreateImageAtIndex(src, 0, nil)!
}

/// Finds where `needle` sits inside `hay` by matching its first row, then checks the whole block.
func locate(_ hay: RawPixels, _ needle: [UInt16], w: Int, h: Int, channels: Int) -> (Int, Int)? {
    let firstRow = Array(needle[0..<(w * channels)])
    for y in 0...(hay.height - h) {
        for x in 0...(hay.width - w) where hay.region(x: x, y: y, w: 1, h: 1, channels: channels) == Array(firstRow[0..<channels]) {
            if hay.region(x: x, y: y, w: w, h: 1, channels: channels) == firstRow,
               hay.region(x: x, y: y, w: w, h: h, channels: channels) == needle { return (x, y) }
        }
    }
    return nil
}

@Suite struct StrictMode {
    @Test(.enabled(if: hasFixture, "needs TestData/gel.png")) func rasterExportCarriesOriginalPixelsExactly() throws {
        let data = try Data(contentsOf: fixtureURL)
        let src = try SourceImage(data: data)
        var p = GelProject(image: "gel.png")
        p.crop = PixelRect(x0: 20, y0: 80, x1: 1940, y1: 1290)
        p.title = "WT"
        p.lanes.centers = [114, 272, 430, 589, 747, 905, 1063, 1222, 1380, 1538, 1696, 1855]
        p.lanes.width = 130
        p.rows = [LabelRow(type: .lanes, labels: ["", "L", "P", "L", "P", "L", "P", "L", "P", "L", "P", ""])]
        p.ladder = Ladder(lane: 1, bands: [LadderBand(y: 155, size: 250), LadderBand(y: 304, size: 100)])
        p.annotations = [BandAnnotation(y: 244, text: "Protein")]
        let w = WorkingImage(source: src, project: p)
        let layout = FigureLayoutEngine.layout(p, imageWidth: w.width, imageHeight: w.height)
        let gel = try #require(w.figureImage(project: p))
        let info = ExportInfo.for(p, sourceSHA256: src.sha256)
        let original = RawPixels(src.cgImage).region(x: 20, y: 80, w: 1920, h: 1210, channels: 3)
        for type in [UTType.png, .tiff] {
            let out = RawPixels(decode(try #require(FigureRenderer.rasterData(layout, gel: gel, type: type, info: info))))
            #expect(out.bits == 8)
            #expect(locate(out, original, w: 1920, h: 1210, channels: 3) != nil, "gel pixels changed in \(type.identifier)")
        }
    }

    @Test func sixteenBitGrayStaysSixteenBitAndExact() throws {
        // synthetic 16-bit gray TIFF with values across the whole range
        let W = 240, H = 160
        var px = [UInt16](repeating: 0, count: W * H)
        for i in px.indices { px[i] = UInt16(truncatingIfNeeded: (i &* 2_654_435_761) >> 7) }
        let provider = CGDataProvider(data: Data(bytes: px, count: px.count * 2) as CFData)!
        let img = CGImage(width: W, height: H, bitsPerComponent: 16, bitsPerPixel: 16, bytesPerRow: W * 2,
                          space: CGColorSpace(name: CGColorSpace.genericGrayGamma2_2)!,
                          bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue | CGBitmapInfo.byteOrder16Little.rawValue),
                          provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
        let tiff = FigureRenderer.encode(img, as: .tiff, dpi: 300, info: ExportInfo(title: "t", description: "t"))
        let src = try SourceImage(data: tiff)
        #expect(src.bitsPerComponent == 16)
        var p = GelProject(image: "synthetic.tiff")
        p.crop = PixelRect(x0: 10, y0: 10, x1: 230, y1: 150)
        p.rows = [LabelRow(type: .lanes, labels: ["A", "B"])]
        p.lanes.centers = [60, 170]
        let w = WorkingImage(source: src, project: p)
        let layout = FigureLayoutEngine.layout(p, imageWidth: w.width, imageHeight: w.height)
        let gel = try #require(w.figureImage(project: p))
        #expect(gel.bitsPerComponent == 16)
        let original = RawPixels(src.cgImage).region(x: 10, y: 10, w: 220, h: 140, channels: 1)
        for type in [UTType.png, .tiff] {
            let out = RawPixels(decode(try #require(FigureRenderer.rasterData(layout, gel: gel, type: type, info: ExportInfo(title: "", description: "")))))
            #expect(out.bits == 16, "\(type.identifier) lost bit depth")
            #expect(locate(out, original, w: 220, h: 140, channels: 1) != nil, "gel pixels changed in \(type.identifier)")
        }
        // the PDF embeds the gel at 16 bits per component too
        let pdf = FigureRenderer.pdf(layout, gel: gel, info: ExportInfo(title: "", description: ""))
        #expect(pdfImageBits(pdf) == [16])
    }

    @Test(.enabled(if: hasFixture, "needs TestData/gel.png")) func strictIgnoresPixelAdjustments() throws {
        let src = try SourceImage(data: try Data(contentsOf: fixtureURL))
        var p = GelProject(image: "x.png")
        p.rotateDeg = 3; p.display.gamma = 2; p.display.invert = true
        let strictGel = try #require(WorkingImage(source: src, project: p).figureImage(project: p))
        #expect(strictGel.width == src.width && strictGel.height == src.height)
        #expect(RawPixels(strictGel).region(x: 500, y: 300, w: 50, h: 50, channels: 3) ==
                RawPixels(src.cgImage).region(x: 500, y: 300, w: 50, h: 50, channels: 3))
        p.strict = false
        let adjusted = try #require(WorkingImage(source: src, project: p).figureImage(project: p))
        #expect(adjusted.bitsPerComponent == 8 && adjusted.colorSpace?.model == .monochrome)
    }
}

/// BitsPerComponent of every image XObject on page 1.
func pdfImageBits(_ data: Data) -> [Int] {
    guard let doc = CGPDFDocument(CGDataProvider(data: data as CFData)!), let page = doc.page(at: 1),
          let pageDict = page.dictionary else { return [] }
    var res: CGPDFDictionaryRef?, xobj: CGPDFDictionaryRef?
    guard CGPDFDictionaryGetDictionary(pageDict, "Resources", &res), let res,
          CGPDFDictionaryGetDictionary(res, "XObject", &xobj), let xobj else { return [] }
    final class Box { var bits: [Int] = [] }
    let box = Box()
    CGPDFDictionaryApplyBlock(xobj, { _, obj, info in
        var stream: CGPDFStreamRef?
        guard CGPDFObjectGetValue(obj, .stream, &stream), let stream, let d = CGPDFStreamGetDictionary(stream) else { return true }
        var bpc: CGPDFInteger = 0
        if CGPDFDictionaryGetInteger(d, "BitsPerComponent", &bpc) {
            Unmanaged<Box>.fromOpaque(info!).takeUnretainedValue().bits.append(Int(bpc))
        }
        return true
    }, Unmanaged.passUnretained(box).toOpaque())
    return box.bits
}

@Suite struct Labels {
    @Test func bracesBecomeTwoRows() {
        let r = QuickLabels.build(QuickLabels.parse("ladder|0{L|P}|125{L|P}|250{L|P}|500{L|P}|750{L|P}|1000{}").items, laneCount: 12)
        #expect(r.ladderLane == 1)
        #expect(r.rows.count == 2)
        #expect(r.rows[0].labels == ["ladder", "L", "P", "L", "P", "L", "P", "L", "P", "L", "P", ""])
        #expect(r.rows[1].groups.map(\.text) == ["0", "125", "250", "500", "750", "1000"])
        #expect(r.rows[1].groups.map(\.lanes) == [[2, 3], [4, 5], [6, 7], [8, 9], [10, 11], [12]])
        #expect(r.warnings.isEmpty)
    }

    @Test func plainLabelsStayOneRow() {
        let r = QuickLabels.build(["M", "WT", "K12A", "uncut"], laneCount: 4)
        #expect(r.rows.count == 1 && r.rows[0].labels == ["M", "WT", "K12A", "uncut"])
        #expect(r.ladderLane == 1)
    }

    @Test func spreadKeepsOrderAndMinimumGap() {
        let out = FigureLayoutEngine.spread1D([0, 1, 20, 21, 21.5, 50], sep: 7.7)
        for (a, b) in zip(out, out.dropFirst()) { #expect(b - a >= 7.7 - 1e-9) }
        #expect(abs(out[0] + out[1] - 1) < 1e-9)   // a colliding pair stays centred on its targets
    }
}

@Suite struct Geometry {
    @Test func dividersMakeLanesIncludingTheEdges() {
        var p = GelProject()
        GelOps.setDividers(&p, xs: [262, 391, 520, 649, 778, 907, 1036, 1165, 1294, 1423, 1552], imageWidth: 1816, imageHeight: 1312)
        #expect(p.laneCount == 12)
        #expect(abs(p.lanes.centers[0] - 198) < 3 && abs(p.lanes.centers[11] - 1617) < 3)
        p.lanes.outerLanes = false
        p.syncLaneCenters(imageWidth: 1816, imageHeight: 1312)
        #expect(p.laneCount == 10)
    }

    @Test func tiltedDividerCentersFollowTheCropTop() {
        var p = GelProject()
        p.lanes.dividers = [LaneDivider(xTop: 100, xBottom: 140, dotY: 50), LaneDivider(xTop: 300, xBottom: 340, dotY: 50)]
        p.lanes.outerLanes = false
        p.crop = PixelRect(x0: 0, y0: 500, x1: 400, y1: 1000)
        p.syncLaneCenters(imageWidth: 400, imageHeight: 1000)
        #expect(p.lanes.centers == [220])   // midpoint at y = 500: (120 + 320) / 2
    }
}

@Suite struct ExampleGel {
    @Test(.enabled(if: hasFixture, "needs TestData/gel.png")) func clicksSnapToLadderBandCenters() throws {
        let src = try SourceImage(data: try Data(contentsOf: fixtureURL))
        let w = WorkingImage(source: src, project: GelProject(image: "x"))
        let dark = w.darkness(bandsDark: true)
        let sloppy: [Double] = [150, 210, 300, 510, 640, 760, 860, 1050, 1210]
        let want: [Double] = [155, 206, 304, 515, 640, 765, 857, 1047, 1213]
        for (y, target) in zip(sloppy, want) {
            let s = try #require(Detect.snapBand(in: dark, x: 114, y: y, laneWidth: 130))
            #expect(abs(s - target) <= 2, "click at \(y) snapped to \(s), band center is \(target)")
        }
    }

    @Test func pythonConfigStillReads() throws {
        let cfg = fixtureURL.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("gel_labeling/configs/gel.json")
        guard FileManager.default.fileExists(atPath: cfg.path) else { return }
        let p = try JSONDecoder().decode(GelProject.self, from: Data(contentsOf: cfg))
        #expect(p.laneCount == 12)
        #expect(p.ladder?.bands.count == 10)
        #expect(p.annotations.first?.text.isEmpty == false)
        #expect(p.strict)   // configs without the key default to strict
    }
}

@Suite struct LadderAssignment {
    @Test func topDownGuessesAreMarkedAuto() {
        var l = Ladder(bands: [LadderBand(y: 10), LadderBand(y: 20), LadderBand(y: 30, ignore: true), LadderBand(y: 40)])
        l.assign(sizes: [250, 130, 100])
        #expect(l.bands.map(\.size) == [250, 130, nil, 100])
        #expect(l.bands.map(\.auto) == [true, true, false, true])
        #expect(l.warnings.isEmpty)
        l.bands[1].size = 300
        #expect(!l.warnings.isEmpty)   // 300 below 250
    }

    @Test func switchingGelSystemRelabelsBandForBand() throws {
        let pr = try #require(LadderLibrary.find("26617"))
        #expect(pr.id == "thermo-pageruler-prestained")
        var p = GelProject()
        p.ladder = Ladder(bands: (0..<10).map { LadderBand(y: Double(100 * $0)) })
        GelOps.applyPreset(&p, pr)   // first system: Tris-glycine 4–20%
        #expect(p.ladder?.bands.map(\.size) == [180, 130, 100, 70, 55, 40, 35, 25, 15, 10])
        p.ladder!.bands[2].auto = false   // user confirmed the 100 kDa band
        GelOps.applySystem(&p, preset: pr, system: try #require(pr.system(named: "bt-4-12-mops")))
        #expect(p.ladder?.bands.map(\.size) == [140, 115, 80, 65, 50, 40, 30, 25, 15, 10])
        #expect(p.ladder?.bands[2].auto == false && p.ladder?.bands[3].auto == true)
        GelOps.applySystem(&p, preset: pr, system: try #require(pr.system(named: "bt-10-mops")))   // 10 kDa runs off
        #expect(p.ladder?.bands.last?.size == nil)
        #expect(p.ladder?.system == "NuPAGE Bis-Tris 10%, MOPS")
    }

    @Test func sizeListParsing() {
        #expect(GelOps.parseSizes("250, 130 | 100 70;55 kDa") == [250, 130, 100, 70, 55])
    }
}

@Suite struct Packages {
    @Test(.enabled(if: hasFixture, "needs TestData/gel.png")) func roundTripKeepsTheImageByteForByte() throws {
        let pkg = try GelPackage.create(imageURL: fixtureURL)
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("gl-\(UUID().uuidString).gelscribe")
        defer { try? FileManager.default.removeItem(at: dir) }
        try pkg.write(to: dir)
        let imgURL = dir.appendingPathComponent(pkg.project.image)
        let before = try FileManager.default.attributesOfItem(atPath: imgURL.path)[.modificationDate] as? Date
        var again = try GelPackage.read(from: dir)
        #expect(again.imageData == (try Data(contentsOf: fixtureURL)))
        #expect(again.imageIntact == true)
        again.project.title = "changed"
        try again.write(to: dir)
        let after = try FileManager.default.attributesOfItem(atPath: imgURL.path)[.modificationDate] as? Date
        #expect(before == after)   // the image is write-once
        #expect(try GelPackage.read(from: dir).project.title == "changed")
    }
}

@Suite struct Rotation {
    @Test(.enabled(if: hasFixture, "needs TestData/gel.png")) func marksStayOnTheirBandsWhenTheImageTurns() throws {
        let src = try SourceImage(data: try Data(contentsOf: fixtureURL))
        var p = GelProject(image: "x", strict: false)
        p.lanes.centers = [114]
        p.lanes.width = 130
        p.ladder = Ladder(lane: 1, bands: [LadderBand(y: 304, size: 100), LadderBand(y: 857, size: 25)])
        GelOps.setRotation(&p, degrees: 5, imageWidth: src.width, imageHeight: src.height)
        let dark = WorkingImage(source: src, project: p).darkness(bandsDark: true)
        // where the ladder lane center went, per the same mapping
        let t = 5.0 * .pi / 180, cx = Double(src.width - 1) / 2, cy = Double(src.height - 1) / 2
        for b in p.ladder!.bands {
            let orig = b.size == 100 ? 304.0 : 857.0
            let x = cos(t) * (114 - cx) + sin(t) * (orig - cy) + cx
            let snapped = try #require(Detect.snapBand(in: dark, x: x, y: b.y, laneWidth: 130))
            #expect(abs(snapped - b.y) <= 3, "\(b.size!) kDa tick at \(b.y) but the band is at \(snapped)")
        }
    }

    @Test func strictIgnoresRotationAndMarksFollow() {
        var p = GelProject(image: "x", strict: false)
        p.ladder = Ladder(bands: [LadderBand(y: 300)])
        p.lanes.centers = [100]
        GelOps.setRotation(&p, degrees: 3, imageWidth: 2000, imageHeight: 1400)
        let turned = p.ladder!.bands[0].y
        GelOps.setStrict(&p, true, imageWidth: 2000, imageHeight: 1400)
        #expect(p.effectiveRotation == 0 && p.rotateDeg == 3)
        #expect(abs(p.ladder!.bands[0].y - 300) <= 1)          // back where it was on the unrotated original
        GelOps.setStrict(&p, false, imageWidth: 2000, imageHeight: 1400)
        #expect(abs(p.ladder!.bands[0].y - turned) <= 1)
    }

    @Test func levelingAngleMakesTheLineLevel() {
        // a band row dropping 55 px over 1600 px, drawn either way
        let a = (x: 200.0, y: 300.0), b = (x: 1800.0, y: 355.0)
        let d = GelOps.levelingAngle(from: a, to: b)
        #expect(abs(d - atan2(55, 1600) * 180 / .pi) < 1e-9)
        #expect(abs(GelOps.levelingAngle(from: b, to: a) - d) < 1e-9)
        // a lane edge leaning right going down → turn the other way
        #expect(GelOps.levelingAngle(from: (x: 100, y: 0), to: (x: 130, y: 1000)) < 0)
    }
}

@Suite struct Padding {
    @Test(.enabled(if: hasFixture, "needs TestData/gel.png")) func wedgesFoundButFlatBackgroundIsGel() throws {
        let src = try SourceImage(data: try Data(contentsOf: fixtureURL))
        let mask = WorkingImage.paddingMask(src.gray)
        let n = mask.filter { $0 }.count
        let total = mask.count
        // two corner triangles (~3% of the frame), not the clipped background (most of the frame)
        #expect(n > total / 100 && n < total / 20, "padding covers \(n) of \(total) pixels")
        #expect(mask[0] && mask[total - 1])                                   // top-left and bottom-right wedges
        #expect(!mask[700 * src.width + 1200])                                // plain background in the gel
        let w = WorkingImage(source: src, project: GelProject(image: "x"))
        #expect(abs(Double(w.background) * 255 - 225) < 2)                    // background is the gel's, not a band's
    }
}

@Suite struct Enhance {
    @Test(.enabled(if: hasFixture, "needs TestData/gel.png")) func useForExportMatchesTheEnhancedView() throws {
        let src = try SourceImage(data: try Data(contentsOf: fixtureURL))
        var p = GelProject(image: "x")   // strict
        let view = try #require(WorkingImage(source: src, project: p).viewImage(project: p, enhance: true))
        // what "Use for Export" does
        let lv = DisplaySettings.auto(for: src.gray, keeping: p.display)
        GelOps.setStrict(&p, false, imageWidth: src.width, imageHeight: src.height)
        p.display.black = lv.black; p.display.white = lv.white; p.display.gamma = 1
        p.fillPadding = false
        let fig = try #require(WorkingImage(source: src, project: p).figureImage(project: p))
        // compare a block of gel away from the corner wedges
        let a = RawPixels(view).region(x: 400, y: 300, w: 600, h: 500, channels: 1)
        let b = RawPixels(fig).region(x: 400, y: 300, w: 600, h: 500, channels: 1)
        #expect(a == b)
        #expect(Set(b).contains(255))   // the clipped 225 background now reads white
    }
}

@Suite struct Schemes {
    @Test func namingSchemeMovesToAnotherGelWithoutItsPositions() throws {
        var a = GelProject(image: "a.png", strict: false, title: "WT")
        GelOps.setDividers(&a, xs: [100, 200, 300], imageWidth: 400, imageHeight: 300)
        GelOps.applyQuickLabels(&a, text: "Ladder|0{L|P}|125{L}", groupRowName: "µM")
        a.ladder = Ladder(lane: 1, name: "PageRuler Prestained (26616/26617/26618)", sizes: [140, 115, 80],
                          system: "NuPAGE Bis-Tris 4–12%, MES", bands: [LadderBand(y: 50, size: 140)])
        a.annotations = [BandAnnotation(y: 80, text: "Protein")]
        a.style.setSize(9, for: .name)
        var b = GelProject(image: "b.png")   // strict, no lanes yet
        LabelScheme(from: a, positions: false).apply(to: &b, imageWidth: 800, imageHeight: 600)
        #expect(b.rows == a.rows && b.title == "WT" && b.annotations.first?.text == "Protein")
        #expect(b.ladder?.system == "NuPAGE Bis-Tris 4–12%, MES" && b.ladder?.sizes == [140, 115, 80])
        #expect(b.ladder?.bands.isEmpty == true && b.lanes.dividers.isEmpty)   // positions stay with gel a
        #expect(b.strict && b.image == "b.png")                                 // never the image or strict mode
        #expect(b.style.size(for: .name) == 9)
        var c = GelProject(image: "c.png")
        LabelScheme(from: a, positions: true).apply(to: &c, imageWidth: 400, imageHeight: 300)
        #expect(c.laneCount == 4 && c.ladder?.bands.count == 1)
    }
}

@Suite struct Shorthand {
    @Test func laneLabelsRoundTripAndWorkBeforeLanes() {
        let text = "µM: Ladder|0{L|P}|125{L|P}|250{L|P}|500{L|P}|750{L|P}|1000{}"
        var a = GelProject()
        GelOps.applyQuickLabels(&a, text: text)          // no lanes yet
        #expect(a.rows.count == 2 && a.rows[0].labels.count == 12)
        #expect(a.rows[1].name == "µM" && a.rows[1].groups.last?.text == "1000")
        #expect(QuickLabels.shorthand(a) == text)
        GelOps.setDividers(&a, xs: (1...11).map { Double($0 * 150) }, imageWidth: 1900, imageHeight: 1000)
        #expect(a.laneCount == 12)                      // placed afterwards; labels already line up
        var b = GelProject()
        GelOps.applyQuickLabels(&b, text: QuickLabels.shorthand(a))
        #expect(b.rows == a.rows)
    }
}

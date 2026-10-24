import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import GelKit

/// An 8-bit gray PNG of a made-up blot piece: `lanes` dark lanes (bands at `bandRows`) on a light background.
private func piecePNG(width: Int, height: Int, lanes: [Double], bandRows: [Int], value: (Int, Int) -> UInt8 = { _, _ in 230 }) -> Data {
    var px = [UInt8](repeating: 0, count: width * height)
    for y in 0..<height {
        for x in 0..<width {
            var v = Double(value(x, y))
            for c in lanes where abs(Double(x) - c) < 26 {   // rounded across, like a real lane
                let across = exp(-pow((Double(x) - c) / 10, 2) / 2)
                for r in bandRows { v -= 170 * across * exp(-pow(Double(y - r) / 4, 2) / 2) }
            }
            px[y * width + x] = UInt8(max(0, min(255, v.rounded())))
        }
    }
    let img = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: width,
                      space: CGColorSpace(name: CGColorSpace.genericGrayGamma2_2)!,
                      bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                      provider: CGDataProvider(data: Data(px) as CFData)!, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
    let out = NSMutableData()
    let dest = CGImageDestinationCreateWithData(out, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, img, nil)
    CGImageDestinationFinalize(dest)
    return out as Data
}

private let mainLanes = (0..<8).map { 60 + 70 * Double($0) }

/// A main piece and a strip whose lanes sit `shift` px further right and `scale` times as far apart.
private func cutBlot(shift: Double = 37, scale: Double = 1) throws -> GelPackage {
    let top = piecePNG(width: 620, height: 160, lanes: mainLanes, bandRows: [60, 110]) { x, y in UInt8(200 + (x * 7 + y * 3) % 40) }
    let stripLanes = mainLanes.map { scale * $0 + shift }
    let bottom = piecePNG(width: 700, height: 220, lanes: stripLanes, bandRows: [90]) { x, y in UInt8(190 + (x * 5 + y * 11) % 50) }
    var pkg = try GelPackage.create(imageData: top, imageName: "top.png")
    GelOps.setDividers(&pkg.project, xs: zip(mainLanes, mainLanes.dropFirst()).map { ($0 + $1) / 2 }, imageWidth: 620, imageHeight: 160)
    try pkg.addStrip(imageData: bottom, imageName: "bottom.png")
    return pkg
}

private func working(_ pkg: GelPackage) throws -> (main: WorkingImage, strips: [WorkingImage]) {
    let main = WorkingImage(source: try SourceImage(data: pkg.imageData), project: pkg.project)
    let strips = try pkg.project.strips.indices.map { i in
        WorkingImage(source: try SourceImage(data: pkg.stripData(i + 1)!), project: pkg.project.stripProject(i + 1))
    }
    return (main, strips)
}

private func stack(_ pkg: GelPackage, _ w: (main: WorkingImage, strips: [WorkingImage])) -> StackGeometry {
    StackGeometry(project: pkg.project, mainWidth: w.main.width, mainHeight: w.main.height,
                  stripSizes: w.strips.map { ($0.width, $0.height) })
}

@Suite struct Strips {
    @Test func quarterTurnsOnlyMovePixels() throws {
        let data = piecePNG(width: 50, height: 30, lanes: [10, 30], bandRows: [12]) { x, y in UInt8((x * 3 + y * 5) % 200) }
        let src = try SourceImage(data: data)
        let half = src.turned(2)
        #expect(half.cgImage.width == 50 && half.cgImage.height == 30 && half.cgImage.bitsPerComponent == 8)
        let a = RawPixels(src.cgImage).region(x: 0, y: 0, w: 50, h: 30, channels: 1)
        let b = RawPixels(half.cgImage).region(x: 0, y: 0, w: 50, h: 30, channels: 1)
        #expect(b == Array(a.reversed()))   // a half turn reads the pixels backwards
        let quarter = src.turned(1)
        #expect(quarter.cgImage.width == 30 && quarter.cgImage.height == 50)
        #expect(RawPixels(quarter.turned(3).cgImage).region(x: 0, y: 0, w: 50, h: 30, channels: 1) == a)
        #expect(half.gray.pixels == Array(src.gray.pixels.reversed()))
        #expect(half.sha256 == src.sha256 && half.data == src.data)   // the file is still the file
    }

    @Test func projectsWithStripsRoundTripAndOldOnesStillRead() throws {
        var pkg = try cutBlot()
        pkg.project.strips[0].turn = 2
        pkg.project.strips[0].top = 20; pkg.project.strips[0].bottom = 150
        GelOps.addTick(&pkg.project, y: 90, size: 40, lane: 1, gelCenterX: 310, strip: 1)
        pkg.project.annotations.append(BandAnnotation(y: 90, text: "Protein Y", strip: 1))
        let json = try GelProject.encoder().encode(pkg.project)
        let back = try JSONDecoder().decode(GelProject.self, from: json)
        #expect(back == pkg.project)
        let text = String(decoding: json, as: UTF8.self)
        #expect(text.contains("\"strips\"") && text.contains("\"strip\" : 1"))

        let old = try GelProject.encoder().encode(GelProject(image: "a.png"))
        #expect(!String(decoding: old, as: UTF8.self).contains("strips"))   // nothing new in a single-image file
        #expect(try JSONDecoder().decode(GelProject.self, from: old).strips.isEmpty)
    }

    @Test func packagesKeepEveryImageByteForByte() throws {
        let pkg = try cutBlot()
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("strips-\(UUID()).gelscribe")
        try pkg.write(to: dir)
        defer { try? FileManager.default.removeItem(at: dir) }
        let back = try GelPackage.read(from: dir)
        #expect(back.stripData(1) == pkg.stripData(1) && back.imageData == pkg.imageData)
        #expect(back.stripIntact(1) == true && back.imageIntact == true)
        var again = back
        try again.addStrip(imageData: pkg.stripData(1)!, imageName: "bottom.png")
        #expect(again.project.strips.map(\.image) == ["bottom.png", "bottom_1.png"])   // names never collide
    }

    @Test func theStackMapsPiecesBothWays() throws {
        let pkg = try cutBlot()
        let w = try working(pkg)
        let g = stack(pkg, w)
        #expect(g.pieces.count == 2 && g.separator >= 1)
        let strip = try #require(g.piece(strip: 1))
        #expect(strip.top == g.pieces[0].bottom + Double(g.separator) && strip.bottom == g.crop.y1)
        let p = strip.toPiece(x: 100, y: strip.top + 30)
        #expect(p.x == 100 && p.y == 30)   // no alignment yet
        let f = strip.toFigure(x: p.x, y: p.y)
        #expect(f.x == 100 && f.y == strip.top + 30)
        #expect(g.piece(atFigureY: strip.top + 1)?.strip == 1 && g.piece(atFigureY: 5)?.strip == nil)
    }

    @Test func autoAlignFindsTheShiftAndTheStretch() throws {
        var pkg = try cutBlot(shift: 37, scale: 1.02)
        pkg.project.strict = false
        let w = try working(pkg)
        let r = try #require(StripAlign.suggest(mainCenters: pkg.project.lanes.centers, strip: w.strips[0], bandsDark: true, allowScale: true))
        #expect(abs(r.scale - 1.02) < 0.005 && abs(r.shift - 37) < 3, "\(r)")
        #expect(r.worst < 2)
        let strict = try #require(StripAlign.suggest(mainCenters: pkg.project.lanes.centers, strip: w.strips[0], bandsDark: true, allowScale: false))
        #expect(strict.scale == 1 && strict.shift == strict.shift.rounded() && strict.worst > r.worst)
    }

    @Test func strictStacksKeepBothOriginals() throws {
        var pkg = try cutBlot(shift: 37)
        pkg.project.strips[0].strict = nil   // no setting of its own: it follows the lanes gel, which keeps its original pixels
        pkg.project.strips[0].shift = 37
        pkg.project.strips[0].top = 40; pkg.project.strips[0].bottom = 140
        let w = try working(pkg)
        let g = stack(pkg, w)
        let gel = try #require(StripStack.figureImage(main: w.main, strips: w.strips, project: pkg.project, stack: g))
        let c = g.crop
        #expect(gel.width == Int(c.width) && gel.height == Int(c.height) && gel.bitsPerComponent == 8)
        let out = RawPixels(gel)
        // the main image's crop, untouched
        let main = RawPixels(w.main.source.cgImage).region(x: Int(c.x0), y: Int(c.y0), w: Int(c.width), h: 160 - Int(c.y0), channels: 1)
        #expect(out.region(x: 0, y: 0, w: Int(c.width), h: 160 - Int(c.y0), channels: 1) == main)
        // a black line, then the strip's rows 40–140, 37 px to the right, untouched
        let piece = try #require(g.piece(strip: 1))
        let lineRow = Int(g.pieces[0].bottom - c.y0)
        #expect(Set(out.region(x: 0, y: lineRow, w: Int(c.width), h: g.separator, channels: 1)) == [0])
        let stripRows = RawPixels(w.strips[0].source.cgImage).region(x: Int(c.x0) + 37, y: 40, w: Int(c.width), h: 100, channels: 1)
        #expect(out.region(x: 0, y: Int(piece.top - c.y0), w: Int(c.width), h: 100, channels: 1) == stripRows)
        // and the PNG export carries the same pixels
        let lay = FigureLayoutEngine.layout(pkg.project, imageWidth: w.main.width, imageHeight: w.main.height, stack: g)
        let raster = try #require(FigureRenderer.raster(lay, gel: gel))
        let k = 1 / lay.ptPerPx
        let gx = Int((lay.gelRect.minX * k).rounded()), gy = Int((lay.gelRect.minY * k).rounded())
        #expect(RawPixels(raster).region(x: gx, y: gy + Int(piece.top - c.y0), w: Int(c.width), h: 100, channels: 1) == stripRows)
    }

    @Test func strictRefusesMixedPixelFormats() throws {
        let gray = try SourceImage(data: piecePNG(width: 40, height: 20, lanes: [20], bandRows: [10]))
        let rgbCtx = CGContext(data: nil, width: 40, height: 20, bitsPerComponent: 8, bytesPerRow: 0,
                               space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        rgbCtx.setFillColor(CGColor(red: 0.5, green: 0.5, blue: 0.5, alpha: 1)); rgbCtx.fill(CGRect(x: 0, y: 0, width: 40, height: 20))
        let msg = StripStack.strictMismatch(main: gray.cgImage, strip: rgbCtx.makeImage()!)
        #expect(msg?.contains("RGB") == true)
        #expect(StripStack.strictMismatch(main: gray.cgImage, strip: gray.cgImage) == nil)
    }

    @Test func stripTicksAndNamesGoInTheirStrip() throws {
        var pkg = try cutBlot()
        GelOps.addTick(&pkg.project, y: 60, size: nil, lane: 1, gelCenterX: 310)
        GelOps.addTick(&pkg.project, y: 110, size: nil, lane: 1, gelCenterX: 310)
        GelOps.addTick(&pkg.project, y: 90, size: nil, lane: 1, gelCenterX: 310, strip: 1)
        pkg.project.ladder!.assign(sizes: [140, 80, 40])   // top to bottom through the stack
        #expect(pkg.project.ladder!.bands.map(\.size) == [140, 80, 40])
        #expect(GelOps.suggestedSize(pkg.project, forY: 150, strip: 1, preset: nil) == nil)
        pkg.project.ladder!.sizes = [140, 80, 40, 30]
        #expect(GelOps.suggestedSize(pkg.project, forY: 150, strip: 1, preset: nil) == 30)
        #expect(GelOps.suggestedSize(pkg.project, forY: 20, strip: 1, preset: nil) == 40)
        pkg.project.annotations.append(BandAnnotation(y: 90, text: "Protein Y", marker: .tick, strip: 1))
        let w = try working(pkg)
        let g = stack(pkg, w)
        let lay = FigureLayoutEngine.layout(pkg.project, imageWidth: w.main.width, imageHeight: w.main.height, stack: g)
        let piece = try #require(g.piece(strip: 1))
        let stripTop = lay.point(x: 0, y: piece.top).y, stripBottom = lay.point(x: 0, y: piece.bottom).y
        let forty = try #require(lay.texts.first { $0.string == "40" })
        #expect(forty.bounds.midY > stripTop && forty.bounds.midY < stripBottom)
        let name = try #require(lay.texts.first { $0.string == "Protein Y" })
        #expect(name.bounds.midY > stripTop && name.bounds.midY < stripBottom)
        #expect(abs(lay.size.height - lay.gelRect.maxY) < 30 && lay.gelRect.height > 160 * lay.ptPerPx)
        // without the stack, a strip's marks stay out rather than landing in the wrong place
        let alone = FigureLayoutEngine.layout(pkg.project, imageWidth: w.main.width, imageHeight: w.main.height)
        #expect(!alone.texts.contains { $0.string == "Protein Y" || $0.string == "40" })
    }

    @Test func provenanceListsEveryStrip() throws {
        var pkg = try cutBlot()
        pkg.project.strips[0].turn = 2
        pkg.project.strips[0].shift = 12
        let info = ExportInfo.for(pkg.project, sourceSHA256: "aaa", strips: [(sha256: "bbb", scale: nil)])
        #expect(info.description.contains("2. bottom.png sha256 bbb") && info.description.contains("turned 180°"))
        #expect(info.description.contains("shifted 12 px") && info.description.contains("2 separately scanned gels, top to bottom"),
                "\(info.description)")
        #expect(info.description.contains("1. top.png, as above"))
        // in the order they're stacked
        pkg.project.mainPosition = 1
        let below = ExportInfo.for(pkg.project, sourceSHA256: "aaa", strips: [(sha256: "bbb", scale: nil)]).description
        #expect(below.contains("1. bottom.png sha256 bbb") && below.contains("2. top.png, as above"), "\(below)")
    }

    @Test func theGelWithTheLanesCanSitBelowAnother() throws {
        var pkg = try cutBlot()
        pkg.project.mainPosition = 1   // the strip on top
        GelOps.addTick(&pkg.project, y: 90, size: 40, lane: 1, gelCenterX: 310, strip: 1)
        GelOps.addTick(&pkg.project, y: 60, size: 80, lane: 1, gelCenterX: 310)
        let w = try working(pkg)
        let g = stack(pkg, w)
        let c = pkg.project.effectiveCrop(width: 620, height: 160)
        #expect(g.pieces.map(\.strip) == [1, nil])
        // the gel with the lanes keeps its own rows; the strip stacks upward from it
        let main = try #require(g.piece(strip: nil)), top = try #require(g.piece(strip: 1))
        #expect(main.top == c.y0 && main.bottom == c.y1)
        #expect(top.bottom == c.y0 - Double(g.separator) && g.crop.y0 == top.top && g.crop.y1 == c.y1)
        #expect(abs(top.toFigure(x: 0, y: top.toPiece(x: 0, y: top.top + 17).y).y - (top.top + 17)) < 1e-9)
        // ticks read top to bottom through the stack: the strip's first
        #expect(pkg.project.stackKey(1, 90) < pkg.project.stackKey(nil, 60))
        let gel = try #require(StripStack.figureImage(main: w.main, strips: w.strips, project: pkg.project, stack: g))
        #expect(gel.height == Int(g.crop.height.rounded()))
        let lay = FigureLayoutEngine.layout(pkg.project, imageWidth: 620, imageHeight: 160, stack: g)
        let forty = try #require(lay.texts.first { $0.string == "40" }), eighty = try #require(lay.texts.first { $0.string == "80" })
        #expect(forty.bounds.midY < eighty.bounds.midY)
    }

    @Test func movingAGelTakesItsTicksAndNames() throws {
        var pkg = try cutBlot()
        try pkg.addStrip(imageData: pkg.stripData(1)!, imageName: "third.png")
        GelOps.addTick(&pkg.project, y: 30, size: nil, lane: 1, gelCenterX: 310, strip: 1)
        GelOps.addTick(&pkg.project, y: 50, size: nil, lane: 1, gelCenterX: 310, strip: 2)
        GelOps.addTick(&pkg.project, y: 70, size: nil, lane: 1, gelCenterX: 310)
        pkg.project.annotations.append(BandAnnotation(y: 50, text: "C", strip: 2))
        #expect(pkg.project.stackOrder == [nil, 1, 2])
        GelOps.moveGel(&pkg.project, from: 2, to: 0)   // third.png to the top
        #expect(pkg.project.stackOrder == [1, nil, 2] && pkg.project.mainSlot == 1)
        #expect(pkg.project.strips.map(\.image) == ["third.png", "bottom.png"])
        // each mark still points at its own gel, under that gel's new number
        let bands = pkg.project.ladder!.bands
        #expect(bands.first { $0.y == 50 }?.strip == 1 && bands.first { $0.y == 30 }?.strip == 2 && bands.first { $0.y == 70 }?.strip == nil)
        #expect(pkg.project.annotations.map(\.strip) == [1])
        // sizes go top to bottom through the new order
        pkg.project.assignLadder(sizes: [100, 50, 20])
        let sized = pkg.project.ladder!.bands
        #expect(sized.first { $0.strip == 1 }?.size == 100 && sized.first { $0.strip == nil }?.size == 50 && sized.first { $0.strip == 2 }?.size == 20)
        #expect(pkg.project.ladderWarnings.isEmpty)
        // round trip, and nonsense orders change nothing
        let back = try JSONDecoder().decode(GelProject.self, from: try GelProject.encoder().encode(pkg.project))
        #expect(back.mainPosition == 1 && back.stackOrder == [1, nil, 2])
        let before = pkg.project
        GelOps.reorder(&pkg.project, [0, 0, 1])
        #expect(pkg.project == before)
    }

    @Test func removingAGelAboveTheLanesKeepsTheOrder() throws {
        var pkg = try cutBlot()
        try pkg.addStrip(imageData: pkg.stripData(1)!, imageName: "third.png")
        pkg.project.mainPosition = 2   // bottom.png, third.png, then the gel with the lanes
        GelOps.removeStrip(&pkg.project, 1)
        #expect(pkg.project.strips.map(\.image) == ["third.png"] && pkg.project.stackOrder == [1, nil])
    }

    @Test func halfTurnsCarryMarksAndQuarterTurnsDropThem() throws {
        var pkg = try cutBlot()
        GelOps.addTick(&pkg.project, y: 30, size: 40, lane: 1, gelCenterX: 310, strip: 1)
        pkg.project.strips[0].top = 20; pkg.project.strips[0].bottom = 200
        let before = pkg.project
        GelOps.turn(&pkg.project, strip: 1, by: 2, width: 700, height: 220)
        #expect(pkg.project.strips[0].turn == 2 && pkg.project.ladder!.bands[0].y == 189)
        #expect(pkg.project.strips[0].top == 20 && pkg.project.strips[0].bottom == 200)
        GelOps.turn(&pkg.project, strip: 1, by: 2, width: 700, height: 220)
        #expect(pkg.project == before)
        GelOps.turn(&pkg.project, strip: 1, by: 1, width: 700, height: 220)
        #expect(pkg.project.ladder!.bands.isEmpty && pkg.project.strips[0].top == nil)

        var main = try cutBlot().project
        let dividers = main.lanes.dividers
        GelOps.turn(&main, strip: nil, by: 2, width: 620, height: 160)
        GelOps.turn(&main, strip: nil, by: 2, width: 620, height: 160)
        #expect(main.lanes.dividers.map(\.xTop) == dividers.map(\.xTop) && main.turn == 0)
    }

    @Test func namesStayWhereTheyWerePutUnlessAPieceIsCut() throws {
        // one image: a name outside the crop is still drawn, as it always was
        var single = try cutBlot().project
        single.strips = []
        single.crop = PixelRect(x0: 0, y0: 40, x1: 620, y1: 130)
        single.annotations = [BandAnnotation(y: 20, text: "Above", marker: .tick)]
        let one = StackGeometry(project: single, mainWidth: 620, mainHeight: 160, stripSizes: [])
        #expect(one.nameY(strip: nil, y: 20) == 20 && one.figureY(strip: nil, y: 20) == nil)
        let lay = FigureLayoutEngine.layout(single, imageWidth: 620, imageHeight: 160, stack: one)
        #expect(lay.texts.contains { $0.string == "Above" })
        // with strips, a name only shows inside its own piece; elsewhere it would point at another piece's bands
        let pkg = try cutBlot()
        let w = try working(pkg)
        let g = stack(pkg, w)
        #expect(g.nameY(strip: nil, y: 20) == 20 && g.nameY(strip: nil, y: 200) == nil)
        #expect(g.nameY(strip: 1, y: 90) != nil && g.nameY(strip: 2, y: 90) == nil)
    }

    @Test func removingAStripRenumbersTheRest() throws {
        var pkg = try cutBlot()
        try pkg.addStrip(imageData: pkg.stripData(1)!, imageName: "third.png")
        GelOps.addTick(&pkg.project, y: 30, size: 40, lane: 1, gelCenterX: 310, strip: 1)
        GelOps.addTick(&pkg.project, y: 50, size: 30, lane: 1, gelCenterX: 310, strip: 2)
        pkg.project.annotations.append(BandAnnotation(y: 50, text: "C", strip: 2))
        GelOps.removeStrip(&pkg.project, 1)
        #expect(pkg.project.strips.map(\.image) == ["third.png"])
        #expect(pkg.project.ladder!.bands.map(\.strip) == [1] && pkg.project.annotations.map(\.strip) == [1])
    }
}

// MARK: several gels, version 2: each gel's own Keep original pixels, and the line between gels

/// An 8-bit gray PNG of `value(x, y)` everywhere.
private func rampPNG(width: Int, height: Int, value: (Int, Int) -> UInt8) -> Data {
    piecePNG(width: width, height: height, lanes: [], bandRows: [], value: value)
}

/// A 16-bit gray PNG of `value(x, y)`, or an 8-bit RGB one when `color` is given.
private func storedPNG(width: Int, height: Int, wide: Bool = false, color: (UInt8, UInt8, UInt8)? = nil, wideColor: Bool = false,
                       value: (Int, Int) -> Int = { x, y in (x * 37 + y * 91) % 60000 + 100 }) -> Data {
    let img: CGImage
    if wideColor {   // 16-bit RGB, a texture in each channel
        var px = [UInt8](repeating: 0, count: width * height * 8)
        for y in 0..<height { for x in 0..<width {
            for c in 0..<3 {
                let v = UInt16(truncatingIfNeeded: value(x + 7 * c, y) + 5000 * c)
                px[(y * width + x) * 8 + c * 2] = UInt8(v >> 8); px[(y * width + x) * 8 + c * 2 + 1] = UInt8(v & 255)   // big-endian
            }
        } }
        img = CGImage(width: width, height: height, bitsPerComponent: 16, bitsPerPixel: 64, bytesPerRow: width * 8,
                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                      bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue | CGBitmapInfo.byteOrder16Big.rawValue),
                      provider: CGDataProvider(data: Data(px) as CFData)!, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
    } else if let color {
        let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        ctx.setFillColor(CGColor(red: Double(color.0) / 255, green: Double(color.1) / 255, blue: Double(color.2) / 255, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        img = ctx.makeImage()!
    } else {
        var px = [UInt8](repeating: 0, count: width * height * 2)
        for y in 0..<height { for x in 0..<width {
            let v = UInt16(value(x, y)); px[(y * width + x) * 2] = UInt8(v >> 8); px[(y * width + x) * 2 + 1] = UInt8(v & 255)   // big-endian
        } }
        img = CGImage(width: width, height: height, bitsPerComponent: 16, bitsPerPixel: 16, bytesPerRow: width * 2,
                      space: CGColorSpace(name: CGColorSpace.genericGrayGamma2_2)!,
                      bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue | CGBitmapInfo.byteOrder16Big.rawValue),
                      provider: CGDataProvider(data: Data(px) as CFData)!, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
    }
    let out = NSMutableData()
    let dest = CGImageDestinationCreateWithData(out, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, img, nil)
    CGImageDestinationFinalize(dest)
    return out as Data
}

/// A project of `top` (620 wide) with `strip` added as gel 2 (rows 40-140, shift 37, stretched `scale`; its columns are the ones under the
/// main image's), its own Keep original pixels as given.
private func twoGels(top: Data, strip: Data, keepStrip: Bool?, scale: Double = 1) throws -> GelPackage {
    var pkg = try GelPackage.create(imageData: top, imageName: "top.png")
    try pkg.addStrip(imageData: strip, imageName: "bottom.png")
    pkg.project.strips[0].strict = keepStrip
    pkg.project.strips[0].top = 40; pkg.project.strips[0].bottom = 140
    pkg.project.strips[0].shift = 37; pkg.project.strips[0].scale = scale
    return pkg
}

private func figure(_ pkg: GelPackage) throws -> (fig: StackedFigure, w: (main: WorkingImage, strips: [WorkingImage])) {
    let w = try working(pkg)
    return (StackedFigure(project: pkg.project, main: w.main, strips: w.strips), w)
}

@Suite struct SeveralGelsVersion2 {
    @Test func eachGelHasItsOwnStrictAndTheLineCanBeWhite() throws {
        var pkg = try cutBlot()
        // a gel added now starts with Keep original pixels off; the gel with the lanes keeps the project's setting
        #expect(pkg.project.strips[0].strict == false && pkg.project.strict)
        #expect(pkg.project.isStrict(gel: nil) && !pkg.project.isStrict(gel: 1))
        pkg.project.separatorWhite = true
        let json = try GelProject.encoder().encode(pkg.project)
        let obj = try #require(JSONSerialization.jsonObject(with: json) as? [String: Any])
        #expect(obj["separator"] as? String == "white" && obj["strict"] as? Bool == true)
        #expect((obj["strips"] as? [[String: Any]])?[0]["strict"] as? Bool == false)
        #expect(try JSONDecoder().decode(GelProject.self, from: json) == pkg.project)
        // black, and a gel with no setting of its own, leave nothing in the file: old projects read as before
        pkg.project.separatorWhite = false; pkg.project.strips[0].strict = nil
        let plain = try #require(JSONSerialization.jsonObject(with: try GelProject.encoder().encode(pkg.project)) as? [String: Any])
        #expect(plain["separator"] == nil && (plain["strips"] as? [[String: Any]])?[0]["strict"] == nil)
        let old = try JSONDecoder().decode(GelProject.self, from: Data(#"{"image":"a.png","strict":false,"strips":[{"image":"b.png"}]}"#.utf8))
        #expect(old.strips[0].strict == nil && !old.isStrict(gel: 1) && !old.separatorWhite)
        var again = old
        again.strict = true
        #expect(again.isStrict(gel: 1) && again.effectiveAlignment(1).scale == 1)   // follows the lanes gel
    }

    @Test func settingStrictForOneGelLeavesTheOthersAndMovesItsMarks() throws {
        var p = try cutBlot().project
        p.strict = true; p.strips[0].rotateDeg = 3
        GelOps.addTick(&p, y: 60, size: 40, lane: 1, gelCenterX: 310, strip: nil)
        GelOps.addTick(&p, y: 90, size: 20, lane: 1, gelCenterX: 310, strip: 1)
        let sizes: [(width: Int, height: Int)?] = [(700, 220)]
        let free = p.ladder!.bands.first { $0.strip == 1 }!.y
        GelOps.setStrict(&p, true, gel: 1, imageWidth: 620, imageHeight: 160, stripSizes: sizes)   // gel 2 keeps its pixels: no rotation
        #expect(p.strips[0].strict == true && p.strict && p.ladder!.bands.first { $0.strip == nil }!.y == 60)
        #expect(p.ladder!.bands.first { $0.strip == 1 }!.y != free)
        GelOps.setStrict(&p, false, gel: 1, imageWidth: 620, imageHeight: 160, stripSizes: sizes)
        #expect(p.strips[0].strict == false && p.strict && abs(p.ladder!.bands.first { $0.strip == 1 }!.y - free) <= 1)
        // the lanes gel's own setting moves the gels that follow it, and only them
        p.strips[0].strict = nil
        GelOps.setStrict(&p, false, imageWidth: 620, imageHeight: 160, stripSizes: sizes)
        #expect(!p.strict && p.strips[0].strict == nil && !p.isStrict(gel: 1))
        GelOps.setStrict(&p, true, gel: 9, imageWidth: 620, imageHeight: 160, stripSizes: sizes)   // no such gel: nothing changes
        #expect(!p.strict && p.strips[0].strict == nil)
    }

    @Test func aMixedStackKeepsTheStrictGelsValuesAndStretchesTheOther() throws {
        let top = piecePNG(width: 620, height: 160, lanes: mainLanes, bandRows: [60, 110]) { x, y in UInt8(200 + (x * 7 + y * 3) % 40) }
        let ramp = rampPNG(width: 700, height: 220) { x, _ in UInt8(255 * x / 700) }
        // the lanes gel keeps its pixels, gel 2 doesn't: it's stretched 2% and its display range is in its pixels
        var pkg = try twoGels(top: top, strip: ramp, keepStrip: false, scale: 1.02)
        pkg.project.strips[0].display.black = 0.4
        var (fig, w) = try figure(pkg)
        #expect(fig.strictProblem == nil)
        var gel = try #require(fig.gel)
        let c = fig.stack.crop, piece = try #require(fig.stack.piece(strip: 1))
        #expect(gel.bitsPerComponent == 8 && gel.colorSpace?.model == .monochrome)
        let out = RawPixels(gel)
        let rows = 160 - Int(c.y0)
        #expect(out.region(x: 0, y: 0, w: Int(c.width), h: rows, channels: 1)
                == RawPixels(w.main.source.cgImage).region(x: Int(c.x0), y: Int(c.y0), w: Int(c.width), h: rows, channels: 1))
        let at = Int(piece.top - c.y0) + 50
        for x in [100, 300, 500] {   // column x shows the gel's column 1.02 x + 37 (its display range: below 0.4 is black)
            let source = 255 * (1.02 * Double(x) + 37) / 700, shown = max(0, (source / 255 - 0.4) / 0.6 * 255)
            let got = Double(out.region(x: x, y: at, w: 1, h: 1, channels: 1)[0])
            #expect(abs(got - shown) <= 2.5, "x \(x): \(got) vs \(shown)")
        }
        // keeping its pixels instead: whole pixels, no stretch, and the display range stays on screen
        pkg.project.strips[0].strict = true
        (fig, w) = try figure(pkg)
        gel = try #require(fig.gel)
        let kept = RawPixels(gel).region(x: 0, y: at, w: Int(c.width), h: 1, channels: 1)
        let original = RawPixels(w.strips[0].source.cgImage).region(x: Int(c.x0) + 37, y: 40 + 50, w: Int(c.width), h: 1, channels: 1)
        #expect(kept == original)
    }

    @Test func aMixedStackIsStoredLikeTheGelsThatKeepTheirPixels() throws {
        let strip8 = rampPNG(width: 700, height: 220) { x, y in UInt8((x * 7 + y * 13) % 251) }   // no flat stretches for the wedge detector
        // 16-bit gray in the lanes gel: the 8-bit gel goes in as 8-bit value x 257, the 16-bit values untouched
        var pkg = try twoGels(top: storedPNG(width: 620, height: 160, wide: true), strip: strip8, keepStrip: false)
        var (fig, w) = try figure(pkg)
        var gel = try #require(fig.gel)
        let c = fig.stack.crop, piece = try #require(fig.stack.piece(strip: 1))
        #expect(gel.bitsPerComponent == 16 && gel.colorSpace?.model == .monochrome)
        var out = RawPixels(gel)
        #expect(out.region(x: 0, y: 0, w: Int(c.width), h: 160 - Int(c.y0), channels: 1)
                == RawPixels(w.main.source.cgImage).region(x: Int(c.x0), y: Int(c.y0), w: Int(c.width), h: 160 - Int(c.y0), channels: 1))
        let wanted = RawPixels(w.strips[0].source.cgImage).region(x: Int(c.x0) + 37, y: 40, w: Int(c.width), h: 100, channels: 1).map { $0 * 257 }
        let got16 = out.region(x: 0, y: Int(piece.top - c.y0), w: Int(c.width), h: 100, channels: 1)
        #expect(out.region(x: 0, y: Int(piece.top - c.y0), w: Int(c.width), h: 100, channels: 1) == wanted)
        #expect(fig.info().description.contains("converted to 16-bit gray (values times 257)"))
        // a color gel that doesn't keep its pixels makes the output RGB at the kept gel's depth (a flat color: one value everywhere);
        // the gray gel's values are copied to all three channels
        pkg = try twoGels(top: storedPNG(width: 620, height: 160, wide: true), strip: storedPNG(width: 700, height: 220, color: (200, 100, 50)), keepStrip: false)
        (fig, w) = try figure(pkg)
        gel = try #require(fig.gel)
        out = RawPixels(gel)
        #expect(gel.colorSpace?.model == .rgb && gel.bitsPerComponent == 16)
        let seen = out.region(x: 300, y: Int(fig.stack.piece(strip: 1)!.top - fig.stack.crop.y0) + 50, w: 1, h: 1, channels: 3)
        let flat = RawPixels(w.strips[0].source.cgImage).region(x: 300, y: 100, w: 1, h: 1, channels: 3).map { $0 * 257 }   // the gel's own colour, x257
        #expect(seen == flat)
        // and a color gel that does keep its pixels can't be stacked with the 16-bit gray one: said, and nothing exported
        pkg.project.strips[0].strict = true
        (fig, _) = try figure(pkg)
        #expect(fig.strictProblem?.contains("RGB") == true && fig.gel == nil && fig.export(.png) == nil)
        pkg.project.strips[0].strict = false
        #expect(try figure(pkg).fig.strictProblem == nil)
        // the lanes gel doesn't keep its pixels, the second does: the second sets the storage and goes in untouched
        let top8 = piecePNG(width: 620, height: 160, lanes: mainLanes, bandRows: [60, 110]) { x, y in UInt8(200 + (x * 7 + y * 3) % 40) }
        pkg = try twoGels(top: top8, strip: storedPNG(width: 700, height: 220, wide: true), keepStrip: true)
        pkg.project.strict = false
        (fig, w) = try figure(pkg)
        gel = try #require(fig.gel)
        out = RawPixels(gel)
        let c2 = fig.stack.crop, p2 = try #require(fig.stack.piece(strip: 1))
        #expect(gel.bitsPerComponent == 16)
        #expect(out.region(x: 0, y: Int(p2.top - c2.y0), w: Int(c2.width), h: 100, channels: 1)
                == RawPixels(w.strips[0].source.cgImage).region(x: Int(c2.x0) + 37, y: 40, w: Int(c2.width), h: 100, channels: 1))
    }

    @Test func theLineBetweenGelsIsTheDarkestOrTheBrightestValue() throws {
        let top = piecePNG(width: 620, height: 160, lanes: mainLanes, bandRows: [60, 110]) { _, _ in 128 }
        for (wide, most) in [(false, 255), (true, 65535)] {
            var pkg = try twoGels(top: wide ? storedPNG(width: 620, height: 160, wide: true) : top,
                                  strip: rampPNG(width: 700, height: 220) { _, _ in 100 }, keepStrip: false)
            for white in [false, true] {
                pkg.project.separatorWhite = white
                let (fig, _) = try figure(pkg)
                let gel = try #require(fig.gel)
                let c = fig.stack.crop, row = Int(fig.stack.pieces[0].bottom - c.y0)
                let line = Set(RawPixels(gel).region(x: 0, y: row, w: Int(c.width), h: fig.stack.separator, channels: 1))
                #expect(line == [white ? UInt16(most) : 0], "\(wide ? 16 : 8)-bit \(white ? "white" : "black")")
                #expect(fig.info().description.contains("with a \(white ? "white" : "black") line between each"))
            }
        }
        // on screen (8-bit color), and in an export where no gel keeps its pixels (8-bit gray: the line is gray)
        var pkg = try twoGels(top: top, strip: rampPNG(width: 700, height: 220) { _, _ in 100 }, keepStrip: false)
        pkg.project.strict = false
        for white in [false, true] {
            pkg.project.separatorWhite = white
            let (fig, w) = try figure(pkg)
            let c = fig.stack.crop, row = Int(fig.stack.pieces[0].bottom - c.y0)
            let views = [w.main.viewImage(project: pkg.project, enhance: false)] + [w.strips[0].viewImage(project: pkg.project.stripProject(1), enhance: false)]
            for (image, channels) in [(try #require(StripStack.viewImage(views: views, stack: fig.stack)), 3), (try #require(fig.gel), 1)] {
                let line = RawPixels(image).region(x: 0, y: row, w: Int(c.width), h: fig.stack.separator, channels: channels)
                #expect(Set(line) == [white ? 255 : 0])
            }
        }
    }

    @Test func provenanceSaysWhatWasDoneToEachGel() throws {
        let top = piecePNG(width: 620, height: 160, lanes: mainLanes, bandRows: [60, 110]) { x, y in UInt8(200 + (x * 7 + y * 3) % 40) }
        var pkg = try twoGels(top: top, strip: rampPNG(width: 700, height: 220) { x, _ in UInt8(x % 200) }, keepStrip: false, scale: 1.02)
        pkg.project.strips[0].rotateDeg = 1.5
        let text = try figure(pkg).fig.info().description
        #expect(text.contains("with a black line between each"))
        #expect(text.contains("2. bottom.png") && text.contains("stretched (scaled 1.0200×)") && text.contains("rotation 1.5°") && text.contains("display range"))
        #expect(!text.contains("original pixels"))
        pkg.project.strips[0].strict = true
        let kept = try figure(pkg).fig.info().description
        #expect(kept.contains("original pixels") && !kept.contains("stretched") && !kept.contains("rotation 1.5°") && !kept.contains("converted"))
    }

    @Test func aGelThatKeepsItsPixelsIsToldWhenStretchingWouldFitBetter() throws {
        for (scale, how) in [(1.1, "farther apart"), (0.9, "closer together")] {
            let pkg = try cutBlot(shift: 37, scale: scale)
            let w = try working(pkg)
            let centers = pkg.project.lanes.centers
            let keep = StripAlign.fit(mainCenters: centers, strip: w.strips[0], bandsDark: true, keepsOriginal: true, gelNumber: 2)
            let note = try #require(keep.note, "\(scale)")
            #expect(keep.outcome.result?.scale == 1 && note.contains("Gel 2's lanes are 10") && note.contains(how) &&
                    note.hasSuffix("Turn off Keep original pixels for Gel 2 to stretch it."), "\(note)")
            // a gel that may stretch just is stretched, with nothing to say; and a small misfit isn't worth a note
            let free = StripAlign.fit(mainCenters: centers, strip: w.strips[0], bandsDark: true, keepsOriginal: false, gelNumber: 2)
            #expect(free.note == nil && abs((free.outcome.result?.scale ?? 0) - scale) < 0.02)
        }
        let near = try cutBlot(shift: 37, scale: 1.02), w = try working(near)
        #expect(StripAlign.fit(mainCenters: near.project.lanes.centers, strip: w.strips[0], bandsDark: true, keepsOriginal: true, gelNumber: 2).note == nil)
    }
}

// MARK: every stacked gel has a full crop (columns and rows of its own)

@Suite struct GelCrops {
    /// A 620 × 160 lanes gel and a 700 × 220 gel 2 (shift 37, rows 40–140, whole width unless `columns` says), both textured.
    private func stacked(columns: (Double, Double)? = nil, top: Data? = nil, strip: Data? = nil, keep: Bool? = nil) throws -> GelPackage {
        let main = top ?? piecePNG(width: 620, height: 160, lanes: [], bandRows: []) { x, y in UInt8(200 + (x * 7 + y * 3) % 40) }
        let other = strip ?? piecePNG(width: 700, height: 220, lanes: [], bandRows: []) { x, y in UInt8(100 + (x * 5 + y * 11) % 90) }
        var pkg = try GelPackage.create(imageData: main, imageName: "top.png")
        try pkg.addStrip(imageData: other, imageName: "bottom.png")
        pkg.project.strips[0].strict = keep
        pkg.project.strips[0].shift = 37
        pkg.project.strips[0].top = 40; pkg.project.strips[0].bottom = 140
        pkg.project.strips[0].left = columns?.0; pkg.project.strips[0].right = columns?.1
        return pkg
    }

    @Test func aGelsColumnsAreKeptInTheFileAndNormalizedLikeRows() throws {
        var s = GelStrip(image: "b.png", top: 10, bottom: 90, left: 20, right: 300)
        let json = try JSONEncoder().encode(s)
        let obj = try #require(JSONSerialization.jsonObject(with: json) as? [String: Any])
        #expect(obj["left"] as? Double == 20 && obj["right"] as? Double == 300 && obj["top"] as? Double == 10)
        #expect(try JSONDecoder().decode(GelStrip.self, from: json) == s)
        // omitted means the whole width: nothing in the file, and the old file reads as before
        s.left = nil; s.right = nil
        let plain = try #require(JSONSerialization.jsonObject(with: try JSONEncoder().encode(s)) as? [String: Any])
        #expect(plain["left"] == nil && plain["right"] == nil)
        let old = try JSONDecoder().decode(GelStrip.self, from: Data(#"{"image":"b.png","top":5,"bottom":50,"shift":37}"#.utf8))
        #expect(old.left == nil && old.right == nil)
        // and a gel with none follows the lanes gel's crop through its alignment, as stacking always did
        var lanesGel = GelProject(image: "a.png")
        lanesGel.strips = [old]
        #expect(lanesGel.keptColumns(strip: 1, width: 700, mainWidth: 620, mainHeight: 160) == (37, 657))
        lanesGel.crop = PixelRect(x0: 100, y0: 0, x1: 500, y1: 160)
        #expect(lanesGel.keptColumns(strip: 1, width: 700, mainWidth: 620, mainHeight: 160) == (137, 537))
        // a file that was edited into nonsense loads with the whole width, as rows do: backwards, negative, not a number
        func loaded(_ text: String) throws -> GelStrip {
            var p = try GelProject.decoder().decode(GelProject.self, from: Data(#"{"image":"a.png","strips":[{"image":"b.png",\#(text)}]}"#.utf8))
            p.sanitize()
            return p.strips[0]
        }
        for bad in [#""left":300,"right":20"#, #""left":-5,"right":100"#, #""left":50,"right":50"#, #""left":NaN,"right":100"#, #""left":-1"#] {
            let g = try loaded(bad)
            #expect(g.left == nil && g.right == nil, "\(bad)")
        }
        let fine = try loaded(#""left":20,"right":300"#)
        #expect(fine.left == 20 && fine.right == 300)
        #expect(try loaded(#""left":20"#).left == 20)   // one edge alone is fine
        // with the gel's size known: columns past its width go back to the whole width, and inside ones stay
        var p = GelProject(image: "a.png")
        p.strips = [GelStrip(image: "b.png", left: 20, right: 800), GelStrip(image: "c.png", left: 20, right: 300)]
        p.normalize(mainSize: (620, 160), stripSizes: [(700, 220), (700, 220)])
        #expect(p.strips[0].left == nil && p.strips[0].right == nil && p.strips[1].left == 20 && p.strips[1].right == 300)
        // an edge that was set is whole pixels inside the image, whatever was stored; one that wasn't follows the lanes gel's crop
        let lanesCrop = PixelRect(x0: 0, y0: 0, x1: 620, y1: 160)
        func columns(_ left: Double?, _ right: Double?) -> [Double] {
            let c = GelStrip(image: "b.png", left: left, right: right).columns(width: 700, laneCrop: lanesCrop, shift: 37, scale: 1)
            return [c.left, c.right, c.followsLeft ? 1 : 0, c.followsRight ? 1 : 0]
        }
        #expect(columns(20.4, 300.6) == [20, 301, 0, 0] && columns(-4, 9000) == [0, 700, 0, 0])
        #expect(columns(nil, nil) == [37, 657, 1, 1] && columns(100, nil) == [100, 657, 0, 1] && columns(nil, 300) == [37, 300, 1, 0])
        #expect(columns(699.9, 5) == [37, 657, 1, 1])   // backwards: followed, as rows go back to the whole gel
        #expect(columns(680, nil) == [680, 700, 0, 0] && columns(nil, 10) == [0, 10, 0, 0])   // a set edge past the followed one: the image's edge
    }

    @Test func settingATurningAndResettingAGelsCrop() throws {
        var p = try stacked().project
        #expect(GelOps.setStripCrop(&p, strip: 1, left: 30, top: 20, right: 650, bottom: 200, width: 700, height: 220))
        #expect((p.strips[0].left, p.strips[0].top, p.strips[0].right, p.strips[0].bottom) == (30, 20, 650, 200))
        // clamped to the image; and nothing left, or not a number, changes nothing
        #expect(GelOps.setStripCrop(&p, strip: 1, left: -50, top: 0, right: 9999, bottom: 9999, width: 700, height: 220))
        #expect((p.strips[0].left, p.strips[0].right, p.strips[0].bottom) == (0, 700, 220))
        let before = p
        for bad in [(100.0, 0.0, 100.0, 50.0), (200, 0, 100, 50), (0, 90, 50, 10), (.nan, 0, 50, 50)] {
            #expect(!GelOps.setStripCrop(&p, strip: 1, left: bad.0, top: bad.1, right: bad.2, bottom: bad.3, width: 700, height: 220))
        }
        #expect(!GelOps.setStripCrop(&p, strip: 2, left: 0, top: 0, right: 50, bottom: 50, width: 700, height: 220) && p == before)
        // a half turn carries the crop across the gel; a quarter turn starts it over (width and height swap)
        GelOps.setStripCrop(&p, strip: 1, left: 30, top: 20, right: 650, bottom: 200, width: 700, height: 220)
        GelOps.turn(&p, strip: 1, by: 2, width: 700, height: 220)
        #expect((p.strips[0].left, p.strips[0].right, p.strips[0].top, p.strips[0].bottom) == (50, 670, 20, 200))
        GelOps.turn(&p, strip: 1, by: 1, width: 700, height: 220)
        #expect(p.strips[0].left == nil && p.strips[0].right == nil && p.strips[0].top == nil && p.strips[0].bottom == nil)
        // an edge that was set stays the same edge of the gel through a half turn, the other still follows
        p.strips[0].left = 100
        GelOps.turn(&p, strip: 1, by: 2, width: 700, height: 220)
        #expect(p.strips[0].left == nil && p.strips[0].right == 600)
    }

    @Test func theFigureRunsFromTheLeftmostToTheRightmostColumnAnyGelKeeps() throws {
        func geometry(_ pkg: GelPackage) -> StackGeometry {
            StackGeometry(project: pkg.project, mainWidth: 620, mainHeight: 160, stripSizes: [(700, 220)])
        }
        // gel 2's columns 100–400 land on figure columns 63–363 (shift 37), inside the lanes gel's 0–620: the figure is the lanes gel's
        var g = geometry(try stacked(columns: (100, 400)))
        #expect(g.crop.x0 == 0 && g.crop.x1 == 620)
        let piece = try #require(g.piece(strip: 1))
        #expect(piece.left == 63 && piece.right == 363 && piece.sourceLeft == 100 && piece.sourceRight == 400)
        // a gel with no columns of its own follows the lanes gel's crop through its alignment: the figure is the lanes gel's, as before
        g = geometry(try stacked())
        let followed = try #require(g.piece(strip: 1))
        #expect(g.crop.x0 == 0 && g.crop.x1 == 620 && followed.left == 0 && followed.right == 620 && followed.sourceLeft == 37 && followed.sourceRight == 657)
        // the whole gel 2, set (columns 0–700), is at figure columns -37 to 663: the figure grows to take it in
        g = geometry(try stacked(columns: (0, 700)))
        #expect(g.crop.x0 == -37 && g.crop.x1 == 663 && g.crop.width == 700)
        // a gel that keeps more on the right than the lanes gel does makes the figure wider on that side only
        g = geometry(try stacked(columns: (100, 690)))
        #expect(g.crop.x0 == 0 && g.crop.x1 == 653)
        // the lanes gel's own crop works as before: it is its kept columns, and the figure covers at least them
        var pkg = try stacked(columns: (100, 400))
        pkg.project.crop = PixelRect(x0: 150, y0: 20, x1: 500, y1: 140)
        g = geometry(pkg)
        #expect(g.crop.x0 == 63 && g.crop.x1 == 500 && g.piece(strip: nil)?.left == 150 && g.piece(strip: nil)?.right == 500)
        // a gel that follows it follows the new crop
        pkg.project.strips[0].left = nil; pkg.project.strips[0].right = nil
        g = geometry(pkg)
        let after = try #require(g.piece(strip: 1))
        #expect(g.crop.x0 == 150 && g.crop.x1 == 500 && after.left == 150 && after.right == 500 && after.sourceLeft == 187 && after.sourceRight == 537)
        // one edge set, the other following: the figure takes the set one
        pkg.project.strips[0].left = 100
        g = geometry(pkg)
        #expect(g.crop.x0 == 63 && g.crop.x1 == 500)
        // a stretched gel's edges are fractional in the figure, so the figure takes the whole pixels around them
        pkg = try stacked(columns: (0, 700))
        pkg.project.strict = false; pkg.project.strips[0].strict = false
        pkg.project.strips[0].scale = 1.02; pkg.project.strips[0].shift = -10.5
        g = geometry(pkg)
        let wide = try #require(g.piece(strip: 1))
        #expect(g.crop.x0 == min(0, wide.left.rounded(.down)) && g.crop.x1 == max(620, wide.right.rounded(.up)))
        #expect(abs(wide.left - 10.5 / 1.02) < 1e-9 && abs(wide.right - 710.5 / 1.02) < 1e-9)
        // the line between gels is as thick as the figure's lines at the figure's own scale, so it follows the width
        var narrow = try stacked(columns: (100, 400))
        narrow.project.style.gelWidthIn = 2; narrow.project.style.lineWidthPt = 2
        let a = geometry(narrow).separator
        narrow.project.strips[0].left = 0; narrow.project.strips[0].right = 700
        #expect(geometry(narrow).crop.width == 700 && a == Int((2 / (2.0 * 72 / 620)).rounded()) && geometry(narrow).separator == Int((2 / (2.0 * 72 / 700)).rounded()))
    }

    @Test func whatNoGelHasIsBlankWhiteInTheStorageOnScreenAndInExports() throws {
        // strict, 8-bit gray: gel 2's columns 100–400 sit under figure columns 63–363, exactly; the rest of its rows is white
        var pkg = try stacked(columns: (100, 400), keep: true)
        var (fig, w) = try figure(pkg)
        var gel = try #require(fig.gel)
        let c = fig.stack.crop, piece = try #require(fig.stack.piece(strip: 1))
        let row = Int(piece.top - c.y0)
        var out = RawPixels(gel)
        #expect(gel.bitsPerComponent == 8 && gel.width == 620)
        #expect(out.region(x: 63, y: row, w: 300, h: 100, channels: 1)
                == RawPixels(w.strips[0].source.cgImage).region(x: 100, y: 40, w: 300, h: 100, channels: 1))
        #expect(Set(out.region(x: 0, y: row, w: 63, h: 100, channels: 1)) == [255])
        #expect(Set(out.region(x: 363, y: row, w: 257, h: 100, channels: 1)) == [255])
        // the screen shows the same blank
        let views = [w.main.viewImage(project: pkg.project, enhance: false), w.strips[0].viewImage(project: pkg.project.stripProject(1), enhance: false)]
        let seen = RawPixels(try #require(StripStack.viewImage(views: views, stack: fig.stack)))
        #expect(Set(seen.region(x: 0, y: row, w: 63, h: 100, channels: 3)) == [255] && Set(seen.region(x: 400, y: row, w: 200, h: 100, channels: 3)) == [255])
        // 16-bit gray storage: white is its maximum value, 65535 (and the gel's own values still go in untouched)
        pkg = try stacked(columns: (100, 400), top: storedPNG(width: 620, height: 160, wide: true), strip: storedPNG(width: 700, height: 220, wide: true), keep: true)
        (fig, w) = try figure(pkg)
        gel = try #require(fig.gel)
        out = RawPixels(gel)
        #expect(gel.bitsPerComponent == 16 && fig.strictProblem == nil)
        #expect(Set(out.region(x: 0, y: row, w: 63, h: 100, channels: 1)) == [65535] && Set(out.region(x: 363, y: row, w: 257, h: 100, channels: 1)) == [65535])
        #expect(out.region(x: 63, y: row, w: 300, h: 100, channels: 1)
                == RawPixels(w.strips[0].source.cgImage).region(x: 100, y: 40, w: 300, h: 100, channels: 1))
        // nothing keeps its pixels: the 8-bit gray figure is white there too
        pkg = try stacked(columns: (100, 400), keep: false)
        pkg.project.strict = false
        (fig, _) = try figure(pkg)
        let color = RawPixels(try #require(fig.gel))
        #expect(Set(color.region(x: 0, y: row, w: 63, h: 100, channels: 1)) == [255])
        // a gel that follows the lanes gel's crop and has no pixels under all of it is white there: shifted 200, its image ends at figure column 500
        pkg = try stacked(keep: true)
        pkg.project.strips[0].shift = 200
        (fig, w) = try figure(pkg)
        out = RawPixels(try #require(fig.gel))
        let end = Int(try #require(fig.stack.piece(strip: 1)).top - fig.stack.crop.y0)
        #expect(fig.stack.crop.x0 == 0 && fig.stack.crop.x1 == 620)
        #expect(Set(out.region(x: 500, y: end, w: 120, h: 100, channels: 1)) == [255])
        #expect(out.region(x: 0, y: end, w: 500, h: 100, channels: 1) == RawPixels(w.strips[0].source.cgImage).region(x: 200, y: 40, w: 500, h: 100, channels: 1))
        // a figure wider than the lanes gel leaves its rows white where the lanes gel isn't (gel 2's whole width, set, reaches past it)
        pkg = try stacked(columns: (0, 700), keep: true)
        (fig, w) = try figure(pkg)
        out = RawPixels(try #require(fig.gel))
        #expect(fig.stack.crop.x0 == -37 && Set(out.region(x: 0, y: 0, w: 37, h: 160, channels: 1)) == [255])
        #expect(out.region(x: 37, y: 0, w: 620, h: 160, channels: 1)
                == RawPixels(w.main.source.cgImage).region(x: 0, y: 0, w: 620, h: 160, channels: 1))
    }

    @Test func provenanceReportsEachGelsKeptRectangle() throws {
        let text = try figure(try stacked(columns: (100, 400))).fig.info().description
        #expect(text.contains("1. top.png, as above (its lanes are the figure's), columns 0–620, rows 0–160"), "\(text)")
        #expect(text.contains("2. bottom.png") && text.contains("columns 100–400, rows 40–140"), "\(text)")
        // a gel with no columns of its own was kept where the lanes gel's crop falls on it
        #expect(try figure(try stacked()).fig.info().description.contains("columns 37–657, rows 40–140"))
    }
}

// MARK: the gel with the lanes moves sideways too

@Suite struct MovingTheLanesGel {
    /// Gel 1 (620 × 160, lanes at 100, 200, 300, 400, 500) and gel 2 (700 × 220) lined up by 37, both textured, gel 2 with columns 100–400.
    private func stacked(mainShift: Double = 0, columns: (Double, Double)? = (100, 400), keep: Bool? = true) throws -> GelPackage {
        let main = piecePNG(width: 620, height: 160, lanes: [], bandRows: []) { x, y in UInt8(200 + (x * 7 + y * 3) % 40) }
        let other = piecePNG(width: 700, height: 220, lanes: [], bandRows: []) { x, y in UInt8(100 + (x * 5 + y * 11) % 90) }
        var pkg = try GelPackage.create(imageData: main, imageName: "top.png")
        try pkg.addStrip(imageData: other, imageName: "bottom.png")
        pkg.project.strict = keep ?? true
        pkg.project.strips[0].strict = keep
        pkg.project.strips[0].shift = 37
        pkg.project.strips[0].top = 40; pkg.project.strips[0].bottom = 140
        pkg.project.strips[0].left = columns?.0; pkg.project.strips[0].right = columns?.1
        GelOps.setDividers(&pkg.project, xs: [150, 250, 350, 450], imageWidth: 620, imageHeight: 160)
        pkg.project.mainShift = mainShift
        return pkg
    }
    private func geometry(_ p: GelProject) -> StackGeometry {
        StackGeometry(project: p, mainWidth: 620, mainHeight: 160, stripSizes: [(700, 220)])
    }

    @Test func itIsKeptInTheFileOnlyWhenItIsNotZero() throws {
        var p = try stacked().project
        func file() throws -> [String: Any] { try #require(JSONSerialization.jsonObject(with: try GelProject.encoder().encode(p)) as? [String: Any]) }
        #expect(try file()["main_shift"] == nil)   // where it was: nothing in the file
        p.mainShift = -20
        #expect(try file()["main_shift"] as? Double == -20)
        #expect(try JSONDecoder().decode(GelProject.self, from: try GelProject.encoder().encode(p)) == p)
        // an old file has none; a damaged one is brought to a number, and the gel always sits on whole pixels
        #expect(try JSONDecoder().decode(GelProject.self, from: Data(#"{"image":"a.png"}"#.utf8)).mainShift == 0)
        let bad = try GelProject.decoder().decode(GelProject.self, from: Data(#"{"image":"a.png","main_shift":NaN}"#.utf8))
        #expect(bad.mainShift == 0)
        var q = GelProject(image: "a.png")
        q.mainShift = 3.6
        #expect(q.effectiveMainShift == 4)
        q.mainShift = 1e12
        q.sanitize()
        #expect(q.mainShift == 1_000_000)
    }

    @Test func movingItLeavesEveryOtherGelWhereItIs() throws {
        // a gel's place in the figure: x in the figure of its column 300, from its own shift. Gel 1's own columns move with it.
        func figureX(_ p: GelProject, gel2 column: Double) -> Double {
            let piece = geometry(p).piece(strip: 1)!
            return piece.toFigure(x: column, y: 0).x - p.effectiveMainShift   // from the lanes gel's coordinates to the figure's
        }
        let base = try stacked().project
        let gel2 = figureX(base, gel2: 300)
        for shift in [-40.0, -20, 15, 40.4] {
            var p = base
            p.mainShift = shift
            #expect(abs(figureX(p, gel2: 300) - gel2) < 1e-9, "main shift \(shift)")   // gel 2 didn't move
            #expect(p.strips[0].shift == 37 && p.strips[0].left == 100 && p.strips[0].right == 400)   // and nothing of its own changed
            // gel 1's column 100 is in the figure at 100 - main shift: it moved by the shift
            #expect(100 - p.effectiveMainShift == 100 - shift.rounded())
        }
        // relative to gel 1 it moved the other way, which is what the picture shows: gel 2's column 300 against lane 1's centre
        var moved = base
        moved.mainShift = -20   // gel 1 moves 20 to the right
        let before = geometry(base).piece(strip: 1)!.toFigure(x: 300, y: 0).x - base.lanes.centers[0]
        let after = geometry(moved).piece(strip: 1)!.toFigure(x: 300, y: 0).x - moved.lanes.centers[0]
        #expect(after - before == -20)
        // and the raster shows it: gel 1's pixels are where they were on the page, gel 2's content 20 columns to the left of where it was
        func raster(_ pkg: GelPackage) throws -> (pixels: RawPixels, g: StackGeometry, w: (main: WorkingImage, strips: [WorkingImage])) {
            let w = try working(pkg), fig = StackedFigure(project: pkg.project, main: w.main, strips: w.strips)
            return (RawPixels(try #require(fig.gel)), fig.stack, w)
        }
        var pkg = try stacked()
        let a = try raster(pkg)
        pkg.project.mainShift = -20
        let b = try raster(pkg)
        let row = Int(try #require(a.g.piece(strip: 1)).top - a.g.crop.y0)
        #expect(a.g.crop.x0 == 0 && b.g.crop.x0 == 0 && a.g.crop.x1 == 620)
        let source = RawPixels(a.w.strips[0].source.cgImage).region(x: 100, y: 40, w: 300, h: 100, channels: 1)
        #expect(a.pixels.region(x: 63, y: row, w: 300, h: 100, channels: 1) == source)
        #expect(b.pixels.region(x: 43, y: row, w: 300, h: 100, channels: 1) == source)
        #expect(a.pixels.region(x: 0, y: 0, w: 620, h: 160, channels: 1) == b.pixels.region(x: 0, y: 0, w: 620, h: 160, channels: 1))
    }

    @Test func theLanesLabelsAndTicksGoWithIt() throws {
        // a gel 2 mark's place against the lanes, and the lanes gel's own marks, whatever its shift
        var p = try stacked().project
        GelOps.addTick(&p, y: 60, size: 40, lane: 1, gelCenterX: 310, strip: nil)
        GelOps.addTick(&p, y: 90, size: 20, lane: 1, gelCenterX: 310, strip: 1)
        _ = GelOps.applyQuickLabels(&p, text: "ladder|a|b|c|d")
        let flat = FigureLayoutEngine.layout(p, imageWidth: 620, imageHeight: 160, stack: geometry(p))
        let lane1 = try #require(flat.texts.first { $0.string == "a" })
        var moved = p
        moved.mainShift = -20
        let after = FigureLayoutEngine.layout(moved, imageWidth: 620, imageHeight: 160, stack: geometry(moved))
        let lane1After = try #require(after.texts.first { $0.string == "a" })
        // the labels stay on their lanes, in gel 1's own columns: the same distance from the dividers, and from gel 1's column 150
        #expect(abs((lane1After.bounds.midX - after.point(x: 150, y: 0).x) - (lane1.bounds.midX - flat.point(x: 150, y: 0).x)) < 1e-6)
        #expect(abs((lane1After.bounds.midX - after.gelRect.minX) - (lane1.bounds.midX - flat.gelRect.minX)) < 1e-6)   // gel 1 is at the page's edge either way
        // while gel 2's marks are where they were against the figure: against the lanes they moved 20 to the left
        let mark = { (l: StackGeometry, q: GelProject) -> Double in q.lanes.centers[0] - (l.piece(strip: 1)!.toFigure(x: 300, y: 0).x) }
        #expect(mark(geometry(moved), moved) - mark(geometry(p), p) == 20)
        // rows don't move: a sideways shift leaves every tick and name where it was down the figure
        let g1 = geometry(p), g2 = geometry(moved)
        #expect(g1.figureY(strip: nil, y: 60) == g2.figureY(strip: nil, y: 60) && g1.figureY(strip: 1, y: 90) == g2.figureY(strip: 1, y: 90))
        // the lane's place in gel 2's own pixels follows the lanes, wherever they are
        let centre = p.lanes.centers[0]
        #expect(GelOps.laneX(p, lane: 1, strip: 1) == centre + 37 && GelOps.laneX(moved, lane: 1, strip: 1) == centre + 37 + 20)
    }

    @Test func autoAlignFindsTheLanesWhereTheGelWithTheLanesNowSits() throws {
        func centers(_ shift: Double, scale: Double = 1) throws -> (GelProject, WorkingImage, [Double]) {
            let top = piecePNG(width: 620, height: 160, lanes: mainLanes, bandRows: [60, 110]) { x, y in UInt8(200 + (x * 7 + y * 3) % 40) }
            let bottom = piecePNG(width: 700, height: 220, lanes: mainLanes.map { scale * $0 + 37 }, bandRows: [90]) { x, y in UInt8(190 + (x * 5 + y * 11) % 50) }
            var pkg = try GelPackage.create(imageData: top, imageName: "top.png")
            GelOps.setDividers(&pkg.project, xs: zip(mainLanes, mainLanes.dropFirst()).map { ($0 + $1) / 2 }, imageWidth: 620, imageHeight: 160)
            try pkg.addStrip(imageData: bottom, imageName: "bottom.png")
            pkg.project.strips[0].strict = true
            pkg.project.mainShift = shift
            let w = WorkingImage(source: try SourceImage(data: try #require(pkg.stripData(1))), project: pkg.project.stripProject(1))
            return (pkg.project, w, pkg.project.lanes.centers)
        }
        var fits: [Double] = []
        for shift in [0.0, -20, 15] {
            let (p, w, c) = try centers(shift)
            let fit = StripAlign.fit(mainCenters: c, strip: w, bandsDark: true, keepsOriginal: true, gelNumber: 2)
            let r = try #require(fit.outcome.result)
            fits.append(r.shift)
            // the fit is to the lanes themselves, so it's the same wherever gel 1 sits; the shift stored is gel 2's place in the figure
            let stored = p.shiftToStore(laneShift: r.shift, scale: r.scale)
            #expect(stored == r.shift + shift, "main shift \(shift)")
            var q = p
            q.strips[0].shift = stored
            #expect(q.laneAlignment(1).shift == r.shift && q.effectiveAlignment(1).shift == stored)
            // with that stored, gel 2's lanes sit under gel 1's lanes, wherever gel 1 is: the same place in gel 2's pixels
            let worst = zip(c, GelOps.laneX(q, lane: 1, strip: 1).map { _ in (1...c.count).map { GelOps.laneX(q, lane: $0, strip: 1)! } } ?? []).map { abs($0.1 - ($0.0 + 37)) }.max() ?? 99
            #expect(worst < 4, "main shift \(shift)")
        }
        #expect(fits[0] == fits[1] && fits[1] == fits[2])
    }

    @Test func aGelThatFollowsTheLanesGelsCropFollowsItWhereItNowSits() throws {
        var p = try stacked(columns: nil).project
        #expect(p.keptColumns(strip: 1, width: 700, mainWidth: 620, mainHeight: 160) == (37, 657))
        p.mainShift = -20   // gel 1 is 20 further right, and the columns under its crop with it
        #expect(p.keptColumns(strip: 1, width: 700, mainWidth: 620, mainHeight: 160) == (57, 677))
        let g = geometry(p), piece = try #require(g.piece(strip: 1))
        #expect(g.crop.x0 == 0 && g.crop.x1 == 620 && piece.left == 0 && piece.right == 620 && piece.sourceLeft == 57 && piece.sourceRight == 677)
        // a gel with columns of its own keeps them, wherever gel 1 is
        p = try stacked().project
        p.mainShift = -20
        let own = geometry(p)
        #expect(own.crop.x0 == 0 && own.crop.x1 == 620 && own.piece(strip: 1)?.sourceLeft == 100 && own.piece(strip: 1)?.sourceRight == 400)
        // and the figure spans everything kept: gel 2's whole width is at 37 columns before gel 1 and 43 after it, until gel 1 moves right
        p = try stacked(columns: (0, 700)).project
        #expect(geometry(p).crop.x0 == -37 && geometry(p).crop.x1 == 663)
        p.mainShift = -20
        #expect(geometry(p).crop.x0 == -57 && geometry(p).crop.x1 == 643)
        p.mainShift = 50   // gel 1 moves 50 to the left: gel 2 (700 wide) is then the only thing at the right, and gel 1 the left edge
        #expect(geometry(p).crop.x0 == 0 && geometry(p).crop.x1 == 713)
    }

    @Test func provenanceMentionsItsShiftOnlyWhenItIsNotZero() throws {
        func note(_ shift: Double) throws -> String {
            var pkg = try stacked()
            pkg.project.mainShift = shift
            let w = try working(pkg)
            return StackedFigure(project: pkg.project, main: w.main, strips: w.strips).info().description
        }
        let zero = try note(0), moved = try note(-20)
        #expect(zero.contains("1. top.png, as above (its lanes are the figure's), columns 0–620, rows 0–160;"), "\(zero)")
        #expect(moved.contains("1. top.png, as above (its lanes are the figure's), columns 0–620, rows 0–160, shifted -20 px;"), "\(moved)")
    }

    @Test func aHalfTurnKeepsItsPlaceAndAQuarterTurnStartsOver() throws {
        var p = try stacked().project
        p.mainShift = -20
        GelOps.turn(&p, strip: nil, by: 2, width: 620, height: 160)
        #expect(p.mainShift == -20)
        GelOps.turn(&p, strip: nil, by: 1, width: 620, height: 160)
        #expect(p.mainShift == 0)
    }
}

// MARK: the line between gels: a color and a thickness

@Suite struct LineBetweenGels {
    @Test func colorsAreParsedAsRRGGBBWithOrWithoutTheHashAndInTheShortForm() throws {
        for text in ["#ff3300", "ff3300", "#FF3300", "FF3300", "f30", "#f30", "#F30", "  #ff3300 "] {
            #expect(SeparatorColor(parsing: text) == .rgb(255, 51, 0), "\(text)")
        }
        #expect(SeparatorColor(parsing: "#1a2b3c") == .rgb(26, 43, 60) && SeparatorColor(parsing: "#1A2B3C")?.hex == "#1a2b3c")
        // black and white by their words or their numbers, and never as a color of their own
        #expect(SeparatorColor(parsing: "black") == .black && SeparatorColor(parsing: "WHITE") == .white)
        #expect(SeparatorColor(parsing: "#000000") == .black && SeparatorColor(parsing: "000") == .black)
        #expect(SeparatorColor(parsing: "#ffffff") == .white && SeparatorColor(parsing: "fff") == .white)
        #expect(SeparatorColor.white.hex == "#ffffff" && SeparatorColor.black.hex == "#000000" && SeparatorColor.rgb(255, 51, 0).name == "#ff3300")
        #expect(SeparatorColor.black.name == "black" && SeparatorColor.white.name == "white")
        for bad in ["", "#", "#ff", "#ff33", "#ff330", "#ff33001", "gg0000", "#12345g", "red", "#ff 330", "0x123456", "#ff33００"] {
            #expect(SeparatorColor(parsing: bad) == nil, "\(bad)")
        }
    }

    @Test func aGrayFigureTakesTheColorsBrightness() {
        // Rec. 709 on the 8-bit values, rounded: 0.2126 R + 0.7152 G + 0.0722 B
        #expect(SeparatorColor.black.gray == 0 && SeparatorColor.white.gray == 255)
        #expect(SeparatorColor(parsing: "#ff3300")!.gray == 91)   // 54.2 + 36.5
        #expect(SeparatorColor(parsing: "#00ff00")!.gray == 182 && SeparatorColor(parsing: "#0000ff")!.gray == 18 && SeparatorColor(parsing: "#ff0000")!.gray == 54)
        #expect(SeparatorColor(parsing: "#808080")!.gray == 128)
    }

    @Test func theColorAndTheThicknessAreInTheFileOnlyWhenTheyAreSet() throws {
        var p = GelProject(image: "a.png")
        func file() throws -> [String: Any] { try #require(JSONSerialization.jsonObject(with: try GelProject.encoder().encode(p)) as? [String: Any]) }
        #expect(try file()["separator"] == nil && file()["separator_width"] == nil)   // an old project has neither, and reads as it did
        p.separatorColor = .white
        #expect(try file()["separator"] as? String == "white" && p.separatorWhite)
        p.separatorColor = SeparatorColor(parsing: "#FF3300")!
        p.separatorWidth = 2.5
        #expect(try file()["separator"] as? String == "#ff3300" && file()["separator_width"] as? Double == 2.5 && !p.separatorWhite)
        #expect(try JSONDecoder().decode(GelProject.self, from: try GelProject.encoder().encode(p)) == p)
        p.separatorWhite = true   // the old switch still sets the two colors
        #expect(p.separatorColor == .white)
        p.separatorWhite = false
        #expect(p.separatorColor == .black)
        // what's read: the words, any case, #RRGGBB; anything else is black
        func read(_ separator: String) throws -> SeparatorColor {
            try JSONDecoder().decode(GelProject.self, from: Data(#"{"image":"a.png","separator":\#(separator)}"#.utf8)).separatorColor
        }
        #expect(try read(#""white""#) == .white && read(#""WHITE""#) == .white && read(#""black""#) == .black)
        #expect(try read(##""#ff3300""##) == .rgb(255, 51, 0) && read(##""#F30""##) == .rgb(255, 51, 0) && read(##""#000000""##) == .black)
        #expect(try read(#""red""#) == .black && read("7") == .black && read("null") == .black)
        // a thickness outside 0.25 to 10 pt is brought into that range when it is read, and one that isn't a number is dropped
        func width(_ text: String) throws -> Double? {
            var q = try GelProject.decoder().decode(GelProject.self, from: Data(#"{"image":"a.png","separator_width":\#(text)}"#.utf8))
            q.sanitize()
            return q.separatorWidth
        }
        #expect(try width("2") == 2 && width("0.25") == 0.25 && width("10") == 10 && width("0.1") == 0.25 && width("50") == 10 && width("-3") == 0.25)
        #expect(try width("NaN") == nil && width("\"x\"") == nil)
    }

    @Test func leftOutTheLineIsAsThickAsTheFiguresLinesAndFollowsThem() throws {
        var p = GelProject(image: "a.png")
        p.style.lineWidthPt = 0.6
        #expect(p.separatorWidth == nil && p.effectiveSeparatorWidth == 0.6)
        p.style.lineWidthPt = 1.2
        #expect(p.effectiveSeparatorWidth == 1.2)   // it follows
        p.separatorWidth = 3
        #expect(p.effectiveSeparatorWidth == 3)     // until it has its own
        p.style.lineWidthPt = 0.3
        #expect(p.effectiveSeparatorWidth == 3)
        p.separatorWidth = 40   // not through the file: kept inside the range all the same
        #expect(p.effectiveSeparatorWidth == 10)
        p.separatorWidth = .nan
        #expect(p.effectiveSeparatorWidth == 0.3)
    }

    /// Gel 1 620 wide and 3.2 in across (0.372 pt a pixel), gel 2 under it, whole width of the lanes gel's crop.
    private func stacked(width: Double?, lines: Double = 0.6) throws -> GelPackage {
        var pkg = try twoGels(top: piecePNG(width: 620, height: 160, lanes: [], bandRows: []) { x, y in UInt8(200 + (x * 7 + y * 3) % 40) },
                              strip: piecePNG(width: 700, height: 220, lanes: [], bandRows: []) { x, y in UInt8(100 + (x * 5 + y * 11) % 90) }, keepStrip: true)
        pkg.project.style.gelWidthIn = 3.2
        pkg.project.style.lineWidthPt = lines
        pkg.project.separatorWidth = width
        return pkg
    }

    @Test func theSeparatorRowsChangeWithTheThickness() throws {
        func rows(_ pkg: GelPackage) throws -> (rows: Int, height: Int, line: Bool) {
            let (fig, _) = try figure(pkg)
            let gel = try #require(fig.gel)
            let c = fig.stack.crop, row = Int(fig.stack.pieces[0].bottom - c.y0)
            let line = Set(RawPixels(gel).region(x: 0, y: row, w: Int(c.width), h: fig.stack.separator, channels: 1)) == [0]
            return (fig.stack.separator, gel.height, line)
        }
        // pt a pixel is 3.2 × 72 / 620: 0.6 pt is 2 rows, 2 pt is 5, 10 pt is 27, and 0.25 pt is still one
        let followed = try rows(try stacked(width: nil)), thin = try rows(try stacked(width: 0.25)), two = try rows(try stacked(width: 2)), thick = try rows(try stacked(width: 10))
        #expect(followed.rows == 2 && thin.rows == 1 && two.rows == 5 && thick.rows == 27)
        #expect(followed.line && thin.line && two.line && thick.line)   // all of them are the line, in black
        #expect(two.height - followed.height == 3 && thick.height - followed.height == 25 && thin.height - followed.height == -1)   // the figure is taller by the difference
        // left out, it follows the figure's lines as they change; with its own, it doesn't
        #expect(try rows(try stacked(width: nil, lines: 2)).rows == 5 && (try rows(try stacked(width: 10, lines: 2)).rows == 27))
        // gels' alignment, crop and rows are untouched by it
        let (a, _) = try figure(try stacked(width: nil)), (b, _) = try figure(try stacked(width: 10))
        #expect(a.stack.crop.x0 == b.stack.crop.x0 && a.stack.crop.x1 == b.stack.crop.x1 && a.stack.pieces[1].bottom - a.stack.pieces[1].top == b.stack.pieces[1].bottom - b.stack.pieces[1].top)
        // on screen the same rows
        let w = try working(try stacked(width: 2))
        let views = [w.main.viewImage(project: try stacked(width: 2).project, enhance: false), w.strips[0].viewImage(project: try stacked(width: 2).project.stripProject(1), enhance: false)]
        let stack = StackGeometry(project: try stacked(width: 2).project, mainWidth: 620, mainHeight: 160, stripSizes: [(700, 220)])
        #expect(stack.separator == 5 && StripStack.viewImage(views: views, stack: stack)?.height == Int(stack.crop.height))
        // and the note: the thickness isn't in it, the color is
        #expect(try figure(try stacked(width: 2)).fig.info().description.contains("with a black line between each"))
    }

    /// The distinct (r, g, b) triples in `values`, which hold r, g, b, r, g, b, …
    private func triples(_ values: [UInt16]) -> Set<[UInt16]> {
        var out = Set<[UInt16]>()
        var i = 0
        while i + 2 < values.count { out.insert([values[i], values[i + 1], values[i + 2]]); i += 3 }
        return out
    }

    @Test func theColorIsItsOwnNumbersInRGBAndItsBrightnessInGray() throws {
        func line(_ pkg: GelPackage, channels: Int) throws -> (values: Set<UInt16>, bits: Int) {
            let (fig, _) = try figure(pkg)
            let gel = try #require(fig.gel)
            let c = fig.stack.crop, row = Int(fig.stack.pieces[0].bottom - c.y0)
            return (Set(RawPixels(gel).region(x: 0, y: row, w: Int(c.width), h: fig.stack.separator, channels: channels)), gel.bitsPerComponent)
        }
        let orange = SeparatorColor(parsing: "#ff3300")!
        let gray8 = piecePNG(width: 620, height: 160, lanes: [], bandRows: []) { x, y in UInt8(200 + (x * 7 + y * 3) % 40) }
        let strip8 = piecePNG(width: 700, height: 220, lanes: [], bandRows: []) { x, y in UInt8(100 + (x * 5 + y * 11) % 90) }
        // 8-bit gray: the luminance, 91
        var pkg = try twoGels(top: gray8, strip: strip8, keepStrip: true)
        pkg.project.separatorColor = orange
        var got = try line(pkg, channels: 1)
        #expect(got.bits == 8 && got.values == [91])
        // 16-bit gray: that times 257, as 8-bit values are scaled everywhere
        pkg = try twoGels(top: storedPNG(width: 620, height: 160, wide: true), strip: storedPNG(width: 700, height: 220, wide: true), keepStrip: true)
        pkg.project.separatorColor = orange
        got = try line(pkg, channels: 1)
        #expect(got.bits == 16 && got.values == [91 * 257])
        // 8-bit RGB: the color itself
        pkg = try twoGels(top: storedPNG(width: 620, height: 160, color: (200, 100, 50)), strip: storedPNG(width: 700, height: 220, color: (50, 100, 200)), keepStrip: true)
        pkg.project.separatorColor = orange
        let rgb = try figure(pkg)
        let rgbImage = try #require(rgb.fig.gel)
        let c = rgb.fig.stack.crop, row = Int(rgb.fig.stack.pieces[0].bottom - c.y0)
        let pixels = RawPixels(rgbImage).region(x: 0, y: row, w: Int(c.width), h: rgb.fig.stack.separator, channels: 3)
        #expect(rgbImage.bitsPerComponent == 8)
        #expect(triples(pixels) == [[255, 51, 0]])
        // 16-bit RGB: each channel times 257
        pkg = try twoGels(top: storedPNG(width: 620, height: 160, wideColor: true), strip: storedPNG(width: 700, height: 220, wideColor: true), keepStrip: true)
        pkg.project.separatorColor = orange
        let wide = try figure(pkg)
        let wideImage = try #require(wide.fig.gel)
        let wc = wide.fig.stack.crop, wrow = Int(wide.fig.stack.pieces[0].bottom - wc.y0)
        let wpx = RawPixels(wideImage).region(x: 0, y: wrow, w: Int(wc.width), h: wide.fig.stack.separator, channels: 3)
        let wideLine: Set<[UInt16]> = [[255 * 257, 51 * 257, 0]]
        #expect(wideImage.bitsPerComponent == 16)
        #expect(triples(wpx) == wideLine)
        // a color that isn't a figure's storage: the 8-bit color screen and a figure of gels that don't keep their pixels are RGB, exactly
        pkg = try twoGels(top: gray8, strip: strip8, keepStrip: false)
        pkg.project.strict = false
        pkg.project.separatorColor = orange
        let (fig, w) = try figure(pkg)
        let free = try #require(fig.gel)
        let fc = fig.stack.crop, frow = Int(fig.stack.pieces[0].bottom - fc.y0)
        let fpx = RawPixels(free).region(x: 0, y: frow, w: Int(fc.width), h: fig.stack.separator, channels: 3)
        #expect(triples(fpx) == [[255, 51, 0]])
        let views = [w.main.viewImage(project: pkg.project, enhance: false), w.strips[0].viewImage(project: pkg.project.stripProject(1), enhance: false)]
        let screen = RawPixels(try #require(StripStack.viewImage(views: views, stack: fig.stack)))
        let spx = screen.region(x: 0, y: frow, w: Int(fc.width), h: fig.stack.separator, channels: 3)
        #expect(triples(spx) == [[255, 51, 0]])
        // black and white are still the darkest and the brightest of any storage, and the note names the color
        pkg.project.separatorColor = .white
        #expect(try figure(pkg).fig.info().description.contains("with a white line between each"))
        pkg.project.separatorColor = orange
        #expect(try figure(pkg).fig.info().description.contains("with a #ff3300 line between each"))
    }
}


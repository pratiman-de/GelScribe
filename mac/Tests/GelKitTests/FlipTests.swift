import CoreGraphics
import Foundation
import Testing
@testable import GelKit

// Flip: the gel mirrored as shown, after the quarter turns (a membrane turned over in the transfer).

private func project(turn: Int = 0) -> GelProject {
    var p = GelProject(image: "a.png")
    p.turn = turn
    p.crop = PixelRect(x0: 10, y0: 5, x1: 60, y1: 30)
    p.lanes.dividers = [LaneDivider(xTop: 20, xBottom: 24, dotY: 10), LaneDivider(xTop: 40, xBottom: 40, dotY: 10), LaneDivider(xTop: 60, xBottom: 62, dotY: 10)]
    _ = GelOps.addTick(&p, y: 8, size: 40, lane: 1, gelCenterX: 30)
    p.annotations.append(BandAnnotation(y: 12, y2: 15, text: "X"))
    return p
}

@Suite struct Flip {
    @Test func theFlipIsInTheFileOnlyWhenSetAndRoundTrips() throws {
        var p = project()
        #expect(!String(decoding: try GelProject.encoder().encode(p), as: UTF8.self).contains("\"flip\""))
        p.flip = .both
        p.strips = [GelStrip(image: "b.png")]
        p.strips[0].flip = .vertical
        let json = try GelProject.encoder().encode(p)
        #expect(String(decoding: json, as: UTF8.self).contains("\"flip\" : \"both\""))
        let back = try GelProject.decoder().decode(GelProject.self, from: json)
        #expect(back.flip == .both && back.strips[0].flip == .vertical)
        let odd = try GelProject.decoder().decode(GelProject.self, from: Data(#"{"image":"a.png","flip":"sideways"}"#.utf8))
        #expect(odd.flip == .none)
    }

    @Test func pixelsAreMirroredExactlyAfterTheTurn() throws {
        let (w, h) = (80, 40)
        let src = try SourceImage(data: gelPNG(width: w, height: h, noiseSeed: 7))
        func rows(_ img: SourceImage) -> [[UInt16]] {
            let r: [UInt16] = RawPixels(img.cgImage).region(x: 0, y: 0, w: w, h: h, channels: 1)
            return (0..<h).map { y in Array(r[y * w..<(y + 1) * w]) }
        }
        let orig = rows(src)
        let mirrored: [[UInt16]] = orig.map { Array($0.reversed()) }
        let upsideDown: [[UInt16]] = Array(orig.reversed())
        let both: [[UInt16]] = Array(mirrored.reversed())
        #expect(rows(src.flipped(.horizontal)) == mirrored)
        #expect(rows(src.flipped(.vertical)) == upsideDown)
        #expect(rows(src.flipped(.both)) == both)
        #expect(src.flipped(.horizontal).gray.pixels != src.gray.pixels)
        #expect(src.flipped(.both).gray.pixels == Array(src.gray.pixels.reversed()))
        #expect(src.flipped(.horizontal).sha256 == src.sha256 && src.flipped(.horizontal).data == src.data)
        // Strict: the working image carries the flipped original values; turn first, then the flip, as shown
        var p = GelProject(image: "a.png")
        p.strict = true; p.flip = .horizontal; p.turn = 1
        let work = WorkingImage(source: src, project: p)
        let turned = src.turned(1)
        #expect(work.source.gray.pixels == turned.flipped(.horizontal).gray.pixels && work.width == h && work.height == w)
        #expect(work.source.gray.pixels != src.flipped(.horizontal).turned(1).gray.pixels)
        // after a 90 degree turn, Flip Horizontally still mirrors left-right on screen: each row of the shown gel reads backwards
        let shown = work.source.gray.pixels, plain = turned.gray.pixels
        for y in 0..<w { #expect(Array(shown[y * h..<(y + 1) * h]) == Array(plain[y * h..<(y + 1) * h].reversed())) }
    }

    @Test func marksMoveWithTheImage() {
        let (w, h) = (80, 40)
        var p = project()
        GelOps.flip(&p, strip: nil, leftRight: true, width: w, height: h)
        #expect(p.flip == .horizontal)
        #expect(p.lanes.dividers.map(\.xTop) == [19, 39, 59] && p.lanes.dividers.map(\.xBottom) == [17, 39, 55])
        #expect(p.crop == PixelRect(x0: 20, y0: 5, x1: 70, y1: 30))
        #expect(p.ladder!.bands.map(\.y) == [8] && p.annotations[0].y == 12)   // up and down stay put
        var v = project()
        GelOps.flip(&v, strip: nil, leftRight: false, width: w, height: h)
        #expect(v.flip == .vertical)
        #expect(v.ladder!.bands.map(\.y) == [31] && v.annotations[0].y == 27 && v.annotations[0].y2 == 24)
        #expect(v.crop == PixelRect(x0: 10, y0: 10, x1: 60, y1: 35))
        #expect(v.lanes.dividers.map(\.xTop) == [24, 40, 62] && v.lanes.dividers.map(\.xBottom) == [20, 40, 60])
        // twice is no flip, and nothing has moved
        GelOps.flip(&v, strip: nil, leftRight: false, width: w, height: h)
        #expect(v.flip == .none && v.ladder!.bands.map(\.y) == [8] && v.crop == project().crop && v.lanes.dividers == project().lanes.dividers)
        // after a quarter turn Flip Horizontally still mirrors left-right as shown: the dividers move, the ticks don't
        var t = project(turn: 1)
        GelOps.flip(&t, strip: nil, leftRight: true, width: w, height: h)
        #expect(t.flip == .horizontal && t.ladder!.bands.map(\.y) == [8] && t.lanes.dividers.map(\.xTop) == [19, 39, 59])
        // and turning a flipped gel a quarter keeps what is shown consistent: the flip runs the other way round
        var q = project()
        q.flip = .horizontal
        GelOps.turn(&q, strip: nil, by: 1, width: w, height: h)
        #expect(q.turn == 1 && q.flip == .vertical)
        GelOps.turn(&q, strip: nil, by: 2, width: h, height: w)
        #expect(q.turn == 3 && q.flip == .vertical)
        var both = project()
        GelOps.flip(&both, strip: nil, leftRight: true, width: w, height: h)
        GelOps.flip(&both, strip: nil, leftRight: false, width: w, height: h)
        #expect(both.flip == .both)
    }

    @Test func aStripFlipsItsOwnMarksAndRows() {
        var p = project()
        p.strips = [GelStrip(image: "b.png", top: 4, bottom: 30, left: 10, right: 50)]
        p.ladder!.bands.append(LadderBand(y: 8, size: 30, strip: 1))
        p.annotations.append(BandAnnotation(y: 6, text: "S", strip: 1))
        GelOps.flip(&p, strip: 1, leftRight: false, width: 80, height: 40)
        #expect(p.strips[0].flip == .vertical && p.flip == .none)
        #expect(p.strips[0].top == 10 && p.strips[0].bottom == 36 && p.strips[0].left == 10 && p.strips[0].right == 50)
        #expect(p.ladder!.bands.map(\.y) == [8, 31] && p.annotations.map(\.y) == [12, 33])
        GelOps.flip(&p, strip: 1, leftRight: true, width: 80, height: 40)
        #expect(p.strips[0].flip == .both && p.strips[0].left == 30 && p.strips[0].right == 70)
        #expect(p.stripProject(1).flip == .both)
    }

    @Test func theExportNoteSaysSoAfterTheTurn() {
        var p = project()
        p.flip = .horizontal; p.turn = 2
        #expect(ExportInfo.for(p, sourceSHA256: "aaa").description.contains("turned 180°, flipped horizontally, crop"))
        p.flip = .vertical
        #expect(ExportInfo.for(p, sourceSHA256: "aaa").description.contains("turned 180°, flipped vertically"))
        p.flip = .both
        #expect(ExportInfo.for(p, sourceSHA256: "aaa").description.contains("turned 180°, flipped horizontally and vertically"))
        p.strips = [GelStrip(image: "b.png")]
        p.strips[0].flip = .vertical
        let info = ExportInfo.for(p, sourceSHA256: "aaa", strips: [(sha256: "bbb", scale: nil)])
        #expect(info.description.contains("flipped vertically"))
    }

    /// The figure's gel pixels (8-bit gray) as rows.
    private func gelArea(_ src: SourceImage, _ p: GelProject) throws -> [[Int]] {
        let w = WorkingImage(source: src, project: p)
        let img = try #require(w.figureImage(project: p, asGray: true))
        let r: [UInt16] = RawPixels(img).region(x: 0, y: 0, w: img.width, h: img.height, channels: 1)
        return (0..<img.height).map { y in (0..<img.width).map { Int(r[y * img.width + $0]) } }
    }

    @Test func aFlipMirrorsTheShownStraightenedAndCroppedGelInPlace() throws {
        let (w, h) = (80, 40)
        let src = try SourceImage(data: gelPNG(width: w, height: h, lanes: [20, 40, 60], bandRows: [12, 25], noiseSeed: 5))
        for (strict, degrees, tolerance) in [(false, 2.4, 3), (false, 0.0, 0), (true, 2.4, 0)] {
            var p = project()
            p.strict = strict; p.rotateDeg = degrees
            let before = try gelArea(src, p)
            var across = p, down = p, both = p
            GelOps.flip(&across, strip: nil, leftRight: true, width: w, height: h)
            GelOps.flip(&down, strip: nil, leftRight: false, width: w, height: h)
            GelOps.flip(&both, strip: nil, leftRight: true, width: w, height: h)
            GelOps.flip(&both, strip: nil, leftRight: false, width: w, height: h)
            #expect(across.rotateDeg == (degrees == 0 ? 0 : -degrees) && down.rotateDeg == across.rotateDeg && both.rotateDeg == degrees)
            let a = try gelArea(src, across), d = try gelArea(src, down), b = try gelArea(src, both)
            #expect(a.count == before.count && a[0].count == before[0].count)
            var worst = 0
            for y in before.indices {
                for x in before[y].indices {
                    worst = max(worst, abs(a[y][x] - before[y][before[y].count - 1 - x]))
                    worst = max(worst, abs(d[y][x] - before[before.count - 1 - y][x]))
                    worst = max(worst, abs(b[y][x] - before[before.count - 1 - y][before[y].count - 1 - x]))
                }
            }
            #expect(worst <= tolerance, "strict \(strict), \(degrees) degrees: off by \(worst)")
            #expect(across.crop == PixelRect(x0: 20, y0: 5, x1: 70, y1: 30))   // the same region, mirrored about the centre
        }
    }

    @Test func flippingTwiceRestoresTheProjectExactly() throws {
        var p = project(turn: 1)
        p.rotateDeg = 2.4; p.strict = false
        p.strips = [GelStrip(image: "b.png", rotateDeg: -1.5, top: 4, bottom: 30, left: 10, right: 50)]
        p.ladder!.unitY = 17
        p.ladder!.bands.append(LadderBand(y: 8, size: 30, strip: 1))
        p.annotations.append(BandAnnotation(y: 6, text: "S", strip: 1))
        p.syncLaneCenters(imageWidth: 80, imageHeight: 40)   // (a flip keeps the lane centres in step with the dividers)
        let original = try GelProject.encoder().encode(p)
        for strip in [nil, 1] as [Int?] {
            for leftRight in [true, false] {
                var q = p
                GelOps.flip(&q, strip: strip, leftRight: leftRight, width: 80, height: 40)
                #expect(q != p)
                GelOps.flip(&q, strip: strip, leftRight: leftRight, width: 80, height: 40)
                let after = try GelProject.encoder().encode(q)
                if after != original {
                    let a = String(decoding: after, as: UTF8.self).split(separator: "\n"), o = String(decoding: original, as: UTF8.self).split(separator: "\n")
                    let diff: String = zip(a, o).filter { $0 != $1 }.map { "\($0) vs \($1)" }.joined(separator: "; ")
                    Issue.record(Comment(rawValue: "strip \(String(describing: strip)) leftRight \(leftRight): \(diff)"))
                }
            }
        }
        var q = p
        GelOps.flip(&q, strip: 1, leftRight: true, width: 80, height: 40)
        #expect(q.strips[0].rotateDeg == 1.5 && q.rotateDeg == 2.4)
        GelOps.flip(&q, strip: nil, leftRight: false, width: 80, height: 40)
        #expect(q.rotateDeg == -2.4 && q.ladder!.unitY == 22)
    }

    @Test(.enabled(if: hasCLI, "needs the built gelscribe")) func theCommandLineFlipsAGelOrTheLanesGel() throws {
        let b = try Bench()
        try b.twoGels()
        #expect(try b.run("edit", "P.gelscribe", "--flip", "horizontal").status == 0)
        #expect(try b.run("edit", "P.gelscribe", "--flip", "both", "--gel", "2").status == 0)
        var p = try GelProject.decoder().decode(GelProject.self, from: b.projectBytes("P.gelscribe"))
        #expect(p.flip == .horizontal && p.strips[0].flip == .both)
        #expect(try b.run("edit", "P.gelscribe", "--flip", "none").status == 0)
        p = try GelProject.decoder().decode(GelProject.self, from: b.projectBytes("P.gelscribe"))
        #expect(p.flip == .none && p.strips[0].flip == .both)
        #expect(try b.json("P.gelscribe")["flip"] == nil)
        let bad = try b.run("edit", "P.gelscribe", "--flip", "sideways")
        #expect(bad.status == 1 && bad.err.contains("--flip wants"))
        #expect(try b.run("help").out.contains("--flip"))
    }
}

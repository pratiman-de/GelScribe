import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import GelKit

private func png(width: Int, height: Int, lanes: [Double], bandRows: [Int]) -> Data {
    var px = [UInt8](repeating: 0, count: width * height)
    for y in 0..<height {
        for x in 0..<width {
            var v = Double(200 + (x * 7 + y * 3) % 40)
            for c in lanes where abs(Double(x) - c) < 26 {
                for r in bandRows { v -= 150 * exp(-pow((Double(x) - c) / 10, 2) / 2) * exp(-pow(Double(y - r) / 4, 2) / 2) }
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

/// Two gels side by side: gel 1 (400 x 200) with 3 lanes, gel 2 (300 x 240) with 2 lanes.
private func twoGels() throws -> GelPackage {
    var pkg = try GelPackage.create(imageData: png(width: 400, height: 200, lanes: [70, 200, 330], bandRows: [50, 150]), imageName: "a.png")
    try pkg.addStrip(imageData: png(width: 300, height: 240, lanes: [80, 220], bandRows: [70, 190]), imageName: "b.png")
    pkg.project.arrangement = .sideBySide
    GelOps.setDividers(&pkg.project, xs: [135, 265], imageWidth: 400, imageHeight: 200)
    GelOps.setDividers(&pkg.project, xs: [150], imageWidth: 300, imageHeight: 240, gel: 1)
    return pkg
}

private func figure(_ pkg: GelPackage) throws -> StackedFigure {
    let main = WorkingImage(source: try SourceImage(data: pkg.imageData), project: pkg.project)
    let strips = try pkg.project.strips.indices.map { i in
        WorkingImage(source: try SourceImage(data: pkg.stripData(i + 1)!), project: pkg.project.stripProject(i + 1))
    }
    return StackedFigure(project: pkg.project, main: main, strips: strips)
}

@Suite struct SideBySide {
    @Test func jsonRoundTripAndDefault() throws {
        let pkg = try twoGels()
        let data = try JSONEncoder().encode(pkg.project)
        let text = String(decoding: data, as: UTF8.self)
        #expect(text.contains("\"arrangement\":\"side_by_side\""))
        let back = try GelProject.decoder().decode(GelProject.self, from: data)
        #expect(back.arrangement == .sideBySide && back.strips[0].lanes?.centers.count == 2 && back == pkg.project)
        var stacked = pkg.project; stacked.arrangement = .topToBottom
        #expect(!String(decoding: try JSONEncoder().encode(stacked), as: UTF8.self).contains("arrangement"))
    }

    @Test func lanesAreNumberedAcrossAndOneLabelRowRuns() throws {
        let pkg = try twoGels()
        var p = pkg.project
        #expect(p.laneCount == 5 && p.laneSlot(4)! == (1, 1) && p.continuousLane(gel: 1, lane: 2) == 5)
        p.rows = [LabelRow(type: .lanes, labels: ["1", "2", "3", "4", "5"])]
        let f = try figure(pkg)
        let fig = FigureLayoutEngine.layout(p, imageWidth: 400, imageHeight: 200, stack: f.stack)
        let xs = fig.texts.filter { if case .laneLabel = $0.role { true } else { false } }.map(\.origin.x)
        #expect(xs.count == 5 && xs == xs.sorted())
        let ys = Set(fig.texts.filter { if case .laneLabel = $0.role { true } else { false } }.map(\.origin.y))
        #expect(ys.count == 1)   // one row
    }

    @Test func cropSpansAndVerticalSeparator() throws {
        var pkg = try twoGels()
        pkg.project.strips[0].shift = 30   // gel 2's row 30 sits at the lanes gel's row 0
        let f = try figure(pkg)
        let s = f.stack, sep = Double(s.separator)
        #expect(s.sideBySide && s.pieces.map(\.strip) == [nil, 1])
        #expect(s.pieces[1].left == 400 + sep && s.crop.x0 == 0 && s.crop.x1 == 700 + sep)
        #expect(s.crop.y0 == -30)   // gel 2's first row is 30 above row 0
        #expect(s.crop.y1 == 210)   // gel 2's last row 240 is at 210; the lanes gel ends at 200
        let img = try #require(f.gel)
        #expect(img.width == Int(700 + sep) && img.height == 240)
        // the line is vertical, the figure's whole height, in the separator colour (black)
        let px = RawPixels(img).region(x: 400, y: 0, w: 1, h: 240, channels: 1)
        #expect(px.allSatisfy { $0 == 0 })
        // gaps are white: above the lanes gel (its rows start 30 down), below it
        let gap = RawPixels(img).region(x: 10, y: 0, w: 1, h: 30, channels: 1)
        #expect(gap.allSatisfy { $0 == 255 })
    }

    @Test func verticalLadderFitAndTopsFallback() throws {
        var pkg = try twoGels()
        // the lanes gel's ticks at 50/150 (sizes 100/50); gel 2's at 70/190 -> scale 1.2, shift 10
        pkg.project.ladder = Ladder(lane: 1, bands: [
            LadderBand(y: 50, size: 100), LadderBand(y: 150, size: 50),
            LadderBand(y: 70, size: 100, strip: 1), LadderBand(y: 190, size: 50, strip: 1)])
        var p = pkg.project
        p.strips[0].strict = false
        let note = GelOps.alignVertically(&p, gel: 1, mainRows: (0, 200), gelHeight: 240)
        #expect(abs(p.strips[0].scale - 1.2) < 1e-9 && abs(p.strips[0].shift - 10) < 1e-9)
        #expect(note == "Lined up on 2 ladder bands, within 0.0 px; stretched 20.0%.")
        var q = pkg.project; q.strips[0].strict = true   // gel 2 keeps original pixels: whole-pixel shift, no stretch
        GelOps.alignVertically(&q, gel: 1, mainRows: (0, 200), gelHeight: 240)
        #expect(q.strips[0].scale == 1)
        #expect(q.strips[0].shift == 30)
        // no matching ladder bands: tops line up
        var r = pkg.project
        r.ladder?.bands.removeAll { $0.strip != nil }
        r.strips[0].top = 25; r.strips[0].strict = false
        let n = GelOps.alignVertically(&r, gel: 1, mainRows: (0, 200), gelHeight: 240)
        #expect(abs(r.strips[0].scale - 215.0 / 200) < 1e-9 && abs(r.strips[0].shift - 25) < 1e-9)   // the same height, tops lined up
        #expect(n == "No matching ladder bands; sized to the same height as Gel 1 and tops lined up.")
        // keeping original pixels: scale 1, and the note says how far apart the heights are
        r.strips[0].strict = true
        let m = GelOps.alignVertically(&r, gel: 1, mainRows: (0, 200), gelHeight: 240)
        #expect(r.strips[0].scale == 1 && r.strips[0].shift == 25)
        #expect(m == "No matching ladder bands; tops lined up. Gel 2 is 215 px tall and Gel 1 200 px (7% different). Turn off Keep original pixels for Gel 2 to size it to the same height.")
    }

    @Test func aSizedGelKeepsItsProportionsAndItsLanesGoWithIt() throws {
        var pkg = try twoGels()
        pkg.project.strips[0].strict = false
        pkg.project.strips[0].scale = 2   // gel 2's pixels are twice the lanes gel's: it is drawn half as wide and half as tall
        let f = try figure(pkg)
        let a = f.stack.pieces[0], b = f.stack.pieces[1]
        #expect(b.right - b.left == 150 && b.bottom - b.top == 120)   // 300 x 240 px at half size
        let at = b.toFigure(x: 150, y: 120)
        #expect(at.x == b.left + 75 - 0 && abs(b.toPiece(x: at.x, y: at.y).x - 150) < 1e-9 && abs(b.toPiece(x: at.x, y: at.y).y - 120) < 1e-9)
        // its one lane (own x 150) is at figure x left + 75, the lanes gel's three before it: lanes numbered across
        let lanes = pkg.project.figureLanes(stack: f.stack)
        #expect(lanes.centers.count == 5 && lanes.centers[3] == b.left + 37.5 && lanes.centers[4] == b.left + 112.5 && a.right == 400)
    }

    @Test func ladderLabelsFromTheLeftmostGelWithTicks() throws {
        var pkg = try twoGels()
        pkg.project.ladder = Ladder(lane: 1, bands: [LadderBand(y: 70, size: 100, strip: 1), LadderBand(y: 190, size: 50, strip: 1)])
        #expect(pkg.project.isLadderLabelGel(1) && !pkg.project.isLadderLabelGel(nil))
        let f = try figure(pkg)
        let fig = FigureLayoutEngine.layout(pkg.project, imageWidth: 400, imageHeight: 200, stack: f.stack)
        #expect(fig.texts.filter { if case .ladderLabel = $0.role { true } else { false } }.count == 2)
        pkg.project.ladder?.bands.append(LadderBand(y: 60, size: 100))   // now the leftmost gel has ticks: only its labels show
        let g = try figure(pkg)
        let fig2 = FigureLayoutEngine.layout(pkg.project, imageWidth: 400, imageHeight: 200, stack: g.stack)
        #expect(fig2.texts.filter { if case .ladderLabel = $0.role { true } else { false } }.count == 1)
    }

    @Test func provenanceWording() throws {
        var pkg = try twoGels()
        pkg.project.strips[0].shift = 12
        let d = try figure(pkg).info().description
        #expect(d.contains("2 separately scanned gels, left to right, with a black line between each:"))
        #expect(d.contains("shifted 12 px vertically"))
        pkg.project.arrangement = .topToBottom
        #expect(try figure(pkg).info().description.contains("top to bottom"))
    }

    @Test func switchingKeepsEachGelsData() throws {
        var p = try twoGels().project
        let before = p
        GelOps.setArrangement(&p, .topToBottom)
        #expect(p.strips[0].lanes == before.strips[0].lanes && p.lanes == before.lanes && p.laneCount == 3)
        GelOps.setArrangement(&p, .sideBySide)
        #expect(p == before && p.laneCount == 5)
    }

    @Test func theLanesGelsNumbersCountFromTheGelOnItsLeft() throws {
        var p = try twoGels().project
        p.mainPosition = 1   // gel 1 is the other gel (2 lanes), the lanes gel (3 lanes) is gel 2
        #expect(p.laneNumbers(ofGel: 1) == 1..<3 && p.laneNumbers(ofGel: nil) == 3..<6)
        #expect(p.laneSlot(3)! == (nil, 1) && p.continuousLane(gel: nil, lane: 3) == 5)
    }

    @Test func topToBottomIsUntouched() throws {
        var pkg = try twoGels()
        pkg.project.arrangement = .topToBottom
        let s = try figure(pkg).stack
        #expect(!s.sideBySide && s.crop.x0 >= 0 && s.pieces[1].top > s.pieces[0].bottom)
    }
}

@Suite(.enabled(if: hasCLI, "needs the built gelscribe")) struct SideBySideCLI {
    @Test func arrangementOwnLanesAndVerticalAlign() throws {
        let b = try Bench()
        try b.twoGels()
        #expect(try b.run("edit", "P.gelscribe", "--arrangement", "sideways").status != 0)
        let r = try b.run("edit", "P.gelscribe", "--arrangement", "side-by-side", "--dividers", "95,165,235")
        #expect(r.status == 0, "\(r.err)")
        let g = try b.run("edit", "P.gelscribe", "--gel", "2", "--dividers", "120,300", "--align", "auto", "--strict", "off")
        #expect(g.status == 0, "\(g.err)")
        #expect((g.out + g.err).contains("sized to the same height as Gel 1 and tops lined up."))
        let j = try b.json("P.gelscribe")
        #expect(j["arrangement"] as? String == "side_by_side")
        let strip = try #require((j["strips"] as? [[String: Any]])?.first)
        #expect(((strip["lanes"] as? [String: Any])?["centers"] as? [Any])?.count == 3)
        #expect(((j["lanes"] as? [String: Any])?["centers"] as? [Any])?.count == 4)
        let png = try b.run("render", "P.gelscribe", "-o", "out", "--formats", "png")
        #expect(png.status == 0, "\(png.err)")
        #expect(try b.run("edit", "P.gelscribe", "--arrangement", "top-to-bottom").status == 0)
        #expect(try b.json("P.gelscribe")["arrangement"] == nil)
    }
}

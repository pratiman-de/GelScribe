import AppKit
import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import GelKit
@testable import GelScribeApp

// Timing probe for live operations on a 12 MP Display P3 colour image (synthetic, same size and format as the owner's photo). It prints
// milliseconds and asserts nothing; it runs only with GELPERF=1.

private let docs = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("docs")

private func p3Data() -> Data {
    let w = 4032, h = 3024
    var px = [UInt8](repeating: 0, count: w * h * 4)
    for y in 0..<h { for x in 0..<w {
        let i = (y * w + x) * 4, v = UInt8(60 + (x * 3 + y * 5) % 120)
        px[i] = v; px[i + 1] = v &+ 20; px[i + 2] = v &+ 40; px[i + 3] = 255
    } }
    let ctx = CGContext(data: &px, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                        space: CGColorSpace(name: CGColorSpace.displayP3)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    let out = NSMutableData()
    let dest = CGImageDestinationCreateWithData(out, UTType.tiff.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, ctx.makeImage()!, nil); CGImageDestinationFinalize(dest)
    return out as Data
}

@MainActor private func ms(_ label: String, draw: (() -> Void)? = nil, _ body: () -> Void) {
    let t0 = DispatchTime.now(); body()
    let op = Int(Double(DispatchTime.now().uptimeNanoseconds - t0.uptimeNanoseconds) / 1e6)
    var d = 0
    if let draw { let t1 = DispatchTime.now(); draw(); d = Int(Double(DispatchTime.now().uptimeNanoseconds - t1.uptimeNanoseconds) / 1e6) }
    print("PROBE \(label): op \(op) ms" + (draw == nil ? "" : ", redraw \(d) ms, total \(op + d) ms"))
}

@MainActor private func msPlain(_ label: String, _ body: () -> Void) {
    let t = DispatchTime.now(); body()
    print("PROBE \(label): \(Int(Double(DispatchTime.now().uptimeNanoseconds - t.uptimeNanoseconds) / 1e6)) ms")
}

@MainActor @Suite(.enabled(if: ProcessInfo.processInfo.environment["GELPERF"] != nil)) struct AppPerfProbe {
    @Test func liveOperations() async throws {
        _ = NSApplication.shared
        let photo = p3Data()
        let top = try Data(contentsOf: docs.appendingPathComponent("top-piece.png"))
        for scenario in ["alone", "gel 2 top-to-bottom", "gel 2 side-by-side"] {
            var pkg = try GelPackage.create(imageData: scenario == "alone" ? photo : top, imageName: "a")
            if scenario != "alone" {
                let work = WorkingImage(source: try SourceImage(data: top), project: pkg.project)
                _ = GelOps.autoDividers(&pkg.project, work, count: 13)
                try pkg.addStrip(imageData: photo, imageName: "photo.tif")
                if scenario.hasSuffix("side-by-side") { pkg.project.arrangement = .sideBySide }
            }
            pkg.project.strict = false
            for i in pkg.project.strips.indices { pkg.project.strips[i].strict = false }
            let ws = Workspace(document: GelDocument(package: pkg))
            let canvas = CanvasNSView()
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1440, height: 900), styleMask: [.titled], backing: .buffered, defer: false)
            if ProcessInfo.processInfo.environment["GELPERF"] == "p3" { window.colorSpace = .displayP3 }
            canvas.workspace = ws
            window.contentView = canvas
            canvas.frame = NSRect(x: 0, y: 0, width: 1440, height: 900)
            ws.redraw = { canvas.needsDisplay = true }
            let k: Int? = scenario == "alone" ? nil : 1
            func draw() {
                guard let rep = canvas.bitmapImageRepForCachingDisplay(in: canvas.bounds) else { return }
                canvas.cacheDisplay(in: canvas.bounds, to: rep)
            }
            func settle() { ws.refreshCaches(settle: true); draw() }
            print("PROBE ---- \(scenario)")
            msPlain("first load + draw") { settle() }
            msPlain("canvas redraw") { draw() }
            ws.chooseGel(k)
            ms("brightness step (live)", draw: draw) { ws.changeContrast(live: true) { $0.black = 0.1 } }
            msPlain("  brightness: refreshCaches") { ws.changeContrast(live: true) { $0.black = 0.11 }; ws.refreshCaches() }
            msPlain("  brightness: displayCropped") { _ = ws.displayCropped }
            ms("brightness step 2", draw: draw) { ws.changeContrast(live: true) { $0.black = 0.12 } }
            ws.endContrastChange()
            ws.showGel(k); ws.tool = .crop; draw()
            ms("crop drag step", draw: draw) { if k == nil { ws.liveCrop(PixelRect(x0: 100, y0: 100, x1: 3800, y1: 2800)) } else { ws.liveStripCrop(PixelRect(x0: 100, y0: 100, x1: 3800, y1: 2800)) } }
            ws.endGesture("Crop")
            ws.tool = .select
            ws.showFigure()
            for (n, a) in [0.4, 0.5, 0.6].enumerated() {
                msPlain("  setRotation") { ws.setRotation(a) }
                msPlain("  refreshCaches") { ws.refreshCaches() }
                msPlain("  displayCropped (preview/compose)") { _ = ws.displayCropped }
                msPlain("  shownImage") { _ = ws.shownImage }
                ms("rotation live step \(n + 1) (rest)", draw: draw) { }
            }
            let rev = ws.cacheRevision
            let t0 = DispatchTime.now()
            while ws.cacheRevision == rev && Double(DispatchTime.now().uptimeNanoseconds - t0.uptimeNanoseconds) < 20e9 {
                ws.refreshCaches()   // what the next draw does first
                try await Task.sleep(for: .milliseconds(5))
            }
            print("PROBE rotation committed (change to pixels landed, incl. 80 ms hold): \(Int(Double(DispatchTime.now().uptimeNanoseconds - t0.uptimeNanoseconds) / 1e6)) ms")
            msPlain("draw after landing") { draw() }
            if let k {
                ms("gel drag step", draw: draw) { ws.liveStripShift(k, scenario.hasSuffix("side-by-side") ? 12 : 20) }
                ws.endGesture("Line Up Gel")
                ms("auto-align", draw: draw) { ws.chooseGel(k); ws.autoAlign() }
            }
            ms("switch gel view", draw: draw) { ws.showGel(k) }
            ms("switch back to figure", draw: draw) { ws.showFigure() }
            ws.showGel(k); draw()
            ms("place tick", draw: draw) { _ = ws.addTick(x: 500, y: 600, strip: k) }
        }
    }
}

private func rampPNG(_ w: Int, _ h: Int) -> Data {
    var px = [UInt8](repeating: 0, count: w * h)
    for y in 0..<h { for x in 0..<w { px[y * w + x] = UInt8(40 + (x * 150 / w + y % 7)) } }
    let img = CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: w,
                      space: CGColorSpace(name: CGColorSpace.genericGrayGamma2_2)!, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                      provider: CGDataProvider(data: Data(px) as CFData)!, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
    let out = NSMutableData()
    let dest = CGImageDestinationCreateWithData(out, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, img, nil); CGImageDestinationFinalize(dest)
    return out as Data
}

@MainActor @Suite struct AngleChangesAreInstant {
    @Test func theAngleShowsAtOnceAndTheExactPixelsComeInTheBackground() async throws {
        var pkg = try GelPackage.create(imageData: rampPNG(300, 200), imageName: "g.png")
        pkg.project.strict = false
        let ws = Workspace(document: GelDocument(package: pkg))
        ws.refreshCaches()
        let before = try #require(ws.working)
        ws.setRotation(3)
        ws.refreshCaches()
        #expect(ws.working?.rotation == before.rotation)   // not rebuilt on the spot
        #expect(ws.displayFull != nil && ws.displayFull?.width == 300)   // the old picture, turned, same size
        // an export is exact at once
        let figure = try #require(ws.figure)
        #expect(figure.main.rotation == 3 && ws.working?.rotation == 3)
        // and a change nobody waits for lands by itself
        ws.setRotation(-2)
        let rev = ws.cacheRevision
        for _ in 0..<400 where ws.cacheRevision == rev {
            ws.refreshCaches()
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(ws.cacheRevision != rev && ws.working?.rotation == -2)
        // Keep original pixels never turns the pixels, whatever the number says
        ws.setStrict(true)
        ws.refreshCaches(settle: true)
        #expect(ws.working?.rotation == 0)
    }
}

/// Writes a screenshot of the Figure view with a photo (gel 1, no lanes) beside a small scan (gel 2, the lanes), side by side, with no ticks
/// and then with ticks on both. Runs only with GELSHOT=<folder>.
@MainActor @Suite(.enabled(if: ProcessInfo.processInfo.environment["GELSHOT"] != nil)) struct SideBySideShot {
    @Test func figureView() throws {
        _ = NSApplication.shared
        let out = URL(fileURLWithPath: ProcessInfo.processInfo.environment["GELSHOT"]!)
        let top = try Data(contentsOf: docs.appendingPathComponent("top-piece.png"))
        var pkg = try GelPackage.create(imageData: top, imageName: "scan.png")
        let work = WorkingImage(source: try SourceImage(data: top), project: pkg.project)
        _ = GelOps.autoDividers(&pkg.project, work, count: 13)
        try pkg.addStrip(imageData: p3Data(), imageName: "photo.tif")
        pkg.project.mainPosition = 1            // the photo is gel 1, the scan gel 2 with the lanes
        pkg.project.arrangement = .sideBySide
        pkg.project.strict = false
        pkg.project.strips[0].strict = false
        for ticks in [false, true] {
            if ticks {
                pkg.project.ladder = Ladder(lane: 1, bands: [
                    LadderBand(y: 60, size: 100), LadderBand(y: 200, size: 40),
                    LadderBand(y: 600, size: 100, strip: 1), LadderBand(y: 2100, size: 40, strip: 1)])
            }
            var p = pkg.project
            GelOps.setArrangement(&p, .topToBottom); GelOps.setArrangement(&p, .sideBySide)   // as when switching: placement starts over
            let ws = Workspace(document: GelDocument(package: GelPackage(project: p, imageData: pkg.imageData, stripImages: pkg.stripImages)))
            ws.refreshCaches(settle: true)
            ws.setArrangement(.topToBottom); ws.setArrangement(.sideBySide)   // sized on the way in
            ws.refreshCaches(settle: true)
            let canvas = CanvasNSView()
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1440, height: 900), styleMask: [.titled], backing: .buffered, defer: false)
            canvas.workspace = ws; window.contentView = canvas; canvas.frame = NSRect(x: 0, y: 0, width: 1440, height: 900)
            ws.tool = .select
            let rep = canvas.bitmapImageRepForCachingDisplay(in: canvas.bounds)!
            canvas.cacheDisplay(in: canvas.bounds, to: rep)
            let name = ticks ? "ticks" : "noticks"
            try rep.representation(using: .png, properties: [:])!.write(to: out.appendingPathComponent("\(name).png"))
            let s = ws.stack
            print("SHOT \(name): pieces", s.pieces.map { "gel \($0.strip.map(String.init) ?? "lanes"): x \(Int($0.left))-\(Int($0.right)) y \(Int($0.top))-\(Int($0.bottom)) scale \(String(format: "%.3f", $0.scale))" }, "note:", ws.alignNote ?? "-")
        }
    }
}

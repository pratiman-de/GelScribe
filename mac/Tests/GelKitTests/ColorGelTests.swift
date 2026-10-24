import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import GelKit

/// An sRGB PNG, 8-bit or 16-bit, of distinct channels: red 180+, green 90+, blue 30+ (each with its own texture).
private func colorPNG(width: Int, height: Int, wide: Bool = false) -> Data {
    let n = wide ? 8 : 4
    var px = [UInt8](repeating: 255, count: width * height * n)
    for y in 0..<height { for x in 0..<width {
        let ch = [180 + x % 20, 90 + y % 20, 30 + (x + y) % 20]
        for c in 0..<3 {
            if wide {   // big-endian 16-bit, value times 257
                let v = UInt16(ch[c] * 257)
                px[(y * width + x) * n + c * 2] = UInt8(v >> 8); px[(y * width + x) * n + c * 2 + 1] = UInt8(v & 255)
            } else { px[(y * width + x) * n + c] = UInt8(ch[c]) }
        }
    } }
    let img = CGImage(width: width, height: height, bitsPerComponent: wide ? 16 : 8, bitsPerPixel: n * 8, bytesPerRow: width * n,
                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                      bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue | (wide ? CGBitmapInfo.byteOrder16Big.rawValue : 0)),
                      provider: CGDataProvider(data: Data(px) as CFData)!, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
    let out = NSMutableData()
    let dest = CGImageDestinationCreateWithData(out, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, img, nil)
    CGImageDestinationFinalize(dest)
    return out as Data
}

private func grayPNG(width: Int, height: Int) -> Data {
    var px = [UInt8](repeating: 0, count: width * height)
    for y in 0..<height { for x in 0..<width { px[y * width + x] = UInt8(100 + (x * 3 + y * 5) % 100) } }
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

private func adjusted(_ data: Data, rotation: Double = 0, strict: Bool = false) throws -> (GelPackage, WorkingImage) {
    var pkg = try GelPackage.create(imageData: data, imageName: "c.png")
    pkg.project.strict = strict
    pkg.project.rotateDeg = rotation
    pkg.project.display.black = 0.2; pkg.project.display.white = 0.9
    return (pkg, WorkingImage(source: try SourceImage(data: data), project: pkg.project))
}

/// The mean of each channel over a region of an 8-bit RGB image.
private func means(_ img: CGImage, x: Int, y: Int, w: Int, h: Int) -> [Double] {
    let v = RawPixels(img).region(x: x, y: y, w: w, h: h, channels: 3)
    return (0..<3).map { c in stride(from: c, to: v.count, by: 3).reduce(0.0) { $0 + Double(v[$1]) } / Double(w * h) }
}

@Suite struct ColorGels {
    @Test func aColorGelStaysColorThroughRotationRangeAndExport() throws {
        let (pkg, w) = try adjusted(colorPNG(width: 300, height: 200), rotation: 4)
        let img = try #require(w.figureImage(project: pkg.project))
        #expect(img.colorSpace?.model == .rgb && img.bitsPerComponent == 8)
        let m = means(img, x: 100, y: 80, w: 100, h: 40)
        #expect(m[0] > m[1] + 20 && m[1] > m[2] + 20)   // still red > green > blue
        // without rotation, every channel is mapped exactly as gray is: (v/255 - 0.2) / 0.7 × 255
        let (p0, w0) = try adjusted(colorPNG(width: 300, height: 200))
        let flat = try #require(w0.figureImage(project: p0.project))
        let px = RawPixels(flat).region(x: 5, y: 7, w: 1, h: 1, channels: 3)
        func map(_ v: Int) -> UInt16 { UInt16(((min(1, max(0, (Double(v) / 255 - 0.2) / 0.7))) * 255).rounded()) }
        #expect(px == [map(180 + 5 % 20), map(90 + 7 % 20), map(30 + 12 % 20)])
        // the screen shows it in colour too
        let view = try #require(w.viewImage(project: pkg.project, enhance: false))
        #expect(view.colorSpace?.model == .rgb)
        let vm = means(view, x: 100, y: 80, w: 100, h: 40)
        #expect(vm[0] > vm[1] + 20 && vm[1] > vm[2] + 20)
    }

    @Test func keepingOriginalPixelsShowsTheRangeInColorOnScreenOnly() throws {
        let (pkg, w) = try adjusted(colorPNG(width: 300, height: 200), strict: true)
        let view = try #require(w.viewImage(project: pkg.project, enhance: false))
        #expect(view.colorSpace?.model == .rgb)
        let m = means(view, x: 50, y: 50, w: 100, h: 40)
        #expect(m[0] > m[1] + 20 && m[1] > m[2] + 5)
        // the export keeps the original values
        let fig = try #require(w.figureImage(project: pkg.project))
        let got = RawPixels(fig).region(x: 5, y: 7, w: 1, h: 1, channels: 3)
        #expect(got == [UInt16(180 + 5 % 20), UInt16(90 + 7 % 20), UInt16(30 + 12 % 20)])
    }

    @Test func aStackWithAColorGelIsRGBAndGrayGelsGoInAsEqualChannels() throws {
        var pkg = try GelPackage.create(imageData: colorPNG(width: 620, height: 160), imageName: "top.png")
        try pkg.addStrip(imageData: grayPNG(width: 700, height: 220), imageName: "bottom.png")
        pkg.project.strict = false
        pkg.project.strips[0].top = 40; pkg.project.strips[0].bottom = 140
        pkg.project.strips[0].shift = 0
        let main = WorkingImage(source: try SourceImage(data: pkg.imageData), project: pkg.project)
        let strip = WorkingImage(source: try SourceImage(data: pkg.stripData(1)!), project: pkg.project.stripProject(1))
        let fig = StackedFigure(project: pkg.project, main: main, strips: [strip])
        let gel = try #require(fig.gel)
        #expect(gel.colorSpace?.model == .rgb && gel.bitsPerComponent == 8)
        let c = fig.stack.crop
        let top = fig.stack.pieces[0], bottom = fig.stack.pieces[1]
        let topMeans = means(gel, x: 100, y: Int(top.top - c.y0) + 10, w: 100, h: 20)
        #expect(topMeans[0] > topMeans[1] + 20 && topMeans[1] > topMeans[2] + 20)
        let g = RawPixels(gel).region(x: 100, y: Int(bottom.top - c.y0) + 10, w: 50, h: 20, channels: 3)
        #expect(stride(from: 0, to: g.count, by: 3).allSatisfy { g[$0] == g[$0 + 1] && g[$0] == g[$0 + 2] })
        #expect(fig.info().description.contains("converted to 8-bit RGB"))
        // and with only gray gels the stack is gray, as before
        var gray = try GelPackage.create(imageData: grayPNG(width: 620, height: 160), imageName: "top.png")
        try gray.addStrip(imageData: grayPNG(width: 700, height: 220), imageName: "bottom.png")
        gray.project.strict = false
        gray.project.strips[0].top = 40; gray.project.strips[0].bottom = 140
        let gm = WorkingImage(source: try SourceImage(data: gray.imageData), project: gray.project)
        let gs = WorkingImage(source: try SourceImage(data: gray.stripData(1)!), project: gray.project.stripProject(1))
        let grayGel = try #require(StackedFigure(project: gray.project, main: gm, strips: [gs]).gel)
        #expect(grayGel.colorSpace?.model == .monochrome)
    }

    @Test func grayGelsAreUnchanged() throws {
        let (pkg, w) = try adjusted(grayPNG(width: 300, height: 200), rotation: 2)
        let img = try #require(w.figureImage(project: pkg.project))
        #expect(img.colorSpace?.model == .monochrome && img.bitsPerPixel == 8)
        #expect(!ExportInfo.for(pkg.project, sourceSHA256: nil).description.contains("converted"))
    }

    @Test func provenanceSaysConvertedUnlessItWas8BitRGB() throws {
        for (wide, says) in [(false, false), (true, true)] {
            let data = colorPNG(width: 100, height: 80, wide: wide)
            let (pkg, w) = try adjusted(data)
            let info = ExportInfo.for(pkg.project, sourceSHA256: nil, colorGels: StripStack.colorGels(main: w, strips: []))
            #expect(info.description.contains("converted to 8-bit RGB") == says)
        }
    }

    /// A gray PNG of 8 or 16 bits per sample.
    private func grayStored(width: Int, height: Int, wide: Bool) -> Data {
        var px = [UInt8](repeating: 0, count: width * height * (wide ? 2 : 1))
        for y in 0..<height { for x in 0..<width {
            let v = (x * 37 + y * 91) % 60000 + 100
            if wide { px[(y * width + x) * 2] = UInt8(v >> 8); px[(y * width + x) * 2 + 1] = UInt8(v & 255) } else { px[y * width + x] = UInt8(v % 200 + 20) }
        } }
        let img = CGImage(width: width, height: height, bitsPerComponent: wide ? 16 : 8, bitsPerPixel: wide ? 16 : 8, bytesPerRow: width * (wide ? 2 : 1),
                          space: CGColorSpace(name: CGColorSpace.genericGrayGamma2_2)!,
                          bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue | (wide ? CGBitmapInfo.byteOrder16Big.rawValue : 0)),
                          provider: CGDataProvider(data: Data(px) as CFData)!, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
        let out = NSMutableData()
        let dest = CGImageDestinationCreateWithData(out, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, img, nil)
        CGImageDestinationFinalize(dest)
        return out as Data
    }

    @Test func aKeptGrayGelAndAnAddedColorGelMakeAnRGBFigure() throws {
        for wide in [true, false] {
            var pkg = try GelPackage.create(imageData: grayStored(width: 620, height: 160, wide: wide), imageName: "top.png")
            try pkg.addStrip(imageData: colorPNG(width: 700, height: 220), imageName: "bottom.png")
            pkg.project.strict = true   // the gray scan keeps its original pixels; the added colour gel doesn't
            pkg.project.strips[0].strict = false
            pkg.project.strips[0].top = 40; pkg.project.strips[0].bottom = 140
            pkg.project.strips[0].shift = 0
            let main = WorkingImage(source: try SourceImage(data: pkg.imageData), project: pkg.project)
            let strip = WorkingImage(source: try SourceImage(data: pkg.stripData(1)!), project: pkg.project.stripProject(1))
            let fig = StackedFigure(project: pkg.project, main: main, strips: [strip])
            let gel = try #require(fig.gel)
            #expect(gel.colorSpace?.model == .rgb && gel.bitsPerComponent == (wide ? 16 : 8))
            let c = fig.stack.crop, bottom = try #require(fig.stack.piece(strip: 1))
            // the gray gel: its exact values in R, G and B
            let w0 = Int(c.width), h0 = 160 - Int(c.y0)
            let rgb = RawPixels(gel).region(x: 0, y: 0, w: w0, h: h0, channels: 3)
            let original = RawPixels(main.source.cgImage).region(x: Int(c.x0), y: Int(c.y0), w: w0, h: h0, channels: 1)
            #expect((0..<original.count).allSatisfy { rgb[3 * $0] == original[$0] && rgb[3 * $0 + 1] == original[$0] && rgb[3 * $0 + 2] == original[$0] })
            // the colour gel stays colour, scaled to the output's depth
            let px = RawPixels(gel).region(x: 100, y: Int(bottom.top - c.y0) + 10, w: 50, h: 20, channels: 3)
            let r = px[0], g = px[1], b = px[2]
            #expect(r > g && g > b)
            if wide { #expect(px.allSatisfy { $0 % 257 == 0 }) }
            let note = fig.info().description
            #expect(note.contains("original values, copied to all three channels"))
            // an 8-bit RGB gel in an 8-bit RGB output isn't converted; a 16-bit output scales it
            #expect(note.contains("converted to 16-bit RGB (values times 257)") == wide)
            #expect(!note.contains("converted to 8-bit"))
        }
    }

    /// A Display P3 image of a saturated colour, as a phone photo has.
    private func p3PNG() -> Data {
        let ctx = CGContext(data: nil, width: 64, height: 48, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.displayP3)!,
                            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        ctx.setFillColor(CGColor(colorSpace: CGColorSpace(name: CGColorSpace.displayP3)!, components: [0.95, 0.3, 0.2, 1])!)
        ctx.fill(CGRect(x: 0, y: 0, width: 64, height: 48))
        let out = NSMutableData()
        let dest = CGImageDestinationCreateWithData(out, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
        CGImageDestinationFinalize(dest)
        return out as Data
    }

    private func inSRGB(_ img: CGImage) -> [UInt8] {
        let ctx = CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        ctx.draw(img, in: CGRect(x: -10, y: -10, width: img.width, height: img.height))
        let d = ctx.data!.bindMemory(to: UInt8.self, capacity: 4)
        return [d[0], d[1], d[2]]
    }

    @Test func displayP3ColoursComeOutRightOnScreenAndInExports() throws {
        let data = p3PNG()
        var pkg = try GelPackage.create(imageData: data, imageName: "p3.png")
        pkg.project.strict = false
        let src = try SourceImage(data: data)
        let w = WorkingImage(source: src, project: pkg.project)
        let want = inSRGB(src.cgImage)
        let view = try #require(w.viewImage(project: pkg.project, enhance: false))
        let fig = try #require(w.figureImage(project: pkg.project))
        #expect(view.colorSpace?.name == CGColorSpace.displayP3 && fig.colorSpace?.name == CGColorSpace.displayP3)
        #expect(inSRGB(view) == want && inSRGB(fig) == want)
        // a stack converts to sRGB through the colour management, same appearance
        var two = try GelPackage.create(imageData: grayPNG(width: 100, height: 60), imageName: "g.png")
        try two.addStrip(imageData: data, imageName: "p3.png")
        two.project.strict = false
        let main = WorkingImage(source: try SourceImage(data: two.imageData), project: two.project)
        let strip = WorkingImage(source: try SourceImage(data: two.stripData(1)!), project: two.project.stripProject(1))
        let stacked = try #require(StackedFigure(project: two.project, main: main, strips: [strip]).gel)
        #expect(stacked.colorSpace?.model == .rgb)
    }

    @Test func movingTheRangeAgainRemapsTheCachedPixels() throws {
        let (pkg, w) = try adjusted(colorPNG(width: 300, height: 200), rotation: 3)
        var project = pkg.project
        let first = RawPixels(try #require(w.viewImage(project: project, enhance: false))).region(x: 150, y: 100, w: 1, h: 1, channels: 3)
        project.display.black = 0.5; project.display.white = 0.6
        let second = RawPixels(try #require(w.viewImage(project: project, enhance: false))).region(x: 150, y: 100, w: 1, h: 1, channels: 3)
        project.display = DisplaySettings()
        let plain = RawPixels(try #require(w.viewImage(project: project, enhance: false))).region(x: 150, y: 100, w: 1, h: 1, channels: 3)
        #expect(first != second && plain != first)
        #expect(second == [0, 0, 0] || second.contains(255) || second != plain)
        // the original values come back when the range is reset: red 180-199, green 90-109, blue 30-49
        #expect(plain[0] >= 175 && plain[0] <= 205 && plain[2] <= 55)
    }
}

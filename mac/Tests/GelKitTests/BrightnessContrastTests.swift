import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import GelKit

/// A 16-bit gray TIFF, optionally with an ImageJ-style description.
private func tiff16(width: Int, height: Int, description: String? = nil, _ value: (Int, Int) -> UInt16) -> Data {
    var px = [UInt16](repeating: 0, count: width * height)
    for y in 0..<height { for x in 0..<width { px[y * width + x] = value(x, y) } }
    let provider = CGDataProvider(data: Data(bytes: px, count: px.count * 2) as CFData)!
    let img = CGImage(width: width, height: height, bitsPerComponent: 16, bitsPerPixel: 16, bytesPerRow: width * 2,
                      space: CGColorSpace(name: CGColorSpace.genericGrayGamma2_2)!,
                      bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue | CGBitmapInfo.byteOrder16Little.rawValue),
                      provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
    let out = NSMutableData()
    let dest = CGImageDestinationCreateWithData(out, UTType.tiff.identifier as CFString, 1, nil)!
    var props: [CFString: Any] = [:]
    if let description { props[kCGImagePropertyTIFFDictionary] = [kCGImagePropertyTIFFImageDescription: description] }
    CGImageDestinationAddImage(dest, img, props as CFDictionary)
    CGImageDestinationFinalize(dest)
    return out as Data
}

/// A faint scan: background 1500, a darker band (1000) across rows 95–105, a ramp elsewhere so values vary.
private func faintGel(description: String? = nil) -> Data {
    tiff16(width: 60, height: 200, description: description) { x, y in (95...105).contains(y) ? 1000 : UInt16(1400 + (x + y) % 100) }
}

@Suite struct BrightnessContrast {
    @Test func imageJRangeIsReadFromTheDescription() {
        #expect(SourceImage.imageJRange("ImageJ=1.54p\nunit=cm\nmin=5.0\nmax=503.0\n") == 5...503)
        #expect(SourceImage.imageJRange("Scanned on a Typhoon") == nil)
        #expect(SourceImage.imageJRange("ImageJ=1.54p\nmin=10\n") == nil)
    }

    @Test func whiteIsZeroFilesShowTheirOwnNumbers() {
        let s = ValueScale(maxValue: 65535, inverted: true)
        var d = DisplaySettings()
        d.setRange(min: 5, max: 503, in: s)
        #expect(abs(d.white - (1 - 5.0 / 65535)) < 1e-12 && abs(d.black - (1 - 503.0 / 65535)) < 1e-12)
        let r = d.range(in: s)
        #expect(abs(r.min - 5) < 1e-6 && abs(r.max - 503) < 1e-6)
    }

    @Test func sixteenBitImagesOpenLikeImageJ() throws {
        let saved = try GelPackage.create(imageData: faintGel(description: "ImageJ=1.54p\nmin=1100.0\nmax=1450.0\n"), imageName: "a.tif")
        let s = try SourceImage(data: saved.imageData).scale
        let r = saved.project.display.range(in: s)
        #expect(abs(r.min - 1100) < 0.5 && abs(r.max - 1450) < 0.5, "ImageJ's saved range: \(r)")

        let plain = try GelPackage.create(imageData: faintGel(), imageName: "b.tif")
        let r2 = plain.project.display.range(in: s)
        #expect(abs(r2.min - 1000) < 0.5 && abs(r2.max - 1499) < 0.5, "darkest to brightest: \(r2)")
        #expect(plain.project.strict)
    }

    @Test func eightBitImagesStartUnchanged() throws {
        let png = FigureRenderer.encode(try #require(GrayImage(width: 4, height: 4, pixels: (0..<16).map { Float($0) / 15 })
            .cgImage(display: DisplaySettings())), as: .png, dpi: 72, info: ExportInfo(title: "", description: ""))
        #expect(try GelPackage.create(imageData: png, imageName: "c.png").project.display.isIdentity)
    }

    @Test func stretchingAFaintRangeKeepsEveryLevel() throws {
        // 256 neighbouring 16-bit values, stretched across the screen: each gets its own output level
        let g = GrayImage(width: 256, height: 1, pixels: (0..<256).map { Float(1000 + $0) / 65535 }, sourceBits: 16)
        var d = DisplaySettings()
        d.setRange(min: 1000, max: 1255, in: ValueScale(maxValue: 65535))
        let img = try #require(g.cgImage(display: d))
        let bytes = [UInt8](img.dataProvider!.data! as Data)
        #expect(Set(bytes).count >= 250, "only \(Set(bytes).count) distinct levels")
    }

    @Test func strictExportsIgnoreTheDisplayRange() throws {
        var pkg = try GelPackage.create(imageData: faintGel(), imageName: "d.tif")
        #expect(pkg.project.strict && !pkg.project.display.isIdentity)
        let w = WorkingImage(source: try SourceImage(data: pkg.imageData), project: pkg.project)
        let gel = try #require(w.figureImage(project: pkg.project))
        #expect(gel.bitsPerComponent == 16)
        #expect(RawPixels(gel).region(x: 0, y: 0, w: 60, h: 200, channels: 1)
                == RawPixels(w.source.cgImage).region(x: 0, y: 0, w: 60, h: 200, channels: 1))

        pkg.project.strict = false
        let info = ExportInfo.for(pkg.project, sourceSHA256: nil, scale: w.source.scale)
        #expect(info.description.contains("display range 1000–1499 of 65535"), "\(info.description)")
    }

    @Test func clicksSnapToFaintBands() throws {
        let src = try SourceImage(data: faintGel())
        let w = WorkingImage(source: src, project: GelProject(image: "e.tif"))
        let y = try #require(Detect.snapBand(in: w.darkness(bandsDark: true), x: 30, y: 92, laneWidth: 40))
        #expect(abs(y - 100) <= 2, "snapped to \(y)")
    }
}

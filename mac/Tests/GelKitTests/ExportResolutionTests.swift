import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import GelKit

@Suite(.enabled(if: hasFixture, "needs TestData/gel.png")) struct ExportResolution {
    private func setup() throws -> (GelProject, FigureLayout, CGImage, SourceImage) {
        let src = try SourceImage(data: try Data(contentsOf: fixtureURL))
        var p = GelProject(image: "gel.png")
        p.crop = PixelRect(x0: 20, y0: 80, x1: 1940, y1: 1290)
        p.lanes.centers = [114, 272, 430, 589, 747, 905, 1063, 1222, 1380, 1538, 1696, 1855]
        p.lanes.width = 130
        p.rows = [LabelRow(type: .lanes, labels: ["", "L", "P", "L", "P", "L", "P", "L", "P", "L", "P", ""])]
        let w = WorkingImage(source: src, project: p)
        let layout = FigureLayoutEngine.layout(p, imageWidth: w.width, imageHeight: w.height)
        return (p, layout, try #require(w.figureImage(project: p)), src)
    }

    private func dpi(_ data: Data) -> Double? {
        guard let s = CGImageSourceCreateWithData(data as CFData, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(s, 0, nil) as? [CFString: Any] else { return nil }
        return (props[kCGImagePropertyDPIWidth] as? NSNumber)?.doubleValue
    }

    @Test func nativeOrUnsetStaysOneToOne() throws {
        let (p, layout, gel, src) = try setup()
        let native = FigureRenderer.nativeDPI(layout)
        #expect(FigureRenderer.resampleDPI(nil, layout) == nil)
        #expect(FigureRenderer.resampleDPI(native, layout) == nil)
        let info = ExportInfo.for(p, sourceSHA256: src.sha256)
        let a = try #require(FigureRenderer.rasterData(layout, gel: gel, type: .png, info: info))
        let b = try #require(FigureRenderer.rasterData(layout, gel: gel, type: .png, info: info, dpi: native))
        #expect(a == b, "asking for the native resolution must not change the file")
        let original = RawPixels(src.cgImage).region(x: 20, y: 80, w: 1920, h: 1210, channels: 3)
        #expect(locate(RawPixels(decode(b)), original, w: 1920, h: 1210, channels: 3) != nil)
    }

    @Test func otherResolutionsRedrawAtThatSizeAndSaySo() throws {
        let (p, layout, gel, src) = try setup()
        let native = FigureRenderer.nativeDPI(layout)
        for target in [300.0, 1200] {
            #expect(FigureRenderer.resampleDPI(target, layout) == target)
            let info = ExportInfo.for(p, sourceSHA256: src.sha256, resampledDPI: target, nativeDPI: native)
            #expect(info.description.contains("resampled to \(Int(target)) dpi from \(Int(native.rounded())) dpi"))
            #expect(!info.description.contains("not resampled"))
            for type in [UTType.png, .tiff] {
                let data = try #require(FigureRenderer.rasterData(layout, gel: gel, type: type, info: info, dpi: target))
                let img = decode(data)
                #expect(img.width == Int((layout.size.width * target / 72).rounded()))
                #expect(img.height == Int((layout.size.height * target / 72).rounded()))
                #expect(dpi(data) == target)
            }
        }
    }
}

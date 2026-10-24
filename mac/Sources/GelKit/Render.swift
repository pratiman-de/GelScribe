import CoreGraphics
import CoreText
import Foundation
import ImageIO
import UniformTypeIdentifiers

public struct ExportInfo: Sendable {
    public var title: String
    /// Provenance written into the file (PDF Subject / PNG Description / TIFF ImageDescription).
    public var description: String
    public init(title: String, description: String) { self.title = title; self.description = description }

    /// `resampledDPI`: a raster export redrawn at that resolution instead of the native `nativeDPI`. With the source's
    /// `scale`, brightness & contrast are given in the file's own values ("display range 5–503 of 65535").
    /// `strips`: each strip's image hash and value scale, for a stack of gels. `size` and `stripSizes`: the working-image
    /// size of the gel with the lanes and of each strip; with them the note says the crop and rows that were actually used
    /// (whole pixels, inside the image), without them the stored numbers. `convertedTo`: how the output is stored when some
    /// gels keep their original pixels and others don't ("16-bit gray"): the others are converted into it. With none keeping
    /// them, the stack is stored as 8-bit gray or RGB (`StripStack.outputIsGray`), and the note says so the same way.
    /// `colorGels`: how each colour gel was stored by gel number (0 = the gel with the lanes, k = strip k; `StripStack.colorGels`):
    /// an adjusted colour gel is stored as 8-bit RGB and the note says "converted to 8-bit RGB" unless it was that already.
    /// The note starts with a warning line for each gel whose image no longer matches its fingerprint
    /// (`changedImageWarnings`), and leaves out every gel's file name when the project's `exportFileNames` is off.
    public static func `for`(_ p: GelProject, sourceSHA256: String?, resampledDPI: Double? = nil, nativeDPI: Double? = nil,
                             scale: ValueScale? = nil, strips: [(sha256: String?, scale: ValueScale?)] = [],
                             size: (width: Int, height: Int)? = nil, stripSizes: [(width: Int, height: Int)?] = [],
                             convertedTo: String? = nil, colorGels: [Int: String] = [:]) -> ExportInfo {
        let cropText: String
        if let crop = p.crop {
            let r = size.map { p.effectiveCrop(width: $0.width, height: $0.height) } ?? crop
            cropText = "crop \(r.x0.safeInt),\(r.y0.safeInt),\(r.x1.safeInt),\(r.y1.safeInt)"
        } else {
            cropText = "full frame"
        }
        let c = (p.turn != 0 ? "turned \(p.turn * 90)°, " : "") + cropText
        let levels = scale.map { s -> String in
            let r = p.display.range(in: s)
            return "display range \(s.format(r.min))–\(s.format(r.max)) of \(s.format(s.maxValue))"
        } ?? "levels \(p.display.black)–\(p.display.white)"
        var adjusted = "rotation \(p.rotateDeg)°, \(levels), gamma \(p.display.gamma)\(p.display.invert ? ", inverted" : "")"
        if p.strips.isEmpty, let stored = colorGels[0], stored != "8-bit RGB" { adjusted += ", converted to 8-bit RGB" }
        let names = p.exportFileNames
        // Some gels keep their original pixels and some don't: the lanes gel's setting alone says nothing about the others, so the
        // headline says "mixed" and each gel below says its own
        let kept = ([nil] + p.strips.indices.map { Optional($0 + 1) }).map { p.isStrict(gel: $0) }
        let mixed = kept.contains(true) && kept.contains(false)
        var pixels = mixed ? mixedHeadline : p.strict
            ? "Gel pixels: original values, bit depth and color space, not resampled (strict); \(c)."
            : "Gel pixels: adjusted (\(adjusted)); \(c)."
        if let dpi = resampledDPI {
            let from = nativeDPI.map { " from \($0.rounded().safeInt) dpi" } ?? ""
            pixels = mixed ? "\(mixedHeadline) Resampled to \(dpi.rounded().safeInt) dpi\(from); \(c)."
                : "Gel pixels: resampled to \(dpi.rounded().safeInt) dpi\(from)" +
                    (p.strict ? ", otherwise unadjusted" : " after adjustments (\(adjusted))") + "; \(c)."
        }
        let hash = sourceSHA256.map { " Source\(names ? " \(p.image)" : "") sha256 \($0)." } ?? ""
        var ladder = ""
        if let l = p.ladder, let name = l.name {
            ladder = " Ladder: \(name)" + (l.system.map { ", apparent sizes for \($0)" } ?? "") + "."
        }
        var pieces = ""
        let mainSize = size   // the gel with the lanes' working size, when known (a strip's own size is called `size` below)
        if !p.strips.isEmpty {
            pieces = " \(p.strips.count + 1) separately scanned gels, \(p.isSideBySide ? "left to right" : "top to bottom"), with a \(p.separatorColor.name) line between each:"
            // what converting into the output's storage did: 8-bit values times 257 for 16-bit
            let conversion = convertedTo.map { "converted to \($0)" + ($0.hasPrefix("16-bit") ? " (values times 257)" : "") }
            /// A colour gel that is 8-bit RGB already is not converted when the stack is 8-bit RGB.
            /// A gray gel that keeps its pixels in an RGB output goes in with its values copied to each channel.
            func copied(_ gel: Int) -> Bool { convertedTo?.hasSuffix("RGB") == true && colorGels[gel] == nil && p.isStrict(gel: gel == 0 ? nil : gel) }
            func conversionNote(for gel: Int) -> String? {
                convertedTo == "8-bit RGB" && colorGels[gel] == "8-bit RGB" ? nil : conversion
            }
            for (n, k) in p.stackOrder.enumerated() {
                guard let k else {
                    var main = p.isSideBySide ? "the reference for vertical placement" : "as above (its lanes are the figure's)"
                    if mixed && p.strict && copied(0) { main += ", original values, copied to all three channels" }
                    if mixed && p.turn != 0 { main += ", turned \(p.turn * 90)°" }   // the headline that said so is the mixed one now
                    if mixed && !p.strict { main += ", \(adjusted)" }   // and so is the one that said what was done to this gel's pixels
                    if let size {   // the kept rectangle, as the figure took it
                        let r = p.effectiveCrop(width: size.width, height: size.height)
                        main += ", columns \(r.x0.safeInt)–\(r.x1.safeInt), rows \(r.y0.safeInt)–\(r.y1.safeInt)"
                    }
                    if p.effectiveMainShift != 0, !p.isSideBySide { main += ", shifted \(FigureLayoutEngine.formatSize(p.effectiveMainShift)) px" }
                    if !p.strict, let conversion = conversionNote(for: 0) { main += ", \(conversion)" }
                    pieces += " \(n + 1). " + (names ? "\(p.image), " : "") + "\(main);"
                    continue
                }
                let i = k - 1, s = p.strips[i]
                let a = p.effectiveAlignment(k)
                let keeps = p.isStrict(gel: k)
                var parts: [String] = []
                if keeps { parts.append("original pixels") }
                if keeps && copied(k) { parts.append("original values, copied to all three channels") }
                if s.turn != 0 { parts.append("turned \(s.turn * 90)°") }
                if !keeps && s.rotateDeg != 0 { parts.append("rotation \(s.rotateDeg)°") }
                if let size = i < stripSizes.count ? stripSizes[i] : nil, let main = mainSize {
                    // the columns and rows the figure took (its kept rectangle), as stacked
                    let c = p.keptColumns(strip: k, width: size.width, mainWidth: main.width, mainHeight: main.height)
                    let r = s.usedRows(height: size.height)
                    parts.append("columns \(c.left.safeInt)–\(c.right.safeInt), rows \(r.top.safeInt)–\(r.bottom.safeInt)")
                } else {
                    // without the sizes: the numbers stored, an edge with none being where the lanes gel's crop falls on this gel
                    parts.append("columns \(s.left.map { String($0.rounded().safeInt) } ?? "crop")–\(s.right.map { String($0.rounded().safeInt) } ?? "crop"), " +
                                 "rows \((s.top ?? 0).rounded().safeInt)–\(s.bottom.map { String($0.rounded().safeInt) } ?? "end")")
                }
                let way = p.isSideBySide ? " vertically" : ""
                parts.append("shifted \(FigureLayoutEngine.formatSize(a.shift)) px\(way)")
                if a.scale != 1 {
                    parts.append(p.isSideBySide ? "sized \(String(format: "%.4f", a.scale))× in both directions (resampled)"
                                 : "stretched (scaled \(String(format: "%.4f", a.scale))×)")
                }
                if !keeps {   // brightness & contrast only reach the pixels of a gel that doesn't keep its original ones
                    if let sc = i < strips.count ? strips[i].scale : nil {
                        let r = s.display.range(in: sc)
                        parts.append("display range \(sc.format(r.min))–\(sc.format(r.max)) of \(sc.format(sc.maxValue))")
                    }
                    if s.display.gamma != 1 { parts.append("gamma \(s.display.gamma)") }
                    if s.display.invert { parts.append("inverted") }
                    if let conversion = conversionNote(for: k) { parts.append(conversion) }
                }
                var head = names ? s.image : ""   // "other.png sha256 …": the file name and fingerprint, whichever there are
                if let sha = i < strips.count ? strips[i].sha256 : nil { head += (head.isEmpty ? "" : " ") + "sha256 \(sha)" }
                pieces += " \(n + 1). " + (head.isEmpty ? "" : head + ", ") + "\(parts.joined(separator: ", "));"
            }
            pieces = String(pieces.dropLast()) + "."
        }
        let warnings = changedImageWarnings(p, sourceSHA256: sourceSHA256, strips: strips.map(\.sha256), fileNames: names)
        return ExportInfo(title: p.title ?? (names ? p.image : "GelScribe figure"),
                          description: (warnings + ["GelScribe figure. \(pixels)\(ladder)\(hash)\(pieces)"]).joined(separator: "\n"))
    }

    /// The headline when some gels keep their original pixels and some don't (it stands in for the one that says what was done to
    /// the figure's gel pixels as a whole).
    static let mixedHeadline = "Gel pixels: mixed. Some gels keep their original values and some were changed; see each gel below."

    /// "Warning: Gel N's image (FILE) has changed since it was added; its SHA-256 no longer matches." for each gel (N counted from
    /// the top of the figure) whose current SHA-256 differs from the fingerprint recorded when it was added; none for a gel with no
    /// fingerprint, or no hash now (an image that can't be read stops an export anyway). `strips`: each strip's current SHA-256.
    /// `fileNames` false leaves " (FILE)" out, for what goes into an exported file.
    public static func changedImageWarnings(_ p: GelProject, sourceSHA256: String?, strips: [String?], fileNames: Bool = true) -> [String] {
        var gels: [(n: Int, file: String)] = []
        if let want = p.imageSHA256, let now = sourceSHA256, want != now { gels.append((p.position(of: nil) + 1, p.image)) }
        for (i, s) in p.strips.enumerated() {
            if let want = s.imageSHA256, i < strips.count, let now = strips[i], want != now { gels.append((p.position(of: i + 1) + 1, s.image)) }
        }
        return gels.sorted { $0.n < $1.n }.map {
            "Warning: Gel \($0.n)'s image" + (fileNames ? " (\($0.file))" : "") + " has changed since it was added; its SHA-256 no longer matches."
        }
    }
}

public enum FigureRenderer {
    /// The biggest raster a figure is drawn as: a side longer than this, or more pixels altogether, is refused (the render
    /// returns nil) rather than asking for memory that can't exist.
    public static let maxSide = 100_000
    public static let maxPixels = 500_000_000

    // MARK: drawing

    /// Draws into a context whose user space is y-down points (a flipped NSView, or after `flipForPoints`).
    public static func draw(_ layout: FigureLayout, gel: CGImage?, in ctx: CGContext, interpolate: Bool = false) {
        if let gel {
            ctx.saveGState()
            ctx.interpolationQuality = interpolate ? .high : .none
            ctx.translateBy(x: layout.gelRect.minX, y: layout.gelRect.maxY)
            ctx.scaleBy(x: 1, y: -1)
            ctx.draw(gel, in: CGRect(origin: .zero, size: layout.gelRect.size))
            ctx.restoreGState()
        }
        drawOverlay(layout, in: ctx)
    }

    /// Everything except the gel pixels. The gel rectangle is clipped out first, so no overlay — border, tick,
    /// arrow or anti-aliased edge — can ever touch a gel pixel.
    public static func drawOverlay(_ layout: FigureLayout, in ctx: CGContext) {
        ctx.saveGState()
        let page = CGRect(origin: .zero, size: layout.size).insetBy(dx: -layout.size.width, dy: -layout.size.height)
        ctx.addRect(page)
        ctx.addRect(layout.gelRect)
        ctx.clip(using: .evenOdd)
        let black = CGColor(gray: 0, alpha: 1)
        ctx.setStrokeColor(black)
        ctx.setFillColor(black)
        ctx.setLineCap(.butt)
        ctx.setLineJoin(.miter)
        if let bw = layout.borderWidth {
            // entirely outside the gel, so no gel pixel is ever covered
            ctx.setLineWidth(bw)
            ctx.stroke(layout.gelRect.insetBy(dx: -bw / 2, dy: -bw / 2))
        }
        for l in layout.lines where l.points.count >= 2 {
            ctx.setLineWidth(l.width)
            ctx.beginPath()
            ctx.addLines(between: l.points)
            ctx.strokePath()
        }
        for poly in layout.fills where poly.count >= 3 {
            ctx.beginPath()
            ctx.addLines(between: poly)
            ctx.closePath()
            ctx.fillPath()
        }
        for t in layout.texts { drawText(t, in: ctx) }
        ctx.restoreGState()
    }

    public static func drawText(_ t: FigureText, in ctx: CGContext) {
        ctx.saveGState()
        ctx.translateBy(x: t.origin.x, y: t.origin.y)
        if t.rotation != 0 { ctx.rotate(by: -t.rotation * .pi / 180) }   // y-down: negative = counter-clockwise
        ctx.scaleBy(x: 1, y: -1)
        ctx.textMatrix = .identity
        for (k, s) in t.lines.enumerated() {   // each line aligned on its own, like centred text in any editor
            let line = Typesetter.line(s, t.font)
            let w = CTLineGetTypographicBounds(line, nil, nil, nil)
            let dx: Double = t.align == .left ? 0 : t.align == .center ? -w / 2 : -w
            ctx.textPosition = CGPoint(x: dx, y: -(t.firstBaseline + Double(k) * t.lineHeight))
            CTLineDraw(line, ctx)
        }
        ctx.restoreGState()
    }

    /// For contexts with the usual y-up origin at the bottom-left.
    public static func flipForPoints(_ ctx: CGContext, height: Double, scale: Double = 1) {
        ctx.translateBy(x: 0, y: height * scale)
        ctx.scaleBy(x: scale, y: -scale)
    }

    // MARK: PDF

    public static func pdf(_ layout: FigureLayout, gel: CGImage?, info: ExportInfo) -> Data {
        let data = NSMutableData()
        var box = CGRect(origin: .zero, size: layout.size)
        let aux: [CFString: Any] = [kCGPDFContextCreator: "GelScribe", kCGPDFContextTitle: info.title,
                                    kCGPDFContextSubject: info.description]
        guard let consumer = CGDataConsumer(data: data as CFMutableData),
              let ctx = CGContext(consumer: consumer, mediaBox: &box, aux as CFDictionary) else { return Data() }
        ctx.beginPDFPage(nil)
        flipForPoints(ctx, height: layout.size.height)
        draw(layout, gel: gel, in: ctx)
        ctx.endPDFPage()
        ctx.closePDF()
        return data as Data
    }

    // MARK: raster

    /// Renders at the gel's native resolution: one gel pixel = one output pixel. The context takes the gel image's
    /// own color space and bit depth, and the gel is drawn unscaled on whole pixels, so its values come through
    /// exactly (verified by the tests).
    public static func raster(_ layout: FigureLayout, gel: CGImage?) -> CGImage? {
        let k = 1 / layout.ptPerPx
        let W = (layout.size.width * k).rounded().safeInt, H = (layout.size.height * k).rounded().safeInt
        guard W > 0, H > 0, W <= maxSide, H <= maxSide, W * H <= maxPixels,
              let ctx = bitmapContext(width: W, height: H, like: gel) else { return nil }
        ctx.setFillColor(CGColor(gray: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: W, height: H))
        if let gel {
            // device pixels, y-up
            let gx = (layout.gelRect.minX * k).rounded().safeInt
            let gyTop = (layout.gelRect.minY * k).rounded().safeInt
            ctx.saveGState()
            ctx.interpolationQuality = .none
            ctx.setShouldAntialias(false)
            ctx.draw(gel, in: CGRect(x: gx, y: H - gyTop - gel.height, width: gel.width, height: gel.height))
            ctx.restoreGState()
        }
        ctx.saveGState()
        flipForPoints(ctx, height: layout.size.height, scale: k)
        drawOverlay(layout, in: ctx)
        ctx.restoreGState()
        return ctx.makeImage()
    }

    static func bitmapContext(width w: Int, height h: Int, like img: CGImage?) -> CGContext? {
        let space = img?.colorSpace
        let model = space?.model ?? .monochrome
        let bpc = img?.bitsPerComponent ?? 8
        let isFloat = img.map { $0.bitmapInfo.contains(.floatComponents) } ?? false
        let gray = CGColorSpace(name: CGColorSpace.genericGrayGamma2_2)!
        let srgb = CGColorSpace(name: CGColorSpace.sRGB)!
        switch (model, bpc, isFloat) {
        case (.monochrome, 32, true):
            return CGContext(data: nil, width: w, height: h, bitsPerComponent: 32, bytesPerRow: 0, space: space!,
                             bitmapInfo: CGImageAlphaInfo.none.rawValue | CGBitmapInfo.floatComponents.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        case (.monochrome, 16, _):
            return CGContext(data: nil, width: w, height: h, bitsPerComponent: 16, bytesPerRow: 0, space: space!,
                             bitmapInfo: CGImageAlphaInfo.none.rawValue | CGBitmapInfo.byteOrder16Little.rawValue)
        case (.monochrome, _, _):
            return CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: space ?? gray,
                             bitmapInfo: CGImageAlphaInfo.none.rawValue)
        case (.rgb, 32, true):
            return CGContext(data: nil, width: w, height: h, bitsPerComponent: 32, bytesPerRow: 0, space: space!,
                             bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue | CGBitmapInfo.floatComponents.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        case (.rgb, 16, _):
            return CGContext(data: nil, width: w, height: h, bitsPerComponent: 16, bytesPerRow: 0, space: space!,
                             bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue | CGBitmapInfo.byteOrder16Little.rawValue)
        case (.rgb, _, _):
            return CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: space!,
                             bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        default:
            return CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: srgb,
                             bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        }
    }

    public static func encode(_ image: CGImage, as type: UTType, dpi: Double, info: ExportInfo) -> Data {
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data as CFMutableData, type.identifier as CFString, 1, nil) else { return Data() }
        var props: [CFString: Any] = [kCGImagePropertyDPIWidth: dpi, kCGImagePropertyDPIHeight: dpi]
        if type == .png {
            props[kCGImagePropertyPNGDictionary] = [kCGImagePropertyPNGDescription: info.description,
                                                    kCGImagePropertyPNGTitle: info.title,
                                                    kCGImagePropertyPNGSoftware: "GelScribe"]
        } else if type == .tiff {
            props[kCGImagePropertyTIFFDictionary] = [kCGImagePropertyTIFFImageDescription: info.description,
                                                     kCGImagePropertyTIFFSoftware: "GelScribe",
                                                     kCGImagePropertyTIFFCompression: 5]   // LZW, lossless
        }
        CGImageDestinationAddImage(dest, image, props as CFDictionary)
        CGImageDestinationFinalize(dest)
        return data as Data
    }

    /// Resolution of a native raster: one gel pixel per output pixel.
    public static func nativeDPI(_ layout: FigureLayout) -> Double { 72 / layout.ptPerPx }

    /// The resolution a raster export is redrawn at, or nil when it stays native (`requested` nil or native).
    public static func resampleDPI(_ requested: Double?, _ layout: FigureLayout) -> Double? {
        guard let d = requested, d.isFinite, d > 0, abs(d - nativeDPI(layout)) > 0.5 else { return nil }
        return d
    }

    /// The figure redrawn at `dpi`: text and lines drawn at that density, the gel resampled (high-quality
    /// interpolation) into its place. Same color space and bit depth as the gel.
    public static func raster(_ layout: FigureLayout, gel: CGImage?, dpi: Double) -> CGImage? {
        let k = dpi / 72
        let W = (layout.size.width * k).rounded().safeInt, H = (layout.size.height * k).rounded().safeInt
        guard W > 0, H > 0, W <= maxSide, H <= maxSide, W * H <= maxPixels,
              let ctx = bitmapContext(width: W, height: H, like: gel) else { return nil }
        ctx.setFillColor(CGColor(gray: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: W, height: H))
        flipForPoints(ctx, height: layout.size.height, scale: k)
        draw(layout, gel: gel, in: ctx, interpolate: true)
        return ctx.makeImage()
    }

    /// PNG or TIFF, native unless `dpi` asks for another resolution (see `resampleDPI`).
    public static func rasterData(_ layout: FigureLayout, gel: CGImage?, type: UTType, info: ExportInfo, dpi: Double? = nil) -> Data? {
        if let dpi = resampleDPI(dpi, layout) {
            guard let img = raster(layout, gel: gel, dpi: dpi) else { return nil }
            return encode(img, as: type, dpi: dpi, info: info)
        }
        guard let img = raster(layout, gel: gel) else { return nil }
        return encode(img, as: type, dpi: nativeDPI(layout), info: info)
    }

    // MARK: SVG

    /// Text stays text; the gel is embedded as a lossless PNG of exactly the pixels the figure uses.
    public static func svg(_ layout: FigureLayout, gel: CGImage?, info: ExportInfo) -> String {
        func n(_ v: Double) -> String { String(format: "%.3f", v) }
        func esc(_ s: String) -> String {
            s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
                .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
        }
        var out = """
        <?xml version="1.0" encoding="UTF-8"?>
        <svg xmlns="http://www.w3.org/2000/svg" xmlns:xlink="http://www.w3.org/1999/xlink" \
        width="\(n(layout.size.width))pt" height="\(n(layout.size.height))pt" \
        viewBox="0 0 \(n(layout.size.width)) \(n(layout.size.height))">
        <title>\(esc(info.title))</title>
        <desc>\(esc(info.description))</desc>

        """
        if let gel {
            let png = encode(gel, as: .png, dpi: 72 / layout.ptPerPx, info: info).base64EncodedString()
            let r = layout.gelRect
            out += "<image x=\"\(n(r.minX))\" y=\"\(n(r.minY))\" width=\"\(n(r.width))\" height=\"\(n(r.height))\" " +
                "preserveAspectRatio=\"none\" image-rendering=\"pixelated\" xlink:href=\"data:image/png;base64,\(png)\"/>\n"
        }
        out += "<g fill=\"none\" stroke=\"#000\" stroke-linecap=\"butt\">\n"
        if let bw = layout.borderWidth {
            let r = layout.gelRect.insetBy(dx: -bw / 2, dy: -bw / 2)
            out += "<rect x=\"\(n(r.minX))\" y=\"\(n(r.minY))\" width=\"\(n(r.width))\" height=\"\(n(r.height))\" stroke-width=\"\(n(bw))\"/>\n"
        }
        for l in layout.lines {
            let pts = l.points.map { "\(n($0.x)),\(n($0.y))" }.joined(separator: " ")
            out += "<polyline points=\"\(pts)\" stroke-width=\"\(n(l.width))\"/>\n"
        }
        out += "</g>\n<g fill=\"#000\" stroke=\"none\">\n"
        for poly in layout.fills {
            out += "<polygon points=\"\(poly.map { "\(n($0.x)),\(n($0.y))" }.joined(separator: " "))\"/>\n"
        }
        for t in layout.texts {
            let anchor = t.align == .left ? "start" : t.align == .center ? "middle" : "end"
            var attrs = "x=\"\(n(t.origin.x))\" y=\"\(n(t.origin.y))\" font-family=\"\(esc(t.font.family))\" " +
                "font-size=\"\(n(t.font.size))\" text-anchor=\"\(anchor)\""
            if t.font.bold { attrs += " font-weight=\"bold\"" }
            if t.font.italic { attrs += " font-style=\"italic\"" }
            if t.rotation != 0 { attrs += " transform=\"rotate(\(n(-t.rotation)) \(n(t.origin.x)) \(n(t.origin.y)))\"" }
            let lines = t.lines
            if lines.count == 1 {
                out += "<text \(attrs)>\(esc(t.string))</text>\n"
            } else {   // one text object per label, a tspan per line, so it stays one editable label
                let spans = lines.enumerated().map { k, s in
                    "<tspan x=\"\(n(t.origin.x))\" y=\"\(n(t.origin.y + t.firstBaseline + Double(k) * t.lineHeight))\">\(esc(s))</tspan>"
                }
                out += "<text \(attrs)>\(spans.joined())</text>\n"
            }
        }
        out += "</g>\n</svg>\n"
        return out
    }
}

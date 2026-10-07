import CoreGraphics
import Foundation
import UniformTypeIdentifiers

// Cut blots: pieces of one membrane scanned separately, stacked under the main image with a line between them.
//
// The figure's gel is made of "figure pixels" on the main image's grid (the main image is the gel with the lanes): its
// crop keeps its own columns and rows, the other gels sit above or below it in stack order, each keeping the rows of its
// own crop and the columns it was given (by default those under the lanes gel's crop) and mapped onto that grid (shifted
// sideways to line its lanes up, and stretched when that gel doesn't keep its original pixels), with a separator line
// between neighbors, black or white. The figure runs from the leftmost to the rightmost column any gel keeps; where a
// gel has no pixels it's blank white. Lanes and labels live in the
// main image's coordinates, which are figure coordinates too; each strip's own marks are converted on the way in and out.

/// Where every piece sits in the figure's gel, and how to convert between figure pixels and a piece's own pixels.
public struct StackGeometry: Sendable, Equatable {
    public struct Piece: Sendable, Equatable {
        /// nil = the main image, else the strip's number (1-based).
        public var strip: Int?
        /// The piece's rows in the figure, half-open, in figure pixels.
        public var top: Double
        public var bottom: Double
        /// The piece's own first row (its working-image pixels) shown at `top`.
        public var sourceTop: Double
        /// x in the piece = scale × figure x + shift; y likewise, from `sourceTop`.
        public var scale: Double
        public var shift: Double
        /// The piece's working image.
        public var width: Int
        public var height: Int
        /// The piece's kept columns in the figure, half-open, in figure pixels: its own columns through the shift and stretch.
        public var left: Double
        public var right: Double
        /// The piece's own first kept column and the one after its last (working-image pixels), shown from `left` to `right`.
        public var sourceLeft: Double
        public var sourceRight: Double

        public func toPiece(x: Double, y: Double) -> (x: Double, y: Double) {
            (scale * x + shift, sourceTop + (y - top) * scale)
        }
        public func toFigure(x: Double, y: Double) -> (x: Double, y: Double) {
            ((x - shift) / scale, top + (y - sourceTop) / scale)
        }
        public func contains(figureY y: Double) -> Bool { y >= top && y < bottom }
        /// The piece's own rows that are in the figure.
        public var sourceBottom: Double { sourceTop + (bottom - top) * scale }
    }

    /// The figure's gel in figure pixels: from the leftmost to the rightmost column any gel keeps (the main image's crop and the
    /// other gels' crops through their alignment), and from the top of the topmost gel to the bottom of the lowest.
    public var crop: PixelRect
    public var pieces: [Piece]
    /// Rows of the line between two pieces.
    public var separator: Int
    /// The line's colour: black is the darkest value of the output's storage and white the brightest; a colour is its own numbers in
    /// an RGB storage and its luminance in a gray one.
    public var separatorColor: SeparatorColor

    public var hasStrips: Bool { pieces.count > 1 }

    /// `stripSizes`: each strip's working-image size (after its turn), in strip order, and nil for a strip that isn't
    /// there (not decoded, or can't be read): it's left out of the stack but keeps its number, so no other gel moves
    /// into its place.
    public init(project p: GelProject, mainWidth: Int, mainHeight: Int, stripSizes: [(width: Int, height: Int)?]) {
        let c = p.effectiveCrop(width: mainWidth, height: mainHeight)
        separatorColor = p.separatorColor
        /// Strip `k` with its columns in the figure and the number of rows it takes, top unknown yet.
        func strip(_ k: Int) -> Piece? {
            guard k - 1 < stripSizes.count, let size = stripSizes[k - 1] else { return nil }
            let s = p.strips[k - 1]
            let (shift, scale) = p.laneAlignment(k)   // lined up with the lanes gel wherever that sits; the figure is on its grid
            let rows = s.usedRows(height: size.height), cols = s.columns(width: size.width, laneCrop: c, shift: shift, scale: scale)
            // an edge the gel followed is the lanes gel's crop edge itself, so such a gel never makes the figure wider
            return Piece(strip: k, top: 0, bottom: max(1, ((rows.bottom - rows.top) / scale).rounded()), sourceTop: rows.top,
                         scale: scale, shift: shift, width: size.width, height: size.height,
                         left: cols.followsLeft ? c.x0 : (cols.left - shift) / scale,
                         right: cols.followsRight ? c.x1 : (cols.right - shift) / scale,
                         sourceLeft: cols.left, sourceRight: cols.right)
        }
        let order = p.stackOrder, m = order.firstIndex { $0 == nil } ?? 0
        let aboveGels = order[..<m].reversed().compactMap { $0 }.compactMap(strip)
        let belowGels = order[(m + 1)...].compactMap { $0 }.compactMap(strip)
        // the figure runs from the leftmost to the rightmost column any gel keeps, in whole figure pixels (rounded first, so a
        // column that is exactly a whole number stays there)
        func clean(_ v: Double) -> Double { (v * 1e6).rounded() / 1e6 }
        let x0 = (aboveGels + belowGels).reduce(c.x0) { min($0, clean($1.left)) }.rounded(.down)
        let x1 = (aboveGels + belowGels).reduce(c.x1) { max($0, clean($1.right)) }.rounded(.up)
        let ptPerPx = p.style.gelWidthIn * 72 / max(x1 - x0, 1)
        let sep = max(1, (p.effectiveSeparatorWidth / ptPerPx).rounded().safeInt)
        separator = sep
        // the main image keeps its own rows; the gels above it stack upward from its crop, the ones below downward
        var above: [Piece] = [], below: [Piece] = []
        var y = c.y0
        for var s in aboveGels {
            let rows = s.bottom
            s.bottom = y - Double(sep); s.top = s.bottom - rows
            y = s.top
            above.insert(s, at: 0)
        }
        let y0 = y
        y = c.y1
        for var s in belowGels {
            let rows = s.bottom
            s.top = y + Double(sep); s.bottom = s.top + rows
            y = s.bottom
            below.append(s)
        }
        pieces = above + [Piece(strip: nil, top: c.y0, bottom: c.y1, sourceTop: c.y0, scale: 1, shift: 0, width: mainWidth, height: mainHeight,
                                left: c.x0, right: c.x1, sourceLeft: c.x0, sourceRight: c.x1)] + below
        crop = PixelRect(x0: x0, y0: y0, x1: x1, y1: y)
    }

    public func piece(strip: Int?) -> Piece? { pieces.first { $0.strip == strip } }

    /// The piece whose rows hold figure row `y`; in a separator, the nearer of the two pieces.
    public func piece(atFigureY y: Double) -> Piece? {
        if let p = pieces.first(where: { $0.contains(figureY: y) }) { return p }
        return pieces.min { min(abs($0.top - y), abs($0.bottom - y)) < min(abs($1.top - y), abs($1.bottom - y)) }
    }

    /// Figure row of a mark at `y` in its own piece, if that piece is in the figure and the row is inside it.
    public func figureY(strip: Int?, y: Double, inside: Bool = true) -> Double? {
        guard let p = piece(strip: strip) else { return nil }
        if strip == nil { return !inside || (y >= p.top && y <= p.bottom) ? y : nil }   // the main image: its crop
        let fy = p.toFigure(x: 0, y: y).y
        return !inside || (fy >= p.top - 0.5 && fy <= p.bottom + 0.5) ? fy : nil
    }

    /// Figure row of a band name at `y` in its own piece. With one image a name stays where it was put, even outside
    /// the crop; with strips, only inside its own piece (elsewhere it would point at another piece).
    public func nameY(strip: Int?, y: Double) -> Double? {
        hasStrips ? figureY(strip: strip, y: y) : (strip == nil ? y : nil)
    }
}

public enum StripStack {
    /// Why Strict can't stack these images untouched, or nil when it can: they must share one pixel format (color
    /// space, bit depth, channels), or the exported pixels couldn't be the original values. Said of the stacked gel,
    /// without its name: "is 8-bit RGB, the gel with the lanes 8-bit gray". `reference`: what `main` is called.
    public static func strictMismatch(main: CGImage, strip: CGImage, reference: String = "the gel with the lanes") -> String? {
        // the name alone isn't enough: two different embedded profiles are both nameless, and drawing one gel through the
        // other's profile would change its values
        func icc(_ i: CGImage) -> Data? { i.colorSpace?.copyICCData().map { $0 as Data } }
        let same = main.bitsPerComponent == strip.bitsPerComponent && main.bitsPerPixel == strip.bitsPerPixel &&
            main.colorSpace?.model == strip.colorSpace?.model && main.colorSpace?.name == strip.colorSpace?.name &&
            icc(main) == icc(strip) &&
            main.alphaInfo == strip.alphaInfo && main.bitmapInfo.contains(.floatComponents) == strip.bitmapInfo.contains(.floatComponents)
        guard !same else { return nil }
        let a = describe(main), b = describe(strip)
        if a != b { return "is \(b), \(reference) \(a)" }
        // the same bit depth and kind of color, so say what does differ instead of guessing at one thing
        func hasAlpha(_ i: CGImage) -> Bool { ![CGImageAlphaInfo.none, .noneSkipFirst, .noneSkipLast].contains(i.alphaInfo) }
        var differs: [String] = []
        if main.colorSpace?.model != strip.colorSpace?.model { differs.append("the color model") }
        if hasAlpha(main) != hasAlpha(strip) { differs.append("the alpha channel") }
        else if main.alphaInfo != strip.alphaInfo || main.bitsPerPixel != strip.bitsPerPixel { differs.append("the channel layout") }
        if main.bitmapInfo.contains(.floatComponents) != strip.bitmapInfo.contains(.floatComponents) { differs.append("the floating-point format") }
        if main.colorSpace?.name != strip.colorSpace?.name || icc(main) != icc(strip) { differs.append("the color profile") }
        if differs.isEmpty { differs = ["the way the pixels are stored"] }
        let list = differs.count < 2 ? differs.joined() : differs.dropLast().joined(separator: ", ") + " and " + differs.last!
        return "is stored differently from \(reference) (\(a) in both, but \(list) \(differs.count == 1 ? "differs" : "differ"))"
    }

    /// How an image is stored, for a message: "8-bit gray", "16-bit RGB".
    static func describe(_ i: CGImage) -> String {
        let model = i.colorSpace?.model == .monochrome ? "gray" : i.colorSpace?.model == .rgb ? "RGB" : "color"
        return "\(i.bitsPerComponent)-bit \(model)"
    }

    /// Why the gels that keep their original pixels can't be stacked untouched, or nil: they must all be stored the same
    /// way. The gel with the lanes is what the others must match when it keeps its pixels, else the topmost that does.
    /// The first that doesn't fit is called `name(k)` (k: its number in `strips`), e.g. "Gel 2 is 8-bit RGB, the gel with
    /// the lanes 8-bit gray". `strips`: each gel's image by its number, nil for one that isn't there (it's skipped, the
    /// numbers stay). Gels that don't keep their original pixels are stored however the output is, so they never count.
    public static func strictProblem(project p: GelProject, main: CGImage, strips: [CGImage?], name: (Int) -> String) -> String? {
        strictProblemDetail(project: p, main: main, strips: strips, name: name)?.message
    }

    /// `strictProblem`, with the number of the gel (in `strips`) it is said of, to show it with that gel.
    public static func strictProblemDetail(project p: GelProject, main: CGImage, strips: [CGImage?], name: (Int) -> String) -> (strip: Int, message: String)? {
        func image(_ k: Int) -> CGImage? { k >= 1 && k <= strips.count ? strips[k - 1] : nil }
        let keeping = p.strips.indices.map { $0 + 1 }.filter { p.isStrict(gel: $0) && image($0) != nil }
        guard let first = p.isStrict(gel: nil) ? Optional(0) : p.stackOrder.compactMap({ $0 }).first(where: { keeping.contains($0) })
        else { return nil }
        let ref = first == 0 ? main : image(first)!
        let refName = first == 0 ? "the gel with the lanes" : name(first)
        for k in keeping where k != first {
            if let m = strictMismatch(main: ref, strip: image(k)!, reference: refName) { return (k, "\(name(k)) \(m)") }
        }
        return nil
    }

    /// Why Strict can't stack these gels with the one that has the lanes untouched, or nil: every gel keeps its original
    /// pixels here (see the other `strictProblem` for projects whose gels have their own setting).
    public static func strictProblem(main: CGImage, strips: [CGImage?], name: (Int) -> String) -> String? {
        for (i, s) in strips.enumerated() {
            if let s, let m = strictMismatch(main: main, strip: s) { return "\(name(i + 1)) \(m)" }
        }
        return nil
    }

    /// The gel as it goes into the figure. Each gel is either one that keeps its original pixels (`isStrict(gel:)`) or not:
    /// - all keep them: every piece's original pixels on whole pixels, unscaled, in the main image's format (nil if a
    ///   gel's format differs: see `strictMismatch`);
    /// - none do: each piece processed and mapped to 8-bit gray, strips resampled when stretched;
    /// - some do: the output is stored like the gels that keep their pixels (which must all match, else nil), their values
    ///   untouched; each other gel is processed as above and then converted to that storage (gray by luminance, 8-bit values
    ///   times 257 for 16-bit).
    /// The separator rows are the darkest value of the storage for a black line, the brightest for white.
    /// `strips`: each gel's working image by its number, nil for one that can't be read (the list may also end early). The
    /// gels that are there are placed by their own numbers, so no other gel's picture ever takes a missing one's place; a
    /// figure that has a gel missing must not be exported (see `StackedFigure.unreadableGel`).
    public static func figureImage(main: WorkingImage, strips: [WorkingImage?], project p: GelProject, stack: StackGeometry) -> CGImage? {
        guard stack.hasStrips else { return main.figureImage(project: p) }
        func working(_ k: Int?) -> WorkingImage? {
            guard let k else { return main }
            return k >= 1 && k <= strips.count ? strips[k - 1] : nil
        }
        /// A gel processed and mapped to 8-bit gray, full frame.
        func processed(_ k: Int?, _ w: WorkingImage) -> CGImage? {
            w.figureImage(project: fullFrame(k.map { p.stripProject($0) } ?? p, w))
        }
        let order = stack.pieces.map(\.strip)
        let keeping = order.filter { p.isStrict(gel: $0) && working($0) != nil }
        if keeping.isEmpty {   // none: processed and mapped to gray, full frame; then cut and placed like the strict pixels
            return compose(stack: stack, like: nil, gray: outputIsGray(p), interpolate: { _ in true }) { piece in
                working(piece.strip).flatMap { processed(piece.strip, $0) }
            }
        }
        // the storage: the gel with the lanes' when it keeps its pixels, else the topmost gel that does
        guard let reference = p.isStrict(gel: nil) ? main : working(keeping[0]) else { return nil }
        let like = reference.source.cgImage
        for k in keeping {
            if let w = working(k), strictMismatch(main: like, strip: w.source.cgImage) != nil { return nil }
        }
        return compose(stack: stack, like: like, interpolate: { !p.isStrict(gel: $0.strip) }) { piece in
            guard let w = working(piece.strip) else { return nil }
            if p.isStrict(gel: piece.strip) { return w.source.cgImage }
            return processed(piece.strip, w).flatMap { stored($0, like: like) }
        }
    }

    /// What a gel that doesn't keep its original pixels is converted to when it's stacked with some that do, or nil when
    /// nothing is converted: "8-bit gray", "16-bit RGB" (what `figureImage` stores the output as).
    public static func conversion(main: WorkingImage, strips: [WorkingImage?], project p: GelProject, stack: StackGeometry) -> String? {
        guard stack.hasStrips else { return nil }
        let order = stack.pieces.map(\.strip)
        guard order.contains(where: { !p.isStrict(gel: $0) }) else { return nil }
        func working(_ k: Int?) -> WorkingImage? {
            guard let k else { return main }
            return k >= 1 && k <= strips.count ? strips[k - 1] : nil
        }
        let keeping = order.filter { p.isStrict(gel: $0) && working($0) != nil }
        if keeping.isEmpty { return outputIsGray(p) ? "8-bit gray" : "8-bit RGB" }   // none keep theirs: see `outputIsGray`
        guard let reference = p.isStrict(gel: nil) ? main : working(keeping[0]) else { return nil }
        return describe(reference.source.cgImage)
    }

    /// Whether a stack in which no gel keeps its original pixels is stored as 8-bit gray (else 8-bit RGB). Every gel is gray then
    /// (a gel that doesn't keep its pixels is mapped to 8-bit gray, whatever it was scanned as), so only the colour of the line
    /// between gels decides: a gray line fits a gray figure, any other colour needs RGB to be kept exactly.
    public static func outputIsGray(_ p: GelProject) -> Bool { p.separatorColor.isGray }

    /// An 8-bit gray rendering stored as `like` is: the same values in its color space and bit depth (8-bit values times 257
    /// for 16-bit), the same value in every channel for color. Other storage (floating point) is left to Core Graphics.
    private static func stored(_ gray: CGImage, like ref: CGImage) -> CGImage? {
        let model = ref.colorSpace?.model
        let float = ref.bitmapInfo.contains(.floatComponents)
        guard let space = ref.colorSpace, !float, model == .monochrome || model == .rgb, ref.bitsPerComponent == 8 || ref.bitsPerComponent == 16,
              gray.bitsPerComponent == 8, gray.bitsPerPixel == 8, let data = gray.dataProvider?.data, let bytes = CFDataGetBytePtr(data)
        else { return gray }
        let w = gray.width, h = gray.height, n = model == .rgb ? 4 : 1, wide = ref.bitsPerComponent == 16
        let unit = wide ? 2 : 1
        var out = [UInt8](repeating: 0, count: w * h * n * unit)
        out.withUnsafeMutableBufferPointer { o in
            for y in 0..<h {
                let row = y * gray.bytesPerRow
                for x in 0..<w {
                    let v = bytes[row + x], at = (y * w + x) * n * unit
                    for c in 0..<n {
                        let skip = n == 4 && c == 3   // the unused fourth channel of RGB
                        let value: UInt16 = skip ? 0xFFFF : UInt16(v) * 257
                        if wide { o[at + c * 2] = UInt8(value & 0xFF); o[at + c * 2 + 1] = UInt8(value >> 8) }   // little-endian
                        else { o[at + c] = skip ? 255 : v }
                    }
                }
            }
        }
        let order: UInt32 = wide ? CGBitmapInfo.byteOrder16Little.rawValue : 0
        let info = CGBitmapInfo(rawValue: (model == .rgb ? CGImageAlphaInfo.noneSkipLast.rawValue : CGImageAlphaInfo.none.rawValue) | order)
        guard let provider = CGDataProvider(data: Data(out) as CFData) else { return gray }
        return CGImage(width: w, height: h, bitsPerComponent: ref.bitsPerComponent, bitsPerPixel: n * ref.bitsPerComponent,
                       bytesPerRow: w * n * unit, space: space, bitmapInfo: info, provider: provider, decode: nil,
                       shouldInterpolate: false, intent: .defaultIntent) ?? gray
    }

    /// The gel for the screen: each piece's full-frame view image (brightness & contrast always applied), cut and
    /// placed as in the figure.
    public static func viewImage(views: [CGImage?], stack: StackGeometry) -> CGImage? {
        compose(stack: stack, like: nil, interpolate: { _ in true }) { piece in
            let i = piece.strip ?? 0
            return i < views.count ? views[i] : nil
        }
    }

    private static func fullFrame(_ p: GelProject, _ w: WorkingImage) -> GelProject {
        var q = p
        q.crop = PixelRect(x0: 0, y0: 0, x1: Double(w.width), y1: Double(w.height))
        return q
    }

    /// The line's colour as numbers of the context's own colour space, so no conversion changes them: an RGB storage gets the colour
    /// exactly, a gray one its gray level (see `SeparatorColor.gray`), which a 16-bit one scales as 8-bit values are everywhere (x 257).
    private static func separatorFill(_ color: SeparatorColor, in ctx: CGContext) -> CGColor {
        let c = color.components
        if let space = ctx.colorSpace {
            if space.model == .rgb, let fill = CGColor(colorSpace: space, components: [CGFloat(c.red) / 255, CGFloat(c.green) / 255, CGFloat(c.blue) / 255, 1]) { return fill }
            if space.model == .monochrome, let fill = CGColor(colorSpace: space, components: [CGFloat(color.gray) / 255, 1]) { return fill }
        }
        return CGColor(gray: CGFloat(color.gray) / 255, alpha: 1)
    }

    /// Draws each piece's rows of `image(piece)` (a full-frame image in that piece's working pixels) into its place.
    /// `like`: the context takes that image's format (Strict); nil = 8-bit RGB, or 8-bit gray with `gray`. `interpolate`: whether a piece is resampled
    /// (a stretched gel) or placed on whole pixels. The lines between pieces are the darkest or the brightest value there is,
    /// and what no piece covers is the brightest: the context starts white, which is the storage's maximum value in any storage.
    private static func compose(stack: StackGeometry, like: CGImage?, gray: Bool = false, interpolate: (StackGeometry.Piece) -> Bool,
                                image: (StackGeometry.Piece) -> CGImage?) -> CGImage? {
        let c = stack.crop
        let W = c.width.rounded().safeInt, H = c.height.rounded().safeInt
        guard W > 0, H > 0, W <= FigureRenderer.maxSide, H <= FigureRenderer.maxSide, W * H <= FigureRenderer.maxPixels else { return nil }
        let ctx: CGContext?
        if let like {
            ctx = FigureRenderer.bitmapContext(width: W, height: H, like: like)
        } else if gray {
            ctx = FigureRenderer.bitmapContext(width: W, height: H, like: nil)   // 8-bit gray
        } else {
            ctx = CGContext(data: nil, width: W, height: H, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        }
        guard let ctx else { return nil }
        ctx.setShouldAntialias(false)
        ctx.setFillColor(CGColor(gray: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: W, height: H))
        /// Figure columns `left`…`right` of the rows from `top` down `rows`, as a y-up device rect (the whole width by default).
        func deviceRect(top: Double, rows: Double, left: Double? = nil, right: Double? = nil) -> CGRect {
            let a = left.map { $0 - c.x0 } ?? 0, b = right.map { $0 - c.x0 } ?? Double(W)
            return CGRect(x: a, y: Double(H) - (top - c.y0) - rows, width: b - a, height: rows)
        }
        for (n, piece) in stack.pieces.enumerated() {
            if n > 0 {
                let prev = stack.pieces[n - 1]
                ctx.setFillColor(separatorFill(stack.separatorColor, in: ctx))
                ctx.fill(deviceRect(top: prev.bottom, rows: piece.top - prev.bottom))
            }
            guard let img = image(piece) else { continue }
            let resample = interpolate(piece)
            ctx.interpolationQuality = resample ? .high : .none
            // the piece's own rectangle for this place: its kept columns and rows. Where the piece has no pixels (outside its
            // columns, or past its image) the figure stays as it was filled, blank white.
            let src = CGRect(x: piece.sourceLeft, y: piece.sourceTop, width: piece.sourceRight - piece.sourceLeft,
                             height: (piece.bottom - piece.top) * piece.scale)
            let dst = deviceRect(top: piece.top, rows: piece.bottom - piece.top, left: piece.left, right: piece.right)
            let bounds = CGRect(x: 0, y: 0, width: img.width, height: img.height)
            let part = src.intersection(bounds).integral.intersection(bounds)
            guard !part.isNull, part.width >= 1, part.height >= 1, let cut = img.cropping(to: part) else { continue }
            // where that part lands: same proportions of the place
            let fx = (part.minX - src.minX) / src.width, fw = part.width / src.width
            let fy = (part.minY - src.minY) / src.height, fh = part.height / src.height
            let target = CGRect(x: dst.minX + fx * dst.width, y: dst.maxY - (fy + fh) * dst.height,
                                width: fw * dst.width, height: fh * dst.height)
            ctx.saveGState()
            ctx.clip(to: dst)
            ctx.draw(cut, in: resample ? target : target.integral)
            ctx.restoreGState()
        }
        return ctx.makeImage()
    }
}

/// Lines a strip's lanes up with the main image's.
public enum StripAlign {
    public struct Result: Sendable, Equatable {
        public var shift: Double
        public var scale: Double
        /// The worst-placed lane after lining up, in figure pixels, and the typical lane spacing, for scale.
        public var worst: Double
        public var pitch: Double
    }

    /// What came of trying to line a gel up.
    public enum Outcome: Sendable, Equatable {
        case aligned(Result)
        /// No lanes could be found in the rows used: nothing to tell them from the gaps (a blank or noisy gel).
        case noLanes
        /// Lanes were found but even the best fit leaves one more than half a lane off, so it's refused.
        case offBy(Result)

        public var result: Result? { if case .aligned(let r) = self { r } else { nil } }
    }

    /// How much darker the lanes must be than the gaps between them, as a share of the profile's own spread (its 5th to
    /// 95th percentile), for a gel's lanes to count as found. The tutorial's pieces score 0.41 to 0.86 here. The bar is low on
    /// purpose: a real piece with faint lanes, or a dye front across it, scores much lower than a clean one, and the fit is
    /// still checked against half a lane. Same as the Python version (scratchpad shared-decisions).
    public static let minimumContrast = 0.08
    /// And as a share of lane + gap (the modulation depth). The spread test alone lets about one gel of pure noise in ten
    /// through, but the tutorial's lanes score 0.63 or more here and noise never above 0.05; a gel must pass both.
    public static let minimumModulation = 0.08
    /// The worst lane may be at most this share of the lane spacing off, or the fit is refused (also in Strict).
    public static let largestMisfit = 0.5

    /// Finds `centers.count` lanes in the strip's rows that are in the figure and fits x_strip = scale × x_main + shift
    /// to the main image's lane centers. `allowScale` false (Strict): scale 1 and a whole-pixel shift. Nil when no
    /// alignment is trustworthy (see `attempt`).
    public static func suggest(mainCenters centers: [Double], strip w: WorkingImage, bandsDark: Bool,
                               rows: ClosedRange<Double>? = nil, allowScale: Bool) -> Result? {
        attempt(mainCenters: centers, strip: w, bandsDark: bandsDark, rows: rows, allowScale: allowScale).result
    }

    /// Like `suggest`, saying why when there's no alignment. It never invents a fit: it refuses when the lanes can't be told
    /// from the gaps between them, and when the best fit still leaves a lane more than half a lane spacing off.
    public static func attempt(mainCenters centers: [Double], strip w: WorkingImage, bandsDark: Bool,
                               rows: ClosedRange<Double>? = nil, allowScale: Bool) -> Outcome {
        let n = centers.count
        guard n >= 2, centers.allSatisfy(\.isFinite) else { return .noLanes }
        guard let found = find(lanes: n, in: w, bandsDark: bandsDark, rows: rows),
              let contrast = laneContrast(col: found.col, centers: found.centers, pitch: found.pitch),
              contrast.spread >= minimumContrast, contrast.modulation >= minimumModulation else { return .noLanes }
        let x = centers, y = found.centers
        let gaps = zip(x.dropFirst(), x).map { $0 - $1 }.sorted()
        let pitch = gaps.isEmpty ? 0 : gaps[gaps.count / 2]
        var scale = 1.0, shift: Double
        if allowScale {
            let mx = x.reduce(0, +) / Double(n), my = y.reduce(0, +) / Double(n)
            let sxx = x.reduce(0) { $0 + ($1 - mx) * ($1 - mx) }
            let sxy = zip(x, y).reduce(0) { $0 + ($1.0 - mx) * ($1.1 - my) }
            scale = sxx > 0 ? sxy / sxx : 1
            // lanes spaced more than twice as far apart (or half) as the lanes gel's can't be the same lanes
            guard scale > 0.5, scale < 2 else { return .offBy(Result(shift: 0, scale: scale, worst: .infinity, pitch: pitch)) }
            shift = my - scale * mx
        } else {
            shift = (zip(x, y).reduce(0) { $0 + $1.1 - $1.0 } / Double(n)).rounded()
        }
        let worst = zip(x, y).map { abs($0.1 - (scale * $0.0 + shift)) / scale }.max() ?? 0
        let r = Result(shift: (shift * 100).rounded() / 100, scale: (scale * 10000).rounded() / 10000,
                       worst: (worst * 10).rounded() / 10, pitch: pitch)
        if pitch > 0, worst > largestMisfit * pitch { return .offBy(r) }
        return .aligned(r)
    }

    /// The lanes found in a strip's rows: the comb's `n` lanes, each moved to the centre of mass of its signal, with the
    /// column darkness profile they were found in.
    struct Found {
        var col: [Double]
        var centers: [Double]
        var pitch: Double
    }

    static func find(lanes n: Int, in w: WorkingImage, bandsDark: Bool, rows: ClosedRange<Double>?) -> Found? {
        var dark = w.darkness(bandsDark: bandsDark)
        if let rows {
            let a = max(0, rows.lowerBound.rounded().safeInt), b = min(dark.height, rows.upperBound.rounded().safeInt)
            if b - a >= 8 {
                dark = GrayImage(width: dark.width, height: b - a, pixels: Array(dark.pixels[(a * dark.width)..<(b * dark.width)]),
                                 sourceBits: dark.sourceBits)
            }
        }
        let fit = Detect.lanes(in: dark, count: n)
        guard fit.centers.count == n, fit.pitch > 0 else { return nil }
        // each lane where its signal is centred: the comb is evenly spaced, real lanes not quite
        var col = [Double](repeating: 0, count: dark.width)
        for y in 0..<dark.height { for x in 0..<dark.width { col[x] += Double(dark.pixels[y * dark.width + x]) } }
        let half = fit.pitch * 0.45
        let y = fit.centers.map { c -> Double in
            let a = max(0, Int(c - half)), b = min(dark.width - 1, Int(c + half))
            guard b > a else { return c }
            let base = col[a...b].min() ?? 0
            var moment = 0.0, mass = 0.0
            for x in a...b { let v = col[x] - base; moment += v * Double(x); mass += v }
            return mass > 0 ? moment / mass : c
        }
        return Found(col: col, centers: y, pitch: fit.pitch)
    }

    /// How clearly the lanes show in a gel's column profile `col`, two ways. `lane` is the mean of `col` within
    /// ±max(1, round(pitch × 0.15)) of each lane centre, `gap` the same at the midpoints between neighbouring centres.
    struct Contrast: Equatable {
        /// (lane − gap) / (hi − lo): lo and hi are the 5th and 95th percentile of `col` across the lanes (numpy's linear
        /// percentiles).
        var spread: Double
        /// (lane − gap) / (lane + gap).
        var modulation: Double
    }

    /// Nil when there's nothing to measure: no spread (a blank gel), or lane + gap isn't above zero.
    static func laneContrast(col: [Double], centers c: [Double], pitch: Double) -> Contrast? {
        guard c.count >= 2, !col.isEmpty else { return nil }
        let w = max(1, (pitch * 0.15).rounded().safeInt)
        func mean(at x: Double) -> Double {
            let i = x.rounded().safeInt
            let a = max(0, i - w), b = min(col.count - 1, i + w)
            guard a <= b else { return 0 }
            return col[a...b].reduce(0, +) / Double(b - a + 1)
        }
        let lane = c.reduce(0) { $0 + mean(at: $1) } / Double(c.count)
        let mids = zip(c, c.dropFirst()).map { ($0 + $1) / 2 }
        let gap = mids.reduce(0) { $0 + mean(at: $1) } / Double(mids.count)
        let from = max(0, ((c.first ?? 0) - pitch / 2).rounded().safeInt)
        let to = min(col.count - 1, ((c.last ?? 0) + pitch / 2).rounded().safeInt)
        guard from <= to, lane + gap > 0 else { return nil }
        let sorted = col[from...to].sorted()
        func percentile(_ q: Double) -> Double {   // linear between ranks, like numpy
            let pos = q / 100 * Double(sorted.count - 1), lo = Int(pos.rounded(.down)), hi = min(lo + 1, sorted.count - 1)
            return sorted[lo] + (sorted[hi] - sorted[lo]) * (pos - Double(lo))
        }
        let low = percentile(5), high = percentile(95)
        guard high > low else { return nil }
        return Contrast(spread: (lane - gap) / (high - low), modulation: (lane - gap) / (lane + gap))
    }

    /// What to tell the user when `attempt` gave no alignment (nil when it did). `gelNumber`: the gel's place from the top.
    /// `strict`: that gel keeps its original pixels, so it can't be stretched.
    public static func refusal(_ outcome: Outcome, gelNumber n: Int, strict: Bool) -> String? {
        switch outcome {
        case .aligned: nil
        case .noLanes: "Couldn't find Gel \(n)'s lanes. Line it up by hand."
        case .offBy:
            "Gel \(n)'s lanes don't line up with the lanes gel's. Line it up by hand" +
                (strict ? " or turn off Keep original pixels for Gel \(n) to let it stretch." : ".")
        }
    }

    /// A gel lined up with its own Keep original pixels in mind. `keepsOriginal`: whole-pixel shift only (no stretch). Then,
    /// when whole pixels leave a lane more than a quarter of a lane off, `note` says how much stretching it would take:
    /// "Gel 2's lanes are 2.5% farther apart (or closer together), so they're up to 13 px off. Turn off Keep original pixels
    /// for Gel 2 to stretch it." `gelNumber`: the gel's place from the top. Never said of a gel that may stretch.
    public static func fit(mainCenters centers: [Double], strip w: WorkingImage, bandsDark: Bool, rows: ClosedRange<Double>? = nil,
                           keepsOriginal: Bool, gelNumber n: Int) -> (outcome: Outcome, note: String?) {
        let whole = attempt(mainCenters: centers, strip: w, bandsDark: bandsDark, rows: rows, allowScale: !keepsOriginal)
        guard keepsOriginal else { return (whole, nil) }
        let off: Result
        switch whole {
        case .noLanes: return (whole, nil)
        case .aligned(let r), .offBy(let r): off = r
        }
        guard off.pitch > 0, off.worst.isFinite, off.worst > quarterLane * off.pitch else { return (whole, nil) }
        let stretched = attempt(mainCenters: centers, strip: w, bandsDark: bandsDark, rows: rows, allowScale: true)
        let scale: Double
        switch stretched {
        case .noLanes: return (whole, nil)
        case .aligned(let r), .offBy(let r): scale = r.scale
        }
        let percent = (scale - 1) * 100
        guard percent.isFinite, abs(percent) >= 0.05 else { return (whole, nil) }   // nothing to stretch away
        let how = percent > 0 ? "farther apart" : "closer together"
        let note = "Gel \(n)'s lanes are \(String(format: "%.1f", abs(percent)))% \(how), so they're up to " +
            "\(FigureLayoutEngine.formatSize(off.worst)) px off. Turn off Keep original pixels for Gel \(n) to stretch it."
        return (whole, note)
    }

    /// The share of a lane's spacing a whole-pixel fit may leave a lane off before a gel that keeps its original pixels is
    /// told it would line up better stretched.
    public static let quarterLane = 0.25
}

/// One project's whole figure, strips included: what the command-line tool, the LLM tools and the app export from.
public struct StackedFigure: @unchecked Sendable {   // CGImage-backed parts are immutable
    public let project: GelProject
    public let main: WorkingImage
    /// Each gel's working image by its number (strip k is `strips[k - 1]`), nil for one that can't be read. Always one
    /// entry per strip, so no gel's picture can end up in another's place.
    public let strips: [WorkingImage?]
    public let stack: StackGeometry
    public let layout: FigureLayout

    /// `strips`: the strips' working images by their numbers (`main.strips` when attached); a list that stops early leaves
    /// the rest missing.
    public init(project p: GelProject, main: WorkingImage, strips: [WorkingImage?]? = nil) {
        var list: [WorkingImage?] = strips ?? main.strips.map { Optional($0) }
        if list.count > p.strips.count { list.removeLast(list.count - p.strips.count) }
        while list.count < p.strips.count { list.append(nil) }
        project = p; self.main = main; self.strips = list
        stack = StackGeometry(project: p, mainWidth: main.width, mainHeight: main.height,
                              stripSizes: list.map { $0.map { (width: $0.width, height: $0.height) } })
        layout = FigureLayoutEngine.layout(p, imageWidth: main.width, imageHeight: main.height, stack: stack)
    }

    /// The strips' working images for a package, each with its own turn, rotation and brightness & contrast.
    /// Fails with "Gel N's image (file) can't be read." when one of them can't be decoded (N counted from the top).
    public static func stripImages(_ pkg: GelPackage) throws -> [WorkingImage] {
        try pkg.project.strips.indices.map { i in
            WorkingImage(source: try pkg.decodeStrip(i + 1), project: pkg.project.stripProject(i + 1))
        }
    }

    /// Why this figure can't be made because a gel's image is missing, or nil: "Gel N's image (file) can't be read." for the
    /// topmost gel that's missing (N counted from the top).
    public var unreadableGel: String? {
        let missing = strips.indices.filter { strips[$0] == nil }
        guard let k = missing.min(by: { project.position(of: $0 + 1) < project.position(of: $1 + 1) }) else { return nil }
        return project.unreadableMessage(strip: k + 1)
    }

    /// Why the gels that keep their original pixels can't be exported untouched (they must all be stored alike), or nil.
    public var strictProblem: String? {
        let p = project
        return StripStack.strictProblem(project: p, main: main.source.cgImage, strips: strips.map { $0?.source.cgImage }) {
            "gel \(p.position(of: $0) + 1)"
        }
    }

    /// What an export says when the gel's picture or the file can't be made (too large, or no drawing context to make it in).
    public static let tooLargeMessage = "The figure is too large to make. Crop the gels or lower the export resolution."

    /// The gel as it goes into the figure (nil when `strictProblem` says Strict can't stack these pieces, or the picture can't be
    /// made: `export` is nil then, never a figure around blank space).
    public var gel: CGImage? { StripStack.figureImage(main: main, strips: strips, project: project, stack: stack) }

    /// One line for each gel (counted from the top) whose image no longer hashes to the fingerprint taken when it was added; empty
    /// when none changed. The export goes ahead: the note starts with these lines (`ExportInfo.changedImageWarnings`).
    public var changedImageWarnings: [String] {
        ExportInfo.changedImageWarnings(project, sourceSHA256: main.source.sha256, strips: strips.map { $0?.source.sha256 })
    }

    public func info(resampledDPI: Double? = nil) -> ExportInfo {
        ExportInfo.for(project, sourceSHA256: main.source.sha256, resampledDPI: resampledDPI,
                       nativeDPI: resampledDPI == nil ? nil : FigureRenderer.nativeDPI(layout), scale: main.source.scale,
                       strips: strips.map { (sha256: $0?.source.sha256, scale: $0?.source.scale) },
                       size: (width: main.width, height: main.height),
                       stripSizes: strips.map { $0.map { (width: $0.width, height: $0.height) } },
                       convertedTo: StripStack.conversion(main: main, strips: strips, project: project, stack: stack))
    }

    /// PDF, PNG, TIFF or SVG. PNG and TIFF at `dpi` when it differs from native (nil: the project's own setting).
    public func export(_ type: UTType, dpi: Double? = nil) -> Data? {
        if unreadableGel != nil { return nil }   // never a figure with a gel missing
        let gel = self.gel
        if strictProblem != nil { return nil }
        guard gel != nil else { return nil }   // too large, or no drawing context: not a figure with blank space where the gels go
        switch type {
        case .pdf: return FigureRenderer.pdf(layout, gel: gel, info: info())
        case .png, .tiff:
            let d = FigureRenderer.resampleDPI(dpi ?? project.style.exportDPI, layout)
            return FigureRenderer.rasterData(layout, gel: gel, type: type, info: info(resampledDPI: d), dpi: d)
        case .svg: return Data(FigureRenderer.svg(layout, gel: gel, info: info()).utf8)
        default: return nil
        }
    }
}

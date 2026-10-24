import CoreGraphics
import CryptoKit
import Foundation
import ImageIO

public enum GelKitError: Error, LocalizedError {
    case unreadableImage
    /// A floating-point image (`bits` per value): not supported, because its values can't be kept exactly.
    case floatImage(bits: Int)
    /// A CMYK image: a printing format, refused rather than converted.
    case cmykImage
    /// An integer image with more than 16 bits per value (32-bit): not supported, because it can't be kept exactly in a figure.
    case integerImage(bits: Int)
    /// Gel `number` (counted from the top of the figure) has an image file that can't be decoded.
    case unreadableGel(number: Int, file: String)
    case badProject(String)
    public var errorDescription: String? {
        switch self {
        case .unreadableImage: "The file could not be read as an image."
        case .floatImage(let bits):
            "This image has \(bits)-bit floating-point values, which GelScribe doesn't support. Export it from your scanner's software as a 16-bit TIFF and open that."
        case .cmykImage: "This image is in CMYK, a colour format for printing, which GelScribe doesn't support. Convert it to RGB and open that."
        case .integerImage(let bits):
            "This image has \(bits)-bit integer values, which GelScribe doesn't support. Export it from your scanner's software as a 16-bit TIFF and open that."
        case .unreadableGel(let n, let file): "Gel \(n)'s image (\(file)) can't be read."
        case .badProject(let why): "Not a GelScribe project: \(why)"
        }
    }
}

extension Double {
    /// `Int(self)` that can't trap: NaN is 0 and huge values stop at ±9e15. For positions and sizes that came from a file
    /// or from outside, where `Int(1e300)` would crash.
    public var safeInt: Int { isNaN ? 0 : Int(Swift.max(-9e15, Swift.min(9e15, self))) }
}

/// Grayscale image, values 0...1 (0 = black), row-major, top row first.
public struct GrayImage: Sendable {
    public let width: Int
    public let height: Int
    public var pixels: [Float]
    /// Bits per component of the source file (8 or 16 typically), for display only.
    public let sourceBits: Int

    public init(width: Int, height: Int, pixels: [Float], sourceBits: Int = 8) {
        precondition(pixels.count == width * height)
        self.width = width; self.height = height; self.pixels = pixels; self.sourceBits = sourceBits
    }

    @inline(__always) public subscript(x: Int, y: Int) -> Float {
        get { pixels[y * width + x] }
        set { pixels[y * width + x] = newValue }
    }

    /// Decodes PNG/TIFF/JPEG/etc. into 32-bit float gray, keeping 16-bit precision.
    public static func load(data: Data) throws -> GrayImage {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil),
              let cg = CGImageSourceCreateImageAtIndex(src, 0, nil) else { throw GelKitError.unreadableImage }
        return try from(cgImage: cg)
    }

    public static func from(cgImage cg: CGImage) throws -> GrayImage {
        let w = cg.width, h = cg.height
        // Gamma-2.2 gray: sRGB and gray-gamma sources keep their perceived values instead of being linearized.
        guard let space = CGColorSpace(name: CGColorSpace.genericGrayGamma2_2) else { throw GelKitError.unreadableImage }
        var buf = [Float](repeating: 0, count: w * h)
        let info = CGImageAlphaInfo.none.rawValue | CGBitmapInfo.floatComponents.rawValue |
            CGBitmapInfo.byteOrder32Little.rawValue
        let ok = buf.withUnsafeMutableBytes { raw -> Bool in
            guard let ctx = CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 32,
                                      bytesPerRow: w * 4, space: space, bitmapInfo: info) else { return false }
            ctx.interpolationQuality = .none
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard ok else { throw GelKitError.unreadableImage }
        for i in buf.indices { buf[i] = min(1, max(0, buf[i])) }
        return GrayImage(width: w, height: h, pixels: buf, sourceBits: cg.bitsPerComponent)
    }

    public func median(where include: (Int) -> Bool = { _ in true }) -> Float {
        // Histogram median: exact enough (1/4096) and O(n).
        var hist = [Int](repeating: 0, count: 4096)
        var n = 0
        for i in pixels.indices where include(i) {
            hist[Int(pixels[i] * 4095)] += 1; n += 1
        }
        guard n > 0 else { return 1 }
        var acc = 0
        for (b, c) in hist.enumerated() {
            acc += c
            if acc * 2 >= n { return Float(b) / 4095 }
        }
        return 1
    }

    /// At 16-bit resolution, so faint 16-bit scans (a few hundred levels out of 65535) still get real values.
    public func percentile(_ q: Double) -> Float {
        var hist = [Int](repeating: 0, count: 65536)
        for v in pixels { hist[Int(v * 65535)] += 1 }
        let target = Int(Double(pixels.count) * q / 100)
        var acc = 0
        for (b, c) in hist.enumerated() {
            acc += c
            if acc > target { return Float(b) / 65535 }
        }
        return 1
    }

    /// Rotates about the center (bilinear), keeping the canvas size; uncovered corners get `fill`.
    /// Positive degrees turn the picture counter-clockwise on screen.
    public func rotated(degrees: Double, fill: Float) -> GrayImage { rotated(degrees: degrees, fill: fill, carrying: nil).image }

    /// `rotated(degrees:fill:)`, also moving a mask along with the picture in the same pass: the new mask is true where the old one was
    /// (bilinear, over a half) and where the rotation uncovered the corners. Rows run in parallel.
    func rotated(degrees: Double, fill: Float, carrying mask: [Bool]?) -> (image: GrayImage, mask: [Bool]?) {
        guard abs(degrees) > 1e-6 else { return (self, mask) }
        let t = degrees * .pi / 180
        let c = Float(cos(t)), s = Float(sin(t))
        let cx = Float(width - 1) / 2, cy = Float(height - 1) / 2
        let w = width, h = height
        var out = [Float](repeating: fill, count: pixels.count)
        var outMask = [Bool](repeating: mask != nil, count: mask == nil ? 0 : pixels.count)
        let carry = mask != nil
        let hasMask = mask?.contains(true) == true   // nothing to carry: the mask is just what the corners uncover
        pixels.withUnsafeBufferPointer { src in
            out.withUnsafeMutableBufferPointer { dst in
                outMask.withUnsafeMutableBufferPointer { om in
                    (mask ?? []).withUnsafeBufferPointer { mk in
                        let dstBase = dst.baseAddress!, omBase = om.baseAddress
                        DispatchQueue.concurrentPerform(iterations: h) { y in
                            let dy = Float(y) - cy
                            for x in 0..<w {
                                let dx = Float(x) - cx
                                // inverse map: y axis points down, so screen-CCW is this rotation
                                let sx = c * dx - s * dy + cx
                                let sy = s * dx + c * dy + cy
                                let x0 = Int(floor(sx)), y0 = Int(floor(sy))
                                guard x0 >= 0, y0 >= 0, x0 < w - 1, y0 < h - 1 else { continue }   // uncovered: fill, and masked
                                let fx = sx - Float(x0), fy = sy - Float(y0)
                                let i = y0 * w + x0
                                let top = src[i] * (1 - fx) + src[i + 1] * fx
                                let bot = src[i + w] * (1 - fx) + src[i + w + 1] * fx
                                dstBase[y * w + x] = top * (1 - fy) + bot * fy
                                if carry, let omBase {
                                    var m = false
                                    if hasMask {
                                        let a = (mk[i] ? Float(1) : 0) * (1 - fx) + (mk[i + 1] ? Float(1) : 0) * fx
                                        let b = (mk[i + w] ? Float(1) : 0) * (1 - fx) + (mk[i + w + 1] ? Float(1) : 0) * fx
                                        m = a * (1 - fy) + b * fy > 0.5
                                    }
                                    omBase[y * w + x] = m
                                }
                            }
                        }
                    }
                }
            }
        }
        return (GrayImage(width: width, height: height, pixels: out, sourceBits: sourceBits), mask == nil ? nil : outMask)
    }

    /// Turned clockwise by `quarterTurns` × 90°: pixels moved, never changed.
    public func turned(_ quarterTurns: Int) -> GrayImage {
        let q = ((quarterTurns % 4) + 4) % 4
        guard q != 0 else { return self }
        let w = width, h = height
        let (nw, nh) = q == 2 ? (w, h) : (h, w)
        var out = [Float](repeating: 0, count: pixels.count)
        for y in 0..<h {
            for x in 0..<w {
                let (nx, ny) = Self.turn(x, y, w, h, q)
                out[ny * nw + nx] = pixels[y * w + x]
            }
        }
        return GrayImage(width: nw, height: nh, pixels: out, sourceBits: sourceBits)
    }

    /// Where pixel (x, y) of a w × h image lands after `q` clockwise quarter turns.
    @inline(__always) static func turn(_ x: Int, _ y: Int, _ w: Int, _ h: Int, _ q: Int) -> (Int, Int) {
        switch q {
        case 1: (h - 1 - y, x)
        case 2: (w - 1 - x, h - 1 - y)
        case 3: (y, w - 1 - x)
        default: (x, y)
        }
    }

    /// 8-bit gray rendering of `rect` with the display mapping applied.
    /// `decimate` > 1: a smaller picture, each pixel the mean of a block of that many pixels square (for drawing a big image zoomed out).
    public func cgImage(display: DisplaySettings, crop rect: PixelRect? = nil, decimate f: Int = 1) -> CGImage? {
        let r = (rect ?? PixelRect(x0: 0, y0: 0, x1: Double(width), y1: Double(height))).normalized(width: width, height: height)
        let x0 = Int(r.x0.rounded()), y0 = Int(r.y0.rounded())
        let fw = max(1, min(width, Int(r.x1.rounded())) - x0), fh = max(1, min(height, Int(r.y1.rounded())) - y0)
        let f = max(1, f)
        let w = (fw + f - 1) / f, h = (fh + f - 1) / f
        let lut = display.lookupTable()
        var bytes = [UInt8](repeating: 0, count: w * h)
        if f == 1 {
            pixels.withUnsafeBufferPointer { src in
                bytes.withUnsafeMutableBufferPointer { dst in
                    let dstBase = dst.baseAddress!, full = width
                    DispatchQueue.concurrentPerform(iterations: h) { y in   // rows in parallel
                        let srow = (y0 + y) * full + x0
                        for x in 0..<w { dstBase[y * w + x] = lut[Int(src[srow + x] * 65535)] }
                    }
                }
            }
        } else {
            pixels.withUnsafeBufferPointer { src in
                bytes.withUnsafeMutableBufferPointer { dst in
                    let dstBase = dst.baseAddress!, full = width
                    DispatchQueue.concurrentPerform(iterations: h) { y in
                        for x in 0..<w {
                            var sum: Float = 0, n: Float = 0
                            for yy in (y * f)..<min(fh, y * f + f) {
                                let row = (y0 + yy) * full + x0
                                for xx in (x * f)..<min(fw, x * f + f) { sum += src[row + xx]; n += 1 }
                            }
                            dstBase[y * w + x] = lut[Int(sum / n * 65535)]
                        }
                    }
                }
            }
        }
        guard let provider = CGDataProvider(data: Data(bytes) as CFData),
              let space = CGColorSpace(name: CGColorSpace.genericGrayGamma2_2) else { return nil }
        return CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: w, space: space,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue), provider: provider,
                       decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }
}

/// A colour image as three float planes (0...1 each), in the file's own colour space, so a colour gel can be rotated, filled and
/// mapped through the display range channel by channel exactly as `GrayImage` does its one channel.
public struct RGBImage: Sendable {
    public var r: GrayImage, g: GrayImage, b: GrayImage
    let space: CGColorSpace

    public var width: Int { r.width }
    public var height: Int { r.height }

    /// Every channel's pixel `i` set to `value` where `mask[i]`.
    public mutating func fill(where mask: [Bool], with value: Float) {
        for i in mask.indices where mask[i] { r.pixels[i] = value; g.pixels[i] = value; b.pixels[i] = value }
    }

    public func rotated(degrees: Double, fill: Float) -> RGBImage {
        guard abs(degrees) > 1e-6 else { return self }
        return RGBImage(r: r.rotated(degrees: degrees, fill: fill), g: g.rotated(degrees: degrees, fill: fill),
                        b: b.rotated(degrees: degrees, fill: fill), space: space)
    }

    /// The pixels as 16-bit integers, rounded.
    func packed() -> RGB16 {
        let n = width * height
        let buf = NSMutableData(length: n * 8)!
        let o = buf.mutableBytes.bindMemory(to: UInt16.self, capacity: n * 4)
        r.pixels.withUnsafeBufferPointer { rp in g.pixels.withUnsafeBufferPointer { gp in b.pixels.withUnsafeBufferPointer { bp in
            for i in 0..<n {
                o[i * 4] = UInt16(min(65535, max(0, (rp[i] * 65535).rounded())))
                o[i * 4 + 1] = UInt16(min(65535, max(0, (gp[i] * 65535).rounded())))
                o[i * 4 + 2] = UInt16(min(65535, max(0, (bp[i] * 65535).rounded())))
                o[i * 4 + 3] = 65535
            }
        } } }
        return RGB16(width: width, height: height, data: buf, space: space)
    }
}

/// A colour image as 16-bit R, G, B, (skipped) interleaved, in the file's own colour space: what a display change re-maps. Cached by
/// `WorkingImage`, so moving the brightness slider costs one table lookup per value, no float work.
public final class RGB16: @unchecked Sendable {
    public let width: Int, height: Int
    let data: NSMutableData
    let space: CGColorSpace

    init(width: Int, height: Int, data: NSMutableData, space: CGColorSpace) {
        self.width = width; self.height = height; self.data = data; self.space = space
    }

    /// Nil unless `cg` is an RGB image. 8-bit values arrive as v x 257, so every channel keeps its stored level.
    public static func from(cgImage cg: CGImage) -> RGB16? {
        guard cg.colorSpace?.model == .rgb, let space = cg.colorSpace else { return nil }
        let w = cg.width, h = cg.height
        guard let buf = NSMutableData(length: w * h * 8) else { return nil }
        let info = CGImageAlphaInfo.noneSkipLast.rawValue | CGBitmapInfo.byteOrder16Little.rawValue
        guard let ctx = CGContext(data: buf.mutableBytes, width: w, height: h, bitsPerComponent: 16, bytesPerRow: w * 8,
                                  space: space, bitmapInfo: info) else { return nil }
        ctx.interpolationQuality = .none
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        return RGB16(width: w, height: h, data: buf, space: space)
    }

    /// A copy with every channel of the pixels where `mask` is true set to `value` (0...1).
    func filled(where mask: [Bool], with value: Float) -> RGB16 {
        let n = width * height
        let copy = NSMutableData(data: data as Data)
        let o = copy.mutableBytes.bindMemory(to: UInt16.self, capacity: n * 4)
        let v = UInt16(min(65535, max(0, (value * 65535).rounded())))
        for i in 0..<n where mask[i] { o[i * 4] = v; o[i * 4 + 1] = v; o[i * 4 + 2] = v }
        return RGB16(width: width, height: height, data: copy, space: space)
    }

    /// Rotated about the centre (bilinear on each channel, rows in parallel), keeping the canvas size; uncovered corners get `fill`.
    /// The same mapping as `GrayImage.rotated`, in 16-bit integers.
    func rotated(degrees: Double, fill: Float) -> RGB16 {
        guard abs(degrees) > 1e-6, let out = NSMutableData(length: width * height * 8) else { return self }
        let t = degrees * .pi / 180
        let c = Float(cos(t)), s = Float(sin(t))
        let w = width, h = height
        let cx = Float(w - 1) / 2, cy = Float(h - 1) / 2
        let f = UInt16(min(65535, max(0, (fill * 65535).rounded())))
        let src = data.bytes.bindMemory(to: UInt16.self, capacity: w * h * 4)
        let dst = out.mutableBytes.bindMemory(to: UInt16.self, capacity: w * h * 4)
        DispatchQueue.concurrentPerform(iterations: h) { y in
            let dy = Float(y) - cy
            var o = y * w * 4
            for x in 0..<w {
                let dx = Float(x) - cx
                let sx = c * dx - s * dy + cx, sy = s * dx + c * dy + cy
                let x0 = Int(floor(sx)), y0 = Int(floor(sy))
                if x0 >= 0, y0 >= 0, x0 < w - 1, y0 < h - 1 {
                    let fx = sx - Float(x0), fy = sy - Float(y0)
                    let i = (y0 * w + x0) * 4, j = i + w * 4
                    let w00 = (1 - fx) * (1 - fy), w10 = fx * (1 - fy), w01 = (1 - fx) * fy, w11 = fx * fy
                    for k in 0..<3 {
                        let v = Float(src[i + k]) * w00 + Float(src[i + 4 + k]) * w10 + Float(src[j + k]) * w01 + Float(src[j + 4 + k]) * w11
                        dst[o + k] = UInt16(min(65535, max(0, v.rounded())))
                    }
                } else {
                    dst[o] = f; dst[o + 1] = f; dst[o + 2] = f
                }
                dst[o + 3] = 65535
                o += 4
            }
        }
        return RGB16(width: w, height: h, data: out, space: space)
    }

    /// Three float planes, for rotating.
    func planes(bits: Int) -> RGBImage {
        let n = width * height
        let p = data.bytes.bindMemory(to: UInt16.self, capacity: n * 4)
        var out = [[Float]](repeating: [Float](repeating: 0, count: n), count: 3)
        for c in 0..<3 { out[c].withUnsafeMutableBufferPointer { o in for i in 0..<n { o[i] = Float(p[i * 4 + c]) / 65535 } } }
        return RGBImage(r: GrayImage(width: width, height: height, pixels: out[0], sourceBits: bits),
                        g: GrayImage(width: width, height: height, pixels: out[1], sourceBits: bits),
                        b: GrayImage(width: width, height: height, pixels: out[2], sourceBits: bits), space: space)
    }

    /// 8-bit RGB rendering of `rect` with the display mapping applied to each channel (rows in parallel).
    /// `decimate` > 1: a smaller picture, each pixel the mean of a block of that many pixels square, per channel (see `GrayImage.cgImage`).
    public func cgImage(display: DisplaySettings, crop rect: PixelRect? = nil, decimate f: Int = 1) -> CGImage? {
        let r0 = (rect ?? PixelRect(x0: 0, y0: 0, x1: Double(width), y1: Double(height))).normalized(width: width, height: height)
        let x0 = Int(r0.x0.rounded()), y0 = Int(r0.y0.rounded())
        let fw = max(1, min(width, Int(r0.x1.rounded())) - x0), fh = max(1, min(height, Int(r0.y1.rounded())) - y0)
        let f = max(1, f)
        let w = (fw + f - 1) / f, h = (fh + f - 1) / f
        let lut = display.lookupTable()
        guard let out = NSMutableData(length: w * h * 4) else { return nil }
        let src = data.bytes.bindMemory(to: UInt16.self, capacity: width * height * 4)
        let dst = out.mutableBytes.bindMemory(to: UInt8.self, capacity: w * h * 4)
        let full = width
        lut.withUnsafeBufferPointer { t in
            DispatchQueue.concurrentPerform(iterations: h) { y in
                if f == 1 {
                    var i = ((y0 + y) * full + x0) * 4, o = y * w * 4
                    for _ in 0..<w {
                        dst[o] = t[Int(src[i])]; dst[o + 1] = t[Int(src[i + 1])]; dst[o + 2] = t[Int(src[i + 2])]; dst[o + 3] = 255
                        i += 4; o += 4
                    }
                    return
                }
                var o = y * w * 4
                for x in 0..<w {
                    var r = 0, g = 0, b = 0, n = 0
                    for yy in (y * f)..<min(fh, y * f + f) {
                        var i = ((y0 + yy) * full + x0 + x * f) * 4
                        for _ in (x * f)..<min(fw, x * f + f) { r += Int(src[i]); g += Int(src[i + 1]); b += Int(src[i + 2]); n += 1; i += 4 }
                    }
                    dst[o] = t[r / n]; dst[o + 1] = t[g / n]; dst[o + 2] = t[b / n]; dst[o + 3] = 255
                    o += 4
                }
            }
        }
        guard let provider = CGDataProvider(data: out as CFData) else { return nil }
        return CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4, space: space,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue), provider: provider,
                       decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }
}

extension DisplaySettings {
    /// 65536-entry map from source value to 8-bit output: every 16-bit level keeps its own entry, so a stretched
    /// faint scan isn't posterized.
    func lookupTable() -> [UInt8] {
        let lo = black, hi = max(white, black + 1e-9)
        return (0..<65536).map { i in
            var v = (Double(i) / 65535 - lo) / (hi - lo)
            v = min(1, max(0, v))
            if gamma != 1 { v = pow(v, 1 / gamma) }
            if invert { v = 1 - v }
            let level = (v * 255).rounded()
            return UInt8(level.isFinite ? min(max(level, 0), 255) : 0)   // never traps, whatever the settings
        }
    }

    /// Levels spanning the 0.1–99.9th percentile, for 16-bit scans that arrive nearly black.
    public static func auto(for img: GrayImage, keeping base: DisplaySettings) -> DisplaySettings {
        var d = base
        d.black = Double(img.percentile(0.1))
        d.white = Double(img.percentile(99.9))
        if d.white - d.black < 1e-5 { d.black = 0; d.white = 1 }
        return d
    }

    /// No change from the stored values.
    public var isIdentity: Bool { black == 0 && white == 1 && gamma == 1 && !invert }

    /// The display range in the file's own numbers, as ImageJ shows it: `min` is drawn as one end of the scale
    /// (black, or white in a white-is-zero file) and `max` as the other.
    public func range(in s: ValueScale) -> (min: Double, max: Double) {
        s.inverted ? ((1 - white) * s.maxValue, (1 - black) * s.maxValue) : (black * s.maxValue, white * s.maxValue)
    }

    public mutating func setRange(min lo: Double, max hi: Double, in s: ValueScale) {
        let a = s.gray(lo), b = s.gray(hi)
        black = Swift.min(a, b)
        white = Swift.max(Swift.max(a, b), black + 1 / s.maxValue)
    }

    /// Brightness as ImageJ's slider has it, −1…1 across the gel's own values `data`: it moves the window, and
    /// positive is brighter on screen whichever way the file stores its values.
    public func brightness(data: ClosedRange<Double>) -> Double {
        let dw = Swift.max(data.upperBound - data.lowerBound, 1e-9)
        return Swift.min(1, Swift.max(-1, ((data.lowerBound + data.upperBound) / 2 - (black + white) / 2) / dw))
    }

    public mutating func setBrightness(_ b: Double, data: ClosedRange<Double>) {
        let dw = Swift.max(data.upperBound - data.lowerBound, 1e-9), w = white - black
        let c = (data.lowerBound + data.upperBound) / 2 - b * dw
        black = c - w / 2
        white = c + w / 2
    }

    /// Contrast, −1…1: 0 spans the gel's own values, positive narrows the window (up to 16×), negative widens it.
    public func contrast(data: ClosedRange<Double>) -> Double {
        let dw = Swift.max(data.upperBound - data.lowerBound, 1e-9), w = Swift.max(white - black, 1e-9)
        return Swift.min(1, Swift.max(-1, -log2(w / dw) / 4))
    }

    public mutating func setContrast(_ k: Double, data: ClosedRange<Double>) {
        let dw = Swift.max(data.upperBound - data.lowerBound, 1e-9), c = (black + white) / 2
        let w = dw * pow(2, -4 * k)
        black = c - w / 2
        white = c + w / 2
    }

    /// Where brightness & contrast start for a new image, the way ImageJ opens it: the range ImageJ saved in the file,
    /// else for 16-bit images their darkest to brightest value, else unchanged.
    public static func initial(for w: WorkingImage) -> DisplaySettings {
        var d = DisplaySettings()
        if let r = w.source.imageJRange {
            d.setRange(min: r.lowerBound, max: r.upperBound, in: w.source.scale)
        } else if w.source.bitsPerComponent > 8 {
            let range = w.gelStats(crop: PixelRect(x0: 0, y0: 0, x1: Double(w.width), y1: Double(w.height))).range
            if range.upperBound > range.lowerBound { d.black = range.lowerBound; d.white = range.upperBound }
        }
        return d
    }
}

/// How a file's stored values relate to the 0…1 gray GelScribe works in, so brightness & contrast can be shown and
/// typed in the file's own numbers (0–65535 for 16-bit, 0–255 for 8-bit), as in ImageJ.
public struct ValueScale: Sendable, Equatable {
    /// Largest stored value: 255, 65535… (1 for floating-point images).
    public var maxValue: Double
    /// Stored white-is-zero (TIFF photometric 0, ImageJ's inverting LUT): gray = 1 − value / maxValue.
    public var inverted: Bool

    public init(maxValue: Double, inverted: Bool = false) { self.maxValue = maxValue; self.inverted = inverted }

    public func value(_ gray: Double) -> Double { (inverted ? 1 - gray : gray) * maxValue }
    public func gray(_ value: Double) -> Double { inverted ? 1 - value / maxValue : value / maxValue }

    /// A stored value as text: whole numbers, or three decimals for floating-point images.
    public func format(_ v: Double) -> String {
        maxValue > 1 ? String(v.rounded().safeInt) : String(format: "%.3f", v)
    }
}

/// The gel's values inside the crop, padding left out: what brightness & contrast work from.
public struct GelStats: Sendable, Equatable {
    /// Darkest to brightest value (0…1 gray).
    public var range: ClosedRange<Double>
    /// 0.1th and 99.9th percentiles: the Auto range.
    public var auto: ClosedRange<Double>
    /// Pixel counts in equal steps across `range`.
    public var counts: [Int]
}

// MARK: - Source and working images

/// The original file, exactly as imported. Never modified; everything else is derived from it.
public struct SourceImage: @unchecked Sendable {   // CGImage is immutable and thread-safe
    public let data: Data
    public let cgImage: CGImage
    /// Float gray copy used for analysis and for non-strict rendering.
    public let gray: GrayImage
    public let sha256: String
    /// How stored values map to gray, for showing brightness & contrast in the file's own numbers.
    public let scale: ValueScale
    /// The display range ImageJ saved in the file ("min=… max=…" in the TIFF description), if any.
    public let imageJRange: ClosedRange<Double>?

    /// Turned clockwise by `quarterTurns` × 90°, losslessly: the decoded pixels are moved in their own format (bit
    /// depth, color space, channels), never redrawn. The file bytes, hash and value scale are the original's.
    public func turned(_ quarterTurns: Int) -> SourceImage {
        let q = ((quarterTurns % 4) + 4) % 4
        guard q != 0, let cg = Self.turn(cgImage, q) else { return self }
        return SourceImage(data: data, cgImage: cg, gray: gray.turned(q), sha256: sha256, scale: scale, imageJRange: imageJRange)
    }

    private init(data: Data, cgImage: CGImage, gray: GrayImage, sha256: String, scale: ValueScale, imageJRange: ClosedRange<Double>?) {
        self.data = data; self.cgImage = cgImage; self.gray = gray; self.sha256 = sha256; self.scale = scale
        self.imageJRange = imageJRange
    }

    /// The same pixels in the same format, turned. Nil for formats that don't pack whole bytes per pixel.
    static func turn(_ cg: CGImage, _ q: Int) -> CGImage? {
        let bpp = cg.bitsPerPixel / 8
        guard cg.bitsPerPixel % 8 == 0, bpp > 0, let raw = cg.dataProvider?.data as Data? else { return nil }
        let w = cg.width, h = cg.height, rowIn = cg.bytesPerRow
        let (nw, nh) = q == 2 ? (w, h) : (h, w)
        let rowOut = nw * bpp
        var out = Data(count: rowOut * nh)
        raw.withUnsafeBytes { (src: UnsafeRawBufferPointer) in
            out.withUnsafeMutableBytes { (dst: UnsafeMutableRawBufferPointer) in
                for y in 0..<h {
                    for x in 0..<w {
                        let (nx, ny) = GrayImage.turn(x, y, w, h, q)
                        let a = y * rowIn + x * bpp, b = ny * rowOut + nx * bpp
                        for k in 0..<bpp { dst[b + k] = src[a + k] }
                    }
                }
            }
        }
        guard let provider = CGDataProvider(data: out as CFData), let space = cg.colorSpace else { return nil }
        return CGImage(width: nw, height: nh, bitsPerComponent: cg.bitsPerComponent, bitsPerPixel: cg.bitsPerPixel,
                       bytesPerRow: rowOut, space: space, bitmapInfo: cg.bitmapInfo, provider: provider,
                       decode: cg.decode, shouldInterpolate: false, intent: cg.renderingIntent)
    }

    public init(data: Data) throws {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil),
              var cg = CGImageSourceCreateImageAtIndex(src, 0, nil) else { throw GelKitError.unreadableImage }
        let float = cg.bitmapInfo.contains(.floatComponents)
        // floating-point values can't be kept exactly through a figure; ask for a 16-bit export instead
        if float { throw GelKitError.floatImage(bits: cg.bitsPerComponent) }
        // so can't 32-bit integers (they'd be squeezed into 16 bits or fewer); the same request
        if cg.bitsPerComponent > 16 { throw GelKitError.integerImage(bits: cg.bitsPerComponent) }
        if cg.colorSpace?.model == .cmyk { throw GelKitError.cmykImage }
        if let expanded = Self.expandedPalette(cg) { cg = expanded }   // a palette image is read as the colours it shows
        scale = ValueScale(maxValue: float ? 1 : pow(2, Double(cg.bitsPerComponent)) - 1,
                           inverted: cg.decode.map { $0[0] > $0[1] } ?? false)
        let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any]
        let description = (props?[kCGImagePropertyTIFFDictionary] as? [CFString: Any])?[kCGImagePropertyTIFFImageDescription] as? String
        imageJRange = description.flatMap(Self.imageJRange)
        self.data = data
        self.cgImage = cg
        self.gray = try GrayImage.from(cgImage: cg)
        self.sha256 = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// A palette (indexed) image as the pixels it shows, taken straight from its palette so no value is converted: 8-bit gray
    /// when every colour in the palette is gray, else 8-bit RGB in the palette's own colour space. Nil for any other image.
    static func expandedPalette(_ cg: CGImage) -> CGImage? {
        guard let space = cg.colorSpace, space.model == .indexed, cg.bitsPerComponent == 8, cg.bitsPerPixel == 8,
              let table = space.colorTable, table.count >= 3, let data = cg.dataProvider?.data, let bytes = CFDataGetBytePtr(data)
        else { return nil }
        let entries = table.count / 3, w = cg.width, h = cg.height
        guard CFDataGetLength(data) >= (h - 1) * cg.bytesPerRow + w else { return nil }
        let gray = (0..<entries).allSatisfy { table[3 * $0] == table[3 * $0 + 1] && table[3 * $0] == table[3 * $0 + 2] }
        let n = gray ? 1 : 4
        var out = [UInt8](repeating: 255, count: w * h * n)
        for y in 0..<h {
            for x in 0..<w {
                let i = min(Int(bytes[y * cg.bytesPerRow + x]), entries - 1) * 3, at = (y * w + x) * n
                out[at] = table[i]
                if !gray { out[at + 1] = table[i + 1]; out[at + 2] = table[i + 2] }   // the fourth byte is unused (255)
            }
        }
        let base = space.baseColorSpace.flatMap { $0.model == .rgb ? $0 : nil } ?? CGColorSpace(name: CGColorSpace.sRGB)
        guard let provider = CGDataProvider(data: Data(out) as CFData),
              let target = gray ? CGColorSpace(name: CGColorSpace.genericGrayGamma2_2) : base else { return nil }
        return CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 8 * n, bytesPerRow: w * n, space: target,
                       bitmapInfo: CGBitmapInfo(rawValue: gray ? CGImageAlphaInfo.none.rawValue : CGImageAlphaInfo.noneSkipLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }

    /// "ImageJ=1.54p\nmin=5.0\nmax=503.0\n…" → 5...503.
    static func imageJRange(_ description: String) -> ClosedRange<Double>? {
        guard description.hasPrefix("ImageJ") else { return nil }
        var lo: Double?, hi: Double?
        for line in description.split(whereSeparator: \.isNewline) {
            let kv = line.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard kv.count == 2 else { continue }
            if kv[0] == "min" { lo = Double(kv[1]) } else if kv[0] == "max" { hi = Double(kv[1]) }
        }
        guard let lo, let hi, hi > lo else { return nil }
        return lo...hi
    }

    public var width: Int { cgImage.width }
    public var height: Int { cgImage.height }
    /// An RGB image: its figure pixels stay colour whatever is done to them.
    public var isColor: Bool { cgImage.colorSpace?.model == .rgb }
    /// How the original is stored, "8-bit RGB" for a colour one, nil for any other.
    public var colorStorage: String? { isColor ? "\(bitsPerComponent)-bit RGB" : nil }
    public var bitsPerComponent: Int { cgImage.bitsPerComponent }
    public var colorModel: String {
        switch cgImage.colorSpace?.model {
        case .monochrome: "Gray"
        case .rgb: "RGB"
        case .cmyk: "CMYK"
        default: "Other"
        }
    }
}

/// What detection works on, plus the pixels the figure shows.
///
/// Analysis always fills padding (so wedge edges don't read as bands) and zeroes it in the darkness map. Whether any
/// of that reaches the *figure* is up to the project: in strict mode the figure gets the original pixels, cropped only.
public struct WorkingImage: @unchecked Sendable {
    public let source: SourceImage
    /// Analysis image in working coordinates (padding filled; rotated when not strict).
    public let analysis: GrayImage
    public let padding: [Bool]
    public let background: Float
    public let strict: Bool
    public let rotation: Double
    public let fillPaddingInFigure: Bool
    /// Paint for rotation corners and old wedges in the figure (non-strict). Analysis always uses `background`.
    public private(set) var figureFill: Float = 1
    /// The padding wedges found in the unrotated picture (before rotation moved them), for filling the figure's pixels.
    private let sourcePadding: [Bool]
    /// The project's strips' working images, when whoever made this one attached them (the LLM tools' hosts do), so
    /// a figure can be drawn whole from it. See `StackedFigure`.
    public var strips: [WorkingImage] = []

    /// The figure pixels before the display mapping (fill and rotation done), made once: a brightness or contrast change only
    /// re-maps them. Shared by copies of this value; valid for its lifetime, which every setting that changes them ends.
    private final class Processed: @unchecked Sendable {
        let lock = NSLock()
        var gray: GrayImage?
        var rgb: RGB16?
    }
    private let cache = Processed()

    public init(source: SourceImage, project: GelProject) {
        let source = source.turned(project.turn)   // lossless, so before everything, Strict or not
        self.source = source
        strict = project.strict
        rotation = project.effectiveRotation
        fillPaddingInFigure = project.effectiveFillPadding

        var img = source.gray
        var pad = Self.paddingMask(img)
        sourcePadding = pad
        var bg = img.median { !pad[$0] }
        if pad.contains(true) { for i in pad.indices where pad[i] { img.pixels[i] = bg } }
        if abs(rotation) > 1e-6 {
            // the picture and its padding move together, and the corners the rotation uncovers are padding too
            let r = img.rotated(degrees: rotation, fill: bg, carrying: pad)
            img = r.image
            pad = r.mask ?? pad
            bg = img.median { !pad[$0] }
        }
        analysis = img
        padding = pad
        background = bg
        switch project.fillMode {
        case .background: figureFill = bg
        case .white: figureFill = 1
        case .custom: figureFill = Float(min(1, max(0, project.fillValue)))
        }
    }

    public var width: Int { analysis.width }
    public var height: Int { analysis.height }

    /// Signal strength on a 0...255 scale (bands positive), padding zeroed. A faint scan (a 16-bit gel using a sliver
    /// of its range) is scaled up so snapping and detection see its bands; gels spanning half the scale or more are
    /// left as they are.
    public func darkness(bandsDark: Bool) -> GrayImage {
        let stats = gelStats(crop: PixelRect(x0: 0, y0: 0, x1: Double(width), y1: Double(height)), bins: 1)
        let gain = Float(max(1, 0.5 / max(stats.auto.upperBound - stats.auto.lowerBound, 1e-6)))
        var out = [Float](repeating: 0, count: analysis.pixels.count)
        for i in out.indices where !padding[i] {
            let d = bandsDark ? background - analysis.pixels[i] : analysis.pixels[i] - background
            out[i] = max(0, d) * 255 * gain
        }
        return GrayImage(width: analysis.width, height: analysis.height, pixels: out, sourceBits: analysis.sourceBits)
    }

    /// The gel image as it goes into the figure.
    ///
    /// Strict: the original decoded image cropped on whole pixels — same values, bit depth and color space, never
    /// resampled. Otherwise: padding fill (if enabled), rotation and the display mapping applied, as 8-bit gray (8-bit
    /// RGB for a colour image, each channel mapped alike).
    /// `asGray`: a colour image is mapped as its gray luminance instead (for a figure stored as gray).
    public func figureImage(project: GelProject, asGray: Bool = false) -> CGImage? {
        let r = project.effectiveCrop(width: width, height: height)
        if project.strict {
            return source.cgImage.cropping(to: CGRect(x: r.x0, y: r.y0, width: r.width, height: r.height))
        }
        if !asGray, let rgb = processedRGB() { return rgb.cgImage(display: project.effectiveDisplay, crop: r) }
        return processedGray().cgImage(display: project.effectiveDisplay, crop: r)
    }

    /// Full-frame image for the editing canvas. Brightness & contrast always show here; in a Strict project they stay
    /// on screen (like ImageJ's display range before Apply) and exports keep the original pixels. `enhance` is the
    /// older screen-only auto stretch, still honoured for projects that had it on.
    /// `maxSide`: a picture at most about that many pixels along its long side, every pixel the mean of a block (for drawing a big image
    /// zoomed out: an exact factor of the image's size, never more than needed); the strict identity picture is always the original.
    public func viewImage(project: GelProject, enhance: Bool, maxSide: Int? = nil) -> CGImage? {
        if !enhance, project.strict, project.display.isIdentity { return source.cgImage }
        let f = maxSide.map { max(1, (max(width, height) + $0 - 1) / $0) } ?? 1
        // a colour image stays colour on screen: the same mapping on each channel
        let rgb = source.isColor ? processedRGB() : nil
        let base = (enhance || rgb == nil) ? (project.strict ? source.gray : processedGray()) : nil
        let display = enhance ? DisplaySettings.auto(for: base!, keeping: DisplaySettings(invert: project.display.invert)) : project.display
        if let rgb { return rgb.cgImage(display: display, decimate: f) }
        return base!.cgImage(display: display, decimate: f)
    }

    /// The gel's values inside `crop`, padding left out, with a `bins`-step histogram across them.
    public func gelStats(crop: PixelRect, bins: Int = 256) -> GelStats {
        let r = crop.normalized(width: width, height: height)
        let x0 = Int(r.x0.rounded()), y0 = Int(r.y0.rounded())
        let x1 = min(width, Int(r.x1.rounded())), y1 = min(height, Int(r.y1.rounded()))
        var fine = [Int](repeating: 0, count: 65536)
        var n = 0
        for y in y0..<max(y0, y1) {
            for x in x0..<max(x0, x1) where !padding[y * width + x] {
                fine[Int(analysis.pixels[y * width + x] * 65535)] += 1
                n += 1
            }
        }
        guard n > 0, let lo = fine.firstIndex(where: { $0 > 0 }), let hi = fine.lastIndex(where: { $0 > 0 }) else {
            return GelStats(range: 0...1, auto: 0...1, counts: [Int](repeating: 0, count: bins))
        }
        func percentile(_ q: Double) -> Int {
            let target = Int(Double(n) * q / 100)
            var acc = 0
            for (b, c) in fine.enumerated() { acc += c; if acc > target { return b } }
            return hi
        }
        let levels = Double((1 << min(max(analysis.sourceBits, 1), 16)) - 1)   // 255 for 8-bit
        let bins = max(1, min(bins, Int((Double(hi - lo) / 65535 * levels).rounded()) + 1))
        var counts = [Int](repeating: 0, count: bins)
        let span = Double(max(hi - lo, 1))
        for b in lo...hi where fine[b] > 0 {
            counts[min(bins - 1, Int(Double(b - lo) / span * Double(bins)))] += fine[b]
        }
        let a = percentile(0.1), z = max(percentile(99.9), a + 1)
        return GelStats(range: Double(lo) / 65535...Double(max(hi, lo + 1)) / 65535,
                        auto: Double(a) / 65535...Double(z) / 65535, counts: counts)
    }

    /// Non-strict figure pixels: the original gray, old wedges optionally painted, rotated; both use `figureFill`.
    private func processed() -> GrayImage {
        var img = source.gray
        if fillPaddingInFigure {
            if sourcePadding.contains(true) { for i in sourcePadding.indices where sourcePadding[i] { img.pixels[i] = figureFill } }
        }
        if abs(rotation) > 1e-6 { img = img.rotated(degrees: rotation, fill: figureFill) }
        return img
    }

    /// `processed()`, made once.
    private func processedGray() -> GrayImage {
        cache.lock.lock(); defer { cache.lock.unlock() }
        if let g = cache.gray { return g }
        let g = processed()
        cache.gray = g
        return g
    }

    /// `processed()` for a colour image: the same fill and rotation on each channel (none of either when the original pixels are
    /// kept: the decoded image as it is), made once. Nil for a gray one.
    private func processedRGB() -> RGB16? {
        guard source.isColor else { return nil }
        cache.lock.lock(); defer { cache.lock.unlock() }
        if let c = cache.rgb { return c }
        guard let base = RGB16.from(cgImage: source.cgImage) else { return nil }
        var out = base
        if fillPaddingInFigure, sourcePadding.contains(true) { out = out.filled(where: sourcePadding, with: figureFill) }
        if abs(rotation) > 1e-6 { out = out.rotated(degrees: rotation, fill: figureFill) }
        cache.rgb = out
        return out
    }

    /// The flat wedges left in the corners when an image was rotated before export, dilated by 3 px to swallow
    /// their anti-aliased rims.
    ///
    /// A wedge is a perfectly flat region that contains an image corner and whose value differs from the image's
    /// most common value. The last test matters: contrast-stretched exports often clip the gel background itself
    /// to one flat value that also reaches the corners, and that is gel, not padding.
    static func paddingMask(_ img: GrayImage, tol: Float = 1.0 / 255, minPixels: Int = 500) -> [Bool] {
        let w = img.width, h = img.height
        var mask = [Bool](repeating: false, count: w * h)
        guard w > 2, h > 2 else { return mask }
        var hist = [Int](repeating: 0, count: 256)
        for v in img.pixels { hist[Int((v * 255).rounded())] += 1 }
        let mode = Float(hist.indices.max { hist[$0] < hist[$1] }!) / 255
        var seen = [Bool](repeating: false, count: w * h)
        var stack: [Int] = []
        var region: [Int] = []
        img.pixels.withUnsafeBufferPointer { px in
            for start in [0, w - 1, (h - 1) * w, h * w - 1] where !seen[start] {
                let v = px[start]
                guard abs(v - mode) > 8.0 / 255 else { continue }   // the background itself, even if flat
                stack.removeAll(keepingCapacity: true); region.removeAll(keepingCapacity: true)
                stack.append(start)
                seen[start] = true
                while let i = stack.popLast() {
                    region.append(i)
                    let x = i % w, y = i / w
                    if x > 0, !seen[i - 1], abs(px[i - 1] - v) <= tol { seen[i - 1] = true; stack.append(i - 1) }
                    if x < w - 1, !seen[i + 1], abs(px[i + 1] - v) <= tol { seen[i + 1] = true; stack.append(i + 1) }
                    if y > 0, !seen[i - w], abs(px[i - w] - v) <= tol { seen[i - w] = true; stack.append(i - w) }
                    if y < h - 1, !seen[i + w], abs(px[i + w] - v) <= tol { seen[i + w] = true; stack.append(i + w) }
                }
                if region.count >= minPixels { for i in region { mask[i] = true } }
            }
        }
        guard mask.contains(true) else { return mask }   // nothing found, nothing to dilate
        for _ in 0..<3 {   // dilate 3 px (4-neighbour)
            var next = mask
            for y in 0..<h {
                let row = y * w
                for x in 0..<w where !mask[row + x] {
                    if (x > 0 && mask[row + x - 1]) || (x < w - 1 && mask[row + x + 1]) ||
                        (y > 0 && mask[row - w + x]) || (y < h - 1 && mask[row + w + x]) {
                        next[row + x] = true
                    }
                }
            }
            mask = next
        }
        return mask
    }
}

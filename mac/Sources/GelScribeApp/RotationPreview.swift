import AppKit
import GelKit

/// Changing a gel's angle must feel instant, while making its rotated pixels takes a moment (a 12 MP colour image: a tenth of a second
/// on all cores). So the angle shows at once as the last finished picture turned by the difference on a small copy of it, and the real
/// pixels are made in the background and swapped in when they are ready.
enum RotationPreview {
    /// The preview of one built picture: its small copy, and the last turned one, kept until the picture or the angle changes.
    final class Cache {
        private var smallKey = ""
        private var small: CGImage?
        private var turnedKey = ""
        private var turned: CGImage?

        /// `built` (a gel's full-frame screen image, built at some angle, identified by `key`) turned counter-clockwise by `degrees` about
        /// its centre, as an image of at most `maxSide` pixels: what the canvas draws until the exact pixels are ready. Corners the
        /// turn uncovers are `fill` (0...1 gray). Nil when no context can be made (the caller shows `built` as it is).
        func image(of built: CGImage, key: String, degrees: Double, fill: Double) -> CGImage? {
            let tk = "\(key)|\(degrees)|\(fill)"
            if tk == turnedKey, let turned { return turned }
            if smallKey != key || small == nil {
                small = RotationPreview.downscaled(built, maxSide: RotationPreview.previewSide)
                smallKey = key
            }
            guard let small, let out = RotationPreview.turned(small, degrees: degrees, fill: fill) else { return nil }
            turned = out; turnedKey = tk
            return out
        }
    }

    nonisolated static let maxSide = 2048
    /// The size a turning preview is made at: it is on screen for a moment, so it is made quickly.
    nonisolated static let previewSide = 1000

    private static func context(width: Int, height: Int, like img: CGImage) -> CGContext? {
        if img.colorSpace?.model == .monochrome, let space = img.colorSpace {
            return CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                             bitmapInfo: CGImageAlphaInfo.none.rawValue)
        }
        let space = img.colorSpace?.model == .rgb ? img.colorSpace! : CGColorSpace(name: CGColorSpace.sRGB)!
        return CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                         bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
    }

    /// `img` at most `maxSide` pixels along its long side (itself when it is that small already).
    static func downscaled(_ img: CGImage, maxSide: Int = RotationPreview.maxSide) -> CGImage? {
        let long = max(img.width, img.height)
        guard long > maxSide else { return img }
        let k = Double(maxSide) / Double(long)
        let w = max(1, Int((Double(img.width) * k).rounded())), h = max(1, Int((Double(img.height) * k).rounded()))
        guard let ctx = context(width: w, height: h, like: img) else { return nil }
        ctx.interpolationQuality = .medium
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage()
    }

    /// `img` turned counter-clockwise on screen by `degrees` about its centre, same size.
    static func turned(_ img: CGImage, degrees: Double, fill: Double) -> CGImage? {
        guard let ctx = context(width: img.width, height: img.height, like: img) else { return nil }
        let w = Double(img.width), h = Double(img.height)
        ctx.setFillColor(CGColor(gray: CGFloat(fill), alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.interpolationQuality = .medium
        ctx.translateBy(x: w / 2, y: h / 2)
        ctx.rotate(by: degrees * .pi / 180)   // counter-clockwise on screen: the bitmap is y-up
        ctx.translateBy(x: -w / 2, y: -h / 2)
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage()
    }
}

/// Where a gel's background pixel build stands.
struct RotationBuild {
    /// What a finished build must still match to land: changes whenever the pixels were replaced some other way.
    var serial = 0
    var running = false
    private var wanted: Double?
    private var since = 0.0

    /// What a build finished in the background brings.
    struct Result: @unchecked Sendable {
        var working: WorkingImage
        var dark: GrayImage
        var view: CGImage?
        var proxy: CGImage?
    }

    /// Whether to start the build for `rotation` now: not while one is running (its landing looks again), and not until the angle
    /// has held still for a moment. When it must wait, `redraw` is asked to look again in time.
    mutating func shouldStart(for rotation: Double, redraw: @escaping () -> Void) -> Bool {
        let now = ProcessInfo.processInfo.systemUptime
        if wanted != rotation { wanted = rotation; since = now }
        guard !running else { return false }
        let wait = 0.05 - (now - since)
        if wait > 0 {
            DispatchQueue.main.asyncAfter(deadline: .now() + wait) { redraw() }
            return false
        }
        return true
    }
}

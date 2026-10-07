import Foundation

// Port of gel_labeling/label_gel.py detection. The scipy pieces it relies on (gaussian_filter1d in 'reflect'
// mode, find_peaks with height/distance/prominence, peak_widths) are reproduced here so results match.

public struct LaneFit: Sendable, Equatable {
    public var centers: [Double]
    public var width: Double
    public var pitch: Double
}

public struct DetectedBand: Sendable, Equatable {
    /// Midpoint of the half-maximum interval: stays correct on saturated, flat-topped bands.
    public var y: Double
    public var fwhm: Double
    public var prominence: Double
}

public enum Detect {
    /// Evenly spaced comb (pitch + offset) fitted to the lane profile.
    ///
    /// The profile is log(1 + max darkness per column), so faint lanes weigh nearly as much as saturated ones and an
    /// alternating strong/weak pattern (e.g. load/pellet pairs) doesn't pull the pitch to twice the real spacing.
    /// With `count` the comb has exactly that many teeth; without it, the pitch comes from the first
    /// autocorrelation peak of the lane/gap mask.
    public static func lanes(in dark: GrayImage, count: Int? = nil) -> LaneFit {
        let W = dark.width
        // nothing to find in an image too narrow to hold lanes, or when asked for fewer than two (a comb needs two teeth)
        guard W >= 20, dark.height >= 1, count.map({ $0 >= 2 }) ?? true else { return LaneFit(centers: [], width: 0, pitch: 0) }
        let sm = Signal.gaussian2D(dark, sigma: 2)
        var colmax = [Float](repeating: 0, count: W)
        for y in 0..<sm.height {
            let row = y * W
            for x in 0..<W where sm.pixels[row + x] > colmax[x] { colmax[x] = sm.pixels[row + x] }
        }
        let prof = Signal.gaussian1D(colmax.map { log1p($0) }, sigma: 3)
        let peak = colmax.max() ?? 0
        let on = colmax.map { $0 > 0.15 * peak }

        let pitches: [Double]
        if let n = count, n >= 2 {
            pitches = Array(stride(from: 40.0, to: Double(W - 1) / Double(n - 1), by: 0.25))
        } else {
            var m = Signal.gaussian1D(on.map { $0 ? 1 : 0 }, sigma: 3)
            let mean = m.reduce(0, +) / Float(max(1, m.count))
            m = m.map { $0 - mean }
            let ac = Signal.autocorrelation(m)
            let tail = Array(ac[min(20, ac.count)..<max(20, min(ac.count, W / 2))])
            let pk = Signal.findPeaks(tail, height: 0.15, prominence: 0.1)
            let lag = pk.first.map { Double($0.index + 20) } ?? Double(W) / 4
            pitches = Array(stride(from: 0.9 * lag, to: 1.1 * lag, by: 0.25))
        }

        var best = (score: -Double.infinity, pitch: 0.0, offset: 0.0)
        for p in pitches {
            let nFit = count ?? Int(Double(W - 1) / p) + 1
            let span = Double(nFit - 1) * p
            let offsets: StrideTo<Double> = count != nil
                ? stride(from: 0, to: Double(W - 1) - span, by: 1)
                : stride(from: 0, to: p, by: 1)
            for o in offsets {
                var sumC = 0.0, nC = 0, sumG = 0.0, nG = 0
                for k in 0..<nFit {
                    let c = o + p * Double(k)
                    if c >= Double(W - 1) { break }
                    sumC += Signal.interp(prof, at: c); nC += 1
                    if k > 0 { sumG += Signal.interp(prof, at: c - p / 2); nG += 1 }
                }
                guard nC >= 2, nG >= 1 else { continue }
                // contrast between lane centers and gaps, normalized so tooth count alone can't win
                let score = sumC / Double(nC) - sumG / Double(nG)
                if score > best.score { best = (score, p, o) }
            }
        }
        guard best.pitch > 0 else { return LaneFit(centers: [], width: 0, pitch: 0) }

        var teeth: [Double]
        if let n = count {
            teeth = (0..<n).map { best.offset + best.pitch * Double($0) }
        } else {
            teeth = Array(stride(from: best.offset, to: Double(W - 1), by: best.pitch))
            let vals = teeth.map { Signal.interp(prof, at: $0) }
            let med = Signal.median(vals)
            teeth = zip(teeth, vals).filter { $0.1 > 0.6 * med }.map(\.0)
        }

        var widths: [Double] = []
        for c in teeth {
            let lo = max(0, Int(c - best.pitch / 2)), hi = min(W, Int(c + best.pitch / 2))
            guard lo < hi else { continue }
            if let a = (lo..<hi).first(where: { on[$0] }), let b = (lo..<hi).last(where: { on[$0] }) {
                widths.append(Double(b - a + 1))
            }
        }
        let width = widths.isEmpty ? 0.8 * best.pitch : Signal.median(widths)
        return LaneFit(centers: teeth.map { ($0 * 10).rounded() / 10 },
                       width: min(width, 0.9 * best.pitch).rounded(), pitch: (best.pitch * 100).rounded() / 100)
    }

    /// Vertical profile of one lane (mean over its central half, smoothed σ=2 px).
    public static func laneProfile(in dark: GrayImage, center: Double, width: Double) -> [Float] {
        guard center.isFinite, width.isFinite else { return [Float](repeating: 0, count: dark.height) }
        let x0 = max(0, (center - width * 0.25).safeInt), x1 = min(dark.width, (center + width * 0.25).safeInt + 1)
        guard x0 < x1 else { return [Float](repeating: 0, count: dark.height) }
        var prof = [Float](repeating: 0, count: dark.height)
        let n = Float(x1 - x0)
        for y in 0..<dark.height {
            var s: Float = 0
            let row = y * dark.width
            for x in x0..<x1 { s += dark.pixels[row + x] }
            prof[y] = s / n
        }
        return Signal.gaussian1D(prof, sigma: 2)
    }

    /// Bands along a lane: peaks with prominence ≥ `relProminence` × the lane's maximum, ≥ 12 px apart.
    public static func bands(in dark: GrayImage, center: Double, width: Double, relProminence: Float = 0.15) -> [DetectedBand] {
        let prof = laneProfile(in: dark, center: center, width: width)
        guard let top = prof.max(), top > 0 else { return [] }
        let peaks = Signal.findPeaks(prof, prominence: relProminence * top, distance: 12)
        return peaks.map { p in
            let (l, r) = Signal.halfWidth(prof, p)
            return DetectedBand(y: ((l + r) / 2).rounded(), fwhm: ((r - l) * 10).rounded() / 10,
                                prominence: (Double(p.prominence) * 10).rounded() / 10)
        }
    }
}

extension Detect {
    /// The center of the band under a click: the nearest peak (half-max midpoint) in the lane around `x`
    /// within ±`window` px of `y`. Nil when nothing band-like is there — the caller keeps the raw click.
    /// With `rows`, only a band whose centre is inside those rows counts, so snapping never carries a mark out of the
    /// rows its gel shows in the figure.
    public static func snapBand(in dark: GrayImage, x: Double, y: Double, laneWidth: Double, window: Double = 25,
                                rows: ClosedRange<Double>? = nil) -> Double? {
        // a position that isn't a number, or is nowhere near the image, has no band to snap to (and mustn't trap)
        guard x.isFinite, y.isFinite, laneWidth.isFinite, window.isFinite else { return nil }
        let half = max(3, laneWidth * 0.25)
        let x0 = max(0, (x - half).safeInt), x1 = min(dark.width, (x + half).safeInt + 1)
        let pad = max(0, window).safeInt + 40
        let y0 = max(0, y.safeInt - pad), y1 = min(dark.height, y.safeInt + pad + 1)
        guard x0 < x1, y1 - y0 > 5 else { return nil }
        var prof = [Float](repeating: 0, count: y1 - y0)
        for yy in y0..<y1 {
            var s: Float = 0
            let row = yy * dark.width
            for xx in x0..<x1 { s += dark.pixels[row + xx] }
            prof[yy - y0] = s / Float(x1 - x0)
        }
        prof = Signal.gaussian1D(prof, sigma: 2)
        guard let top = prof.max(), top > 2 else { return nil }
        let peaks = Signal.findPeaks(prof, prominence: max(1.5, 0.12 * top), distance: 6)
        let local = y - Double(y0)
        var best: (d: Double, c: Double)?
        for p in peaks {
            let (l, r) = Signal.halfWidth(prof, p)
            let c = (l + r) / 2
            if let rows, !rows.contains(((Double(y0) + c)).rounded()) { continue }
            let d = (local >= l && local <= r) ? 0 : abs(c - local)
            if d <= window, best == nil || d < best!.d { best = (d, c) }
        }
        return best.map { (Double(y0) + $0.c).rounded() }
    }
}

// MARK: - Calibration

/// Apparent size at a migration distance, interpolated piecewise-linearly in log(size) between labeled ladder bands.
public struct Calibration: Sendable {
    public let points: [(y: Double, logSize: Double)]

    /// From the main image's ticks: a cut membrane's strips have theirs in their own pixels.
    public init?(ladder: Ladder) {
        let pts = ladder.bands.compactMap { b -> (Double, Double)? in
            guard let s = b.size, s > 0, !b.ignore, b.strip == nil else { return nil }
            return (b.y, log10(s))
        }.sorted { $0.0 < $1.0 }
        guard pts.count >= 2 else { return nil }
        points = pts.map { (y: $0.0, logSize: $0.1) }
    }

    /// `extrapolated` is true outside the ladder's range, where the value is only a rough guide.
    public func size(atY y: Double) -> (size: Double, extrapolated: Bool) {
        let p = points
        var i = 0
        if y <= p[0].y { i = 0 } else if y >= p[p.count - 1].y { i = p.count - 2 } else {
            while i < p.count - 2 && y > p[i + 1].y { i += 1 }
        }
        let a = p[i], b = p[i + 1]
        let t = (y - a.y) / (b.y - a.y)
        let v = a.logSize + t * (b.logSize - a.logSize)
        return (pow(10, v), y < p[0].y || y > p[p.count - 1].y)
    }
}

// MARK: - Signal helpers (scipy-compatible)

public enum Signal {
    struct Peak { var index: Int; var prominence: Float; var leftBase: Int; var rightBase: Int }

    /// scipy.ndimage.gaussian_filter1d, truncate=4, mode='reflect' (d c b a | a b c d | d c b a).
    public static func gaussian1D(_ x: [Float], sigma: Double) -> [Float] {
        let n = x.count
        guard n > 1, sigma > 0 else { return x }
        let k = kernel(sigma)
        let r = k.count / 2
        var out = [Float](repeating: 0, count: n)
        x.withUnsafeBufferPointer { src in
            for i in 0..<n {
                var s: Float = 0
                for j in -r...r { s += k[j + r] * src[reflect(i + j, n)] }
                out[i] = s
            }
        }
        return out
    }

    public static func gaussian2D(_ img: GrayImage, sigma: Double) -> GrayImage {
        let w = img.width, h = img.height
        let k = kernel(sigma), r = k.count / 2
        var tmp = [Float](repeating: 0, count: w * h)
        var out = [Float](repeating: 0, count: w * h)
        img.pixels.withUnsafeBufferPointer { src in
            tmp.withUnsafeMutableBufferPointer { t in
                for y in 0..<h {
                    let row = y * w
                    for x in 0..<w {
                        var s: Float = 0
                        if x >= r && x < w - r {
                            for j in 0...(2 * r) { s += k[j] * src[row + x - r + j] }
                        } else {
                            for j in -r...r { s += k[j + r] * src[row + reflect(x + j, w)] }
                        }
                        t[row + x] = s
                    }
                }
            }
        }
        tmp.withUnsafeBufferPointer { t in
            out.withUnsafeMutableBufferPointer { o in
                for y in 0..<h {
                    for j in -r...r {
                        let wgt = k[j + r]
                        let srcRow = reflect(y + j, h) * w
                        let dstRow = y * w
                        for x in 0..<w { o[dstRow + x] += wgt * t[srcRow + x] }
                    }
                }
            }
        }
        return GrayImage(width: w, height: h, pixels: out, sourceBits: img.sourceBits)
    }

    static func kernel(_ sigma: Double) -> [Float] {
        let r = Int(4 * sigma + 0.5)
        var k = (-r...r).map { Float(exp(-0.5 * Double($0 * $0) / (sigma * sigma))) }
        let s = k.reduce(0, +)
        k = k.map { $0 / s }
        return k
    }

    @inline(__always) static func reflect(_ i: Int, _ n: Int) -> Int {
        var i = i
        let period = 2 * n
        i %= period
        if i < 0 { i += period }
        return i < n ? i : period - 1 - i
    }

    /// numpy.interp on integer sample positions, clamped at the ends.
    @inline(__always) public static func interp(_ y: [Float], at x: Double) -> Double {
        if !(x > 0) { return Double(y[0]) }   // also a position that isn't a number
        let last = y.count - 1
        if x >= Double(last) { return Double(y[last]) }
        let i = Int(x), f = x - Double(i)
        return Double(y[i]) * (1 - f) + Double(y[i + 1]) * f
    }

    static func autocorrelation(_ m: [Float]) -> [Float] {
        let n = m.count
        var ac = [Float](repeating: 0, count: n)
        m.withUnsafeBufferPointer { a in
            for lag in 0..<n {
                var s: Float = 0
                for i in 0..<(n - lag) { s += a[i] * a[i + lag] }
                ac[lag] = s
            }
        }
        let z = ac[0] == 0 ? 1 : ac[0]
        return ac.map { $0 / z }
    }

    public static func median(_ v: [Double]) -> Double {
        guard !v.isEmpty else { return 0 }
        let s = v.sorted()
        return s.count % 2 == 1 ? s[s.count / 2] : (s[s.count / 2 - 1] + s[s.count / 2]) / 2
    }

    /// scipy.signal.find_peaks: local maxima (plateau midpoints) → height → distance → prominence.
    static func findPeaks(_ x: [Float], height: Float? = nil, prominence: Float? = nil, distance: Int? = nil) -> [Peak] {
        let n = x.count
        guard n >= 3 else { return [] }
        var idx: [Int] = []
        var i = 1
        while i < n - 1 {
            if x[i - 1] < x[i] {
                var ahead = i + 1
                while ahead < n - 1 && x[ahead] == x[i] { ahead += 1 }
                if x[ahead] < x[i] {
                    idx.append((i + ahead - 1) / 2)
                    i = ahead
                }
            }
            i += 1
        }
        if let h = height { idx = idx.filter { x[$0] >= h } }
        if let d = distance, d > 1, idx.count > 1 {
            var keep = [Bool](repeating: true, count: idx.count)
            let order = idx.indices.sorted { x[idx[$0]] < x[idx[$1]] }
            for j in order.reversed() where keep[j] {
                var k = j - 1
                while k >= 0 && idx[j] - idx[k] < d { keep[k] = false; k -= 1 }
                k = j + 1
                while k < idx.count && idx[k] - idx[j] < d { keep[k] = false; k += 1 }
            }
            idx = idx.indices.filter { keep[$0] }.map { idx[$0] }
        }
        var peaks = idx.map { p -> Peak in
            var lmin = x[p], lbase = p, j = p
            while j >= 0 && x[j] <= x[p] { if x[j] < lmin { lmin = x[j]; lbase = j }; j -= 1 }
            var rmin = x[p], rbase = p
            j = p
            while j < n && x[j] <= x[p] { if x[j] < rmin { rmin = x[j]; rbase = j }; j += 1 }
            return Peak(index: p, prominence: x[p] - max(lmin, rmin), leftBase: lbase, rightBase: rbase)
        }
        if let pr = prominence { peaks = peaks.filter { $0.prominence >= pr } }
        return peaks
    }

    /// scipy.signal.peak_widths at rel_height 0.5: interpolated (left, right) crossing positions.
    static func halfWidth(_ x: [Float], _ p: Peak) -> (Double, Double) {
        let h = x[p.index] - p.prominence * 0.5
        var i = p.index
        while p.leftBase < i && h < x[i] { i -= 1 }
        var left = Double(i)
        if x[i] < h { left += Double((h - x[i]) / (x[i + 1] - x[i])) }
        i = p.index
        while i < p.rightBase && h < x[i] { i += 1 }
        var right = Double(i)
        if x[i] < h { right -= Double((h - x[i]) / (x[i - 1] - x[i])) }
        return (left, right)
    }
}

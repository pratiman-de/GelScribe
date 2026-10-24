import CoreGraphics
import Foundation

// Gels side by side (radioactive gels, each scanned on its own): left to right in stack order, every gel with its own lane dividers
// in its own pixels. Lanes are numbered continuously across the figure, one row of lane labels runs over all of them, and each
// gel is placed vertically against the gel with the lanes (`GelStrip.shift` and `scale` act on y: y in the gel = scale x y in the
// lanes gel + shift). The figure's grid is the lanes gel's rows; sideways every gel keeps its own kept columns, one pixel per pixel.

extension GelProject {
    /// Whether the gels sit side by side: that arrangement, and more than one gel (one gel is the same either way).
    public var isSideBySide: Bool { arrangement == .sideBySide && !strips.isEmpty }

    /// Gel `k`'s own lanes (nil = the gel with the lanes): a strip with none has no lanes yet.
    public func lanes(ofGel k: Int?) -> Lanes {
        guard let k else { return lanes }
        return k >= 1 && k <= strips.count ? strips[k - 1].lanes ?? Lanes() : Lanes()
    }

    public mutating func setLanes(_ l: Lanes, ofGel k: Int?) {
        guard let k else { lanes = l; return }
        if k >= 1 && k <= strips.count { strips[k - 1].lanes = l }
    }

    /// Continuous lane `n` (1-based, left to right across the figure) as a gel and that gel's own lane number.
    public func laneSlot(_ n: Int) -> (gel: Int?, lane: Int)? {
        guard n >= 1 else { return nil }
        guard isSideBySide else { return n <= lanes.centers.count ? (nil, n) : nil }
        var before = 0
        for g in stackOrder {
            let c = lanes(ofGel: g).centers.count
            if n <= before + c { return (g, n - before) }
            before += c
        }
        return nil
    }

    /// The continuous number of gel `k`'s own lane `lane`.
    public func continuousLane(gel k: Int?, lane: Int) -> Int? {
        guard isSideBySide else { return k == nil && lane >= 1 && lane <= lanes.centers.count ? lane : nil }
        var before = 0
        for g in stackOrder {
            let c = lanes(ofGel: g).centers.count
            if g == k { return lane >= 1 && lane <= c ? before + lane : nil }
            before += c
        }
        return nil
    }

    /// Lane `n` (continuous) as a lane of the gel with the lanes: its centre and width in that gel's own pixels. Nil when there is no
    /// such lane, or (side by side) it belongs to another gel.
    public func mainLaneInfo(_ n: Int) -> (x: Double, width: Double)? {
        guard let s = laneSlot(n), s.gel == nil else { return nil }
        return (lanes.centers[s.lane - 1], lanes.width)
    }

    /// Side by side: where the ticks of gel `k` (nil = the gel with the lanes) snap to, as x in that gel's own pixels. Each gel has its
    /// ladder in the lane with the same place on that gel as the ladder lane has on its own (lane 2 of its gel, say), when it has one.
    public func ladderLaneX(gel k: Int?, lane n: Int) -> (x: Double, width: Double)? {
        let l = lanes(ofGel: k)
        let local = laneSlot(n)?.lane ?? 1
        return local >= 1 && local <= l.centers.count ? (l.centers[local - 1], l.width) : nil
    }

    /// The message for a lane number that `mainLaneInfo` can't give, for tools that only work on the gel with the lanes.
    public func mainLaneProblem(_ n: Int) -> String {
        guard let s = laneSlot(n) else { return "lane \(n) doesn't exist (have \(laneCount))" }
        let r = laneNumbers(ofGel: nil)
        return "lane \(n) is on gel \(position(of: s.gel) + 1); this tool reads the gel with the lanes (lanes \(r.lowerBound) to \(r.upperBound - 1))"
    }

    /// The continuous numbers of the lanes gel `k` has (empty when it has none).
    public func laneNumbers(ofGel k: Int?) -> Range<Int> {
        let c = lanes(ofGel: k).centers.count
        guard isSideBySide else { return k == nil ? 1..<(c + 1) : 1..<1 }
        var before = 0
        for g in stackOrder {
            if g == k { return (before + 1)..<(before + 1 + c) }
            before += lanes(ofGel: g).centers.count
        }
        return 1..<1
    }

    /// Every lane's centre in figure pixels, in continuous order (nil for a lane outside its gel's kept columns, or on a gel that
    /// isn't in the figure), and a lane's width for group lines. Needs the stack for where each gel sits.
    public func figureLanes(stack: StackGeometry) -> (centers: [Double?], width: Double) {
        var out: [Double?] = [], widths: [Double] = []
        for g in stackOrder {
            let l = lanes(ofGel: g)
            let piece = stack.piece(strip: g)
            for c in l.centers {
                if let piece, c >= piece.sourceLeft, c <= piece.sourceRight { out.append(piece.toFigure(x: c, y: 0).x) } else { out.append(nil) }
            }
            if !l.centers.isEmpty { widths.append(l.width / (piece?.scale ?? 1)) }   // in figure pixels
        }
        return (out, widths.isEmpty ? lanes.width : widths.reduce(0, +) / Double(widths.count))
    }

    /// Side by side, whether gel `g` is the one the figure's ladder size labels come from: the leftmost gel with ladder ticks that have
    /// sizes. (Ticks on the other gels only guide the alignment.)
    public func isLadderLabelGel(_ g: Int?) -> Bool {
        guard isSideBySide, let l = ladder else { return true }
        let first = stackOrder.first { s in l.bands.contains { $0.strip == s && !$0.ignore && $0.size != nil } }
        guard let first else { return true }
        return first == g
    }
}

extension GelStrip {
    /// Kept columns side by side: its own, whole pixels inside the image (`width` wide), the whole width where none are set.
    public func sideColumns(width: Int) -> (left: Double, right: Double) {
        let w = Double(max(width, 1))
        let l = left.flatMap { $0.isFinite ? min(max($0.rounded(), 0), w - 1) : nil } ?? 0
        let r = right.flatMap { $0.isFinite ? min(max($0.rounded(), l + 1), w) : nil } ?? w
        return (l, max(r, l + 1))
    }
}

extension StripAlign {
    /// What lining a gel up vertically with the gel with the lanes found.
    public struct Vertical: Sendable, Equatable {
        public var shift: Double
        public var scale: Double
        /// Matching ladder bands used, 0 when the tops were lined up instead.
        public var bands: Int
        /// The worst distance, in the gel's own pixels, between a band and where the fit puts it.
        public var worst: Double
        public var note: String
    }

    /// y in the gel = scale x y in the lanes gel + shift (the one size in both directions), by least squares on the ticks that have the
    /// same size on both gels (at least 2; a size that is on more than one tick of a gel is left out). `keepsOriginal`: whole-pixel shift
    /// and scale 1. Without enough matches the gel is sized to the lanes gel's kept height with the tops lined up (`mainRows`, `gelRows`:
    /// each gel's kept rows in its own pixels); a gel that keeps its original pixels is only lined up by the tops, and told how far off
    /// the heights are.
    public static func vertical(_ p: GelProject, gel k: Int, mainRows: (top: Double, bottom: Double), gelRows: (top: Double, bottom: Double),
                                keepsOriginal: Bool) -> Vertical {
        func ticks(_ g: Int?) -> [Double: Double] {   // size -> y, for sizes on one tick only
            var seen: [Double: [Double]] = [:]
            for b in p.ladder?.bands ?? [] where b.strip == g && !b.ignore && b.y.isFinite {
                if let s = b.size, s.isFinite, p.isInFigure(strip: g, y: b.y) { seen[s, default: []].append(b.y) }
            }
            return seen.compactMapValues { $0.count == 1 ? $0[0] : nil }
        }
        let a = ticks(nil), b = ticks(k)
        let pairs = a.keys.filter { b[$0] != nil }.sorted().map { (x: a[$0]!, y: b[$0]!) }
        guard pairs.count >= 2 else {
            let mainH = max(mainRows.bottom - mainRows.top, 1), gelH = max(gelRows.bottom - gelRows.top, 1)
            let lanesGel = p.position(of: nil) + 1, thisGel = p.position(of: k) + 1
            if keepsOriginal {
                var note = "No matching ladder bands on both gels; tops lined up."
                if abs(gelH - mainH) >= 1 {
                    let f = FigureLayoutEngine.formatSize
                    note = "No matching ladder bands; tops lined up. Gel \(thisGel) is \(f(gelH)) px tall and Gel \(lanesGel) \(f(mainH)) px " +
                        "(\(String(format: "%.0f", abs(gelH / mainH - 1) * 100))% different). Turn off Keep original pixels for Gel \(thisGel) to size it to the same height."
                } else { note += " Place ladder ticks on both to line them up by size." }
                return Vertical(shift: (gelRows.top - mainRows.top).rounded(), scale: 1, bands: 0, worst: 0, note: note)
            }
            let scale = min(max(gelH / mainH, GelStrip.sideScales.lowerBound), GelStrip.sideScales.upperBound)
            return Vertical(shift: gelRows.top - scale * mainRows.top, scale: scale, bands: 0, worst: 0,
                            note: "No matching ladder bands; sized to the same height as Gel \(lanesGel) and tops lined up.")
        }
        let n = Double(pairs.count)
        let mx = pairs.reduce(0) { $0 + $1.x } / n, my = pairs.reduce(0) { $0 + $1.y } / n
        let sxx = pairs.reduce(0) { $0 + ($1.x - mx) * ($1.x - mx) }, sxy = pairs.reduce(0) { $0 + ($1.x - mx) * ($1.y - my) }
        var scale = sxx > 0 ? sxy / sxx : 1
        if !(scale.isFinite && scale > 0) { scale = 1 }
        scale = min(max(scale, GelStrip.sideScales.lowerBound), GelStrip.sideScales.upperBound)
        var shift = my - scale * mx
        if keepsOriginal { scale = 1; shift = (my - mx).rounded() }
        let worst = pairs.map { abs($0.y - (scale * $0.x + shift)) }.max() ?? 0
        var note = "Lined up on \(pairs.count) ladder bands, within \(String(format: "%.1f", worst)) px"
        if !keepsOriginal { note += "; stretched \(String(format: "%.1f", abs(scale - 1) * 100))%" }
        return Vertical(shift: shift, scale: scale, bands: pairs.count, worst: worst, note: note + ".")
    }
}

extension GelOps {
    /// Auto-align gel `k` vertically against the gel with the lanes (side by side), sizing it too (see `StripAlign.vertical`). `mainRows`:
    /// the lanes gel's kept rows; `gelHeight`: the gel's working height. Returns the note to show.
    @discardableResult
    public static func alignVertically(_ p: inout GelProject, gel k: Int, mainRows: (top: Double, bottom: Double), gelHeight: Int) -> String? {
        guard k >= 1, k <= p.strips.count else { return nil }
        let r = p.strips[k - 1].usedRows(height: gelHeight)
        let v = StripAlign.vertical(p, gel: k, mainRows: mainRows, gelRows: (r.top, r.bottom), keepsOriginal: p.isStrict(gel: k))
        p.strips[k - 1].shift = v.shift
        p.strips[k - 1].scale = v.scale
        return v.note
    }

    /// Stacks the gels top to bottom or puts them side by side. Every gel keeps its lanes, ticks, names and crop (a strip's own lanes
    /// stay in the file while stacked, unused). A gel's shift and stretch mean a sideways place when stacked and a vertical one side
    /// by side, so they start over (0 and 1) when the arrangement changes: line the gels up again after switching.
    public static func setArrangement(_ p: inout GelProject, _ a: Arrangement) {
        guard p.arrangement != a else { return }
        p.arrangement = a
        for i in p.strips.indices { p.strips[i].shift = 0; p.strips[i].scale = 1 }
    }
}

import Foundation

// A project.json that was damaged or edited by hand must load with sane numbers instead of crashing a later render:
// positions and sizes become whole-pixel counts somewhere down the line, and `Int(1e300)` or `Int(.nan)` traps. So on
// load anything non-finite or absurd is clamped or dropped here, and the render code guards its own conversions too.

/// What a project may hold.
enum Sane {
    /// Pixel positions, either way from the top-left corner.
    static let coordinate = 1_000_000.0
    /// Ladder sizes (kDa or bp).
    static let size = 1e12
    /// Lane numbers in labels, groups and the ladder.
    static let lanes = 4096
    /// Label rows above the gel.
    static let rows = 64

    static func isCoordinate(_ v: Double) -> Bool { v.isFinite && abs(v) <= coordinate }
    static func isSize(_ v: Double) -> Bool { v.isFinite && v > 0 && v <= size }
    static func clamp(_ v: Double, _ lo: Double, _ hi: Double, or fallback: Double) -> Double {
        v.isFinite ? min(max(v, lo), hi) : fallback
    }
}

extension DisplaySettings {
    mutating func sanitize() {
        black = Sane.clamp(black, -10, 10, or: 0)
        white = Sane.clamp(white, -10, 10, or: 1)
        gamma = Sane.clamp(gamma, 0.01, 100, or: 1)
    }
}

extension Lanes {
    mutating func sanitize() {
        width = width.isFinite && width > 0 ? min(width, Sane.coordinate) : 100
        if centers.count > Sane.lanes || !centers.allSatisfy(Sane.isCoordinate) { centers = [] }
        dividers.removeAll { !(Sane.isCoordinate($0.xTop) && Sane.isCoordinate($0.xBottom) && Sane.isCoordinate($0.dotY)) }
        if dividers.count > Sane.lanes { dividers = Array(dividers.prefix(Sane.lanes)) }
    }
}

extension LabelRow {
    mutating func sanitize() {
        rotation = Self.clampedAngle(rotation)
        for i in groups.indices { groups[i].lanes = groups[i].lanes.map { min(max($0, 1), Sane.lanes) } }
    }
}

extension LadderBand {
    /// Nil when the tick can't be kept: its row isn't a position, or it belongs to a gel the project doesn't have.
    func sanitized(strips: Int) -> LadderBand? {
        guard Sane.isCoordinate(y) else { return nil }
        if let k = strip, k < 1 || k > strips { return nil }
        var b = self
        if let s = size, !Sane.isSize(s) { b.size = nil; b.auto = false }
        return b
    }
}

extension BandAnnotation {
    func sanitized(strips: Int) -> BandAnnotation? {
        guard Sane.isCoordinate(y) else { return nil }
        if let k = strip, k < 1 || k > strips { return nil }
        var a = self
        if let y2, !Sane.isCoordinate(y2) { a.y2 = nil }
        return a
    }
}

extension Ladder {
    /// `strips`: how many other gels the project has, for the marks that name one.
    mutating func sanitize(strips: Int) {
        lane = min(max(lane, 1), Sane.lanes)
        if let s = sizes { sizes = s.filter(Sane.isSize) }
        bands = bands.compactMap { $0.sanitized(strips: strips) }
        if let y = unitY, !Sane.isCoordinate(y) { unitY = nil }
        if let k = unitStrip, k < 1 || k > strips { unitY = nil }
        if unitY == nil { unitStrip = nil }
    }
}

extension FigureStyle {
    mutating func sanitize() {
        let d = FigureStyle()
        if font.isEmpty { font = d.font }
        size = Sane.clamp(size, 1, 200, or: d.size)
        titleSize = Sane.clamp(titleSize, 1, 200, or: d.titleSize)
        gelWidthIn = Sane.clamp(gelWidthIn, 0.05, 100, or: d.gelWidthIn)
        tickLenPt = Sane.clamp(tickLenPt, 0, 100, or: d.tickLenPt)
        lineWidthPt = Sane.clamp(lineWidthPt, 0, 50, or: d.lineWidthPt)
        rowGapPt = Sane.clamp(rowGapPt, 0, 200, or: d.rowGapPt)
        groupLineInset = Sane.clamp(groupLineInset, 0, 1, or: d.groupLineInset)
        labelSep = Sane.clamp(labelSep, 0, 20, or: d.labelSep)
        leaderPt = Sane.clamp(leaderPt, 0, 100, or: d.leaderPt)
        func kind(_ v: Double?) -> Double? { v.map { Sane.clamp($0, 1, 200, or: size) } }
        laneLabelSize = kind(laneLabelSize); groupLabelSize = kind(groupLabelSize); rowNameSize = kind(rowNameSize)
        ladderLabelSize = kind(ladderLabelSize); nameSize = kind(nameSize)
        textSizes = textSizes.filter { Self.isTextSizeKey($0.key) && $0.value.isFinite }.mapValues { min(max($0, 1), 200) }
        if let dpi = exportDPI, !(dpi.isFinite && dpi >= 1 && dpi <= 10_000) { exportDPI = nil }
    }

    /// Whether `key` is one a single-label size can have (see `FigureRole.sizeKey`): `lane.R.L`, `group.R.G`, `rowname.R` or
    /// `name.I`, each number a whole one. Anything else in a hand-edited or damaged file is dropped on load.
    static func isTextSizeKey(_ key: String) -> Bool {
        let parts = key.split(separator: ".", omittingEmptySubsequences: false)
        func number(_ s: Substring) -> Bool { !s.isEmpty && s.allSatisfy { $0 >= "0" && $0 <= "9" } && Int(s) != nil }
        switch parts.first {
        case "lane", "group": return parts.count == 3 && number(parts[1]) && number(parts[2])
        case "rowname", "name": return parts.count == 2 && number(parts[1])
        default: return false
        }
    }

    /// After band names were taken out or put in another order: `oldIndex[i]` is where the name now at place i used to be
    /// (nil for a new one), so every name keeps its own single-name size.
    public mutating func remapNameSizes(oldIndex: [Int?]) {
        let old = textSizes.filter { $0.key.hasPrefix("name.") }
        guard !old.isEmpty else { return }
        for key in old.keys { textSizes[key] = nil }
        for (i, was) in oldIndex.enumerated() {
            if let was, let v = old["name.\(was)"] { textSizes["name.\(i)"] = v }
        }
    }
}

extension GelStrip {
    mutating func sanitize(scales: ClosedRange<Double> = 0.5...2) {
        turn = ((turn % 4) + 4) % 4
        rotateDeg = Sane.clamp(rotateDeg, -360, 360, or: 0)
        display.sanitize()
        lanes?.sanitize()
        shift = Sane.clamp(shift, -Sane.coordinate, Sane.coordinate, or: 0)
        scale = Sane.clamp(scale, scales.lowerBound, scales.upperBound, or: 1)   // side by side a gel may be sized much more
        // rows that aren't 0 <= top < bottom mean the whole gel
        let t = top ?? 0
        if let b = bottom {
            if !(t.isFinite && b.isFinite && t >= 0 && t < b) { top = nil; bottom = nil }
        } else if !(t.isFinite && t >= 0) {
            top = nil
        }
        // and columns that aren't 0 <= left < right the whole width
        let l = left ?? 0
        if let r = right {
            if !(l.isFinite && r.isFinite && l >= 0 && l < r) { left = nil; right = nil }
        } else if !(l.isFinite && l >= 0) {
            left = nil
        }
    }

    /// Where this gel's kept columns start and end, in its own pixels (its working image, after its turn, is `width` wide), when the
    /// gel with the lanes keeps figure columns `c` and this gel is lined up by `shift` and `scale`.
    ///
    /// An edge the gel has set is its own: whole pixels inside the image. An edge it hasn't follows the lanes gel's crop edge
    /// through the alignment, which is what stacking did before gels had columns of their own: a gel with none shows what lines up
    /// with the lanes gel's crop, and never makes the figure wider. A followed edge is exact and may lie past the image (stacking
    /// leaves blank what the gel has no pixels for). Columns that can't be used (not a number, or empty) are followed instead.
    func columns(width: Int, laneCrop c: PixelRect, shift: Double, scale: Double)
        -> (left: Double, right: Double, followsLeft: Bool, followsRight: Bool) {
        let w = Double(max(width, 1))
        var l = left.flatMap { $0.isFinite ? min(max($0.rounded(), 0), w - 1) : nil }
        var r = right.flatMap { $0.isFinite ? min(max($0.rounded(), 1), w) : nil }
        if let a = l, let b = r, !(a < b) { l = nil; r = nil }
        var out = (left: l ?? scale * c.x0 + shift, right: r ?? scale * c.x1 + shift, followsLeft: l == nil, followsRight: r == nil)
        // one edge set and the other followed can cross: the followed one is then the image's own edge
        if out.followsRight, let a = l, !(out.right > a) { out.right = w; out.followsRight = false }
        if out.followsLeft, let b = r, !(out.left < b) { out.left = 0; out.followsLeft = false }
        return out
    }

    /// The rows of this gel that go into the figure, as whole pixels with 0 <= top < bottom <= `height` (the gel's height
    /// in its turned image). Missing rows mean the edge, and rows that can't be used (not numbers, or empty) the whole
    /// gel. It's what stacking, aligning and the provenance note all use, so they agree.
    public func usedRows(height: Int) -> (top: Double, bottom: Double) {
        let h = Double(max(height, 1))
        let a = top ?? 0, b = bottom ?? h
        guard a.isFinite, b.isFinite else { return (0, h) }
        let t = min(max(a.rounded(), 0), h - 1)
        return (t, min(max(b.rounded(), t + 1), h))
    }

    /// `usedRows(height:)` as a range, for code that wants one (it can't be empty or backwards, so it can't trap).
    public func rowRange(height: Int) -> ClosedRange<Double> {
        let r = usedRows(height: height)
        return r.top...r.bottom
    }
}

extension GelProject {
    public static func decoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.allowsJSON5 = true   // also takes the NaN and Infinity some tools write; sanitize() puts them right
        return d
    }

    /// Puts anything non-finite or absurd back in range, drops marks that name a gel the project doesn't have, and makes
    /// every stacked gel's rows valid. Done on every load. Returns whether anything changed.
    @discardableResult
    public mutating func sanitize() -> Bool {
        let before = self
        turn = ((turn % 4) + 4) % 4
        rotateDeg = Sane.clamp(rotateDeg, -360, 360, or: 0)
        mainShift = Sane.clamp(mainShift, -Sane.coordinate, Sane.coordinate, or: 0)
        // a line thickness that isn't a number goes back to following the figure's lines, one outside 0.25 to 10 pt into that range
        separatorWidth = separatorWidth.flatMap { $0.isFinite ? min(max($0, Self.separatorWidths.lowerBound), Self.separatorWidths.upperBound) : nil }
        fillValue = Sane.clamp(fillValue, 0, 1, or: 0.9)
        if let c = crop, !(Sane.isCoordinate(c.x0) && Sane.isCoordinate(c.y0) && Sane.isCoordinate(c.x1) && Sane.isCoordinate(c.y1)) {
            crop = nil
        }
        display.sanitize()
        lanes.sanitize()
        if rows.count > Sane.rows { rows = Array(rows.prefix(Sane.rows)) }
        for i in rows.indices { rows[i].sanitize() }
        for i in strips.indices { strips[i].sanitize(scales: arrangement == .sideBySide ? GelStrip.sideScales : 0.5...2) }
        let n = strips.count
        ladder?.sanitize(strips: n)
        var kept: [Int] = []
        annotations = annotations.enumerated().compactMap { i, a in
            guard let ok = a.sanitized(strips: n) else { return nil }
            kept.append(i)
            return ok
        }
        style.sanitize()
        if kept.count != before.annotations.count { style.remapNameSizes(oldIndex: kept) }   // sizes follow their names
        return self != before
    }

    /// With the sizes of the gels known (each one's working image, after its quarter turns): rows that aren't
    /// 0 <= top < bottom <= height, and columns that aren't 0 <= left < right <= width, go back to the whole gel, and a mark outside its gel's image moves to the nearest
    /// row of it. `stripSizes[k - 1]` is strip k's; nil = not known.
    public mutating func normalize(mainSize: (width: Int, height: Int)?, stripSizes: [(width: Int, height: Int)?]) {
        for k in strips.indices where k < stripSizes.count {
            guard let size = stripSizes[k] else { continue }
            let h = Double(size.height), w = Double(size.width)
            let t = strips[k].top ?? 0, b = strips[k].bottom ?? h
            if !(t >= 0 && t < b && b <= h) { strips[k].top = nil; strips[k].bottom = nil }
            let l = strips[k].left ?? 0, r = strips[k].right ?? w
            if !(l >= 0 && l < r && r <= w) { strips[k].left = nil; strips[k].right = nil }
        }
        func height(_ strip: Int?) -> Double? {
            if let k = strip { return k >= 1 && k <= stripSizes.count ? stripSizes[k - 1].map { Double($0.height) } : nil }
            return mainSize.map { Double($0.height) }
        }
        func inside(_ y: Double, _ strip: Int?) -> Double { height(strip).map { min(max(y, 0), $0) } ?? y }
        if var l = ladder {
            for i in l.bands.indices { l.bands[i].y = inside(l.bands[i].y, l.bands[i].strip) }
            if let uy = l.unitY { l.unitY = inside(uy, l.unitStrip) }
            ladder = l
        }
        for i in annotations.indices {
            annotations[i].y = inside(annotations[i].y, annotations[i].strip)
            if let y2 = annotations[i].y2 { annotations[i].y2 = inside(y2, annotations[i].strip) }
        }
    }

    /// The gel with the lanes' size after its quarter turns, from the file's own size.
    public func workingSize(width: Int, height: Int) -> (width: Int, height: Int) {
        turn % 2 == 0 ? (width, height) : (height, width)
    }
}

extension GelOps {
    /// The message for rows that can't be used.
    public static func rowsMessage(height: Int) -> String { "Rows must be top,bottom with top < bottom, inside 0–\(height)." }

    /// Sets the rows of gel `k` (its number in `strips`) that go into the figure. `top` and `bottom` are clamped to 0…`height`
    /// (the gel's height in its turned image). Returns false, with the rows left as they were, when that leaves no rows
    /// (top must be less than bottom) or either isn't a number.
    @discardableResult
    public static func setStripRows(_ p: inout GelProject, strip k: Int, top: Double, bottom: Double, height: Int) -> Bool {
        guard k >= 1, k <= p.strips.count, top.isFinite, bottom.isFinite, height > 0 else { return false }
        let h = Double(height)
        let t = min(max(top, 0), h), b = min(max(bottom, 0), h)
        guard t < b else { return false }
        p.strips[k - 1].top = t
        p.strips[k - 1].bottom = b
        return true
    }

    /// The message for a crop that can't be used.
    public static func cropMessage(width: Int, height: Int) -> String {
        "A crop must be X0,Y0,X1,Y1 with X0 < X1 and Y0 < Y1, inside 0–\(width) across and 0–\(height) down."
    }

    /// Sets the crop of gel `k` (its number in `strips`): the columns and rows of it that go into the figure, clamped to the
    /// gel's image (`width`×`height`, after its quarter turns). Returns false, with the crop left as it was, when that leaves
    /// nothing (left must be less than right, top less than bottom) or a value isn't a number.
    @discardableResult
    public static func setStripCrop(_ p: inout GelProject, strip k: Int, left: Double, top: Double, right: Double, bottom: Double,
                                    width: Int, height: Int) -> Bool {
        guard k >= 1, k <= p.strips.count, [left, top, right, bottom].allSatisfy(\.isFinite), width > 0, height > 0 else { return false }
        let w = Double(width), h = Double(height)
        let l = min(max(left, 0), w), r = min(max(right, 0), w), t = min(max(top, 0), h), b = min(max(bottom, 0), h)
        guard l < r, t < b else { return false }
        p.strips[k - 1].left = l; p.strips[k - 1].right = r
        p.strips[k - 1].top = t; p.strips[k - 1].bottom = b
        return true
    }

    /// Takes out the band names `isRemoved` picks, so every other name keeps its own single-name size. Returns how many went.
    @discardableResult
    public static func removeAnnotations(_ p: inout GelProject, where isRemoved: (BandAnnotation) -> Bool) -> Int {
        let keep = p.annotations.indices.filter { !isRemoved(p.annotations[$0]) }
        let removed = p.annotations.count - keep.count
        guard removed > 0 else { return 0 }
        p.annotations = keep.map { p.annotations[$0] }
        p.style.remapNameSizes(oldIndex: keep)
        return removed
    }

    /// Takes out band name `index`.
    public static func removeAnnotation(_ p: inout GelProject, at index: Int) {
        guard p.annotations.indices.contains(index) else { return }
        var i = -1
        removeAnnotations(&p) { _ in i += 1; return i == index }
    }
}

extension GelProject {
    /// Gel `k`'s kept columns as whole pixels inside its image (`width` wide, after its turn), for showing them and for a crop to start
    /// from: its own where it has set them, else the lanes gel's crop through the alignment (see `GelStrip.columns`).
    /// `mainWidth`×`mainHeight`: the gel with the lanes' working image.
    public func keptColumns(strip k: Int, width: Int, mainWidth: Int, mainHeight: Int) -> (left: Double, right: Double) {
        let w = Double(max(width, 1))
        guard k >= 1, k <= strips.count else { return (0, w) }
        if isSideBySide { return strips[k - 1].sideColumns(width: width) }   // its own columns: nothing to follow
        let (shift, scale) = laneAlignment(k)
        let c = strips[k - 1].columns(width: width, laneCrop: effectiveCrop(width: mainWidth, height: mainHeight), shift: shift, scale: scale)
        guard c.left.isFinite, c.right.isFinite else { return (0, w) }
        let l = min(max(c.left.rounded(), 0), w - 1)
        return (l, min(max(c.right.rounded(), l + 1), w))
    }

    /// The rows gel `strip` (nil = the one with the lanes) shows in the figure, in that gel's own pixels. `width`×`height`:
    /// that gel's working image. A tick or name belongs between them.
    public func figureRows(strip: Int?, width: Int, height: Int) -> ClosedRange<Double> {
        if let k = strip, k >= 1, k <= strips.count { return strips[k - 1].rowRange(height: height) }
        let c = effectiveCrop(width: width, height: height)
        return c.y0...max(c.y0, c.y1)
    }

    /// `y` moved into the rows gel `strip` shows in the figure (see `figureRows`), for placing, dragging, snapping and
    /// nudging a tick or name. A value that isn't a number goes to the top row.
    public func clampY(_ y: Double, strip: Int?, width: Int, height: Int) -> Double {
        let r = figureRows(strip: strip, width: width, height: height)
        return min(max(y.isFinite ? y : r.lowerBound, r.lowerBound), r.upperBound)
    }
}

extension GelProject {
    /// "Gel N's image (file) can't be read." for gel `strip` (nil = the one with the lanes), N counted from the top of the
    /// figure: what exports, Copy Figure and the command-line tool say when a gel's picture can't be decoded.
    public func unreadableMessage(strip: Int?) -> String {
        let file = strip.flatMap { $0 >= 1 && $0 <= strips.count ? strips[$0 - 1].image : nil } ?? image
        return GelKitError.unreadableGel(number: position(of: strip) + 1, file: file).errorDescription ?? "A gel's image can't be read."
    }
}

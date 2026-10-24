import Foundation

/// Edits shared by the app, the CLI and the MCP tools, so all three change a project the same way.
public enum GelOps {
    // MARK: lanes

    /// A vertical divider through the clicked point (one click per gap between lanes).
    /// `gel`: side by side, a strip's number adds it to that gel's own lanes (dividers are in that gel's pixels).
    public static func addDivider(_ p: inout GelProject, x: Double, y: Double, imageWidth: Int, imageHeight: Int, gel: Int? = nil) {
        guard Sane.isCoordinate(x), Sane.isCoordinate(y), gel == nil || (1...max(p.strips.count, 1)).contains(gel!) && !p.strips.isEmpty else { return }
        var l = p.lanes(ofGel: gel)
        l.dividers.append(LaneDivider(x: x, dotY: y))
        l.dividers.sort { ($0.xTop + $0.xBottom) < ($1.xTop + $1.xBottom) }
        p.setLanes(l, ofGel: gel)
        p.syncLaneCenters(imageWidth: imageWidth, imageHeight: imageHeight, gel: gel)
    }

    /// Replaces all dividers with vertical ones at `xs` (positions that aren't numbers are left out). With none, the lanes
    /// go too, so no lane centres are left behind without dividers.
    public static func setDividers(_ p: inout GelProject, xs: [Double], imageWidth: Int, imageHeight: Int, gel: Int? = nil) {
        guard gel == nil || (gel! >= 1 && gel! <= p.strips.count) else { return }
        // dot a little inside the visible gel, clear of the end handle
        let top: Double, height: Double
        if let k = gel {
            let r = p.strips[k - 1].usedRows(height: imageHeight)
            (top, height) = (r.top, r.bottom - r.top)
        } else {
            let c = p.effectiveCrop(width: imageWidth, height: imageHeight)
            (top, height) = (c.y0, c.height)
        }
        let y = (top + height * 0.14).rounded()
        var l = p.lanes(ofGel: gel)
        l.dividers = xs.filter(Sane.isCoordinate).sorted().map { LaneDivider(x: $0, dotY: y) }
        if l.dividers.isEmpty { l.centers = [] }
        p.setLanes(l, ofGel: gel)
        p.syncLaneCenters(imageWidth: imageWidth, imageHeight: imageHeight, gel: gel)
    }

    /// Fallback for the CLI/LLM: detect lane centers, then place dividers midway between them.
    @discardableResult
    public static func autoDividers(_ p: inout GelProject, _ w: WorkingImage, count: Int?, gel: Int? = nil) -> LaneFit {
        let bandsDark = gel.map { $0 >= 1 && $0 <= p.strips.count ? p.strips[$0 - 1].display.bandsDark : p.display.bandsDark } ?? p.display.bandsDark
        let fit = Detect.lanes(in: w.darkness(bandsDark: bandsDark), count: count)
        guard fit.centers.count >= 2 else { return fit }
        let mids = zip(fit.centers, fit.centers.dropFirst()).map { ($0 + $1) / 2 }
        var l = p.lanes(ofGel: gel)
        l.outerLanes = true
        p.setLanes(l, ofGel: gel)
        setDividers(&p, xs: mids, imageWidth: w.width, imageHeight: w.height, gel: gel)
        return fit
    }

    /// Lane geometry, from dividers or (for dividerless configs) from `centers`.
    /// `gel`: a strip's number gives that gel's own lanes (side by side), `imageWidth`/`imageHeight` being that gel's.
    public static func geometry(_ p: GelProject, imageWidth: Int, imageHeight: Int, gel: Int? = nil) -> LaneGeometry? {
        let lanes = p.lanes(ofGel: gel)
        if let g = LaneGeometry.resolve(lanes, imageWidth: Double(imageWidth), imageHeight: Double(imageHeight)) { return g }
        let c = lanes.centers
        guard !c.isEmpty else { return nil }
        let half = lanes.width / 0.85 / 2
        var lines: [LaneGeometry.Line] = [LaneGeometry.Line(xTop: c[0] - half, xBottom: c[0] - half)]
        for (a, b) in zip(c, c.dropFirst()) { let m = (a + b) / 2; lines.append(.init(xTop: m, xBottom: m)) }
        lines.append(.init(xTop: c[c.count - 1] + half, xBottom: c[c.count - 1] + half))
        return LaneGeometry(boundaries: lines, height: Double(imageHeight))
    }

    // MARK: rotation

    /// Moves dividers, ticks and band names with the image when it turns by `delta` degrees (counter-clockwise on
    /// screen, about the image center — the same mapping `GrayImage.rotated` uses), so they stay on their bands.
    public static func rotateMarks(_ p: inout GelProject, by delta: Double, imageWidth: Int, imageHeight: Int) {
        guard delta.isFinite, abs(delta) > 1e-9 else { return }
        let t = delta * .pi / 180, c = cos(t), s = sin(t)
        let cx = Double(imageWidth - 1) / 2, cy = Double(imageHeight - 1) / 2
        let H = Double(imageHeight)
        func turn(_ x: Double, _ y: Double) -> (Double, Double) {
            let dx = x - cx, dy = y - cy
            return (c * dx + s * dy + cx, -s * dx + c * dy + cy)
        }
        for i in p.lanes.dividers.indices {
            let d = p.lanes.dividers[i]
            let a = turn(d.xTop, 0), b = turn(d.xBottom, H), dot = turn(d.x(atY: d.dotY, height: H), d.dotY)
            // the turned line through a and b, re-expressed by its x at the image's top and bottom rows
            let m = abs(b.1 - a.1) < 1e-9 ? 0 : (b.0 - a.0) / (b.1 - a.1)
            p.lanes.dividers[i].xTop = a.0 - m * a.1
            p.lanes.dividers[i].xBottom = a.0 + m * (H - a.1)
            p.lanes.dividers[i].dotY = dot.1
        }
        let centers = p.lanes.centers
        if var l = p.ladder {
            let x = p.isSideBySide ? p.ladderLaneX(gel: nil, lane: l.lane)?.x ?? cx
                : l.lane >= 1 && l.lane <= centers.count ? centers[l.lane - 1] : cx
            for i in l.bands.indices where l.bands[i].strip == nil { l.bands[i].y = turn(x, l.bands[i].y).1.rounded() }
            if let uy = l.unitY, l.unitStrip == nil { l.unitY = turn(x, uy).1.rounded() }
            p.ladder = l
        }
        for i in p.annotations.indices where p.annotations[i].strip == nil {
            let x = p.annotations[i].side == .right ? (centers.last ?? cx) : (centers.first ?? cx)
            p.annotations[i].y = turn(x, p.annotations[i].y).1.rounded()
            if let y2 = p.annotations[i].y2 { p.annotations[i].y2 = turn(x, y2).1.rounded() }
        }
        p.syncLaneCenters(imageWidth: imageWidth, imageHeight: imageHeight)
    }

    /// Sets the rotation, moving the marks by the change in the angle that actually applies.
    public static func setRotation(_ p: inout GelProject, degrees: Double, imageWidth: Int, imageHeight: Int) {
        guard degrees.isFinite else { return }
        let before = p.effectiveRotation
        p.rotateDeg = (degrees * 100).rounded() / 100
        rotateMarks(&p, by: p.effectiveRotation - before, imageWidth: imageWidth, imageHeight: imageHeight)
    }

    /// Keep original pixels on ignores a gel's rotation (and off applies it again); marks follow either way, the strips' too
    /// (`stripSizes`: their working-image sizes by strip number, nil for a gel that isn't there, so the others keep their place).
    /// `gel`: a strip's number sets that gel's own value; nil sets the gel with the lanes', which the strips that have no
    /// value of their own follow.
    public static func setStrict(_ p: inout GelProject, _ strict: Bool, gel: Int? = nil, imageWidth: Int, imageHeight: Int,
                                 stripSizes: [(width: Int, height: Int)?] = []) {
        if let k = gel, k < 1 || k > p.strips.count { return }
        let before = p.effectiveRotation
        let stripBefore = p.strips.indices.map { p.isStrict(gel: $0 + 1) ? 0 : p.strips[$0].rotateDeg }
        if let k = gel { p.strips[k - 1].strict = strict } else { p.strict = strict }
        rotateMarks(&p, by: p.effectiveRotation - before, imageWidth: imageWidth, imageHeight: imageHeight)
        for (i, size) in stripSizes.enumerated() where i < p.strips.count {
            guard let size else { continue }
            let now = p.isStrict(gel: i + 1) ? 0 : p.strips[i].rotateDeg
            rotateStripMarks(&p, strip: i + 1, by: now - stripBefore[i], width: size.width, height: size.height)
        }
    }

    // MARK: strips

    /// Lane `n`'s center in strip `k`'s own pixels (lanes are the main image's, lined up through the alignment).
    public static func laneX(_ p: GelProject, lane n: Int, strip k: Int) -> Double? {
        if p.isSideBySide { return k >= 1 && k <= p.strips.count ? p.ladderLaneX(gel: k, lane: n)?.x : nil }   // each gel's own lanes
        guard n >= 1, n <= p.lanes.centers.count, k >= 1, k <= p.strips.count else { return nil }
        let a = p.laneAlignment(k)   // the lanes are the lanes gel's, wherever it sits
        return a.scale * p.lanes.centers[n - 1] + a.shift
    }

    /// Moves strip `k`'s ticks and names with its image when it turns by `delta` degrees (as `rotateMarks`).
    public static func rotateStripMarks(_ p: inout GelProject, strip k: Int, by delta: Double, width: Int, height: Int) {
        guard delta.isFinite, abs(delta) > 1e-9, k >= 1, k <= p.strips.count else { return }
        let t = delta * .pi / 180, c = cos(t), s = sin(t)
        let cx = Double(width - 1) / 2, cy = Double(height - 1) / 2
        func turnY(_ x: Double, _ y: Double) -> Double { -s * (x - cx) + c * (y - cy) + cy }
        if var l = p.ladder {
            let x = laneX(p, lane: l.lane, strip: k) ?? cx
            for i in l.bands.indices where l.bands[i].strip == k { l.bands[i].y = turnY(x, l.bands[i].y).rounded() }
            if let uy = l.unitY, l.unitStrip == k { l.unitY = turnY(x, uy).rounded() }
            p.ladder = l
        }
        let n = p.lanes.centers.count
        for i in p.annotations.indices where p.annotations[i].strip == k {
            let x = laneX(p, lane: p.annotations[i].side == .right ? n : 1, strip: k) ?? cx
            p.annotations[i].y = turnY(x, p.annotations[i].y).rounded()
            if let y2 = p.annotations[i].y2 { p.annotations[i].y2 = turnY(x, y2).rounded() }
        }
    }

    /// Straightens strip `k` (it resamples, so it only applies while that gel doesn't keep original pixels); its marks move
    /// with it.
    public static func setStripRotation(_ p: inout GelProject, strip k: Int, degrees: Double, width: Int, height: Int) {
        guard k >= 1, k <= p.strips.count, degrees.isFinite else { return }
        let keeps = p.isStrict(gel: k)
        let before = keeps ? 0 : p.strips[k - 1].rotateDeg
        p.strips[k - 1].rotateDeg = (degrees * 100).rounded() / 100
        rotateStripMarks(&p, strip: k, by: (keeps ? 0 : p.strips[k - 1].rotateDeg) - before, width: width, height: height)
    }

    /// Turns a piece by quarter turns (`strip` nil = the main image). `width`×`height` is its working image before.
    /// A half turn carries its marks across; a quarter turn makes lanes run the other way, so that piece's marks go
    /// (crop, and for the main image its dividers), and the unit label if it was placed on that piece.
    public static func turn(_ p: inout GelProject, strip k: Int?, by quarterTurns: Int, width W: Int, height H: Int) {
        let q = ((quarterTurns % 4) + 4) % 4
        guard q != 0 else { return }
        let w = Double(W), h = Double(H)
        if let k {
            guard k >= 1, k <= p.strips.count else { return }
            p.strips[k - 1].turn = (p.strips[k - 1].turn + q) % 4
            if var l = p.strips[k - 1].lanes {   // this gel's own lanes (side by side) turn with it, or go when lanes would run the other way
                if q == 2 {
                    l.dividers = l.dividers.map {
                        var d = $0
                        (d.xTop, d.xBottom, d.dotY) = (w - 1 - $0.xBottom, w - 1 - $0.xTop, h - 1 - $0.dotY)
                        return d
                    }.sorted { ($0.xTop + $0.xBottom) < ($1.xTop + $1.xBottom) }
                } else { l.dividers = []; l.centers = [] }
                p.strips[k - 1].lanes = l
            }
            if q == 2 {
                let s = p.strips[k - 1]
                (p.strips[k - 1].top, p.strips[k - 1].bottom) = (s.bottom.map { h - $0 }, s.top.map { h - $0 })
                (p.strips[k - 1].left, p.strips[k - 1].right) = (s.right.map { w - $0 }, s.left.map { w - $0 })
                // a crop that doesn't fit the gel (it should have, before) goes back to the whole gel
                let t = p.strips[k - 1].top ?? 0, b = p.strips[k - 1].bottom ?? h
                if !(t >= 0 && t < b && b <= h) { p.strips[k - 1].top = nil; p.strips[k - 1].bottom = nil }
                let l = p.strips[k - 1].left ?? 0, r = p.strips[k - 1].right ?? w
                if !(l >= 0 && l < r && r <= w) { p.strips[k - 1].left = nil; p.strips[k - 1].right = nil }
            } else {
                p.strips[k - 1].top = nil; p.strips[k - 1].bottom = nil   // a quarter turn swaps width and height: the crop starts over
                p.strips[k - 1].left = nil; p.strips[k - 1].right = nil
            }
        } else {
            p.turn = (p.turn + q) % 4
            if q != 2 { p.mainShift = 0 }   // a quarter turn swaps the gel's width and height: where it sat sideways starts over
            if q == 2 {
                p.crop = p.crop.map { PixelRect(x0: w - $0.x1, y0: h - $0.y1, x1: w - $0.x0, y1: h - $0.y0) }
                p.lanes.dividers = p.lanes.dividers.map {
                    var d = $0
                    (d.xTop, d.xBottom, d.dotY) = (w - 1 - $0.xBottom, w - 1 - $0.xTop, h - 1 - $0.dotY)
                    return d
                }.sorted { ($0.xTop + $0.xBottom) < ($1.xTop + $1.xBottom) }
            } else {
                p.crop = nil; p.lanes.dividers = []; p.lanes.centers = []
            }
        }
        if var l = p.ladder {
            if q == 2 {
                for i in l.bands.indices where l.bands[i].strip == k { l.bands[i].y = h - 1 - l.bands[i].y }
                if let uy = l.unitY, l.unitStrip == k { l.unitY = h - 1 - uy }
            } else {
                l.bands.removeAll { $0.strip == k }
                if l.unitStrip == k { l.unitY = nil; l.unitStrip = nil }   // the label was on a gel whose bands just went
            }
            p.ladder = l
        }
        if q == 2 {
            for i in p.annotations.indices where p.annotations[i].strip == k {
                p.annotations[i].y = h - 1 - p.annotations[i].y
                if let y2 = p.annotations[i].y2 { p.annotations[i].y2 = h - 1 - y2 }
            }
        } else {
            removeAnnotations(&p) { $0.strip == k }   // the other names keep their own sizes
        }
        if k == nil && q == 2 { p.syncLaneCenters(imageWidth: W, imageHeight: H) }
        if let k, q == 2, p.strips.indices.contains(k - 1), p.strips[k - 1].lanes != nil { p.syncLaneCenters(imageWidth: W, imageHeight: H, gel: k) }
    }

    /// Takes strip `k` out, with its ticks and names; the gels under it move up one.
    public static func removeStrip(_ p: inout GelProject, _ k: Int) {
        guard k >= 1, k <= p.strips.count else { return }
        if k - 1 < p.mainSlot { p.mainPosition = p.mainSlot - 1 }
        p.strips.remove(at: k - 1)
        func renumber(_ s: Int?) -> Int? { s.map { $0 > k ? $0 - 1 : $0 } }
        if var l = p.ladder {
            l.bands.removeAll { $0.strip == k }
            for i in l.bands.indices { l.bands[i].strip = renumber(l.bands[i].strip) }
            if l.unitStrip == k { l.unitY = nil; l.unitStrip = nil } else { l.unitStrip = renumber(l.unitStrip) }   // back to automatic
            p.ladder = l
        }
        removeAnnotations(&p) { $0.strip == k }   // before renumbering; the other names keep their own sizes
        for i in p.annotations.indices { p.annotations[i].strip = renumber(p.annotations[i].strip) }
    }

    /// Moves the gel at place `from` in the stack (counted from the top, from 0) to place `to`; the others keep their
    /// order. Each gel keeps its own settings, ticks and names.
    public static func moveGel(_ p: inout GelProject, from: Int, to: Int) {
        var order = Array(p.stackOrder.indices)
        guard order.indices.contains(from), order.indices.contains(to), from != to else { return }
        order.insert(order.remove(at: from), at: to)
        reorder(&p, order)
    }

    /// Puts the gels in a new order: `order[i]` is the current place (from 0 at the top) of the gel that goes to
    /// place i. Ignored unless it lists every place once.
    public static func reorder(_ p: inout GelProject, _ order: [Int]) {
        let ids = p.stackOrder
        guard order.count == ids.count, Set(order) == Set(ids.indices) else { return }
        let wanted = order.map { ids[$0] }
        let old = p.strips
        var number: [Int: Int] = [:]   // old strip number → new
        p.strips = wanted.compactMap { $0 }.enumerated().map { i, k in number[k] = i + 1; return old[k - 1] }
        p.mainPosition = wanted.firstIndex { $0 == nil } ?? 0
        // a mark that names a gel follows it; one that names a gel the project doesn't have is dropped, never given to
        // the gel with the lanes
        func follows(_ strip: Int?) -> Bool { strip == nil || number[strip!] != nil }
        if var l = p.ladder {
            l.bands = l.bands.filter { follows($0.strip) }
            for i in l.bands.indices { l.bands[i].strip = l.bands[i].strip.flatMap { number[$0] } }
            if let k = l.unitStrip { if let n = number[k] { l.unitStrip = n } else { l.unitY = nil; l.unitStrip = nil } }
            p.ladder = l
        }
        removeAnnotations(&p) { !follows($0.strip) }
        for i in p.annotations.indices { p.annotations[i].strip = p.annotations[i].strip.flatMap { number[$0] } }
    }

    /// The rotation change that levels a line drawn from a to b: to horizontal if it's flatter than 45°, else vertical.
    public static func levelingAngle(from a: (x: Double, y: Double), to b: (x: Double, y: Double)) -> Double {
        let dx = b.x - a.x, dy = b.y - a.y
        if abs(dx) >= abs(dy) {
            let dxp = dx < 0 ? -dx : dx, dyp = dx < 0 ? -dy : dy   // direction-independent
            return atan2(dyp, dxp) * 180 / .pi
        } else {
            let dxp = dy < 0 ? -dx : dx, dyp = dy < 0 ? -dy : dy
            return -atan2(dxp, dyp) * 180 / .pi
        }
    }

    // MARK: labels

    /// Lane labels from the shorthand (`µM: Ladder|0{L|P}|…`). Without typed titles the label rows keep the ones
    /// they had; `groupRowName` names the row right above the lane labels.
    @discardableResult
    /// `keepTitles`: with no titles typed, keep the rows' current ones (pasting bare labels from another gel). Off
    /// when the text is the project's own shorthand being edited, where a deleted title should go.
    public static func applyQuickLabels(_ p: inout GelProject, text: String, groupRowName: String? = nil,
                                        keepTitles: Bool = true) -> QuickLabels.Result {
        let (typed, body) = QuickLabels.splitRowName(text)
        var names = typed.isEmpty && keepTitles ? p.rows.filter { $0.type == .groups }.reversed().map { $0.name ?? "" } : typed
        if let groupRowName { names = Array(names.dropLast()) + [groupRowName] }
        let parsed = QuickLabels.parse(body)
        if let error = parsed.error {   // refused: the labels stay as they were
            return QuickLabels.Result(rows: p.rows, ladderLane: nil, perLane: [], warnings: [error], error: error)
        }
        var r = QuickLabels.build(parsed.items, laneCount: p.laneCount, knownLadderLane: p.ladder?.lane, rowNames: names)
        r.warnings = parsed.warnings + r.warnings
        let layers = r.rows.count - 1
        if typed.count > layers {
            r.warnings.append("\(typed.count) row titles for \(layers) label row\(layers == 1 ? "" : "s") above the lanes; the top ones were left out.")
        }
        let angle = p.labelAngle   // the figure's one label angle survives retyping the labels
        let groupAngles = p.rows.filter { $0.type == .groups }.map(\.rotation)   // and each group row's, by its place among them
        p.rows = r.rows
        if angle > 0 { setLabelAngle(&p, angle) }
        var n = 0
        for i in p.rows.indices where p.rows[i].type == .groups {
            if n < groupAngles.count { p.rows[i].rotation = groupAngles[n] }
            n += 1
        }
        if let lane = r.ladderLane {
            if p.ladder == nil { p.ladder = Ladder(lane: lane) } else { p.ladder!.lane = lane }
        }
        return r
    }

    /// Stands the lane labels at `degrees` (0 horizontal, 90 straight up), clamped to that range: set on every row of lane
    /// labels, so the figure has one angle. Returns false, changing nothing, when `degrees` isn't a number or there are
    /// no lane labels yet.
    @discardableResult
    public static func setLabelAngle(_ p: inout GelProject, _ degrees: Double) -> Bool {
        guard degrees.isFinite else { return false }
        let angle = LabelRow.clampedAngle(degrees)
        var any = false
        for i in p.rows.indices where p.rows[i].type == .lanes {
            p.rows[i].rotation = angle
            any = true
        }
        return any
    }

    /// Stands the group labels of row `row` (its place in `rows`, index 0 on the gel) at `degrees`, any angle, brought into
    /// 0 ..< 360: each group row has its own, the underline stays flat. Returns false, changing nothing, when `degrees` isn't a
    /// number or `row` isn't a row of group labels (lane labels share the figure's one angle: `setLabelAngle`).
    @discardableResult
    public static func setRowAngle(_ p: inout GelProject, row: Int, _ degrees: Double) -> Bool {
        guard degrees.isFinite, p.rows.indices.contains(row), p.rows[row].type == .groups else { return false }
        p.rows[row].rotation = LabelRow.clampedAngle(degrees)
        return true
    }

    // MARK: ladder ticks

    /// A tick at `y` (usually snapped to a band center). The first tick also fixes the ladder lane and side.
    /// `auto` marks the size as a suggestion the user hasn't confirmed. Returns the new tick's id (nil when nothing was added), so
    /// a second tick on the same row is found by its own id and never mistaken for the older one.
    @discardableResult
    public static func addTick(_ p: inout GelProject, y: Double, size: Double?, auto: Bool = false, lane: Int?, gelCenterX: Double?,
                               strip: Int? = nil) -> UUID? {
        guard Sane.isCoordinate(y), size.map(Sane.isSize) ?? true else { return nil }   // a position or size that isn't one
        if let strip, strip < 1 || strip > p.strips.count { return nil }                // no such gel
        if p.ladder == nil {
            var l = Ladder(lane: lane ?? 1)
            if let lane, let mid = gelCenterX, lane <= p.lanes.centers.count {
                l.side = p.lanes.centers[lane - 1] > mid ? .right : .left
            }
            p.ladder = l
        } else if let lane, p.ladder!.bands.isEmpty {
            p.ladder!.lane = lane
        }
        let band = LadderBand(y: y, size: size, auto: auto && size != nil, strip: strip)
        p.ladder!.bands.append(band)
        let q = p
        p.ladder!.bands.sort { q.stackKey($0.strip, $0.y) < q.stackKey($1.strip, $1.y) }
        return band.id
    }

    /// The size list in use: the project's own (edited) list, else the preset's.
    public static func ladderSizes(_ p: GelProject, preset: LadderPreset?) -> [Double] {
        p.ladder?.sizes ?? preset?.sizes ?? []
    }

    /// The size a new tick at `y` would get: the one whose rank matches the tick's rank from the top, counting only the
    /// ticks of its own ladder group (the gels that carry one ladder on from gel to gel) that are in the figure. A guess.
    public static func suggestedSize(_ p: GelProject, forY y: Double, strip: Int? = nil, preset: LadderPreset?) -> Double? {
        let sizes = ladderSizes(p, preset: preset)
        let group = p.ladderGroup(of: strip)
        let key = p.stackKey(strip, y - 0.5)
        let above = (p.ladder?.bands ?? []).filter {
            !$0.ignore && p.isInFigure(strip: $0.strip, y: $0.y) && p.ladderGroup(of: $0.strip) == group && p.stackKey($0.strip, $0.y) < key
        }.count
        return above < sizes.count ? sizes[above] : nil
    }

    /// Gives gel `strip` (nil = the one with the lanes) its own ladder, or has it carry on from the gel above again. When
    /// that changes how the gels are grouped, the ladder's sizes are re-assigned top-down, as Assign top-down does (a guess,
    /// marked auto), if the project has a ladder with a size list. `preset` supplies the list when the ladder has none yet.
    public static func setOwnLadder(_ p: inout GelProject, strip: Int?, _ own: Bool, preset: LadderPreset? = nil) {
        let groups = p.ladderGroups
        if let k = strip {
            guard k >= 1, k <= p.strips.count else { return }
            p.strips[k - 1].ownLadder = own
        } else {
            p.ownLadder = own
        }
        guard p.ladderGroups != groups else { return }   // the top gel starts its group either way
        let sizes = ladderSizes(p, preset: preset)
        if p.ladder != nil, !sizes.isEmpty { p.assignLadder(sizes: sizes) }
    }

    /// Places the unit label ("kDa") on row `y` of gel `strip` (nil = the one with the lanes), or back to the automatic
    /// place above the gel with nil. The label goes with that gel when gels are moved, and goes when that gel does.
    public static func setUnitY(_ p: inout GelProject, y: Double?, strip: Int?) {
        guard let y, y.isFinite else {
            p.ladder?.unitY = nil; p.ladder?.unitStrip = nil
            return
        }
        if p.ladder == nil { p.ladder = Ladder() }
        p.ladder!.unitY = y.rounded()
        p.ladder!.unitStrip = strip
    }

    /// Adopts a preset's size list and guesses sizes for the ticks top-down (marked auto).
    public static func applyPreset(_ p: inout GelProject, _ preset: LadderPreset) {
        if p.ladder == nil { p.ladder = Ladder() }
        p.ladder!.name = preset.displayName
        p.ladder!.unit = preset.unit
        let sys = preset.system(named: p.ladder!.system) ?? preset.systems.first
        let sizes = sys?.sizes ?? preset.sizes
        p.ladder!.sizes = sizes
        p.ladder!.system = sys?.name
        p.assignLadder(sizes: sizes)
    }

    /// Uses a gel system's apparent sizes. Ticks keep their protein: a tick holding the i-th size of the current
    /// list gets the i-th size of the new one (nil if that band runs off the new gel). Guess/confirmed flags stay.
    public static func applySystem(_ p: inout GelProject, preset: LadderPreset, system: LadderSystem) {
        if p.ladder == nil { p.ladder = Ladder() }
        let old = p.ladder!.sizes ?? preset.sizes
        for i in p.ladder!.bands.indices {
            guard let s = p.ladder!.bands[i].size, let k = old.firstIndex(of: s) else { continue }
            p.ladder!.bands[i].size = k < system.sizes.count ? system.sizes[k] : nil
        }
        p.ladder!.name = preset.displayName
        p.ladder!.unit = preset.unit
        p.ladder!.sizes = system.sizes
        p.ladder!.system = system.name
    }

    /// "250, 130 | 100 70" → [250, 130, 100, 70]; largest first.
    public static func parseSizes(_ text: String) -> [Double] {
        text.split(whereSeparator: { ",;| \t\n".contains($0) })
            .compactMap { Double($0.replacingOccurrences(of: "kDa", with: "").replacingOccurrences(of: "bp", with: "")) }
            .filter(Sane.isSize)
            .sorted(by: >)
    }

    // MARK: names

    public static func addAnnotation(_ p: inout GelProject, text: String, y: Double, marker: AnnotationMarker = .arrow,
                                     side: LadderSide? = nil) {
        guard Sane.isCoordinate(y) else { return }
        let s = side ?? (p.ladder?.side == .right ? .left : .right)
        p.annotations.append(BandAnnotation(y: y, text: text, marker: marker, side: s))
    }

    // MARK: measuring

    public struct MeasuredBand: Codable, Sendable {
        public var y: Double
        public var fwhm: Double
        public var prominence: Double
        public var apparentSize: Double?
        public var unit: String?
        public var extrapolated: Bool
    }

    /// Bands in one lane with apparent sizes from the ladder. On a tilted gel these are only as good as the tilt allows.
    public static func measureLane(_ p: GelProject, _ w: WorkingImage, lane: Int) -> [MeasuredBand] {
        guard let info = p.mainLaneInfo(lane) else { return [] }
        let dark = w.darkness(bandsDark: p.display.bandsDark)
        let cal = p.ladder.flatMap(Calibration.init)
        return Detect.bands(in: dark, center: info.x, width: info.width).map { b in
            let s = cal?.size(atY: b.y)
            return MeasuredBand(y: b.y, fwhm: b.fwhm, prominence: b.prominence,
                                apparentSize: s.map { ($0.size * 10).rounded() / 10 }, unit: p.ladder?.unit,
                                extrapolated: s?.extrapolated ?? false)
        }
    }

    // MARK: crop

    /// Lanes with a small margin across; top to bottom, stopping below the lowest labeled ladder band if there is one.
    public static func suggestCrop(_ p: GelProject, imageWidth: Int, imageHeight: Int) -> PixelRect {
        var r = PixelRect(x0: 0, y0: 0, x1: Double(imageWidth), y1: Double(imageHeight))
        if let g = geometry(p, imageWidth: imageWidth, imageHeight: imageHeight), g.count > 0 {
            let first = g.boundaries[0], last = g.boundaries[g.count]
            r.x0 = max(0, min(first.xTop, first.xBottom) - 6)
            r.x1 = min(Double(imageWidth), max(last.xTop, last.xBottom) + 6)
        }
        if let lowest = p.ladder?.bands.filter({ !$0.ignore && $0.size != nil && $0.strip == nil }).map(\.y).max() {
            let ys = (p.ladder?.bands ?? []).filter { $0.strip == nil }.map(\.y).sorted()
            let gaps = zip(ys.dropFirst(), ys).map { $0 - $1 }.sorted()
            let step = gaps.isEmpty ? 60 : gaps[gaps.count / 2]
            r.y1 = min(Double(imageHeight), lowest + max(40, step * 0.6))
        }
        return r.normalized(width: imageWidth, height: imageHeight)
    }
}

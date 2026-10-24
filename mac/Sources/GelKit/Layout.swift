import CoreGraphics
import CoreText
import Foundation

// One layout, many renderers: the on-screen canvas, PDF, PNG/TIFF and SVG all draw this structure,
// so the preview is the export.

public struct FontSpec: Sendable, Hashable {
    public var family: String
    public var size: Double
    public var bold: Bool
    public var italic: Bool
    public init(family: String, size: Double, bold: Bool = false, italic: Bool = false) {
        self.family = family; self.size = size; self.bold = bold; self.italic = italic
    }
}

public enum TextAlign: String, Sendable { case left, center, right }

/// What a piece of text is, so the editor can map a click back to the thing to edit.
public enum FigureRole: Sendable, Hashable {
    case title
    case rowName(row: Int)
    case laneLabel(row: Int, lane: Int)
    case groupLabel(row: Int, group: Int)
    case ladderLabel(band: Int)
    case ladderUnit
    case annotation(Int)
}

public struct FigureText: Sendable {
    public var string: String
    public var font: FontSpec
    /// Baseline anchor, points, y down.
    public var origin: CGPoint
    public var align: TextAlign
    /// Degrees, counter-clockwise on screen, about `origin`.
    public var rotation: Double
    public var role: FigureRole
    /// Axis-aligned bounds, y down.
    public var bounds: CGRect
    /// For text with line breaks: the distance between baselines, and where the first line's baseline sits relative
    /// to `origin` (y down; 0 for a single line).
    public var lineHeight: Double
    public var firstBaseline: Double

    public init(string: String, font: FontSpec, origin: CGPoint, align: TextAlign, rotation: Double, role: FigureRole, bounds: CGRect,
                lineHeight: Double = 0, firstBaseline: Double = 0) {
        self.string = string; self.font = font; self.origin = origin; self.align = align
        self.rotation = rotation; self.role = role; self.bounds = bounds
        self.lineHeight = lineHeight; self.firstBaseline = firstBaseline
    }

    /// The label's lines (a label gets a line break with ⌘↩ in its editor, or `\n` in Quick labels).
    public var lines: [String] { string.components(separatedBy: "\n") }
}

extension FigureText {
    /// The text's own box, ascent of its first line to descent of its last, as four corners in figure points: a rotated
    /// rectangle for rotated text (the axis-aligned `bounds` around it is bigger). What a click on the text is tested against.
    public var box: [CGPoint] {
        let (u0, u1, v0, v1) = boxExtent
        let t = rotation * .pi / 180
        return [(u0, v0), (u1, v0), (u1, v1), (u0, v1)].map { u, v in
            CGPoint(x: origin.x + u * cos(t) + v * sin(t), y: origin.y - u * sin(t) + v * cos(t))
        }
    }

    /// Whether `point` (figure points) is inside the text's own box, which for rotated text is the rotated rectangle.
    public func contains(_ point: CGPoint) -> Bool {
        let (u0, u1, v0, v1) = boxExtent
        let t = rotation * .pi / 180
        let dx = Double(point.x - origin.x), dy = Double(point.y - origin.y)
        let u = dx * cos(t) - dy * sin(t), v = dx * sin(t) + dy * cos(t)   // the point in the text's own frame
        return u >= u0 && u <= u1 && v >= v0 && v <= v1
    }

    /// The box in the text's own frame: x along the text from `origin`, y down from the baseline.
    private var boxExtent: (u0: Double, u1: Double, v0: Double, v1: Double) {
        let m = Typesetter.metrics(font)
        let ends = lines.map { line -> (Double, Double) in
            let w = Typesetter.width(line, font)
            let dx: Double = align == .left ? 0 : align == .center ? -w / 2 : -w
            return (dx, dx + w)
        }
        return (ends.map(\.0).min() ?? 0, ends.map(\.1).max() ?? 0, firstBaseline - m.ascent,
                firstBaseline + Double(lines.count - 1) * lineHeight + m.descent)
    }
}

/// Where a label of several lines sits on its baseline.
public enum TextAnchor: Sendable {
    /// The last line on the baseline, the others stacked above it: labels over the gel and the title.
    case bottom
    /// The block centred on the baseline's line: names and the unit label beside the gel.
    case middle
}

public struct FigureLine: Sendable {
    public var points: [CGPoint]
    public var width: Double
}

public struct FigureLayout: Sendable {
    public var size: CGSize
    /// Where the cropped gel image goes, points, y down.
    public var gelRect: CGRect
    public var crop: PixelRect
    /// Points per gel pixel.
    public var ptPerPx: Double
    public var texts: [FigureText] = []
    public var lines: [FigureLine] = []
    /// Filled polygons (arrowheads).
    public var fills: [[CGPoint]] = []
    public var borderWidth: Double?

    /// Gel pixel → figure point.
    public func point(x: Double, y: Double) -> CGPoint {
        CGPoint(x: gelRect.minX + (x - crop.x0) * ptPerPx, y: gelRect.minY + (y - crop.y0) * ptPerPx)
    }
    /// Figure point → gel pixel.
    public func pixel(_ p: CGPoint) -> (x: Double, y: Double) {
        ((p.x - gelRect.minX) / ptPerPx + crop.x0, (p.y - gelRect.minY) / ptPerPx + crop.y0)
    }
}

// MARK: - Typesetting

public enum Typesetter {
    public static func font(_ f: FontSpec) -> CTFont {
        var traits: UInt32 = 0
        if f.bold { traits |= CTFontSymbolicTraits.traitBold.rawValue }
        if f.italic { traits |= CTFontSymbolicTraits.traitItalic.rawValue }
        let attrs: [CFString: Any] = [
            kCTFontFamilyNameAttribute: f.family,
            kCTFontTraitsAttribute: [kCTFontSymbolicTrait: traits],
        ]
        let desc = CTFontDescriptorCreateWithAttributes(attrs as CFDictionary)
        return CTFontCreateWithFontDescriptor(desc, f.size, nil)
    }

    public static func line(_ s: String, _ f: FontSpec) -> CTLine {
        let attrs: [CFString: Any] = [kCTFontAttributeName: font(f), kCTForegroundColorFromContextAttributeName: true]
        return CTLineCreateWithAttributedString(CFAttributedStringCreate(nil, s as CFString, attrs as CFDictionary))
    }

    public static func width(_ s: String, _ f: FontSpec) -> Double {
        CTLineGetTypographicBounds(line(s, f), nil, nil, nil)
    }

    public struct Metrics: Sendable { public var ascent: Double, descent: Double, capHeight: Double, leading: Double }

    public static func metrics(_ f: FontSpec) -> Metrics {
        let ct = font(f)
        return Metrics(ascent: CTFontGetAscent(ct), descent: CTFontGetDescent(ct), capHeight: CTFontGetCapHeight(ct),
                       leading: CTFontGetLeading(ct))
    }

    /// Baseline to baseline within one label.
    public static func lineHeight(_ f: FontSpec) -> Double {
        let m = metrics(f)
        return m.ascent + m.descent + max(m.leading, 0.03 * f.size)
    }
}

// MARK: - Engine

public enum FigureLayoutEngine {
    /// `stack`: where the strips go, for a project with strips (see `StackGeometry`); their ticks and names are left
    /// out without it.
    public static func layout(_ p: GelProject, imageWidth: Int, imageHeight: Int, stack: StackGeometry? = nil) -> FigureLayout {
        let st = p.style
        let crop = stack?.crop ?? p.effectiveCrop(width: imageWidth, height: imageHeight)
        /// Figure row of a mark at `y` in its own piece, if it's in the figure.
        func figureY(_ strip: Int?, _ y: Double) -> Double? {
            guard y.isFinite else { return nil }
            if let stack { return stack.figureY(strip: strip, y: y) }
            return strip == nil && y >= crop.y0 && y <= crop.y1 ? y : nil
        }
        func nameY(_ strip: Int?, _ y: Double) -> Double? {
            guard y.isFinite else { return nil }
            if let stack { return stack.nameY(strip: strip, y: y) }
            return strip == nil ? y : nil
        }
        let gelW = st.gelWidthIn * 72
        let s = gelW / max(crop.width, 1)
        let gelH = crop.height * s
        let lw = st.lineWidthPt

        var texts: [FigureText] = []
        var lines: [FigureLine] = []
        var fills: [[CGPoint]] = []

        func X(_ px: Double) -> Double { (px - crop.x0) * s }
        func Y(_ py: Double) -> Double { (py - crop.y0) * s }
        let centers = p.lanes.centers
        // side by side: one row of lanes across every gel, numbered from the left
        let across = stack?.sideBySide == true ? stack.map { p.figureLanes(stack: $0) } : nil
        func laneX(_ n: Int) -> Double? {
            if let across { return n >= 1 && n <= across.centers.count ? across.centers[n - 1].map(X) : nil }
            guard n >= 1, n <= centers.count else { return nil }
            let c = centers[n - 1]
            return (c >= crop.x0 && c <= crop.x1) ? X(c) : nil
        }
        let laneHalf = (across?.width ?? p.lanes.width) * s / 2

        func text(_ str: String, _ f: FontSpec, at o: CGPoint, align: TextAlign, rotation: Double = 0,
                  role: FigureRole, anchor: TextAnchor = .bottom) -> FigureText {
            let lines = str.components(separatedBy: "\n")
            let m = Typesetter.metrics(f)
            let lh = Typesetter.lineHeight(f)
            let first = -Double(lines.count - 1) * lh * (anchor == .bottom ? 1 : 0.5)
            // local (y-down) box of every line relative to origin, then rotate CCW on screen
            var corners: [CGPoint] = []
            for (k, line) in lines.enumerated() {
                let w = Typesetter.width(line, f)
                let dx: Double = align == .left ? 0 : align == .center ? -w / 2 : -w
                let base = first + Double(k) * lh
                corners += [CGPoint(x: dx, y: base - m.ascent), CGPoint(x: dx + w, y: base - m.ascent),
                            CGPoint(x: dx, y: base + m.descent), CGPoint(x: dx + w, y: base + m.descent)]
            }
            let t = rotation * .pi / 180
            let pts = corners.map { c in
                CGPoint(x: o.x + c.x * cos(t) + c.y * sin(t), y: o.y - c.x * sin(t) + c.y * cos(t))
            }
            let xs = pts.map(\.x), ys = pts.map(\.y)
            let b = CGRect(x: xs.min()!, y: ys.min()!, width: xs.max()! - xs.min()!, height: ys.max()! - ys.min()!)
            return FigureText(string: str, font: f, origin: o, align: align, rotation: rotation, role: role, bounds: b,
                              lineHeight: lh, firstBaseline: first)
        }

        // --- label rows, stacked upward from the gel's top edge
        var yAbove = 2.0
        for (ri, row) in p.rows.enumerated() {
            let kind: TextKind = row.type == .groups ? .groupLabel : .laneLabel
            func font(_ role: FigureRole) -> FontSpec { FontSpec(family: st.font, size: st.size(for: role), bold: row.bold) }
            // the row is as tall as its biggest label; every label sits on the same baseline
            let roles: [FigureRole] = row.type == .lanes
                ? row.labels.indices.filter { !row.labels[$0].isEmpty }.map { .laneLabel(row: ri, lane: $0 + 1) }
                : row.groups.indices.map { .groupLabel(row: ri, group: $0) }
            let sizes = roles.map { st.size(for: $0) }
            let big = FontSpec(family: st.font, size: sizes.max() ?? st.size(for: kind), bold: row.bold)
            let m = Typesetter.metrics(big)
            var rowTexts: [FigureText] = []
            var rowHeight = m.ascent + m.descent
            var textBaseline = -(yAbove + m.descent)
            var leftmost = Double.infinity
            // lane labels and group labels may stand at an angle; row titles, names and ladder sizes stay horizontal
            let angle = LabelRow.clampedAngle(row.rotation)
            let t = angle * .pi / 180, sn = sin(t), cs = cos(t)
            /// A label standing at `angle` (not 0), over `x`. Any angle. The end of its middle line (half a cap height above the
            /// baseline) nearest the gel sits over `x`: the start while the text rises (under 180°), the end while it falls (over
            /// 180°), the middle when it's level (180°). Lines of a longer label stack along the text's own "down" direction,
            /// the block centred on that line. The label then goes up or down so its lowest point is exactly on `bottom`, where
            /// horizontal labels' descenders end, so the gap above the gel (or above a group's underline) is the usual one.
            func turned(_ lab: String, _ f: FontSpec, over x: Double, bottom: Double, role: FigureRole) -> FigureText {
                let halfCap = Typesetter.metrics(f).capHeight / 2
                let w = lab.components(separatedBy: "\n").map { Typesetter.width($0, f) }.max() ?? 0
                let along = sn > 1e-9 ? 0 : sn < -1e-9 ? w : w / 2
                // the middle line's point `along` the text: O + along (cos t, -sin t) - (c/2)(sin t, cos t), over x
                let ox = x - along * cs + halfCap * sn
                let probe = text(lab, f, at: CGPoint(x: ox, y: 0), align: .left, rotation: angle, role: role, anchor: .middle)
                return text(lab, f, at: CGPoint(x: ox, y: bottom - probe.bounds.maxY), align: .left, rotation: angle, role: role, anchor: .middle)
            }

            switch row.type {
            case .lanes:
                if angle != 0 {
                    // The row reaches up to its highest rotated corner, so the rows above keep their usual gap above that point.
                    var highest = 0.0   // how far the highest corner is above the line horizontal descenders end on
                    for (i, lab) in row.labels.enumerated() where !lab.isEmpty {
                        guard let x = laneX(i + 1) else { continue }
                        let role = FigureRole.laneLabel(row: ri, lane: i + 1)
                        let tx = turned(lab, font(role), over: x, bottom: -yAbove, role: role)
                        rowTexts.append(tx)
                        highest = max(highest, -yAbove - tx.bounds.minY)
                        leftmost = min(leftmost, tx.bounds.minX)
                    }
                    if !rowTexts.isEmpty { rowHeight = highest }
                } else {
                    for (i, lab) in row.labels.enumerated() where !lab.isEmpty {
                        guard let x = laneX(i + 1) else { continue }
                        let role = FigureRole.laneLabel(row: ri, lane: i + 1)
                        let tx = text(lab, font(role), at: CGPoint(x: x, y: textBaseline), align: .center, role: role)
                        rowTexts.append(tx)
                        leftmost = min(leftmost, tx.bounds.minX)
                    }
                }
            case .groups:
                let rise = row.underline ? 2.5 : 0
                textBaseline = -(yAbove + rise + m.descent)
                rowHeight += rise
                var highest = 0.0   // as for lane labels
                for (gi, g) in row.groups.enumerated() {
                    guard let lo = laneX(g.first), let hi = laneX(g.last) else { continue }
                    if row.underline {   // flat under the span, whatever the angle of the text
                        let inset = laneHalf * (1 - 2 * st.groupLineInset)
                        let ly = -(yAbove + 1.2)
                        lines.append(FigureLine(points: [CGPoint(x: lo - inset, y: ly), CGPoint(x: hi + inset, y: ly)], width: lw))
                        leftmost = min(leftmost, lo - inset)
                    }
                    if !g.text.isEmpty {
                        let role = FigureRole.groupLabel(row: ri, group: gi)
                        if angle != 0 {
                            // the same rules as turned lane labels, over the middle of the span, the lowest point where horizontal
                            // text would end: above the underline, with the usual gap
                            let tx = turned(g.text, font(role), over: (lo + hi) / 2, bottom: -(yAbove + rise), role: role)
                            rowTexts.append(tx)
                            highest = max(highest, -yAbove - tx.bounds.minY)
                            leftmost = min(leftmost, tx.bounds.minX)
                        } else {
                            let tx = text(g.text, font(role), at: CGPoint(x: (lo + hi) / 2, y: textBaseline), align: .center, role: role)
                            rowTexts.append(tx)
                            leftmost = min(leftmost, tx.bounds.minX)
                        }
                    }
                }
                if angle != 0, !rowTexts.isEmpty { rowHeight = highest }
            }
            if angle == 0 {
                rowHeight += rowTexts.map { Double($0.lines.count - 1) * $0.lineHeight }.max() ?? 0
            }
            if let name = row.name, !name.isEmpty {
                // the title stays horizontal, left of the row's leftmost point, on the baseline horizontal labels would have
                let right = leftmost.isFinite ? leftmost - 3.5 : -3.5
                let nb = textBaseline
                let nf = FontSpec(family: st.font, size: st.size(for: FigureRole.rowName(row: ri)))
                let nameLines = Double(name.components(separatedBy: "\n").count - 1)
                rowHeight = max(rowHeight, Typesetter.metrics(nf).ascent + m.descent + nameLines * Typesetter.lineHeight(nf))
                rowTexts.append(text(name, nf, at: CGPoint(x: right, y: nb), align: .right, role: .rowName(row: ri)))
            }
            texts += rowTexts
            yAbove += rowHeight + st.rowGapPt
        }

        if let title = p.title, !title.isEmpty {
            let f = FontSpec(family: st.font, size: st.titleSize, bold: true)
            let m = Typesetter.metrics(f)
            texts.append(text(title, f, at: CGPoint(x: gelW / 2, y: -(yAbove + 2 + m.descent)), align: .center, role: .title))
        }

        // --- ladder ticks; crowded labels spread apart and joined to their tick by a leader
        var ladderColumnWidth = 0.0
        if let ladder = p.ladder {
            let f = FontSpec(family: st.font, size: st.size(for: .ladder))
            let m = Typesetter.metrics(f)
            let tl = st.tickLenPt
            let right = ladder.side == .right
            let edge = right ? gelW : 0
            let dir: Double = right ? 1 : -1
            let marks = ladder.bands.enumerated()
                .compactMap { e -> (offset: Int, element: LadderBand, fy: Double)? in
                    guard !e.element.ignore, e.element.size != nil, p.isLadderLabelGel(e.element.strip), let fy = figureY(e.element.strip, e.element.y) else { return nil }
                    return (e.offset, e.element, fy)
                }
                .sorted { $0.fy < $1.fy }
            let bandY = marks.map { Y($0.fy) }
            let labelY = spread1D(bandY, sep: f.size * st.labelSep)
            let moved = zip(bandY, labelY).contains { abs($0 - $1) > 0.3 }
            let conn = moved ? st.leaderPt : 0
            let tx = edge + dir * (tl + conn + 1.5)
            for (k, (i, band, _)) in marks.enumerated() {
                lines.append(FigureLine(points: [CGPoint(x: edge, y: bandY[k]), CGPoint(x: edge + dir * tl, y: bandY[k])], width: lw))
                if conn > 0 {
                    lines.append(FigureLine(points: [CGPoint(x: edge + dir * tl, y: bandY[k]),
                                                     CGPoint(x: edge + dir * (tl + conn), y: labelY[k])], width: lw))
                }
                let t = text(formatSize(band.size!), f, at: CGPoint(x: tx, y: labelY[k] + m.capHeight / 2),
                             align: right ? .left : .right, role: .ladderLabel(band: i))
                ladderColumnWidth = max(ladderColumnWidth, t.bounds.width + tl + conn + 1.5)
                texts.append(t)
            }
            if !marks.isEmpty {
                // where the user put it (centered on that row of its gel, like the numbers), else heading the column; a
                // placement on a gel that isn't in the figure (or a row it doesn't show) goes back to the heading
                let placed = ladder.unitY.flatMap { figureY(ladder.unitStrip, $0) }
                let y = placed.map { Y($0) + m.capHeight / 2 } ?? -(2 + m.descent)
                texts.append(text(ladder.unit, f, at: CGPoint(x: tx, y: y), align: right ? .left : .right, role: .ladderUnit,
                                  anchor: placed == nil ? .bottom : .middle))
            }
        }

        // --- band annotations at the edge (protein names); markers at the true y, text spread if crowded
        for side in LadderSide.allCases {
            // each name at its figure row (a strip's names converted from the strip's own pixels)
            let items = p.annotations.enumerated().compactMap { e -> (offset: Int, element: BandAnnotation)? in
                guard e.element.side == side, !e.element.text.isEmpty, let fy = nameY(e.element.strip, e.element.y) else { return nil }
                var a = e.element
                a.y = fy
                if let y2 = a.y2 { a.y2 = nameY(a.strip, y2) ?? fy }
                return (e.offset, a)
            }
                .sorted { $0.element.y < $1.element.y }
            guard !items.isEmpty else { continue }
            let right = side == .right
            let dir: Double = right ? 1 : -1
            let sharesLadderSide = p.ladder?.side == side && ladderColumnWidth > 0
            let edge = (right ? gelW : 0) + dir * (sharesLadderSide ? ladderColumnWidth + 4 : 0)
            let nameSize = st.size(for: .name)
            let fBase = FontSpec(family: st.font, size: nameSize)
            let cap = Typesetter.metrics(fBase).capHeight
            let anchorY = items.map { a -> Double in
                let e = a.element
                return e.marker == .bracket && e.y2 != nil ? Y((e.y + e.y2!) / 2) : Y(e.y)
            }
            // names of several lines need more room from their neighbours
            let lineCounts = items.map { $0.element.text.components(separatedBy: "\n").count }
            let textY: [Double]
            if lineCounts.allSatisfy({ $0 == 1 }) {
                textY = spread1D(anchorY, sep: nameSize * st.labelSep)
            } else {
                let lh = Typesetter.lineHeight(fBase)
                textY = spread1D(anchorY, gaps: zip(lineCounts, lineCounts.dropFirst()).map {
                    nameSize * st.labelSep + Double($0 + $1 - 2) * lh / 2
                })
            }
            for (k, (i, a)) in items.enumerated() {
                let y = Y(a.y)
                var end: Double      // outer end of the marker
                switch a.marker {
                case .arrow:
                    let tip = edge + dir * 1, hl = 0.5 * nameSize, hw = 0.22 * nameSize
                    fills.append([CGPoint(x: tip, y: y), CGPoint(x: tip + dir * hl, y: y - hw), CGPoint(x: tip + dir * hl, y: y + hw)])
                    end = edge + dir * 8
                    lines.append(FigureLine(points: [CGPoint(x: tip + dir * hl * 0.8, y: y), CGPoint(x: end, y: y)], width: lw))
                case .tick:
                    end = edge + dir * st.tickLenPt
                    lines.append(FigureLine(points: [CGPoint(x: edge, y: y), CGPoint(x: end, y: y)], width: lw))
                case .bracket:
                    let y2 = Y(a.y2 ?? a.y)
                    let bx = edge + dir * 3
                    lines.append(FigureLine(points: [CGPoint(x: edge, y: y), CGPoint(x: bx, y: y), CGPoint(x: bx, y: y2),
                                                     CGPoint(x: edge, y: y2)], width: lw))
                    end = bx
                case .none:
                    end = edge
                }
                var start = end + dir * 1.5
                if abs(textY[k] - anchorY[k]) > 0.3 {   // leader to a displaced label
                    lines.append(FigureLine(points: [CGPoint(x: end, y: anchorY[k]), CGPoint(x: end + dir * 2.5, y: textY[k])], width: lw))
                    start = end + dir * 4
                }
                let f = FontSpec(family: st.font, size: st.size(for: FigureRole.annotation(i)), bold: a.bold, italic: a.italic)
                texts.append(text(a.text, f, at: CGPoint(x: start, y: textY[k] + cap / 2), align: right ? .left : .right,
                                  role: .annotation(i), anchor: .middle))
            }
        }

        // --- bounding box, then shift so the gel origin lands on the gel's own pixel grid (exact raster export)
        var bbox = CGRect(x: 0, y: 0, width: gelW, height: gelH)
        for t in texts { bbox = bbox.union(t.bounds) }
        for l in lines { for pt in l.points { bbox = bbox.union(CGRect(origin: pt, size: .zero).insetBy(dx: -lw, dy: -lw)) } }
        for poly in fills { for pt in poly { bbox = bbox.union(CGRect(origin: pt, size: .zero)) } }
        let margin = 2.2
        let tx = ((margin - bbox.minX) / s).rounded(.up) * s
        let ty = ((margin - bbox.minY) / s).rounded(.up) * s
        func shift(_ pt: CGPoint) -> CGPoint { CGPoint(x: pt.x + tx, y: pt.y + ty) }
        texts = texts.map { var t = $0; t.origin = shift(t.origin); t.bounds = t.bounds.offsetBy(dx: tx, dy: ty); return t }
        lines = lines.map { FigureLine(points: $0.points.map(shift), width: $0.width) }
        fills = fills.map { $0.map(shift) }
        // page size in whole gel pixels too
        let pw = ((bbox.maxX + tx + margin) / s).rounded(.up) * s
        let ph = ((bbox.maxY + ty + margin) / s).rounded(.up) * s

        var out = FigureLayout(size: CGSize(width: pw, height: ph), gelRect: CGRect(x: tx, y: ty, width: gelW, height: gelH),
                               crop: crop, ptPerPx: s)
        out.texts = texts
        out.lines = lines
        out.fills = fills
        out.borderWidth = st.border ? lw : nil
        return out
    }

    public static func formatSize(_ v: Double) -> String {
        v == v.rounded() && abs(v) < 1e15 ? String(Int(v)) : String(format: "%g", v)   // never traps, whatever the number
    }

    /// Like `spread1D(_:sep:)`, with its own minimum distance between each neighbouring pair (`gaps[i]` between
    /// targets i and i + 1), for labels of different heights.
    public static func spread1D(_ targets: [Double], gaps: [Double]) -> [Double] {
        var offset = [Double](repeating: 0, count: targets.count)   // from the first item of its cluster
        var clusters: [(first: Int, last: Int, start: Double)] = []
        for i in targets.indices {
            clusters.append((i, i, targets[i]))
            while clusters.count > 1 {
                let b = clusters[clusters.count - 1], a = clusters[clusters.count - 2]
                guard a.start + offset[a.last] + gaps[a.last] > b.start else { break }
                let base = offset[a.last] + gaps[a.last]
                for k in b.first...b.last { offset[k] += base }
                clusters.removeLast(2)
                let mean = (a.first...b.last).reduce(0.0) { $0 + targets[$1] - offset[$1] } / Double(b.last - a.first + 1)
                clusters.append((a.first, b.last, mean))
            }
        }
        var out = [Double](repeating: 0, count: targets.count)
        for c in clusters { for k in c.first...c.last { out[k] = c.start + offset[k] } }
        return out
    }

    /// Positions ≥ `sep` apart, order kept, each cluster centred on its targets (minimal total displacement).
    public static func spread1D(_ targets: [Double], sep: Double) -> [Double] {
        var clusters: [(start: Double, n: Int, acc: Double)] = []
        for t in targets {
            clusters.append((t, 1, t))
            while clusters.count > 1, clusters[clusters.count - 2].start + Double(clusters[clusters.count - 2].n) * sep > clusters[clusters.count - 1].start {
                let b = clusters.removeLast(), a = clusters.removeLast()
                let acc = a.acc + b.acc - Double(b.n * a.n) * sep
                let n = a.n + b.n
                clusters.append((acc / Double(n), n, acc))
            }
        }
        return clusters.flatMap { c in (0..<c.n).map { c.start + Double($0) * sep } }
    }
}

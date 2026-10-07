import Foundation

/// The naming scheme of a figure — everything that isn't tied to one image — so it can be reused on the next gel:
/// label rows, row titles, title, band names, ladder settings (preset, gel system, size list, side, unit) and type.
/// With `positions`, also the image-specific geometry (lane dividers, crop, tick and name positions), for gels
/// scanned with the same framing.
///
/// A scheme carries the marks of the gel with the lanes only. Ticks and names on the other (stacked) gels belong to
/// those gels, which another project doesn't have, and the figure's export resolution belongs to the project it was set
/// on, so neither travels.
public struct LabelScheme: Codable, Sendable, Equatable {
    public static let pasteboardType = "local.gelscribe.scheme"

    public var rows: [LabelRow]
    public var title: String?
    public var annotations: [BandAnnotation]
    public var ladder: Ladder?
    public var style: FigureStyle
    public var lanes: Lanes?
    public var crop: PixelRect?

    public var hasPositions: Bool { lanes != nil }

    public init(from p: GelProject, positions: Bool) {
        rows = p.rows
        title = p.title
        let keep = p.annotations.indices.filter { p.annotations[$0].strip == nil }
        annotations = keep.map { p.annotations[$0] }
        style = p.style
        if keep.count != p.annotations.count { style.remapNameSizes(oldIndex: keep) }   // sizes go with the names that stay
        style.exportDPI = nil
        if var l = p.ladder {
            // ticks and a placed unit label belong to one image; keep them only with positions, and only the gel's with the lanes
            l.bands = positions ? l.bands.filter { $0.strip == nil } : []
            if !positions || l.unitStrip != nil { l.unitY = nil; l.unitStrip = nil }
            ladder = l
        }
        lanes = positions ? p.lanes : nil
        crop = positions ? p.crop : nil
    }

    /// Replaces the naming scheme of `p`. Its image, strict setting, pixel adjustments and export resolution are never
    /// touched, and neither are the ticks and names on its other gels.
    public func apply(to p: inout GelProject, imageWidth: Int, imageHeight: Int) {
        p.rows = rows
        p.title = title
        // names: the scheme's (the gel with the lanes') then this project's own on its other gels, each keeping its size
        let own = annotations.filter { $0.strip == nil }
        var sizes = style
        sizes.remapNameSizes(oldIndex: annotations.indices.filter { annotations[$0].strip == nil })
        let others = p.annotations.indices.filter { p.annotations[$0].strip != nil }
        for (j, old) in others.enumerated() {
            if let v = p.style.textSizes["name.\(old)"] { sizes.textSizes["name.\(own.count + j)"] = v }
        }
        sizes.exportDPI = p.style.exportDPI
        p.annotations = own + others.map { p.annotations[$0] }
        p.style = sizes
        if var l = ladder {
            let mine = p.ladder?.bands ?? []
            // this gel's own ticks stay unless the scheme brings positions; the other gels' ticks always stay
            let carried = l.bands.filter { $0.strip == nil }
            l.bands = (carried.isEmpty ? mine.filter { $0.strip == nil } : carried) + mine.filter { $0.strip != nil }
            // a unit label the scheme places (on the gel with the lanes) wins, else this project's own placement stays
            if l.unitY == nil || l.unitStrip != nil { l.unitY = p.ladder?.unitY; l.unitStrip = p.ladder?.unitStrip }
            p.ladder = l
            let q = p
            p.ladder!.bands.sort { q.stackKey($0.strip, $0.y) < q.stackKey($1.strip, $1.y) }
        }
        if let lanes { p.lanes = lanes }
        if let crop { p.crop = crop.normalized(width: imageWidth, height: imageHeight) }
        p.syncLaneCenters(imageWidth: imageWidth, imageHeight: imageHeight)
    }

    enum CodingKeys: String, CodingKey { case rows, title, annotations, ladder, style, lanes, crop }

    /// Reads a scheme the way a project is read: numbers that aren't sane are put right, and marks that name a gel (this
    /// scheme has none to name) are dropped.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        rows = try c.decodeIfPresent([LabelRow].self, forKey: .rows) ?? []
        title = try c.decodeIfPresent(String.self, forKey: .title)
        annotations = try c.decodeIfPresent([BandAnnotation].self, forKey: .annotations) ?? []
        ladder = try c.decodeIfPresent(Ladder.self, forKey: .ladder)
        style = try c.decodeIfPresent(FigureStyle.self, forKey: .style) ?? .init()
        lanes = try c.decodeIfPresent(Lanes.self, forKey: .lanes)
        crop = try c.decodeIfPresent(PixelRect.self, forKey: .crop)
        sanitize()
    }

    mutating func sanitize() {
        if rows.count > Sane.rows { rows = Array(rows.prefix(Sane.rows)) }
        for i in rows.indices { rows[i].sanitize() }
        var kept: [Int] = []
        let before = annotations.count
        annotations = annotations.enumerated().compactMap { i, a in
            guard let ok = a.sanitized(strips: 0) else { return nil }   // no gels here: any gel number is dropped
            kept.append(i)
            return ok
        }
        style.sanitize()
        if kept.count != before { style.remapNameSizes(oldIndex: kept) }
        style.exportDPI = nil
        ladder?.sanitize(strips: 0)
        lanes?.sanitize()
        if let c = crop, !(Sane.isCoordinate(c.x0) && Sane.isCoordinate(c.y0) && Sane.isCoordinate(c.x1) && Sane.isCoordinate(c.y1)) {
            crop = nil
        }
    }

    public func encoded() throws -> Data { try GelProject.encoder().encode(self) }
    public static func decode(_ data: Data) throws -> LabelScheme { try GelProject.decoder().decode(LabelScheme.self, from: data) }
}

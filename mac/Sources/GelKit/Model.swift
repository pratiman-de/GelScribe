import Foundation

/// One labeled gel figure. Stored as `project.json` inside a `.gelscribe` package, next to an untouched copy
/// of the original image. Keys match `gel_labeling/label_gel.py` configs, so either tool can read the other's.
///
/// Every coordinate (lane centers, band y, crop) is in pixels of the *working image*: the original after
/// padding fill and rotation. Rotation keeps the canvas size, so coordinates stay put when the angle changes.
///
/// **Strict mode** (the default) guarantees the figure carries the original pixels untouched: same values, bit depth
/// and color space, never resampled. Rotation, levels/gamma/invert and padding fill are then ignored for output;
/// cropping is allowed because it only selects pixels. Detection still masks padding internally — that never
/// reaches the figure.
public struct GelProject: Codable, Equatable, Sendable {
    public var image: String
    /// SHA-256 (hex) of the original image file, recorded on import so its integrity can be checked later.
    public var imageSHA256: String?
    public var strict: Bool
    public var title: String?
    public var crop: PixelRect?
    public var fillPadding: Bool
    /// Quarter turns clockwise (0…3) before anything else, for a scan made the wrong way round. Lossless: it only
    /// reorders pixels, so Strict allows it.
    public var turn: Int = 0
    public var rotateDeg: Double
    /// What rotation corners (and, with `fillPadding`, the old flat wedges) are painted with. Non-strict only.
    public var fillMode: FillMode
    /// Gray level 0…1 for `.custom`.
    public var fillValue: Double
    /// "Enhance view" was on: a screen-only contrast stretch, remembered with the project, never in exports.
    public var viewEnhance: Bool = false
    public var display: DisplaySettings
    public var lanes: Lanes
    /// Label rows listed from the gel upward (index 0 sits directly on the gel).
    public var rows: [LabelRow]
    public var ladder: Ladder?
    /// Named bands marked at the gel edge (protein names, "dimer", smears…), usually on the right.
    public var annotations: [BandAnnotation]
    public var style: FigureStyle
    /// More gels in the same figure, each scanned on its own (the pieces of a cut membrane, or the same samples on
    /// another gel), stacked top to bottom in this order with a line between each. This image's lanes and labels are
    /// shared; each of these has its own pixels, ticks and names.
    public var strips: [GelStrip] = []
    /// How the gels sit in the figure: stacked top to bottom (the default, left out of the file) or side by side, left to right in
    /// stack order (JSON `"arrangement": "side_by_side"`), each gel with its own lanes and a vertical placement against the gel
    /// with the lanes (`GelStrip.shift` and `scale` then act vertically). See `isSideBySide`.
    public var arrangement: Arrangement = .topToBottom
    /// Where this image, the gel whose lanes every gel shares, sits among `strips`, counted from the top: 0 = above
    /// all of them.
    public var mainPosition: Int = 0
    /// Where the gel with the lanes sits sideways in the figure, said the way a stacked gel's `shift` says where it does: the
    /// figure's column x shows this gel's column x + `mainShift`, so a positive number moves the gel to the left. Its lane dividers,
    /// lane labels, ticks and names go with it, and no other gel moves when it does (their own `shift` is a place in the figure
    /// too). Whole pixels (`effectiveMainShift`). 0, which is left out of the file, is where the gel was before it could move.
    public var mainShift: Double = 0
    /// This image's ladder sizes start again from the top of the list instead of carrying on from the gel above (see
    /// `ladderGroups`). The top gel always starts one, so this only matters when it isn't the top gel.
    public var ownLadder: Bool = false
    /// The colour of the line between stacked gels: black, white, or any #RRGGBB (JSON `"separator"`: `"white"` or `"#ff3300"`,
    /// left out for black).
    public var separatorColor: SeparatorColor = .black
    /// Black or white: the line between stacked gels is white instead of black.
    public var separatorWhite: Bool {
        get { separatorColor == .white }
        set { separatorColor = newValue ? .white : .black }
    }
    /// How thick the line between stacked gels is, in points (0.25 to 10; JSON `"separator_width"`). Left out, it is as thick as
    /// the figure's other lines (`style.lineWidthPt`) and follows them.
    public var separatorWidth: Double?
    public static let separatorWidths = 0.25...10.0
    /// Whether exported files and the Export tab's note carry each gel's file name (JSON `"export_file_names"`, left out when
    /// true). File names can identify samples or people; the SHA-256 fingerprints stay either way.
    public var exportFileNames = true
    /// How thick the line between stacked gels is, in points: its own width when it has one, else the figure's line width.
    public var effectiveSeparatorWidth: Double {
        separatorWidth.flatMap { $0.isFinite ? min(max($0, Self.separatorWidths.lowerBound), Self.separatorWidths.upperBound) : nil }
            ?? style.lineWidthPt
    }

    public init(image: String = "", imageSHA256: String? = nil, strict: Bool = true, title: String? = nil,
                crop: PixelRect? = nil, fillPadding: Bool = true,
                rotateDeg: Double = 0, fillMode: FillMode = .background, fillValue: Double = 0.9,
                display: DisplaySettings = .init(), lanes: Lanes = .init(),
                rows: [LabelRow] = [], ladder: Ladder? = nil, annotations: [BandAnnotation] = [],
                style: FigureStyle = .init()) {
        self.image = image
        self.imageSHA256 = imageSHA256
        self.strict = strict
        self.title = title
        self.crop = crop
        self.fillPadding = fillPadding
        self.rotateDeg = rotateDeg
        self.fillMode = fillMode
        self.fillValue = fillValue
        self.display = display
        self.lanes = lanes
        self.rows = rows
        self.ladder = ladder
        self.annotations = annotations
        self.style = style
    }

    enum CodingKeys: String, CodingKey {
        case image, strict, title, crop, display, lanes, rows, ladder, annotations, style
        case imageSHA256 = "image_sha256"
        case fillPadding = "fill_padding"
        case rotateDeg = "rotate_deg"
        case fillMode = "fill_mode", fillValue = "fill_value", viewEnhance = "view_enhance"
        case turn, strips, arrangement
        case mainPosition = "main_position", mainShift = "main_shift", ownLadder = "own_ladder"
        case separator
        case separatorWidth = "separator_width"
        case exportFileNames = "export_file_names"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        image = try c.decodeIfPresent(String.self, forKey: .image) ?? ""
        imageSHA256 = try c.decodeIfPresent(String.self, forKey: .imageSHA256)
        strict = try c.decodeIfPresent(Bool.self, forKey: .strict) ?? true
        title = try c.decodeIfPresent(String.self, forKey: .title)
        crop = try c.decodeIfPresent(PixelRect.self, forKey: .crop)
        fillPadding = try c.decodeIfPresent(Bool.self, forKey: .fillPadding) ?? true
        rotateDeg = try c.decodeIfPresent(Double.self, forKey: .rotateDeg) ?? 0
        fillMode = try c.decodeIfPresent(FillMode.self, forKey: .fillMode) ?? .background
        fillValue = try c.decodeIfPresent(Double.self, forKey: .fillValue) ?? 0.9
        viewEnhance = try c.decodeIfPresent(Bool.self, forKey: .viewEnhance) ?? false
        display = try c.decodeIfPresent(DisplaySettings.self, forKey: .display) ?? .init()
        lanes = try c.decodeIfPresent(Lanes.self, forKey: .lanes) ?? .init()
        rows = try c.decodeIfPresent([LabelRow].self, forKey: .rows) ?? []
        ladder = try c.decodeIfPresent(Ladder.self, forKey: .ladder)
        annotations = try c.decodeIfPresent([BandAnnotation].self, forKey: .annotations) ?? []
        style = try c.decodeIfPresent(FigureStyle.self, forKey: .style) ?? .init()
        turn = ((try c.decodeIfPresent(Int.self, forKey: .turn) ?? 0) % 4 + 4) % 4
        strips = try c.decodeIfPresent([GelStrip].self, forKey: .strips) ?? []
        arrangement = (try? c.decodeIfPresent(Arrangement.self, forKey: .arrangement)) ?? .topToBottom
        mainPosition = try c.decodeIfPresent(Int.self, forKey: .mainPosition) ?? 0
        mainShift = try c.decodeIfPresent(Double.self, forKey: .mainShift) ?? 0
        ownLadder = try c.decodeIfPresent(Bool.self, forKey: .ownLadder) ?? false
        separatorColor = (try? c.decodeIfPresent(String.self, forKey: .separator)).flatMap { SeparatorColor(parsing: $0) } ?? .black
        separatorWidth = (try? c.decodeIfPresent(Double.self, forKey: .separatorWidth)) ?? nil
        exportFileNames = try c.decodeIfPresent(Bool.self, forKey: .exportFileNames) ?? true   // (not a yes or no: the project is refused, as for any other switch)
        sanitize()   // a damaged or hand-edited file loads with sane numbers instead of crashing a render later
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(image, forKey: .image)
        try c.encodeIfPresent(imageSHA256, forKey: .imageSHA256)
        try c.encode(strict, forKey: .strict)
        try c.encodeIfPresent(title, forKey: .title)
        try c.encodeIfPresent(crop, forKey: .crop)
        try c.encode(fillPadding, forKey: .fillPadding)
        try c.encode(rotateDeg, forKey: .rotateDeg)
        try c.encode(fillMode, forKey: .fillMode)
        if fillMode == .custom { try c.encode(fillValue, forKey: .fillValue) }
        if viewEnhance { try c.encode(true, forKey: .viewEnhance) }
        try c.encode(display, forKey: .display)
        try c.encode(lanes, forKey: .lanes)
        try c.encode(rows, forKey: .rows)
        try c.encodeIfPresent(ladder, forKey: .ladder)
        try c.encode(annotations, forKey: .annotations)
        try c.encode(style, forKey: .style)
        if turn != 0 { try c.encode(turn, forKey: .turn) }
        if !strips.isEmpty { try c.encode(strips, forKey: .strips) }
        if arrangement != .topToBottom { try c.encode(arrangement, forKey: .arrangement) }
        if mainSlot != 0 { try c.encode(mainSlot, forKey: .mainPosition) }
        if mainShift != 0 { try c.encode(mainShift, forKey: .mainShift) }
        if ownLadder { try c.encode(true, forKey: .ownLadder) }
        if separatorColor != .black { try c.encode(separatorColor.name, forKey: .separator) }
        try c.encodeIfPresent(separatorWidth, forKey: .separatorWidth)
        if !exportFileNames { try c.encode(false, forKey: .exportFileNames) }
    }

    /// The lanes in the figure: the lanes gel's, or side by side all gels' together, numbered continuously from the left.
    public var laneCount: Int { isSideBySide ? stackOrder.reduce(0) { $0 + lanes(ofGel: $1).centers.count } : lanes.centers.count }

    /// What actually applies to pixels, after strict mode has had its say.
    public var effectiveRotation: Double { strict ? 0 : rotateDeg }
    public var effectiveFillPadding: Bool { strict ? false : fillPadding }
    public var effectiveDisplay: DisplaySettings {
        guard strict else { return display }
        var d = DisplaySettings()
        d.bandsDark = display.bandsDark   // analysis polarity only, never touches pixels
        return d
    }
    /// Strict crops are whole pixels so the original grid is kept.
    public func effectiveCrop(width w: Int, height h: Int) -> PixelRect {
        var r = (crop ?? PixelRect(x0: 0, y0: 0, x1: Double(w), y1: Double(h))).normalized(width: w, height: h)
        do {  // whole pixels always: the gel grid never shifts by a fraction
            r = PixelRect(x0: r.x0.rounded(.down), y0: r.y0.rounded(.down), x1: r.x1.rounded(.up), y1: r.y1.rounded(.up))
                .normalized(width: w, height: h)
        }
        return r
    }
}

/// The colour of the line between stacked gels: black, white, or an RGB colour. Black and white are also what #000000 and #ffffff
/// read as, so a colour is never one of those two.
public enum SeparatorColor: Hashable, Sendable {
    case black, white
    case rgb(UInt8, UInt8, UInt8)

    public init(red: UInt8, green: UInt8, blue: UInt8) {
        switch (red, green, blue) {
        case (0, 0, 0): self = .black
        case (255, 255, 255): self = .white
        default: self = .rgb(red, green, blue)
        }
    }

    /// "black", "white", "#RRGGBB" (the # is optional), or the short "#RGB" (each digit doubled): nil when it isn't one.
    public init?(parsing text: String) {
        let t = text.trimmingCharacters(in: .whitespaces).lowercased()
        if t == "black" { self = .black; return }
        if t == "white" { self = .white; return }
        var digits = t.hasPrefix("#") ? String(t.dropFirst()) : t
        guard digits.allSatisfy({ $0.isASCII && $0.isHexDigit }) else { return nil }
        if digits.count == 3 { digits = digits.map { "\($0)\($0)" }.joined() }
        guard digits.count == 6, let v = UInt32(digits, radix: 16) else { return nil }
        self.init(red: UInt8(v >> 16 & 255), green: UInt8(v >> 8 & 255), blue: UInt8(v & 255))
    }

    /// Whether it is a gray (red = green = blue), so a gray figure can hold it exactly.
    public var isGray: Bool { let c = components; return c.red == c.green && c.green == c.blue }

    /// Its red, green and blue, 0 to 255.
    public var components: (red: UInt8, green: UInt8, blue: UInt8) {
        switch self {
        case .black: (0, 0, 0)
        case .white: (255, 255, 255)
        case .rgb(let r, let g, let b): (r, g, b)
        }
    }

    /// "#rrggbb", lower case, whichever colour it is.
    public var hex: String {
        let c = components
        return String(format: "#%02x%02x%02x", c.red, c.green, c.blue)
    }

    /// How a note and the file say it: "black", "white" or "#rrggbb".
    public var name: String {
        switch self {
        case .black: "black"
        case .white: "white"
        case .rgb: hex
        }
    }

    /// Its gray level in a gray figure, 0 to 255: the luminance of its 8-bit red, green and blue (Rec. 709), rounded. A 16-bit
    /// gray figure takes this times 257.
    public var gray: UInt8 {
        let c = components
        let y = 0.2126 * Double(c.red) + 0.7152 * Double(c.green) + 0.0722 * Double(c.blue)
        return UInt8(min(max(y.rounded(), 0), 255))
    }
}

/// Paint for areas that have no image after rotating.
public enum FillMode: String, Codable, Sendable, CaseIterable {
    /// The gel's own measured background (median of the non-padding pixels) — off-white on a typical scan.
    case background
    case white
    case custom
}

/// `[x0, y0, x1, y1]` in JSON, half-open like the Python config.
public struct PixelRect: Codable, Equatable, Sendable {
    public var x0: Double, y0: Double, x1: Double, y1: Double
    public init(x0: Double, y0: Double, x1: Double, y1: Double) {
        self.x0 = x0; self.y0 = y0; self.x1 = x1; self.y1 = y1
    }
    public var width: Double { x1 - x0 }
    public var height: Double { y1 - y0 }

    public init(from decoder: Decoder) throws {
        var c = try decoder.unkeyedContainer()
        x0 = try c.decode(Double.self); y0 = try c.decode(Double.self)
        x1 = try c.decode(Double.self); y1 = try c.decode(Double.self)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.unkeyedContainer()
        try c.encode(x0); try c.encode(y0); try c.encode(x1); try c.encode(y1)
    }

    /// Clamped to an image, ordered, at least 8 px each way.
    public func normalized(width w: Int, height h: Int) -> PixelRect {
        // a number that isn't one is the edge it would have been (so nothing downstream sees NaN)
        let (u0, v0, u1, v1) = (x0.isFinite ? x0 : 0, y0.isFinite ? y0 : 0, x1.isFinite ? x1 : Double(w), y1.isFinite ? y1 : Double(h))
        var a = PixelRect(x0: min(u0, u1), y0: min(v0, v1), x1: max(u0, u1), y1: max(v0, v1))
        a.x0 = max(0, min(a.x0, Double(w) - 8)); a.y0 = max(0, min(a.y0, Double(h) - 8))
        a.x1 = min(Double(w), max(a.x1, a.x0 + 8)); a.y1 = min(Double(h), max(a.y1, a.y0 + 8))
        return a
    }
}

/// How pixel values map to gray on screen and in exports. Detection always uses the raw values.
public struct DisplaySettings: Codable, Equatable, Sendable {
    /// Levels on the 0...1 scale of the source's full range.
    public var black: Double
    public var white: Double
    public var gamma: Double
    public var invert: Bool
    /// Bands are darker than background (stained gels, inverted fluorescence exports). False for bright bands.
    public var bandsDark: Bool

    public init(black: Double = 0, white: Double = 1, gamma: Double = 1, invert: Bool = false, bandsDark: Bool = true) {
        self.black = black; self.white = white; self.gamma = gamma; self.invert = invert; self.bandsDark = bandsDark
    }

    enum CodingKeys: String, CodingKey { case black, white, gamma, invert, bandsDark = "bands_dark" }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        black = try c.decodeIfPresent(Double.self, forKey: .black) ?? 0
        white = try c.decodeIfPresent(Double.self, forKey: .white) ?? 1
        gamma = try c.decodeIfPresent(Double.self, forKey: .gamma) ?? 1
        invert = try c.decodeIfPresent(Bool.self, forKey: .invert) ?? false
        bandsDark = try c.decodeIfPresent(Bool.self, forKey: .bandsDark) ?? true
    }
}

/// Lanes are defined by the dividers the user draws in the gaps between them (one click per gap → a straight line).
/// `centers` is derived from the dividers when there are any; configs without dividers (older files, the CLI's
/// detector) use `centers` directly.
public struct Lanes: Codable, Equatable, Sendable {
    public var dividers: [LaneDivider]
    /// The areas before the first and after the last divider count as lanes (sized like their neighbours).
    public var outerLanes: Bool
    /// Lane 1 first, at the gel's top edge.
    public var centers: [Double]
    public var width: Double

    public init(dividers: [LaneDivider] = [], outerLanes: Bool = true, centers: [Double] = [], width: Double = 100) {
        self.dividers = dividers; self.outerLanes = outerLanes; self.centers = centers; self.width = width
    }
    enum CodingKeys: String, CodingKey { case dividers, centers, width, outerLanes = "outer_lanes" }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        dividers = try c.decodeIfPresent([LaneDivider].self, forKey: .dividers) ?? []
        outerLanes = try c.decodeIfPresent(Bool.self, forKey: .outerLanes) ?? true
        centers = try c.decodeIfPresent([Double].self, forKey: .centers) ?? []
        width = try c.decodeIfPresent(Double.self, forKey: .width) ?? 100
    }
}

/// A straight line between two lanes, spanning the whole image. Stored by its x at the image's top and bottom
/// rows, so dragging either end tilts it and dragging the dot moves it sideways.
public struct LaneDivider: Codable, Equatable, Sendable, Identifiable {
    public var id = UUID()
    public var xTop: Double
    public var xBottom: Double
    /// Where the dot sits (the y the user clicked).
    public var dotY: Double

    public init(x: Double, dotY: Double) { xTop = x; xBottom = x; self.dotY = dotY }
    public init(xTop: Double, xBottom: Double, dotY: Double) { self.xTop = xTop; self.xBottom = xBottom; self.dotY = dotY }

    /// x of the line at image row `y` in an image `height` pixels tall.
    public func x(atY y: Double, height: Double) -> Double {
        height <= 0 ? xTop : xTop + (xBottom - xTop) * (y / height)
    }

    enum CodingKeys: String, CodingKey { case xTop = "x_top", xBottom = "x_bottom", dotY = "dot_y" }
    public static func == (a: LaneDivider, b: LaneDivider) -> Bool {
        a.xTop == b.xTop && a.xBottom == b.xBottom && a.dotY == b.dotY
    }
}

/// Lanes resolved from dividers: boundary lines left to right, including the virtual outer ones.
public struct LaneGeometry: Sendable {
    public struct Line: Sendable { public var xTop: Double, xBottom: Double }
    public var boundaries: [Line]
    public var height: Double
    public var count: Int { max(0, boundaries.count - 1) }

    public func x(_ line: Line, atY y: Double) -> Double { line.xTop + (line.xBottom - line.xTop) * (y / max(height, 1)) }
    /// Center of lane `n` (1-based) at row `y`.
    public func center(_ n: Int, atY y: Double) -> Double {
        (x(boundaries[n - 1], atY: y) + x(boundaries[n], atY: y)) / 2
    }
    public func lane(atX px: Double, y: Double) -> Int? {
        guard count > 0 else { return nil }
        for n in 1...count where px >= x(boundaries[n - 1], atY: y) && px < x(boundaries[n], atY: y) { return n }
        return nil
    }

    /// Nil when there are no dividers (the project then uses `centers` as given).
    public static func resolve(_ lanes: Lanes, imageWidth: Double, imageHeight: Double) -> LaneGeometry? {
        let h = imageHeight
        let lines = lanes.dividers
            .map { Line(xTop: $0.xTop, xBottom: $0.xBottom) }
            .sorted { ($0.xTop + $0.xBottom) < ($1.xTop + $1.xBottom) }
        guard !lines.isEmpty else { return nil }
        var b = lines
        if lanes.outerLanes {
            let mids = lines.map { ($0.xTop + $0.xBottom) / 2 }
            let gaps = zip(mids.dropFirst(), mids).map { $0 - $1 }.sorted()
            // outer lanes as wide as a typical lane; with a single divider, reach the image edges
            let spacing = gaps.isEmpty ? nil : gaps[gaps.count / 2]
            let first = lines[0], last = lines[lines.count - 1]
            let dl = spacing ?? ((first.xTop + first.xBottom) / 2)
            let dr = spacing ?? (imageWidth - (last.xTop + last.xBottom) / 2)
            b.insert(Line(xTop: first.xTop - dl, xBottom: first.xBottom - dl), at: 0)
            b.append(Line(xTop: last.xTop + dr, xBottom: last.xBottom + dr))
        }
        return LaneGeometry(boundaries: b, height: h)
    }
}

extension GelProject {
    /// Recomputes `lanes.centers` (at the gel's top edge) and `lanes.width` from the dividers. Call after any divider edit.
    /// `gel`: a strip's number works on that gel's own lanes (side by side) at the top of its kept rows.
    public mutating func syncLaneCenters(imageWidth: Int, imageHeight: Int, gel: Int? = nil) {
        var l = lanes(ofGel: gel)
        guard let g = LaneGeometry.resolve(l, imageWidth: Double(imageWidth), imageHeight: Double(imageHeight)) else { return }
        let top = gel.map { strips[$0 - 1].usedRows(height: imageHeight).top } ?? effectiveCrop(width: imageWidth, height: imageHeight).y0
        l.centers = (0..<g.count).map { ((g.center($0 + 1, atY: top)) * 10).rounded() / 10 }
        let widths = (0..<g.count).map { g.x(g.boundaries[$0 + 1], atY: top) - g.x(g.boundaries[$0], atY: top) }.sorted()
        if !widths.isEmpty { l.width = (widths[widths.count / 2] * 0.85).rounded() }
        setLanes(l, ofGel: gel)
    }
}

public enum RowKind: String, Codable, Sendable, CaseIterable {
    /// One label per lane.
    case lanes
    /// Text centered over a span of lanes, with an optional underline.
    case groups
}

public struct LabelRow: Codable, Equatable, Sendable, Identifiable {
    public var id = UUID()
    public var type: RowKind
    /// Row title printed at the left, e.g. "µM".
    public var name: String?
    public var labels: [String]
    public var groups: [LabelGroup]
    /// The angle the row's labels stand at, in degrees: 0 is horizontal, 90 straight up, the text rising to the right from the
    /// lane's centre (a group label's anchor is the centre of its span of lanes). Always in 0 ..< 360: see `clampedAngle`. For a
    /// row of lane labels one angle is shared by the figure (`GelOps.setLabelAngle`); each row of group labels has its own
    /// (`GelOps.setRowAngle`) and its underline stays flat. Row titles, band names and ladder sizes stay horizontal.
    public var rotation: Double
    public var underline: Bool
    public var bold: Bool

    public init(type: RowKind, name: String? = nil, labels: [String] = [], groups: [LabelGroup] = [],
                rotation: Double = 0, underline: Bool = true, bold: Bool = false) {
        self.type = type; self.name = name; self.labels = labels; self.groups = groups
        self.rotation = rotation; self.underline = underline; self.bold = bold
    }

    enum CodingKeys: String, CodingKey { case type, name, labels, groups, rotation, underline, weight }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        type = try c.decodeIfPresent(RowKind.self, forKey: .type) ?? .lanes
        name = try c.decodeIfPresent(String.self, forKey: .name)
        labels = try c.decodeIfPresent([String].self, forKey: .labels) ?? []
        groups = try c.decodeIfPresent([LabelGroup].self, forKey: .groups) ?? []
        rotation = Self.clampedAngle(try c.decodeIfPresent(Double.self, forKey: .rotation) ?? 0)
        underline = try c.decodeIfPresent(Bool.self, forKey: .underline) ?? true
        bold = (try c.decodeIfPresent(String.self, forKey: .weight)) == "bold"
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(type, forKey: .type)
        try c.encodeIfPresent(name, forKey: .name)
        switch type {
        case .lanes: try c.encode(labels, forKey: .labels)
        case .groups: try c.encode(groups, forKey: .groups); try c.encode(underline, forKey: .underline)
        }
        if rotation != 0 { try c.encode(rotation, forKey: .rotation) }
        if bold { try c.encode("bold", forKey: .weight) }
    }

    /// `degrees` brought into the range lane labels can stand at, 0 to 90 (a number that isn't one is 0).
    /// Any angle, brought into 0 ..< 360 (a number that isn't one is 0).
    public static func clampedAngle(_ degrees: Double) -> Double {
        guard degrees.isFinite else { return 0 }
        let a = degrees.truncatingRemainder(dividingBy: 360), r = a < 0 ? a + 360 : a
        return r >= 360 ? 0 : r
    }

    public static func == (a: LabelRow, b: LabelRow) -> Bool {
        a.type == b.type && a.name == b.name && a.labels == b.labels && a.groups == b.groups &&
            a.rotation == b.rotation && a.underline == b.underline && a.bold == b.bold
    }
}

public struct LabelGroup: Codable, Equatable, Sendable, Identifiable {
    public var id = UUID()
    public var text: String
    /// Lanes spanned (1-based). Only the first and last matter.
    public var lanes: [Int]
    public init(text: String, lanes: [Int]) { self.text = text; self.lanes = lanes }
    public var first: Int { lanes.min() ?? 1 }
    public var last: Int { lanes.max() ?? 1 }
    enum CodingKeys: String, CodingKey { case text, lanes }
    public static func == (a: LabelGroup, b: LabelGroup) -> Bool { a.text == b.text && a.lanes == b.lanes }
}

public enum LadderSide: String, Codable, Sendable, CaseIterable { case left, right }

public struct Ladder: Codable, Equatable, Sendable {
    /// 1-based lane holding the ladder.
    public var lane: Int
    /// Preset name, for the record.
    public var name: String?
    public var unit: String
    public var side: LadderSide
    /// The ladder's sizes (largest first) as the user has them — starts as the preset's list and is editable,
    /// so a figure records exactly which sizes it used.
    public var sizes: [Double]?
    /// Gel and running buffer the sizes are for (apparent sizes of prestained ladders depend on it).
    public var system: String?
    public var bands: [LadderBand]
    /// Row the unit label ("kDa") is centered on, placed by the user, in the pixels of the gel `unitStrip` names; nil =
    /// above the top of the gel.
    public var unitY: Double?
    /// The gel (strip number, 1-based) `unitY` is a row of; nil = the gel with the lanes. The label goes with that gel.
    public var unitStrip: Int?

    public init(lane: Int = 1, name: String? = nil, unit: String = "kDa", side: LadderSide = .left,
                sizes: [Double]? = nil, system: String? = nil, bands: [LadderBand] = [], unitY: Double? = nil,
                unitStrip: Int? = nil) {
        self.lane = lane; self.name = name; self.unit = unit; self.side = side; self.sizes = sizes
        self.system = system; self.bands = bands; self.unitY = unitY; self.unitStrip = unitStrip
    }
    enum CodingKeys: String, CodingKey { case lane, name, unit, side, sizes, system, bands, unitY = "unit_y", unitStrip = "unit_strip" }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        lane = try c.decodeIfPresent(Int.self, forKey: .lane) ?? 1
        name = try c.decodeIfPresent(String.self, forKey: .name)
        unit = try c.decodeIfPresent(String.self, forKey: .unit) ?? "kDa"
        side = try c.decodeIfPresent(LadderSide.self, forKey: .side) ?? .left
        sizes = try c.decodeIfPresent([Double].self, forKey: .sizes)
        system = try c.decodeIfPresent(String.self, forKey: .system)
        bands = try c.decodeIfPresent([LadderBand].self, forKey: .bands) ?? []
        unitY = try c.decodeIfPresent(Double.self, forKey: .unitY)
        unitStrip = try c.decodeIfPresent(Int.self, forKey: .unitStrip)
    }

    /// A guess, not a decision: gives `sizes` (largest first) to the non-skipped bands from the top down and marks
    /// each one `auto` until the user confirms or changes it. Extra bands get no size. `position`: where each tick's
    /// gel sits from the top (`GelProject.position(of:)`; use `GelProject.assignLadder` for a stack of gels).
    public mutating func assign(sizes: [Double], position: (Int?) -> Int = { $0 ?? 0 }) {
        bands.sort { (position($0.strip), $0.y) < (position($1.strip), $1.y) }
        var next = sizes.makeIterator()
        for i in bands.indices {
            bands[i].size = bands[i].ignore ? nil : next.next()
            bands[i].auto = bands[i].size != nil
        }
    }

    /// Problems worth showing: sizes that don't decrease down the lane, repeated sizes (one gel; see
    /// `GelProject.ladderWarnings` for a stack).
    public var warnings: [String] { warnings() }

    public func warnings(position: (Int?) -> Int = { $0 ?? 0 }) -> [String] {
        let labeled = bands.filter { !$0.ignore && $0.size != nil }
            .sorted { (position($0.strip), $0.y) < (position($1.strip), $1.y) }
        var w: [String] = []
        for (a, b) in zip(labeled, labeled.dropFirst()) where b.size! >= a.size! {
            w.append("\(FigureLayoutEngine.formatSize(b.size!)) sits below \(FigureLayoutEngine.formatSize(a.size!)). Sizes should shrink down the lane.")
        }
        let sizes = labeled.compactMap(\.size)
        if Set(sizes).count != sizes.count { w.append("The same size is on more than one tick.") }
        return w
    }
}

public struct LadderBand: Codable, Equatable, Sendable, Identifiable {
    public var id = UUID()
    public var y: Double
    /// nil = marked but not labeled.
    public var size: Double?
    /// Not a ladder band (dye front, artifact). Skipped when preset sizes are assigned.
    public var ignore: Bool
    /// The size is the app's guess (top-down assignment), not something the user entered or confirmed.
    public var auto: Bool
    public var note: String?
    /// The strip (1-based) this tick is on, with `y` in that strip's own pixels; nil = the main image.
    public var strip: Int?

    public init(y: Double, size: Double? = nil, ignore: Bool = false, auto: Bool = false, note: String? = nil, strip: Int? = nil) {
        self.y = y; self.size = size; self.ignore = ignore; self.auto = auto; self.note = note; self.strip = strip
    }
    enum CodingKeys: String, CodingKey { case y, size, ignore, auto, note, strip }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        y = try c.decode(Double.self, forKey: .y)
        size = try c.decodeIfPresent(Double.self, forKey: .size)
        ignore = try c.decodeIfPresent(Bool.self, forKey: .ignore) ?? false
        auto = try c.decodeIfPresent(Bool.self, forKey: .auto) ?? false
        note = try c.decodeIfPresent(String.self, forKey: .note)
        strip = try c.decodeIfPresent(Int.self, forKey: .strip)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(y, forKey: .y)
        try c.encode(size, forKey: .size)   // explicit null, like the Python config
        if ignore { try c.encode(true, forKey: .ignore) }
        if auto { try c.encode(true, forKey: .auto) }
        try c.encodeIfPresent(note, forKey: .note)
        try c.encodeIfPresent(strip, forKey: .strip)
    }
    public static func == (a: LadderBand, b: LadderBand) -> Bool {
        a.y == b.y && a.size == b.size && a.ignore == b.ignore && a.auto == b.auto && a.note == b.note && a.strip == b.strip
    }
}

/// How the gels of a figure sit: stacked, or next to each other.
public enum Arrangement: String, Codable, Sendable, CaseIterable {
    case topToBottom = "top_to_bottom"
    case sideBySide = "side_by_side"
}

/// Another gel in the figure, scanned on its own: a piece of a membrane cut to probe different antibodies, or the same
/// samples run on another gel. It's stacked with the project's image, a line between them so the figure shows they
/// were imaged separately. Lanes and lane labels are the project image's; this gel is lined up under them with `shift`
/// (and, when Strict is off, `scale`). Its ticks and names are in the project's ladder and annotations, marked with
/// its number in `strips`.
public struct GelStrip: Codable, Equatable, Sendable, Identifiable {
    /// The sizes a gel may be given against the gel with the lanes when the gels sit side by side (`scale`).
    public static let sideScales = 0.01...100.0
    public var id = UUID()
    /// File name of the piece's image inside the package, copied byte-for-byte like the main image.
    public var image: String
    public var imageSHA256: String?
    /// Quarter turns clockwise (0…3), for a piece scanned the wrong way round. Lossless.
    public var turn: Int
    /// Straightening, degrees; resamples, so it only applies when Strict is off.
    public var rotateDeg: Double
    public var display: DisplaySettings
    /// The rows of this piece that go into the figure, in its own working-image pixels; nil = the edge of the image.
    public var top: Double?
    public var bottom: Double?
    /// The columns that go into the figure, the same way (nil = the edge of the image). With the rows, the piece's own crop:
    /// the figure runs from the leftmost to the rightmost column any gel keeps, and what no gel has is blank white.
    public var left: Double?
    public var right: Double?
    /// Lines the lanes up: x in this piece = scale × x in the main image + shift. Strict uses whole-pixel shifts only.
    public var shift: Double
    public var scale: Double
    /// This gel's ladder sizes start again from the top of the list instead of carrying on from the gel above.
    public var ownLadder: Bool
    /// Keep original pixels for this gel: true keeps them (whole-pixel shift, no stretch, no rotation, brightness &
    /// contrast on screen only), false stretches, rotates and applies its brightness & contrast to what's exported.
    /// nil = the same as the gel with the lanes (`GelProject.isStrict(gel:)`), which is how older projects read.
    public var strict: Bool?
    /// This gel's own lanes, in its own pixels, used when the gels sit side by side (JSON `"lanes"`, left out when it has none). Kept
    /// in the file, unused, while the gels are stacked top to bottom.
    public var lanes: Lanes?

    public init(image: String, imageSHA256: String? = nil, turn: Int = 0, rotateDeg: Double = 0,
                display: DisplaySettings = .init(), top: Double? = nil, bottom: Double? = nil, left: Double? = nil, right: Double? = nil,
                shift: Double = 0, scale: Double = 1, ownLadder: Bool = false, strict: Bool? = nil) {
        self.image = image; self.imageSHA256 = imageSHA256; self.turn = turn; self.rotateDeg = rotateDeg
        self.display = display; self.top = top; self.bottom = bottom; self.left = left; self.right = right
        self.shift = shift; self.scale = scale
        self.ownLadder = ownLadder; self.strict = strict
    }

    enum CodingKeys: String, CodingKey {
        case image, turn, display, top, bottom, left, right, shift, scale, strict, lanes
        case imageSHA256 = "image_sha256", rotateDeg = "rotate_deg", ownLadder = "own_ladder"
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        image = try c.decode(String.self, forKey: .image)
        imageSHA256 = try c.decodeIfPresent(String.self, forKey: .imageSHA256)
        turn = ((try c.decodeIfPresent(Int.self, forKey: .turn) ?? 0) % 4 + 4) % 4
        rotateDeg = try c.decodeIfPresent(Double.self, forKey: .rotateDeg) ?? 0
        display = try c.decodeIfPresent(DisplaySettings.self, forKey: .display) ?? .init()
        top = try c.decodeIfPresent(Double.self, forKey: .top)
        bottom = try c.decodeIfPresent(Double.self, forKey: .bottom)
        left = try c.decodeIfPresent(Double.self, forKey: .left)
        right = try c.decodeIfPresent(Double.self, forKey: .right)
        shift = try c.decodeIfPresent(Double.self, forKey: .shift) ?? 0
        scale = try c.decodeIfPresent(Double.self, forKey: .scale) ?? 1
        ownLadder = try c.decodeIfPresent(Bool.self, forKey: .ownLadder) ?? false
        strict = try c.decodeIfPresent(Bool.self, forKey: .strict)
        lanes = try c.decodeIfPresent(Lanes.self, forKey: .lanes)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(image, forKey: .image)
        try c.encodeIfPresent(imageSHA256, forKey: .imageSHA256)
        if turn != 0 { try c.encode(turn, forKey: .turn) }
        try c.encode(rotateDeg, forKey: .rotateDeg)
        try c.encode(display, forKey: .display)
        try c.encodeIfPresent(top, forKey: .top)
        try c.encodeIfPresent(bottom, forKey: .bottom)
        try c.encodeIfPresent(left, forKey: .left)
        try c.encodeIfPresent(right, forKey: .right)
        try c.encode(shift, forKey: .shift)
        try c.encode(scale, forKey: .scale)
        if ownLadder { try c.encode(true, forKey: .ownLadder) }
        try c.encodeIfPresent(strict, forKey: .strict)
        try c.encodeIfPresent(lanes, forKey: .lanes)
    }
    public static func == (a: GelStrip, b: GelStrip) -> Bool {
        a.image == b.image && a.imageSHA256 == b.imageSHA256 && a.turn == b.turn && a.rotateDeg == b.rotateDeg &&
            a.display == b.display && a.top == b.top && a.bottom == b.bottom && a.left == b.left && a.right == b.right &&
            a.shift == b.shift && a.scale == b.scale &&
            a.ownLadder == b.ownLadder && a.strict == b.strict && a.lanes == b.lanes
    }
}

extension GelProject {
    /// The angle the lane labels stand at, 0 to 90 degrees: the first row of lane labels' (0 without one). One setting
    /// for the figure; `GelOps.setLabelAngle` sets it on every row of lane labels.
    public var labelAngle: Double {
        rows.first { $0.type == .lanes }.map { LabelRow.clampedAngle($0.rotation) } ?? 0
    }

    /// Where the image with the lanes sits in the stack, kept in range (see `mainPosition`).
    public var mainSlot: Int { min(max(mainPosition, 0), strips.count) }

    /// The gels top to bottom: nil = this image (the one with the lanes), k = `strips[k - 1]`.
    public var stackOrder: [Int?] {
        var order: [Int?] = strips.indices.map { $0 + 1 }
        order.insert(nil, at: mainSlot)
        return order
    }

    /// A gel's place in the stack, from 0 at the top (nil = this image).
    public func position(of strip: Int?) -> Int { Self.position(of: strip, mainSlot: mainSlot) }

    static func position(of strip: Int?, mainSlot m: Int) -> Int {
        guard let k = strip else { return m }
        return k - 1 < m ? k - 1 : k
    }

    /// Sort key for a mark at `y` in its own gel: top to bottom through the stack.
    public func stackKey(_ strip: Int?, _ y: Double) -> (Int, Double) { (position(of: strip), y) }

    // MARK: ladder groups

    /// Whether gel `strip` (nil = the one with the lanes) is marked as having its own ladder.
    public func hasOwnLadder(_ strip: Int?) -> Bool {
        if isSideBySide { return true }   // every gel next to another has a ladder of its own
        guard let k = strip else { return ownLadder }
        return k >= 1 && k <= strips.count && strips[k - 1].ownLadder
    }

    /// For each place in the stack (from the top), the number of the ladder group it belongs to. The top gel starts the
    /// first group and every gel with its own ladder starts another; the gels in between carry their group's sizes on.
    private var groupByPosition: [Int] {
        var out: [Int] = [], g = -1
        for (i, s) in stackOrder.enumerated() {
            if i == 0 || hasOwnLadder(s) { g += 1 }
            out.append(g)
        }
        return out
    }

    /// The gels top to bottom, split into the groups that share one ladder (see `ladderGroup(of:)`).
    public var ladderGroups: [[Int?]] {
        var groups: [[Int?]] = []
        for (i, s) in stackOrder.enumerated() {
            if i == 0 || hasOwnLadder(s) { groups.append([s]) } else { groups[groups.count - 1].append(s) }
        }
        return groups
    }

    /// The number (from 0) of the ladder group gel `strip` (nil = the one with the lanes) is in. Ladder sizes run on
    /// from gel to gel inside a group and start again from the top of the list in the next group.
    public func ladderGroup(of strip: Int?) -> Int {
        let by = groupByPosition
        return by[min(position(of: strip), by.count - 1)]
    }

    /// Whether a mark at `y` (in the pixels of gel `strip`, nil = the one with the lanes) is inside the rows that gel
    /// shows in the figure. A tick or name outside them was hidden by a later crop: it keeps its size but no longer takes
    /// part in the ladder (assigning sizes, the suggested size, the warnings).
    public func isInFigure(strip: Int?, y: Double) -> Bool {
        guard y.isFinite else { return false }
        if let k = strip {
            guard k >= 1, k <= strips.count else { return false }
            let s = strips[k - 1]
            let top = (s.top ?? 0).rounded(), bottom = s.bottom.map { $0.rounded() } ?? .infinity
            guard top.isFinite || s.top == nil else { return false }
            return y >= top - 0.5 && y <= bottom + 0.5
        }
        guard let c = crop, c.y0.isFinite, c.y1.isFinite else { return true }
        return y >= min(c.y0, c.y1).rounded(.down) && y <= max(c.y0, c.y1).rounded(.up)
    }

    /// Ladder sizes from the top down through the gels (a guess, marked `auto`). Every ladder group starts again from the
    /// top of `sizes`, and ticks that a crop hides keep the size they had.
    public mutating func assignLadder(sizes: [Double]) {
        guard var l = ladder else { return }
        let by = groupByPosition, m = mainSlot
        l.bands.sort { stackKey($0.strip, $0.y) < stackKey($1.strip, $1.y) }
        var used = [Int](repeating: 0, count: by.count)
        for i in l.bands.indices {
            let b = l.bands[i]
            guard isInFigure(strip: b.strip, y: b.y) else { continue }
            if b.ignore { l.bands[i].size = nil; l.bands[i].auto = false; continue }
            let g = by[min(Self.position(of: b.strip, mainSlot: m), by.count - 1)]
            let n = used[g]
            used[g] += 1
            l.bands[i].size = n < sizes.count ? sizes[n] : nil
            l.bands[i].auto = l.bands[i].size != nil
        }
        ladder = l
    }

    /// The ladder's warnings, reading the ticks top to bottom through each ladder group. Ticks hidden by a crop don't count.
    public var ladderWarnings: [String] {
        guard let l = ladder else { return [] }
        let by = groupByPosition, m = mainSlot
        func group(_ s: Int?) -> Int { by[min(Self.position(of: s, mainSlot: m), by.count - 1)] }
        let labeled = l.bands.filter { !$0.ignore && $0.size != nil && isInFigure(strip: $0.strip, y: $0.y) }
            .sorted { stackKey($0.strip, $0.y) < stackKey($1.strip, $1.y) }
        var w: [String] = []
        var repeated = false
        for g in Set(labeled.map { group($0.strip) }).sorted() {
            let inGroup = labeled.filter { group($0.strip) == g }
            for (a, b) in zip(inGroup, inGroup.dropFirst()) where b.size! >= a.size! {
                w.append("\(FigureLayoutEngine.formatSize(b.size!)) sits below \(FigureLayoutEngine.formatSize(a.size!)). Sizes should shrink down the lane.")
            }
            let sizes = inGroup.compactMap(\.size)
            if Set(sizes).count != sizes.count { repeated = true }
        }
        if repeated { w.append("The same size is on more than one tick.") }
        return w
    }

    /// Strip `k` (1-based) as a project of its own, which is what `WorkingImage` reads: its image, turn, rotation and
    /// brightness & contrast, with its own Keep original pixels (`isStrict(gel:)`) and this project's fill.
    public func stripProject(_ k: Int) -> GelProject {
        let s = strips[k - 1]
        var p = GelProject(image: s.image, imageSHA256: s.imageSHA256, strict: isStrict(gel: k), fillPadding: fillPadding,
                           rotateDeg: s.rotateDeg, fillMode: fillMode, fillValue: fillValue, display: s.display)
        p.turn = s.turn
        return p
    }

    /// Whether a gel keeps its original pixels (`gel` nil = the gel with the lanes, else its number in `strips`): the
    /// gel's own setting, or the lanes gel's when it has none.
    public func isStrict(gel k: Int?) -> Bool {
        guard let k, k >= 1, k <= strips.count else { return strict }
        return strips[k - 1].strict ?? strict
    }

    /// Where the gel with the lanes sits sideways (see `mainShift`): whole pixels, and a number that isn't one is 0.
    public var effectiveMainShift: Double {
        mainShift.isFinite ? min(max(mainShift, -Sane.coordinate), Sane.coordinate).rounded() : 0
    }

    /// What lines gel `k` up with the gel with the lanes wherever that sits: x in the gel = scale × x in the lanes gel + shift. The
    /// gel's `shift` (`effectiveAlignment`) is its place in the figure, and the lanes gel itself sits at `effectiveMainShift`, so
    /// the two differ by scale × that. Stacking, the lanes' places in a gel's own pixels and Auto-align work from this.
    public func laneAlignment(_ k: Int) -> (shift: Double, scale: Double) {
        let a = effectiveAlignment(k)
        return (a.shift - a.scale * effectiveMainShift, a.scale)
    }

    /// The `shift` to store for gel `k` so it lines up with the lanes gel by `laneShift` (see `laneAlignment`) wherever that sits.
    public func shiftToStore(laneShift: Double, scale: Double) -> Double { laneShift + scale * effectiveMainShift }

    /// What lines strip `k` up, after its Keep original pixels has had its say: whole-pixel shifts and no stretching.
    public func effectiveAlignment(_ k: Int) -> (shift: Double, scale: Double) {
        let s = strips[k - 1]
        // numbers that aren't sane never reach the stacking: no shift, no stretch
        let shift = s.shift.isFinite ? min(max(s.shift, -Sane.coordinate), Sane.coordinate) : 0
        let range = isSideBySide ? GelStrip.sideScales : 0.5...2   // side by side a photo and a small scan can differ a lot in size
        let scale = s.scale.isFinite && s.scale > 0 ? min(max(s.scale, range.lowerBound), range.upperBound) : 1
        return isStrict(gel: k) ? (shift.rounded(), 1) : (shift, scale)
    }
}

public enum AnnotationMarker: String, Codable, Sendable, CaseIterable {
    /// Filled arrowhead pointing at the gel edge.
    case arrow
    /// Short line, like a ladder tick.
    case tick
    /// Vertical bracket spanning `y`…`y2` (smears, oligomer ladders).
    case bracket
    /// Text only.
    case none
}

/// A name placed at the gel's edge beside a band, e.g. a protein name on the right. `y` is where the band meets that edge,
/// which on a tilted gel differs from where the ladder would put it.
public struct BandAnnotation: Codable, Equatable, Sendable, Identifiable {
    public var id = UUID()
    public var y: Double
    public var y2: Double?
    public var text: String
    public var marker: AnnotationMarker
    public var side: LadderSide
    public var italic: Bool
    public var bold: Bool
    public var note: String?
    /// The strip (1-based) this name is on, with `y` in that strip's own pixels; nil = the main image.
    public var strip: Int?

    public init(y: Double, y2: Double? = nil, text: String, marker: AnnotationMarker = .arrow, side: LadderSide = .right,
                italic: Bool = false, bold: Bool = false, note: String? = nil, strip: Int? = nil) {
        self.y = y; self.y2 = y2; self.text = text; self.marker = marker; self.side = side
        self.italic = italic; self.bold = bold; self.note = note; self.strip = strip
    }

    enum CodingKeys: String, CodingKey { case y, y2, text, marker, side, italic, bold, note, strip }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        y = try c.decode(Double.self, forKey: .y)
        y2 = try c.decodeIfPresent(Double.self, forKey: .y2)
        text = try c.decodeIfPresent(String.self, forKey: .text) ?? ""
        marker = try c.decodeIfPresent(AnnotationMarker.self, forKey: .marker) ?? .arrow
        side = try c.decodeIfPresent(LadderSide.self, forKey: .side) ?? .right
        italic = try c.decodeIfPresent(Bool.self, forKey: .italic) ?? false
        bold = try c.decodeIfPresent(Bool.self, forKey: .bold) ?? false
        note = try c.decodeIfPresent(String.self, forKey: .note)
        strip = try c.decodeIfPresent(Int.self, forKey: .strip)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(y, forKey: .y)
        try c.encodeIfPresent(y2, forKey: .y2)
        try c.encode(text, forKey: .text)
        try c.encode(marker, forKey: .marker)
        try c.encode(side, forKey: .side)
        if italic { try c.encode(true, forKey: .italic) }
        if bold { try c.encode(true, forKey: .bold) }
        try c.encodeIfPresent(note, forKey: .note)
        try c.encodeIfPresent(strip, forKey: .strip)
    }
    public static func == (a: BandAnnotation, b: BandAnnotation) -> Bool {
        a.y == b.y && a.y2 == b.y2 && a.text == b.text && a.marker == b.marker && a.side == b.side &&
            a.italic == b.italic && a.bold == b.bold && a.note == b.note && a.strip == b.strip
    }
}

extension FigureRole {
    /// Key for a single-label size override. Ladder numbers and the title only size as a group, so they have none.
    public var sizeKey: String? {
        switch self {
        case .laneLabel(let r, let lane): "lane.\(r).\(lane)"
        case .groupLabel(let r, let g): "group.\(r).\(g)"
        case .rowName(let r): "rowname.\(r)"
        case .annotation(let i): "name.\(i)"
        case .title, .ladderLabel, .ladderUnit: nil
        }
    }
}

/// Kinds of text in a figure, each with its own size.
public enum TextKind: String, CaseIterable, Sendable, Identifiable {
    case laneLabel, groupLabel, rowName, ladder, name, title
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .laneLabel: "Lane labels"
        case .groupLabel: "Group labels"
        case .rowName: "Row titles"
        case .ladder: "Ladder sizes"
        case .name: "Band names"
        case .title: "Title"
        }
    }
    public init(role: FigureRole) {
        switch role {
        case .title: self = .title
        case .rowName: self = .rowName
        case .laneLabel: self = .laneLabel
        case .groupLabel: self = .groupLabel
        case .ladderLabel, .ladderUnit: self = .ladder
        case .annotation: self = .name
        }
    }
}

public struct FigureStyle: Codable, Equatable, Sendable {
    public var font: String
    /// Points: lane, group and ladder labels.
    public var size: Double
    public var titleSize: Double
    /// Printed width of the cropped gel.
    public var gelWidthIn: Double
    public var tickLenPt: Double
    public var lineWidthPt: Double
    public var border: Bool
    public var rowGapPt: Double
    /// Fraction of a lane width trimmed from each end of a group underline.
    public var groupLineInset: Double
    /// Minimum ladder-label spacing, in multiples of the font size.
    public var labelSep: Double
    /// Horizontal run of the leader used when a ladder label had to move.
    public var leaderPt: Double
    /// Sizes for single labels (e.g. just "Ladder"), keyed by `FigureRole.sizeKey`. Win over the per-kind size.
    public var textSizes: [String: Double] = [:]
    /// PNG/TIFF resolution; nil = native (one gel pixel per output pixel, the only exact one). Any other value
    /// redraws the figure at that density and resamples the gel.
    public var exportDPI: Double?
    /// Per-kind sizes in points; nil follows `size`.
    public var laneLabelSize: Double?
    public var groupLabelSize: Double?
    public var rowNameSize: Double?
    public var ladderLabelSize: Double?
    public var nameSize: Double?

    public init() {
        font = "Arial"; size = 7; titleSize = 8; gelWidthIn = 3.2; tickLenPt = 3; lineWidthPt = 0.6
        border = true; rowGapPt = 3; groupLineInset = 0.12; labelSep = 1.1; leaderPt = 3
    }

    public func size(for kind: TextKind) -> Double {
        switch kind {
        case .laneLabel: laneLabelSize ?? size
        case .groupLabel: groupLabelSize ?? size
        case .rowName: rowNameSize ?? size
        case .ladder: ladderLabelSize ?? size
        case .name: nameSize ?? size
        case .title: titleSize
        }
    }

    public mutating func setSize(_ v: Double, for kind: TextKind) {
        let x = min(max((v * 2).rounded() / 2, 3), 48)
        switch kind {
        case .laneLabel: laneLabelSize = x
        case .groupLabel: groupLabelSize = x
        case .rowName: rowNameSize = x
        case .ladder: ladderLabelSize = x
        case .name: nameSize = x
        case .title: titleSize = x
        }
    }

    /// Everything bigger or smaller by `delta` points, keeping the differences between kinds.
    public mutating func scaleAll(by delta: Double) {
        for k in TextKind.allCases { setSize(size(for: k) + delta, for: k) }
        for (k, v) in textSizes { textSizes[k] = min(max(v + delta, 3), 48) }
        size = min(max(size + delta, 3), 48)
    }

    enum CodingKeys: String, CodingKey {
        case font, size, border
        case titleSize = "title_size", gelWidthIn = "gel_width_in", tickLenPt = "tick_len_pt"
        case lineWidthPt = "line_width_pt", rowGapPt = "row_gap_pt", groupLineInset = "group_line_inset"
        case labelSep = "label_sep", leaderPt = "leader_pt"
        case laneLabelSize = "lane_label_size", groupLabelSize = "group_label_size", rowNameSize = "row_name_size"
        case ladderLabelSize = "ladder_label_size", nameSize = "name_size", textSizes = "text_sizes", exportDPI = "export_dpi"
    }
    public init(from decoder: Decoder) throws {
        self.init()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        font = try c.decodeIfPresent(String.self, forKey: .font) ?? font
        size = try c.decodeIfPresent(Double.self, forKey: .size) ?? size
        titleSize = try c.decodeIfPresent(Double.self, forKey: .titleSize) ?? titleSize
        gelWidthIn = try c.decodeIfPresent(Double.self, forKey: .gelWidthIn) ?? gelWidthIn
        tickLenPt = try c.decodeIfPresent(Double.self, forKey: .tickLenPt) ?? tickLenPt
        lineWidthPt = try c.decodeIfPresent(Double.self, forKey: .lineWidthPt) ?? lineWidthPt
        border = try c.decodeIfPresent(Bool.self, forKey: .border) ?? border
        rowGapPt = try c.decodeIfPresent(Double.self, forKey: .rowGapPt) ?? rowGapPt
        groupLineInset = try c.decodeIfPresent(Double.self, forKey: .groupLineInset) ?? groupLineInset
        labelSep = try c.decodeIfPresent(Double.self, forKey: .labelSep) ?? labelSep
        leaderPt = try c.decodeIfPresent(Double.self, forKey: .leaderPt) ?? leaderPt
        laneLabelSize = try c.decodeIfPresent(Double.self, forKey: .laneLabelSize)
        groupLabelSize = try c.decodeIfPresent(Double.self, forKey: .groupLabelSize)
        rowNameSize = try c.decodeIfPresent(Double.self, forKey: .rowNameSize)
        ladderLabelSize = try c.decodeIfPresent(Double.self, forKey: .ladderLabelSize)
        nameSize = try c.decodeIfPresent(Double.self, forKey: .nameSize)
        textSizes = try c.decodeIfPresent([String: Double].self, forKey: .textSizes) ?? [:]
        exportDPI = try c.decodeIfPresent(Double.self, forKey: .exportDPI)
    }

    /// Size of one piece of text: its own override, else its kind's size.
    public func size(for role: FigureRole) -> Double {
        role.sizeKey.flatMap { textSizes[$0] } ?? size(for: TextKind(role: role))
    }

    public mutating func setSize(_ v: Double, forLabel role: FigureRole) {
        guard let k = role.sizeKey else { setSize(v, for: TextKind(role: role)); return }
        textSizes[k] = min(max((v * 2).rounded() / 2, 3), 48)
    }
}

extension GelProject {
    public static func encoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return e
    }
}

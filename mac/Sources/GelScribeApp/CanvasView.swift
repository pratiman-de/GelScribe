import AppKit
import GelKit
import SwiftUI

/// Pixelmator-style canvas: the real figure on a dark backdrop, with editing guides drawn on top.
struct CanvasView: NSViewRepresentable {
    let workspace: Workspace
    // Passed so SwiftUI re-runs updateNSView whenever any of these change.
    let project: GelProject
    let tool: Tool
    let selection: Selection?
    let showGuides: Bool
    let enhanceView: Bool
    let inspectorVisible: Bool
    let zoomRequest: Workspace.ZoomRequest?
    let activeStrip: Int?
    let stripSizes: [CGSize?]
    let showsGel: Bool

    func makeNSView(context: Context) -> CanvasNSView {
        let v = CanvasNSView()
        v.workspace = workspace
        return v
    }

    func updateNSView(_ v: CanvasNSView, context: Context) {
        v.workspace = workspace
        if v.lastTool != tool {
            // crop/straighten work on the whole image, everything else on the figure: different units, so re-fit (a gel
            // that's on view by itself is the whole image whatever the tool)
            if (v.lastTool?.usesFullImage ?? false) != tool.usesFullImage, !workspace.viewsOtherGel { v.fitToWindow() }
            v.lastTool = tool
        }
        if v.lastActive != activeStrip {
            if tool.usesFullImage, !showsGel { v.fitToWindow() }   // crop/straighten show the active piece: another size
            v.lastActive = activeStrip
        }
        if let z = zoomRequest {
            v.handle(z)
            DispatchQueue.main.async { workspace.zoomRequest = nil }
        }
        v.needsDisplay = true
    }
}

final class CanvasNSView: NSView {
    var workspace: Workspace?
    var lastTool: Tool?
    var lastActive: Int?

    // view state
    private var zoom: CGFloat?          // nil = fit
    private var pan = CGPoint.zero
    /// A gel is being dragged sideways (see `DragState.strip`): the view slides freely to keep it under the pointer.
    private var holdingGel: Bool { if case .strip? = drag { true } else { false } }
    private var hover: CGPoint?
    private var spaceDown = false
    private var drag: DragState?
    /// A press on a tick or band name: a click (no movement) opens its editor, a drag moves it.
    private var press: (at: CGPoint, target: Selection)?
    private var tracking: NSTrackingArea?
    private var popover: NSPopover?

    private enum DividerPart { case body, top, bottom }
    private enum CropHandle { case new, move, left, right, top, bottom, topLeft, topRight, bottomLeft, bottomRight }
    private enum DragState {
        case pan(start: CGPoint, startPan: CGPoint)
        case divider(id: UUID, part: DividerPart, start: LaneDivider, startPx: CGPoint)
        case tick(id: UUID)
        case name(id: UUID)
        case crop(handle: CropHandle, startRect: PixelRect, startPx: CGPoint)
        case level(start: CGPoint, end: CGPoint)
        /// The ladder's unit label ("kDa") moving up or down; figure rows (it lands on the gel under the pointer).
        case unit(startY: Double, startView: CGPoint)
        /// A gel moving sideways (`k` nil = the gel with the lanes): its shift when the drag began, where the pointer began (view
        /// points), how many view points a figure pixel was then, the gel's own column that was under the pointer, and the zoom
        /// the view had (nil = fit). The figure can change width as a gel moves (it runs from the leftmost to the rightmost column
        /// any gel keeps), so the pointer's distance is measured at the scale the drag began with, the view keeps that scale
        /// while the gel is held, and slides so the gel stays under the pointer and the other gels stay where they were.
        case strip(k: Int?, startShift: Double, startView: CGPoint, pointsPerPx: CGFloat, column: Double, zoomed: CGFloat?)
    }

    // palette
    static let laneColor = NSColor(red: 0.35, green: 0.80, blue: 1.00, alpha: 1)
    static let tickColor = NSColor(red: 1.00, green: 0.82, blue: 0.10, alpha: 1)
    static let nameColor = NSColor(red: 1.00, green: 0.40, blue: 0.55, alpha: 1)

    override var isFlipped: Bool { true }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); needsDisplay = true }
    /// The white page's shadow: lighter on the light backdrop.
    private var pageShadow: CGColor { CGColor(gray: 0, alpha: effectiveAppearance.isDark ? 0.6 : 0.32) }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let t = NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect, .cursorUpdate],
                               owner: self, userInfo: nil)
        addTrackingArea(t)
        tracking = t
    }

    // MARK: geometry

    private struct Mapping {
        var origin: CGPoint
        var scale: CGFloat
        func view(_ p: CGPoint) -> CGPoint { CGPoint(x: origin.x + p.x * scale, y: origin.y + p.y * scale) }
        func model(_ p: CGPoint) -> CGPoint { CGPoint(x: (p.x - origin.x) / scale, y: (p.y - origin.y) / scale) }
        func view(_ r: CGRect) -> CGRect { CGRect(origin: view(r.origin), size: CGSize(width: r.width * scale, height: r.height * scale)) }
    }

    private var cropMode: Bool { workspace?.tool.usesFullImage ?? false }
    /// Another gel than the one with the lanes is on view by itself (and not being cropped or straightened, which show it whole
    /// too): its whole image, with its ticks and names and its lanes dashed through the alignment.
    private var stripMode: Bool { !cropMode && (workspace?.viewsOtherGel ?? false) }

    /// Space not covered by the floating palettes or the title bar (the canvas runs under the bar's glass).
    private var available: CGRect {
        let right: CGFloat = (workspace?.inspectorVisible ?? true) ? 352 : 32
        // the gel switcher floats above the canvas, under the title bar: the figure starts below it
        let top = max(24, safeAreaInsets.top + 12, (workspace?.project.strips.isEmpty ?? true) ? 0 : 100)
        // a gel on view by itself is shown whole, so its band names (outside its right edge) and sizes need room at the sides
        let side: CGFloat = (workspace?.viewsOtherGel ?? false) ? 120 : 0
        return CGRect(x: 92 + side, y: top, width: max(100, bounds.width - 92 - right - 2 * side), height: max(100, bounds.height - top - 76))
    }

    private var contentSize: CGSize {
        guard let ws = workspace else { return CGSize(width: 1, height: 1) }
        if cropMode || stripMode { let a = ws.activeSize; return CGSize(width: max(1, a.width), height: max(1, a.height)) }
        return ws.shownLayout?.size ?? CGSize(width: 1, height: 1)
    }

    private var fitScale: CGFloat {
        let s = contentSize, a = available
        return min(a.width / s.width, a.height / s.height)
    }

    private var mapping: Mapping {
        let s = contentSize, a = available
        let sc = zoom ?? fitScale
        let pan = clamped(self.pan, scale: sc)
        return Mapping(origin: CGPoint(x: (a.midX - s.width * sc / 2 + pan.x).rounded(),
                                       y: (a.midY - s.height * sc / 2 + pan.y).rounded()), scale: sc)
    }

    /// Pan stays on screen: a figure smaller than the view can move up to the view's edges, a larger one until its
    /// own edge comes into view. Applied when drawing, so a resize or zoom never strands it out of sight.
    private func clamped(_ p: CGPoint, scale sc: CGFloat) -> CGPoint {
        if holdingGel { return p }   // a gel is being dragged: the figure slides under it as far as it has to
        let s = contentSize, a = available, margin: CGFloat = 20
        let lx = abs(a.width - s.width * sc) / 2 + margin, ly = abs(a.height - s.height * sc) / 2 + margin
        return CGPoint(x: min(lx, max(-lx, p.x)), y: min(ly, max(-ly, p.y)))
    }

    /// The pan in use, after clamping.
    private var shownPan: CGPoint { clamped(pan, scale: zoom ?? fitScale) }

    func fitToWindow() { zoom = nil; pan = .zero; needsDisplay = true }

    func handle(_ z: Workspace.ZoomRequest) {
        switch z {
        case .fit: fitToWindow()
        case .actual:
            // 1 gel pixel = 1 screen pixel
            if let l = workspace?.shownLayout, !cropMode, !stripMode {
                zoom = 1 / (l.ptPerPx * (window?.backingScaleFactor ?? 2))
            } else { zoom = 1 / (window?.backingScaleFactor ?? 2) }
        case .zoomIn: zoom(by: 1.25, around: CGPoint(x: available.midX, y: available.midY))
        case .zoomOut: zoom(by: 0.8, around: CGPoint(x: available.midX, y: available.midY))
        }
        needsDisplay = true
    }

    private func zoom(by f: CGFloat, around p: CGPoint) {
        let m = mapping
        let model = m.model(p)
        let ns = min(60, max(0.05, m.scale * f))
        let s = contentSize, a = available
        let centered = CGPoint(x: a.midX - s.width * ns / 2, y: a.midY - s.height * ns / 2)
        pan = clamped(CGPoint(x: p.x - model.x * ns - centered.x, y: p.y - model.y * ns - centered.y), scale: ns)
        zoom = ns
        needsDisplay = true
    }

    var zoomPercent: Int { Int(((zoom ?? fitScale) * 100).rounded()) }

    /// Where figure column `x` (counted in the gel with the lanes' pixels, as the layout does) and row `y` are on the canvas, in view
    /// points. For tests, which check that a gel that is being dragged stays under the pointer.
    func viewPoint(figureX x: Double, y: Double) -> CGPoint? {
        workspace?.shownLayout.map { pxToView(x, y, $0, mapping) }
    }

    // figure-mode conversions
    private func pxToView(_ x: Double, _ y: Double, _ l: FigureLayout, _ m: Mapping) -> CGPoint { m.view(l.point(x: x, y: y)) }
    private func viewToPx(_ p: CGPoint, _ l: FigureLayout, _ m: Mapping) -> CGPoint {
        let q = l.pixel(m.model(p))
        return CGPoint(x: q.x, y: q.y)
    }

    // MARK: drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        ctx.setFillColor(Chrome.backdrop.cgColor)   // draw(_:) runs in the view's appearance, so this resolves to it
        ctx.fill(bounds)
        guard let ws = workspace else { return }
        ws.refreshCaches()
        guard ws.working != nil else { return }
        if cropMode {
            if ws.tool == .straighten { drawStraighten(ctx, ws) } else { drawCrop(ctx, ws) }
            return
        }
        if stripMode { drawStripView(ctx, ws); return }
        guard let layout = ws.shownLayout else { return }
        let m = mapping
        let page = m.view(CGRect(origin: .zero, size: layout.size))

        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: 10), blur: 34, color: pageShadow)
        ctx.setFillColor(.white)
        ctx.fill(page)
        ctx.restoreGState()

        ctx.saveGState()
        ctx.clip(to: page)
        ctx.translateBy(x: m.origin.x, y: m.origin.y)
        ctx.scaleBy(x: m.scale, y: m.scale)
        let screenPxPerGelPx = m.scale * layout.ptPerPx * (window?.backingScaleFactor ?? 2)
        FigureRenderer.draw(layout, gel: ws.shownImage, in: ctx, interpolate: screenPxPerGelPx < 1)
        ctx.restoreGState()

        if ws.showGuides { drawGuides(ctx, ws, layout, m) }
    }

    private func drawGuides(_ ctx: CGContext, _ ws: Workspace, _ l: FigureLayout, _ m: Mapping) {
        let p = ws.project
        let crop = ws.crop
        let stack = ws.shownStack
        let H = Double(ws.imageHeight)
        let gel = m.view(l.gelRect)
        let tool = ws.tool

        // with strips, the piece the inspector and crop/straighten act on
        if stack.hasStrips, let piece = stack.piece(strip: ws.activeStrip) {
            let a = pxToView(piece.left, piece.top, l, m), b = pxToView(piece.right, piece.bottom, l, m)   // what it keeps of the figure
            let r = CGRect(x: a.x - 3, y: a.y - 3, width: b.x - a.x + 6, height: b.y - a.y + 6)
            ctx.setStrokeColor(NSColor.controlAccentColor.withAlphaComponent(0.9).cgColor)
            ctx.setLineWidth(2)
            ctx.addPath(CGPath(roundedRect: r, cornerWidth: 3, cornerHeight: 3, transform: nil))
            ctx.strokePath()
        }

        // lane dividers: in the main image as placed; through the strips straight down from the top of the crop, where
        // the strips' lanes were lined up
        ctx.saveGState()
        for d in p.lanes.dividers {
            let top = pxToView(d.x(atY: crop.y0, height: H), crop.y0, l, m)
            let bot = pxToView(d.x(atY: crop.y1, height: H), crop.y1, l, m)
            let sel = ws.selection == .divider(d.id)
            let faded = !(tool == .lanes || tool == .select || sel)
            let color = Self.laneColor.withAlphaComponent(faded ? 0.35 : 0.95).cgColor
            strokeLine(ctx, top, bot, color: CGColor(gray: 0, alpha: faded ? 0.15 : 0.35), width: sel ? 4 : 3)
            strokeLine(ctx, top, bot, color: color, width: sel ? 2 : 1.25)
            for piece in stack.pieces where piece.strip != nil {
                let a = pxToView(d.x(atY: crop.y0, height: H), piece.top, l, m)
                let b = pxToView(d.x(atY: crop.y0, height: H), piece.bottom, l, m)
                strokeLine(ctx, a, b, color: CGColor(gray: 0, alpha: faded ? 0.12 : 0.3), width: 3)
                strokeLine(ctx, a, b, color: Self.laneColor.withAlphaComponent(faded ? 0.3 : 0.75).cgColor, width: 1, dash: true)
            }
            let dy = min(max(d.dotY, crop.y0), crop.y1)
            let dot = pxToView(d.x(atY: dy, height: H), dy, l, m)
            circle(ctx, dot, r: sel ? 6 : 5, fill: color, stroke: CGColor(gray: 1, alpha: faded ? 0.4 : 1), width: 1.5)
            if !faded {
                handle(ctx, top, color: color)
                handle(ctx, bot, color: color)
            }
        }
        ctx.restoreGState()

        // lane numbers while placing dividers
        if tool == .lanes, let g = ws.geometry, g.count > 0 {
            for n in 1...g.count {
                let c = pxToView(g.center(n, atY: crop.y0), crop.y0, l, m)
                badge("\(n)", at: CGPoint(x: c.x, y: gel.minY + 14), color: Self.laneColor, textColor: .black)
            }
        }

        // ladder ticks, each in its own piece
        if let ladder = p.ladder, tool == .ladder || tool == .select {
            for b in ladder.bands {
                guard let fy = stack.figureY(strip: b.strip, y: b.y) else { continue }   // outside the crop: not in the figure
                let ry = b.strip == nil ? b.y : crop.y0   // a strip's lanes run straight down from the crop's top
                let y = pxToView(0, fy, l, m).y
                var x0 = gel.minX, x1 = gel.minX + gel.width * 0.12
                if let g = ws.geometry, ladder.lane >= 1, ladder.lane <= g.count {
                    x0 = pxToView(g.x(g.boundaries[ladder.lane - 1], atY: ry), fy, l, m).x
                    x1 = pxToView(g.x(g.boundaries[ladder.lane], atY: ry), fy, l, m).x
                }
                let sel = ws.selection == .tick(b.id)
                let c = (b.ignore || b.size == nil ? NSColor.systemGray : Self.tickColor).withAlphaComponent(0.95).cgColor
                strokeLine(ctx, CGPoint(x: x0, y: y), CGPoint(x: x1, y: y), color: CGColor(gray: 0, alpha: 0.35), width: sel ? 4 : 3)
                strokeLine(ctx, CGPoint(x: x0, y: y), CGPoint(x: x1, y: y), color: c, width: sel ? 2 : 1.25, dash: b.size == nil)
                if b.ignore {
                    badge("skip", at: CGPoint(x: x1 + 16, y: y), color: .systemGray, textColor: .black)
                } else if b.auto, let sz = b.size {
                    // a guess until confirmed: outlined, with a question mark
                    outlineBadge(FigureLayoutEngine.formatSize(sz) + "?", at: CGPoint(x: x1 + 16, y: y), color: Self.tickColor)
                } else {
                    badge(b.size.map(FigureLayoutEngine.formatSize) ?? "–", at: CGPoint(x: x1 + 14, y: y),
                          color: b.size == nil ? .systemGray : Self.tickColor, textColor: .black)
                }
            }
        }

        // selected label (for sizing); a slanted one is outlined along its own box, not the bounds around it
        if case .text(let role)? = ws.selection {
            for t in l.texts where t.role == role {
                let outline: CGPath
                if t.rotation == 0 {
                    outline = CGPath(roundedRect: m.view(t.bounds).insetBy(dx: -3, dy: -2), cornerWidth: 3, cornerHeight: 3, transform: nil)
                } else {
                    let path = CGMutablePath()
                    path.addLines(between: t.box.map { m.view($0) })
                    path.closeSubpath()
                    outline = path
                }
                ctx.setStrokeColor(NSColor.controlAccentColor.cgColor)
                ctx.setLineWidth(1.5)
                ctx.addPath(outline)
                ctx.strokePath()
                ctx.setFillColor(NSColor.controlAccentColor.withAlphaComponent(0.12).cgColor)
                ctx.addPath(outline)
                ctx.fillPath()
            }
        }

        // band names
        if tool == .names || tool == .select {
            for a in p.annotations {
                guard let fy = stack.nameY(strip: a.strip, y: a.y) else { continue }
                let y = pxToView(0, fy, l, m).y
                let x = a.side == .right ? gel.maxX : gel.minX
                let sel = ws.selection == .name(a.id)
                let r = CGRect(x: a.side == .right ? x - 4 : x - 60, y: y - 7, width: 64, height: 14)
                ctx.setStrokeColor(Self.nameColor.withAlphaComponent(sel ? 1 : 0.8).cgColor)
                ctx.setLineWidth(sel ? 2 : 1.25)
                ctx.addPath(CGPath(roundedRect: r, cornerWidth: 5, cornerHeight: 5, transform: nil))
                ctx.strokePath()
            }
        }

        // placing the unit label: where it would go
        if ws.placingUnit, let h = hover {
            let left = p.ladder?.side != .right
            let edge = left ? gel.minX : gel.maxX
            strokeLine(ctx, CGPoint(x: left ? edge - 60 : edge, y: h.y), CGPoint(x: left ? edge : edge + 60, y: h.y),
                       color: Self.tickColor.withAlphaComponent(0.8).cgColor, width: 1.25, dash: true)
            badge(p.ladder?.unit ?? "kDa", at: CGPoint(x: left ? edge - 76 : edge + 76, y: h.y), color: Self.tickColor, textColor: .black)
            return
        }

        // ghost previews under the cursor
        guard let h = hover, drag == nil, gel.insetBy(dx: -1, dy: -1).contains(h) else { return }
        let px = viewToPx(h, l, m)
        let free = NSEvent.modifierFlags.contains(.option)
        switch tool {
        case .lanes:
            let hitting = hitDivider(h, ws, l, m) != nil
            if !hitting {
                strokeLine(ctx, CGPoint(x: h.x, y: gel.minY), CGPoint(x: h.x, y: gel.maxY),
                           color: Self.laneColor.withAlphaComponent(0.6).cgColor, width: 1, dash: true)
                circle(ctx, h, r: 4, fill: Self.laneColor.withAlphaComponent(0.6).cgColor, stroke: CGColor(gray: 1, alpha: 0.7), width: 1)
            }
        case .ladder:
            guard hitTick(h, ws, l, m) == nil else { return }
            let snap = ws.snapInFigure(x: px.x, y: px.y, free: free)
            let vy = pxToView(0, snap.figureY, l, m).y
            let ry = snap.strip == nil ? snap.y : crop.y0
            var x0 = h.x - 40, x1 = h.x + 40
            if let g = ws.geometry, let lane = g.lane(atX: px.x, y: ry) {
                x0 = pxToView(g.x(g.boundaries[lane - 1], atY: ry), snap.figureY, l, m).x
                x1 = pxToView(g.x(g.boundaries[lane], atY: ry), snap.figureY, l, m).x
            }
            strokeLine(ctx, CGPoint(x: x0, y: vy), CGPoint(x: x1, y: vy), color: Self.tickColor.withAlphaComponent(0.75).cgColor, width: 1.25, dash: true)
            if let s = ws.suggestedSize(forY: snap.y, strip: snap.strip) {
                badge(FigureLayoutEngine.formatSize(s), at: CGPoint(x: x1 + 14, y: vy), color: Self.tickColor.withAlphaComponent(0.75), textColor: .black)
            }
        case .names:
            guard hitName(h, ws, l, m) == nil else { return }
            let vy = pxToView(0, ws.snapInFigure(x: px.x, y: px.y, free: free).figureY, l, m).y
            let side: LadderSide = ws.project.ladder?.side == .right ? .left : .right
            let ex = side == .right ? gel.maxX : gel.minX
            let dir: CGFloat = side == .right ? 1 : -1
            ctx.setFillColor(Self.nameColor.withAlphaComponent(0.8).cgColor)
            ctx.beginPath()
            ctx.move(to: CGPoint(x: ex + dir * 3, y: vy))
            ctx.addLine(to: CGPoint(x: ex + dir * 13, y: vy - 5))
            ctx.addLine(to: CGPoint(x: ex + dir * 13, y: vy + 5))
            ctx.closePath()
            ctx.fillPath()
            strokeLine(ctx, CGPoint(x: gel.minX, y: vy), CGPoint(x: gel.maxX, y: vy), color: Self.nameColor.withAlphaComponent(0.35).cgColor, width: 1, dash: true)
        default: break
        }
    }

    /// The active gel's whole working image on its page (crop, straighten and the view of a stacked gel), as a view rect.
    private func drawWholeImage(_ ctx: CGContext, _ img: CGImage, _ size: (width: Int, height: Int), _ m: Mapping) -> CGRect {
        let r = m.view(CGRect(x: 0, y: 0, width: Double(size.width), height: Double(size.height)))
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: 10), blur: 34, color: pageShadow)
        ctx.setFillColor(.white); ctx.fill(r)
        ctx.restoreGState()
        ctx.saveGState()
        ctx.interpolationQuality = m.scale * (window?.backingScaleFactor ?? 2) < 1 ? .high : .none
        ctx.translateBy(x: r.minX, y: r.maxY)
        ctx.scaleBy(x: 1, y: -1)
        ctx.draw(img, in: CGRect(origin: .zero, size: r.size))
        ctx.restoreGState()
        return r
    }

    private func drawCrop(_ ctx: CGContext, _ ws: Workspace) {
        guard let img = ws.activeView else { return }
        let m = mapping
        let size = ws.activeSize
        let H = Double(size.height)
        let r = drawWholeImage(ctx, img, size, m)

        let c = ws.activeStripRect ?? ws.crop
        let cr = m.view(CGRect(x: c.x0, y: c.y0, width: c.width, height: c.height))
        ctx.saveGState()
        ctx.addRect(r); ctx.addRect(cr)
        ctx.setFillColor(CGColor(gray: 0, alpha: 0.55))
        ctx.fillPath(using: .evenOdd)
        ctx.restoreGState()

        // dividers faintly, to crop around the lanes; on a stacked gel, where its lanes were lined up
        if let k = ws.activeStrip, let piece = ws.shownStack.piece(strip: k) {
            for d in ws.project.lanes.dividers {
                let x = piece.scale * d.x(atY: ws.crop.y0, height: Double(ws.imageHeight)) + piece.shift
                strokeLine(ctx, m.view(CGPoint(x: x, y: 0)), m.view(CGPoint(x: x, y: H)),
                           color: Self.laneColor.withAlphaComponent(0.45).cgColor, width: 1)
            }
        } else {
            for d in ws.project.lanes.dividers {
                strokeLine(ctx, m.view(CGPoint(x: d.xTop, y: 0)), m.view(CGPoint(x: d.xBottom, y: H)),
                           color: Self.laneColor.withAlphaComponent(0.45).cgColor, width: 1)
            }
        }

        ctx.setStrokeColor(.white); ctx.setLineWidth(1.5); ctx.stroke(cr)
        let L: CGFloat = 16
        ctx.setLineWidth(4)
        for (pt, dx, dy) in [(CGPoint(x: cr.minX, y: cr.minY), 1.0, 1.0), (CGPoint(x: cr.maxX, y: cr.minY), -1.0, 1.0),
                             (CGPoint(x: cr.minX, y: cr.maxY), 1.0, -1.0), (CGPoint(x: cr.maxX, y: cr.maxY), -1.0, -1.0)] {
            ctx.beginPath()
            ctx.move(to: CGPoint(x: pt.x + dx * L, y: pt.y))
            ctx.addLine(to: pt)
            ctx.addLine(to: CGPoint(x: pt.x, y: pt.y + dy * L))
            ctx.strokePath()
        }
        for mid in [CGPoint(x: cr.midX, y: cr.minY), CGPoint(x: cr.midX, y: cr.maxY), CGPoint(x: cr.minX, y: cr.midY), CGPoint(x: cr.maxX, y: cr.midY)] {
            handle(ctx, mid, color: .white)
        }
        badge((ws.activeStrip == nil ? "" : ws.gelName(ws.activeStrip) + " · ") + "\(Int(c.width)) × \(Int(c.height)) px",
              at: CGPoint(x: cr.midX, y: cr.maxY + 18), color: NSColor(white: 0.18, alpha: 0.95), textColor: .white)
    }

    private func drawStraighten(_ ctx: CGContext, _ ws: Workspace) {
        guard let img = ws.activeView else { return }
        let m = mapping
        let r = drawWholeImage(ctx, img, ws.activeSize, m)
        // a square grid, fixed while the image turns under it: rows for band rows, columns for lane edges
        ctx.saveGState()
        ctx.clip(to: r)
        let grid = CGColor(red: 0.3, green: 0.8, blue: 1, alpha: 0.32)
        let step = r.height / 12
        for k in 1..<12 {
            let y = r.minY + step * CGFloat(k)
            strokeLine(ctx, CGPoint(x: r.minX, y: y), CGPoint(x: r.maxX, y: y), color: grid, width: 1)
        }
        var x = r.minX + step
        while x < r.maxX - 1 {
            strokeLine(ctx, CGPoint(x: x, y: r.minY), CGPoint(x: x, y: r.maxY), color: grid, width: 1)
            x += step
        }
        ctx.restoreGState()
        if case .level(let a, let b)? = drag {
            let va = m.view(a), vb = m.view(b)
            strokeLine(ctx, va, vb, color: CGColor(gray: 0, alpha: 0.5), width: 4)
            strokeLine(ctx, va, vb, color: Self.laneColor.cgColor, width: 2)
            circle(ctx, va, r: 4, fill: Self.laneColor.cgColor, stroke: .white, width: 1.5)
            circle(ctx, vb, r: 4, fill: Self.laneColor.cgColor, stroke: .white, width: 1.5)
            let d = GelOps.levelingAngle(from: (Double(a.x), Double(a.y)), to: (Double(b.x), Double(b.y)))
            badge(String(format: "%+.2f°", d), at: CGPoint(x: (va.x + vb.x) / 2, y: (va.y + vb.y) / 2 - 18),
                  color: NSColor(white: 0.15, alpha: 0.95), textColor: .white)
        } else {
            let a = String(format: "%.2f°", ws.activeStrict ? 0 : ws.activeRotation)
            let piece = ws.project.strips.isEmpty ? "" : ws.activeName + " · "
            badge(piece + "Rotation \(a)" + (ws.activeStrict ? " · keeps original pixels" : ""), at: CGPoint(x: r.midX, y: r.maxY + 18),
                  color: NSColor(white: 0.18, alpha: 0.95), textColor: .white)
        }
    }

    // MARK: a stacked gel on its own

    /// A tick of the gel on view as it's drawn (view points): across the ladder lane's columns, through the alignment.
    private struct StripTick { var id: UUID; var band: LadderBand; var y: CGFloat; var x0: CGFloat; var x1: CGFloat }
    private struct StripName { var id: UUID; var name: BandAnnotation; var y: CGFloat; var x: CGFloat }

    /// The ladder lane's columns in gel `k`'s own pixels (the lanes are the gel with the lanes', lined up through the
    /// alignment); before there are lanes, a strip at the left of what the figure shows.
    private func ladderColumns(_ ws: Workspace, _ k: Int) -> (a: Double, b: Double) {
        let used = ws.activeStripRect ?? ws.crop
        guard let piece = ws.shownStack.piece(strip: k), let g = ws.geometry, let l = ws.project.ladder, l.lane >= 1, l.lane <= g.count
        else { return (used.x0, used.x0 + used.width * 0.12) }
        return (piece.scale * g.x(g.boundaries[l.lane - 1], atY: ws.crop.y0) + piece.shift,
                piece.scale * g.x(g.boundaries[l.lane], atY: ws.crop.y0) + piece.shift)
    }

    private func stripTicks(_ ws: Workspace, _ k: Int, _ m: Mapping) -> [StripTick] {
        guard let ladder = ws.project.ladder else { return [] }
        let c = ladderColumns(ws, k)
        let x0 = m.view(CGPoint(x: c.a, y: 0)).x, x1 = m.view(CGPoint(x: c.b, y: 0)).x
        return ladder.bands.filter { $0.strip == k }.map { StripTick(id: $0.id, band: $0, y: m.view(CGPoint(x: 0, y: $0.y)).y, x0: x0, x1: x1) }
    }

    private func stripNames(_ ws: Workspace, _ k: Int, _ m: Mapping) -> [StripName] {
        let used = ws.activeStripRect ?? ws.crop
        return ws.project.annotations.filter { $0.strip == k }.map {
            StripName(id: $0.id, name: $0, y: m.view(CGPoint(x: 0, y: $0.y)).y,
                      x: m.view(CGPoint(x: $0.side == .right ? used.x1 : used.x0, y: 0)).x)
        }
    }

    private func hitStripTick(_ p: CGPoint, _ ws: Workspace, _ k: Int, _ m: Mapping) -> UUID? {
        var best: (UUID, CGFloat)?
        for t in stripTicks(ws, k, m) {
            let d = abs(p.y - t.y)
            if d < 6, p.x >= min(t.x0, t.x1) - 50, p.x <= max(t.x0, t.x1) + 30, best == nil || d < best!.1 { best = (t.id, d) }
        }
        return best?.0
    }

    private func hitStripName(_ p: CGPoint, _ ws: Workspace, _ k: Int, _ m: Mapping) -> UUID? {
        var best: (UUID, CGFloat)?
        for n in stripNames(ws, k, m) {
            let inX = n.name.side == .right ? (p.x > n.x - 16 && p.x < n.x + 140) : (p.x < n.x + 16 && p.x > n.x - 140)
            let d = abs(p.y - n.y)
            if inX, d < 8, best == nil || d < best!.1 { best = (n.id, d) }
        }
        return best?.0
    }

    /// The gel on view by itself: its whole working image (turned, rotated, with its brightness & contrast), what goes into the
    /// figure outlined and the rest dimmed, its lanes dashed through the alignment, its ticks and names.
    private func drawStripView(_ ctx: CGContext, _ ws: Workspace) {
        guard let k = ws.activeStrip, let img = ws.activeView, let piece = ws.shownStack.piece(strip: k) else { return }
        let m = mapping
        let size = ws.activeSize
        let r = drawWholeImage(ctx, img, size, m)
        let used = ws.activeStripRect ?? ws.crop
        // what the figure takes of this gel (its columns can reach past the gel's edge when it's shifted): outlined, the rest dimmed
        let cr = m.view(CGRect(x: used.x0, y: used.y0, width: used.width, height: used.height)).intersection(r)
        ctx.saveGState()
        ctx.clip(to: r)
        ctx.addRect(r); ctx.addRect(cr)
        ctx.setFillColor(CGColor(gray: 0, alpha: 0.55))
        ctx.fillPath(using: .evenOdd)
        ctx.restoreGState()
        ctx.setStrokeColor(NSColor.controlAccentColor.withAlphaComponent(0.9).cgColor)
        ctx.setLineWidth(1.5)
        ctx.stroke(cr)
        // the lanes, where they were lined up
        if ws.showGuides {
            ctx.saveGState()
            ctx.clip(to: r)
            for d in ws.project.lanes.dividers {
                let x = piece.scale * d.x(atY: ws.crop.y0, height: Double(ws.imageHeight)) + piece.shift
                let a = m.view(CGPoint(x: x, y: 0)), b = m.view(CGPoint(x: x, y: Double(size.height)))
                strokeLine(ctx, a, b, color: CGColor(gray: 0, alpha: 0.3), width: 3)
                strokeLine(ctx, a, b, color: Self.laneColor.withAlphaComponent(0.85).cgColor, width: 1, dash: true)
            }
            ctx.restoreGState()
        }
        // ladder ticks, with the sizes; a tick the figure doesn't show (outside its rows) is faint
        if ws.tool == .ladder || ws.tool == .select {
            for t in stripTicks(ws, k, m) {
                let b = t.band, sel = ws.selection == .tick(b.id)
                let alpha: CGFloat = b.y >= used.y0 && b.y <= used.y1 ? 0.95 : 0.45
                let c = (b.ignore || b.size == nil ? NSColor.systemGray : Self.tickColor).withAlphaComponent(alpha).cgColor
                strokeLine(ctx, CGPoint(x: t.x0, y: t.y), CGPoint(x: t.x1, y: t.y), color: CGColor(gray: 0, alpha: 0.35), width: sel ? 4 : 3)
                strokeLine(ctx, CGPoint(x: t.x0, y: t.y), CGPoint(x: t.x1, y: t.y), color: c, width: sel ? 2 : 1.25, dash: b.size == nil)
                let at = CGPoint(x: max(t.x0, t.x1) + 16, y: t.y)
                if b.ignore { badge("skip", at: at, color: .systemGray, textColor: .black) }
                else if b.auto, let sz = b.size { outlineBadge(FigureLayoutEngine.formatSize(sz) + "?", at: at, color: Self.tickColor) }
                else { badge(b.size.map(FigureLayoutEngine.formatSize) ?? "–", at: at, color: b.size == nil ? .systemGray : Self.tickColor, textColor: .black) }
            }
        }
        // band names, at the edge of what the figure shows
        if ws.tool == .names || ws.tool == .select {
            for n in stripNames(ws, k, m) {
                let sel = ws.selection == .name(n.id), right = n.name.side == .right
                let box = CGRect(x: right ? n.x - 4 : n.x - 60, y: n.y - 7, width: 64, height: 14)
                ctx.setStrokeColor(Self.nameColor.withAlphaComponent(sel ? 1 : 0.8).cgColor)
                ctx.setLineWidth(sel ? 2 : 1.25)
                ctx.addPath(CGPath(roundedRect: box, cornerWidth: 5, cornerHeight: 5, transform: nil))
                ctx.strokePath()
                if !n.name.text.isEmpty {
                    let w = (n.name.text as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 10, weight: .semibold)]).width
                    outlineBadge(n.name.text, at: CGPoint(x: n.x + (right ? 14 + w / 2 : -(14 + w / 2)), y: n.y), color: Self.nameColor)
                }
            }
        }
        // the tick or name about to be placed, under the pointer
        if let h = hover, drag == nil, r.contains(h), !ws.placingUnit {
            let q = m.model(h), free = NSEvent.modifierFlags.contains(.option)
            switch ws.tool {
            case .ladder where hitStripTick(h, ws, k, m) == nil:
                let y = ws.snapInGel(strip: k, x: q.x, y: q.y, free: free), vy = m.view(CGPoint(x: 0, y: y)).y
                let c = ladderColumns(ws, k), x0 = m.view(CGPoint(x: c.a, y: 0)).x, x1 = m.view(CGPoint(x: c.b, y: 0)).x
                strokeLine(ctx, CGPoint(x: x0, y: vy), CGPoint(x: x1, y: vy), color: Self.tickColor.withAlphaComponent(0.75).cgColor, width: 1.25, dash: true)
                if let sz = ws.suggestedSize(forY: y, strip: k) {
                    badge(FigureLayoutEngine.formatSize(sz), at: CGPoint(x: max(x0, x1) + 14, y: vy), color: Self.tickColor.withAlphaComponent(0.75), textColor: .black)
                }
            case .names where hitStripName(h, ws, k, m) == nil:
                let y = ws.snapInGel(strip: k, x: q.x, y: q.y, free: free), vy = m.view(CGPoint(x: 0, y: y)).y
                strokeLine(ctx, CGPoint(x: cr.minX, y: vy), CGPoint(x: cr.maxX, y: vy), color: Self.nameColor.withAlphaComponent(0.35).cgColor, width: 1, dash: true)
            default: break
            }
        }
        badge("\(ws.gelName(k)) · rows \(Int(used.y0))–\(Int(used.y1)) of \(size.height)", at: CGPoint(x: r.midX, y: r.maxY + 18),
              color: NSColor(white: 0.18, alpha: 0.95), textColor: .white)
    }

    /// A press on the gel on view: ticks and names are picked up and placed on the gel's own pixels.
    private func stripMouseDown(_ p: CGPoint, _ e: NSEvent, _ ws: Workspace) {
        guard let k = ws.activeStrip else { return }
        let m = mapping, q = m.model(p), size = ws.activeSize
        let inside = q.x >= 0 && q.y >= 0 && q.x <= Double(size.width) && q.y <= Double(size.height)
        let free = e.modifierFlags.contains(.option)
        if ws.placingUnit {   // "Place…" in the Ladder tab: this click sets the unit label's height on this gel
            ws.placingUnit = false
            ws.setUnitY(ws.clampedY(q.y, strip: k).rounded(), strip: k)
            needsDisplay = true
            return
        }
        let tick = hitStripTick(p, ws, k, m), name = hitStripName(p, ws, k, m)
        switch ws.tool {
        case .ladder, .select:
            if let id = tick {
                ws.selection = .tick(id); press = (p, .tick(id)); drag = .tick(id: id)
            } else if ws.tool == .select, let id = name {
                ws.selection = .name(id); press = (p, .name(id)); drag = .name(id: id)
            } else if ws.tool == .ladder, inside {
                let piece = ws.shownStack.piece(strip: k)
                let y = ws.snapInGel(strip: k, x: q.x, y: q.y, free: free)
                let id = ws.addTick(x: ((q.x - (piece?.shift ?? 0)) / (piece?.scale ?? 1)), y: y, strip: k)   // x as in the gel with the lanes
                ws.selection = .tick(id)
                showTickEditor(id)
            } else {
                ws.selection = nil
            }
        case .names:
            if let id = name {
                ws.selection = .name(id); press = (p, .name(id)); drag = .name(id: id)
            } else if inside {
                let id = ws.addName(y: ws.snapInGel(strip: k, x: q.x, y: q.y, free: free), strip: k)
                ws.selection = .name(id)
                showNameEditor(id, isNew: true)
            } else {
                ws.selection = nil
            }
        default: break
        }
        needsDisplay = true
    }

    // drawing helpers
    private func strokeLine(_ ctx: CGContext, _ a: CGPoint, _ b: CGPoint, color: CGColor, width: CGFloat, dash: Bool = false) {
        ctx.saveGState()
        ctx.setStrokeColor(color)
        ctx.setLineWidth(width)
        ctx.setLineCap(.round)
        if dash { ctx.setLineDash(phase: 0, lengths: [5, 4]) }
        ctx.beginPath(); ctx.move(to: a); ctx.addLine(to: b); ctx.strokePath()
        ctx.restoreGState()
    }

    private func circle(_ ctx: CGContext, _ c: CGPoint, r: CGFloat, fill: CGColor, stroke: CGColor, width: CGFloat) {
        let rect = CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r)
        ctx.setFillColor(fill); ctx.fillEllipse(in: rect)
        ctx.setStrokeColor(stroke); ctx.setLineWidth(width); ctx.strokeEllipse(in: rect)
    }

    private func handle(_ ctx: CGContext, _ c: CGPoint, color: CGColor) {
        let r = CGRect(x: c.x - 4, y: c.y - 4, width: 8, height: 8)
        ctx.setFillColor(.white)
        ctx.addPath(CGPath(roundedRect: r, cornerWidth: 2, cornerHeight: 2, transform: nil)); ctx.fillPath()
        ctx.setStrokeColor(color); ctx.setLineWidth(1.25)
        ctx.addPath(CGPath(roundedRect: r, cornerWidth: 2, cornerHeight: 2, transform: nil)); ctx.strokePath()
    }

    private func badge(_ s: String, at c: CGPoint, color: NSColor, textColor: NSColor) {
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 10, weight: .semibold), .foregroundColor: textColor]
        let str = NSAttributedString(string: s, attributes: attrs)
        let sz = str.size()
        let r = CGRect(x: c.x - sz.width / 2 - 6, y: c.y - sz.height / 2 - 2, width: sz.width + 12, height: sz.height + 4)
        color.setFill()
        NSBezierPath(roundedRect: r, xRadius: r.height / 2, yRadius: r.height / 2).fill()
        str.draw(at: CGPoint(x: r.minX + 6, y: r.minY + 2))
    }

    private func outlineBadge(_ s: String, at c: CGPoint, color: NSColor) {
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 10, weight: .semibold), .foregroundColor: color]
        let str = NSAttributedString(string: s, attributes: attrs)
        let sz = str.size()
        let r = CGRect(x: c.x - sz.width / 2 - 6, y: c.y - sz.height / 2 - 2, width: sz.width + 12, height: sz.height + 4)
        NSColor(white: 0.08, alpha: 0.85).setFill()
        let path = NSBezierPath(roundedRect: r, xRadius: r.height / 2, yRadius: r.height / 2)
        path.fill()
        color.setStroke()
        path.lineWidth = 1.25
        let dash: [CGFloat] = [3, 2]
        path.setLineDash(dash, count: 2, phase: 0)
        path.stroke()
        str.draw(at: CGPoint(x: r.minX + 6, y: r.minY + 2))
    }

    // MARK: hit testing (view coordinates)

    private func hitDivider(_ p: CGPoint, _ ws: Workspace, _ l: FigureLayout, _ m: Mapping) -> (id: UUID, part: DividerPart)? {
        let crop = ws.crop, H = Double(ws.imageHeight)
        var best: (UUID, DividerPart, CGFloat)?
        for d in ws.project.lanes.dividers {
            let top = pxToView(d.x(atY: crop.y0, height: H), crop.y0, l, m)
            let bot = pxToView(d.x(atY: crop.y1, height: H), crop.y1, l, m)
            let dy = min(max(d.dotY, crop.y0), crop.y1)
            let dot = pxToView(d.x(atY: dy, height: H), dy, l, m)
            for (pt, part) in [(top, DividerPart.top), (bot, .bottom), (dot, .body)] {
                let dist = hypot(pt.x - p.x, pt.y - p.y)
                if dist < 8, best == nil || dist < best!.2 { best = (d.id, part, dist) }
            }
            let dist = distanceToSegment(p, top, bot)
            if dist < 5, best == nil || dist + 2 < best!.2 { best = (d.id, .body, dist + 2) }
        }
        return best.map { ($0.0, $0.1) }
    }

    private func hitTick(_ p: CGPoint, _ ws: Workspace, _ l: FigureLayout, _ m: Mapping) -> UUID? {
        guard let ladder = ws.project.ladder else { return nil }
        let gel = m.view(l.gelRect)
        var best: (UUID, CGFloat)?
        let crop = ws.crop, stack = ws.shownStack
        for b in ladder.bands {
            guard let fy = stack.figureY(strip: b.strip, y: b.y) else { continue }
            let ry = b.strip == nil ? b.y : crop.y0
            let y = pxToView(0, fy, l, m).y
            var x0 = gel.minX - 50, x1 = gel.minX + gel.width * 0.15
            if let g = ws.geometry, ladder.lane >= 1, ladder.lane <= g.count {
                x0 = min(gel.minX - 50, pxToView(g.x(g.boundaries[ladder.lane - 1], atY: ry), fy, l, m).x)
                x1 = pxToView(g.x(g.boundaries[ladder.lane], atY: ry), fy, l, m).x + 30
                if ladder.side == .right { x1 = max(x1, gel.maxX + 50) }
            }
            let d = abs(p.y - y)
            if d < 6, p.x >= x0, p.x <= x1, best == nil || d < best!.1 { best = (b.id, d) }
        }
        return best?.0
    }

    private func hitName(_ p: CGPoint, _ ws: Workspace, _ l: FigureLayout, _ m: Mapping) -> UUID? {
        let gel = m.view(l.gelRect)
        var best: (UUID, CGFloat)?
        let stack = ws.shownStack
        for a in ws.project.annotations {
            guard let fy = stack.nameY(strip: a.strip, y: a.y) else { continue }
            let y = pxToView(0, fy, l, m).y
            let inX = a.side == .right ? (p.x > gel.maxX - 16 && p.x < gel.maxX + 140) : (p.x < gel.minX + 16 && p.x > gel.minX - 140)
            let d = abs(p.y - y)
            if inX, d < 8, best == nil || d < best!.1 { best = (a.id, d) }
        }
        return best?.0
    }

    /// The label under view point `p`, a few pixels forgiving; slanted lane labels by their own rotated box.
    private func hitText(_ p: CGPoint, _ l: FigureLayout, _ m: Mapping) -> FigureText? {
        l.text(at: m.model(p), slack: CGSize(width: 3 / m.scale, height: 2 / m.scale))
    }

    private func distanceToSegment(_ p: CGPoint, _ a: CGPoint, _ b: CGPoint) -> CGFloat {
        let dx = b.x - a.x, dy = b.y - a.y
        let len2 = dx * dx + dy * dy
        guard len2 > 0 else { return hypot(p.x - a.x, p.y - a.y) }
        let t = max(0, min(1, ((p.x - a.x) * dx + (p.y - a.y) * dy) / len2))
        return hypot(p.x - (a.x + t * dx), p.y - (a.y + t * dy))
    }

    // MARK: mouse

    override func mouseDown(with e: NSEvent) {
        window?.makeFirstResponder(self)
        popover?.close()
        press = nil
        guard let ws = workspace, ws.working != nil else { return }
        let p = convert(e.locationInWindow, from: nil)
        if ws.tool == .pan || spaceDown {
            drag = .pan(start: p, startPan: shownPan)
            NSCursor.closedHand.set()
            return
        }
        if ws.tool == .straighten {
            let q = mapping.model(p)
            drag = .level(start: q, end: q)
            needsDisplay = true
            return
        }
        if cropMode { beginCrop(p, ws); return }
        if stripMode { stripMouseDown(p, e, ws); return }
        guard let l = ws.shownLayout else { return }
        let m = mapping
        if ws.placingUnit {   // "Place…" in the Ladder tab: this click sets the unit label's height, on the gel under it
            ws.placingUnit = false
            ws.placeUnit(atFigureY: viewToPx(p, l, m).y)
            needsDisplay = true
            return
        }
        let px = viewToPx(p, l, m)
        let gel = m.view(l.gelRect)
        let inGel = gel.insetBy(dx: -2, dy: -2).contains(p)
        let option = e.modifierFlags.contains(.option)
        let stack = ws.shownStack
        // with strips, a click with the Select tool in a piece's rows chooses it: the gel the inspector and crop/straighten act
        // on. The other tools act on the gel under the click (a tick or name belongs to it) but never change the chosen gel.
        if ws.tool == .select, stack.hasStrips, p.y >= gel.minY, p.y <= gel.maxY, let piece = stack.piece(atFigureY: px.y) {
            ws.chooseGel(piece.strip)
        }

        switch ws.tool {
        case .lanes:
            if let hit = hitDivider(p, ws, l, m), let d = ws.project.lanes.dividers.first(where: { $0.id == hit.id }) {
                if option { ws.deleteDivider(hit.id); break }
                ws.selection = .divider(hit.id)
                drag = .divider(id: hit.id, part: hit.part, start: d, startPx: px)
            } else if editLabel(at: p, ws, l, m) {
            } else if inGel {
                let id = ws.addDivider(x: px.x.rounded(), y: min(max(px.y, ws.crop.y0), ws.crop.y1).rounded())
                ws.selection = .divider(id)
                if let d = ws.project.lanes.dividers.first(where: { $0.id == id }) {
                    drag = .divider(id: id, part: .body, start: d, startPx: px)
                }
            } else {
                ws.selection = nil
            }

        case .ladder:
            if let id = hitTick(p, ws, l, m) {
                ws.selection = .tick(id)
                press = (p, .tick(id))
                drag = .tick(id: id)
            } else if editLabel(at: p, ws, l, m) {
            } else if inGel || (p.y > gel.minY && p.y < gel.maxY && abs(p.x - gel.minX) < 60) {
                let snap = ws.snapInFigure(x: px.x, y: px.y, free: option)
                let id = ws.addTick(x: px.x, y: snap.y, strip: snap.strip)
                ws.selection = .tick(id)
                showTickEditor(id)
            } else {
                ws.selection = nil
            }

        case .names:
            if let id = hitName(p, ws, l, m) {
                ws.selection = .name(id)
                press = (p, .name(id))
                drag = .name(id: id)
            } else if editLabel(at: p, ws, l, m) {
            } else if inGel {
                let snap = ws.snapInFigure(x: px.x, y: px.y, free: option)
                let id = ws.addName(y: snap.y, strip: snap.strip)
                ws.selection = .name(id)
                showNameEditor(id, isNew: true)
            } else {
                ws.selection = nil
            }

        case .select:
            if let hit = hitDivider(p, ws, l, m), let d = ws.project.lanes.dividers.first(where: { $0.id == hit.id }) {
                ws.selection = .divider(hit.id)
                drag = .divider(id: hit.id, part: hit.part, start: d, startPx: px)
            } else if let id = hitTick(p, ws, l, m) {
                ws.selection = .tick(id)
                press = (p, .tick(id))
                drag = .tick(id: id)
            } else if let id = hitName(p, ws, l, m) {
                ws.selection = .name(id)
                press = (p, .name(id))
                drag = .name(id: id)
            } else if editLabel(at: p, ws, l, m) {
            } else if e.clickCount >= 2, p.y < gel.minY, p.x > gel.minX, p.x < gel.maxX,
                      let g = ws.geometry, let lane = g.lane(atX: px.x, y: ws.crop.y0) {
                showLaneLabelEditor(lane: lane, at: CGRect(x: p.x - 10, y: p.y - 8, width: 20, height: 16))
            } else if e.clickCount >= 2, inGel, stack.hasStrips, let piece = stack.piece(atFigureY: px.y) {
                ws.selection = nil
                ws.showGel(piece.strip)   // a double-click: that gel on its own
            } else if inGel, stack.hasStrips, let piece = stack.piece(atFigureY: px.y) {
                // dragging a gel moves it sideways (the lanes gel too, with its lane dividers, labels, ticks and names): no other gel moves
                ws.selection = nil
                drag = .strip(k: piece.strip, startShift: ws.gelShift(piece.strip), startView: p, pointsPerPx: max(m.scale * l.ptPerPx, 1e-6),
                              column: piece.toPiece(x: px.x, y: px.y).x, zoomed: zoom)
                zoom = m.scale   // the scale holds while the gel is held, even as the figure gets wider or narrower
            } else {
                ws.selection = nil
            }
        default: break
        }
        needsDisplay = true
    }

    /// One click on a figure label opens its editor, whatever the tool: text and size for titles and labels, the
    /// size menu for ladder numbers, the name editor for band names. False when `p` isn't on a label.
    private func editLabel(at p: CGPoint, _ ws: Workspace, _ l: FigureLayout, _ m: Mapping) -> Bool {
        guard let t = hitText(p, l, m) else { return false }
        switch t.role {
        case .ladderLabel(let bi):
            guard let bands = ws.project.ladder?.bands, bands.indices.contains(bi) else { return false }
            ws.selection = .tick(bands[bi].id)
            showTickEditor(bands[bi].id)
        case .annotation(let i):
            guard ws.project.annotations.indices.contains(i) else { return false }
            let id = ws.project.annotations[i].id
            ws.selection = .name(id)
            showNameEditor(id, isNew: false)
        case .ladderUnit:
            // a click edits the unit, a drag moves it up or down (mouseUp tells them apart)
            ws.selection = .text(.ladderUnit)
            press = (p, .text(.ladderUnit))
            drag = .unit(startY: l.pixel(CGPoint(x: t.bounds.midX, y: t.bounds.midY)).y, startView: p)
        default:
            ws.selection = .text(t.role)
            showTextEditor(role: t.role, at: m.view(t.bounds))
        }
        return true
    }

    override func mouseDragged(with e: NSEvent) {
        guard let ws = workspace else { return }
        let p = convert(e.locationInWindow, from: nil)
        hover = p
        if let pr = press, hypot(p.x - pr.at.x, p.y - pr.at.y) > 3 { press = nil }   // it's a drag, not a click
        switch drag {
        case .pan(let start, let startPan)?:
            pan = clamped(CGPoint(x: startPan.x + p.x - start.x, y: startPan.y + p.y - start.y), scale: mapping.scale)
        case .divider(let id, let part, let start, let startPx)?:
            guard let l = ws.shownLayout else { return }
            let px = viewToPx(p, l, mapping)
            switch part {
            case .body:
                let dotY = min(max(px.y, ws.crop.y0), ws.crop.y1)
                ws.dragDivider(id, from: start, .move(dx: (px.x - startPx.x).rounded(), dotY: dotY.rounded()))
            case .top: ws.dragDivider(id, from: start, .top(x: px.x.rounded()))
            case .bottom: ws.dragDivider(id, from: start, .bottom(x: px.x.rounded()))
            }
        case .tick(let id)?:
            if stripMode, let k = ws.activeStrip {   // on the gel's own pixels
                let q = mapping.model(p)
                let x = ws.project.ladder.flatMap { GelOps.laneX(ws.project, lane: $0.lane, strip: k) } ?? q.x
                ws.moveTick(id, y: ws.snapInGel(strip: k, x: x, y: q.y, free: e.modifierFlags.contains(.option)))
                break
            }
            guard let l = ws.shownLayout else { return }
            let px = viewToPx(p, l, mapping)
            let laneX = ws.project.ladder.flatMap { ld in
                ld.lane >= 1 && ld.lane <= ws.project.lanes.centers.count ? ws.project.lanes.centers[ld.lane - 1] : nil
            } ?? px.x
            ws.dragTick(id, x: laneX, figureY: px.y, free: e.modifierFlags.contains(.option))
        case .name(let id)?:
            if stripMode, let k = ws.activeStrip {
                let q = mapping.model(p), n = ws.project.lanes.centers.count
                let onLeft = ws.project.annotations.first { $0.id == id }?.side == .left
                let x = GelOps.laneX(ws.project, lane: onLeft ? 1 : n, strip: k) ?? q.x
                ws.moveName(id, y: ws.snapInGel(strip: k, x: x, y: q.y, free: e.modifierFlags.contains(.option)))
                break
            }
            guard let l = ws.shownLayout else { return }
            let px = viewToPx(p, l, mapping)
            // snaps in the lane next to the edge the name is on
            let centers = ws.project.lanes.centers
            let onLeft = ws.project.annotations.first { $0.id == id }?.side == .left
            let edgeLane = (onLeft ? centers.first : centers.last) ?? px.x
            ws.dragName(id, x: edgeLane, figureY: px.y, free: e.modifierFlags.contains(.option))
        case .crop(let h, let r0, let s0)?:
            let r = cropRect(h, r0, from: s0, to: mapping.model(p), ws)
            if ws.activeStrip != nil { ws.liveStripCrop(r) } else { ws.liveCrop(r) }
        case .strip(let k, let s0, let start, let pointsPerPx, let column, _)?:
            ws.liveStripShift(k, s0 - ws.stripScale(k) * Double((p.x - start.x) / pointsPerPx))
            // the figure may have moved on the page (it starts at the leftmost column any gel keeps): slide the view so the gel's column
            // is under the pointer again, which also keeps the gels that didn't move where they were on screen
            if let l = ws.shownLayout, let piece = ws.shownStack.piece(strip: k) {
                let at = pxToView(piece.toFigure(x: column, y: 0).x, 0, l, mapping)
                pan.x += p.x - at.x
            }
        case .level(let a, _)?:
            drag = .level(start: a, end: mapping.model(p))
        case .unit(let y0, let start)?:
            guard press == nil, let l = ws.shownLayout else { break }   // still a click until it moves
            ws.moveUnit(toFigureY: y0 + (p.y - start.y) / (mapping.scale * l.ptPerPx))
        case nil: break
        }
        needsDisplay = true
    }

    override func mouseUp(with e: NSEvent) {
        guard let ws = workspace else { return }
        switch drag {
        case .divider?: ws.endGesture("Move Lane Divider")
        case .tick?: ws.endGesture("Move Ladder Tick")
        case .name?: ws.endGesture("Move Band Name")
        case .crop?: ws.endGesture(ws.activeStrip == nil ? "Crop" : "Gel Crop")
        case .strip(_, _, _, _, _, let zoomed)?:
            ws.endGesture("Line Up Gel")
            if zoomed == nil { fitToWindow() }   // it was fitting before the drag: it fits the new figure
        case .level(let a, let b)?: ws.straighten(from: a, to: b)
        case .unit?: ws.endGesture("Move Unit Label")
        case .pan?: updateCursor(at: convert(e.locationInWindow, from: nil))
        case nil: break
        }
        drag = nil
        if let pr = press {   // pressed and let go without moving: edit it
            press = nil
            switch pr.target {
            case .tick(let id): showTickEditor(id)
            case .name(let id): showNameEditor(id, isNew: false)
            case .text(let role):
                if let l = ws.shownLayout, let t = l.texts.first(where: { $0.role == role }) { showTextEditor(role: role, at: mapping.view(t.bounds)) }
            default: break
            }
        }
        needsDisplay = true
    }

    override func mouseMoved(with e: NSEvent) {
        let p = convert(e.locationInWindow, from: nil)
        hover = p
        updateCursor(at: p)
        needsDisplay = true
    }

    override func mouseExited(with e: NSEvent) { hover = nil; needsDisplay = true }

    override func flagsChanged(with e: NSEvent) { needsDisplay = true }   // ⌥ toggles the snap preview

    override func scrollWheel(with e: NSEvent) {
        let p = convert(e.locationInWindow, from: nil)
        if e.modifierFlags.contains(.command) {
            zoom(by: exp(e.scrollingDeltaY * (e.hasPreciseScrollingDeltas ? 0.01 : 0.1)), around: p)
        } else {
            if zoom == nil { zoom = fitScale }
            let k: CGFloat = e.hasPreciseScrollingDeltas ? 1 : 8, now = shownPan
            pan = clamped(CGPoint(x: now.x + e.scrollingDeltaX * k, y: now.y + e.scrollingDeltaY * k), scale: zoom ?? fitScale)
            needsDisplay = true
        }
    }

    override func magnify(with e: NSEvent) {
        zoom(by: 1 + e.magnification, around: convert(e.locationInWindow, from: nil))
    }

    private func updateCursor(at p: CGPoint) {
        guard let ws = workspace else { return }
        if spaceDown || ws.tool == .pan { NSCursor.openHand.set(); return }
        if cropMode || ws.placingUnit { NSCursor.crosshair.set(); return }
        if stripMode, let k = ws.activeStrip {
            let m = mapping
            if hitStripTick(p, ws, k, m) != nil || hitStripName(p, ws, k, m) != nil { NSCursor.resizeUpDown.set() }
            else if ws.tool == .ladder || ws.tool == .names { NSCursor.crosshair.set() } else { NSCursor.arrow.set() }
            return
        }
        guard let l = ws.shownLayout else { NSCursor.arrow.set(); return }
        let m = mapping
        switch ws.tool {
        case .lanes:
            if let hit = hitDivider(p, ws, l, m) { (hit.part == .body ? NSCursor.resizeLeftRight : NSCursor.crosshair).set() }
            else if hitText(p, l, m) != nil { NSCursor.pointingHand.set() }   // a click edits the label
            else if m.view(l.gelRect).contains(p) { NSCursor.crosshair.set() } else { NSCursor.arrow.set() }
        case .ladder, .names:
            if hitTick(p, ws, l, m) != nil || hitName(p, ws, l, m) != nil { NSCursor.resizeUpDown.set() }
            else if hitText(p, l, m) != nil { NSCursor.pointingHand.set() }
            else if m.view(l.gelRect).contains(p) { NSCursor.crosshair.set() } else { NSCursor.arrow.set() }
        default:
            if hitDivider(p, ws, l, m) != nil { NSCursor.resizeLeftRight.set() }
            else if hitTick(p, ws, l, m) != nil || hitName(p, ws, l, m) != nil { NSCursor.resizeUpDown.set() }
            else if hitText(p, l, m) != nil { NSCursor.pointingHand.set() } else { NSCursor.arrow.set() }
        }
    }

    // MARK: crop

    private func beginCrop(_ p: CGPoint, _ ws: Workspace) {
        let m = mapping
        let c = ws.activeStripRect ?? ws.crop
        let r = m.view(CGRect(x: c.x0, y: c.y0, width: c.width, height: c.height))
        let q = m.model(p)
        let t: CGFloat = 9
        let nearL = abs(p.x - r.minX) < t, nearR = abs(p.x - r.maxX) < t
        let nearT = abs(p.y - r.minY) < t, nearB = abs(p.y - r.maxY) < t
        let inY = p.y > r.minY - t && p.y < r.maxY + t, inX = p.x > r.minX - t && p.x < r.maxX + t
        let h: CropHandle
        switch (nearL, nearR, nearT, nearB) {
        case (true, _, true, _): h = .topLeft
        case (_, true, true, _): h = .topRight
        case (true, _, _, true): h = .bottomLeft
        case (_, true, _, true): h = .bottomRight
        case (true, _, _, _) where inY: h = .left
        case (_, true, _, _) where inY: h = .right
        case (_, _, true, _) where inX: h = .top
        case (_, _, _, true) where inX: h = .bottom
        default: h = r.contains(p) ? .move : .new
        }
        drag = .crop(handle: h, startRect: c, startPx: q)   // every gel has all four edges and corners
    }

    private func cropRect(_ h: CropHandle, _ r0: PixelRect, from s: CGPoint, to q: CGPoint, _ ws: Workspace) -> PixelRect {
        let dx = (q.x - s.x).rounded(), dy = (q.y - s.y).rounded()
        var r = r0
        switch h {
        case .new:
            r = PixelRect(x0: min(s.x, q.x).rounded(), y0: min(s.y, q.y).rounded(), x1: max(s.x, q.x).rounded(), y1: max(s.y, q.y).rounded())
        case .move:
            let size = ws.activeSize
            let W = Double(size.width), H = Double(size.height)
            let mx = min(max(dx, -r0.x0), W - r0.x1), my = min(max(dy, -r0.y0), H - r0.y1)
            r = PixelRect(x0: r0.x0 + mx, y0: r0.y0 + my, x1: r0.x1 + mx, y1: r0.y1 + my)
        case .left: r.x0 += dx
        case .right: r.x1 += dx
        case .top: r.y0 += dy
        case .bottom: r.y1 += dy
        case .topLeft: r.x0 += dx; r.y0 += dy
        case .topRight: r.x1 += dx; r.y0 += dy
        case .bottomLeft: r.x0 += dx; r.y1 += dy
        case .bottomRight: r.x1 += dx; r.y1 += dy
        }
        return r
    }

    // MARK: keyboard

    override func keyDown(with e: NSEvent) {
        guard let ws = workspace else { super.keyDown(with: e); return }
        if e.charactersIgnoringModifiers == " " {
            if !spaceDown { spaceDown = true; NSCursor.openHand.set() }
            return
        }
        let step: Double = e.modifierFlags.contains(.shift) ? 10 : 1
        switch e.keyCode {
        case 51, 117:   // delete, forward delete
            switch ws.selection {
            case .divider(let id)?: ws.deleteDivider(id)
            case .tick(let id)?: ws.deleteTick(id)
            case .name(let id)?: ws.deleteName(id)
            case .text?, nil: break
            }
        case 123, 124: nudge(ws, dx: e.keyCode == 123 ? -step : step, dy: 0)
        case 125, 126: nudge(ws, dx: 0, dy: e.keyCode == 126 ? -step : step)
        case 53:        // escape
            if ws.placingUnit { ws.placingUnit = false }
            else if ws.tool == .crop { ws.cancelCrop() } else { ws.selection = nil }
        case 36, 76:    // return
            if ws.tool == .crop { ws.tool = .select }
        default:
            if e.modifierFlags.intersection([.command, .control, .option]).isEmpty,
               let ch = e.charactersIgnoringModifiers?.lowercased().first,
               let t = ShortcutStore.shared.tool(forKey: ch) {
                ws.tool = t
            } else {
                super.keyDown(with: e)
            }
        }
        needsDisplay = true
    }

    override func keyUp(with e: NSEvent) {
        if e.charactersIgnoringModifiers == " " {
            spaceDown = false
            if let h = hover { updateCursor(at: h) }
        }
    }

    private func nudge(_ ws: Workspace, dx: Double, dy: Double) {
        switch ws.selection {
        case .divider(let id)?:
            guard dx != 0, let d = ws.project.lanes.dividers.first(where: { $0.id == id }) else { return }
            ws.dragDivider(id, from: d, .move(dx: dx, dotY: d.dotY))
            ws.endGesture("Nudge Lane Divider")
        case .tick(let id)?:
            guard dy != 0, let b = ws.project.ladder?.bands.first(where: { $0.id == id }) else { return }
            ws.moveTick(id, y: b.y + dy); ws.endGesture("Nudge Ladder Tick")
        case .name(let id)?:
            guard dy != 0, let a = ws.project.annotations.first(where: { $0.id == id }) else { return }
            ws.moveName(id, y: a.y + dy); ws.endGesture("Nudge Band Name")
        case nil:
            // nothing selected, with several gels: left and right move the chosen gel (the lanes gel too) a pixel at a time
            guard dx != 0, !ws.project.strips.isEmpty else { return }
            ws.nudgeActiveStrip(by: dx)
        case .text?: break
        }
    }

    // MARK: popovers

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil, LaunchOptions.shared.value("--edit") != nil {   // once the window has settled
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in self?.openLaunchEditor(tries: 0) }
        }
    }

    /// Testing hook: `--edit tick:N`, `--edit name:N` or `--edit label:TEXT` opens that editor once the figure is up, as a click on
    /// it would (N counts from 1 in the order they were made; TEXT is a lane or group label's text).
    private func openLaunchEditor(tries: Int) {
        guard let spec = LaunchOptions.shared.value("--edit"), let colon = spec.firstIndex(of: ":") else { return }
        guard let ws = workspace, let layout = ws.shownLayout, bounds.width > 400 else {
            if tries < 30 { DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in self?.openLaunchEditor(tries: tries + 1) } }
            return
        }
        let kind = spec[..<colon], arg = String(spec[spec.index(after: colon)...]), n = Int(arg) ?? 0
        switch kind {
        case "tick": if let bands = ws.project.ladder?.bands, n >= 1, n <= bands.count { showTickEditor(bands[n - 1].id) }
        case "name": if n >= 1, n <= ws.project.annotations.count { showNameEditor(ws.project.annotations[n - 1].id, isNew: false) }
        case "label":
            let hit = layout.texts.first { t in
                switch t.role { case .laneLabel, .groupLabel: t.string == arg; default: false }
            }
            if let t = hit { showTextEditor(role: t.role, at: mapping.view(t.bounds)) }
        default: break
        }
        // a popover is a child window, which a screenshot of the window taken from outside (a window on another Space) can't
        // include; on its own it can be captured
        for child in window?.childWindows ?? [] { window?.removeChildWindow(child) }
    }

    private func present<V: View>(_ content: V, at rect: CGRect, edge: NSRectEdge = .maxX) {
        popover?.close()
        let pop = NSPopover()
        pop.behavior = .transient
        pop.animates = true
        pop.appearance = AppAppearance.current.nsAppearance
        // solid, so the inspector and gel behind don't show through the glass
        pop.contentViewController = NSHostingController(rootView: content
            .background(Color(nsColor: Chrome.popover))
            .preferredColorScheme(AppAppearance.current.colorScheme))
        pop.show(relativeTo: rect.insetBy(dx: -2, dy: -2), of: self, preferredEdge: edge)
        popover = pop
    }

    private func closePopover() { popover?.performClose(nil); popover = nil; window?.makeFirstResponder(self) }

    private func showTickEditor(_ id: UUID) {
        guard let ws = workspace, let ladder = ws.project.ladder, let band = ladder.bands.first(where: { $0.id == id }) else { return }
        let m = mapping
        let inward = ladder.side != .right   // a left ladder opens to the right
        var x: CGFloat, y: CGFloat
        if stripMode, let k = ws.activeStrip, let t = stripTicks(ws, k, m).first(where: { $0.id == id }) {
            x = inward ? max(t.x0, t.x1) : min(t.x0, t.x1); y = t.y   // the gel on view by itself: its own pixels
        } else {
            guard let l = ws.shownLayout else { return }
            let gel = m.view(l.gelRect)
            let fy = ws.figureY(strip: band.strip, y: band.y) ?? band.y
            let ry = band.strip == nil ? band.y : ws.crop.y0
            y = pxToView(0, fy, l, m).y
            // Beside the ladder lane, on the gel's side, past the size badges: the whole lane stays free, so the next band
            // down can be clicked straight away. (Anchored at the gel's outer edge it had no room, and macOS flipped it
            // over the lane; above the band it had no room for the top bands.)
            x = inward ? gel.minX + gel.width * 0.12 : gel.maxX - gel.width * 0.12
            if let g = ws.geometry, ladder.lane >= 1, ladder.lane <= g.count {
                let edge = g.boundaries[inward ? ladder.lane : ladder.lane - 1]
                x = pxToView(g.x(edge, atY: ry), fy, l, m).x
            }
        }
        x += inward ? 34 : -34
        let editor = TickEditor(
            initial: band.size, isGuess: band.auto,
            suggestion: ws.suggestedSize(forY: band.y - 0.001, strip: band.strip),
            ladderSizes: ws.ladderSizes, unit: ws.project.ladder?.unit ?? ws.preset?.unit ?? "kDa",
            onCommit: { [weak self] size in ws.setTick(id, size: size); self?.closePopover() },
            onSkip: { [weak self] in ws.setTick(id, size: nil, ignore: true); self?.closePopover() },
            onDelete: { [weak self] in ws.deleteTick(id); self?.closePopover() })
        present(editor, at: CGRect(x: x - 6, y: y - 6, width: 12, height: 12), edge: inward ? .maxX : .minX)
    }

    private func showNameEditor(_ id: UUID, isNew: Bool) {
        guard let ws = workspace, let a = ws.project.annotations.first(where: { $0.id == id }) else { return }
        let m = mapping
        let x: CGFloat, y: CGFloat
        if stripMode, let k = ws.activeStrip, let n = stripNames(ws, k, m).first(where: { $0.id == id }) {
            x = n.x; y = n.y
        } else {
            guard let l = ws.shownLayout else { return }
            let gel = m.view(l.gelRect)
            y = pxToView(0, ws.shownStack.nameY(strip: a.strip, y: a.y) ?? a.y, l, m).y
            x = a.side == .right ? gel.maxX : gel.minX
        }
        let index = ws.project.annotations.firstIndex { $0.id == id } ?? 0
        let editor = NameEditor(
            initial: a, recent: ws.recentNames, size: ws.project.style.size(for: FigureRole.annotation(index)),
            onCommit: { [weak self] text, marker in
                if text.trimmingCharacters(in: .whitespaces).isEmpty { ws.deleteName(id) }
                else { ws.updateName(id) { $0.text = text; $0.marker = marker }; ws.rememberName(of: id) }
                self?.closePopover()
            },
            onSize: { v in ws.setSize(v, forLabel: .annotation(index)) },
            onDelete: { [weak self] in ws.deleteName(id); self?.closePopover() },
            onForget: { name in ws.forget(name: name) })
        present(editor, at: CGRect(x: x - 6, y: y - 6, width: 12, height: 12), edge: a.side == .right ? .maxX : .minX)
        _ = isNew
    }

    private func showTextEditor(role: FigureRole, at rect: CGRect) {
        guard let ws = workspace else { return }
        let kind = TextKind(role: role)
        let editor = TextEditorPopover(
            title: role == .ladderUnit ? "Ladder Unit" : kind.title.dropLast(kind == .title ? 0 : 1).description.capitalized,
            initial: ws.text(for: role), size: ws.project.style.size(for: role),
            sizeScope: role == .title ? "the title" : role.sizeKey == nil ? "all \(kind.title.lowercased())" : "this label only",
            onCommit: { [weak self] value in ws.setText(role, value); self?.closePopover() },
            onSize: { v in ws.setSize(v, forLabel: role) })
        present(editor, at: rect, edge: .maxY)
    }

    private func showLaneLabelEditor(lane: Int, at rect: CGRect) {
        guard let ws = workspace else { return }
        let editor = TextEditorPopover(
            title: "Lane \(lane) label", initial: "", size: ws.project.style.size(for: .laneLabel),
            sizeScope: "all lane labels",
            onCommit: { [weak self] value in ws.setLaneLabel(lane: lane, value); self?.closePopover() },
            onSize: { v in ws.setSize(v, for: .laneLabel) })
        present(editor, at: rect, edge: .maxY)
    }
}

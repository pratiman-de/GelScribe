import AppKit
import CoreGraphics
import Foundation
import Testing
import UniformTypeIdentifiers
@testable import GelKit
@testable import GelScribeApp

// The app's own logic without launching it: what the Figure and gel views show, each gel's own Keep original pixels, and the
// canvas, driven with real mouse events on an offscreen window. Uses the tutorial's two pieces (docs/).

private let docsURL = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("docs")
private let hasDocs = FileManager.default.fileExists(atPath: docsURL.appendingPathComponent("bottom-piece.png").path)
/// The canvas needs a window, so a login session (not an SSH one).
private let hasWindowServer = CGSessionCopyCurrentDictionary() != nil

/// The top piece with its 13 lanes found, and the bottom piece as gel 2 (a new gel starts with Keep original pixels off). Made
/// once: finding the lanes takes a while in a debug build.
private let cutBlotPackage: GelPackage = {
    let top = try! Data(contentsOf: docsURL.appendingPathComponent("top-piece.png"))
    let bottom = try! Data(contentsOf: docsURL.appendingPathComponent("bottom-piece.png"))
    var pkg = try! GelPackage.create(imageData: top, imageName: "top-piece.png")
    let work = WorkingImage(source: try! SourceImage(data: top), project: pkg.project)
    _ = GelOps.autoDividers(&pkg.project, work, count: 13)
    try! pkg.addStrip(imageData: bottom, imageName: "bottom-piece.png")
    return pkg
}()

@MainActor private func cutBlot() throws -> (ws: Workspace, undo: UndoManager) {
    #expect(cutBlotPackage.project.laneCount == 13)
    let ws = Workspace(document: GelDocument(package: cutBlotPackage))
    let undo = UndoManager()
    undo.groupsByEvent = false
    ws.undoManager = undo
    return (ws, undo)
}

/// One undoable step (the undo manager here doesn't group by run loop turn).
@MainActor private func step(_ undo: UndoManager, _ body: () -> Void) { undo.beginUndoGrouping(); body(); undo.endUndoGrouping() }

@MainActor @Suite struct GelViews {
    @Test(.enabled(if: hasDocs)) func theSwitcherChoosesAndShowsGels() throws {
        let (ws, _) = try cutBlot()
        #expect(!ws.showsGel && !ws.viewsOtherGel)   // starts on the figure
        ws.zoomRequest = nil
        ws.showGel(1)   // the switcher's "Gel 2": chosen, shown on its own, zoomed to fit
        #expect(ws.showsGel && ws.viewsOtherGel && ws.activeStrip == 1 && ws.zoomRequest == .fit)
        ws.zoomRequest = nil
        ws.chooseGel(nil)   // a click in the Gels list moves a gel view that is showing
        #expect(ws.showsGel && !ws.viewsOtherGel && ws.activeStrip == nil && ws.zoomRequest == .fit)
        #expect(ws.shownLayout != nil && !ws.shownStack.hasStrips && ws.stack.hasStrips)   // the lanes gel: a figure of its own
        ws.zoomRequest = nil
        ws.showFigure()
        #expect(!ws.showsGel && ws.activeStrip == nil && ws.zoomRequest == .fit)
        ws.zoomRequest = nil
        ws.chooseGel(1)   // on the figure, a click in the list only chooses
        #expect(!ws.showsGel && ws.activeStrip == 1 && ws.zoomRequest == nil)
    }

    @Test(.enabled(if: hasDocs)) func theLaneDividerToolIsOnlyForTheGelWithTheLanes() throws {
        let (ws, _) = try cutBlot()
        ws.tool = .lanes
        ws.showGel(nil)
        #expect(ws.tool == .lanes)   // the lanes gel's own view works as for a single gel
        ws.showGel(1)
        #expect(ws.tool == .select)   // another gel: the tool moves off the dividers
        ws.tool = .lanes
        #expect(ws.tool == .select && ws.toolNote == "Lane dividers are set on Gel 1, the gel with the lanes.")
        ws.tool = .ladder
        #expect(ws.tool == .ladder)
        ws.showFigure()
        ws.tool = .lanes
        #expect(ws.tool == .lanes)
    }

    @Test(.enabled(if: hasDocs)) func theGelViewEndsWithTheGels() throws {
        let (ws, undo) = try cutBlot()
        ws.showGel(1)
        step(undo) { ws.removeActiveGel() }
        #expect(!ws.showsGel)   // one gel left: no switcher, no gel view
        undo.undo()
        #expect(ws.project.strips.count == 1 && !ws.showsGel)   // and it doesn't come back with the gel
    }

    @Test(.enabled(if: hasDocs)) func eachGelHasItsOwnKeepOriginalPixels() throws {
        let (ws, undo) = try cutBlot()
        #expect(ws.project.strict && ws.project.strips[0].strict == false && ws.pixelsKept == .some)
        ws.activeStrip = 1
        step(undo) { ws.autoAlign() }   // a new gel stretches into line (the tutorial's pieces differ by 2.5%)
        #expect(abs(ws.project.strips[0].scale - 1.0237) < 0.005, "\(ws.project.strips[0].scale)")
        step(undo) { ws.setStrict(true) }   // gel 2's own switch: the lanes gel isn't touched
        #expect(ws.project.strips[0].strict == true && ws.project.strict && ws.pixelsKept == .all)
        step(undo) { ws.autoAlign() }   // now a whole-pixel shift, and it says so
        #expect(ws.project.strips[0].shift == ws.project.strips[0].shift.rounded() && ws.alignNote?.contains("allows a shift only") == true)
        ws.setScale(1.05)
        #expect(ws.project.effectiveAlignment(1).scale == 1)   // stretching is off while it keeps its pixels
        step(undo) { ws.setStrict(false) }
        #expect(!ws.activeStrict && ws.figure?.strictProblem == nil && ws.figure?.gel != nil)   // mixed: exports
        // the lanes gel's switch leaves a gel of an older project (no setting of its own) as it was
        ws.activeStrip = nil
        step(undo) { ws.setStrict(true) }   // lanes gel: on, as it was
        ws.document.edit("older project", undoManager: nil) { $0.strips[0].strict = nil }
        step(undo) { ws.setStrict(false) }
        #expect(!ws.project.strict && ws.project.strips[0].strict == true && ws.project.isStrict(gel: 1))
    }

    @Test(.enabled(if: hasDocs)) func theLineBetweenGelsIsOneUndoableChoice() throws {
        let (ws, undo) = try cutBlot()
        #expect(!ws.project.separatorWhite)
        step(undo) { ws.setSeparatorWhite(true) }
        #expect(ws.project.separatorWhite && ws.exportInfo.description.contains("with a white line between each"))
        undo.undo()
        #expect(!ws.project.separatorWhite && ws.exportInfo.description.contains("with a black line between each"))
        // any color, typed as hex: one undo step, and the note names it
        step(undo) { ws.setSeparatorColor(SeparatorColor(parsing: "f30")!) }
        #expect(ws.project.separatorColor == .rgb(255, 51, 0) && ws.exportInfo.description.contains("with a #ff3300 line between each"))
        ws.setSeparatorColor(.rgb(255, 51, 0))   // the same color again registers nothing, so one undo takes it back
        undo.undo()
        #expect(ws.project.separatorColor == .black)
    }

    @Test(.enabled(if: hasDocs)) func theLinesThicknessIsItsOwnUntilItMatchesTheFiguresLinesAgain() throws {
        let (ws, undo) = try cutBlot()
        let lines = ws.project.style.lineWidthPt
        #expect(ws.project.separatorWidth == nil && ws.project.effectiveSeparatorWidth == lines)   // follows the Lines width
        let rows = ws.stack.separator
        step(undo) { ws.setSeparatorWidth(4) }
        #expect(ws.project.separatorWidth == 4 && ws.stack.separator > rows)   // the figure's rows change with it
        step(undo) { ws.setSeparatorWidth(40) }   // 0.25 to 10 pt
        #expect(ws.project.separatorWidth == 10)
        step(undo) { ws.setSeparatorWidth(0.01) }
        #expect(ws.project.separatorWidth == 0.25)
        ws.setSeparatorWidth(.nan)   // not a number: nothing changes
        #expect(ws.project.separatorWidth == 0.25)
        // Match lines: unset again, and it follows the Lines width as it changes
        step(undo) { ws.setSeparatorWidth(nil) }
        #expect(ws.project.separatorWidth == nil && ws.stack.separator == rows)
        step(undo) { ws.edit("Line Width") { $0.style.lineWidthPt = 2 } }
        #expect(ws.project.effectiveSeparatorWidth == 2 && ws.stack.separator > rows)
        undo.undo(); undo.undo()   // the Lines width, and Match lines
        #expect(ws.project.separatorWidth == 0.25)
    }
}

@MainActor @Suite struct EveryGelsSwitch {
    /// A flat 8-bit RGB PNG.
    private func rgbPNG(width: Int, height: Int) -> Data {
        let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        ctx.setFillColor(CGColor(red: 0.8, green: 0.5, blue: 0.3, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let out = NSMutableData()
        let dest = CGImageDestinationCreateWithData(out, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
        CGImageDestinationFinalize(dest)
        return out as Data
    }

    @Test(.enabled(if: hasDocs)) func eachGelsSwitchActsOnThatGelWhicheverIsChosen() throws {
        let (ws, undo) = try cutBlot()
        ws.activeStrip = 1   // gel 2 is chosen; the rows switch any gel
        #expect(ws.pixelsKept == .some)   // the lanes gel keeps its pixels, a gel added doesn't
        step(undo) { ws.setStrict(true, gel: 1) }
        #expect(ws.project.strips[0].strict == true && ws.project.strict && ws.pixelsKept == .all)
        step(undo) { ws.setStrict(false, gel: nil) }   // the lanes gel's, while gel 2 stays chosen
        #expect(!ws.project.strict && ws.project.strips[0].strict == true && ws.activeStrip == 1 && ws.pixelsKept == .some)
        step(undo) { ws.setStrict(false, gel: 1) }
        #expect(ws.pixelsKept == .none)
        undo.undo(); undo.undo()
        #expect(ws.project.strict && ws.project.strips[0].strict == true)
    }

    @Test func theProblemIsSaidOfTheGelItConcerns() throws {
        // a gray gel with the lanes and a color gel 2, both keeping their pixels, can't be stored the same way: said of gel 2
        let gray = try Data(contentsOf: docsURL.appendingPathComponent("top-piece.png"))
        var pkg = try GelPackage.create(imageData: gray, imageName: "top.png")
        try pkg.addStrip(imageData: rgbPNG(width: 300, height: 100), imageName: "color.png")
        pkg.project.strips[0].strict = true
        let ws = Workspace(document: GelDocument(package: pkg))
        let problem = try #require(ws.strictProblemDetail)
        #expect(problem.gel == 1 && problem.text.hasPrefix("Gel 2 is 8-bit RGB"), "\(problem)")
        #expect(ws.strictProblem == problem.text)
        // a gel that doesn't keep its pixels is stored however the output is: nothing to say, and the badge reads Mixed
        ws.document.edit("off", undoManager: nil) { $0.strips[0].strict = false }
        #expect(ws.strictProblemDetail == nil && ws.pixelsKept == .some)
    }
}

// MARK: the canvas, with mouse events

@MainActor private final class Bench {
    let ws: Workspace, undo: UndoManager, canvas = CanvasNSView(), window: NSWindow
    init() throws {
        (ws, undo) = try cutBlot()
        _ = NSApplication.shared
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1440, height: 900), styleMask: [.titled], backing: .buffered, defer: false)
        canvas.workspace = ws
        window.contentView = canvas
        canvas.frame = NSRect(x: 0, y: 0, width: 1440, height: 900)
        ws.undoManager = nil   // edits from the canvas register their own undo steps below
        ws.undoManager = undo
        undo.groupsByEvent = true
    }

    /// Where the canvas puts a figure of `content` points, or a whole gel (its own 120-point margins): the same arithmetic as the canvas
    /// (the switcher keeps the top 100 points free).
    func place(_ x: Double, _ y: Double, content: CGSize, gel: Bool) -> CGPoint {
        let side: CGFloat = gel ? 120 : 0
        let a = CGRect(x: 92 + side, y: 100, width: 1440 - 92 - 352 - 2 * side, height: 900 - 100 - 76)
        let sc = min(a.width / content.width, a.height / content.height)
        return CGPoint(x: (a.midX - content.width * sc / 2).rounded() + x * sc, y: (a.midY - content.height * sc / 2).rounded() + y * sc)
    }
    /// A point of the figure: gel `strip`'s piece at `row` (0 to 1 down the piece), column `x` of the gel with the lanes.
    func figurePoint(strip: Int?, x: Double? = nil, row: Double = 0.5) -> CGPoint {
        let l = ws.shownLayout!, piece = ws.stack.piece(strip: strip)!
        let pt = l.point(x: x ?? (ws.crop.x0 + ws.crop.width * 0.8), y: piece.top + (piece.bottom - piece.top) * row)
        return place(pt.x, pt.y, content: l.size, gel: false)
    }
    /// A point of the gel on view, in its own pixels.
    func gelPoint(_ x: Double, _ y: Double) -> CGPoint {
        place(x, y, content: CGSize(width: ws.activeSize.width, height: ws.activeSize.height), gel: true)
    }

    func event(_ type: NSEvent.EventType, _ p: CGPoint, count: Int = 1, option: Bool = false) -> NSEvent {
        NSEvent.mouseEvent(with: type, location: CGPoint(x: p.x, y: 900 - p.y), modifierFlags: option ? [.option] : [], timestamp: 0,
                           windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: count, pressure: 1)!
    }
    func click(_ p: CGPoint, count: Int = 1, option: Bool = false) {
        canvas.mouseDown(with: event(.leftMouseDown, p, count: count, option: option))
        canvas.mouseUp(with: event(.leftMouseUp, p, count: count, option: option))
    }
    func key(_ code: UInt16) {
        let character = code == 53 ? "\u{1b}" : "\r"
        canvas.keyDown(with: NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
                                              context: nil, characters: character, charactersIgnoringModifiers: character, isARepeat: false, keyCode: code)!)
    }
    func drag(from a: CGPoint, to b: CGPoint, option: Bool = false) {
        canvas.mouseDown(with: event(.leftMouseDown, a, count: 1, option: option))
        canvas.mouseDragged(with: event(.leftMouseDragged, b, count: 1, option: option))
        canvas.mouseUp(with: event(.leftMouseUp, b, count: 1, option: option))
    }
}

@MainActor @Suite(.enabled(if: hasWindowServer, "needs a login session for a window")) struct CanvasClicks {
    @Test(.enabled(if: hasDocs)) func inTheFigureOnlyTheSelectToolChoosesTheGelUnderTheClick() throws {
        let b = try Bench(), ws = b.ws
        ws.tool = .select
        b.click(b.figurePoint(strip: 1))
        #expect(ws.activeStrip == 1 && !ws.showsGel)   // Select: chosen, and still the figure
        b.click(b.figurePoint(strip: nil))
        #expect(ws.activeStrip == nil)
        // the other tools act on the gel under the click (a tick or name belongs to it) and never change the chosen gel
        ws.tool = .ladder
        let ticks = ws.project.ladder?.bands.count ?? 0
        b.click(b.figurePoint(strip: 1, row: 0.45))
        #expect(ws.activeStrip == nil && ws.project.ladder?.bands.count == ticks + 1 && ws.project.ladder?.bands.last?.strip == 1)
        ws.tool = .names
        let names = ws.project.annotations.count
        b.click(b.figurePoint(strip: 1, row: 0.7))
        #expect(ws.activeStrip == nil && ws.project.annotations.count == names + 1 && ws.project.annotations.last?.strip == 1)
        ws.tool = .lanes
        b.click(b.figurePoint(strip: 1, x: 40, row: 0.3))
        #expect(ws.activeStrip == nil)
    }

    @Test(.enabled(if: hasDocs)) func doubleClickingAGelInTheFigureOpensItsView() throws {
        let b = try Bench(), ws = b.ws
        ws.tool = .select
        b.click(b.figurePoint(strip: nil), count: 2)
        #expect(ws.showsGel && ws.activeStrip == nil)
        ws.showFigure()
        ws.zoomRequest = nil
        b.click(b.figurePoint(strip: 1), count: 2)
        #expect(ws.showsGel && ws.activeStrip == 1 && ws.zoomRequest == .fit)
    }

    @Test(.enabled(if: hasDocs)) func aGelOnViewTakesTicksAndNamesOnItsOwnPixels() throws {
        let b = try Bench(), ws = b.ws
        ws.showGel(1)
        let mark = { Set((ws.project.ladder?.bands ?? []).filter { $0.strip == 1 }.map(\.id)) }
        let others = ws.project.ladder?.bands.filter { $0.strip == nil }.count ?? 0
        let before = mark()
        ws.tool = .ladder
        b.click(b.gelPoint(400, 200), option: true)   // option: exactly where it was clicked
        let added = (ws.project.ladder?.bands ?? []).filter { $0.strip == 1 && !before.contains($0.id) }
        #expect(added.count == 1 && abs((added.first?.y ?? 0) - 200) <= 1)
        #expect((ws.project.ladder?.bands.filter { $0.strip == nil }.count ?? 0) == others)
        // picked up with the Select tool, and moved along the gel's rows
        ws.tool = .select
        let lane = GelOps.laneX(ws.project, lane: ws.project.ladder?.lane ?? 1, strip: 1) ?? 60   // the ladder lane, on this gel
        b.click(b.gelPoint(lane, 200))
        #expect(ws.selection == .tick(added[0].id))
        b.drag(from: b.gelPoint(lane, 200), to: b.gelPoint(lane, 230), option: true)
        #expect(abs((ws.project.ladder?.bands.first { $0.id == added[0].id }?.y ?? 0) - 230) <= 1)
        ws.tool = .names
        let names = ws.project.annotations.filter { $0.strip == 1 }.count
        b.click(b.gelPoint(400, 120), option: true)
        #expect(ws.project.annotations.filter { $0.strip == 1 }.count == names + 1)
        // the gel with the lanes, on its own, works as a single gel: dividers are placed on it
        ws.showGel(nil)
        ws.tool = .lanes
        let dividers = ws.project.lanes.dividers.count
        let l = ws.shownLayout!, at = l.point(x: 1000, y: 120)
        b.click(b.place(at.x, at.y, content: l.size, gel: false))
        #expect(ws.project.lanes.dividers.count == dividers + 1)
    }

    @Test(.enabled(if: hasDocs)) func aStackedGelHasAllFourEdgesAndCornersToCrop() throws {
        let b = try Bench(), ws = b.ws
        ws.activeStrip = 1
        ws.tool = .crop   // chosen in the figure
        let w = Double(ws.activeSize.width), h = Double(ws.activeSize.height)
        func at(_ x: Double, _ y: Double) -> CGPoint { b.place(x, y, content: CGSize(width: w, height: h), gel: false) }
        func crop() -> (Double?, Double?, Double?, Double?) {
            let s = ws.project.strips[0]
            return (s.left, s.top, s.right, s.bottom)
        }
        #expect(ws.activeStripRect == PixelRect(x0: 0, y0: 0, x1: w, y1: h))   // a new gel keeps everything
        b.drag(from: at(0, 0), to: at(50, 40))   // the top left corner
        #expect(crop() == (50, 40, nil, nil) || crop() == (50, 40, w, h), "\(crop())")
        b.drag(from: at(w, h), to: at(w - 30, h - 20))   // the bottom right corner
        #expect(crop() == (50, 40, w - 30, h - 20))
        b.drag(from: at(50, 200), to: at(80, 200))   // the left edge
        #expect(crop().0 == 80)
        b.drag(from: at(w - 30, 200), to: at(w - 100, 200))   // the right edge
        #expect(crop().2 == w - 100)
        b.drag(from: at(300, 40), to: at(300, 60))   // the top edge
        #expect(crop().1 == 60)
        b.drag(from: at(300, h - 20), to: at(300, h - 70))   // the bottom edge
        #expect(crop().3 == h - 70)
        // the figure takes what the gel keeps: its columns land where the alignment puts them
        let piece = try #require(ws.stack.piece(strip: 1))
        #expect(piece.sourceLeft == 80 && piece.sourceRight == w - 100 && piece.sourceTop == 60)
        // Return keeps the crop
        b.key(36)
        #expect(ws.tool == .select && crop() == (80, 60, w - 100, h - 70))
    }

    @Test(.enabled(if: hasDocs)) func escapePutsAStackedGelsCropBackAndReturnKeepsIt() throws {
        let b = try Bench(), ws = b.ws
        ws.showGel(1)   // its own view: the same crop tool
        ws.tool = .crop
        let w = Double(ws.activeSize.width), h = Double(ws.activeSize.height)
        func at(_ x: Double, _ y: Double) -> CGPoint { b.place(x, y, content: CGSize(width: w, height: h), gel: true) }
        let whole = ws.project.strips[0]
        b.drag(from: at(0, 0), to: at(100, 60))
        b.drag(from: at(w, h), to: at(w - 40, h - 25))
        #expect(ws.project.strips[0].left == 100 && ws.project.strips[0].bottom == h - 25)
        b.key(53)   // Esc
        #expect(ws.tool == .select && ws.project.strips[0].left == whole.left && ws.project.strips[0].right == whole.right
                && ws.project.strips[0].top == whole.top && ws.project.strips[0].bottom == whole.bottom)
        // a crop that was there stays after a cancel that changed nothing, and Esc puts back what the tool began with
        ws.tool = .crop
        b.drag(from: at(0, 0), to: at(30, 20))
        b.key(36)   // Return
        #expect(ws.tool == .select && ws.project.strips[0].left == 30 && ws.project.strips[0].top == 20)
        ws.tool = .crop
        b.drag(from: at(30, 20), to: at(70, 50))
        #expect(ws.project.strips[0].left == 70)
        b.key(53)
        #expect(ws.project.strips[0].left == 30 && ws.project.strips[0].top == 20)
        // the gel with the lanes keeps working as it did: Esc leaves the tool and the crop stays
        ws.showGel(nil)
        ws.tool = .crop
        let lw = Double(ws.activeSize.width), lh = Double(ws.activeSize.height)
        b.drag(from: b.place(0, 0, content: CGSize(width: lw, height: lh), gel: false), to: b.place(40, 30, content: CGSize(width: lw, height: lh), gel: false))
        let lanesCrop = ws.project.crop
        #expect(lanesCrop != nil)
        b.key(53)
        #expect(ws.tool == .select && ws.project.crop == lanesCrop)
        // Reset on a stacked gel takes all four back to the whole gel
        ws.showGel(1)
        ws.resetCrop()
        #expect(ws.project.strips[0].left == nil && ws.project.strips[0].right == nil && ws.project.strips[0].top == nil && ws.project.strips[0].bottom == nil)
    }

    @Test(.enabled(if: hasDocs)) func draggingAGelSidewaysMovesItByThePointersDistance() throws {
        let b = try Bench(), ws = b.ws
        ws.tool = .select
        // gel 2 keeps the columns up to the figure's right edge, so moving it right makes the figure wider as it goes
        let size = ws.gelSize(1)!
        GelOps.setStripCrop(&ws.document.project, strip: 1, left: 0, top: 0, right: Double(size.width), bottom: Double(size.height), width: size.width, height: size.height)
        let before = ws.project.strips[0].shift, scale = ws.project.effectiveAlignment(1).scale
        let x = ws.crop.x0 + ws.crop.width * 0.5
        b.drag(from: b.figurePoint(strip: 1, x: x), to: b.figurePoint(strip: 1, x: x + 20))   // 20 figure pixels to the right
        #expect(abs(ws.project.strips[0].shift - (before - scale * 20)) < 0.011, "\(ws.project.strips[0].shift) from \(before)")
        // and arrows and the Shift field move it as before (the click chose it)
        #expect(ws.activeStrip == 1)
        let moved = ws.project.strips[0].shift
        ws.nudgeActiveStrip(by: 1)
        #expect(abs(ws.project.strips[0].shift - (moved - scale)) < 0.011)
        ws.setShift(12.34)
        #expect(ws.project.strips[0].shift == 12.34)
    }

    @Test(.enabled(if: hasDocs)) func aGelWithNoColumnsStartsTheCropToolAtTheColumnsItFollows() throws {
        let b = try Bench(), ws = b.ws
        // lined up as the tutorial's pieces are, with the lanes gel cropped to columns 100–900
        ws.document.edit("setup", undoManager: nil) { p in
            p.crop = PixelRect(x0: 100, y0: 20, x1: 900, y1: 200)
            p.strips[0].shift = -129.85; p.strips[0].scale = 1.0237
        }
        ws.activeStrip = 1
        ws.tool = .crop
        let w = Double(ws.activeSize.width), h = Double(ws.activeSize.height)
        func at(_ x: Double, _ y: Double) -> CGPoint { b.place(x, y, content: CGSize(width: w, height: h), gel: false) }
        // the columns under the lanes gel's crop: 1.0237 × 100 - 129.85 is before the gel starts, 1.0237 × 900 - 129.85 is 791
        #expect(ws.activeStripRect == PixelRect(x0: 0, y0: 0, x1: 791, y1: h))
        // dragging only the top edge leaves it following
        b.drag(from: at(400, 0), to: at(400, 25))
        let s = { ws.project.strips[0] }
        #expect(s().top == 25 && s().left == nil && s().right == nil)
        // dragging a side edge gives it columns of its own: the followed left edge is where it starts
        b.drag(from: at(791, 200), to: at(700, 200))
        #expect(s().left == 0 && s().right == 700)
        // Reset: all four follow again
        ws.resetCrop()
        #expect(s().left == nil && s().right == nil && s().top == nil && ws.activeStripRect == PixelRect(x0: 0, y0: 0, x1: 791, y1: h))
        // Esc puts back a following gel as it was
        b.drag(from: at(791, 200), to: at(600, 200))
        #expect(s().right == 600)
        b.key(53)
        #expect(s().left == nil && s().right == nil)
    }

    @Test(.enabled(if: hasDocs)) func draggingTheGelWithTheLanesMovesItAndNoOtherGel() throws {
        let b = try Bench(), ws = b.ws
        ws.tool = .select
        let gel2Shift = ws.project.strips[0].shift, before = ws.project.effectiveMainShift
        let x = ws.crop.x0 + ws.crop.width * 0.5, column = 300.0   // a column of gel 1, and one of gel 2's own
        let rowOfGel2 = try #require(ws.stack.piece(strip: 1)).top + 5
        func gel2Point() -> CGPoint {
            b.canvas.viewPoint(figureX: ws.stack.piece(strip: 1)!.toFigure(x: column, y: 0).x, y: rowOfGel2)!
        }
        let start = b.figurePoint(strip: nil, x: x), gel2Was = gel2Point()
        let perPx = b.canvas.viewPoint(figureX: x + 1, y: 0)!.x - b.canvas.viewPoint(figureX: x, y: 0)!.x   // view points a pixel takes
        // held 60 points to the right: gel 1 moves right by that many pixels (its shift is the number of columns it is moved left)
        let held = CGPoint(x: start.x + 60, y: start.y)
        b.canvas.mouseDown(with: b.event(.leftMouseDown, start))
        b.canvas.mouseDragged(with: b.event(.leftMouseDragged, held))
        #expect(abs((ws.project.effectiveMainShift - before) + 60 / Double(perPx)) <= 1)
        #expect(ws.project.strips[0].shift == gel2Shift)   // no other gel moved
        // it's under the pointer, and gel 2 is where it was on the screen
        let now = b.canvas.viewPoint(figureX: x, y: ws.stack.piece(strip: nil)!.top + 5)!
        #expect(abs(now.x - held.x) < 1.5, "\(now.x) against \(held.x)")
        #expect(abs(gel2Point().x - gel2Was.x) < 1.5, "\(gel2Point().x) against \(gel2Was.x)")
        b.canvas.mouseUp(with: b.event(.leftMouseUp, held))
        #expect(ws.project.strips[0].shift == gel2Shift && ws.project.effectiveMainShift < before)
        #expect(ws.activeStrip == nil)   // the click chose it
        // and a stacked gel is held the same way: it moves, gel 1 stays
        let main = ws.project.effectiveMainShift
        let p2 = b.figurePoint(strip: 1)
        b.drag(from: p2, to: CGPoint(x: p2.x - 40, y: p2.y))
        #expect(ws.project.effectiveMainShift == main && ws.project.strips[0].shift != gel2Shift)
    }

    @Test(.enabled(if: hasDocs)) func theArrowsAndTheShiftFieldMoveTheGelWithTheLanesToo() throws {
        let b = try Bench(), ws = b.ws
        ws.activeStrip = nil
        let gel2 = ws.project.strips[0].shift
        b.key(124)   // → with nothing selected
        #expect(ws.project.mainShift == -1 && ws.activeShift == -1)
        b.key(123)
        #expect(ws.project.mainShift == 0)
        ws.setShift(7.6)   // whole pixels
        #expect(ws.project.mainShift == 8 && ws.activeShift == 8)
        let scale = ws.project.strips[0].scale
        ws.setScale(1.05)   // stretch is for the stacked gels
        #expect(ws.project.strips[0].scale == scale && ws.project.strips[0].shift == gel2)
        // Auto-align lines gel 2 up with the lanes where gel 1 now sits
        ws.activeStrip = 1
        ws.setShift(0)
        ws.document.edit("setup", undoManager: nil) { $0.mainShift = 0 }
        ws.autoAlign()
        let lined = ws.project.strips[0].shift
        ws.document.edit("move gel 1", undoManager: nil) { $0.mainShift = 25 }
        ws.autoAlign()
        // x in gel 2 = scale × x in the figure + shift: gel 1 25 to the left (shift 25) leaves gel 2 where it is, so lined up to gel 1's lanes again
        // it takes 25 more figure pixels of shift
        #expect(abs(ws.project.strips[0].shift - (lined + ws.project.strips[0].scale * 25)) < 0.3, "\(ws.project.strips[0].shift) from \(lined)")
    }
}

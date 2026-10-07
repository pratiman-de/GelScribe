import CoreGraphics
import CryptoKit
import Foundation
import GelKit
import GelMCP
import ImageIO
import UniformTypeIdentifiers

/// The LLM-facing tool surface. The same tools run headless (files) or against the live app (documents).
///
/// Restrictions built in, independent of what the model asks:
/// - the original image is never written: no tool touches image bytes, and the package's copy is write-once;
/// - strict mode and pixel adjustments (rotation, levels, invert, wedge fill) have no tools at all, only the user
///   changes them, in the app;
/// - every number is checked before it reaches a project (see `Limits`), and a host runs what a tool did through
///   `GelProject.settle` before keeping it;
/// - exports never overwrite without `overwrite: true`, never write inside a project package (in any letter case),
///   and never overwrite a file whose bytes are any of the project's original images.
public enum GelTools {
    public static let instructions = """
    GelScribe labels gel and western-blot images for figures: lane labels, ladder (kDa/bp) ticks and band names.
    Typical flow: create_project (or open_project) → render_preview with guides → set_lane_dividers (use \
    suggest_lanes only as a starting point and check it on the preview) → set_lane_labels with the bench shorthand \
    (e.g. "µM: ladder|0{L|P}|50{L|P}|…") → find_ladder_bands → set_ladder → add_band_name → render_preview → export_figure.
    Coordinates are pixels of the gel image, x to the right and y down.
    Rules: never guess the ladder product or which bands are ladder bands vs. dye front, ask the user. \
    The original image is never modified and strict mode (original pixels in the figure) cannot be changed here.
    """

    public static func make(host: ProjectHost) -> [MCPTool] {
        let project: JSONValue = ["type": "string", "description": "Project id or .gelscribe path"]
        func schema(_ props: [String: JSONValue], _ required: [String] = []) -> JSONValue {
            ["type": "object", "properties": .object(props), "required": .array(required.map { .string($0) }),
             "additionalProperties": false]
        }
        let readOnly = MCPToolAnnotations(readOnlyHint: true, destructiveHint: false, openWorldHint: false)
        let edit = MCPToolAnnotations(readOnlyHint: false, destructiveHint: false, openWorldHint: false)
        let coordinates = -Limits.coordinate...Limits.coordinate

        return [
            MCPTool(name: "list_projects", description: "Projects currently open (in the app: its windows).",
                    inputSchema: schema([:]), annotations: readOnly) { _ in
                .json(try JSONValue(encoding: await host.list()))
            },

            MCPTool(name: "open_project", description: "Open a .gelscribe project and return its summary.",
                    inputSchema: schema(["path": ["type": "string"]], ["path"]), annotations: readOnly) { a in
                let info = try await host.open(path: try a.reqString("path"))
                return .json(try await summary(host, info.id))
            },

            MCPTool(name: "create_project",
                    description: "Create a .gelscribe project around a gel image (PNG/TIFF/JPEG). The image is copied byte for byte and never modified; strict mode (original pixels in the figure) is on. Saved next to the image unless save_to is given. Never inside another project.",
                    inputSchema: schema(["image_path": ["type": "string"], "save_to": ["type": "string", "description": "Path ending in .gelscribe"]], ["image_path"]),
                    annotations: edit) { a in
                let info = try await host.create(imagePath: try a.reqString("image_path"), savePath: try a.optString("save_to"))
                return .json(try await summary(host, info.id))
            },

            MCPTool(name: "get_project", description: "Everything about a project: image facts and integrity, lanes, label rows, ladder ticks, band names, crop, style.",
                    inputSchema: schema(["project": project], ["project"]), annotations: readOnly) { a in
                .json(try await summary(host, try a.reqString("project")))
            },

            MCPTool(name: "render_preview",
                    description: "Render the figure as a PNG you can look at. With guides=true, lane dividers (cyan), lane numbers and ladder tick lines (yellow) are drawn on top so you can check placement.",
                    inputSchema: schema(["project": project, "guides": ["type": "boolean"], "width": ["type": "integer", "description": "Max width in px, default 1400"]], ["project"]),
                    annotations: readOnly) { a in
                let guides = try a.optBool("guides") ?? true
                let width = try a.optInt("width", 1...1_000_000) ?? 1400
                let png: Data = try await host.access(try a.reqString("project"), action: nil) { p, w in
                    try Preview.png(p, w, guides: guides, maxWidth: max(200, min(width, 4000)))
                }
                return MCPToolResult(content: [.image(png, mimeType: "image/png"),
                                               .text(guides ? "Guides on: cyan = lane dividers with lane numbers, yellow = ladder ticks." : "Exact figure.")])
            },

            MCPTool(name: "suggest_lanes",
                    description: "Automatic lane detection, for a first guess only: returns lane centers and the divider x positions between them. Changes nothing; check it on render_preview, then call set_lane_dividers.",
                    inputSchema: schema(["project": project, "count": ["type": "integer", "description": "Expected number of lanes including the ladder (2 or more)"]], ["project"]),
                    annotations: readOnly) { a in
                let count = try a.optInt("count", 2...Limits.lanes)
                let fit: LaneFit = try await host.access(try a.reqString("project"), action: nil) { p, w in
                    Detect.lanes(in: w.darkness(bandsDark: p.display.bandsDark), count: count)
                }
                let mids = zip(fit.centers, fit.centers.dropFirst()).map { (($0 + $1) / 2).rounded() }
                return .json(["lane_centers": .array(fit.centers.map { .number($0) }), "suggested_dividers": .array(mids.map { .number($0) }),
                              "pitch": .number(fit.pitch), "lane_width": .number(fit.width)])
            },

            MCPTool(name: "set_lane_dividers",
                    description: "Replace the lane dividers with vertical lines at these x positions (one per gap between lanes, inside the image). With outer_lanes (default true) the strips before the first and after the last divider are lanes too, so N dividers make N+1 lanes.",
                    inputSchema: schema(["project": project, "x": ["type": "array", "items": ["type": "number"]], "outer_lanes": ["type": "boolean"]], ["project", "x"]),
                    annotations: edit) { a in
                let xs = try a.numbers("x", in: coordinates, atMost: Limits.lanes - 1)
                let outer = try a.optBool("outer_lanes")
                let r: JSONValue = try await host.access(try a.reqString("project"), action: "Set Lane Dividers") { p, w in
                    guard xs.allSatisfy({ $0 >= 0 && $0 <= Double(w.width) }) else {
                        throw MCPToolError("x positions must be inside the image, from 0 to \(w.width).")
                    }
                    if let outer { p.lanes.outerLanes = outer }
                    GelOps.setDividers(&p, xs: xs, imageWidth: w.width, imageHeight: w.height)
                    return ["lanes": .number(Double(p.laneCount)), "lane_centers": .array(p.lanes.centers.map { .number($0) })]
                }
                return .json(r)
            },

            MCPTool(name: "set_lane_labels",
                    description: "Label lanes with one entry per lane separated by |. Braces put lanes under a label, to any depth up to \(QuickLabels.maxDepth): \"ladder|0{L|P}|50{L|P}|200{}\" gives a row 0, 50, 200 over lane labels L P L P and a blank lane; \"WT{0{L|P}|50{L|P}}|KO{0{L|P}|50{L|P}}\" gives three rows. X{} is X over one blank lane. A ladder word marks the ladder lane. Row titles can lead, from the top: \"Strain, µM: …\"; group_row_name titles the row right above the lane labels (e.g. \"µM\").",
                    inputSchema: schema(["project": project, "labels": ["type": "string"], "group_row_name": ["type": "string"]], ["project", "labels"]),
                    annotations: edit) { a in
                let text = try a.reqString("labels", max: Limits.shorthand)
                let name = try a.optString("group_row_name")
                let r: JSONValue = try await host.access(try a.reqString("project"), action: "Set Lane Labels") { p, _ in
                    guard p.laneCount > 0 else { throw MCPToolError("No lanes yet: call set_lane_dividers first.") }
                    let res = GelOps.applyQuickLabels(&p, text: text, groupRowName: name)
                    if let error = res.error { throw MCPToolError(error) }   // refused (nested too deep): nothing changed
                    return ["rows": rowsJSON(p), "ladder_lane": res.ladderLane.map { .number(Double($0)) } ?? .null,
                            "warnings": .array(res.warnings.map { .string($0) })]
                }
                return .json(r)
            },

            MCPTool(name: "set_row_name", description: "Title a label row (row 0 is the one right above the gel), e.g. \"µM\".",
                    inputSchema: schema(["project": project, "row": ["type": "integer"], "name": ["type": "string"]], ["project", "row", "name"]),
                    annotations: edit) { a in
                let row = try a.reqInt("row", 0...Limits.rows), name = try a.reqString("name")
                let r: JSONValue = try await host.access(try a.reqString("project"), action: "Row Title") { p, _ in
                    guard p.rows.indices.contains(row) else { throw MCPToolError("row \(row) doesn't exist (have \(p.rows.count))") }
                    p.rows[row].name = name
                    return rowsJSON(p)
                }
                return .json(r)
            },

            MCPTool(name: "list_ladder_presets", description: "Ladder presets (sizes largest first) with vendor sources.",
                    inputSchema: schema(["unit": ["type": "string", "enum": ["kDa", "bp"]]]), annotations: readOnly) { a in
                let unit = try a.optString("unit", max: 32)
                let list = LadderLibrary.all().filter { unit == nil || $0.unit == unit }.map { p -> JSONValue in
                    ["id": .string(p.id), "name": .string(p.displayName), "unit": .string(p.unit),
                     "sizes": .array(p.sizes.map { .number($0) }), "notes": .string(p.notes), "source": .string(p.source),
                     "gel_systems": .array(p.systems.map { ["id": .string($0.id), "name": .string($0.name), "sizes": .array($0.sizes.map { .number($0) })] })]
                }
                return .json(.array(list))
            },

            MCPTool(name: "find_ladder_bands",
                    description: "Detect bands in the ladder lane (or any lane): y centers (half-max midpoints, safe on saturated bands), width and prominence. Changes nothing. Decide with the user which are ladder bands.",
                    inputSchema: schema(["project": project, "lane": ["type": "integer"]], ["project"]), annotations: readOnly) { a in
                let lane = try a.optInt("lane", 1...Limits.lanes)
                let r: JSONValue = try await host.access(try a.reqString("project"), action: nil) { p, w in
                    let n = lane ?? p.ladder?.lane ?? 1
                    guard n >= 1, n <= p.laneCount else { throw MCPToolError("lane \(n) doesn't exist (have \(p.laneCount))") }
                    let bands = Detect.bands(in: w.darkness(bandsDark: p.display.bandsDark), center: p.lanes.centers[n - 1], width: p.lanes.width)
                    return ["lane": .number(Double(n)), "bands": .array(bands.map { ["y": .number($0.y), "fwhm": .number($0.fwhm), "prominence": .number($0.prominence)] })]
                }
                return .json(r)
            },

            MCPTool(name: "set_ladder",
                    description: "Set the ladder ticks on the gel with the lanes (replaces its existing ones; other stacked gels keep theirs, sizes included). Each band has y and optionally size or ignore. A tick is kept inside the rows the figure shows. With snap (default true) each y moves to the band center in the ladder lane. With a preset and no sizes, sizes are assigned top-down to the non-ignored bands of the gel with the lanes (marked as guesses), counted the way the app counts: a gel with its own ladder starts again from the top of the list. Prestained ladders run at different apparent sizes per gel and buffer: pass gel_system (see list_ladder_presets) and ask the user which gel they ran.",
                    inputSchema: schema([
                        "project": project, "lane": ["type": "integer"], "preset": ["type": "string", "description": "Preset id, catalog number or name"],
                        "gel_system": ["type": "string", "description": "e.g. bt-4-12-mops or \"Tris-glycine 4–20%\""],
                        "unit": ["type": "string"], "side": ["type": "string", "enum": ["left", "right"]], "snap": ["type": "boolean"],
                        "bands": ["type": "array", "items": ["type": "object", "properties": ["y": ["type": "number"], "size": ["type": ["number", "null"]], "ignore": ["type": "boolean"]], "required": ["y"]]],
                    ], ["project", "bands"]),
                    annotations: edit) { a in
                let presetQuery = try a.optString("preset")
                let preset = try presetQuery.map { q in try LadderLibrary.find(q) ?? { throw MCPToolError("unknown preset \(q); see list_ladder_presets") }() }
                let systemKey = try a.optString("gel_system")
                if let key = systemKey, let pr = preset, pr.system(named: key) == nil {
                    throw MCPToolError("\(pr.name) has no gel system \(key); options: " + pr.systems.map { "\($0.id) (\($0.name))" }.joined(separator: ", "))
                }
                let lane = try a.optInt("lane", 1...Limits.lanes), unit = try a.optString("unit", max: 32)
                let side = try a.optString("side", max: 16).map { name -> LadderSide in
                    guard let s = LadderSide(rawValue: name) else { throw MCPToolError("side must be left or right.") }
                    return s
                }
                let snap = try a.optBool("snap") ?? true
                guard let raw = a["bands"]?.arrayValue else { throw MCPToolError("bands must be a list.") }
                guard raw.count <= Limits.ticks else { throw MCPToolError("bands has too many entries (at most \(Limits.ticks)).") }
                let bands: [(y: Double, size: Double?, ignore: Bool)] = try raw.map { b in
                    guard b.objectValue != nil else { throw MCPToolError("every band must be an object with y.") }
                    return (try b.reqNumber("y", coordinates), try b.optSize("size"), try b.optBool("ignore") ?? false)
                }
                let r: JSONValue = try await host.access(try a.reqString("project"), action: "Set Ladder") { p, w in
                    var ladder = p.ladder ?? Ladder()
                    if let lane { ladder.lane = lane }
                    guard ladder.lane >= 1, ladder.lane <= max(1, p.laneCount) else { throw MCPToolError("lane \(ladder.lane) doesn't exist") }
                    if let side { ladder.side = side }
                    let rows = p.figureRows(strip: nil, width: w.width, height: w.height)
                    let dark = w.darkness(bandsDark: p.display.bandsDark)
                    let cx = p.laneCount >= ladder.lane ? p.lanes.centers[ladder.lane - 1] : 0
                    var notes: [String] = []
                    var mine: [LadderBand] = []
                    for (y0, size, ignore) in bands {
                        var y = p.clampY(y0, strip: nil, width: w.width, height: w.height)   // a tick belongs inside the figure's rows
                        if y != y0 { notes.append(movedNote("A tick at y \(Int(y0.rounded()))", to: y, rows)) }
                        if snap, p.laneCount > 0 { y = Detect.snapBand(in: dark, x: cx, y: y, laneWidth: p.lanes.width, rows: rows) ?? y }
                        mine.append(LadderBand(y: y, size: size, ignore: ignore))
                    }
                    ladder.bands = (mine + ladder.bands.filter { $0.strip != nil }).sorted { p.stackKey($0.strip, $0.y) < p.stackKey($1.strip, $1.y) }
                    if let preset {
                        ladder.name = preset.displayName
                        ladder.unit = preset.unit
                        let sys = preset.system(named: systemKey ?? ladder.system) ?? preset.systems.first
                        ladder.system = sys?.name
                        ladder.sizes = sys?.sizes ?? preset.sizes
                    }
                    if let unit { ladder.unit = unit }
                    p.ladder = ladder
                    if preset != nil, bands.allSatisfy({ $0.size == nil }) {
                        // Guesses for this gel's ticks only, counted as Assign top-down counts (gels that carry one ladder on, a gel with
                        // its own ladder starting again, ticks a crop hides left out); the other gels keep the sizes they have.
                        var q = p
                        q.assignLadder(sizes: ladder.sizes ?? [])
                        let guessed = Dictionary(q.ladder?.bands.map { ($0.id, $0) } ?? [], uniquingKeysWith: { a, _ in a })
                        for i in p.ladder!.bands.indices where p.ladder!.bands[i].strip == nil {
                            if let g = guessed[p.ladder!.bands[i].id] { p.ladder!.bands[i].size = g.size; p.ladder!.bands[i].auto = g.auto }
                        }
                    }
                    return ladderJSON(p.ladder!, p, notes: notes)
                }
                return .json(r)
            },

            MCPTool(name: "add_band_name",
                    description: "Name a band at the gel edge (e.g. a protein name). y is where the band is; with snap (default true) it moves to the band center in `lane` (default: the lane nearest that edge), which matters on tilted gels. A name is kept inside the rows the figure shows.",
                    inputSchema: schema(["project": project, "text": ["type": "string"], "y": ["type": "number"], "lane": ["type": "integer"],
                                         "marker": ["type": "string", "enum": ["arrow", "tick", "bracket", "none"]], "y2": ["type": "number"],
                                         "side": ["type": "string", "enum": ["left", "right"]], "italic": ["type": "boolean"], "snap": ["type": "boolean"]],
                                        ["project", "text", "y"]),
                    annotations: edit) { a in
                let text = try a.reqString("text"), y0 = try a.reqNumber("y", coordinates)
                let marker = try a.optString("marker", max: 16).map { name -> AnnotationMarker in
                    guard let m = AnnotationMarker(rawValue: name) else { throw MCPToolError("marker must be arrow, tick, bracket or none.") }
                    return m
                } ?? .arrow
                let side = try a.optString("side", max: 16).map { name -> LadderSide in
                    guard let s = LadderSide(rawValue: name) else { throw MCPToolError("side must be left or right.") }
                    return s
                }
                let lane = try a.optInt("lane", 1...Limits.lanes), snap = try a.optBool("snap") ?? true
                let italic = try a.optBool("italic") ?? false, y2 = try a.optNumber("y2", coordinates)
                let r: JSONValue = try await host.access(try a.reqString("project"), action: "Add Band Name") { p, w in
                    let s = side ?? (p.ladder?.side == .right ? .left : .right)
                    let rows = p.figureRows(strip: nil, width: w.width, height: w.height)
                    var notes: [String] = []
                    var y = p.clampY(y0, strip: nil, width: w.width, height: w.height)   // a name belongs inside the figure's rows
                    if y != y0 { notes.append(movedNote("The name at y \(Int(y0.rounded()))", to: y, rows)) }
                    if snap, p.laneCount > 0 {
                        let n = lane ?? (s == .right ? p.laneCount : 1)
                        guard n >= 1, n <= p.laneCount else { throw MCPToolError("lane \(n) doesn't exist (have \(p.laneCount))") }
                        y = Detect.snapBand(in: w.darkness(bandsDark: p.display.bandsDark), x: p.lanes.centers[n - 1], y: y, laneWidth: p.lanes.width, rows: rows) ?? y
                    }
                    let end = y2.map { p.clampY($0, strip: nil, width: w.width, height: w.height) }
                    p.annotations.append(BandAnnotation(y: y, y2: end, text: text, marker: marker, side: s, italic: italic))
                    var out: [String: JSONValue] = ["names": .array(p.annotations.map { gel(["text": .string($0.text), "y": .number($0.y), "marker": .string($0.marker.rawValue), "side": .string($0.side.rawValue)], $0.strip, p) })]
                    if !notes.isEmpty { out["warnings"] = .array(notes.map { .string($0) }) }
                    return .object(out)
                }
                return .json(r)
            },

            MCPTool(name: "remove_band_name", description: "Remove band names with this text.",
                    inputSchema: schema(["project": project, "text": ["type": "string"]], ["project", "text"]), annotations: edit) { a in
                let text = try a.reqString("text")
                let n: Int = try await host.access(try a.reqString("project"), action: "Remove Band Name") { p, _ in
                    GelOps.removeAnnotations(&p) { $0.text == text }   // the other names keep their own text sizes
                }
                return .text("removed \(n)")
            },

            MCPTool(name: "measure_lane",
                    description: "Bands in a lane with apparent sizes read off the ladder (log-linear between ladder ticks; flagged when extrapolated). Only as accurate as the gel is straight.",
                    inputSchema: schema(["project": project, "lane": ["type": "integer"]], ["project", "lane"]), annotations: readOnly) { a in
                let lane = try a.reqInt("lane", 1...Limits.lanes)
                let bands: [GelOps.MeasuredBand] = try await host.access(try a.reqString("project"), action: nil) { p, w in
                    guard lane >= 1, lane <= p.laneCount else { throw MCPToolError("lane \(lane) doesn't exist (have \(p.laneCount))") }
                    // a size that can't be worked out (two ticks on one row) is left out rather than written as a non-number
                    return GelOps.measureLane(p, w, lane: lane).map { b in
                        var b = b
                        if let s = b.apparentSize, !s.isFinite { b.apparentSize = nil }
                        return b
                    }
                }
                return .json(try JSONValue(encoding: bands))
            },

            MCPTool(name: "set_title", description: "Bold title above the figure, e.g. \"RPS6\". Empty string removes it.",
                    inputSchema: schema(["project": project, "title": ["type": "string"]], ["project", "title"]), annotations: edit) { a in
                let t = try a.reqString("title")
                try await host.access(try a.reqString("project"), action: "Title") { p, _ in p.title = t.isEmpty ? nil : t }
                return .text("ok")
            },

            MCPTool(name: "set_crop",
                    description: "Crop the gel region shown (selection only; pixels are never altered). Give x0,y0,x1,y1, or fit=true to hug the lanes and stop below the lowest labeled ladder band, or reset=true.",
                    inputSchema: schema(["project": project, "x0": ["type": "number"], "y0": ["type": "number"], "x1": ["type": "number"], "y1": ["type": "number"],
                                         "fit": ["type": "boolean"], "reset": ["type": "boolean"]], ["project"]), annotations: edit) { a in
                let fit = try a.optBool("fit") ?? false, reset = try a.optBool("reset") ?? false
                let v = try ["x0", "y0", "x1", "y1"].compactMap { try a.optNumber($0, coordinates) }
                let r: JSONValue = try await host.access(try a.reqString("project"), action: "Crop") { p, w in
                    if reset { p.crop = nil }
                    else if fit { p.crop = GelOps.suggestCrop(p, imageWidth: w.width, imageHeight: w.height) }
                    else if v.count == 4 { p.crop = PixelRect(x0: v[0], y0: v[1], x1: v[2], y1: v[3]).normalized(width: w.width, height: w.height) }
                    else { throw MCPToolError("give x0,y0,x1,y1 or fit/reset") }
                    p.syncLaneCenters(imageWidth: w.width, imageHeight: w.height)
                    let c = p.effectiveCrop(width: w.width, height: w.height)
                    return ["x0": .number(c.x0), "y0": .number(c.y0), "x1": .number(c.x1), "y1": .number(c.y1)]
                }
                return .json(r)
            },

            MCPTool(name: "set_style", description: "Typography and layout of the labels (never the gel pixels).",
                    inputSchema: schema(["project": project, "font": ["type": "string"], "size": ["type": "number"], "title_size": ["type": "number"],
                                         "gel_width_in": ["type": "number"], "line_width_pt": ["type": "number"], "tick_len_pt": ["type": "number"],
                                         "border": ["type": "boolean"]], ["project"]), annotations: edit) { a in
                let font = try a.optString("font", max: 128)
                if font?.isEmpty == true { throw MCPToolError("font can't be empty.") }
                let size = try a.optNumber("size", coordinates), titleSize = try a.optNumber("title_size", coordinates)
                let gelWidth = try a.optNumber("gel_width_in", coordinates), lineWidth = try a.optNumber("line_width_pt", coordinates)
                let tickLen = try a.optNumber("tick_len_pt", coordinates), border = try a.optBool("border")
                let r: JSONValue = try await host.access(try a.reqString("project"), action: "Style") { p, _ in
                    if let font { p.style.font = font }
                    if let size { p.style.size = min(max(size, 4), 24) }
                    if let titleSize { p.style.titleSize = min(max(titleSize, 4), 36) }
                    if let gelWidth { p.style.gelWidthIn = min(max(gelWidth, 0.5), 12) }
                    if let lineWidth { p.style.lineWidthPt = min(max(lineWidth, 0.1), 4) }
                    if let tickLen { p.style.tickLenPt = min(max(tickLen, 0.5), 12) }
                    if let border { p.style.border = border }
                    return try JSONValue(encoding: p.style)
                }
                return .json(r)
            },

            MCPTool(name: "export_figure",
                    description: "Write the figure: pdf (vector text), png/tiff (native resolution, gel pixels 1:1) or svg. Needs an absolute path; won't overwrite without overwrite=true, won't write inside a project package, and never overwrites an original image of the project (the gel with the lanes or any other gel).",
                    inputSchema: schema(["project": project, "format": ["type": "string", "enum": ["pdf", "png", "tiff", "svg"]], "path": ["type": "string"],
                                         "overwrite": ["type": "boolean"]], ["project", "format", "path"]),
                    annotations: MCPToolAnnotations(readOnlyHint: false, destructiveHint: false, idempotentHint: true, openWorldHint: false)) { a in
                let format = try a.reqString("format", max: 16)
                guard ["pdf", "png", "tiff", "svg"].contains(format) else { throw MCPToolError("format must be pdf, png, tiff or svg.") }
                var path = try a.reqString("path")
                let overwrite = try a.optBool("overwrite") ?? false
                path = (path as NSString).expandingTildeInPath
                guard path.hasPrefix("/") else { throw MCPToolError("path must be absolute") }
                if (path as NSString).pathExtension.lowercased() != format { path += "." + format }
                let url = URL(fileURLWithPath: path).standardizedFileURL
                guard !PathRules.isInsideProject(url, orSelf: true) else { throw MCPToolError("refusing to write inside a project package") }
                let (data, originals): (Data, Set<String>) = try await host.access(try a.reqString("project"), action: nil) { p, w in
                    (try Preview.export(p, w, format: format), originalHashes(p, w))
                }
                let fm = FileManager.default
                if fm.fileExists(atPath: url.path) {
                    // whatever the path says (another spelling, a link), a file with the bytes of an original image is one
                    if let have = sha256(ofFileAt: url), originals.contains(have) {
                        throw MCPToolError("refusing: \(url.path) is an original image of the project")
                    }
                    guard overwrite else { throw MCPToolError("\(url.path) exists; pass overwrite=true to replace it") }
                }
                try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try data.write(to: url, options: .atomic)
                return .json(["path": .string(url.path), "bytes": .number(Double(data.count))])
            },

            MCPTool(name: "copy_labels",
                    description: "Copy one project's naming scheme onto another: label rows, row titles, title, band names, ladder settings (preset, gel system, sizes) and text sizes. Only the marks of the gel with the lanes go; other stacked gels' marks stay out. With with_positions, also lane dividers, crop and tick positions (same framing only). Never touches the target's image, strict mode or export resolution.",
                    inputSchema: schema(["from": project, "to": project, "with_positions": ["type": "boolean"]], ["from", "to"]),
                    annotations: edit) { a in
                let withPositions = try a.optBool("with_positions") ?? false
                let scheme: LabelScheme = try await host.access(try a.reqString("from"), action: nil) { p, _ in LabelScheme(from: p, positions: withPositions) }
                let r: JSONValue = try await host.access(try a.reqString("to"), action: "Paste Labels") { p, w in
                    let dpi = p.style.exportDPI
                    scheme.apply(to: &p, imageWidth: w.width, imageHeight: w.height)
                    p.style.exportDPI = dpi   // the resolution belongs to the project it was set on, never to a scheme
                    return ["rows": rowsJSON(p), "lanes": .number(Double(p.laneCount))]
                }
                return .json(r)
            },

            MCPTool(name: "verify_image", description: "Check the project's images (the gel with the lanes and every other gel) still match the SHA-256 recorded when each was imported.",
                    inputSchema: schema(["project": project], ["project"]), annotations: readOnly) { a in
                let r: JSONValue = try await host.access(try a.reqString("project"), action: nil) { p, w in
                    var verdicts: [Bool?] = [p.imageSHA256.map { $0 == w.source.sha256 }]
                    var out: [String: JSONValue] = ["recorded": p.imageSHA256.map { .string($0) } ?? .null, "actual": .string(w.source.sha256)]
                    var gels: [JSONValue] = []
                    for (i, s) in p.strips.enumerated() {
                        let actual = i < w.strips.count ? w.strips[i].source.sha256 : nil
                        let ok = s.imageSHA256.map { $0 == actual }
                        verdicts.append(ok)
                        gels.append(["gel": .number(Double(p.position(of: i + 1) + 1)), "image": .string(s.image),
                                     "recorded": s.imageSHA256.map { .string($0) } ?? .null, "actual": actual.map { .string($0) } ?? .null,
                                     "intact": ok.map { .bool($0) } ?? .null])
                    }
                    out["intact"] = verdicts.contains(false) ? .bool(false) : verdicts.contains(true) ? .bool(true) : .null
                    if !gels.isEmpty { out["gels"] = .array(gels) }
                    return .object(out)
                }
                return .json(r)
            },
        ]
    }

    // MARK: summaries

    static func summary(_ host: ProjectHost, _ id: String) async throws -> JSONValue {
        try await host.access(id, action: nil) { p, w in
            let s = w.source
            let c = p.effectiveCrop(width: w.width, height: w.height)
            return [
                "id": .string(id),
                "image": ["name": .string(p.image), "width": .number(Double(s.width)), "height": .number(Double(s.height)),
                          "bits_per_component": .number(Double(s.bitsPerComponent)), "color": .string(s.colorModel),
                          "sha256": .string(s.sha256), "intact": p.imageSHA256.map { .bool($0 == s.sha256) } ?? .null],
                // the gel with the lanes' setting; each gel's own is in "gels" (a gel with none follows this one)
                "strict": .bool(p.strict),
                // the line between stacked gels: its colour ("black", "white" or "#rrggbb") and thickness (pt; the figure's lines' when not set)
                "separator": .string(p.separatorColor.name),
                "separator_width": .number(p.effectiveSeparatorWidth),
                "title": p.title.map { .string($0) } ?? .null,
                "crop": ["x0": .number(c.x0), "y0": .number(c.y0), "x1": .number(c.x1), "y1": .number(c.y1)],
                "lanes": ["count": .number(Double(p.laneCount)), "outer_lanes": .bool(p.lanes.outerLanes),
                          "dividers_x": .array(p.lanes.dividers.map { .number((($0.xTop + $0.xBottom) / 2).rounded()) }),
                          "centers": .array(p.lanes.centers.map { .number($0) })],
                "rows": rowsJSON(p),
                "ladder": p.ladder.map { ladderJSON($0, p) } ?? .null,
                "annotations": .array(p.annotations.map { a in
                    gel(["text": .string(a.text), "y": .number(a.y), "marker": .string(a.marker.rawValue), "side": .string(a.side.rawValue)], a.strip, p)
                }),
                "style": (try? JSONValue(encoding: p.style)) ?? .null,
                // more gels stacked with the image, top to bottom; with them, every mark carries "gel" (its gel's
                // number from the top), and y is in that gel's own pixels. "own_ladder" (only when true): that gel's
                // ladder sizes start again from the top of the list instead of carrying on from the gel above
                "gels": p.strips.isEmpty ? .array([]) : .array(p.stackOrder.enumerated().map { n, k -> JSONValue in
                    var o: [String: JSONValue]
                    if let k {
                        let s = p.strips[k - 1], a = p.effectiveAlignment(k)
                        o = ["gel": .number(Double(n + 1)), "image": .string(s.image), "lanes": .bool(false),
                             "strict": .bool(p.isStrict(gel: k)),
                             "shift": .number(a.shift), "scale": .number(a.scale),
                             "rows": s.top == nil && s.bottom == nil ? .null : .array([.number(s.top ?? 0), s.bottom.map { .number($0) } ?? .null]),
                             // the columns the gel was given; null = the ones under the gel with the lanes' crop (what a gel follows)
                             "columns": s.left == nil && s.right == nil ? .null : .array([.number(s.left ?? 0), s.right.map { .number($0) } ?? .null])]
                    } else {
                        o = ["gel": .number(Double(n + 1)), "image": .string(p.image), "lanes": .bool(true), "strict": .bool(p.strict)]
                    }
                    if p.hasOwnLadder(k) { o["own_ladder"] = .bool(true) }
                    return .object(o)
                }),
            ]
        }
    }

    static func rowsJSON(_ p: GelProject) -> JSONValue {
        .array(p.rows.enumerated().map { i, r in
            var o: [String: JSONValue] = ["row": .number(Double(i)), "type": .string(r.type.rawValue), "name": r.name.map { .string($0) } ?? .null]
            if r.type == .lanes { o["labels"] = .array(r.labels.map { .string($0) }) }
            else { o["groups"] = .array(r.groups.map { ["text": .string($0.text), "lanes": .array($0.lanes.map { .number(Double($0)) })] }) }
            return .object(o)
        })
    }

    /// The ladder; "warnings" (when there are any) are `notes` and the project's own ladder warnings, which read each
    /// ladder group top to bottom and leave out ticks a crop hides.
    static func ladderJSON(_ l: Ladder, _ p: GelProject, notes: [String] = []) -> JSONValue {
        var o: [String: JSONValue] = [
            "lane": .number(Double(l.lane)), "name": l.name.map { .string($0) } ?? .null, "unit": .string(l.unit), "side": .string(l.side.rawValue),
            "gel_system": l.system.map { .string($0) } ?? .null,
            "bands": .array(l.bands.map { b in
                gel(["y": .number(b.y), "size": b.size.map { .number($0) } ?? .null, "ignore": .bool(b.ignore), "guess": .bool(b.auto)], b.strip, p)
            })]
        let warnings = notes + p.ladderWarnings
        if !warnings.isEmpty { o["warnings"] = .array(warnings.map { .string($0) }) }
        return .object(o)
    }

    /// A mark's JSON; with more than one gel, "gel" says which (numbered from the top).
    static func gel(_ o: [String: JSONValue], _ strip: Int?, _ p: GelProject) -> JSONValue {
        var o = o
        if !p.strips.isEmpty { o["gel"] = .number(Double(p.position(of: strip) + 1)) }
        return .object(o)
    }

    /// "A tick at y 3000 is outside the rows shown in the figure (100 to 900), so it was moved to 900."
    static func movedNote(_ what: String, to y: Double, _ rows: ClosedRange<Double>) -> String {
        "\(what) is outside the rows shown in the figure (\(Int(rows.lowerBound)) to \(Int(rows.upperBound))), so it was moved to \(Int(y.rounded()))."
    }

    // MARK: protecting the originals

    /// SHA-256 of every original image the project is made of, as recorded and as loaded: no file with these bytes may
    /// be overwritten by an export. (A bare JSON config records no hash, so the loaded bytes count too.)
    static func originalHashes(_ p: GelProject, _ w: WorkingImage) -> Set<String> {
        var s: Set<String> = [w.source.sha256]
        if let h = p.imageSHA256 { s.insert(h) }
        for strip in w.strips { s.insert(strip.source.sha256) }
        for strip in p.strips { if let h = strip.imageSHA256 { s.insert(h) } }
        return s
    }

    /// SHA-256 (hex) of a file, read in pieces so a big file isn't held in memory.
    static func sha256(ofFileAt url: URL) -> String? {
        guard let h = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? h.close() }
        var hasher = SHA256()
        while let chunk = try? h.read(upToCount: 1 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

// MARK: - rendering for tools

enum Preview {
    static func export(_ p: GelProject, _ w: WorkingImage, format: String) throws -> Data {
        // the whole figure, a cut membrane's strips included; PNG/TIFF at the resolution the user set in the app
        let fig = StackedFigure(project: p, main: w)
        if let missing = fig.unreadableGel { throw MCPToolError(missing) }   // never a figure with a gel left out
        if let problem = fig.strictProblem {
            throw MCPToolError("The gels that keep their original pixels can't be stacked untouched: \(problem). Turn off Keep original pixels for a gel in the app to export.")
        }
        let type: UTType
        switch format {
        case "pdf": type = .pdf
        case "png": type = .png
        case "tiff": type = .tiff
        case "svg": type = .svg
        default: throw MCPToolError("unknown format \(format)")
        }
        return try fig.export(type).orThrow(StackedFigure.tooLargeMessage)   // (a gel's picture or the file too large to make)
    }

    /// Downscaled RGB preview, optionally with editing guides.
    static func png(_ p: GelProject, _ w: WorkingImage, guides: Bool, maxWidth: Int) throws -> Data {
        // a preview: when the gels that keep their original pixels can't be stacked untouched, they're shown processed rather than not at all
        var fig = StackedFigure(project: p, main: w)
        if let missing = fig.unreadableGel { throw MCPToolError(missing) }
        if fig.strictProblem != nil {
            var q = p
            q.strict = false
            for i in q.strips.indices { q.strips[i].strict = false }
            fig = StackedFigure(project: q, main: w)
        }
        guard let gel = fig.gel else { throw MCPToolError(StackedFigure.tooLargeMessage) }   // never blank space where the gels go
        let layout = fig.layout
        let scale = min(Double(maxWidth) / max(layout.size.width, 1), 4)
        let W = max(1, (layout.size.width * scale).safeInt), H = max(1, (layout.size.height * scale).safeInt)
        guard W <= 20_000, H <= 20_000, W * H <= 60_000_000 else { throw MCPToolError("The preview would be too large. Use a smaller width.") }
        guard let ctx = CGContext(data: nil, width: W, height: H, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        else { throw MCPToolError("render failed") }
        ctx.setFillColor(CGColor(gray: 1, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: W, height: H))
        FigureRenderer.flipForPoints(ctx, height: layout.size.height, scale: scale)
        FigureRenderer.draw(layout, gel: gel, in: ctx, interpolate: true)
        if guides {
            let crop = layout.crop, Hh = Double(w.height)
            let cyan = CGColor(red: 0, green: 0.7, blue: 1, alpha: 0.9), yellow = CGColor(red: 1, green: 0.75, blue: 0, alpha: 0.9)
            ctx.setLineWidth(1.2 / scale * 2)
            ctx.setStrokeColor(cyan)
            for d in p.lanes.dividers {
                ctx.beginPath()
                ctx.move(to: layout.point(x: d.x(atY: crop.y0, height: Hh), y: crop.y0))
                ctx.addLine(to: layout.point(x: d.x(atY: crop.y1, height: Hh), y: crop.y1))
                ctx.strokePath()
            }
            let font = FontSpec(family: "Helvetica", size: 6, bold: true)
            for (i, c) in p.lanes.centers.enumerated() {
                let pt = layout.point(x: c, y: crop.y0)
                let t = FigureText(string: "\(i + 1)", font: font, origin: CGPoint(x: pt.x, y: pt.y + 8), align: .center,
                                   rotation: 0, role: .title, bounds: .zero)
                ctx.setFillColor(cyan)
                ctx.fillEllipse(in: CGRect(x: pt.x - 5, y: pt.y + 1.5, width: 10, height: 9))
                ctx.setFillColor(CGColor(gray: 0, alpha: 1))
                FigureRenderer.drawText(t, in: ctx)
            }
            if let l = p.ladder {
                ctx.setStrokeColor(yellow)
                for b in l.bands {
                    guard let fy = fig.stack.figureY(strip: b.strip, y: b.y, inside: false) else { continue }
                    let a = layout.point(x: crop.x0, y: fy), z = layout.point(x: crop.x1, y: fy)
                    ctx.setLineDash(phase: 0, lengths: b.size == nil ? [2, 2] : [])
                    ctx.beginPath(); ctx.move(to: a); ctx.addLine(to: CGPoint(x: z.x, y: z.y)); ctx.strokePath()
                }
                ctx.setLineDash(phase: 0, lengths: [])
            }
        }
        guard let img = ctx.makeImage() else { throw MCPToolError("render failed") }
        return FigureRenderer.encode(img, as: .png, dpi: 72 * scale, info: ExportInfo(title: "preview", description: "GelScribe preview"))
    }
}

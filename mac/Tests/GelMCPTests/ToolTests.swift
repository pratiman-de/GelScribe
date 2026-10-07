import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import GelKit
@testable import GelMCP
@testable import GelService

// The LLM tools, run the way a client runs them: JSON-RPC into an MCPServer over a FileProjectHost, on projects in a
// folder of their own. Images are made up here.

/// An 8-bit gray PNG of a made-up blot: dark lanes with bands at `bandRows` on a light background (`seed` makes
/// otherwise equal images differ).
private func gelPNG(width: Int = 620, height: Int = 300, seed: Int = 0, bandRows: [Int] = [60, 110, 160, 210]) -> Data {
    let lanes = (0..<8).map { 60 + 70 * Double($0) }
    var px = [UInt8](repeating: 0, count: width * height)
    for y in 0..<height {
        for x in 0..<width {
            var v = Double(200 + (x * 7 + y * 3 + seed) % 40)
            for c in lanes where abs(Double(x) - c) < 26 {
                let across = exp(-pow((Double(x) - c) / 10, 2) / 2)
                for r in bandRows { v -= 170 * across * exp(-pow(Double(y - r) / 4, 2) / 2) }
            }
            px[y * width + x] = UInt8(max(0, min(255, v.rounded())))
        }
    }
    let img = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: width,
                      space: CGColorSpace(name: CGColorSpace.genericGrayGamma2_2)!,
                      bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                      provider: CGDataProvider(data: Data(px) as CFData)!, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
    let out = NSMutableData()
    let dest = CGImageDestinationCreateWithData(out, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, img, nil)
    CGImageDestinationFinalize(dest)
    return out as Data
}

/// A folder of its own for one test, gone when the test is.
private final class Folder {
    let url: URL
    init() {
        url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("gelscribe-tests-" + UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }
    deinit { try? FileManager.default.removeItem(at: url) }
    func path(_ name: String) -> String { url.appendingPathComponent(name).path }
}

/// A saved project with lanes set, and `gels - 1` more gels stacked under it.
@discardableResult
private func makeProject(in folder: Folder, name: String = "gel", gels: Int = 1, edit: (inout GelPackage) -> Void = { _ in }) throws -> URL {
    var pkg = try GelPackage.create(imageData: gelPNG(), imageName: "\(name).png")
    GelOps.setDividers(&pkg.project, xs: [95, 165, 235, 305, 375, 445, 515], imageWidth: 620, imageHeight: 300)
    if gels > 1 {
        for k in 2...gels { try pkg.addStrip(imageData: gelPNG(seed: k, bandRows: [70, 120, 170]), imageName: "\(name)-\(k).png") }
    }
    edit(&pkg)
    let url = folder.url.appendingPathComponent("\(name).gelscribe")
    try pkg.write(to: url)
    return url
}

private struct Client {
    let server: MCPServer
    init(_ host: ProjectHost = FileProjectHost()) {
        server = MCPServer(name: "t", version: "1", tools: GelTools.make(host: host))
    }

    struct Reply {
        var isError: Bool
        var text: String
        var json: JSONValue?
    }

    func raw(_ data: Data) async -> JSONValue? {
        guard let reply = await server.handle(data) else { return nil }
        return try? JSONDecoder().decode(JSONValue.self, from: reply)
    }

    func tool(_ name: String, _ args: JSONValue) async -> Reply {
        let message: JSONValue = ["jsonrpc": "2.0", "id": 1, "method": "tools/call", "params": ["name": .string(name), "arguments": args]]
        guard let reply = await raw(try! JSONEncoder().encode(message)), let result = reply["result"] else {
            return Reply(isError: true, text: "no result", json: nil)
        }
        let text = result["content"]?[0]?["text"]?.stringValue ?? ""
        return Reply(isError: result["isError"]?.boolValue ?? true, text: text, json: result["structuredContent"])
    }
}

private func projectJSON(_ url: URL) throws -> Data { try Data(contentsOf: url.appendingPathComponent("project.json")) }
private func readProject(_ url: URL) throws -> GelProject { try GelPackage.read(from: url).project }

@Suite struct ToolNumbers {
    @Test func numbersAreCheckedBeforeTheyReachTheProject() async throws {
        let f = Folder(), url = try makeProject(in: f), c = Client()
        let p = JSONValue.string(url.path)
        let before = try projectJSON(url)
        let bad: [(String, JSONValue)] = [
            ("suggest_lanes", ["project": p, "count": -1]),
            ("suggest_lanes", ["project": p, "count": 1]),
            ("suggest_lanes", ["project": p, "count": 5000]),
            ("suggest_lanes", ["project": p, "count": 2.5]),
            ("suggest_lanes", ["project": p, "count": "8"]),
            ("set_lane_dividers", ["project": p, "x": [1e308, 1.5e308]]),
            ("set_lane_dividers", ["project": p, "x": [10, 99999]]),
            ("set_lane_dividers", ["project": p, "x": [-5, 100]]),
            ("set_lane_dividers", ["project": p, "x": [10, "20"]]),
            ("set_lane_dividers", ["project": p, "x": .array((0..<5000).map { .number(Double($0 % 600)) })]),
            ("set_ladder", ["project": p, "bands": [["y": 60, "size": 1e19]]]),
            ("set_ladder", ["project": p, "bands": [["y": 60, "size": -5]]]),
            ("set_ladder", ["project": p, "bands": [["y": 60, "size": 0]]]),
            ("set_ladder", ["project": p, "bands": [["y": 60, "size": "50"]]]),
            ("set_ladder", ["project": p, "bands": [["y": 1e300]], "snap": false]),
            ("set_ladder", ["project": p, "bands": [["y": 60]], "lane": 99]),
            ("set_ladder", ["project": p, "bands": [["y": 60, "ignore": "yes"]]]),
            ("set_ladder", ["project": p, "bands": .array((0..<1001).map { _ in ["y": 60] })]),
            ("add_band_name", ["project": p, "text": "X", "y": 1e300, "snap": false]),
            ("add_band_name", ["project": p, "text": "X", "y": 1e19]),
            ("add_band_name", ["project": p, "text": "X", "y": 100, "y2": 1e19]),
            ("add_band_name", ["project": p, "text": "X", "y": 100, "lane": 0]),
            ("add_band_name", ["project": p, "text": "X", "y": 100, "marker": "star"]),
            ("set_crop", ["project": p, "x0": 1e300, "y0": 0, "x1": 100, "y1": 100]),
            ("set_style", ["project": p, "size": 1e300]),
            ("set_style", ["project": p, "gel_width_in": "wide"]),
            ("set_style", ["project": p, "font": ""]),
            ("set_row_name", ["project": p, "row": -1, "name": "x"]),
            ("set_title", ["project": p, "title": .string(String(repeating: "x", count: 5000))]),
            ("render_preview", ["project": p, "width": 0.5]),
            ("find_ladder_bands", ["project": p, "lane": 1e19]),
            ("measure_lane", ["project": p, "lane": -3]),
        ]
        for (name, args) in bad {
            let r = await c.tool(name, args)
            #expect(r.isError, "\(name) \(args.jsonString())")
        }
        #expect(try projectJSON(url) == before, "a refused call changes nothing")
        let ok = await c.tool("get_project", ["project": p])
        #expect(!ok.isError)
    }

    @Test func validNumbersStillWork() async throws {
        let f = Folder(), url = try makeProject(in: f), c = Client()
        let p = JSONValue.string(url.path)
        let lanes = await c.tool("suggest_lanes", ["project": p, "count": 8])
        #expect(!lanes.isError)
        let nulls = await c.tool("suggest_lanes", ["project": p, "count": .null])   // null is the same as leaving it out
        #expect(!nulls.isError)
        let ladder = await c.tool("set_ladder", ["project": p, "preset": "thermo-pageruler-plus", "snap": false,
                                                 "bands": [["y": 60], ["y": 110, "size": .null], ["y": 160, "ignore": true]]])
        #expect(!ladder.isError, "\(ladder.text)")
        let name = await c.tool("add_band_name", ["project": p, "text": "RPS6", "y": 110])
        #expect(!name.isError, "\(name.text)")
        #expect(name.json?["names"]?[0]?["text"]?.stringValue == "RPS6")
    }

    @Test func ticksAndNamesStayInsideTheRowsTheFigureShows() async throws {
        let f = Folder(), url = try makeProject(in: f) { $0.project.crop = PixelRect(x0: 20, y0: 50, x1: 600, y1: 200) }
        let c = Client()
        let p = JSONValue.string(url.path)
        let ladder = await c.tool("set_ladder", ["project": p, "snap": false, "bands": [["y": 10], ["y": 100], ["y": 290]]])
        #expect(!ladder.isError, "\(ladder.text)")
        #expect(ladder.json?["warnings"]?.arrayValue?.count == 2, "the two moved ticks are said")
        let name = await c.tool("add_band_name", ["project": p, "text": "far", "y": 280, "snap": false])
        #expect(name.json?["warnings"]?.arrayValue?.count == 1)
        let saved = try readProject(url)
        #expect(saved.ladder?.bands.map(\.y) == [50, 100, 200])
        #expect(saved.annotations.map(\.y) == [200])
    }

    @Test func snappingNeverCarriesATickOutOfTheCrop() async throws {
        // a band just outside the crop (y 110 is a band row), a click inside it: the tick may not snap across the edge
        let f = Folder(), url = try makeProject(in: f) { $0.project.crop = PixelRect(x0: 20, y0: 50, x1: 600, y1: 130) }
        let c = Client()
        let r = await c.tool("set_ladder", ["project": .string(url.path), "bands": [["y": 112]]])
        #expect(!r.isError)
        let y = try readProject(url).ladder?.bands.first?.y ?? -1
        #expect(y >= 50 && y <= 130)
    }

    @Test func labelsNestedTooDeepAreRefused() async throws {
        let f = Folder(), url = try makeProject(in: f), c = Client()
        let p = JSONValue.string(url.path)
        let before = try projectJSON(url)
        let deep = await c.tool("set_lane_labels", ["project": p, "labels": .string(String(repeating: "{", count: 100_000))])
        #expect(deep.isError && deep.text.contains("nest"), "\(deep.text)")
        let tooLong = await c.tool("set_lane_labels", ["project": p, "labels": .string(String(repeating: "a|", count: 150_000))])
        #expect(tooLong.isError)
        #expect(try projectJSON(url) == before)
        let fine = await c.tool("set_lane_labels", ["project": p, "labels": "µM: ladder|0{L|P}|50{L|P}|200{}"])
        #expect(!fine.isError, "\(fine.text)")
    }

    @Test func aJSONValueTooDeepIsAParseErrorNotACrash() async {
        let c = Client()
        let deep = Data(String(repeating: "[", count: 200_000).utf8)
        #expect(await c.raw(deep)?["error"]?["code"]?.intValue == -32700)
        // inside a tool call, under Foundation's own limit of 512 levels but deeper than a 512 KB stack holds when it's the
        // decoder recursing (that crashed the server, with a valid token, before the limit)
        let nested = String(repeating: "[", count: 480) + String(repeating: "]", count: 480)
        let call = #"{"jsonrpc":"2.0","id":7,"method":"tools/call","params":{"name":"get_project","arguments":{"project":"x","deep":\#(nested)}}}"#
        #expect(await c.raw(Data(call.utf8))?["error"]?["code"]?.intValue == -32700)
        // a reasonable depth is fine
        let ok = String(repeating: "[", count: 20) + String(repeating: "]", count: 20)
        let fine = #"{"jsonrpc":"2.0","id":8,"method":"tools/call","params":{"name":"get_project","arguments":{"project":"x","deep":\#(ok)}}}"#
        let reply = await c.raw(Data(fine.utf8))
        #expect(reply?["error"] == nil && reply?["id"]?.intValue == 8)
    }
}

@Suite struct ToolProtections {
    /// The bytes of every file in a folder, by relative path: to see that a call left a package alone.
    private func snapshot(_ url: URL) -> [String: Data] {
        var out: [String: Data] = [:]
        let fm = FileManager.default
        for name in fm.subpaths(atPath: url.path) ?? [] {
            let u = url.appendingPathComponent(name)
            if !GelPackage.isFolder(u) { out[name] = try? Data(contentsOf: u) }
        }
        return out
    }

    @Test func exportsNeverGoInsideAPackageInAnyLetterCase() async throws {
        let f = Folder(), url = try makeProject(in: f, name: "a", gels: 2), c = Client()
        let before = snapshot(url)
        try FileManager.default.createSymbolicLink(atPath: f.path("link"), withDestinationPath: url.path)
        let shout = f.url.appendingPathComponent("A.GELSCRIBE")   // the same folder on a disk that ignores case
        for target in [url.appendingPathComponent("x.png").path, shout.appendingPathComponent("a-2.png").path,
                       shout.appendingPathComponent("sub/deeper/x.pdf").path, f.path("link/y.png"),
                       url.path + "/../a.gelscribe/z.png"] {
            for overwrite in [false, true] {
                let r = await c.tool("export_figure", ["project": .string(url.path), "format": .string((target as NSString).pathExtension.isEmpty ? "png" : (target as NSString).pathExtension),
                                                       "path": .string(target), "overwrite": .bool(overwrite)])
                #expect(r.isError && r.text.contains("inside a project"), "\(target): \(r.text)")
            }
        }
        #expect(snapshot(url) == before, "nothing was written into the package")
    }

    @Test func exportsNeverOverwriteAnOriginalImage() async throws {
        // the originals sit outside the project: the user's own files, copied into the package when the gels were added
        let f = Folder(), c = Client()
        let one = gelPNG(seed: 1), two = gelPNG(seed: 2, bandRows: [70, 120])
        let originals = f.url.appendingPathComponent("originals")
        try FileManager.default.createDirectory(at: originals, withIntermediateDirectories: true)
        try one.write(to: originals.appendingPathComponent("gel1.png"))
        try two.write(to: originals.appendingPathComponent("gel2.png"))
        var pkg = try GelPackage.create(imageData: one, imageName: "gel1.png")
        try pkg.addStrip(imageData: two, imageName: "gel2.png")
        let url = f.url.appendingPathComponent("p.gelscribe")
        try pkg.write(to: url)
        for name in ["gel1.png", "gel2.png"] {   // the first gel's, and a stacked gel's
            let r = await c.tool("export_figure", ["project": .string(url.path), "format": "png", "path": .string(originals.appendingPathComponent(name).path), "overwrite": true])
            #expect(r.isError && r.text.contains("original"), "\(name): \(r.text)")
        }
        #expect(try Data(contentsOf: originals.appendingPathComponent("gel1.png")) == one)
        #expect(try Data(contentsOf: originals.appendingPathComponent("gel2.png")) == two)
        // anything else may be replaced, once overwrite says so
        let out = f.path("out/fig.png")
        let first = await c.tool("export_figure", ["project": .string(url.path), "format": "png", "path": .string(out)])
        #expect(!first.isError, "\(first.text)")
        let again = await c.tool("export_figure", ["project": .string(url.path), "format": "png", "path": .string(out)])
        #expect(again.isError && again.text.contains("overwrite=true"))
        let replaced = await c.tool("export_figure", ["project": .string(url.path), "format": "png", "path": .string(out), "overwrite": true])
        #expect(!replaced.isError, "\(replaced.text)")
    }

    @Test func aBareConfigsImagesAreProtectedToo() async throws {
        // a label_gel.py style config records no hash, and its images are the originals themselves
        let f = Folder(), c = Client()
        let dir = f.url.appendingPathComponent("cfg")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let one = gelPNG(seed: 3), two = gelPNG(seed: 4)
        try one.write(to: dir.appendingPathComponent("gel.png"))
        try two.write(to: dir.appendingPathComponent("gel2.png"))
        var project = GelProject(image: "gel.png")
        project.strips = [GelStrip(image: "gel2.png")]
        let config = dir.appendingPathComponent("project.json")
        try GelProject.encoder().encode(project).write(to: config)
        let opened = await c.tool("open_project", ["path": .string(config.path)])
        #expect(!opened.isError, "\(opened.text)")
        for name in ["gel.png", "gel2.png"] {
            let r = await c.tool("export_figure", ["project": .string(config.path), "format": "png", "path": .string(dir.appendingPathComponent(name).path), "overwrite": true])
            #expect(r.isError && r.text.contains("original"), "\(name): \(r.text)")
        }
        #expect(try Data(contentsOf: dir.appendingPathComponent("gel.png")) == one)
        #expect(try Data(contentsOf: dir.appendingPathComponent("gel2.png")) == two)
    }

    @Test func copyingLabelsNeverCopiesTheExportResolutionOrOtherGelsMarks() async throws {
        let f = Folder(), c = Client()
        let from = try makeProject(in: f, name: "from", gels: 2) { pkg in
            pkg.project.style.exportDPI = 300
            pkg.project.annotations = [BandAnnotation(y: 100, text: "main"), BandAnnotation(y: 90, text: "other gel", strip: 1)]
            pkg.project.title = "Scheme"
        }
        let to = try makeProject(in: f, name: "to")
        let own = try makeProject(in: f, name: "own") { $0.project.style.exportDPI = 150 }
        for (target, want) in [(to, nil), (own, 150)] as [(URL, Double?)] {
            for positions in [false, true] {
                let r = await c.tool("copy_labels", ["from": .string(from.path), "to": .string(target.path), "with_positions": .bool(positions)])
                #expect(!r.isError, "\(r.text)")
                let p = try readProject(target)
                #expect(p.style.exportDPI == want, "the resolution stays the target's own")
                #expect(p.strict && p.title == "Scheme")
                #expect(p.annotations.map(\.text) == ["main"] && p.annotations.allSatisfy { $0.strip == nil }, "only the gel with the lanes' names go")
            }
        }
    }

    @Test func editsMadeOutsideAreNeverWrittenOver() async throws {
        let f = Folder(), url = try makeProject(in: f), c = Client()
        let p = JSONValue.string(url.path)
        let a = await c.tool("set_title", ["project": p, "title": "mine"])
        #expect(!a.isError)
        // the user changes the project elsewhere (the app, a text editor)
        var pkg = try GelPackage.read(from: url)
        pkg.project.title = "theirs"
        pkg.project.rows = [LabelRow(type: .lanes, labels: ["1", "2", "3"])]
        try pkg.write(to: url)
        let edited = try projectJSON(url)
        let refused = await c.tool("set_title", ["project": p, "title": "mine again"])
        #expect(refused.isError && refused.text.contains("changed outside"), "\(refused.text)")
        #expect(try projectJSON(url) == edited, "their edit is still there")
        // reading shows the file as it is now, and then the edit can be made again
        let look = await c.tool("get_project", ["project": p])
        #expect(look.json?["title"]?.stringValue == "theirs")
        let again = await c.tool("set_title", ["project": p, "title": "mine again"])
        #expect(!again.isError, "\(again.text)")
        let now = try readProject(url)
        #expect(now.title == "mine again" && now.rows.first?.labels == ["1", "2", "3"])
        // a project that was deleted is never written back
        try FileManager.default.removeItem(at: url)
        let gone = await c.tool("set_title", ["project": p, "title": "x"])
        #expect(gone.isError && !FileManager.default.fileExists(atPath: url.path))
    }

    @Test func aNewProjectNeverGoesInsideAnotherProject() async throws {
        let f = Folder(), c = Client()
        let host = try makeProject(in: f, name: "host")
        let inside = host.appendingPathComponent("host.png").path   // the image inside a package: the default place is next to it
        let r1 = await c.tool("create_project", ["image_path": .string(inside)])
        #expect(r1.isError && r1.text.contains("inside another project"), "\(r1.text)")
        let outside = f.path("scan.png")
        try gelPNG().write(to: URL(fileURLWithPath: outside))
        for save in [host.appendingPathComponent("new.gelscribe").path, f.path("HOST.GELSCRIBE/new.gelscribe"), host.path + "/x/y/z.gelscribe"] {
            let r = await c.tool("create_project", ["image_path": .string(outside), "save_to": .string(save)])
            #expect(r.isError && r.text.contains("inside another project"), "\(save): \(r.text)")
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: host.path).sorted() == ["host.png", "project.json"])
        let wrong = await c.tool("create_project", ["image_path": .string(outside), "save_to": .string(f.path("nope.png"))])
        #expect(wrong.isError)
        // outside any project, in any letter case, it works
        let fine = await c.tool("create_project", ["image_path": .string(outside), "save_to": .string(f.path("Scan.GelScribe"))])
        #expect(!fine.isError, "\(fine.text)")
        let twice = await c.tool("create_project", ["image_path": .string(outside), "save_to": .string(f.path("Scan.GelScribe"))])
        #expect(twice.isError && twice.text.contains("already exists"))
    }

    @Test func aGelWhoseImageCantBeReadIsNamedByItsPlace() async throws {
        let f = Folder(), c = Client()
        let url = try makeProject(in: f, gels: 2) { $0.stripImages["gel-2.png"] = Data("not an image".utf8) }
        let r = await c.tool("open_project", ["path": .string(url.path)])
        #expect(r.isError && r.text == "Gel 2's image (gel-2.png) can't be read.", "\(r.text)")
    }
}

@Suite struct ToolLadders {
    private let sizes = [250.0, 130, 100, 70, 55, 35, 25, 15, 10]   // PageRuler Plus, the first gel system

    private func stacked(_ f: Folder, edit: @escaping (inout GelPackage) -> Void = { _ in }) throws -> URL {
        try makeProject(in: f, gels: 2) { pkg in
            GelOps.addTick(&pkg.project, y: 90, size: 40, lane: 1, gelCenterX: 310, strip: 1)
            GelOps.addTick(&pkg.project, y: 140, size: 15, lane: 1, gelCenterX: 310, strip: 1)
            edit(&pkg)
        }
    }

    private func setLadder(_ c: Client, _ url: URL) async -> Client.Reply {
        await c.tool("set_ladder", ["project": .string(url.path), "preset": "thermo-pageruler-plus", "snap": false,
                                    "bands": [["y": 60], ["y": 110], ["y": 160]]])
    }

    @Test func aPresetGivesGuessesToTheGelWithTheLanesOnly() async throws {
        let f = Folder(), url = try stacked(f), c = Client()
        let r = await setLadder(c, url)
        #expect(!r.isError, "\(r.text)")
        let bands = try readProject(url).ladder?.bands ?? []
        let mine = bands.filter { $0.strip == nil }, other = bands.filter { $0.strip == 1 }
        #expect(mine.map(\.size) == [250, 130, 100] && mine.allSatisfy(\.auto))
        #expect(other.map(\.size) == [40, 15] && other.allSatisfy { !$0.auto }, "the other gel keeps what it had")
    }

    @Test func aGelWithItsOwnLadderIsLeftAlone() async throws {
        let f = Folder(), url = try stacked(f) { $0.project.strips[0].ownLadder = true }, c = Client()
        _ = await setLadder(c, url)
        let bands = try readProject(url).ladder?.bands ?? []
        #expect(bands.filter { $0.strip == nil }.map(\.size) == [250, 130, 100])
        #expect(bands.filter { $0.strip == 1 }.map(\.size) == [40, 15], "its sizes are its own")
        #expect(try readProject(url).strips[0].ownLadder)
    }

    @Test func theLadderRunsOnFromTheGelAbove() async throws {
        // the gel with the lanes is under the other gel, which carries the same ladder: its ticks come first
        let f = Folder(), url = try stacked(f) { $0.project.mainPosition = 1 }, c = Client()
        _ = await setLadder(c, url)
        let bands = try readProject(url).ladder?.bands ?? []
        #expect(bands.filter { $0.strip == nil }.map(\.size) == [100, 70, 55])
        #expect(bands.filter { $0.strip == 1 }.map(\.size) == [40, 15])
        // with its own ladder it starts again from the top
        var pkg = try GelPackage.read(from: url)
        pkg.project.ownLadder = true
        try pkg.write(to: url)
        _ = await c.tool("open_project", ["path": .string(url.path)])   // changed outside: take it as it is now
        let r = await setLadder(c, url)
        #expect(!r.isError, "\(r.text)")
        #expect(try readProject(url).ladder?.bands.filter { $0.strip == nil }.map(\.size) == [250, 130, 100])
    }

    @Test func getProjectSaysWhichGelsHaveTheirOwnLadder() async throws {
        let f = Folder(), url = try stacked(f) { $0.project.strips[0].ownLadder = true }, c = Client()
        let r = await c.tool("get_project", ["project": .string(url.path)])
        let gels = r.json?["gels"]?.arrayValue ?? []
        #expect(gels.count == 2)
        #expect(gels[0]["own_ladder"] == nil && gels[0]["lanes"]?.boolValue == true)
        #expect(gels[1]["own_ladder"]?.boolValue == true && gels[1]["lanes"]?.boolValue == false)
    }

    @Test func getProjectSaysEachGelsKeepOriginalPixelsAndTheLineBetweenGels() async throws {
        let f = Folder(), c = Client()
        // a gel added to a project starts with Keep original pixels off; the lanes gel keeps the project's setting
        let url = try stacked(f) { $0.project.separatorWhite = true }
        let r = await c.tool("get_project", ["project": .string(url.path)])
        let gels = r.json?["gels"]?.arrayValue ?? []
        #expect(r.json?["strict"]?.boolValue == true && r.json?["separator"]?.stringValue == "white")
        #expect(gels[0]["strict"]?.boolValue == true && gels[1]["strict"]?.boolValue == false)
        // a gel with no setting of its own follows the lanes gel
        let old = try stacked(f) { $0.project.strips[0].strict = nil; $0.project.strict = false }
        let o = await c.tool("get_project", ["project": .string(old.path)])
        #expect(o.json?["separator"]?.stringValue == "black" && o.json?["gels"]?.arrayValue?.map { $0["strict"]?.boolValue } == [false, false])
    }
}

@Suite struct Settling {
    @Test func whatAToolDidIsMadeSaneBeforeAHostKeepsIt() throws {
        // the last line of defense: numbers a tool let through (it shouldn't) never reach a document or a saved file
        let pkg = try GelPackage.create(imageData: gelPNG(), imageName: "g.png")
        let w = WorkingImage(source: try SourceImage(data: pkg.imageData), project: pkg.project)
        var p = pkg.project
        p.lanes.centers = [.infinity, 50]
        p.lanes.dividers = [LaneDivider(x: 1e300, dotY: 5), LaneDivider(x: 100, dotY: 5)]
        p.ladder = Ladder(bands: [LadderBand(y: 1e300, size: 50), LadderBand(y: 100, size: 1e19), LadderBand(y: 5000)])
        p.annotations = [BandAnnotation(y: .nan, text: "x"), BandAnnotation(y: 100, y2: 1e300, text: "y")]
        p.style.size = .infinity
        p.crop = PixelRect(x0: 0, y0: 0, x1: .infinity, y1: 100)
        p.settle(with: w)
        #expect(p.lanes.centers.isEmpty && p.lanes.dividers.count == 1)
        #expect(p.ladder?.bands.map(\.y) == [100, 300], "the tick that isn't a position is dropped, one past the image comes back to its edge")
        #expect(p.ladder?.bands.first?.size == nil, "a size that isn't one is dropped")
        #expect(p.annotations.map(\.text) == ["y"] && p.annotations[0].y2 == nil)
        #expect(p.style.size.isFinite && p.crop == nil)
        _ = try GelProject.encoder().encode(p)   // and it can be saved
    }
}

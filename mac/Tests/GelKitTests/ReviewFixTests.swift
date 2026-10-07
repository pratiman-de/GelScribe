import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import GelKit

// Tests for the 2026-10-06 review fixes (the numbers are the review's findings).

/// A little-endian TIFF of 32-bit unsigned integers (ImageIO reads it as 32 bits per component, not floating point).
private func tiff32(width: Int = 8, height: Int = 6) -> Data {
    let pixels = Data((0..<width * height).flatMap { i in withUnsafeBytes(of: UInt32(i) &* 70_000_000) { Array($0) } })
    let tags: [(UInt16, UInt16, UInt32)] = [(256, 3, UInt32(width)), (257, 3, UInt32(height)), (258, 3, 32), (259, 3, 1), (262, 3, 1),
                                            (273, 4, 8), (277, 3, 1), (278, 3, UInt32(height)), (279, 4, UInt32(pixels.count)), (339, 3, 1)]
    var out = Data("II*\0".utf8)
    func put<T: FixedWidthInteger>(_ v: T) { withUnsafeBytes(of: v.littleEndian) { out.append(contentsOf: $0) } }
    put(UInt32(8 + pixels.count)); out.append(pixels); put(UInt16(tags.count))
    for (tag, type, value) in tags {
        put(tag); put(type); put(UInt32(1))
        if type == 3 { put(UInt16(value)); put(UInt16(0)) } else { put(value) }   // a short fills the first half of the value field
    }
    put(UInt32(0))
    return out
}

/// 8 x 6 palette PNGs, pixel (x, y) using palette entry y * 8 + x: a gray palette (entry i is gray 5i mod 256) and a colored one
/// (entry i is (5i mod 256, 255 - 5i mod 256, 7i mod 256)).
private let grayPalettePNG = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAgAAAAGCAMAAADJ2y/JAAAAkFBMVEUAAAAFBQUKCgoPDw8UFBQZGRkeHh4jIyMoKCgtLS0yMjI3Nzc8PDxBQUFGRkZLS0tQUFBVVVVaWlpfX19kZGRpaWlubm5zc3N4eHh9fX2CgoKHh4eMjIyRkZGWlpabm5ugoKClpaWqqqqvr6+0tLS5ubm+vr7Dw8PIyMjNzc3S0tLX19fc3Nzh4eHm5ubr6+vQHTbwAAAAPklEQVR42mNgYGRiZmFlY2fg4OTi5uHl42cQEBQSFhEVE2eQkJSSlpGVk2dQUFRSVlFVU2fQ0NTS1tHV0wcATtIEaR2lTpQAAAAASUVORK5CYII=")!
private let colorPalettePNG = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAgAAAAGCAMAAADJ2y/JAAAAkFBMVEUA/wAF+gcK9Q4P8BUU6xwZ5iMe4Soj3DEo1zgt0j8yzUY3yE08w1RBvltGuWJLtGlQr3BVqndapX5foIVkm4xplpNukZpzjKF4h6h9gq+CfbaHeL2Mc8SRbsuWadKbZNmgX+ClWueqVe6vUPW0S/y5RgO+QQrDPBHINxjNMh/SLSbXKC3cIzThHjvmGULrFEkJ9n/GAAAAPklEQVR42mNgYGRiZmFlY2fg4OTi5uHl42cQEBQSFhEVE2eQkJSSlpGVk2dQUFRSVlFVU2fQ0NTS1tHV0wcATtIEaR2lTpQAAAAASUVORK5CYII=")!

/// A project of two gels: the lanes gel (a.png) keeps its original pixels, gel 2 (b.png) doesn't (a new gel starts that way).
private func twoGelPackage() throws -> GelPackage {
    var pkg = try GelPackage.create(imageData: gelPNG(width: 620, height: 160, lanes: [100, 200], bandRows: [60]), imageName: "a.png")
    try pkg.addStrip(imageData: gelPNG(width: 700, height: 220, lanes: [130, 230], bandRows: [90]), imageName: "b.png")
    return pkg
}

private func reload(_ p: GelProject, _ changes: [String: Any]) throws -> GelProject {
    var d = try #require(JSONSerialization.jsonObject(with: GelProject.encoder().encode(p)) as? [String: Any])
    for (k, v) in changes { d[k] = v }
    return try GelProject.decoder().decode(GelProject.self, from: JSONSerialization.data(withJSONObject: d))
}

@Suite struct ReviewFixes {
    // 1: only a .gelscribe package ever loses an image copy
    @Test func onlyAPackageLosesAnImageCopy() throws {
        let dir = tempFolder("plain")
        defer { try? FileManager.default.removeItem(at: dir) }
        let fm = FileManager.default
        let plain = dir.appendingPathComponent("folder"), package = dir.appendingPathComponent("P.GelScribe"), link = dir.appendingPathComponent("L.gelscribe")
        for u in [plain, package] {
            try fm.createDirectory(at: u, withIntermediateDirectories: true)
            for n in ["x.png", "project.json"] { try Data("img".utf8).write(to: u.appendingPathComponent(n)) }
        }
        try fm.createSymbolicLink(at: link, withDestinationURL: plain)   // named like a package, but leads to a plain folder
        for refused in [plain, link] { #expect(!GelPackage.deleteRemovedCopy(named: "x.png", in: refused)) }
        #expect(fm.fileExists(atPath: plain.appendingPathComponent("x.png").path))
        for odd in ["project.json", "..", "a/b", ""] { #expect(!GelPackage.deleteRemovedCopy(named: odd, in: package)) }
        #expect(GelPackage.deleteRemovedCopy(named: "x.png", in: package))
        #expect(!fm.fileExists(atPath: package.appendingPathComponent("x.png").path) && fm.fileExists(atPath: package.appendingPathComponent("project.json").path))
    }

    // 2: the headline when only some gels keep their original pixels
    @Test func mixedGelsGetTheMixedHeadline() throws {
        var pkg = try twoGelPackage()
        let mixed = "Gel pixels: mixed. Some gels keep their original values and some were changed; see each gel below."
        func note(_ dpi: Double? = nil) -> String {
            ExportInfo.for(pkg.project, sourceSHA256: "aaa", resampledDPI: dpi, nativeDPI: dpi == nil ? nil : 300, strips: [(sha256: "bbb", scale: nil)]).description
        }
        #expect(note().contains(mixed) && !note().contains("original values, bit depth"))
        #expect(note(600).contains(mixed + " Resampled to 600 dpi from 300 dpi; full frame.") && !note(600).contains("otherwise unadjusted"))
        pkg.project.strict = false   // the other way round (the lanes gel adjusted, gel 2 original): mixed too, with the lanes gel's own settings in its entry
        pkg.project.strips[0].strict = true
        #expect(note().contains(mixed) && !note().contains("Gel pixels: adjusted") && note().contains("1. a.png, as above (its lanes are the figure's), rotation 0.0°"))
        pkg.project.strict = true   // every gel keeps its pixels, or none does: the headline stays as it was
        #expect(note().contains("Gel pixels: original values, bit depth and color space, not resampled (strict)") && !note().contains("mixed"))
        pkg.project.strict = false
        pkg.project.strips[0].strict = false
        #expect(note().contains("Gel pixels: adjusted (") && !note().contains("mixed"))
    }

    // 3: a changed image is warned about in the note (the CLI and the app say it too: see the other tests)
    @Test func aChangedImageStartsTheNoteWithAWarning() throws {
        var pkg = try twoGelPackage()
        let sha = try #require(pkg.project.strips[0].imageSHA256)
        func note(main: String? = pkg.project.imageSHA256, strip: String = sha) -> String {
            ExportInfo.for(pkg.project, sourceSHA256: main, strips: [(sha256: strip, scale: nil)]).description
        }
        #expect(note().hasPrefix("GelScribe figure."))   // nothing changed: no warning
        #expect(note(strip: "ccc").hasPrefix("Warning: Gel 2's image (b.png) has changed since it was added; its SHA-256 no longer matches.\nGelScribe figure."))
        pkg.project.mainPosition = 1   // the lanes gel below gel 2: numbered from the top
        let both = note(main: "bbb", strip: "ccc").split(separator: "\n").map(String.init)
        #expect(both[0] == "Warning: Gel 1's image (b.png) has changed since it was added; its SHA-256 no longer matches.")
        #expect(both[1] == "Warning: Gel 2's image (a.png) has changed since it was added; its SHA-256 no longer matches." && both[2].hasPrefix("GelScribe figure."))
    }

    // 4: malformed text size keys are dropped on load
    @Test func malformedTextSizeKeysAreDroppedOnLoad() throws {
        var p = GelProject(image: "a.png")
        p.style.textSizes = ["lane.0.2": 14, "group.1.0": 11, "rowname.2": 12, "name.1": 9, "": 5, ".": 6, "lane.x.1": 7, "group.1": 8,
                             "lane.0.": 3, "lane.1.2.3": 4, "rowname.-1": 9, "name": 2, "title": 10]
        let back = try reload(p, [:])
        #expect(Set(back.style.textSizes.keys) == ["lane.0.2", "group.1.0", "rowname.2", "name.1"])
    }

    // 6: a bad separator or separator width loads as black / the Lines width, without an error
    @Test func badSeparatorSettingsLoadAsTheDefaults() throws {
        let base = GelProject(image: "a.png")
        for bad: Any in ["#GGG", "blue", 5, true, [1], ["a": 1]] { #expect(try reload(base, ["separator": bad]).separatorColor == .black, "\(bad)") }
        for bad: Any in ["wide", true, [2], "3", ["a": 1]] { #expect(try reload(base, ["separator_width": bad]).separatorWidth == nil, "\(bad)") }
        let good = try reload(base, ["separator": "#ff3300", "separator_width": 2])
        #expect(good.separatorColor == SeparatorColor(parsing: "#ff3300") && good.separatorWidth == 2)
        #expect(try reload(base, ["separator_width": 50]).separatorWidth == 10)   // a number out of range is held to the range
    }

    // 7: 32-bit integer images are refused like floating-point ones
    @Test func thirtyTwoBitIntegerImagesAreRefused() throws {
        let message = "This image has 32-bit integer values, which GelScribe doesn't support. Export it from your scanner's software as a 16-bit TIFF and open that."
        func failure(_ body: () throws -> Void) -> String? { do { try body(); return nil } catch { return error.localizedDescription } }
        let data = tiff32()
        var pkg = try twoGelPackage()
        #expect(failure { _ = try SourceImage(data: data) } == message)
        #expect(failure { _ = try GelPackage.create(imageData: data, imageName: "i.tif") } == message)
        #expect(failure { _ = try pkg.addStrip(imageData: data, imageName: "i.tif") } == message)
        pkg.stripImages["b.png"] = data   // a copy that was swapped for one: this refusal, not "can't be read"
        #expect(failure { _ = try pkg.decodeStrip(1) } == message)
    }

    // 8: no gel keeps its pixels: 8-bit gray, or 8-bit RGB when the line between gels isn't a gray
    @Test func aStackWhereNoGelKeepsItsPixelsIsGrayOrRGBBySeparator() throws {
        var pkg = try twoGelPackage()
        pkg.project.strict = false
        func made(_ separator: String) throws -> (image: CGImage, note: String) {
            pkg.project.separatorColor = try #require(SeparatorColor(parsing: separator))
            let fig = StackedFigure(project: pkg.project, main: WorkingImage(source: try pkg.decodeMain(), project: pkg.project),
                                    strips: try StackedFigure.stripImages(pkg))
            return (try #require(fig.gel), fig.info().description)
        }
        for gray in ["black", "white", "#808080"] {
            let (image, note) = try made(gray)
            #expect(image.colorSpace?.model == .monochrome && image.bitsPerComponent == 8 && image.bitsPerPixel == 8, "\(gray)")
            #expect(note.contains("converted to 8-bit gray") && !note.contains("8-bit RGB"), "\(gray)")
        }
        let (rgb, note) = try made("#ff3300")
        #expect(rgb.colorSpace?.model == .rgb && rgb.bitsPerComponent == 8)
        #expect(note.contains("converted to 8-bit RGB") && !note.contains("8-bit gray"))
    }

    // 9: a figure whose gel can't be made isn't exported as blank space
    @Test func aFigureWhoseGelCantBeComposedIsNotExported() throws {
        var pkg = try twoGelPackage()
        func figure() throws -> StackedFigure {
            StackedFigure(project: pkg.project, main: WorkingImage(source: try pkg.decodeMain(), project: pkg.project), strips: try StackedFigure.stripImages(pkg))
        }
        #expect(try figure().export(.pdf) != nil)
        pkg.project.strips[0].left = 0   // a gel with columns of its own, shifted far sideways: the figure grows past the largest picture
        pkg.project.strips[0].right = 700
        pkg.project.strips[0].shift = 200_000
        let fig = try figure()
        #expect(fig.gel == nil)
        for type in [UTType.pdf, .png, .tiff, .svg] { #expect(fig.export(type) == nil, "\(type)") }
        #expect(StackedFigure.tooLargeMessage == "The figure is too large to make. Crop the gels or lower the export resolution.")
    }

    // 10: file names can be left out of the note and the metadata; the fingerprints stay
    @Test func fileNamesCanBeLeftOutOfTheNote() throws {
        var pkg = try twoGelPackage()
        let main = try #require(pkg.project.imageSHA256), strip = try #require(pkg.project.strips[0].imageSHA256)
        func note(_ now: String? = nil) -> ExportInfo { ExportInfo.for(pkg.project, sourceSHA256: main, strips: [(sha256: now ?? strip, scale: nil)]) }
        #expect(note().description.contains("a.png") && note().description.contains("b.png"))
        #expect(!String(decoding: try GelProject.encoder().encode(pkg.project), as: UTF8.self).contains("export_file_names"))   // omitted: true
        pkg.project.exportFileNames = false
        let n = note("ccc")   // a changed image still warns, without its name
        #expect(!n.description.contains(".png") && !n.title.contains(".png"), "\(n.description)")
        #expect(n.description.contains("Source sha256 \(main).") && n.description.contains("2. sha256 ccc, "))
        #expect(n.description.hasPrefix("Warning: Gel 2's image has changed since it was added; its SHA-256 no longer matches.\n"))
        let json = try GelProject.encoder().encode(pkg.project)
        #expect(String(decoding: json, as: UTF8.self).contains("\"export_file_names\" : false"))
        #expect(try GelProject.decoder().decode(GelProject.self, from: json).exportFileNames == false)
        #expect(throws: (any Error).self) { try reload(pkg.project, ["export_file_names": "no"]) }   // not a yes or no: refused, like any switch
    }

    // 11: a second tick on the same row is the one that was just added
    @Test func aSecondTickOnTheSameRowHasItsOwnID() {
        var p = GelProject(image: "a.png")
        let first = GelOps.addTick(&p, y: 50, size: 40, lane: 1, gelCenterX: 310)
        let second = GelOps.addTick(&p, y: 50, size: 40, lane: 1, gelCenterX: 310)
        #expect(first != nil && second != nil && first != second && p.ladder?.bands.count == 2)
        #expect(p.ladder?.bands.contains { $0.id == second } == true)
        #expect(GelOps.addTick(&p, y: .nan, size: nil, lane: 1, gelCenterX: 310) == nil)   // nothing added, no id
    }

    // 15: a palette image is read as the colors it shows: 8-bit gray when they are all gray, else 8-bit RGB
    @Test func paletteImagesAreReadAsTheColorsTheyShow() throws {
        let gray = try SourceImage(data: grayPalettePNG).cgImage
        #expect(gray.colorSpace?.model == .monochrome && gray.bitsPerComponent == 8 && gray.bitsPerPixel == 8)
        let grays: [UInt16] = (0..<48).map { UInt16($0 * 5 % 256) }
        #expect(RawPixels(gray).region(x: 0, y: 0, w: 8, h: 6, channels: 1) == grays)
        let color = try SourceImage(data: colorPalettePNG).cgImage
        #expect(color.colorSpace?.model == .rgb && color.bitsPerComponent == 8)
        var wanted: [UInt16] = []
        for i in 0..<48 { wanted += [UInt16(i * 5 % 256), UInt16(255 - i * 5 % 256), UInt16(7 * i % 256)] }
        #expect(RawPixels(color).region(x: 0, y: 0, w: 8, h: 6, channels: 3) == wanted)
        // so a gray palette gel stacks untouched with an ordinary gray one
        let plain = try SourceImage(data: gelPNG(width: 8, height: 6)).cgImage
        #expect(StripStack.strictMismatch(main: gray, strip: plain) == nil)
    }
}

// MARK: the command-line tool

@Suite(.enabled(if: hasCLI, "needs the built gelscribe")) struct ReviewFixesCommandLine {
    private func exists(_ b: Bench, _ path: String) -> Bool { FileManager.default.fileExists(atPath: b.file(path).path) }

    // 1: removing a gel deletes its copy from a package, never a file from a plain folder
    @Test func removingAGelNeverDeletesAFileFromAPlainFolder() throws {
        let b = try Bench()
        try b.twoGels()
        try FileManager.default.copyItem(at: b.file("P.gelscribe"), to: b.file("plain"))   // the same files in a plain folder
        #expect(try b.run("edit", "plain", "--remove-gel", "2").status == 0)
        #expect(exists(b, "plain/other.png") && exists(b, "plain/gel.png"))   // the project no longer lists other.png; the file stays
        #expect((try b.json("plain")["strips"] as? [Any])?.isEmpty ?? true)
        #expect(try b.run("edit", "P.gelscribe", "--remove-gel", "2").status == 0)
        #expect(!exists(b, "P.gelscribe/other.png") && exists(b, "P.gelscribe/gel.png"))   // a package's own copy goes
    }

    // 3: a changed image still renders (exit 0), with the warning on stderr and at the top of the note
    @Test func renderWarnsAboutAChangedImageAndStillExportsIt() throws {
        let b = try Bench()
        try b.twoGels()
        try gelPNG(width: 300, height: 100).write(to: b.file("P.gelscribe/other.png"))   // gel 2's copy swapped for another picture
        let r = try b.run("render", "P.gelscribe", "--formats", "svg")
        #expect(r.status == 0, "\(r.err)")
        let line = "Warning: Gel 2's image (other.png) has changed since it was added; its SHA-256 no longer matches."
        #expect(r.err.contains(line + "\n"))
        #expect(try String(contentsOf: b.file("P.figure.svg"), encoding: .utf8).contains("<desc>" + line + "\nGelScribe figure."))
    }

    // 9: too large to make: it fails with the message, and writes nothing
    @Test func renderRefusesAFigureThatIsTooLarge() throws {
        let b = try Bench()
        try b.twoGels()
        #expect(try b.run("edit", "P.gelscribe", "--gel", "2", "--crop", "0,0,700,220", "--shift", "200000").status == 0)
        let r = try b.run("render", "P.gelscribe", "--formats", "pdf,svg")
        #expect(r.status == 1 && r.err.contains("The figure is too large to make. Crop the gels or lower the export resolution."), "\(r.err)")
        #expect(!exists(b, "P.figure.pdf") && !exists(b, "P.figure.svg"))
    }

    // 10: --file-names off keeps the file names out of the files
    @Test func fileNamesOffKeepsThemOutOfExportedFiles() throws {
        let b = try Bench()
        try b.twoGels()
        #expect(try b.run("edit", "P.gelscribe", "--file-names", "maybe").status != 0)
        #expect(try b.run("edit", "P.gelscribe", "--file-names", "off").status == 0)
        #expect(try b.json("P.gelscribe")["export_file_names"] as? Bool == false)
        let r = try b.run("render", "P.gelscribe", "--formats", "png,svg")
        #expect(r.status == 0, "\(r.err)")
        let svg = try String(contentsOf: b.file("P.figure.svg"), encoding: .utf8)
        #expect(!svg.contains("gel.png") && !svg.contains("other.png") && svg.contains("sha256"))
        let source = try #require(CGImageSourceCreateWithURL(b.file("P.figure.png") as CFURL, nil))
        let props = try #require(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
        let png = try #require(props[kCGImagePropertyPNGDictionary] as? [CFString: Any])
        let description = try #require(png[kCGImagePropertyPNGDescription] as? String)
        #expect(!description.contains(".png") && description.contains("sha256"))
        #expect(try b.run("edit", "P.gelscribe", "--file-names", "on").status == 0 && b.json("P.gelscribe")["export_file_names"] == nil)
    }

    // 12: one gel that can't be read stops only the options that need it
    @Test func editsThatDontNeedAGelsPixelsWorkWhenItCantBeRead() throws {
        let b = try Bench()
        try b.twoGels()
        try Data("not an image".utf8).write(to: b.file("P.gelscribe/other.png"))   // gel 2 damaged
        for args in [["--title", "kept"], ["--labels", "ladder|WT{L|P}"], ["--separator", "white"], ["--file-names", "off"]] {
            let r = try b.run(["edit", "P.gelscribe"] + args)
            #expect(r.status == 0, "\(args): \(r.err)")
        }
        #expect(try b.json("P.gelscribe")["title"] as? String == "kept")
        let needs = try b.run("edit", "P.gelscribe", "--gel", "2", "--crop", "0,0,50,50")
        #expect(needs.status == 1 && needs.err.contains("Gel 2's image (other.png) can't be read."), "\(needs.err)")
        #expect(try b.run("edit", "P.gelscribe", "--order", "2,1").status == 0)   // gel 2 is the one that can't be read: it moves, untouched
        try Data("not an image".utf8).write(to: b.file("P.gelscribe/gel.png"))   // the gel with the lanes too
        #expect(try b.run("edit", "P.gelscribe", "--title", "again").status == 0)
        #expect(try b.run("edit", "P.gelscribe", "--auto-lanes", "3").status == 1)
    }

    // 21: counts are pluralized in the summary
    @Test func theSummaryPluralizesItsCounts() throws {
        let b = try Bench()
        try b.run("new", "gel.png", "-o", "P.gelscribe")
        #expect(try b.run("edit", "P.gelscribe", "--dividers", "310", "--ticks", "60", "--name", "X@60").out == "2 lanes, 1 tick, 1 name\n")
        try b.run("edit", "P.gelscribe", "--add-gel", "other.png")
        #expect(try b.run("edit", "P.gelscribe", "--name", "Y@80").out == "2 lanes, 1 tick, 2 names, 2 gels\n")
    }

    // 7: refused when a project is made from it
    @Test func theToolRefusesA32BitIntegerImage() throws {
        let b = try Bench()
        try tiff32().write(to: b.file("i.tif"))
        let r = try b.run("new", "i.tif", "-o", "I.gelscribe")
        #expect(r.status == 1 && r.err.contains("This image has 32-bit integer values, which GelScribe doesn't support."))
        #expect(!exists(b, "I.gelscribe"))
    }
}

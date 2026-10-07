import CryptoKit
import Foundation
import ImageIO

/// A `.gelscribe` document: a folder holding `project.json` and a byte-for-byte copy of the original image (and of
/// each stacked gel's image). Images are written once, when added, and never rewritten.
public struct GelPackage: Sendable {
    public static let projectFileName = "project.json"
    public static let fileExtension = "gelscribe"
    public static var projectExtensions: [String] { [fileExtension] }

    /// Whether `ext` is the project extension, in any letter case (a Mac or Windows disk doesn't tell `X.GelScribe` from
    /// `X.gelscribe`).
    public static func isProjectExtension(_ ext: String) -> Bool { ext.lowercased() == fileExtension }
    /// Whether `url` names a project by its extension, in any letter case.
    public static func isProjectPath(_ url: URL) -> Bool { isProjectExtension(url.pathExtension) }

    /// What two image file names are compared by: capitals and the way an accent is typed don't matter, because the disk
    /// doesn't tell them apart, so two images in one project can't differ only in that.
    public static func nameKey(_ name: String) -> String { name.precomposedStringWithCanonicalMapping.lowercased() }
    public static func sameName(_ a: String, _ b: String) -> Bool { nameKey(a) == nameKey(b) }

    public var project: GelProject
    public var imageData: Data
    /// The strips' images by file name (`GelStrip.image`), byte-for-byte.
    public var stripImages: [String: Data]

    public init(project: GelProject, imageData: Data, stripImages: [String: Data] = [:]) {
        self.project = project
        self.imageData = imageData
        self.stripImages = stripImages
    }

    /// Strip `k`'s image bytes (1-based).
    public func stripData(_ k: Int) -> Data? {
        k >= 1 && k <= project.strips.count ? stripImages[project.strips[k - 1].image] : nil
    }

    /// Adds another gel at the bottom of the stack: its image copied in byte-for-byte under a name of its own, lined
    /// up at first with no shift. Returns its number in `strips`.
    @discardableResult
    public mutating func addStrip(imageData data: Data, imageName: String) throws -> Int {
        let source = try SourceImage(data: data)   // refuses non-images up front
        var name = (imageName as NSString).lastPathComponent
        if name.isEmpty || name == "." || name == ".." || Self.sameName(name, Self.projectFileName) { name = "gel.png" }
        // names are compared without regard to capitals: the disk can't hold two that differ only in them
        let taken = Set(([project.image, Self.projectFileName] + project.strips.map(\.image)).map(Self.nameKey))
        if taken.contains(Self.nameKey(name)) {
            let stem = (name as NSString).deletingPathExtension, ext = (name as NSString).pathExtension
            func numbered(_ n: Int) -> String { "\(stem)_\(n)" + (ext.isEmpty ? "" : ".\(ext)") }
            var n = 1
            while taken.contains(Self.nameKey(numbered(n))) { n += 1 }
            name = numbered(n)
        }
        let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        // a new gel starts with Keep original pixels off, so Auto-align can stretch it into line with nothing to set; the
        // lanes gel's setting stays as it is
        var strip = GelStrip(image: name, imageSHA256: hash, strict: false)
        strip.display.bandsDark = project.display.bandsDark   // the same kind of scan: bands the same way round
        project.strips.append(strip)
        let k = project.strips.count
        strip.display = .initial(for: WorkingImage(source: source, project: project.stripProject(k)))
        strip.display.bandsDark = project.display.bandsDark
        project.strips[k - 1] = strip
        stripImages[name] = data
        return k
    }

    /// Whether some gel of the project (the main image or a stacked one) is stored under this file name, compared the
    /// way the disk does (capitals don't count).
    public func usesImage(named name: String) -> Bool {
        Self.sameName(name, project.image) || project.strips.contains { Self.sameName($0.image, name) }
    }

    /// Takes gel `k` (its number in `strips`) out with its ticks and names. Its image copy goes too, unless another gel
    /// still uses that file name (capitals don't count). Returns the file name to delete from a project folder on disk,
    /// or nil when there's nothing to delete. The original file elsewhere is never touched.
    @discardableResult
    public mutating func removeStrip(_ k: Int) -> String? {
        guard k >= 1, k <= project.strips.count else { return nil }
        let image = project.strips[k - 1].image
        GelOps.removeStrip(&project, k)
        guard !usesImage(named: image) else { return nil }
        stripImages[image] = nil
        return image
    }

    /// Whether `url` is a `.gelscribe` package by name, the only folder in which GelScribe ever deletes a file (the copies it made
    /// itself). A plain folder that holds a `project.json` is the user's own: whatever was taken out of the project, every file in
    /// it stays. The name that counts is where the path really leads (`.` and links followed), so a link named `.gelscribe` that
    /// leads to a plain folder doesn't count.
    public static func ownsImageCopies(in url: URL) -> Bool {
        isProjectPath(url.standardizedFileURL.resolvingSymlinksInPath()) && isFolder(url)
    }

    /// Deletes the image copy of a gel that was taken out (`removeStrip` says its name) from the package at `url`: never anywhere
    /// else (see `ownsImageCopies`), and never anything but a plain file name directly inside the package. True if it was deleted.
    @discardableResult
    public static func deleteRemovedCopy(named name: String, in url: URL) -> Bool {
        guard ownsImageCopies(in: url), !name.isEmpty, name != ".", name != "..", !name.contains("/"), !sameName(name, projectFileName)
        else { return false }
        return (try? FileManager.default.removeItem(at: url.appendingPathComponent(name))) != nil
    }

    /// A new, empty project around an image. Nothing is detected: the user places lanes and bands.
    public static func create(imageData: Data, imageName: String) throws -> GelPackage {
        let source = try SourceImage(data: imageData)   // refuses non-images up front
        var name = (imageName as NSString).lastPathComponent
        if name.isEmpty || name == "." || name == ".." || sameName(name, projectFileName) {
            name = "image" + ((imageName as NSString).pathExtension.isEmpty ? ".png" : "." + (imageName as NSString).pathExtension)
        }
        let hash = SHA256.hash(data: imageData).map { String(format: "%02x", $0) }.joined()
        let title = ((name as NSString).deletingPathExtension)
        var project = GelProject(image: name, imageSHA256: hash, title: title)
        // like ImageJ, open 16-bit scans with a usable contrast (screen only while Strict is on)
        project.display = .initial(for: WorkingImage(source: source, project: project))
        return GelPackage(project: project, imageData: imageData)
    }

    public static func create(imageURL: URL) throws -> GelPackage {
        try create(imageData: Data(contentsOf: imageURL), imageName: imageURL.lastPathComponent)
    }

    public init(fileWrapper: FileWrapper) throws {
        guard fileWrapper.isDirectory, let files = fileWrapper.fileWrappers,
              let pj = files[Self.projectFileName]?.regularFileContents else { throw GelKitError.badProject("no project.json") }
        let project = try Self.decodeProject(pj)
        guard let img = files[project.image]?.regularFileContents else {
            throw GelKitError.badProject("the image \(project.image) is missing from the package")
        }
        var strips: [String: Data] = [:]
        for s in project.strips {
            guard let d = files[s.image]?.regularFileContents else {
                throw GelKitError.badProject("the gel image \(s.image) is missing from the package")
            }
            strips[s.image] = d
        }
        self.init(project: project, imageData: img, stripImages: strips)
        normalize()
    }

    private static func decodeProject(_ data: Data) throws -> GelProject {
        do { return try GelProject.decoder().decode(GelProject.self, from: data) } catch {
            throw GelKitError.badProject("project.json can't be read")
        }
    }

    /// A file's size in pixels, read from its header without decoding the picture.
    public static func pixelSize(of data: Data) -> (width: Int, height: Int)? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
              let w = (props[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
              let h = (props[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue, w > 0, h > 0 else { return nil }
        return (w, h)
    }

    /// Once the images are at hand, puts a loaded project in order: every gel's rows valid, and marks inside their gel's
    /// image (see `GelProject.normalize`). Done by every way of reading a project.
    public mutating func normalize() {
        let main = Self.pixelSize(of: imageData).map { project.workingSize(width: $0.width, height: $0.height) }
        let sizes: [(width: Int, height: Int)?] = project.strips.indices.map { i in
            guard let d = stripData(i + 1), let s = Self.pixelSize(of: d) else { return nil }
            return project.stripProject(i + 1).workingSize(width: s.width, height: s.height)
        }
        project.normalize(mainSize: main, stripSizes: sizes)
    }

    /// The main image, decoded. Fails with "Gel N's image (file) can't be read." (N counted from the top of the figure).
    public func decodeMain() throws -> SourceImage {
        do { return try SourceImage(data: imageData) } catch let e as GelKitError {
            if case .floatImage = e { throw e }
            if case .cmykImage = e { throw e }
            if case .integerImage = e { throw e }
            throw GelKitError.unreadableGel(number: project.position(of: nil) + 1, file: project.image)
        }
    }

    /// Strip `k`'s image, decoded. Fails like `decodeMain`, with that gel's number and file.
    public func decodeStrip(_ k: Int) throws -> SourceImage {
        guard k >= 1, k <= project.strips.count else { throw GelKitError.unreadableImage }
        let unreadable = GelKitError.unreadableGel(number: project.position(of: k) + 1, file: project.strips[k - 1].image)
        guard let d = stripData(k) else { throw unreadable }
        do { return try SourceImage(data: d) } catch let e as GelKitError {
            if case .floatImage = e { throw e }
            if case .cmykImage = e { throw e }
            if case .integerImage = e { throw e }
            throw unreadable
        }
    }

    public func fileWrapper() throws -> FileWrapper {
        let pj = FileWrapper(regularFileWithContents: try GelProject.encoder().encode(project))
        var files = [Self.projectFileName: pj, project.image: FileWrapper(regularFileWithContents: imageData)]
        for s in project.strips { if let d = stripImages[s.image] { files[s.image] = FileWrapper(regularFileWithContents: d) } }
        // two names that differ only in capitals would land on one file (or get a made-up name) on the disk
        guard Set(files.keys.map(Self.nameKey)).count == files.count else {
            throw GelKitError.badProject("two of the gel images have names that differ only in capital letters; rename one")
        }
        return FileWrapper(directoryWithFileWrappers: files)
    }

    /// Reads a `.gelscribe` package, or a bare JSON config (label_gel.py style) whose `image` path is relative to it.
    public static func read(from url: URL) throws -> GelPackage {
        var isDir: ObjCBool = false
        FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
        if isDir.boolValue {
            return try GelPackage(fileWrapper: FileWrapper(url: url, options: .immediate))
        }
        let project = try decodeProject(Data(contentsOf: url))
        let dir = url.deletingLastPathComponent()
        let imgURL = URL(fileURLWithPath: project.image, relativeTo: dir)
        var strips: [String: Data] = [:]
        for s in project.strips { strips[s.image] = try Data(contentsOf: URL(fileURLWithPath: s.image, relativeTo: dir)) }
        var pkg = GelPackage(project: project, imageData: try Data(contentsOf: imgURL), stripImages: strips)
        pkg.normalize()
        return pkg
    }

    /// Whether `url` is a project folder (as opposed to a bare JSON config next to its image).
    public static func isFolder(_ url: URL) -> Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) && isDir.boolValue
    }

    /// Writes `project.json` atomically. Each image is copied in only if the package doesn't have it yet; one that's
    /// there already must be this project's own, never another file under the same name (names are compared without
    /// regard to capitals, as the disk does). Everything is checked before anything is written, and what was written
    /// is taken back if a write fails, so a refused project leaves no stray image behind.
    public func write(to url: URL) throws {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        if fm.fileExists(atPath: url.path, isDirectory: &isDir), !isDir.boolValue {
            // a bare JSON config (label_gel.py style) next to its image: only the config is rewritten, and only if
            // it is one, so no other file can be replaced by a project
            guard let old = try? Data(contentsOf: url), (try? Self.decodeProject(old)) != nil else {
                throw GelKitError.badProject("\(url.lastPathComponent) is a file, not a project folder")
            }
            try GelProject.encoder().encode(project).write(to: url, options: .atomic)
            return
        }
        var present: [String: String] = [:]   // name key → the name the folder has it under
        for name in (try? fm.contentsOfDirectory(atPath: url.path)) ?? [] { present[Self.nameKey(name)] = name }
        var missing: [(name: String, data: Data)] = []
        func check(_ name: String, _ data: Data, differs: String) throws {
            if let there = present[Self.nameKey(name)] {
                guard there == name else {
                    throw GelKitError.badProject("\(name) would replace \(there) in the package, which differs only in capital letters; add the gel under another name")
                }
                if (try? Data(contentsOf: url.appendingPathComponent(name), options: .mappedIfSafe)) != data { throw GelKitError.badProject(differs) }
            } else {
                missing.append((name, data))
                present[Self.nameKey(name)] = name
            }
        }
        try check(project.image, imageData, differs: "\(project.image) in the package is a different image from this project's")
        for s in project.strips {
            guard let d = stripImages[s.image] else { continue }
            try check(s.image, d, differs: "\(s.image) in the package is a different image; add the gel under another name")
        }
        let json = try GelProject.encoder().encode(project)
        let madeFolder = !fm.fileExists(atPath: url.path)
        try fm.createDirectory(at: url, withIntermediateDirectories: true)
        var written: [URL] = []
        do {
            for (name, data) in missing {
                let u = url.appendingPathComponent(name)
                try data.write(to: u, options: .atomic)
                written.append(u)
            }
            try json.write(to: url.appendingPathComponent(Self.projectFileName), options: .atomic)
        } catch {
            for u in written { try? fm.removeItem(at: u) }
            if madeFolder { try? fm.removeItem(at: url) }
            throw error
        }
    }

    /// True when the image bytes still hash to what was recorded on import (nil if nothing was recorded).
    public var imageIntact: Bool? {
        guard let want = project.imageSHA256 else { return nil }
        return SHA256.hash(data: imageData).map { String(format: "%02x", $0) }.joined() == want
    }

    /// Like `imageIntact`, for strip `k` (1-based).
    public func stripIntact(_ k: Int) -> Bool? {
        guard k >= 1, k <= project.strips.count, let want = project.strips[k - 1].imageSHA256 else { return nil }
        guard let d = stripData(k) else { return false }
        return SHA256.hash(data: d).map { String(format: "%02x", $0) }.joined() == want
    }
}

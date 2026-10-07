import Foundation
import GelKit

public struct ProjectInfo: Codable, Sendable {
    public var id: String
    public var path: String?
    public var image: String
    public var title: String?
    public var lanes: Int
    public var strict: Bool
    public init(id: String, path: String?, image: String, title: String?, lanes: Int, strict: Bool) {
        self.id = id; self.path = path; self.image = image; self.title = title; self.lanes = lanes; self.strict = strict
    }
}

/// Where projects live: `.gelscribe` files on disk (CLI) or the documents open in the app.
public protocol ProjectHost: Sendable {
    func list() async -> [ProjectInfo]
    func open(path: String) async throws -> ProjectInfo
    func create(imagePath: String, savePath: String?) async throws -> ProjectInfo
    /// Runs `body` on a copy of the project with its working image. With a non-nil `action` the edited copy is kept:
    /// saved to `project.json` (files) or applied as one undoable step named `action` (app).
    func access<T: Sendable>(_ id: String, action: String?,
                             _ body: @Sendable (inout GelProject, WorkingImage) throws -> T) async throws -> T
}

extension GelProject {
    func info(id: String, path: String?) -> ProjectInfo {
        ProjectInfo(id: id, path: path, image: image, title: title, lanes: laneCount, strict: strict)
    }

    /// What an edit made through the tools must pass before a host keeps it: every number sane (as when a project is
    /// loaded) and every mark inside its gel's image. The tools check what they're given; this is the last line, so
    /// nothing a tool does can leave a project that crashes a render, or can't be saved, or can't be opened again.
    public mutating func settle(with w: WorkingImage) {
        sanitize()
        normalize(mainSize: (width: w.width, height: w.height), stripSizes: w.strips.map { (width: $0.width, height: $0.height) })
    }
}

/// Projects as `.gelscribe` packages on disk. Only `project.json` is ever rewritten; the image is write-once.
///
/// A project is read once and kept. If its file is changed by someone else after that (the user edited it in the app, or
/// another program did), the next call sees the new file, and an edit is refused instead of writing over it.
public actor FileProjectHost: ProjectHost {
    private struct Entry {
        var url: URL
        var pkg: GelPackage
        var source: SourceImage
        var work: WorkingImage
        /// The project file as it was when read here or last written here; a different file now was changed elsewhere.
        var onDisk: Data?
    }
    private var entries: [String: Entry] = [:]
    private var order: [String] = []

    public init() {}

    public func list() -> [ProjectInfo] {
        order.compactMap { id in entries[id].map { $0.pkg.project.info(id: id, path: $0.url.path) } }
    }

    /// project.json inside a package, or the config itself for a bare JSON project.
    private static func fileContents(_ url: URL) -> Data? {
        try? Data(contentsOf: GelPackage.isFolder(url) ? url.appendingPathComponent(GelPackage.projectFileName) : url)
    }

    private static func load(_ url: URL) throws -> Entry {
        let pkg = try GelPackage.read(from: url)
        let src = try pkg.decodeMain()
        var work = WorkingImage(source: src, project: pkg.project)
        work.strips = try StackedFigure.stripImages(pkg)   // a cut membrane's other pieces, for exports and previews
        return Entry(url: url, pkg: pkg, source: src, work: work, onDisk: fileContents(url))
    }

    public func open(path: String) throws -> ProjectInfo {
        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath).standardizedFileURL
        let id = url.path
        if let e = entries[id] {
            if Self.fileContents(e.url) != e.onDisk { entries[id] = try Self.load(e.url) }   // changed elsewhere: take it as it is now
            return entries[id]!.pkg.project.info(id: id, path: id)
        }
        let e = try Self.load(url)
        entries[id] = e
        order.append(id)
        return e.pkg.project.info(id: id, path: id)
    }

    public func create(imagePath: String, savePath: String?) throws -> ProjectInfo {
        let (img, dest) = try PathRules.newProject(imagePath: imagePath, savePath: savePath)
        try GelPackage.create(imageURL: img).write(to: dest)
        return try open(path: dest.path)
    }

    public func access<T: Sendable>(_ id: String, action: String?,
                                    _ body: @Sendable (inout GelProject, WorkingImage) throws -> T) throws -> T {
        let key = try resolve(id)
        guard var e = entries[key] else { throw GelServiceError("unknown project \(id)") }
        if Self.fileContents(e.url) != e.onDisk {
            // Changed outside these tools since it was read. Reading shows the file as it is now; an edit never writes over it.
            e = try Self.load(e.url)
            entries[key] = e
            if action != nil {
                throw GelServiceError("\(e.url.lastPathComponent) was changed outside these tools after it was opened, so this edit was not made. It has been reloaded as it is now: check it with get_project, then repeat the edit if it's still wanted.")
            }
        }
        var p = e.pkg.project
        let result = try body(&p, e.work)
        if action != nil {
            p.settle(with: e.work)
            if p != e.pkg.project {
                let old = e.pkg.project
                let pixelsChanged = p.strict != old.strict || p.rotateDeg != old.rotateDeg || p.fillPadding != old.fillPadding || p.turn != old.turn
                let stripsChanged = pixelsChanged || p.strips.map { [$0.image, "\($0.turn)", "\($0.rotateDeg)", "\(String(describing: $0.strict))"] }
                    != old.strips.map { [$0.image, "\($0.turn)", "\($0.rotateDeg)", "\(String(describing: $0.strict))"] }
                e.pkg.project = p
                if pixelsChanged {
                    let strips = e.work.strips
                    e.work = WorkingImage(source: e.source, project: p)
                    e.work.strips = strips
                }
                if stripsChanged { e.work.strips = try StackedFigure.stripImages(e.pkg) }
                try e.pkg.write(to: e.url)
                e.onDisk = Self.fileContents(e.url)
                entries[key] = e
            }
        }
        return result
    }

    /// Accepts an id from list/open/create, or a path to a project not opened yet.
    private func resolve(_ id: String) throws -> String {
        if entries[id] != nil { return id }
        let std = URL(fileURLWithPath: (id as NSString).expandingTildeInPath).standardizedFileURL.path
        if entries[std] != nil { return std }
        return try open(path: id).id
    }
}

public struct GelServiceError: Error, LocalizedError, Sendable {
    public let message: String
    public init(_ m: String) { message = m }
    public var errorDescription: String? { message }
}

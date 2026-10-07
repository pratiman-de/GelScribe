import Foundation
import GelKit

/// Where the tools may put files. A project is a folder named `.gelscribe`; the disk doesn't tell `X.GelScribe` from
/// `X.gelscribe`, so every check here ignores letter case, and looks at where symlinks lead as well as at the path as
/// written.
public enum PathRules {
    /// Whether `url` is inside a project (some folder above it is one), or with `orSelf` is one itself.
    public static func isInsideProject(_ url: URL, orSelf: Bool = false) -> Bool {
        func check(_ u: URL) -> Bool {
            var u = orSelf ? u : u.deletingLastPathComponent()
            while u.pathComponents.count > 1 {
                if GelPackage.isProjectPath(u) { return true }
                u.deleteLastPathComponent()
            }
            return false
        }
        let std = url.standardizedFileURL
        return check(std) || check(resolved(std))
    }

    /// `url` with the symlinks of its existing part followed (the rest may not exist yet).
    static func resolved(_ url: URL) -> URL {
        let fm = FileManager.default
        var existing = url
        var rest: [String] = []
        while existing.pathComponents.count > 1, !fm.fileExists(atPath: existing.path) {
            rest.insert(existing.lastPathComponent, at: 0)
            existing.deleteLastPathComponent()
        }
        var out = existing.resolvingSymlinksInPath()
        for name in rest { out.appendPathComponent(name) }
        return out
    }

    /// The image to start from and where the new project goes (next to the image unless `savePath` says otherwise), or a
    /// message saying why not: the name must end in .gelscribe, nothing may be there already, and it can't go inside
    /// another project (an image inside a project would otherwise put its new project in that one).
    public static func newProject(imagePath: String, savePath: String?) throws -> (image: URL, project: URL) {
        let image = URL(fileURLWithPath: (imagePath as NSString).expandingTildeInPath).standardizedFileURL
        let dest = savePath.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath).standardizedFileURL }
            ?? image.deletingPathExtension().appendingPathExtension(GelPackage.fileExtension)
        guard GelPackage.isProjectPath(dest) else { throw GelServiceError("save_to must end in .gelscribe") }
        guard !isInsideProject(dest) else {
            throw GelServiceError("\(dest.path) would be inside another project. Give save_to a folder outside any .gelscribe project.")
        }
        guard !FileManager.default.fileExists(atPath: dest.path) else {
            throw GelServiceError("\(dest.path) already exists; open it with open_project instead")
        }
        return (image, dest)
    }
}

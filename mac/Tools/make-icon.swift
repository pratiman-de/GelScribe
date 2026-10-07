// Builds the app icon from square artwork on Apple's macOS icon grid: an 824 px tile with continuous corners on a
// 1024 canvas, with a soft drop shadow in the margin. The artwork itself is only cropped and scaled.
//
//   swift Tools/make-icon.swift ARTWORK [--crop X,Y,SIZE] [--preview OUT.png]
//
// --crop is a square in artwork pixels from the top-left (default: the largest centered square).
// --preview writes only the 1024 icon to OUT.png, for trying candidates.
// Otherwise it writes Resources/AppIcon.icns, Resources/Logo/GelScribe-icon-1024.png and
// Resources/Logo/GelScribe-logo-trimmed.png (the cropped artwork with the icon's corners, no shadow).

import AppKit
import SwiftUI
import UniformTypeIdentifiers

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("make-icon: \(message)\n".utf8))
    exit(1)
}

func option(_ name: String) -> String? {
    let args = CommandLine.arguments
    guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
    return args[i + 1]
}

let args = CommandLine.arguments
guard args.count >= 2, !args[1].hasPrefix("--") else {
    fail("usage: swift Tools/make-icon.swift ARTWORK [--crop X,Y,SIZE] [--preview OUT.png]")
}
let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()

guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: args[1]) as CFURL, nil),
      let artwork = CGImageSourceCreateImageAtIndex(source, 0, nil) else { fail("cannot read \(args[1])") }

let crop: CGRect
if let spec = option("--crop") {
    let v = spec.split(separator: ",").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
    guard v.count == 3, v[2] > 0 else { fail("--crop wants X,Y,SIZE") }
    crop = CGRect(x: v[0], y: v[1], width: v[2], height: v[2])
} else {
    let side = Double(min(artwork.width, artwork.height))
    crop = CGRect(x: ((Double(artwork.width) - side) / 2).rounded(.down),
                  y: ((Double(artwork.height) - side) / 2).rounded(.down), width: side, height: side)
}
guard crop.minX >= 0, crop.minY >= 0, crop.maxX <= Double(artwork.width), crop.maxY <= Double(artwork.height),
      let art = artwork.cropping(to: crop) else {
    fail("crop \(crop) is outside the \(artwork.width)×\(artwork.height) artwork")
}

/// Apple's icon tile shape: continuous ("squircle") corners, radius 185.4 on an 824 tile.
func tile(_ rect: CGRect) -> CGPath {
    RoundedRectangle(cornerRadius: rect.width * 185.4 / 824, style: .continuous).path(in: rect).cgPath
}

let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!

func canvas(_ side: Int) -> CGContext {
    guard let ctx = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0, space: sRGB,
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { fail("no bitmap context") }
    ctx.interpolationQuality = .high
    return ctx
}

/// The icon at `side` pixels. The shadow comes from the clipped artwork itself (a transparency layer), so the tile
/// edge has no dark fringe.
func icon(_ side: Int) -> CGImage {
    let ctx = canvas(side)
    let s = CGFloat(side) / 1024
    let rect = CGRect(x: 100 * s, y: 100 * s, width: 824 * s, height: 824 * s)
    ctx.setShadow(offset: CGSize(width: 0, height: -12 * s), blur: 24 * s, color: CGColor(gray: 0, alpha: 0.3))
    ctx.beginTransparencyLayer(auxiliaryInfo: nil)
    ctx.addPath(tile(rect))
    ctx.clip()
    ctx.draw(art, in: rect)
    ctx.endTransparencyLayer()
    return ctx.makeImage()!
}

func trimmed() -> CGImage {
    let ctx = canvas(art.width)
    let rect = CGRect(x: 0, y: 0, width: art.width, height: art.height)
    ctx.addPath(tile(rect))
    ctx.clip()
    ctx.draw(art, in: rect)
    return ctx.makeImage()!
}

func writePNG(_ image: CGImage, to url: URL) {
    guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
        fail("cannot write \(url.path)")
    }
    CGImageDestinationAddImage(dest, image, nil)
    guard CGImageDestinationFinalize(dest) else { fail("cannot write \(url.path)") }
}

if let preview = option("--preview") {
    writePNG(icon(1024), to: URL(fileURLWithPath: preview))
    exit(0)
}

let logo = root.appending(path: "Resources/Logo")
writePNG(icon(1024), to: logo.appending(path: "GelScribe-icon-1024.png"))
writePNG(trimmed(), to: logo.appending(path: "GelScribe-logo-trimmed.png"))

// Every size is drawn from the artwork, not downsampled from the 1024 icon.
let files = FileManager.default
let iconset = files.temporaryDirectory.appending(path: "GelScribe-\(ProcessInfo.processInfo.processIdentifier).iconset")
try? files.removeItem(at: iconset)
do { try files.createDirectory(at: iconset, withIntermediateDirectories: true) } catch { fail("\(error)") }
for points in [16, 32, 128, 256, 512] {
    writePNG(icon(points), to: iconset.appending(path: "icon_\(points)x\(points).png"))
    writePNG(icon(points * 2), to: iconset.appending(path: "icon_\(points)x\(points)@2x.png"))
}
let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", root.appending(path: "Resources/AppIcon.icns").path]
do { try iconutil.run() } catch { fail("\(error)") }
iconutil.waitUntilExit()
try? files.removeItem(at: iconset)
guard iconutil.terminationStatus == 0 else { fail("iconutil failed") }
print("wrote Resources/AppIcon.icns, Resources/Logo/GelScribe-icon-1024.png, Resources/Logo/GelScribe-logo-trimmed.png")

import AppKit
import CoreGraphics
import Foundation
import Testing
import UniformTypeIdentifiers
@testable import GelKit
@testable import GelScribeApp

// The 2026-10-06 review fixes that live in the app (the numbers are the review's findings).

/// A small 8-bit gray PNG with a ramp across it.
private func smallPNG(width: Int = 120, height: Int = 60) -> Data {
    var px = [UInt8](repeating: 0, count: width * height)
    for y in 0..<height { for x in 0..<width { px[y * width + x] = UInt8(40 + 150 * x / width) } }
    let img = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: width,
                      space: CGColorSpace(name: CGColorSpace.genericGrayGamma2_2)!, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                      provider: CGDataProvider(data: Data(px) as CFData)!, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
    let out = NSMutableData()
    let dest = CGImageDestinationCreateWithData(out, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, img, nil)
    CGImageDestinationFinalize(dest)
    return out as Data
}

@MainActor private func workspace(changed: Bool = false) throws -> Workspace {
    var pkg = try GelPackage.create(imageData: smallPNG(), imageName: "top.png")
    if changed { pkg.project.imageSHA256 = String(repeating: "0", count: 64) }   // as if the copy had been swapped since it was added
    return Workspace(document: GelDocument(package: pkg))
}

@MainActor @Suite struct ReviewFixesInTheApp {
    // 3: exporting or copying asks first when a gel's image has changed
    @Test func aChangedImageIsAskedAboutBeforeTheFigureLeaves() throws {
        let ws = try workspace(changed: true)
        let line = "Warning: Gel 1's image (top.png) has changed since it was added; its SHA-256 no longer matches."
        ws.export(.pdf, suggestedName: "x.pdf")   // asks: no save panel opens
        let ask = try #require(ws.pendingChangedExport)
        #expect(ask.message == line && ask.action == .export(.pdf, "x.pdf"))
        ws.pendingChangedExport = nil   // Cancel
        ws.copyFigure()
        #expect(ws.pendingChangedExport?.action == .copy && ws.pendingChangedExport?.message == line)
        ws.pendingChangedExport = nil
        let fine = try workspace()   // nothing changed: nothing to ask
        #expect(fine.changedImageWarnings.isEmpty)
        #expect(ws.exportInfo.description.hasPrefix(line + "\nGelScribe figure."))
    }

    // 4: Delete Row used to trap on a damaged text size key
    @Test func deletingARowSurvivesDamagedTextSizeKeys() throws {
        let ws = try workspace()
        ws.document.edit("Test", undoManager: nil) {
            $0.rows = [LabelRow(type: .groups, groups: []), LabelRow(type: .groups, groups: [])]
            $0.style.textSizes = ["": 9, ".": 9, "x": 9, "rowname.1": 12, "lane.1.0": 11]
        }
        ws.deleteRow(0)
        #expect(ws.project.rows.count == 1 && ws.project.style.textSizes["rowname.0"] == 12 && ws.project.style.textSizes["lane.0.0"] == 11)
    }

    // 11: a second tick on the same row is the one that opens
    @Test func aSecondTickOnTheSameRowGetsItsOwnID() throws {
        let ws = try workspace()
        let first = ws.addTick(x: 60, y: 30), second = ws.addTick(x: 60, y: 30)
        #expect(first != second && ws.project.ladder?.bands.count == 2 && ws.project.ladder?.bands.contains { $0.id == second } == true)
    }

    // 14: an older version's token removed at launch is told once
    @Test func anOlderTokenRemovedAtLaunchLeavesAOneTimeNote() throws {
        let name = "gelscribe-test-\(UUID().uuidString)"
        let d = try #require(UserDefaults(suiteName: name))
        defer { d.removePersistentDomain(forName: name) }
        d.set("an-old-token", forKey: "mcpToken")
        LLMAccess.dropOldToken(in: d, enabled: true)   // on: it's moved to the Keychain, not dropped
        #expect(d.object(forKey: "mcpToken") != nil && !d.bool(forKey: LLMAccess.oldTokenFlag))
        LLMAccess.dropOldToken(in: d, enabled: false)
        #expect(d.object(forKey: "mcpToken") == nil && d.bool(forKey: LLMAccess.oldTokenFlag))
        d.removeObject(forKey: LLMAccess.oldTokenFlag)
        LLMAccess.dropOldToken(in: d, enabled: false)   // nothing left to drop: nothing to say
        #expect(!d.bool(forKey: LLMAccess.oldTokenFlag))
        #expect(LLMAccess.oldTokenText == "A token from an older version was removed. Turn on LLM access and copy the new command into your LLM client.")
    }
}

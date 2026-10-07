import GelKit
import SwiftUI
import Synchronization
import UniformTypeIdentifiers

extension UTType {
    nonisolated static let gelScribe = UTType(exportedAs: "local.gelscribe.project", conformingTo: .package)
}

/// A `.gelscribe` package. Images are never opened as documents — only read — so macOS can't save over an original.
/// Lives on the main actor. SwiftUI may ask for the save snapshot off the main actor, so every change also
/// refreshes a lock-protected copy that `snapshot(contentType:)` returns.
@MainActor
final class GelDocument: ReferenceFileDocument {
    typealias Snapshot = GelPackage

    nonisolated static var readableContentTypes: [UTType] { [.gelScribe] }
    nonisolated static var writableContentTypes: [UTType] { [.gelScribe] }

    // Plain Sendable storage (not @Published) so the nonisolated file-reading init can set it;
    // changes are announced by hand.
    var project: GelProject {
        willSet { objectWillChange.send() }
        didSet { publishSnapshot() }
    }
    /// Original image bytes; nil until the user picks an image for a new document.
    private(set) var imageData: Data? {
        willSet { objectWillChange.send() }
        didSet { publishSnapshot() }
    }
    /// The strips' original image bytes, by file name (a cut blot's other pieces).
    private(set) var stripImages: [String: Data] = [:] {
        willSet { objectWillChange.send() }
        didSet { publishSnapshot() }
    }

    private nonisolated let saved = Mutex<GelPackage?>(nil)

    nonisolated init() {
        project = GelProject()
        imageData = nil
    }

    /// A new, untitled document around a prepared package (used by "New Gel with These Labels").
    nonisolated init(package pkg: GelPackage) {
        project = pkg.project
        imageData = pkg.imageData
        stripImages = pkg.stripImages
        saved.withLock { $0 = pkg }
    }

    nonisolated required init(configuration: ReadConfiguration) throws {
        let pkg = try GelPackage(fileWrapper: configuration.file)
        project = pkg.project
        imageData = pkg.imageData
        stripImages = pkg.stripImages
        saved.withLock { $0 = pkg }
    }

    private func publishSnapshot() {
        guard publishHold == 0 else { return }   // inside `changeTogether`: the snapshot comes after the last part has changed
        let pkg = imageData.map { GelPackage(project: project, imageData: $0, stripImages: stripImages) }
        saved.withLock { $0 = pkg }
    }

    private var publishHold = 0

    /// Changes several parts as one: the snapshot SwiftUI may ask for at any moment is taken once they all have, never
    /// with the new images next to the old project (that would save a package that can't be opened again).
    private func changeTogether(_ changes: () -> Void) {
        publishHold += 1
        changes()
        publishHold -= 1
        publishSnapshot()
    }

    /// Strip `k`'s image bytes (1-based).
    func stripData(_ k: Int) -> Data? {
        k >= 1 && k <= project.strips.count ? stripImages[project.strips[k - 1].image] : nil
    }

    /// Adds another gel at the bottom of the stack. Undoable. Returns its number in `project.strips`.
    @discardableResult
    func addStrip(imageData data: Data, name: String, undoManager: UndoManager?) throws -> Int {
        guard let main = imageData else { throw CocoaError(.fileReadUnknown, userInfo: [NSLocalizedDescriptionKey: "Open the first gel first."]) }
        var pkg = GelPackage(project: project, imageData: main, stripImages: stripImages)
        let k = try pkg.addStrip(imageData: data, imageName: name)
        setStrips(project: pkg.project, images: pkg.stripImages, name: "Add Gel", undoManager: undoManager)
        return k
    }

    /// Takes gel `k` (its number in `project.strips`) out, with its marks. Its image copy goes too, unless another gel
    /// still uses that file name (capitals don't count: the disk can't tell them apart). Undoable.
    func removeStrip(_ k: Int, undoManager: UndoManager?) {
        guard let main = imageData, k >= 1, k <= project.strips.count else { return }
        var pkg = GelPackage(project: project, imageData: main, stripImages: stripImages)
        pkg.removeStrip(k)
        setStrips(project: pkg.project, images: pkg.stripImages, name: "Remove Gel", undoManager: undoManager)
    }

    private func setStrips(project p: GelProject, images: [String: Data], name: String, undoManager: UndoManager?) {
        let oldProject = project, oldImages = stripImages
        changeTogether { stripImages = images; project = p }
        undoManager?.registerUndo(withTarget: self) { doc in
            doc.setStrips(project: oldProject, images: oldImages, name: name, undoManager: undoManager)
        }
        undoManager?.setActionName(name)
    }

    nonisolated func snapshot(contentType: UTType) throws -> GelPackage {
        guard let pkg = saved.withLock({ $0 }) else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSLocalizedDescriptionKey: "Add an image before saving."])
        }
        return pkg
    }

    nonisolated func fileWrapper(snapshot: GelPackage, configuration: WriteConfiguration) throws -> FileWrapper {
        try snapshot.fileWrapper()
    }

    var hasImage: Bool { imageData != nil }

    /// Starts the project around an image. The bytes are kept exactly as read. Undoable, back to the empty drop zone.
    func adopt(imageData data: Data, name: String, undoManager: UndoManager?) throws {
        let pkg = try GelPackage.create(imageData: data, imageName: name)
        setImage(pkg.imageData, project: pkg.project, undoManager: undoManager)
    }

    private func setImage(_ data: Data?, project p: GelProject, undoManager: UndoManager?) {
        let oldData = imageData, oldProject = project
        changeTogether { imageData = data; project = p }
        undoManager?.registerUndo(withTarget: self) { doc in
            doc.setImage(oldData, project: oldProject, undoManager: undoManager)
        }
        undoManager?.setActionName("Choose Image")
    }

    // MARK: undoable edits

    /// One undo step. `change` edits a copy; nothing is registered if it made no difference. An edit that arrives while a
    /// drag is in progress (an LLM's, say) is a step of its own: the drag so far is closed as one step first, and what's
    /// left of the drag becomes another, so no step ever holds a mix of both.
    func edit(_ name: String, undoManager: UndoManager?, _ change: (inout GelProject) -> Void) {
        interruptGesture(undoManager: undoManager)
        var next = project
        change(&next)
        guard next != project else { return }
        replace(with: next, name: name, undoManager: undoManager)
    }

    private func replace(with next: GelProject, name: String, undoManager: UndoManager?) {
        let previous = project
        project = next
        undoManager?.registerUndo(withTarget: self) { doc in
            doc.replace(with: previous, name: name, undoManager: undoManager)
        }
        undoManager?.setActionName(name)
    }

    // Drags update live and become ONE undo step when they end.
    private var gestureStart: GelProject?
    /// What the step is called if something else interrupts the drag before it ends.
    private var gestureName: String?

    func beginGesture() { if gestureStart == nil { gestureStart = project } }

    /// Live, unrecorded update during a drag. `name` is the step's name should the drag be interrupted.
    func live(_ name: String? = nil, _ change: (inout GelProject) -> Void) {
        beginGesture()
        if gestureName == nil { gestureName = name }
        change(&project)
    }

    /// Closes a drag that is still going, as a step in an undo group of its own (the edit that interrupts it is another),
    /// so one Undo never takes back both. The groups open now are closed and as many are opened again, for the caller (or
    /// the run loop, which groups by event) to close.
    private func interruptGesture(undoManager: UndoManager?) {
        guard gestureStart != nil else { return }
        guard let um = undoManager else { endGesture(gestureName ?? "Edit", undoManager: nil); return }
        let open = um.groupingLevel
        um.beginUndoGrouping()
        endGesture(gestureName ?? "Edit", undoManager: um)
        while um.groupingLevel > 0 { um.endUndoGrouping() }
        for _ in 0..<max(open, 1) { um.beginUndoGrouping() }
    }

    func endGesture(_ name: String, undoManager: UndoManager?) {
        guard let start = gestureStart else { return }
        gestureStart = nil
        gestureName = nil
        guard start != project else { return }
        let end = project
        changeTogether {   // back to where the drag began and on to where it ended, so the undo step has its start; no snapshot in between
            project = start
            replace(with: end, name: name, undoManager: undoManager)
        }
    }
}

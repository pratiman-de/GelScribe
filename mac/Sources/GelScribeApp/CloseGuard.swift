import AppKit

/// Replaces macOS's long "Do you want to keep this new document?" sheet with a short one, only for an edited,
/// untitled document that is being closed. Saved documents, autosave and Versions are untouched: every other
/// document goes through NSDocument's own `canClose(withDelegate:…)` exactly as before.
///
/// SwiftUI's DocumentGroup owns the NSDocument class and the window delegate (and puts its own delegate back after
/// edits), so neither can be overridden. `NSDocument.canClose(withDelegate:shouldClose:contextInfo:)` is where every
/// close (the red button, ⌘W, Close All, quitting) asks the document, so that one method is exchanged for a version that
/// asks first for these documents, and otherwise calls the original.
enum CloseGuard {
    nonisolated(unsafe) private static var installed = false

    static func install() {
        guard !installed,
              let original = class_getInstanceMethod(NSDocument.self, #selector(NSDocument.canClose(withDelegate:shouldClose:contextInfo:))),
              let ours = class_getInstanceMethod(NSDocument.self, #selector(NSDocument.gs_canClose(withDelegate:shouldClose:contextInfo:)))
        else { return }
        installed = true
        method_exchangeImplementations(original, ours)
    }

    /// Whether the short sheet replaces macOS's for this document.
    static func applies(to doc: NSDocument) -> Bool {
        doc.fileURL == nil && (doc.isDocumentEdited || doc.hasUnautosavedChanges)
            && doc.windowControllers.first?.window != nil
    }

    /// Asks "Save “name”?" as a sheet on the document's window, then tells `answer` whether the document may close.
    static func ask(_ doc: NSDocument, answer: @escaping (Bool) -> Void) {
        guard let window = doc.windowControllers.first?.window else { return answer(false) }
        if window.attachedSheet != nil { return answer(false) }   // a save panel or another question is already up
        let alert = NSAlert()
        alert.icon = NSApp.applicationIconImage
        alert.messageText = "Want to save your changes to “\(doc.displayName ?? "Untitled")”?"
        alert.addButton(withTitle: "Save")           // Return
        let discard = alert.addButton(withTitle: "Don't Save")
        discard.keyEquivalent = "d"
        discard.keyEquivalentModifierMask = .command
        alert.addButton(withTitle: "Cancel").keyEquivalent = "\u{1b}"
        alert.beginSheetModal(for: window) { response in
            switch response {
            case .alertFirstButtonReturn:
                // the normal save panel; the document closes once the file is written and stays if the panel is cancelled
                let finisher = SaveFinisher(answer)
                doc.save(withDelegate: finisher, didSave: #selector(SaveFinisher.document(_:didSave:contextInfo:)), contextInfo: nil)
            case .alertSecondButtonReturn:
                answer(true)
            default:
                answer(false)
            }
        }
    }
}

/// Receives the result of the save panel. NSDocument does not retain its delegate, so it keeps itself alive until then.
private final class SaveFinisher: NSObject {
    private var me: SaveFinisher?
    private let answer: (Bool) -> Void
    init(_ answer: @escaping (Bool) -> Void) { self.answer = answer; super.init(); me = self }
    @objc func document(_ doc: NSDocument, didSave: Bool, contextInfo: UnsafeMutableRawPointer?) {
        answer(didSave)
        me = nil
    }
}

extension NSDocument {
    /// After the exchange this is what `canClose(withDelegate:…)` runs, and calling it runs the original.
    @objc func gs_canClose(withDelegate delegate: Any, shouldClose selector: Selector?, contextInfo: UnsafeMutableRawPointer?) {
        guard CloseGuard.applies(to: self), let selector else {
            gs_canClose(withDelegate: delegate, shouldClose: selector, contextInfo: contextInfo)   // the original
            return
        }
        CloseGuard.ask(self) { [self] shouldClose in
            // delegate.selector(document, shouldClose: Bool, contextInfo:) is how NSDocument reports the answer
            let target = delegate as AnyObject
            guard let imp = target.method(for: selector) else { return }
            typealias Reply = @convention(c) (AnyObject, Selector, AnyObject, Bool, UnsafeMutableRawPointer?) -> Void
            unsafeBitCast(imp, to: Reply.self)(target, selector, self, shouldClose, contextInfo)
        }
    }
}

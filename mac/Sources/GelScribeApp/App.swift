import AppKit
import GelKit
import SwiftUI
import UniformTypeIdentifiers

@main
struct GelScribeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @AppStorage(AppAppearance.key) private var appearance: AppAppearance = .dark

    var body: some Scene {
        DocumentGroup(newDocument: { GelDocument() }) { file in
            ContentView(document: file.document, fileURL: file.fileURL)
                .frame(minWidth: 980, minHeight: 640)
        }
        .defaultSize(width: 1440, height: 920)
        .windowToolbarStyle(.unifiedCompact)
        .commands { AppCommands() }

        Settings {
            SettingsTabs()
                .preferredColorScheme(appearance.colorScheme)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillFinishLaunching(_ notification: Notification) {
        AppAppearance.apply()   // dark unless View › Appearance says light
    }

    private var titleBarMonitor: Any?

    /// Files sent from outside (Finder's Open With, the Dock icon, `open -a`): an image starts a new project, like
    /// dropping it on a new window; anything else goes to the document controller as usual.
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            if ImageOpener.isImage(url) {
                ImageOpener.shared.open(url)
            } else {
                NSDocumentController.shared.openDocument(withContentsOf: url, display: true) { _, _, error in
                    if let error, (error as? CocoaError)?.code != .userCancelled { NSApp.presentError(error) }
                }
            }
        }
    }

    /// No Help menu: `CommandGroup(replacing: .help)` empties it, and this hides the empty menu. Hidden rather than
    /// removed, so SwiftUI doesn't put it back when it rebuilds the menus; checked before each update all the same.
    func applicationWillUpdate(_ notification: Notification) {
        for item in NSApp.mainMenu?.items ?? [] where !item.isHidden && item.submenu != nil
            && (item.submenu === NSApp.helpMenu || item.title == "Help") {
            item.isHidden = true
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        Task { await LLMAccess.shared.apply() }   // only listens if the user turned LLM access on
        // double-clicking an empty part of a document window's title bar fills the screen (not full-screen mode);
        // doing it again puts the window back as it was
        titleBarMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { event in
            guard event.clickCount == 2, let w = event.window, Self.isEmptyTitleBar(event.locationInWindow, in: w) else { return event }
            w.zoom(nil)
            return nil
        }
    }

    /// The strip above a document window's content, away from its buttons and toolbar items.
    static func isEmptyTitleBar(_ p: NSPoint, in w: NSWindow) -> Bool {
        guard w.styleMask.contains(.titled), w.styleMask.contains(.resizable), !(w is NSPanel),
              p.y > w.contentLayoutRect.maxY, let frame = w.contentView?.superview else { return false }
        var view = frame.hitTest(p)   // the frame view has no superview: window coordinates
        while let v = view, v !== frame {
            let name = NSStringFromClass(type(of: v))
            if v is NSControl || name.contains("ItemViewer") || name.contains("Hosting") { return false }
            view = v.superview
        }
        return true
    }
}

/// Which Settings tab shows. Not saved, so each launch starts on Shortcuts; Tools → LLM Access… picks "llm".
@Observable
final class SettingsNavigation {
    static let shared = SettingsNavigation()
    var tab = LaunchOptions.shared.value("--settings").flatMap { ["shortcuts", "llm"].contains($0) ? $0 : nil } ?? "shortcuts"
}

/// Settings: keyboard shortcuts, then LLM access.
struct SettingsTabs: View {
    @Bindable private var nav = SettingsNavigation.shared
    var body: some View {
        TabView(selection: $nav.tab) {
            ShortcutsSettings().tabItem { Label("Shortcuts", systemImage: "keyboard") }.tag("shortcuts")
            SettingsView().tabItem { Label("LLM Access", systemImage: "sparkle") }.tag("llm")
        }
    }
}

/// Opens images as new untitled projects. The image itself is never the document, so macOS can't save over it.
final class ImageOpener {
    static let shared = ImageOpener()
    private var newDocument: NewDocumentAction?
    private var waiting: [URL] = []

    static func isImage(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.contentTypeKey]))?.contentType?.conforms(to: .image) == true
    }

    /// SwiftUI's new-document action, from the menu bar commands. Images that arrived before it (at launch) open now.
    func ready(_ action: NewDocumentAction) {
        guard newDocument == nil else { return }
        newDocument = action
        let urls = waiting
        waiting = []
        Task { urls.forEach(open) }
    }

    func open(_ url: URL) {
        guard let newDocument else { waiting.append(url); return }
        do {
            let pkg = try GelPackage.create(imageURL: url)
            newDocument { GelDocument(package: pkg) }
        } catch {
            NSAlert(error: error).runModal()
        }
    }
}

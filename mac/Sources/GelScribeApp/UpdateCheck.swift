import AppKit
import SwiftUI

/// A newer release found on GitHub.
struct ReleaseInfo: Equatable {
    let version: String   // without a leading "v"
    let url: URL
    let notes: String
}

/// The update notice: asks GitHub (once a day, in the background) whether a newer release exists and offers a link.
/// Nothing is downloaded or installed, and nothing but the request itself is sent.
enum UpdateCheck {
    static let enabledKey = "updateCheckEnabled"
    static let lastCheckKey = "lastUpdateCheck"
    static let interval: TimeInterval = 24 * 3600
    static let endpoint = URL(string: "https://api.github.com/repos/pratiman-de/GelScribe/releases/latest")!

    /// What the check found. `skipped` is an automatic check that wasn't due (or is turned off).
    enum Outcome: Equatable { case newer(ReleaseInfo), upToDate, failed, skipped }

    /// Returns the response body. Tests pass their own; the app's does the request.
    typealias Fetch = @Sendable (URLRequest) async throws -> Data

    /// The running version, from Info.plist (written by make-app.sh).
    nonisolated static var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    /// "v0.1.1" or "0.1.1" as numbers; nil when it isn't dotted numbers.
    nonisolated static func parts(_ tag: String) -> [Int]? {
        var s = tag.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("v") || s.hasPrefix("V") { s.removeFirst() }
        let pieces = s.split(separator: ".", omittingEmptySubsequences: false).map { Int($0) }
        guard !pieces.isEmpty, !pieces.contains(nil) else { return nil }
        return pieces.compactMap { $0 }
    }

    /// Numeric, part by part (0.10 > 0.9, 0.1 < 0.1.1); missing parts count as 0.
    nonisolated static func isNewer(_ candidate: String, than current: String) -> Bool {
        guard let a = parts(candidate), let b = parts(current) else { return false }
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0, y = i < b.count ? b[i] : 0
            if x != y { return x > y }
        }
        return false
    }

    /// tag_name, html_url and body from a GitHub "latest release" response; nil when anything needed is missing.
    nonisolated static func parseRelease(_ data: Data) -> ReleaseInfo? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = json["tag_name"] as? String, parts(tag) != nil,
              let link = json["html_url"] as? String, let url = URL(string: link), url.scheme == "https" else { return nil }
        let version = tag.trimmingCharacters(in: .whitespaces).drop { $0 == "v" || $0 == "V" }
        return ReleaseInfo(version: String(version), url: url, notes: json["body"] as? String ?? "")
    }

    /// The first lines of the release notes, blank lines dropped.
    nonisolated static func excerpt(_ notes: String, maxLines: Int = 6) -> String {
        notes.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }.prefix(maxLines).joined(separator: "\n")
    }

    static func isEnabled(_ defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: enabledKey) as? Bool ?? true
    }

    /// Whether an automatic check is due now.
    static func isDue(now: Date, defaults: UserDefaults = .standard) -> Bool {
        guard isEnabled(defaults) else { return false }
        guard let last = defaults.object(forKey: lastCheckKey) as? Date else { return true }
        return now.timeIntervalSince(last) >= interval || last > now
    }

    /// One check. Automatic checks (`manual: false`) honor the setting and the 24 hour throttle; a manual one always asks.
    /// The time is stored only after an answer arrived, so any error means trying again next launch.
    static func run(manual: Bool, current: String = currentVersion, now: Date = Date(),
                    defaults: UserDefaults = .standard, fetch: Fetch = defaultFetch) async -> Outcome {
        if !manual && !isDue(now: now, defaults: defaults) { return .skipped }
        var request = URLRequest(url: endpoint, timeoutInterval: 10)
        request.setValue("GelScribe/\(current)", forHTTPHeaderField: "User-Agent")
        guard let data = try? await fetch(request), let release = parseRelease(data) else { return .failed }
        defaults.set(now, forKey: lastCheckKey)
        return isNewer(release.version, than: current) ? .newer(release) : .upToDate
    }

    static let defaultFetch: Fetch = { request in
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
        return data
    }
}

/// Shows the results: a sheet on the front window (a small panel when there is none), never a blocking alert.
@MainActor
final class UpdateNotice {
    static let shared = UpdateNotice()
    private var showing = false

    /// On launch, in the background: silent unless a newer release is found.
    func checkOnLaunch() {
        Task {
            if case .newer(let release) = await UpdateCheck.run(manual: false) { present(release) }
        }
    }

    /// Help › Check for Updates…: checks now and always says what it found.
    func checkNow() {
        Task {
            switch await UpdateCheck.run(manual: true) {
            case .newer(let release): present(release)
            case .upToDate: info("GelScribe \(UpdateCheck.currentVersion) is the latest version.")
            default: info("Couldn't check for updates. Check your internet connection.")
            }
        }
    }

    private var frontWindow: NSWindow? {
        NSApp.keyWindow ?? NSApp.mainWindow ?? NSApp.windows.first { $0.isVisible && $0.styleMask.contains(.titled) && !($0 is NSPanel) }
    }

    private func info(_ text: String) {
        let alert = NSAlert()
        alert.messageText = text
        if let w = frontWindow { alert.beginSheetModal(for: w) } else { alert.runModal() }
    }

    private func present(_ release: ReleaseInfo) {
        guard !showing else { return }
        showing = true
        let panel = NSPanel(contentViewController: NSHostingController(rootView: UpdateNoticeView(release: release) { [weak self] in
            self?.close($0)
        }))
        panel.styleMask = [.titled]
        panel.title = ""
        if let w = frontWindow { w.beginSheet(panel) } else { panel.center(); panel.makeKeyAndOrderFront(nil) }
    }

    private func close(_ panel: NSWindow?) {
        showing = false
        guard let panel else { return }
        if let parent = panel.sheetParent { parent.endSheet(panel) }
        panel.orderOut(nil)
    }
}

private struct UpdateNoticeView: View {
    let release: ReleaseInfo
    let done: (NSWindow?) -> Void
    @State private var window: NSWindow?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("GelScribe \(release.version) is available").font(.headline)
            Text("You have \(UpdateCheck.currentVersion).").foregroundStyle(.secondary)
            let notes = UpdateCheck.excerpt(release.notes)
            if !notes.isEmpty { Text(notes).font(.callout).lineLimit(6).fixedSize(horizontal: false, vertical: true) }
            HStack {
                Button("Don't show this again") {
                    UserDefaults.standard.set(false, forKey: UpdateCheck.enabledKey)
                    done(window)
                }
                Spacer()
                Button("Later") { done(window) }.keyboardShortcut(.cancelAction)
                Button("Download") {
                    NSWorkspace.shared.open(release.url)
                    done(window)
                }.keyboardShortcut(.defaultAction)
            }
            .padding(.top, 4)
        }
        .padding(20)
        .frame(width: 420)
        .background(WindowGrabber { window = $0 })
    }
}

private struct WindowGrabber: NSViewRepresentable {
    let found: (NSWindow?) -> Void
    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        DispatchQueue.main.async { found(v.window) }
        return v
    }
    func updateNSView(_ nsView: NSView, context: Context) {}
}

/// Settings › General.
struct GeneralSettings: View {
    @AppStorage(UpdateCheck.enabledKey) private var updates = true
    var body: some View {
        Form {
            Toggle("Check for updates when GelScribe opens", isOn: $updates)
            Text("Once a day GelScribe asks GitHub whether a newer release exists. It sends nothing but that request, and downloads nothing.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
        .frame(width: 620, height: 200)
    }
}

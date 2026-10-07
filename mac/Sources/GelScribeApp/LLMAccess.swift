import AppKit
import GelKit
import GelMCP
import GelService
import Observation
import SwiftUI

// LLM access to the live app over MCP (localhost HTTP). Off until the user turns it on in Settings.
// Every LLM edit is one undoable step named "LLM: …" on the window it touched, so the user can see and revert it.

/// Open windows, so the MCP host can find them.
final class AppRegistry {
    static let shared = AppRegistry()
    private var items: [UUID: WeakWorkspace] = [:]
    struct WeakWorkspace { weak var ws: Workspace? }

    func register(_ ws: Workspace) { items[ws.id] = WeakWorkspace(ws: ws) }
    func unregister(_ ws: Workspace) { items[ws.id] = nil }
    var all: [Workspace] {
        items = items.filter { $0.value.ws != nil }
        return items.values.compactMap(\.ws).sorted { $0.openedAt < $1.openedAt }
    }
    func find(_ key: String) -> Workspace? {
        if let u = UUID(uuidString: key), let ws = items[u]?.ws { return ws }
        let std = URL(fileURLWithPath: (key as NSString).expandingTildeInPath).standardizedFileURL.path
        return all.first { $0.fileURL?.standardizedFileURL.path == std }
    }
}

/// ProjectHost over the app's open documents. Runs on the main actor, like the documents.
@MainActor
final class AppProjectHost: ProjectHost {
    func list() async -> [ProjectInfo] {
        AppRegistry.shared.all.filter { $0.document.hasImage }.map(info)
    }

    func open(path: String) async throws -> ProjectInfo {
        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath).standardizedFileURL
        if let ws = AppRegistry.shared.find(url.path) { return info(ws) }
        _ = try await NSDocumentController.shared.openDocument(withContentsOf: url, display: true)
        for _ in 0..<40 {   // the window's workspace registers on appear
            if let ws = AppRegistry.shared.find(url.path) { return info(ws) }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw GelServiceError("opened \(url.lastPathComponent), but its window didn't appear")
    }

    func create(imagePath: String, savePath: String?) async throws -> ProjectInfo {
        let (img, dest) = try PathRules.newProject(imagePath: imagePath, savePath: savePath)
        try GelPackage.create(imageURL: img).write(to: dest)
        return try await open(path: dest.path)
    }

    func access<T: Sendable>(_ id: String, action: String?,
                             _ body: @Sendable (inout GelProject, WorkingImage) throws -> T) async throws -> T {
        guard let ws = AppRegistry.shared.find(id) else {
            // a path to a project that isn't open yet
            if FileManager.default.fileExists(atPath: (id as NSString).expandingTildeInPath) {
                let opened = try await open(path: id)
                return try await access(opened.id, action: action, body)
            }
            throw GelServiceError("no open project \(id); call list_projects or open_project")
        }
        ws.refreshCaches()
        guard var work = ws.working else { throw GelServiceError("that window has no image yet") }
        // a cut membrane's other pieces, for exports and previews, each by its own number: a gel that can't be read is
        // said, never left out (the gels under it would shift into its place)
        var strips: [WorkingImage] = []
        for k in ws.project.strips.indices {
            guard let w = ws.stripWorking(k + 1) else { throw GelServiceError(ws.project.unreadableMessage(strip: k + 1)) }
            strips.append(w)
        }
        work.strips = strips
        var p = ws.project
        let result = try body(&p, work)
        if let action {
            p.settle(with: work)   // whatever a tool did, nothing but sane numbers inside the gels reaches the document
            if p != ws.project {
                ws.edit("LLM: \(action)") { $0 = p }
                ws.noteLLM(action)
            }
        }
        return result
    }

    private func info(_ ws: Workspace) -> ProjectInfo {
        let p = ws.project
        return ProjectInfo(id: ws.id.uuidString, path: ws.fileURL?.path, image: p.image, title: p.title, lanes: p.laneCount, strict: p.strict)
    }
}

@Observable
final class LLMAccess {
    static let shared = LLMAccess()

    static let defaultPort = 47860
    /// Ports below 1024 are for the system; 65535 is the largest there is.
    static let portRange = 1024...65535

    var enabled: Bool {
        didSet {
            UserDefaults.standard.set(enabled, forKey: "mcpEnabled")
            if enabled { oldTokenNoteSeen() }   // the new command is on show now: what the note asks for is being done
            Task { await apply() }
        }
    }
    var port: Int {
        didSet { UserDefaults.standard.set(port, forKey: "mcpPort") }
    }
    /// Empty until `loadToken()` has run. Kept in the Keychain; only an older version's copy in the preferences is ever read
    /// from there, to move it.
    private(set) var token = ""
    /// Something about the token worth telling the user: it couldn't be kept safely.
    private(set) var tokenNote: String?
    /// Shown once in Settings when an older version's token was removed at launch (a `claude mcp add` set-up made with it no longer
    /// works); nil when there's nothing to say, or it has been seen.
    private(set) var oldTokenNote: String?
    static let oldTokenText = "A token from an older version was removed. Turn on LLM access and copy the new command into your LLM client."
    static let oldTokenFlag = "mcpOldTokenRemoved"
    private(set) var listeningPort: UInt16?
    private(set) var problem: String?

    @ObservationIgnored private var http: MCPHTTPServer?
    @ObservationIgnored private var tokenLoaded = false
    /// Counts stops and restarts, so a start that was still under way when one came can tell it's out of date.
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var syncing = false
    @ObservationIgnored private var again = false

    private static let tokens = TokenStore(secrets: KeychainSecret(service: "local.gelscribe.mcp", account: "http-token"))

    private init() {
        let d = UserDefaults.standard
        enabled = d.bool(forKey: "mcpEnabled")
        port = d.object(forKey: "mcpPort") as? Int ?? Self.defaultPort
        // The Keychain is only touched once LLM access is on: start() reads the token (and moves an older version's copy
        // there). With LLM access off, an old copy left in the preferences isn't used, so it's removed, and Settings says so once.
        Self.dropOldToken(in: d, enabled: enabled)
        oldTokenNote = d.bool(forKey: Self.oldTokenFlag) ? Self.oldTokenText : nil
    }

    /// With LLM access off, removes an older version's token from the preferences and leaves a flag for the one-time note in Settings.
    static func dropOldToken(in d: UserDefaults, enabled: Bool) {
        guard !enabled else { return }
        if d.object(forKey: "mcpToken") != nil { d.set(true, forKey: oldTokenFlag) }
        d.removeObject(forKey: "mcpToken")
    }

    /// The note has been seen (Settings closed) or is moot (LLM access turned on): it isn't shown again.
    func oldTokenNoteSeen() {
        oldTokenNote = nil
        UserDefaults.standard.removeObject(forKey: Self.oldTokenFlag)
    }

    /// Reads the token from the Keychain (making one the first time), once. An old copy in the preferences is moved there
    /// and removed from the preferences.
    func loadToken() {
        guard !tokenLoaded else { return }
        tokenLoaded = true
        let d = UserDefaults.standard
        let loaded = Self.tokens.load(legacy: d.string(forKey: "mcpToken"), forgetLegacy: { d.removeObject(forKey: "mcpToken") })
        token = loaded.token
        tokenNote = loaded.note
    }

    func regenerateToken() {
        do {
            let made = try Self.tokens.regenerate()
            tokenLoaded = true
            token = made.token
            tokenNote = made.note
            Task { await restart() }
        } catch {
            problem = "Couldn't make a new token: \(error.localizedDescription)"
        }
    }

    /// Makes the server match the switch. One run at a time: a request that comes while one is under way makes it go round again.
    func apply() async {
        again = true
        guard !syncing else { return }
        syncing = true
        defer { syncing = false }
        while again {
            again = false
            if enabled { await start() } else { stop() }
        }
    }

    func restart() async {
        stop()
        await apply()
    }

    private func start() async {
        guard http == nil else { return }
        loadToken()
        guard MCPToken.isUsable(token) else {
            problem = tokenNote ?? "LLM access needs a token, and none could be made."
            return
        }
        guard Self.portRange.contains(port) else {
            problem = portProblem
            listeningPort = nil
            return
        }
        let mine = generation
        let server = MCPServer(name: "gelscribe-app", version: "0.1", instructions: GelTools.instructions + """

        This server edits the documents open in the GelScribe app; the user sees every change live and can undo it (⌘Z).
        """, tools: GelTools.make(host: AppProjectHost()))
        let h = MCPHTTPServer(server: server, port: UInt16(port), token: token)
        do {
            let listening = try await h.start()
            guard generation == mine, enabled else { h.stop(); return }   // switched off, or restarted, while it was starting
            listeningPort = listening
            http = h
            problem = nil
        } catch {
            guard generation == mine, !(error is CancellationError) else { return }
            problem = "Could not listen on 127.0.0.1:\(port): \(error.localizedDescription)"
            listeningPort = nil
        }
    }

    private func stop() {
        generation += 1
        http?.stop()
        http = nil
        listeningPort = nil
        problem = nil
    }

    var portProblem: String? {
        Self.portRange.contains(port) ? nil : "Port must be a number from \(Self.portRange.lowerBound) to \(Self.portRange.upperBound)."
    }

    /// The port the command names: the one the server listens on.
    private var commandPort: Int { listeningPort.map(Int.init) ?? port }

    private func httpCommand(token t: String) -> String {
        "claude mcp add --transport http gelscribe http://127.0.0.1:\(commandPort)/mcp --header \"Authorization: Bearer \(t)\""
    }
    /// What's copied.
    var httpCommand: String { httpCommand(token: token) }
    /// What's shown: the token's first four characters, then dots.
    var maskedHttpCommand: String { httpCommand(token: MCPToken.masked(token)) }
    var stdioCommand: String {
        "claude mcp add gelscribe -- \"\(Bundle.main.bundlePath)/Contents/Helpers/gelscribe\" mcp"
    }
}

struct SettingsView: View {
    @Bindable var access = LLMAccess.shared
    @State private var copied: String?

    var body: some View {
        Form {
            Section {
                Toggle("Allow LLM access (MCP)", isOn: $access.enabled)
                if let p = access.listeningPort {
                    Label("Listening on 127.0.0.1:\(String(p)) (this Mac only, token required)", systemImage: "dot.radiowaves.left.and.right")
                        .foregroundStyle(.green)
                } else if let problem = access.problem {
                    Label(problem, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                } else {
                    Label("Off", systemImage: "moon.zzz").foregroundStyle(.secondary)
                }
                TextField("Port", value: $access.port, format: .number.grouping(.never))
                    .onSubmit { Task { await access.restart() } }
                if let message = access.portProblem, message != access.problem {   // the status above already says it, when it's the problem
                    Label(message, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                }
                if let note = access.oldTokenNote {
                    Label(note, systemImage: "info.circle").foregroundStyle(.secondary)
                }
            } header: {
                Text("LLM access")
            } footer: {
                Text("An LLM can place lane dividers, labels, ladder ticks and band names in the windows you have open, and export figures. It cannot modify original images, turn off strict mode or change pixel adjustments. Every change is one undo step named “LLM: …”.")
                    .foregroundStyle(.secondary)
            }

            Section("Connect Claude Code (live app)") {
                if access.enabled {
                    CommandRow(text: access.maskedHttpCommand, copy: access.httpCommand, copied: $copied)
                    HStack {
                        Text("Token").foregroundStyle(.secondary)
                        Text(MCPToken.masked(access.token)).font(.system(.body, design: .monospaced))
                        Spacer()
                        Button("New Token") { access.regenerateToken() }
                    }
                    if let note = access.tokenNote {
                        Label(note, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    }
                } else {
                    // The token lives in the Keychain, which is left alone until LLM access is turned on.
                    Text("Turn on LLM access to see the command and its token.").foregroundStyle(.secondary)
                }
            }
            Section("Or headless, on project files (no app needed)") {
                CommandRow(text: access.stdioCommand, copied: $copied)
            }
        }
        .formStyle(.grouped)
        .frame(width: 620, height: 600)   // tall enough that nothing needs scrolling
        .padding(.vertical, 8)
        .onDisappear { access.oldTokenNoteSeen() }   // once: shown while Settings is open, gone the next time
    }
}

/// A command to show and copy. `text` is what's shown; `copy` (when it differs, like a command with its token hidden) is what
/// the Copy button puts on the clipboard.
struct CommandRow: View {
    let text: String
    var copy: String?
    @Binding var copied: String?
    private var payload: String { copy ?? text }
    var body: some View {
        HStack(alignment: .top) {
            Text(text)
                .font(.system(size: 11, design: .monospaced))
                .textSelection(.enabled)
                .lineLimit(4)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button(copied == payload ? "Copied" : "Copy") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(payload, forType: .string)
                copied = payload
            }
        }
    }
}

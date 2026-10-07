import Foundation
import Network

/// MCP "Streamable HTTP" transport with plain JSON responses (no server-initiated streams).
///
/// Restrictions, all enforced per request:
/// - listens on 127.0.0.1 only;
/// - requires `Authorization: Bearer <token>` (the scheme in any letter case) when a token is set;
/// - rejects any `Host` that isn't loopback and any `Origin` that isn't a loopback http(s) origin (DNS rebinding);
/// - checks all of that from the headers alone, so a request that isn't allowed never gets its body read;
/// - holds at most `HTTPLimits` of anything: headers, trailers, body, open connections, time a connection may sit idle.
public final class MCPHTTPServer: @unchecked Sendable {
    private let server: MCPServer
    private let requestedPort: UInt16
    private let token: String?
    private let path: String
    private let limits: HTTPLimits
    private let queue = DispatchQueue(label: "gelscribe.mcp.http")
    private var listener: NWListener?
    private var connections: [ObjectIdentifier: HTTPConnection] = [:]
    private var sweeper: DispatchSourceTimer?
    public private(set) var port: UInt16?

    public convenience init(server: MCPServer, port: UInt16 = 0, token: String?, path: String = "/mcp") {
        self.init(server: server, port: port, token: token, path: path, limits: HTTPLimits())
    }

    init(server: MCPServer, port: UInt16, token: String?, path: String, limits: HTTPLimits) {
        self.server = server
        self.requestedPort = port
        self.token = token
        self.path = path
        self.limits = limits
    }

    public func start() async throws -> UInt16 {
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        params.requiredInterfaceType = .loopback
        params.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: NWEndpoint.Port(rawValue: requestedPort) ?? .any)
        let l = try NWListener(using: params)
        l.newConnectionHandler = { [weak self] c in self?.accept(c) }
        let once = Once()
        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<UInt16, Error>) in
            l.stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready:
                    guard once.claim() else { return }
                    let p = l.port?.rawValue ?? 0
                    self?.port = p
                    cont.resume(returning: p)
                case .failed(let e):
                    guard once.claim() else { return }
                    cont.resume(throwing: e)
                case .cancelled:
                    // stopped before it was ready: the caller isn't left waiting
                    guard once.claim() else { return }
                    cont.resume(throwing: CancellationError())
                default: break
                }
            }
            queue.async { self.listener = l; self.startSweeping() }
            l.start(queue: queue)
            // a listener that never gets to ready (and never fails) mustn't leave the caller waiting for good
            queue.asyncAfter(deadline: .now() + Self.startTimeout) {
                guard once.claim() else { return }
                l.cancel()
                cont.resume(throwing: StartError())
            }
        }
    }

    /// Seconds a listener has to become ready.
    static let startTimeout = 10.0

    struct StartError: Error, LocalizedError {
        var errorDescription: String? { "The server didn't start within \(Int(MCPHTTPServer.startTimeout)) seconds." }
    }

    public func stop() {
        queue.async {
            self.sweeper?.cancel()
            self.sweeper = nil
            self.listener?.cancel()
            self.listener = nil
            for c in Array(self.connections.values) { c.close() }
            self.connections.removeAll()
            self.port = nil
        }
    }

    private func accept(_ c: NWConnection) {
        if connections.count >= limits.connections { sweep() }
        guard connections.count < limits.connections else { c.cancel(); return }   // full: the newcomer waits its turn elsewhere
        let conn = HTTPConnection(connection: c, queue: queue, owner: self, limits: limits)
        connections[ObjectIdentifier(conn)] = conn
        conn.start()
    }

    fileprivate func finished(_ conn: HTTPConnection) { connections[ObjectIdentifier(conn)] = nil }

    /// Closes connections that have sat idle too long, or taken too long to send one request.
    private func startSweeping() {
        sweeper?.cancel()
        let t = DispatchSource.makeTimerSource(queue: queue)
        let every = max(0.05, min(limits.idle, limits.request) / 4)
        t.schedule(deadline: .now() + every, repeating: every)
        t.setEventHandler { [weak self] in self?.sweep() }
        t.resume()
        sweeper = t
    }

    private func sweep() {
        let now = DispatchTime.now()
        for c in Array(connections.values) where c.expired(now) { c.close() }
    }

    // MARK: request handling

    /// Why a request isn't allowed, judged from its head alone (nil: it is). Done before its body is read.
    fileprivate func screen(_ r: HTTPRequest) -> HTTPResponse? {
        guard let host = r.headers["host"], Self.isLoopbackHost(host) else { return .text(403, "Forbidden: Host must be loopback") }
        if let origin = r.headers["origin"], !Self.isLoopbackOrigin(origin) { return .text(403, "Forbidden: Origin not allowed") }
        if let token {
            guard let got = Self.bearerToken(r.headers["authorization"]), Self.constantTimeEqual(got, token) else {
                var resp = HTTPResponse.text(401, "Unauthorized")
                resp.headers["WWW-Authenticate"] = "Bearer"
                return resp
            }
        }
        let p = r.path.split(separator: "?", maxSplits: 1).first.map(String.init) ?? r.path
        guard p == path else { return .text(404, "Not Found") }
        guard ["POST", "GET", "DELETE"].contains(r.method) else {
            var resp = HTTPResponse.text(405, "Method Not Allowed")
            resp.headers["Allow"] = "POST, DELETE"
            return resp
        }
        return nil
    }

    fileprivate func respond(to r: HTTPRequest) async -> HTTPResponse {
        if let refusal = screen(r) { return refusal }
        switch r.method {
        case "POST":
            guard let reply = await server.handle(r.body) else { return HTTPResponse(status: 202) }
            var resp = HTTPResponse(status: 200, body: reply)
            resp.headers["Content-Type"] = "application/json"
            if MCPServer.isInitialize(r.body) { resp.headers["Mcp-Session-Id"] = UUID().uuidString }
            return resp
        case "GET":
            var resp = HTTPResponse.text(405, "Method Not Allowed: this server sends no event stream")
            resp.headers["Allow"] = "POST, DELETE"
            return resp
        default:   // DELETE
            return HTTPResponse(status: 204)
        }
    }

    static func isLoopbackHost(_ hostHeader: String) -> Bool {
        let h = hostHeader.trimmingCharacters(in: .whitespaces).lowercased()
        let name: Substring
        if h.hasPrefix("[") {
            guard let end = h.firstIndex(of: "]") else { return false }
            name = h[h.index(after: h.startIndex)..<end]
            let rest = h[h.index(after: end)...]
            guard rest.isEmpty || (rest.hasPrefix(":") && rest.dropFirst().allSatisfy(\.isNumber)) else { return false }
        } else {
            let parts = h.split(separator: ":", omittingEmptySubsequences: false)
            guard parts.count <= 2 else { return false }
            if parts.count == 2 { guard !parts[1].isEmpty, parts[1].allSatisfy(\.isNumber) else { return false } }
            name = parts[0]
        }
        return name == "127.0.0.1" || name == "localhost" || name == "::1"
    }

    static func isLoopbackOrigin(_ origin: String) -> Bool {
        let o = origin.trimmingCharacters(in: .whitespaces).lowercased()
        for scheme in ["http://", "https://"] where o.hasPrefix(scheme) {
            let rest = o.dropFirst(scheme.count)
            guard !rest.contains("/") else { return false }
            return isLoopbackHost(String(rest))
        }
        return false
    }

    /// The token in an `Authorization: Bearer <token>` header. The scheme's letter case doesn't matter (RFC 9110), the
    /// token's does.
    static func bearerToken(_ header: String?) -> String? {
        guard let header else { return nil }
        let parts = header.trimmingCharacters(in: .whitespaces).split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
        guard parts.count == 2, parts[0].lowercased() == "bearer" else { return nil }
        return parts[1].trimmingCharacters(in: .whitespaces)
    }

    static func constantTimeEqual(_ a: String, _ b: String) -> Bool {
        let x = Array(a.utf8), y = Array(b.utf8)
        var diff = UInt8(x.count == y.count ? 0 : 1)
        for i in 0..<max(x.count, y.count) {
            diff |= (i < x.count ? x[i] : 0) ^ (i < y.count ? y[i] : 0)
        }
        return diff == 0
    }
}

private final class Once: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    func claim() -> Bool { lock.lock(); defer { lock.unlock() }; if done { return false }; done = true; return true }
}

// MARK: - one connection

/// Everything here runs on the server's queue.
fileprivate final class HTTPConnection: @unchecked Sendable {
    private let connection: NWConnection
    private let queue: DispatchQueue
    private weak var owner: MCPHTTPServer?
    private let limits: HTTPLimits
    private var parser: HTTPParser
    /// A request is being answered. Nothing is read meanwhile, so a client that keeps sending waits on the network
    /// instead of piling up in memory.
    private var busy = false
    private var reading = false
    private var closed = false
    private var peerClosed = false
    private var lastActivity = DispatchTime.now()
    /// When the first byte of the request still being received came.
    private var requestStarted: DispatchTime?

    init(connection: NWConnection, queue: DispatchQueue, owner: MCPHTTPServer, limits: HTTPLimits) {
        self.connection = connection
        self.queue = queue
        self.owner = owner
        self.limits = limits
        self.parser = HTTPParser(limits: limits)
    }

    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled: self?.close()
            default: break
            }
        }
        connection.start(queue: queue)
        receive()
    }

    func close() {
        guard !closed else { return }
        closed = true
        connection.cancel()
        owner?.finished(self)
    }

    func expired(_ now: DispatchTime) -> Bool {
        guard !busy else { return false }   // a tool is at work; it isn't the client that's slow
        func seconds(since t: DispatchTime) -> Double { Double(now.uptimeNanoseconds &- t.uptimeNanoseconds) / 1e9 }
        if seconds(since: lastActivity) > limits.idle { return true }
        if let started = requestStarted, seconds(since: started) > limits.request { return true }
        return false
    }

    private func receive() {
        guard !closed, !reading else { return }
        reading = true
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 << 10) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            self.reading = false
            guard !self.closed else { return }
            if let data, !data.isEmpty {
                let now = DispatchTime.now()
                self.lastActivity = now
                if self.requestStarted == nil { self.requestStarted = now }
                self.parser.feed(data)
            }
            if error != nil { self.close(); return }
            if isComplete { self.peerClosed = true }
            self.advance()
        }
    }

    /// Takes what has arrived as far as it goes: each request's head is checked before its body is read, and requests are
    /// answered one at a time.
    private func advance() {
        while !busy && !closed {
            switch parser.next() {
            case .needMore:
                if peerClosed { close() } else { receive() }
                return
            case .fail(let status, let message):
                send(.text(status, message), keepAlive: false)
                return
            case .head(let head):
                if let refusal = owner?.screen(head) { send(refusal, keepAlive: false); return }   // its body is never read
                if head.headers["expect"]?.lowercased() == "100-continue" {
                    connection.send(content: Data("HTTP/1.1 100 Continue\r\n\r\n".utf8), completion: .idempotent)
                }
            case .request(let req):
                requestStarted = parser.buffered > 0 ? DispatchTime.now() : nil
                busy = true
                let keepAlive = req.keepAlive && !peerClosed
                Task { [weak self] in
                    guard let self, let owner = self.owner else { return }
                    let resp = await owner.respond(to: req)
                    self.queue.async {
                        self.busy = false
                        self.lastActivity = DispatchTime.now()
                        self.send(resp, keepAlive: keepAlive)
                        if keepAlive { self.advance() }
                    }
                }
            }
        }
    }

    private func send(_ resp: HTTPResponse, keepAlive: Bool) {
        guard !closed else { return }
        connection.send(content: resp.serialized(keepAlive: keepAlive, idle: Int(limits.idle)), completion: .contentProcessed { [weak self] _ in
            if !keepAlive { self?.close() }
        })
    }
}

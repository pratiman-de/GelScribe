import Foundation

// HTTP/1.1 framing for the localhost transport. Whatever a client sends, memory and work stay bounded: every part of a
// request has a cap, bytes are dropped as soon as they've been used, and a request can be refused from its headers alone,
// before any of its body is read.

/// How much of anything a client may make the server hold.
struct HTTPLimits {
    /// The request line and the headers together.
    var head = 64 << 10
    var headerLines = 100
    /// A request's body (after chunking).
    var body = 16 << 20
    /// The line that gives a chunk's size.
    var chunkLine = 1024
    /// Everything after the last chunk.
    var trailers = 8 << 10
    /// Open connections.
    var connections = 32
    /// Seconds a connection may sit with nothing happening, and to get one request in once it has started.
    var idle: TimeInterval = 30
    var request: TimeInterval = 60
}

struct HTTPRequest {
    var method = ""
    var path = ""
    var headers: [String: String] = [:]
    var body = Data()
    var keepAlive = true
}

struct HTTPError: Error {
    var status: Int
    var message: String
    init(_ status: Int, _ message: String) { self.status = status; self.message = message }
}

/// Reads one request at a time from the bytes of a connection, as they arrive.
struct HTTPParser {
    enum Event {
        /// Nothing complete yet; feed more.
        case needMore
        /// The request line and headers are in and the body isn't. The caller may refuse the request here, so a body that
        /// isn't wanted is never read; calling `next()` again goes on to the body.
        case head(HTTPRequest)
        case request(HTTPRequest)
        /// Not acceptable: answer with this status and message, then close.
        case fail(Int, String)
    }

    private enum State { case head, length(Int), chunkSize, chunk(Int), chunkEnd, trailers }
    private enum Framing { case none, length(Int), chunked }

    let limits: HTTPLimits
    private var state = State.head
    private var buf: [UInt8] = []
    /// Where the bytes not used yet start.
    private var pos = 0
    /// While waiting for the end of the headers: how far past `pos` has been searched for it.
    private var searched = 0
    private var current = HTTPRequest()
    private var trailerBytes = 0

    init(limits: HTTPLimits = HTTPLimits()) { self.limits = limits }

    /// Bytes waiting that haven't been used.
    var buffered: Int { buf.count - pos }

    mutating func feed(_ data: Data) { buf.append(contentsOf: data) }

    mutating func next() -> Event {
        while true {
            switch state {
            case .head:
                guard let end = blankLine() else {
                    compact()
                    return buf.count > limits.head + 3 ? .fail(431, "Headers too large") : .needMore
                }
                guard end - 4 - pos <= limits.head else { return .fail(431, "Headers too large") }
                do {
                    let (request, framing) = try Self.parseHead(buf[pos..<(end - 4)], limits: limits)
                    pos = end
                    searched = 0
                    current = request
                    switch framing {
                    case .none: state = .length(0)
                    case .length(let n): state = .length(n)
                    case .chunked: state = .chunkSize
                    }
                    return .head(request)
                } catch let e as HTTPError {
                    return .fail(e.status, e.message)
                } catch {
                    return .fail(400, "Bad Request")
                }

            case .length(let remaining):
                let n = min(remaining, buf.count - pos)
                current.body.append(contentsOf: buf[pos..<(pos + n)])
                pos += n
                if n < remaining { state = .length(remaining - n); compact(); return .needMore }
                return finish()

            case .chunkSize:
                guard let eol = crlf() else {
                    if buf.count - pos > limits.chunkLine { return .fail(400, "Bad chunk") }
                    compact()
                    return .needMore
                }
                guard eol - pos <= limits.chunkLine, let size = Self.chunkSize(buf[pos..<eol], limit: limits.body) else {
                    return .fail(400, "Bad chunk")
                }
                // `size` comes from the sender and stops at limit + 1; compare without adding, so nothing can overflow
                guard size <= limits.body - current.body.count else { return .fail(413, "Body too large") }
                pos = eol + 2
                state = size == 0 ? .trailers : .chunk(size)

            case .chunk(let remaining):
                let n = min(remaining, buf.count - pos)
                current.body.append(contentsOf: buf[pos..<(pos + n)])
                pos += n
                if n < remaining { state = .chunk(remaining - n); compact(); return .needMore }
                state = .chunkEnd

            case .chunkEnd:
                guard buf.count - pos >= 2 else { compact(); return .needMore }
                guard buf[pos] == 13, buf[pos + 1] == 10 else { return .fail(400, "Bad chunk") }
                pos += 2
                state = .chunkSize

            case .trailers:
                // after the last chunk: header lines nobody wants, up to the blank line, within their cap
                guard let eol = crlf() else {
                    if trailerBytes + buf.count - pos > limits.trailers { return .fail(431, "Trailers too large") }
                    compact()
                    return .needMore
                }
                if eol == pos { pos += 2; return finish() }
                trailerBytes += eol - pos + 2
                guard trailerBytes <= limits.trailers else { return .fail(431, "Trailers too large") }
                pos = eol + 2
            }
        }
    }

    private mutating func finish() -> Event {
        let request = current
        current = HTTPRequest()
        state = .head
        searched = 0
        trailerBytes = 0
        compact()   // what's left is the next request, if one was sent already
        return .request(request)
    }

    private mutating func compact() {
        guard pos > 0 else { return }
        buf.removeFirst(pos)
        pos = 0
    }

    /// Index just past the blank line that ends the headers, or nil. Each byte is looked at once over any number of feeds.
    private mutating func blankLine() -> Int? {
        var i = pos + max(0, searched - 3)
        let n = buf.count
        while i + 3 < n {
            if buf[i] == 13, buf[i + 1] == 10, buf[i + 2] == 13, buf[i + 3] == 10 { return i + 4 }
            i += 1
        }
        searched = n - pos
        return nil
    }

    /// Index of the next CR LF at or after `pos`.
    private func crlf() -> Int? {
        var i = pos
        while i + 1 < buf.count {
            if buf[i] == 13, buf[i + 1] == 10 { return i }
            i += 1
        }
        return nil
    }

    private static func parseHead(_ bytes: ArraySlice<UInt8>, limits: HTTPLimits) throws -> (HTTPRequest, Framing) {
        guard let text = String(bytes: bytes, encoding: .utf8) else { throw HTTPError(400, "Bad Request") }
        let lines = text.components(separatedBy: "\r\n")
        guard lines.count <= limits.headerLines + 1 else { throw HTTPError(431, "Too many headers") }
        let start = lines[0].split(separator: " ")
        guard start.count == 3, start[2].hasPrefix("HTTP/1.") else { throw HTTPError(400, "Bad Request") }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { throw HTTPError(400, "Bad Request") }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty else { throw HTTPError(400, "Bad Request") }
            headers[name] = headers[name].map { "\($0), \(value)" } ?? value
        }
        let connection = headers["connection"]?.lowercased()
        let keepAlive = start[2] == "HTTP/1.0" ? connection?.contains("keep-alive") == true : connection?.contains("close") != true

        let framing: Framing
        if let coding = headers["transfer-encoding"] {
            // chunked and nothing else; both it and a length is how requests get smuggled past a proxy, so neither is taken
            guard coding.lowercased() == "chunked", headers["content-length"] == nil else { throw HTTPError(400, "Bad Request") }
            framing = .chunked
        } else if let length = headers["content-length"] {
            guard !length.isEmpty, length.utf8.allSatisfy({ $0 >= 0x30 && $0 <= 0x39 }) else { throw HTTPError(400, "Bad Content-Length") }
            guard length.utf8.count <= 12, let n = Int(length), n <= limits.body else { throw HTTPError(413, "Body too large") }
            framing = .length(n)
        } else {
            framing = .none
        }
        return (HTTPRequest(method: String(start[0]), path: String(start[1]), headers: headers, body: Data(), keepAlive: keepAlive), framing)
    }

    /// The size on a chunk-size line (extensions after ";" are ignored), or nil if it isn't a hex number. It stops growing
    /// at `limit + 1`, so a line of any length of digits can't overflow, and tells "too large" apart from "not a number".
    static func chunkSize(_ line: ArraySlice<UInt8>, limit: Int) -> Int? {
        var digits = line.prefix { $0 != 0x3B }
        while let c = digits.first, c == 0x20 || c == 0x09 { digits = digits.dropFirst() }
        while let c = digits.last, c == 0x20 || c == 0x09 { digits = digits.dropLast() }
        guard !digits.isEmpty else { return nil }
        var size = 0
        for c in digits {
            let v: Int
            switch c {
            case 0x30...0x39: v = Int(c) - 0x30
            case 0x41...0x46: v = Int(c) - 0x41 + 10
            case 0x61...0x66: v = Int(c) - 0x61 + 10
            default: return nil
            }
            size = min(size * 16 + v, limit + 1)
        }
        return size
    }
}

struct HTTPResponse {
    var status: Int
    var headers: [String: String] = [:]
    var body = Data()

    static func text(_ status: Int, _ s: String) -> HTTPResponse {
        var r = HTTPResponse(status: status, body: Data((s + "\n").utf8))
        r.headers["Content-Type"] = "text/plain; charset=utf-8"
        return r
    }

    /// `idle`: seconds the connection is kept waiting for the next request; told to the client so it lets go first.
    func serialized(keepAlive: Bool, idle: Int? = nil) -> Data {
        let reasons = [200: "OK", 202: "Accepted", 204: "No Content", 400: "Bad Request", 401: "Unauthorized",
                       403: "Forbidden", 404: "Not Found", 405: "Method Not Allowed", 413: "Payload Too Large",
                       431: "Request Header Fields Too Large", 500: "Internal Server Error"]
        var head = "HTTP/1.1 \(status) \(reasons[status] ?? "Status")\r\n"
        var h = headers
        h["Content-Length"] = String(body.count)
        h["Connection"] = keepAlive ? "keep-alive" : "close"
        if keepAlive, let idle { h["Keep-Alive"] = "timeout=\(idle)" }
        h["Cache-Control"] = "no-store"
        for (k, v) in h.sorted(by: { $0.key < $1.key }) { head += "\(k): \(v)\r\n" }
        head += "\r\n"
        var d = Data(head.utf8)
        d.append(body)
        return d
    }
}

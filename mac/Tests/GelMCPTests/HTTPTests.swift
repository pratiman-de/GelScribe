import Foundation
import Testing
@testable import GelMCP

// The HTTP framing, and the transport over a real loopback socket: what a hostile client can make it do.

private func request(_ headers: [String], body: String = "") -> String {
    "POST /mcp HTTP/1.1\r\nHost: 127.0.0.1\r\n" + headers.joined(separator: "\r\n") + (headers.isEmpty ? "" : "\r\n") + "\r\n" + body
}

/// Feeds `text` and returns every event up to the first that needs more bytes (or fails).
private func events(_ parser: inout HTTPParser, _ text: String, byteByByte: Bool = false) -> [HTTPParser.Event] {
    var out: [HTTPParser.Event] = []
    let pieces: [Data] = byteByByte ? text.utf8.map { Data([$0]) } : [Data(text.utf8)]
    for piece in pieces {
        parser.feed(piece)
        loop: while true {
            let e = parser.next()
            out.append(e)
            switch e {
            case .needMore: break loop
            case .fail: return out
            default: continue
            }
        }
    }
    return out
}

private func failure(_ e: [HTTPParser.Event]) -> Int? {
    for x in e { if case .fail(let status, _) = x { return status } }
    return nil
}

private func requests(_ e: [HTTPParser.Event]) -> [HTTPRequest] {
    e.compactMap { if case .request(let r) = $0 { r } else { nil } }
}

@Suite struct HTTPParsing {
    @Test func aChunkSizeThatWouldOverflowIsRefusedNotCrashed() {
        // 1 byte, then a chunk of Int.max: the old code added the two and trapped, before any token was looked at
        for size in ["7fffffffffffffff", "ffffffffffffffff", "10000000000000000", String(repeating: "f", count: 500), "1000001"] {
            var p = HTTPParser()
            let e = events(&p, request(["Transfer-Encoding: chunked"], body: "1\r\nA\r\n\(size)\r\n"))
            #expect(failure(e) == 413, "\(size.prefix(20)): \(e)")
        }
        // not numbers at all
        for size in ["-1", "+5", "zz", "", "0x5", "5 5"] {
            var p = HTTPParser()
            #expect(failure(events(&p, request(["Transfer-Encoding: chunked"], body: "\(size)\r\nAAAAA\r\n"))) == 400, "\(size)")
        }
    }

    @Test func chunkedAndPlainBodiesAssemble() {
        for byteByByte in [false, true] {
            var p = HTTPParser()
            let chunked = requests(events(&p, request(["Transfer-Encoding: chunked"], body: "5\r\nhello\r\n6;ext=1\r\n world\r\n0\r\nX-Trailer: a\r\n\r\n"), byteByByte: byteByByte))
            #expect(chunked.count == 1 && String(decoding: chunked[0].body, as: UTF8.self) == "hello world")
            var q = HTTPParser()
            let plain = requests(events(&q, request(["Content-Length: 5"], body: "hello"), byteByByte: byteByByte))
            #expect(plain.count == 1 && String(decoding: plain[0].body, as: UTF8.self) == "hello" && plain[0].keepAlive)
        }
        var p = HTTPParser()
        let two = requests(events(&p, request(["Content-Length: 1"], body: "a") + request(["Content-Length: 2", "Connection: close"], body: "bc")))
        #expect(two.map { String(decoding: $0.body, as: UTF8.self) } == ["a", "bc"] && two[0].keepAlive && !two[1].keepAlive, "pipelined")
    }

    @Test func oneByteChunksCostWorkInProportion() {
        var p = HTTPParser()
        let n = 30_000
        let e = events(&p, request(["Transfer-Encoding: chunked"], body: String(repeating: "1\r\nA\r\n", count: n) + "0\r\n\r\n"))
        #expect(requests(e).first?.body.count == n)
    }

    @Test func everyPartHasACap() {
        var small = HTTPLimits()
        small.body = 10; small.headerLines = 5; small.head = 200; small.trailers = 40; small.chunkLine = 20
        // a body too long is refused from its header, and when chunked at the chunk that goes over
        var p = HTTPParser(limits: small)
        #expect(failure(events(&p, request(["Content-Length: 11"], body: ""))) == 413)
        p = HTTPParser(limits: small)
        #expect(failure(events(&p, request(["Transfer-Encoding: chunked"], body: "6\r\naaaaaa\r\n5\r\n"))) == 413)
        p = HTTPParser(limits: small)
        #expect(requests(events(&p, request(["Transfer-Encoding: chunked"], body: "6\r\naaaaaa\r\n4\r\nbbbb\r\n0\r\n\r\n"))).first?.body.count == 10)
        // too many header lines, and headers too big
        p = HTTPParser(limits: small)
        #expect(failure(events(&p, request((0..<6).map { "X-\($0): 1" }))) == 431)
        p = HTTPParser(limits: small)
        #expect(failure(events(&p, request(["X: " + String(repeating: "a", count: 300)]))) == 431)
        p = HTTPParser(limits: small)
        #expect(failure(events(&p, "POST /mcp HTTP/1.1\r\nHost: x\r\nX: " + String(repeating: "a", count: 300))) == 431, "no end of headers in sight")
        // trailers, and a chunk-size line that never ends
        p = HTTPParser(limits: small)
        #expect(failure(events(&p, request(["Transfer-Encoding: chunked"], body: "0\r\n" + String(repeating: "T: aaaaaaaaa\r\n", count: 5)))) == 431)
        p = HTTPParser(limits: small)
        #expect(failure(events(&p, request(["Transfer-Encoding: chunked"], body: String(repeating: "0", count: 50)))) == 400)
        // the limits of the real thing
        var big = HTTPParser()
        let trailers = request(["Transfer-Encoding: chunked"], body: "0\r\n" + String(repeating: "T: " + String(repeating: "a", count: 90) + "\r\n", count: 100))
        #expect(failure(events(&big, trailers)) == 431, "128 MB of trailers made the old server grow by 128 MB")
    }

    @Test func badLengthsAndCodingsAreRefused() {
        for (header, status) in [("Content-Length: abc", 400), ("Content-Length: -5", 400), ("Content-Length: 5, 5", 400), ("Content-Length: ", 400),
                                 ("Content-Length: 99999999999999999999", 413), ("Content-Length: 17000000", 413)] {
            var p = HTTPParser()
            #expect(failure(events(&p, request([header]))) == status, "\(header)")
        }
        var p = HTTPParser()
        #expect(failure(events(&p, request(["Transfer-Encoding: chunked", "Content-Length: 5"]))) == 400, "both framings: a smuggling shape")
        p = HTTPParser()
        #expect(failure(events(&p, request(["Transfer-Encoding: gzip, chunked"]))) == 400)
        p = HTTPParser()
        #expect(failure(events(&p, "GET / HTTP/2\r\n\r\n")) == 400)
        p = HTTPParser()
        #expect(failure(events(&p, "POST /mcp HTTP/1.1\r\nno colon here\r\n\r\n")) == 400)
    }

    @Test func theHeadComesBeforeTheBody() {
        // so the server can refuse a request from its headers, with none of its body read
        var p = HTTPParser()
        let e = events(&p, request(["Content-Length: 5000000", "Authorization: Bearer nope"]))
        guard case .head(let head) = e.first else { Issue.record("expected the head first: \(e)"); return }
        #expect(head.headers["authorization"] == "Bearer nope" && head.method == "POST")
        #expect(p.buffered == 0)
    }

    @Test func bearerAnyCase() {
        #expect(MCPHTTPServer.bearerToken("Bearer abc") == "abc")
        #expect(MCPHTTPServer.bearerToken("bearer abc") == "abc")
        #expect(MCPHTTPServer.bearerToken("BEARER   abc ") == "abc")
        #expect(MCPHTTPServer.bearerToken("Bearer") == nil)
        #expect(MCPHTTPServer.bearerToken("Basic abc") == nil)
        #expect(MCPHTTPServer.bearerToken("abc") == nil)
        #expect(MCPHTTPServer.bearerToken(nil) == nil)
        #expect(MCPHTTPServer.bearerToken("Bearer ABC") != "abc", "the token itself keeps its case")
    }
}

// MARK: - over a socket

/// A client on a plain BSD socket, so it can send anything, in any order. Blocking calls run off the concurrency pool.
private final class Raw: @unchecked Sendable {
    let fd: Int32

    init?(port: UInt16) {
        fd = socket(AF_INET, SOCK_STREAM, 0)
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let rc = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        if rc != 0 { close(fd); return nil }
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
    }
    deinit { close(fd) }
    /// Bytes read past the end of the last response: the server may answer two pipelined requests in one write.
    private var pending = Data()

    func send(_ data: Data) async {
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            DispatchQueue.global().async {
                var sent = 0
                data.withUnsafeBytes { raw in
                    while sent < raw.count {
                        let n = Foundation.send(self.fd, raw.baseAddress! + sent, raw.count - sent, 0)
                        if n <= 0 { break }
                        sent += n
                    }
                }
                c.resume()
            }
        }
    }
    func send(_ s: String) async { await send(Data(s.utf8)) }

    /// Reads until the other side closes or `seconds` pass without a byte; `closed` says which.
    func read(seconds: Double = 2) async -> (data: Data, closed: Bool) {
        await withCheckedContinuation { (c: CheckedContinuation<(data: Data, closed: Bool), Never>) in
            DispatchQueue.global().async {
                var tv = timeval(tv_sec: Int(seconds), tv_usec: Int32((seconds - Double(Int(seconds))) * 1_000_000))
                setsockopt(self.fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
                var out = Data()
                var buf = [UInt8](repeating: 0, count: 65536)
                while true {
                    let n = recv(self.fd, &buf, buf.count, 0)
                    if n > 0 { out.append(contentsOf: buf[0..<n]); continue }
                    c.resume(returning: (out, n == 0 || errno != EAGAIN))
                    return
                }
            }
        }
    }

    /// One response (its head and the body its Content-Length gives), leaving the connection open.
    func response(seconds: Double = 2) async -> String {
        await withCheckedContinuation { (c: CheckedContinuation<String, Never>) in
            DispatchQueue.global().async {
                var tv = timeval(tv_sec: Int(seconds), tv_usec: Int32((seconds - Double(Int(seconds))) * 1_000_000))
                setsockopt(self.fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
                var out = self.pending
                var buf = [UInt8](repeating: 0, count: 65536)
                let sep = Data("\r\n\r\n".utf8)
                while true {
                    if let r = out.range(of: sep) {
                        let head = String(decoding: out[..<r.lowerBound], as: UTF8.self).lowercased()
                        let length = head.components(separatedBy: "\r\n").first { $0.hasPrefix("content-length:") }
                            .flatMap { Int($0.dropFirst(15).trimmingCharacters(in: .whitespaces)) } ?? 0
                        if out.count - r.upperBound >= length {
                            let end = r.upperBound + length
                            self.pending = Data(out[end...])
                            out = Data(out[..<end])
                            break
                        }
                    }
                    let n = recv(self.fd, &buf, buf.count, 0)
                    if n <= 0 { break }
                    out.append(contentsOf: buf[0..<n])
                }
                c.resume(returning: String(decoding: out, as: UTF8.self))
            }
        }
    }
}

private let secret = String(repeating: "0a1b2c3d", count: 6)
private let initialize = #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18"}}"#

private func post(_ body: String, auth: String? = "Bearer " + secret, extra: [String] = [], close: Bool = false) -> String {
    var h = ["POST /mcp HTTP/1.1", "Host: 127.0.0.1", "Content-Type: application/json", "Content-Length: \(body.utf8.count)"]
    if let auth { h.append("Authorization: \(auth)") }
    if close { h.append("Connection: close") }
    return (h + extra).joined(separator: "\r\n") + "\r\n\r\n" + body
}

private func status(_ response: String) -> String { String(response.prefix { $0 != "\r" }) }

private func serve(_ limits: HTTPLimits = HTTPLimits()) async throws -> (MCPHTTPServer, UInt16) {
    let s = MCPServer(name: "t", version: "1", tools: [MCPTool(name: "echo", description: "echo", inputSchema: ["type": "object"]) { a in .json(a) }])
    let http = MCPHTTPServer(server: s, port: 0, token: secret, path: "/mcp", limits: limits)
    return (http, try await http.start())
}

@Suite(.serialized) struct HTTPServing {
    @Test func theBearerSchemeInAnyLetterCaseButOnlyTheRightToken() async throws {
        let (http, port) = try await serve()
        defer { http.stop() }
        for (auth, want) in [("Bearer " + secret, "200"), ("bearer " + secret, "200"), ("BEARER " + secret, "200"),
                             ("Bearer " + secret.uppercased(), "401"), ("Bearer " + secret + "x", "401"), ("Basic " + secret, "401"),
                             (secret, "401"), ("Bearer", "401"), (nil, "401")] {
            let c = try #require(Raw(port: port))
            await c.send(post(initialize, auth: auth, close: true))
            #expect(status(await c.response()).contains(want), "\(auth ?? "none")")
        }
    }

    @Test func aChunkOfInt64MaxIsAnErrorAndTheServerLivesOn() async throws {
        let (http, port) = try await serve()
        defer { http.stop() }
        let attack = "POST /mcp HTTP/1.1\r\nHost: 127.0.0.1\r\nTransfer-Encoding: chunked\r\n"
        // with the token (the body is read) and without (it never is): the old server trapped on the first, and parsed
        // the body of the second before it looked at the token
        for auth in ["Authorization: Bearer \(secret)\r\n", ""] {
            let c = try #require(Raw(port: port))
            await c.send(attack + auth + "\r\n1\r\nA\r\n7fffffffffffffff\r\n")
            let r = await c.response()
            #expect(status(r).contains(auth.isEmpty ? "401" : "413"), "\(status(r))")
        }
        let c = try #require(Raw(port: port))
        await c.send(post(initialize, close: true))
        #expect(status(await c.response()).contains("200"), "still answering")
    }

    @Test func aRequestThatIsNotAllowedGetsNoBodyRead() async throws {
        var limits = HTTPLimits()
        limits.body = 100
        let (http, port) = try await serve(limits)
        defer { http.stop() }
        // wrong token, and a body that is promised but never sent: the answer comes from the headers
        let c = try #require(Raw(port: port))
        await c.send("POST /mcp HTTP/1.1\r\nHost: 127.0.0.1\r\nAuthorization: Bearer wrong\r\nContent-Length: 90\r\n\r\n")
        let r = await c.response(seconds: 1)
        #expect(status(r).contains("401"), "\(r)")
        // wrong host, wrong origin, wrong path, wrong method: all before any body
        for (head, want) in [("Host: evil.example\r\nAuthorization: Bearer \(secret)", "403"), ("Host: 127.0.0.1\r\nOrigin: http://evil.example\r\nAuthorization: Bearer \(secret)", "403"),
                             ("Host: localhost.attacker.com\r\nAuthorization: Bearer \(secret)", "403")] {
            let d = try #require(Raw(port: port))
            await d.send("POST /mcp HTTP/1.1\r\n\(head)\r\nContent-Length: 90\r\n\r\n")
            #expect(status(await d.response(seconds: 1)).contains(want), "\(head)")
        }
        let e = try #require(Raw(port: port))
        await e.send("POST /elsewhere HTTP/1.1\r\nHost: 127.0.0.1\r\nAuthorization: Bearer \(secret)\r\nContent-Length: 90\r\n\r\n")
        #expect(status(await e.response(seconds: 1)).contains("404"))
        let f = try #require(Raw(port: port))
        await f.send("PUT /mcp HTTP/1.1\r\nHost: 127.0.0.1\r\nAuthorization: Bearer \(secret)\r\nContent-Length: 90\r\n\r\n")
        #expect(status(await f.response(seconds: 1)).contains("405"))
        // and a body over the cap is refused from its length
        let g = try #require(Raw(port: port))
        await g.send(post(String(repeating: " ", count: 150)))
        #expect(status(await g.response(seconds: 1)).contains("413"))
    }

    @Test func requestsKeepComingOnOneConnection() async throws {
        let (http, port) = try await serve()
        defer { http.stop() }
        let c = try #require(Raw(port: port))
        let ping = #"{"jsonrpc":"2.0","id":2,"method":"ping"}"#
        await c.send(post(initialize) + post(ping))   // two at once
        let a = await c.response(), b = await c.response()
        #expect(status(a).contains("200") && a.contains("protocolVersion") && a.lowercased().contains("mcp-session-id"))
        #expect(status(b).contains("200") && b.contains("\"id\":2"))
        await c.send(post(ping))
        #expect(status(await c.response()).contains("200"))
        // chunked, as some clients send
        let body = ping
        await c.send("POST /mcp HTTP/1.1\r\nHost: 127.0.0.1\r\nAuthorization: Bearer \(secret)\r\nTransfer-Encoding: chunked\r\n\r\n\(String(body.utf8.count, radix: 16))\r\n\(body)\r\n0\r\n\r\n")
        #expect(status(await c.response()).contains("200"))
    }

    @Test func connectionsAreCappedAndIdleOnesAreClosed() async throws {
        var limits = HTTPLimits()
        limits.connections = 3; limits.idle = 0.6; limits.request = 0.6
        let (http, port) = try await serve(limits)
        defer { http.stop() }
        let held = (0..<3).compactMap { _ in Raw(port: port) }
        #expect(held.count == 3)
        try await Task.sleep(for: .milliseconds(150))
        // full: the next one is turned away at once, with no say in what the others do
        let extra = try #require(Raw(port: port))
        let turned = await extra.read(seconds: 1)
        #expect(turned.closed && turned.data.isEmpty)
        // the idle ones are let go, and then there is room
        let gone = await held[0].read(seconds: 2)
        #expect(gone.closed, "idle connections are closed")
        try await Task.sleep(for: .milliseconds(200))
        let again = try #require(Raw(port: port))
        await again.send(post(initialize, close: true))
        #expect(status(await again.response()).contains("200"))
    }

    @Test func aRequestSentTooSlowlyIsDropped() async throws {
        var limits = HTTPLimits()
        limits.idle = 5; limits.request = 0.6
        let (http, port) = try await serve(limits)
        defer { http.stop() }
        let c = try #require(Raw(port: port))
        await c.send("POST /mcp HTTP/1.1\r\nHost: 127.0.0.1\r\n")   // the rest never comes (or a byte at a time)
        try await Task.sleep(for: .milliseconds(300))
        await c.send("X")
        let r = await c.read(seconds: 2)
        #expect(r.closed)
    }

    @Test func headersWithoutAnEndAreCutOff() async throws {
        let (http, port) = try await serve()
        defer { http.stop() }
        let c = try #require(Raw(port: port))
        await c.send("POST /mcp HTTP/1.1\r\nHost: 127.0.0.1\r\nX: " + String(repeating: "a", count: 200_000))
        let r = await c.read(seconds: 2)
        // the answer, or just the end of the connection (a server that closes on unread bytes may reset it before the answer is read)
        #expect(r.closed && (r.data.isEmpty || String(decoding: r.data, as: UTF8.self).contains("431")))
    }

    @Test(.timeLimit(.minutes(1))) func stoppingWhileStartingNeverLeavesTheCallerWaiting() async throws {
        for _ in 0..<20 {
            let s = MCPServer(name: "t", version: "1", tools: [])
            let http = MCPHTTPServer(server: s, port: 0, token: secret)
            async let started: Bool = {
                do { _ = try await http.start(); return true } catch { return false }   // listening, or told it was stopped
            }()
            http.stop()
            _ = await started   // it comes back either way
            http.stop()
        }
    }

    @Test func aStandardHTTPClientWorksWithIt() async throws {
        let (http, port) = try await serve()
        defer { http.stop() }
        let url = URL(string: "http://127.0.0.1:\(port)/mcp")!
        func call(_ body: Data, token: String = secret) async throws -> (Int, Data, [AnyHashable: Any]) {
            var r = URLRequest(url: url)
            r.httpMethod = "POST"
            r.httpBody = body
            r.setValue("application/json", forHTTPHeaderField: "Content-Type")
            r.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
            let (data, resp) = try await URLSession.shared.data(for: r)
            let h = resp as! HTTPURLResponse
            return (h.statusCode, data, h.allHeaderFields)
        }
        let (code, data, headers) = try await call(Data(initialize.utf8))
        #expect(code == 200 && headers["Mcp-Session-Id"] != nil && String(decoding: data, as: UTF8.self).contains("protocolVersion"))
        // a big body (2 MB), two on one connection, and a wrong token
        let big = #"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"echo","arguments":{"text":"\#(String(repeating: "x", count: 2_000_000))"}}}"#
        let (bigCode, bigData, _) = try await call(Data(big.utf8))
        #expect(bigCode == 200 && bigData.count > 2_000_000)
        let (wrong, _, _) = try await call(Data(initialize.utf8), token: "nope")
        #expect(wrong == 401)
    }

    @Test(.enabled(if: FileManager.default.isExecutableFile(atPath: "/usr/bin/curl"))) func curlWorksWithItEvenWhenItWaitsForContinue() async throws {
        let (http, port) = try await serve()
        defer { http.stop() }
        let file = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("curl-body-" + UUID().uuidString + ".json")
        try Data(#"{"jsonrpc":"2.0","id":4,"method":"ping"}"#.utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        func curl(_ extra: [String]) async -> (Int32, String) {
            await withCheckedContinuation { c in
                DispatchQueue.global().async {
                    let p = Process()
                    p.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
                    p.arguments = ["-sS", "--max-time", "10", "-w", " [%{http_code}]", "-H", "Authorization: Bearer " + secret,
                                   "-H", "Content-Type: application/json", "--data-binary", "@" + file.path] + extra + ["http://127.0.0.1:\(port)/mcp"]
                    let out = Pipe()
                    p.standardOutput = out; p.standardError = out
                    try? p.run()
                    let text = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                    p.waitUntilExit()
                    c.resume(returning: (p.terminationStatus, text))
                }
            }
        }
        for extra in [[], ["-H", "Expect: 100-continue"], ["-H", "Transfer-Encoding: chunked"], ["-H", "Transfer-Encoding: chunked", "-H", "Expect: 100-continue"], ["--http1.0"]] {
            let (status, text) = await curl(extra)
            #expect(status == 0 && text.hasSuffix("[200]") && text.contains("\"id\":4"), "\(extra): \(text)")
        }
    }
}

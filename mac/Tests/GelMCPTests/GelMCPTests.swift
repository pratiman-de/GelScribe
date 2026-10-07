import Foundation
import Testing
@testable import GelMCP

func server() -> MCPServer {
    MCPServer(name: "t", version: "1", instructions: "hi", tools: [
        MCPTool(name: "echo", description: "echo", inputSchema: ["type": "object"]) { a in .json(a) },
        MCPTool(name: "boom", description: "fails", inputSchema: ["type": "object"]) { _ in throw MCPToolError("nope") },
    ])
}

func call(_ s: MCPServer, _ json: String) async -> JSONValue? {
    guard let d = await s.handle(Data(json.utf8)) else { return nil }
    return try? JSONDecoder().decode(JSONValue.self, from: d)
}

@Suite struct Protocol {
    @Test func integersRoundTrip() throws {
        let v = try JSONDecoder().decode(JSONValue.self, from: Data(#"{"id":1,"x":2.5}"#.utf8))
        let s = String(decoding: try JSONEncoder().encode(v), as: UTF8.self)
        #expect(s.contains("\"id\":1") && !s.contains("1.0") && s.contains("2.5"))
    }

    @Test func initializeNegotiatesVersion() async {
        let s = server()
        let a = await call(s, #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18"}}"#)
        #expect(a?["result"]?["protocolVersion"]?.stringValue == "2025-06-18")
        let b = await call(s, #"{"jsonrpc":"2.0","id":"x","method":"initialize","params":{"protocolVersion":"1999-01-01"}}"#)
        #expect(b?["result"]?["protocolVersion"]?.stringValue == MCPServer.supportedVersions[0])
        #expect(b?["id"]?.stringValue == "x")
    }

    @Test func toolsAndErrors() async {
        let s = server()
        let list = await call(s, #"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#)
        #expect(list?["result"]?["tools"]?.arrayValue?.count == 2)
        let ok = await call(s, #"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"echo","arguments":{"a":1}}}"#)
        #expect(ok?["result"]?["isError"]?.boolValue == false)
        #expect(ok?["result"]?["structuredContent"]?["a"]?.intValue == 1)
        let bad = await call(s, #"{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"boom"}}"#)
        #expect(bad?["result"]?["isError"]?.boolValue == true)
        let unknown = await call(s, #"{"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"zzz"}}"#)
        #expect(unknown?["error"]?["code"]?.intValue == -32602)
        #expect(await call(s, #"{"jsonrpc":"2.0","id":6,"method":"nope"}"#)?["error"]?["code"]?.intValue == -32601)
        #expect(await call(s, "not json")?["error"]?["code"]?.intValue == -32700)
        #expect(await call(s, #"{"jsonrpc":"2.0","method":"notifications/initialized"}"#) == nil)
        let batch = await call(s, #"[{"jsonrpc":"2.0","id":7,"method":"ping"},{"jsonrpc":"2.0","method":"notifications/x"}]"#)
        #expect(batch?.arrayValue?.count == 1)
    }
}

@Suite struct Replies {
    @Test func aReplyThatCantBeWrittenIsAnErrorWithTheRequestsId() async {
        let s = MCPServer(name: "t", version: "1", instructions: nil, tools: [
            MCPTool(name: "inf", description: "x", inputSchema: ["type": "object"]) { _ in .json(["x": .number(.infinity)]) },
        ])
        let one = await call(s, #"{"jsonrpc":"2.0","id":41,"method":"tools/call","params":{"name":"inf"}}"#)
        #expect(one?["id"]?.intValue == 41 && one?["error"]?["code"]?.intValue == -32603, "\(String(describing: one))")   // not {}
        let batch = await call(s, #"[{"jsonrpc":"2.0","id":1,"method":"ping"},{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"inf"}}]"#)
        #expect(batch?.arrayValue?.count == 2 && batch?[0]?["result"] != nil && batch?[1]?["id"]?.intValue == 2 && batch?[1]?["error"] != nil)
    }
}

@Suite struct HTTPRules {
    @Test func loopbackHostsOnly() {
        for ok in ["127.0.0.1", "127.0.0.1:47860", "localhost:1", "[::1]:47860", "LOCALHOST"] { #expect(MCPHTTPServer.isLoopbackHost(ok), "\(ok)") }
        for bad in ["evil.example", "127.0.0.1.evil.example", "localhost:abc", "10.0.0.2:47860", "[::2]"] { #expect(!MCPHTTPServer.isLoopbackHost(bad), "\(bad)") }
    }

    @Test func loopbackOriginsOnly() {
        for ok in ["http://localhost:3000", "https://127.0.0.1", "http://[::1]:8080"] { #expect(MCPHTTPServer.isLoopbackOrigin(ok)) }
        for bad in ["null", "http://evil.example", "file://", "http://localhost.evil.example", "http://localhost:1/path"] {
            #expect(!MCPHTTPServer.isLoopbackOrigin(bad), "\(bad)")
        }
    }

    @Test func tokenComparison() {
        #expect(MCPHTTPServer.constantTimeEqual("Bearer abc", "Bearer abc"))
        #expect(!MCPHTTPServer.constantTimeEqual("Bearer abc", "Bearer abd"))
        #expect(!MCPHTTPServer.constantTimeEqual("Bearer ab", "Bearer abc"))
    }
}

@Suite struct StdioFraming {
    private func lines(_ bytes: [UInt8], max: Int = 1 << 20) -> [MCPLineSplitter.Output] {
        var s = MCPLineSplitter(maxLength: max)
        var out: [MCPLineSplitter.Output] = []
        for b in bytes { let o = s.add(b); if o != .pending { out.append(o) } }
        if let rest = s.finish() { out.append(.line(rest)) }
        return out
    }

    @Test func messagesSplitAtNewlineBytesOnly() {
        // JSON.stringify leaves U+2028, U+2029 and U+0085 as they are inside a string; they aren't ends of messages
        let msg = "{\"a\":\"x\u{2028}y\u{2029}z\u{85}w\"}"
        #expect(lines(Array((msg + "\n" + msg + "\r\n").utf8)) == [.line(Data(msg.utf8)), .line(Data(msg.utf8))])
        #expect(lines(Array("{\"a\":1}".utf8)) == [.line(Data("{\"a\":1}".utf8))], "a last message with no newline still counts")
        #expect(lines([]) == [])
    }

    @Test func aMessageTooLongIsSkippedToItsNewline() {
        let long = [UInt8](repeating: 0x61, count: 50)
        #expect(lines(long + [0x0A] + Array("ok\n".utf8), max: 10) == [.tooLong, .line(Data("ok".utf8))])
        #expect(lines(long, max: 10) == [], "cut off at the end of input: nothing to answer")
    }

    @Test func aMessageWithUnicodeLineSeparatorsGetsOneAnswer() async {
        let s = server()
        let msg = #"{"jsonrpc":"2.0","id":9,"method":"tools/call","params":{"name":"echo","arguments":{"text":"a\#u{2028}b\#u{2029}c\#u{85}d"}}}"#
        var replies: [Data] = []
        let input = AsyncStream<UInt8> { c in
            for b in Array((msg + "\n  \n\t\n" + #"{"jsonrpc":"2.0","id":10,"method":"ping"}"# + "\n").utf8) { c.yield(b) }
            c.finish()
        }
        await MCPStdio.run(s, input: input) { replies.append($0) }
        let decoded = replies.compactMap { try? JSONDecoder().decode(JSONValue.self, from: $0) }
        #expect(decoded.count == 2 && decoded[0]["id"]?.intValue == 9 && decoded[1]["id"]?.intValue == 10)
        #expect(decoded[0]["result"]?["structuredContent"]?["text"]?.stringValue == "a\u{2028}b\u{2029}c\u{85}d")
        #expect(replies.allSatisfy { $0.last == 0x0A && $0.dropLast().allSatisfy { $0 != 0x0A } })
    }
}

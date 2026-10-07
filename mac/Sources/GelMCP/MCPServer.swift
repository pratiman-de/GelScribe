import Foundation

// Model Context Protocol server core: JSON-RPC 2.0 message handling, tools only.
// Transport-agnostic; see MCPStdio and MCPHTTPServer.

public enum MCPContent: Sendable {
    case text(String)
    case image(Data, mimeType: String)

    var json: JSONValue {
        switch self {
        case .text(let s): return ["type": "text", "text": .string(s)]
        case .image(let d, let m): return ["type": "image", "data": .string(d.base64EncodedString()), "mimeType": .string(m)]
        }
    }
}

public struct MCPToolResult: Sendable {
    public var content: [MCPContent]
    public var structuredContent: JSONValue?
    public var isError: Bool
    public init(content: [MCPContent], structuredContent: JSONValue? = nil, isError: Bool = false) {
        self.content = content; self.structuredContent = structuredContent; self.isError = isError
    }
    public static func text(_ s: String) -> MCPToolResult { MCPToolResult(content: [.text(s)]) }
    /// Pretty JSON as text, plus the same value as structuredContent.
    public static func json(_ v: JSONValue) -> MCPToolResult {
        MCPToolResult(content: [.text(v.jsonString(pretty: true))], structuredContent: v.objectValue != nil ? v : ["result": v])
    }
}

/// Thrown by a handler to report a tool failure to the model (a result with isError, not a protocol error).
public struct MCPToolError: Error, Sendable, LocalizedError {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

public struct MCPToolAnnotations: Sendable {
    public var title: String?
    public var readOnlyHint: Bool?
    public var destructiveHint: Bool?
    public var idempotentHint: Bool?
    public var openWorldHint: Bool?
    public init(title: String? = nil, readOnlyHint: Bool? = nil, destructiveHint: Bool? = nil,
                idempotentHint: Bool? = nil, openWorldHint: Bool? = nil) {
        self.title = title; self.readOnlyHint = readOnlyHint; self.destructiveHint = destructiveHint
        self.idempotentHint = idempotentHint; self.openWorldHint = openWorldHint
    }
    var json: JSONValue {
        var o: [String: JSONValue] = [:]
        if let title { o["title"] = .string(title) }
        if let readOnlyHint { o["readOnlyHint"] = .bool(readOnlyHint) }
        if let destructiveHint { o["destructiveHint"] = .bool(destructiveHint) }
        if let idempotentHint { o["idempotentHint"] = .bool(idempotentHint) }
        if let openWorldHint { o["openWorldHint"] = .bool(openWorldHint) }
        return .object(o)
    }
}

public struct MCPTool: Sendable {
    public let name: String
    public let title: String?
    public let description: String
    public let inputSchema: JSONValue
    public let annotations: MCPToolAnnotations?
    public let handler: @Sendable (JSONValue) async throws -> MCPToolResult

    public init(name: String, title: String? = nil, description: String, inputSchema: JSONValue,
                annotations: MCPToolAnnotations? = nil,
                handler: @escaping @Sendable (JSONValue) async throws -> MCPToolResult) {
        self.name = name; self.title = title; self.description = description; self.inputSchema = inputSchema
        self.annotations = annotations; self.handler = handler
    }

    var listing: JSONValue {
        var o: [String: JSONValue] = ["name": .string(name), "description": .string(description), "inputSchema": inputSchema]
        if let title { o["title"] = .string(title) }
        if let annotations { o["annotations"] = annotations.json }
        return .object(o)
    }
}

public actor MCPServer {
    public static let supportedVersions = ["2025-11-25", "2025-06-18", "2025-03-26", "2024-11-05"]

    let name: String
    let version: String
    let instructions: String?
    private var tools: [String: MCPTool] = [:]
    private var order: [String] = []

    public init(name: String, version: String, instructions: String? = nil, tools: [MCPTool]) {
        self.name = name
        self.version = version
        self.instructions = instructions
        for t in tools { self.tools[t.name] = t; order.append(t.name) }
    }

    public func setTools(_ list: [MCPTool]) {
        tools = [:]; order = []
        for t in list { tools[t.name] = t; order.append(t.name) }
    }

    /// One JSON-RPC message or a batch. Nil when nothing is owed (notifications, responses).
    public func handle(_ message: Data) async -> Data? {
        guard let msg = try? JSONDecoder().decode(JSONValue.self, from: message) else {
            return encode(errorResponse(id: .null, code: -32700, message: "Parse error"))
        }
        if case .array(let batch) = msg {
            if batch.isEmpty { return encode(errorResponse(id: .null, code: -32600, message: "Invalid Request: empty batch")) }
            var out: [JSONValue] = []
            for m in batch { if let r = await handleOne(m) { out.append(r) } }
            return out.isEmpty ? nil : encode(.array(out))
        }
        return await handleOne(msg).map(encode)
    }

    private func handleOne(_ msg: JSONValue) async -> JSONValue? {
        guard case .object(let o) = msg else { return errorResponse(id: .null, code: -32600, message: "Invalid Request") }
        let id = o["id"]
        guard let method = o["method"]?.stringValue else {
            // a response from the client (we never send requests) or garbage
            if o["result"] != nil || o["error"] != nil { return nil }
            return errorResponse(id: id ?? .null, code: -32600, message: "Invalid Request")
        }
        guard let id, !id.isNull else { return nil }   // notification: never answered
        switch id {
        case .number, .string: break
        default: return errorResponse(id: .null, code: -32600, message: "Invalid Request: id must be a string or number")
        }
        let params = o["params"] ?? [:]
        switch method {
        case "initialize":
            let asked = params["protocolVersion"]?.stringValue
            let v = asked.flatMap { Self.supportedVersions.contains($0) ? $0 : nil } ?? Self.supportedVersions[0]
            var result: [String: JSONValue] = [
                "protocolVersion": .string(v),
                "capabilities": ["tools": ["listChanged": false]],
                "serverInfo": ["name": .string(name), "version": .string(version)],
            ]
            if let instructions { result["instructions"] = .string(instructions) }
            return success(id: id, result: .object(result))
        case "ping":
            return success(id: id, result: [:])
        case "tools/list":
            return success(id: id, result: ["tools": .array(order.compactMap { tools[$0]?.listing })])
        case "tools/call":
            guard let name = params["name"]?.stringValue else {
                return errorResponse(id: id, code: -32602, message: "Invalid params: missing tool name")
            }
            guard let tool = tools[name] else { return errorResponse(id: id, code: -32602, message: "Unknown tool: \(name)") }
            var args = params["arguments"] ?? [:]
            if args.objectValue == nil { args = [:] }
            let result: MCPToolResult
            do { result = try await tool.handler(args) }
            catch let e as MCPToolError { result = MCPToolResult(content: [.text(e.message)], isError: true) }
            catch { result = MCPToolResult(content: [.text(error.localizedDescription)], isError: true) }
            var r: [String: JSONValue] = ["content": .array(result.content.map(\.json)), "isError": .bool(result.isError)]
            if let s = result.structuredContent { r["structuredContent"] = s }
            return success(id: id, result: .object(r))
        default:
            return errorResponse(id: id, code: -32601, message: "Method not found: \(method)")
        }
    }

    private func success(id: JSONValue, result: JSONValue) -> JSONValue {
        ["jsonrpc": "2.0", "id": id, "result": result]
    }

    private func errorResponse(id: JSONValue, code: Int, message: String) -> JSONValue {
        ["jsonrpc": "2.0", "id": id, "error": ["code": .number(Double(code)), "message": .string(message)]]
    }

    private static func write(_ v: JSONValue) -> Data? {
        let e = JSONEncoder()
        e.outputFormatting = [.withoutEscapingSlashes]
        return try? e.encode(v)
    }

    /// A reply as JSON. One that can't be written (a number that isn't finite somewhere in a result) goes out as an error
    /// reply with the same id, never as an empty object the client can't match to its request.
    private func encode(_ v: JSONValue) -> Data {
        if let d = Self.write(v) { return d }
        if case .array(let batch) = v { return encode(.array(batch.map(writable))) }
        return Self.write(writable(v)) ?? Data(#"{"jsonrpc":"2.0","id":null,"error":{"code":-32603,"message":"Internal error"}}"#.utf8)
    }

    private func writable(_ reply: JSONValue) -> JSONValue {
        Self.write(reply) != nil ? reply
            : errorResponse(id: reply["id"] ?? .null, code: -32603, message: "Internal error: the reply could not be written.")
    }

    /// Whether a message is an `initialize` request (the HTTP transport issues a session id for it).
    public static func isInitialize(_ data: Data) -> Bool {
        guard let v = try? JSONDecoder().decode(JSONValue.self, from: data) else { return false }
        return v["method"]?.stringValue == "initialize"
    }
}

/// Cuts a byte stream into messages at newline bytes, and only there. (`AsyncBytes.lines` also splits at U+2028, U+2029 and
/// U+0085, which `JSON.stringify` writes as they are inside a string, so one valid message arrived as two broken halves.)
public struct MCPLineSplitter {
    public enum Output: Equatable {
        case pending
        /// A message, without its newline (or the CR before it).
        case line(Data)
        /// A message longer than `maxLength`: skipped up to its newline.
        case tooLong
    }

    public let maxLength: Int
    private var bytes: [UInt8] = []
    private var skipping = false

    public init(maxLength: Int = 16 << 20) { self.maxLength = maxLength }

    public mutating func add(_ byte: UInt8) -> Output {
        if byte == 0x0A {
            defer { bytes.removeAll(keepingCapacity: true); skipping = false }
            if skipping { return .tooLong }
            if bytes.last == 0x0D { bytes.removeLast() }
            return .line(Data(bytes))
        }
        if skipping { return .pending }
        if bytes.count >= maxLength { bytes.removeAll(keepingCapacity: false); skipping = true; return .pending }
        bytes.append(byte)
        return .pending
    }

    /// What's left when the stream ends without a final newline.
    public mutating func finish() -> Data? {
        defer { bytes.removeAll(); skipping = false }
        return bytes.isEmpty || skipping ? nil : Data(bytes)
    }
}

/// Newline-delimited JSON-RPC over stdin/stdout. Only protocol messages go to stdout.
public enum MCPStdio {
    public static func run(_ server: MCPServer) async {
        let out = FileHandle.standardOutput
        await run(server, input: FileHandle.standardInput.bytes) { try out.write(contentsOf: $0) }
    }

    /// Answers each message of `input` in turn until it ends, giving every reply (with its newline) to `write`.
    static func run<Input: AsyncSequence>(_ server: MCPServer, input: Input, write: (Data) throws -> Void) async where Input.Element == UInt8 {
        var splitter = MCPLineSplitter()
        func answer(_ message: Data) async throws {
            var lo = message.startIndex, hi = message.endIndex   // spaces and tabs around a message don't count
            while lo < hi, message[lo] == 0x20 || message[lo] == 0x09 { lo += 1 }
            while hi > lo, message[hi - 1] == 0x20 || message[hi - 1] == 0x09 { hi -= 1 }
            let trimmed = Data(message[lo..<hi])
            guard !trimmed.isEmpty else { return }
            if var reply = await server.handle(trimmed) {
                reply.append(0x0A)
                try write(reply)
            }
        }
        do {
            for try await byte in input {
                switch splitter.add(byte) {
                case .pending: continue
                case .line(let message): try await answer(message)
                case .tooLong:
                    try write(Data((#"{"jsonrpc":"2.0","id":null,"error":{"code":-32600,"message":"Message too large"}}"# + "\n").utf8))
                }
            }
            if let last = splitter.finish() { try await answer(last) }
        } catch {
            FileHandle.standardError.write(Data("mcp stdio: \(error.localizedDescription)\n".utf8))
        }
    }
}

import Foundation

/// A tool the MCP server offers to AI clients.
struct MCPTool: Sendable {
    let name: String
    let title: String
    let description: String
    /// JSON Schema of the `arguments` object.
    let inputSchema: JSONValue

    var json: JSONValue {
        [
            "name": .string(name),
            "title": .string(title),
            "description": .string(description),
            "inputSchema": inputSchema,
            // Every v1 tool only reads.
            "annotations": ["readOnlyHint": true, "destructiveHint": false, "openWorldHint": false],
        ]
    }
}

/// What a tool call produced. Tool failures are reported in the result (with
/// `isError`) rather than as JSON-RPC errors, so the model can read them and
/// correct itself.
struct MCPToolResult: Sendable, Equatable {
    var text: String
    var isError: Bool = false

    static func error(_ message: String) -> MCPToolResult {
        MCPToolResult(text: message, isError: true)
    }
}

/// The client that opened the session, from its `initialize` request.
struct MCPClientInfo: Sendable, Equatable {
    var name: String
    var version: String
}

/// Lists and runs the server's tools. Implemented by `MCPToolbox`; tests
/// substitute their own.
protocol MCPToolHandling: Sendable {
    var tools: [MCPTool] { get }
    func callTool(_ name: String, arguments: [String: JSONValue], client: MCPClientInfo?) async -> MCPToolResult
}

/// Protocol constants shared by the server and the stdio bridge.
enum MCPProtocol {
    /// Protocol revisions this server implements, newest first.
    static let supportedVersions = ["2025-11-25", "2025-06-18", "2025-03-26", "2024-11-05"]

    /// The revision to answer `initialize` with: the client's when we
    /// support it, otherwise our newest (the client then decides whether to
    /// continue).
    static func negotiate(_ requested: String?) -> String {
        if let requested, supportedVersions.contains(requested) {
            return requested
        }
        return supportedVersions[0]
    }

    enum ErrorCode {
        static let parseError = -32700
        static let invalidRequest = -32600
        static let methodNotFound = -32601
        static let invalidParams = -32602
        static let internalError = -32603
        /// Server-defined: SequelPG is not running or its MCP server is off.
        static let serverUnavailable = -32000
    }

    static func errorResponse(id: JSONValue, code: Int, message: String) -> JSONValue {
        ["jsonrpc": "2.0", "id": id, "error": ["code": .int(code), "message": .string(message)]]
    }

    static var serverVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"
    }
}

/// One MCP client connection: decodes JSON-RPC messages, answers the
/// lifecycle methods, and runs tool calls concurrently. Each request runs in
/// its own task so `notifications/cancelled` can stop a long query.
actor MCPSession {
    typealias Sender = @Sendable (Data) async -> Void

    private let handler: MCPToolHandling
    private let send: Sender
    private(set) var client: MCPClientInfo?
    private var inFlight: [JSONValue: Task<Void, Never>] = [:]

    init(handler: MCPToolHandling, send: @escaping Sender) {
        self.handler = handler
        self.send = send
    }

    static let instructions = """
    SequelPG exposes the user's saved PostgreSQL connections. Call list_connections first and pass a \
    connection's id to the other tools. Queries run in read-only transactions with a row limit.
    """

    /// Handles one line of input. Returns once the message is dispatched —
    /// tool calls finish (and reply) in the background.
    func receive(_ line: Data) async {
        let message: JSONValue
        do {
            message = try JSONDecoder().decode(JSONValue.self, from: line)
        } catch {
            await send(MCPProtocol.errorResponse(
                id: .null,
                code: MCPProtocol.ErrorCode.parseError,
                message: "Parse error"
            ).encodedLine())
            return
        }
        guard case let .object(fields) = message, let method = fields["method"]?.stringValue else {
            // Responses to server-initiated requests (we send none) and
            // batches (removed from the protocol) are not supported.
            let isResponse = message["method"] == nil && (message["result"] != nil || message["error"] != nil)
            if isResponse {
                return
            }
            await send(MCPProtocol.errorResponse(
                id: message["id"] ?? .null,
                code: MCPProtocol.ErrorCode.invalidRequest,
                message: "Invalid request"
            ).encodedLine())
            return
        }
        let params = fields["params"]?.objectValue ?? [:]

        guard let id = fields["id"], !id.isNull else {
            handleNotification(method, params: params)
            return
        }

        switch method {
        case "initialize":
            await reply(id: id, result: initialize(params))
        case "ping":
            await reply(id: id, result: [:])
        case "tools/list":
            await reply(id: id, result: ["tools": .array(handler.tools.map(\.json))])
        case "tools/call":
            await startToolCall(id: id, params: params)
        default:
            await send(MCPProtocol.errorResponse(
                id: id,
                code: MCPProtocol.ErrorCode.methodNotFound,
                message: "Method not found: \(method)"
            ).encodedLine())
        }
    }

    /// Waits for running tool calls to reply (the client sent its last
    /// request and half-closed the connection).
    func drain() async {
        while let task = inFlight.values.first {
            await task.value
            // A finished task removes itself; a cancelled one may not have.
            if let entry = inFlight.first(where: { $0.value == task }) {
                inFlight.removeValue(forKey: entry.key)
            }
        }
    }

    /// Cancels every running tool call (the server is stopping).
    func close() {
        for task in inFlight.values {
            task.cancel()
        }
        inFlight.removeAll()
    }

    // MARK: - Private

    private func handleNotification(_ method: String, params: [String: JSONValue]) {
        switch method {
        case "notifications/cancelled":
            if let requestID = params["requestId"], let task = inFlight.removeValue(forKey: requestID) {
                task.cancel()
            }
        default:
            // notifications/initialized and anything else need no action.
            break
        }
    }

    private func initialize(_ params: [String: JSONValue]) -> JSONValue {
        if let info = params["clientInfo"] {
            client = MCPClientInfo(
                name: info["name"]?.stringValue ?? "unknown",
                version: info["version"]?.stringValue ?? ""
            )
        }
        return [
            "protocolVersion": .string(MCPProtocol.negotiate(params["protocolVersion"]?.stringValue)),
            "capabilities": ["tools": ["listChanged": false]],
            "serverInfo": ["name": "SequelPG", "title": "SequelPG", "version": .string(MCPProtocol.serverVersion)],
            "instructions": .string(Self.instructions),
        ]
    }

    private func startToolCall(id: JSONValue, params: [String: JSONValue]) async {
        guard inFlight[id] == nil else {
            await send(MCPProtocol.errorResponse(
                id: id,
                code: MCPProtocol.ErrorCode.invalidRequest,
                message: "Request id is already in use"
            ).encodedLine())
            return
        }
        guard let name = params["name"]?.stringValue else {
            await send(MCPProtocol.errorResponse(
                id: id,
                code: MCPProtocol.ErrorCode.invalidParams,
                message: "Missing tool name"
            ).encodedLine())
            return
        }
        guard handler.tools.contains(where: { $0.name == name }) else {
            await send(MCPProtocol.errorResponse(
                id: id,
                code: MCPProtocol.ErrorCode.invalidParams,
                message: "Unknown tool: \(name)"
            ).encodedLine())
            return
        }
        let arguments = params["arguments"]?.objectValue ?? [:]
        let handler = handler
        let client = client
        inFlight[id] = Task {
            let result = await handler.callTool(name, arguments: arguments, client: client)
            // A cancelled request gets no response (the client stopped waiting).
            guard !Task.isCancelled else { return }
            await self.finish(id: id, result: [
                "content": [["type": "text", "text": .string(result.text)]],
                "isError": .bool(result.isError),
            ])
        }
    }

    private func finish(id: JSONValue, result: JSONValue) async {
        guard inFlight.removeValue(forKey: id) != nil else { return }
        await reply(id: id, result: result)
    }

    private func reply(id: JSONValue, result: JSONValue) async {
        await send(JSONValue.object(["jsonrpc": "2.0", "id": id, "result": result]).encodedLine())
    }
}

extension JSONValue: Hashable {
    func hash(into hasher: inout Hasher) {
        switch self {
        case .null: hasher.combine(0)
        case let .bool(value): hasher.combine(value)
        case let .int(value): hasher.combine(value)
        case let .double(value): hasher.combine(value)
        case let .string(value): hasher.combine(value)
        case let .array(value): hasher.combine(value)
        case let .object(value): hasher.combine(value)
        }
    }
}

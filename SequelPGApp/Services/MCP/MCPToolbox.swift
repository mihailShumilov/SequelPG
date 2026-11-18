import Foundation

/// The tools SequelPG offers over MCP.
struct MCPToolbox: MCPToolHandling {
    let store: ConnectionStoreProtocol

    var tools: [MCPTool] {
        [Self.listConnections]
    }

    func callTool(_ name: String, arguments _: [String: JSONValue], client _: MCPClientInfo?) async -> MCPToolResult {
        switch name {
        case Self.listConnections.name:
            return listConnections()
        default:
            return .error("Unknown tool: \(name)")
        }
    }

    // MARK: - list_connections

    static let listConnections = MCPTool(
        name: "list_connections",
        title: "List connections",
        description: "Lists the PostgreSQL connections saved in SequelPG. Pass a connection's id to the other tools.",
        inputSchema: ["type": "object", "properties": [:], "additionalProperties": false]
    )

    private func listConnections() -> MCPToolResult {
        let profiles = store.loadAll()
        guard !profiles.isEmpty else {
            return MCPToolResult(text: "No connections are saved in SequelPG.")
        }
        let rows = profiles.map { profile -> JSONValue in
            [
                "id": .string(profile.id.uuidString),
                "name": .string(profile.displayName),
                "host": .string(profile.host),
                "port": .int(profile.port),
                "database": .string(profile.database),
                "user": .string(profile.username),
                "ssh_tunnel": .bool(profile.useSSHTunnel),
            ]
        }
        return MCPToolResult(text: JSONValue.array(rows).encodedString)
    }
}

import Foundation

/// The tools SequelPG offers over MCP. Every tool only reads, and only
/// connections whose MCP access is turned on are visible.
struct MCPToolbox: MCPToolHandling {
    let store: ConnectionStoreProtocol
    /// Which connections are shared: the Keychain copy, not the profile's
    /// `mcpAccess` mirror in UserDefaults.
    let authorization: MCPAuthorizationStore
    let pool: MCPSessionPool
    /// Server-side `statement_timeout` for run_query / explain_query.
    var queryTimeout: TimeInterval = 30
    /// Asks the user, once per client, whether it may use the tools.
    var authorize: @Sendable (MCPClientInfo?) async -> Bool = { _ in true }

    /// Tool calls running at once, across all clients; the rest wait.
    static let maxConcurrentCalls = 4
    private let limiter = AsyncLimiter(limit: MCPToolbox.maxConcurrentCalls)

    static let defaultMaxRows = 200
    static let maxRowsLimit = 1000

    var tools: [MCPTool] {
        [
            Self.listConnections, Self.listDatabases, Self.listSchemas, Self.listObjects,
            Self.describeTable, Self.getDDL, Self.runQuery, Self.explainQuery,
        ]
    }

    func callTool(_ name: String, arguments: [String: JSONValue], client: MCPClientInfo?) async -> MCPToolResult {
        // Bounds the connections an assistant firing calls in parallel can open.
        await limiter.acquire()
        defer { Task { await limiter.release() } }
        guard await authorize(client) else {
            return .error(
                "The user did not allow \(MCPServerController.normalizedName(client)) to use SequelPG. "
                    + "It will be asked again after SequelPG restarts."
            )
        }
        do {
            let args = Arguments(values: arguments)
            switch name {
            case Self.listConnections.name: return listConnectionsResult()
            case Self.listDatabases.name: return try await listDatabases(args)
            case Self.listSchemas.name: return try await listSchemas(args)
            case Self.listObjects.name: return try await listObjects(args)
            case Self.describeTable.name: return try await describeTable(args)
            case Self.getDDL.name: return try await getDDL(args)
            case Self.runQuery.name: return try await runQuery(args)
            case Self.explainQuery.name: return try await explainQuery(args)
            default: return .error("Unknown tool: \(name)")
            }
        } catch is CancellationError {
            return .error("Cancelled.")
        } catch {
            return .error(error.localizedDescription)
        }
    }

    // MARK: - Tool definitions

    private static let connectionProperty: JSONValue = [
        "type": "string",
        "description": "Connection id (or exact name) from list_connections.",
    ]
    private static let databaseProperty: JSONValue = [
        "type": "string",
        "description": "Database to use instead of the connection's default (see list_databases).",
    ]
    private static let schemaProperty: JSONValue = ["type": "string", "description": "Schema name, e.g. public."]

    private static func schema(_ properties: [String: JSONValue], required: [String]) -> JSONValue {
        [
            "type": "object",
            "properties": .object(properties),
            "required": .array(required.map { .string($0) }),
            "additionalProperties": false,
        ]
    }

    static let listConnections = MCPTool(
        name: "list_connections",
        title: "List connections",
        description: "Lists the PostgreSQL connections the user shared with MCP in SequelPG. "
            + "Pass a connection's id to the other tools.",
        inputSchema: schema([:], required: [])
    )

    static let listDatabases = MCPTool(
        name: "list_databases",
        title: "List databases",
        description: "Lists the databases on a connection's server.",
        inputSchema: schema(["connection": connectionProperty], required: ["connection"])
    )

    static let listSchemas = MCPTool(
        name: "list_schemas",
        title: "List schemas",
        description: "Lists the schemas in a database.",
        inputSchema: schema(
            ["connection": connectionProperty, "database": databaseProperty],
            required: ["connection"]
        )
    )

    static let listObjects = MCPTool(
        name: "list_objects",
        title: "List schema objects",
        description: "Lists the tables, views, materialized views, functions, sequences, types and other "
            + "objects in a schema.",
        inputSchema: schema(
            ["connection": connectionProperty, "database": databaseProperty, "schema": schemaProperty],
            required: ["connection", "schema"]
        )
    )

    static let describeTable = MCPTool(
        name: "describe_table",
        title: "Describe table",
        description: "Shows a table's or view's columns (types, nullability, defaults, primary key), indexes, "
            + "constraints including foreign keys, triggers and approximate row count.",
        inputSchema: schema(
            [
                "connection": connectionProperty, "database": databaseProperty, "schema": schemaProperty,
                "table": ["type": "string", "description": "Table or view name."],
            ],
            required: ["connection", "schema", "table"]
        )
    )

    static let ddlTypes: [DBObjectType] = [
        .table, .view, .materializedView, .function, .procedure, .triggerFunction, .aggregate, .sequence,
        .type, .domain, .foreignTable,
    ]

    static let getDDL = MCPTool(
        name: "get_ddl",
        title: "Get object DDL",
        description: "Returns the CREATE statement for a table, view, function or other object. "
            + "Functions are named with their argument types as listed by list_objects.",
        inputSchema: schema(
            [
                "connection": connectionProperty, "database": databaseProperty, "schema": schemaProperty,
                "name": ["type": "string", "description": "Object name."],
                "type": [
                    "type": "string",
                    "enum": .array(ddlTypes.map { .string($0.rawValue) }),
                    "description": "Object type. Defaults to table.",
                ],
            ],
            required: ["connection", "schema", "name"]
        )
    )

    static let runQuery = MCPTool(
        name: "run_query",
        title: "Run read-only query",
        description: "Runs one SQL statement in a read-only transaction that is always rolled back, and returns "
            + "the rows as a pipe-separated table. Writes, DDL, COPY, transaction control and multiple "
            + "statements are rejected. Use LIMIT for large tables.",
        inputSchema: schema(
            [
                "connection": connectionProperty, "database": databaseProperty,
                "sql": ["type": "string", "description": "A single SQL statement, e.g. a SELECT."],
                "max_rows": [
                    "type": "integer", "minimum": 1, "maximum": .int(maxRowsLimit),
                    "description": .string("Rows to return (default \(defaultMaxRows), max \(maxRowsLimit))."),
                ],
            ],
            required: ["connection", "sql"]
        )
    )

    static let explainQuery = MCPTool(
        name: "explain_query",
        title: "Explain query",
        description: "Shows PostgreSQL's execution plan for one statement. With analyze=true the statement "
            + "is executed (in a read-only transaction) to report actual timings.",
        inputSchema: schema(
            [
                "connection": connectionProperty, "database": databaseProperty,
                "sql": ["type": "string", "description": "The statement to explain."],
                "analyze": ["type": "boolean", "description": "Run the statement for actual timings. Default false."],
            ],
            required: ["connection", "sql"]
        )
    )

    // MARK: - Implementations

    /// Profiles MCP clients may use.
    private func sharedProfiles() -> [ConnectionProfile] {
        let shared = authorization.load()
        return store.loadAll().compactMap { profile in
            var profile = profile
            profile.mcpAccess = shared.access(for: profile.id)
            return profile.mcpAccess == .off ? nil : profile
        }
    }

    private func listConnectionsResult() -> MCPToolResult {
        let profiles = sharedProfiles()
        guard !profiles.isEmpty else {
            return MCPToolResult(text: """
            No connections are shared with MCP. In SequelPG, edit a connection and set \
            "MCP access" to Read-only.
            """)
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
                "access": .string(profile.mcpAccess.rawValue),
            ]
        }
        return MCPToolResult(text: JSONValue.array(rows).encodedString)
    }

    private func session(_ args: Arguments) async throws -> any PostgresClientProtocol {
        let reference = try args.requiredString("connection")
        let profiles = sharedProfiles()
        let profile = profiles.first { $0.id.uuidString.caseInsensitiveCompare(reference) == .orderedSame }
            ?? profiles.first { $0.displayName == reference }
        guard let profile else {
            throw ToolError("Unknown connection \"\(reference)\". Call list_connections for the available ids.")
        }
        return try await pool.client(for: profile, database: args.string("database"))
    }

    private func listDatabases(_ args: Arguments) async throws -> MCPToolResult {
        let databases = try await session(args).listDatabases()
        return MCPToolResult(text: databases.joined(separator: "\n"))
    }

    private func listSchemas(_ args: Arguments) async throws -> MCPToolResult {
        let schemas = try await session(args).listSchemas()
        return MCPToolResult(text: schemas.joined(separator: "\n"))
    }

    private func listObjects(_ args: Arguments) async throws -> MCPToolResult {
        let schema = try args.requiredString("schema")
        let objects = try await session(args).listAllSchemaObjects(schema: schema)
        let groups: [(String, [DBObject])] = [
            ("tables", objects.tables), ("views", objects.views),
            ("materialized views", objects.materializedViews), ("foreign tables", objects.foreignTables),
            ("functions", objects.functions), ("procedures", objects.procedures),
            ("trigger functions", objects.triggerFunctions), ("aggregates", objects.aggregates),
            ("sequences", objects.sequences), ("types", objects.types), ("domains", objects.domains),
        ]
        let lines = groups.filter { !$0.1.isEmpty }.map { label, items in
            "\(label): " + items.map(\.name).joined(separator: ", ")
        }
        return MCPToolResult(text: MCPResultFormatter.capped(
            lines.isEmpty ? "Schema \(schema) has no objects (or does not exist)." : lines.joined(separator: "\n")
        ))
    }

    private func describeTable(_ args: Arguments) async throws -> MCPToolResult {
        let schema = try args.requiredString("schema")
        let table = try args.requiredString("table")
        let client = try await session(args)
        let columns = try await client.getColumns(schema: schema, table: table)
        guard !columns.isEmpty else {
            throw ToolError("\(schema).\(table) was not found. Use list_objects to see the schema's tables.")
        }
        let indexes = try await client.listIndexes(schema: schema, table: table)
        let constraints = try await client.listConstraints(schema: schema, table: table)
        let triggers = try await client.listTriggers(schema: schema, table: table)
        // The planner's estimate only. `getApproximateRowCount` falls back
        // to COUNT(*) outside a read-only transaction, which would run a
        // view's functions read-write and scan without a time limit.
        let estimate = try? await client.runReadOnlyQuery(
            "SELECT c.reltuples::bigint AS n FROM pg_catalog.pg_class c "
                + "JOIN pg_catalog.pg_namespace s ON s.oid = c.relnamespace "
                + "WHERE s.nspname = \(quoteLiteral(.text(schema))) AND c.relname = \(quoteLiteral(.text(table)))",
            maxRows: 1, timeout: 5
        )
        var rowCount: Int64?
        if case let .text(value)? = estimate?.rows.first?.first {
            rowCount = Int64(value)
        }

        var lines = ["\(schema).\(table)" + (rowCount.map { $0 >= 0 ? " (~\($0) rows)" : "" } ?? "")]
        lines.append("Columns:")
        for column in columns.sorted(by: { $0.ordinalPosition < $1.ordinalPosition }) {
            var line = "- \(column.name) \(column.udtName.flatMap { $0.isEmpty ? nil : $0 } ?? column.dataType)"
            if !column.isNullable {
                line += " NOT NULL"
            }
            if let generation = column.identityGeneration, column.isIdentity {
                line += " GENERATED \(generation) AS IDENTITY"
            } else if let defaultValue = column.columnDefault {
                line += " DEFAULT \(defaultValue)"
            }
            if column.isPrimaryKey {
                line += " [PK]"
            }
            lines.append(line)
        }
        if !indexes.isEmpty {
            lines.append("Indexes:")
            for index in indexes {
                var flags: [String] = []
                if index.isPrimary {
                    flags.append("primary")
                } else if index.isUnique {
                    flags.append("unique")
                }
                if index.isPartial {
                    flags.append("partial")
                }
                let suffix = flags.isEmpty ? "" : " " + flags.joined(separator: ", ")
                lines.append("- \(index.name): \(index.method) (\(index.columns.joined(separator: ", ")))\(suffix)")
            }
        }
        if !constraints.isEmpty {
            lines.append("Constraints:")
            for constraint in constraints {
                lines.append("- \(constraint.name): \(constraint.definition)")
            }
        }
        if !triggers.isEmpty {
            lines.append("Triggers:")
            for trigger in triggers {
                let state = trigger.isDisabled ? " (disabled)" : ""
                lines.append("- \(trigger.name)\(state): \(trigger.actionStatement)")
            }
        }
        return MCPToolResult(text: MCPResultFormatter.capped(lines.joined(separator: "\n")))
    }

    private func getDDL(_ args: Arguments) async throws -> MCPToolResult {
        let schema = try args.requiredString("schema")
        let name = try args.requiredString("name")
        let typeName = args.string("type") ?? DBObjectType.table.rawValue
        guard let type = DBObjectType(rawValue: typeName), Self.ddlTypes.contains(type) else {
            throw ToolError("Unsupported type \"\(typeName)\".")
        }
        let ddl = try await session(args).getObjectDDL(schema: schema, name: name, type: type)
        return MCPToolResult(text: MCPResultFormatter.capped(ddl))
    }

    private func runQuery(_ args: Arguments) async throws -> MCPToolResult {
        let sql = try args.requiredString("sql")
        let maxRows = min(max(args.int("max_rows") ?? Self.defaultMaxRows, 1), Self.maxRowsLimit)
        // Validate before connecting, so a rejected statement costs nothing.
        _ = try ReadOnlySQLGuard.validate(sql)
        let result = try await session(args).runReadOnlyQuery(sql, maxRows: maxRows, timeout: queryTimeout)
        return MCPToolResult(text: MCPResultFormatter.format(result, maxRowsRequested: maxRows))
    }

    private func explainQuery(_ args: Arguments) async throws -> MCPToolResult {
        let statement = try ReadOnlySQLGuard.validate(args.requiredString("sql"))
        let analyze = args.bool("analyze") ?? false
        let sql = "EXPLAIN (ANALYZE \(analyze), FORMAT TEXT) \(statement)"
        let result = try await session(args).runReadOnlyQuery(sql, maxRows: 10000, timeout: queryTimeout)
        let plan = result.rows.compactMap { row -> String? in
            guard case let .text(line)? = row.first else { return nil }
            return line
        }
        return MCPToolResult(text: MCPResultFormatter.capped(plan.joined(separator: "\n")))
    }
}

// MARK: - Arguments

/// Typed access to a tool call's `arguments`.
private struct Arguments {
    let values: [String: JSONValue]

    func string(_ key: String) -> String? {
        guard let value = values[key]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty
        else { return nil }
        return value
    }

    func requiredString(_ key: String) throws -> String {
        guard let value = string(key) else { throw ToolError("Missing required argument \"\(key)\".") }
        return value
    }

    func int(_ key: String) -> Int? {
        values[key]?.intValue ?? values[key]?.stringValue.flatMap { Int($0) }
    }

    func bool(_ key: String) -> Bool? {
        values[key]?.boolValue ?? values[key]?.stringValue.flatMap { Bool($0.lowercased()) }
    }
}

/// A FIFO counting semaphore for async code.
actor AsyncLimiter {
    private let limit: Int
    private var running = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(limit: Int) {
        self.limit = limit
    }

    func acquire() async {
        if running < limit {
            running += 1
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }

    func release() {
        if waiters.isEmpty {
            running -= 1
        } else {
            // The slot passes straight to the next waiter.
            waiters.removeFirst().resume()
        }
    }
}

/// A tool failure with a message for the model.
struct ToolError: LocalizedError {
    let message: String
    init(_ message: String) {
        self.message = message
    }

    var errorDescription: String? {
        message
    }
}

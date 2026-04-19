import Foundation
import OSLog
import PostgresNIO

/// Protocol for database operations, enabling test mocking.
protocol PostgresClientProtocol: Sendable {
    func connect(profile: ConnectionProfile, password: String?, sshPassword: String?) async throws
    func disconnect() async
    var isConnected: Bool { get async }
    func runQuery(_ sql: String, maxRows: Int, timeout: TimeInterval) async throws -> QueryResult
    func listSchemas() async throws -> [String]
    func listTables(schema: String) async throws -> [DBObject]
    func listViews(schema: String) async throws -> [DBObject]
    func listMaterializedViews(schema: String) async throws -> [DBObject]
    func listFunctions(schema: String) async throws -> [DBObject]
    func listSequences(schema: String) async throws -> [DBObject]
    func listTypes(schema: String) async throws -> [DBObject]
    func listAllSchemaObjects(schema: String) async throws -> SchemaObjects
    func getColumns(schema: String, table: String) async throws -> [ColumnInfo]
    func getPrimaryKeys(schema: String, table: String) async throws -> [String]
    func getApproximateRowCount(schema: String, table: String) async throws -> Int64
    func invalidateCache() async
    func listDatabases() async throws -> [String]
    func switchDatabase(to database: String, profile: ConnectionProfile, password: String?, sshPassword: String?) async throws
    func getObjectDDL(schema: String, name: String, type: DBObjectType) async throws -> String
    // Per-table metadata
    func listIndexes(schema: String, table: String) async throws -> [IndexInfo]
    func listConstraints(schema: String, table: String) async throws -> [ConstraintInfo]
    func listTriggers(schema: String, table: String) async throws -> [TriggerInfo]
    func listPartitions(schema: String, table: String) async throws -> [DBObject]
    // Database-wide metadata
    func listExtensions() async throws -> [ExtensionInfo]
    func listAvailableExtensions() async throws -> [ExtensionInfo]
    func listRoles() async throws -> [RoleInfo]
}

/// The sole component that communicates with PostgreSQL via PostgresNIO.
actor DatabaseClient: PostgresClientProtocol {
    private var client: PostgresClient?
    private var runTask: Task<Void, Never>?
    private let sshTunnel = SSHTunnelService()

    // Introspection cache
    private var cachedServerVersion: Int?
    private var cachedSchemas: [String]?
    private var cachedTables: [String: [DBObject]] = [:]
    private var cachedViews: [String: [DBObject]] = [:]
    private var cachedMatViews: [String: [DBObject]] = [:]
    private var cachedFunctions: [String: [DBObject]] = [:]
    private var cachedSequences: [String: [DBObject]] = [:]
    private var cachedTypes: [String: [DBObject]] = [:]
    private var cachedColumns: [String: [ColumnInfo]] = [:]
    private var cachedPrimaryKeys: [String: [String]] = [:]

    var isConnected: Bool {
        client != nil
    }

    func connect(profile: ConnectionProfile, password: String?, sshPassword: String? = nil) async throws {
        await disconnect()

        let (host, port) = try await resolveConnectionEndpoint(profile: profile, sshPassword: sshPassword)
        try await establishClient(
            host: host, port: port,
            username: profile.username, password: password,
            database: profile.database, sslMode: profile.sslMode,
            cleanupOnFailure: { [weak self] in await self?.disconnect() }
        )

        Log.db.info("Connected to \(profile.host, privacy: .public):\(profile.port)/\(profile.database, privacy: .public)")
    }

    /// Returns the effective (host, port) the PostgreSQL client should dial.
    /// "localhost" is forced to 127.0.0.1 to dodge IPv6 "connection refused"
    /// noise; when an SSH tunnel is requested, starts it and returns the
    /// loopback port to use instead of the remote endpoint.
    private func resolveConnectionEndpoint(profile: ConnectionProfile, sshPassword: String?) async throws -> (host: String, port: Int) {
        if profile.useSSHTunnel {
            let localPort = try await sshTunnel.start(
                sshHost: profile.sshHost,
                sshPort: profile.sshPort,
                sshUser: profile.sshUser,
                sshAuthMethod: profile.sshAuthMethod,
                sshKeyPath: profile.sshKeyPath,
                sshPassword: sshPassword,
                remoteHost: profile.host,
                remotePort: profile.port
            )
            return ("127.0.0.1", Int(localPort))
        }
        let effectiveHost = profile.host.lowercased() == "localhost" ? "127.0.0.1" : profile.host
        return (effectiveHost, profile.port)
    }

    /// Builds a `PostgresClient`, spawns its run-loop task, and verifies the
    /// connection with a trivial `SELECT 1`. On verification failure, runs the
    /// caller-supplied cleanup (`disconnect` for `connect`, a narrower teardown
    /// for `switchDatabase` that preserves the SSH tunnel).
    private func establishClient(
        host: String,
        port: Int,
        username: String,
        password: String?,
        database: String,
        sslMode: SSLMode,
        cleanupOnFailure: () async -> Void
    ) async throws {
        let config = PostgresClient.Configuration(
            host: host, port: port,
            username: username, password: password,
            database: database,
            tls: Self.makeTLS(for: sslMode)
        )

        let newClient = PostgresClient(configuration: config)
        self.client = newClient

        runTask = Task { await newClient.run() }

        do {
            let rows = try await newClient.query("SELECT 1 AS ok")
            for try await _ in rows {}
        } catch {
            await cleanupOnFailure()
            throw AppError.connectionFailed(error.localizedDescription)
        }
    }

    /// Build TLS configuration for the given SSL mode.
    private static func makeTLS(for sslMode: SSLMode) -> PostgresClient.Configuration.TLS {
        switch sslMode {
        case .off:
            return .disable
        case .prefer:
            return .prefer(.makeClientConfiguration())
        case .require:
            return .require(.makeClientConfiguration())
        case .verifyCa:
            var c = TLSConfiguration.makeClientConfiguration()
            c.certificateVerification = .noHostnameVerification
            return .require(c)
        case .verifyFull:
            var c = TLSConfiguration.makeClientConfiguration()
            c.certificateVerification = .fullVerification
            return .require(c)
        }
    }

    func disconnect() async {
        runTask?.cancel()
        runTask = nil
        client = nil
        await sshTunnel.stop()
        await invalidateCache()
        Log.db.info("Disconnected")
    }

    func invalidateCache() async {
        cachedServerVersion = nil
        cachedSchemas = nil
        cachedTables.removeAll()
        cachedViews.removeAll()
        cachedMatViews.removeAll()
        cachedFunctions.removeAll()
        cachedSequences.removeAll()
        cachedTypes.removeAll()
        cachedColumns.removeAll()
        cachedPrimaryKeys.removeAll()
    }

    func runQuery(
        _ sql: String,
        maxRows: Int = 2000,
        timeout: TimeInterval = 10.0
    ) async throws -> QueryResult {
        guard let client else {
            throw AppError.notConnected
        }

        let start = CFAbsoluteTimeGetCurrent()

        // `statement_timeout` is a session-level setting; we must always reset
        // it back to 0 once this query ends, success or failure, so later
        // introspection queries aren't silently capped.
        let resetTimeout = { [client] in
            try? await client.query(PostgresQuery(unsafeSQL: "SET statement_timeout = 0"))
        }

        do {
            let result = try await withThrowingTaskGroup(of: QueryResult.self) { group in
                group.addTask { [client] in
                    try Task.checkCancellation()

                    // Server-side guard — the server kills the query if our
                    // client-side cancellation doesn't reach the driver in time.
                    let timeoutMs = Int(timeout * 1000)
                    try await client.query(PostgresQuery(unsafeSQL: "SET statement_timeout = \(timeoutMs)"))

                    let rowSequence = try await client.query(PostgresQuery(unsafeSQL: sql))

                    var columns: [String] = []
                    var rows: [[CellValue]] = []
                    var isTruncated = false

                    for try await row in rowSequence {
                        try Task.checkCancellation()

                        let randomRow = PostgresRandomAccessRow(row)

                        if columns.isEmpty {
                            for i in 0 ..< randomRow.count {
                                columns.append(randomRow[i].columnName)
                            }
                        }

                        var cellValues: [CellValue] = []
                        for i in 0 ..< randomRow.count {
                            cellValues.append(Self.decodeCellValue(randomRow[i]))
                        }

                        rows.append(cellValues)

                        if rows.count >= maxRows {
                            isTruncated = true
                            break
                        }
                    }

                    let elapsed = CFAbsoluteTimeGetCurrent() - start
                    Log.perf.info("Query: \(elapsed, format: .fixed(precision: 3))s, \(rows.count) rows")

                    return QueryResult(
                        columns: columns,
                        rows: rows,
                        executionTime: elapsed,
                        rowsAffected: nil,
                        isTruncated: isTruncated
                    )
                }

                group.addTask {
                    try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                    throw AppError.queryTimeout
                }

                // Return whichever task finishes first, then cancel the other.
                // `withThrowingTaskGroup` also auto-cancels on throw, but doing
                // it explicitly prevents the timeout task from firing after
                // the query has already succeeded.
                defer { group.cancelAll() }
                guard let winner = try await group.next() else {
                    throw AppError.queryTimeout
                }
                return winner
            }
            await resetTimeout()
            return result
        } catch let error as AppError {
            await resetTimeout()
            throw error
        } catch let error as PSQLError {
            await resetTimeout()
            if error.code == .serverClosedConnection || error.code == .connectionError {
                self.client = nil
                self.runTask?.cancel()
                self.runTask = nil
                throw AppError.connectionFailed("Connection lost: \(Self.formatPSQLError(error))")
            }
            if error.serverInfo?[.sqlState] == "23503" {
                throw AppError.foreignKeyViolation(Self.formatPSQLError(error))
            }
            if let sqlState = error.serverInfo?[.sqlState], sqlState.hasPrefix("08") {
                self.client = nil
                self.runTask?.cancel()
                self.runTask = nil
                throw AppError.connectionFailed("Connection lost: \(Self.formatPSQLError(error))")
            }
            throw AppError.queryFailed(Self.formatPSQLError(error))
        } catch {
            await resetTimeout()
            throw AppError.queryFailed(error.localizedDescription)
        }
    }

    // MARK: - Cell Decoding

    private static let dateFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private static let dateOnlyFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    /// Lookup table for type-aware cell decoders. Each entry converts the wire
    /// bytes to a `CellValue.text(...)`; returning nil means the decode failed
    /// and the caller falls back to plain-String decoding.
    ///
    /// Binary-encoded types (timestamps, numerics, etc.) need their native
    /// decoder; a raw String fallback on binary data produces garbled text, so
    /// all binary-encoded types must have an entry here.
    private static let cellDecoders: [PostgresDataType: @Sendable (PostgresCell) -> CellValue?] = [
        .bool: { cell in (try? cell.decode(Bool.self)).map { .text($0 ? "true" : "false") } },
        .int2: { cell in (try? cell.decode(Int16.self)).map { .text(String($0)) } },
        .int4: { cell in (try? cell.decode(Int32.self)).map { .text(String($0)) } },
        .int8: { cell in (try? cell.decode(Int64.self)).map { .text(String($0)) } },
        .float4: { cell in (try? cell.decode(Float.self)).map { .text(String(Double($0))) } },
        .float8: { cell in (try? cell.decode(Double.self)).map { .text(String($0)) } },
        .numeric: { cell in (try? cell.decode(String.self)).map { .text($0) } },
        .uuid: { cell in (try? cell.decode(UUID.self)).map { .text($0.uuidString) } },
        .timestamp: { cell in (try? cell.decode(Date.self)).map { .text(dateFormatter.string(from: $0)) } },
        .timestamptz: { cell in (try? cell.decode(Date.self)).map { .text(dateFormatter.string(from: $0)) } },
        .date: { cell in (try? cell.decode(Date.self)).map { .text(dateOnlyFormatter.string(from: $0)) } },
        .bytea: { _ in .text("<binary>") },
    ]

    /// Decode a PostgresCell to CellValue using type-aware decoding.
    /// When adding support for new PostgreSQL types, add an entry to
    /// `cellDecoders` to prevent them from hitting the String fallback silently.
    private static func decodeCellValue(_ cell: PostgresCell) -> CellValue {
        guard cell.bytes != nil else { return .null }

        if let decoded = cellDecoders[cell.dataType]?(cell) {
            return decoded
        }

        // Fallback: try String decoding (works for text, varchar, json, jsonb, etc.)
        // Unknown binary-encoded types that can't be decoded as String fall through
        // to "<binary>".
        guard let v = try? cell.decode(String.self) else { return .text("<binary>") }
        return .text(v.count > 10_000 ? String(v.prefix(10_000)) + "…" : v)
    }

    // MARK: - Error Formatting

    /// Extracts the human-readable message and detail from a PSQLError,
    /// falling back to the localized description.
    private static func formatPSQLError(_ error: PSQLError) -> String {
        guard let serverInfo = error.serverInfo else {
            return error.localizedDescription
        }

        var parts: [String] = []
        if let message = serverInfo[.message] {
            parts.append(message)
        }
        if let detail = serverInfo[.detail] {
            parts.append(detail)
        }

        return parts.isEmpty ? error.localizedDescription : parts.joined(separator: "\n")
    }

    // MARK: - Introspection

    func listSchemas() async throws -> [String] {
        if let cached = cachedSchemas { return cached }
        guard let client else { throw AppError.notConnected }

        let sql = """
            SELECT schema_name
            FROM information_schema.schemata
            WHERE schema_name NOT IN ('pg_catalog', 'information_schema')
              AND schema_name NOT LIKE 'pg_%'
            ORDER BY schema_name
            """
        var schemas: [String] = []
        let rows = try await client.query(PostgresQuery(unsafeSQL: sql))
        for try await row in rows {
            let (name,) = try row.decode(String.self)
            schemas.append(name)
        }
        cachedSchemas = schemas
        Log.db.info("Loaded \(schemas.count) schemas")
        return schemas
    }

    /// Runs a single-column name-selecting query and wraps each row in a
    /// DBObject of the given type. Used for the 7 dedicated `list*` methods
    /// plus the inline lists inside `listAllSchemaObjects`.
    ///
    /// Accepts a `PostgresQuery` so callers bind user-supplied schema/table
    /// names as parameters instead of hand-escaping into the SQL.
    private func fetchNamedObjects(
        client: PostgresClient,
        schema: String,
        query: PostgresQuery,
        type: DBObjectType
    ) async throws -> [DBObject] {
        var result: [DBObject] = []
        let rows = try await client.query(query)
        for try await row in rows {
            let (name,) = try row.decode(String.self)
            result.append(DBObject(schema: schema, name: name, type: type))
        }
        return result
    }

    /// Memoized list fetcher. Hits the per-schema cache before issuing a query
    /// and stores the result back under the given key. Logging stays centralized
    /// so each call site doesn't repeat the `Log.db.info` line.
    /// Uses getter/setter closures because KeyPath can't address actor-isolated
    /// properties.
    private func cachedList(
        read: () -> [DBObject]?,
        write: ([DBObject]) -> Void,
        schema: String,
        label: String,
        type: DBObjectType,
        query: PostgresQuery
    ) async throws -> [DBObject] {
        if let cached = read() { return cached }
        guard let client else { throw AppError.notConnected }
        let list = try await fetchNamedObjects(client: client, schema: schema, query: query, type: type)
        write(list)
        Log.db.info("Loaded \(list.count) \(label) in schema \(schema, privacy: .public)")
        return list
    }

    func listTables(schema: String) async throws -> [DBObject] {
        return try await cachedList(
            read: { self.cachedTables[schema] },
            write: { self.cachedTables[schema] = $0 },
            schema: schema, label: "tables", type: .table,
            query: """
                SELECT table_name
                FROM information_schema.tables
                WHERE table_schema = \(schema) AND table_type = 'BASE TABLE'
                ORDER BY table_name
                """
        )
    }

    func listViews(schema: String) async throws -> [DBObject] {
        return try await cachedList(
            read: { self.cachedViews[schema] },
            write: { self.cachedViews[schema] = $0 },
            schema: schema, label: "views", type: .view,
            query: """
                SELECT table_name
                FROM information_schema.views
                WHERE table_schema = \(schema)
                ORDER BY table_name
                """
        )
    }

    func listMaterializedViews(schema: String) async throws -> [DBObject] {
        return try await cachedList(
            read: { self.cachedMatViews[schema] },
            write: { self.cachedMatViews[schema] = $0 },
            schema: schema, label: "materialized views", type: .materializedView,
            query: """
                SELECT matviewname
                FROM pg_matviews
                WHERE schemaname = \(schema)
                ORDER BY matviewname
                """
        )
    }

    func listFunctions(schema: String) async throws -> [DBObject] {
        if let cached = cachedFunctions[schema] { return cached }
        guard let client else { throw AppError.notConnected }

        let pgVersion = await detectServerVersion(client: client)
        // PostgresQuery interpolation binds `\(schema)` as a parameter; the
        // version-dependent `kindFilter` is a static SQL fragment so it goes
        // into the SQL verbatim via unsafe interpolation.
        let kindFilter = pgVersion >= 11 ? "p.prokind = 'f'" : "NOT p.proisagg AND NOT p.proiswindow"
        let query: PostgresQuery = """
            SELECT p.proname || '(' || COALESCE(pg_get_function_identity_arguments(p.oid), '') || ')' AS func_sig
            FROM pg_proc p
            JOIN pg_namespace n ON p.pronamespace = n.oid
            WHERE n.nspname = \(schema)
              AND \(unescaped: kindFilter)
              AND NOT EXISTS (SELECT 1 FROM pg_type t WHERE t.oid = p.prorettype AND t.typname = 'trigger')
            ORDER BY p.proname
            """
        let functions = try await fetchNamedObjects(client: client, schema: schema, query: query, type: .function)
        cachedFunctions[schema] = functions
        Log.db.info("Loaded \(functions.count) functions in schema \(schema, privacy: .public)")
        return functions
    }

    func listSequences(schema: String) async throws -> [DBObject] {
        return try await cachedList(
            read: { self.cachedSequences[schema] },
            write: { self.cachedSequences[schema] = $0 },
            schema: schema, label: "sequences", type: .sequence,
            query: """
                SELECT sequence_name
                FROM information_schema.sequences
                WHERE sequence_schema = \(schema)
                ORDER BY sequence_name
                """
        )
    }

    func listTypes(schema: String) async throws -> [DBObject] {
        return try await cachedList(
            read: { self.cachedTypes[schema] },
            write: { self.cachedTypes[schema] = $0 },
            schema: schema, label: "types", type: .type,
            query: """
                SELECT t.typname
                FROM pg_type t
                JOIN pg_namespace n ON t.typnamespace = n.oid
                WHERE n.nspname = \(schema)
                  AND t.typtype IN ('e', 'c', 'd', 'r')
                  AND NOT EXISTS (SELECT 1 FROM pg_class c WHERE c.reltype = t.oid AND c.relkind IN ('r','v','m','S'))
                ORDER BY t.typname
                """
        )
    }

    func listAllSchemaObjects(schema: String) async throws -> SchemaObjects {
        guard let client else { throw AppError.notConnected }

        // Detect server version for version-dependent queries
        let pgVersion = await detectServerVersion(client: client)

        // Run all queries in parallel. `listX(schema:)` methods use the
        // per-type cache; the inline queries below pull object types not
        // exposed by dedicated `list*` APIs, so they hit pg_catalog directly.
        async let tables = listTables(schema: schema)
        async let views = listViews(schema: schema)
        async let matViews = listMaterializedViews(schema: schema)
        async let functions = listFunctions(schema: schema)
        async let sequences = listSequences(schema: schema)
        async let types = listTypes(schema: schema)

        // Version-dependent fragments are server-derived, never user input —
        // safe to splice via `unescaped:` interpolation.
        let aggFilter = pgVersion >= 11 ? "p.prokind = 'a'" : "p.proisagg = true"
        async let aggregates = fetchNamedObjects(client: client, schema: schema, query: """
            SELECT p.proname FROM pg_proc p
            JOIN pg_namespace n ON p.pronamespace = n.oid
            WHERE n.nspname = \(schema) AND \(unescaped: aggFilter)
            ORDER BY p.proname
            """, type: .aggregate)

        async let collations = fetchNamedObjects(client: client, schema: schema, query: """
            SELECT c.collname FROM pg_collation c
            JOIN pg_namespace n ON c.collnamespace = n.oid
            WHERE n.nspname = \(schema)
            ORDER BY c.collname
            """, type: .collation)

        async let domains = fetchNamedObjects(client: client, schema: schema, query: """
            SELECT domain_name FROM information_schema.domains
            WHERE domain_schema = \(schema)
            ORDER BY domain_name
            """, type: .domain)

        async let ftsConfigs = fetchNamedObjects(client: client, schema: schema, query: """
            SELECT cfgname FROM pg_ts_config c
            JOIN pg_namespace n ON c.cfgnamespace = n.oid
            WHERE n.nspname = \(schema)
            ORDER BY cfgname
            """, type: .ftsConfiguration)

        async let ftsDicts = fetchNamedObjects(client: client, schema: schema, query: """
            SELECT dictname FROM pg_ts_dict d
            JOIN pg_namespace n ON d.dictnamespace = n.oid
            WHERE n.nspname = \(schema)
            ORDER BY dictname
            """, type: .ftsDictionary)

        async let ftsParsers = fetchNamedObjects(client: client, schema: schema, query: """
            SELECT prsname FROM pg_ts_parser p
            JOIN pg_namespace n ON p.prsnamespace = n.oid
            WHERE n.nspname = \(schema)
            ORDER BY prsname
            """, type: .ftsParser)

        async let ftsTemplates = fetchNamedObjects(client: client, schema: schema, query: """
            SELECT tmplname FROM pg_ts_template t
            JOIN pg_namespace n ON t.tmplnamespace = n.oid
            WHERE n.nspname = \(schema)
            ORDER BY tmplname
            """, type: .ftsTemplate)

        async let foreignTables = fetchNamedObjects(client: client, schema: schema, query: """
            SELECT c.relname FROM pg_class c
            JOIN pg_namespace n ON c.relnamespace = n.oid
            WHERE n.nspname = \(schema) AND c.relkind = 'f'
            ORDER BY c.relname
            """, type: .foreignTable)

        async let operators = fetchNamedObjects(client: client, schema: schema, query: """
            SELECT oprname FROM pg_operator o
            JOIN pg_namespace n ON o.oprnamespace = n.oid
            WHERE n.nspname = \(schema)
            ORDER BY oprname
            """, type: .operator)

        // PG 11 introduced prokind; earlier versions have neither procedures
        // nor a reliable way to filter them out. Skip the fetch entirely there.
        async let procedures: [DBObject] = pgVersion >= 11
            ? fetchNamedObjects(client: client, schema: schema, query: """
                SELECT p.proname FROM pg_proc p
                JOIN pg_namespace n ON p.pronamespace = n.oid
                WHERE n.nspname = \(schema) AND p.prokind = 'p'
                ORDER BY p.proname
                """, type: .procedure)
            : []

        let triggerKindFilter = pgVersion >= 11 ? "AND p.prokind = 'f'" : "AND NOT p.proisagg"
        async let triggerFunctions = fetchNamedObjects(client: client, schema: schema, query: """
            SELECT p.proname FROM pg_proc p
            JOIN pg_namespace n ON p.pronamespace = n.oid
            JOIN pg_type t ON p.prorettype = t.oid
            WHERE n.nspname = \(schema) AND t.typname = 'trigger' \(unescaped: triggerKindFilter)
            ORDER BY p.proname
            """, type: .triggerFunction)

        return SchemaObjects(
            aggregates: try await aggregates,
            collations: try await collations,
            domains: try await domains,
            ftsConfigurations: try await ftsConfigs,
            ftsDictionaries: try await ftsDicts,
            ftsParsers: try await ftsParsers,
            ftsTemplates: try await ftsTemplates,
            foreignTables: try await foreignTables,
            functions: try await functions,
            materializedViews: try await matViews,
            operators: try await operators,
            procedures: try await procedures,
            sequences: try await sequences,
            tables: try await tables,
            triggerFunctions: try await triggerFunctions,
            types: try await types,
            views: try await views
        )
    }

    private func detectServerVersion(client: PostgresClient) async -> Int {
        if let cached = cachedServerVersion { return cached }
        do {
            let rows = try await client.query("SHOW server_version_num")
            for try await row in rows {
                if let (vStr,) = try? row.decode(String.self), let num = Int(vStr) {
                    let version = num / 10000
                    cachedServerVersion = version
                    return version
                }
            }
        } catch {}
        return 14
    }

    func getColumns(schema: String, table: String) async throws -> [ColumnInfo] {
        let cacheKey = "\(schema).\(table)"
        if let cached = cachedColumns[cacheKey] { return cached }
        guard let client else { throw AppError.notConnected }

        let pkNames = try await getPrimaryKeys(schema: schema, table: table)
        let pkSet = Set(pkNames)

        let query: PostgresQuery = """
            SELECT column_name, ordinal_position, data_type, is_nullable, column_default,
                   character_maximum_length, udt_name, numeric_precision, numeric_scale,
                   is_identity, identity_generation
            FROM information_schema.columns
            WHERE table_schema = \(schema)
              AND table_name = \(table)
            ORDER BY ordinal_position
            """
        var columns: [ColumnInfo] = []
        let rows = try await client.query(query)
        for try await row in rows {
            let randomRow = PostgresRandomAccessRow(row)
            let name = try randomRow["column_name"].decode(String.self)
            let ordinal = Int(try randomRow["ordinal_position"].decode(Int32.self))
            let dataType = try randomRow["data_type"].decode(String.self)
            let nullable = try randomRow["is_nullable"].decode(String.self)
            let defaultVal = try? randomRow["column_default"].decode(String?.self)
            let maxLength = try? randomRow["character_maximum_length"].decode(Int?.self)
            let udtName = try? randomRow["udt_name"].decode(String?.self)
            let numericPrecision = try? randomRow["numeric_precision"].decode(Int?.self)
            let numericScale = try? randomRow["numeric_scale"].decode(Int?.self)
            let isIdentityStr = try? randomRow["is_identity"].decode(String?.self)
            let identityGeneration = try? randomRow["identity_generation"].decode(String?.self)

            columns.append(ColumnInfo(
                name: name,
                ordinalPosition: ordinal,
                dataType: dataType,
                isNullable: nullable == "YES",
                columnDefault: defaultVal ?? nil,
                characterMaximumLength: maxLength ?? nil,
                isPrimaryKey: pkSet.contains(name),
                udtName: udtName ?? nil,
                numericPrecision: numericPrecision ?? nil,
                numericScale: numericScale ?? nil,
                isIdentity: (isIdentityStr ?? nil) == "YES",
                identityGeneration: identityGeneration ?? nil
            ))
        }
        cachedColumns[cacheKey] = columns
        Log.db.info("Loaded \(columns.count) columns for \(cacheKey, privacy: .public)")
        return columns
    }

    func getPrimaryKeys(schema: String, table: String) async throws -> [String] {
        let cacheKey = "\(schema).\(table)"
        if let cached = cachedPrimaryKeys[cacheKey] { return cached }
        guard let client else { throw AppError.notConnected }

        let query: PostgresQuery = """
            SELECT a.attname
            FROM pg_index i
            JOIN pg_attribute a ON a.attrelid = i.indrelid AND a.attnum = ANY(i.indkey)
            JOIN pg_class c ON c.oid = i.indrelid
            JOIN pg_namespace n ON n.oid = c.relnamespace
            WHERE i.indisprimary
              AND n.nspname = \(schema)
              AND c.relname = \(table)
            ORDER BY a.attnum
            """
        var keys: [String] = []
        let rows = try await client.query(query)
        for try await row in rows {
            let (name,) = try row.decode(String.self)
            keys.append(name)
        }
        cachedPrimaryKeys[cacheKey] = keys
        Log.db.info("Loaded \(keys.count) primary keys for \(cacheKey, privacy: .public)")
        return keys
    }

    func getApproximateRowCount(schema: String, table: String) async throws -> Int64 {
        guard let client else { throw AppError.notConnected }

        let query: PostgresQuery = """
            SELECT reltuples::bigint AS approx_count
            FROM pg_class c
            JOIN pg_namespace n ON n.oid = c.relnamespace
            WHERE n.nspname = \(schema)
              AND c.relname = \(table)
            """
        let rows = try await client.query(query)
        for try await row in rows {
            let (count,) = try row.decode(Int64.self)
            if count >= 0 {
                return count
            }
            // reltuples = -1 means ANALYZE has never run; fall back to exact count
            let countSQL = "SELECT COUNT(*) FROM \(quoteIdent(schema)).\(quoteIdent(table))"
            let countRows = try await client.query(PostgresQuery(unsafeSQL: countSQL))
            for try await countRow in countRows {
                let (exact,) = try countRow.decode(Int64.self)
                return exact
            }
        }
        return 0
    }

    func listDatabases() async throws -> [String] {
        guard let client else { throw AppError.notConnected }

        let sql = """
            SELECT datname
            FROM pg_database
            WHERE datistemplate = false
            ORDER BY datname
            """
        var databases: [String] = []
        let rows = try await client.query(PostgresQuery(unsafeSQL: sql))
        for try await row in rows {
            let (name,) = try row.decode(String.self)
            databases.append(name)
        }
        Log.db.info("Loaded \(databases.count) databases")
        return databases
    }

    func switchDatabase(to database: String, profile: ConnectionProfile, password: String?, sshPassword: String? = nil) async throws {
        // Tear down only the PostgreSQL client — leave the SSH tunnel running.
        runTask?.cancel()
        runTask = nil
        client = nil
        await invalidateCache()
        Log.db.info("PostgreSQL client disconnected for database switch (tunnel preserved)")

        var newProfile = profile
        newProfile.database = database

        // Reuse the existing tunnel if we still have one; otherwise start a
        // fresh tunnel (or dial directly for non-tunneled profiles).
        let host: String
        let port: Int
        if newProfile.useSSHTunnel, await sshTunnel.isActive {
            host = "127.0.0.1"
            port = Int(await sshTunnel.tunnelLocalPort)
        } else {
            (host, port) = try await resolveConnectionEndpoint(profile: newProfile, sshPassword: sshPassword)
        }

        try await establishClient(
            host: host, port: port,
            username: newProfile.username, password: password,
            database: newProfile.database, sslMode: newProfile.sslMode,
            cleanupOnFailure: { [weak self] in
                // Preserve SSH tunnel on switch failure so the caller can retry.
                await self?.teardownPostgresClient()
            }
        )

        Log.db.info("Switched to database \(database, privacy: .public) on \(host, privacy: .public):\(port)")
    }

    /// Tears down the PostgresNIO client and cache without touching the SSH
    /// tunnel — used during database switches so the tunnel can be reused.
    private func teardownPostgresClient() async {
        runTask?.cancel()
        runTask = nil
        client = nil
        await invalidateCache()
    }

    /// Splits a signature like "my_func(integer, text)" into ("my_func", "integer, text").
    /// Returns (name, "") when no parentheses are present.
    private func splitFunctionSignature(_ name: String) -> (base: String, args: String) {
        guard let parenIdx = name.firstIndex(of: "("), name.hasSuffix(")") else {
            return (name, "")
        }
        let base = String(name[name.startIndex ..< parenIdx])
        let argsStart = name.index(after: parenIdx)
        let argsEnd = name.index(before: name.endIndex)
        let args = argsStart < argsEnd ? String(name[argsStart ..< argsEnd]) : ""
        return (base, args)
    }

    func getObjectDDL(schema: String, name: String, type: DBObjectType) async throws -> String {
        guard let client else { throw AppError.notConnected }

        let query = makeObjectDDLQuery(schema: schema, name: name, type: type)
        let rows = try await client.query(query)
        for try await row in rows {
            if let (ddl,) = try? row.decode(String.self) {
                return ddl
            }
        }
        return "-- Definition not available"
    }

    /// Builds the parameterized lookup query for each DDL object type.
    /// Schema/name are always bound as parameters — both in WHERE filters
    /// and in the `CREATE …` string reconstructions, where text parameters
    /// concatenate into the output just like string literals did.
    private func makeObjectDDLQuery(schema: String, name: String, type: DBObjectType) -> PostgresQuery {
        switch type {
        case .function, .procedure, .aggregate, .triggerFunction:
            // `name` may include args like "my_func(integer, text)". Match by
            // full identity signature via regprocedure so overloads resolve to
            // the exact function the user is viewing. Fall back to name-only
            // lookup only when the signature can't be formed.
            let (baseName, argList) = splitFunctionSignature(name)
            let hasArgs = !argList.isEmpty && argList != "*"
            if hasArgs {
                let regprocLiteral = "\(schema).\(baseName)(\(argList))"
                return """
                    SELECT pg_get_functiondef(p.oid)
                    FROM pg_proc p
                    WHERE p.oid = \(regprocLiteral)::regprocedure
                    LIMIT 1
                    """
            }
            return """
                SELECT pg_get_functiondef(p.oid)
                FROM pg_proc p
                JOIN pg_namespace n ON p.pronamespace = n.oid
                WHERE n.nspname = \(schema) AND p.proname = \(baseName)
                LIMIT 1
                """
        case .view:
            return """
                SELECT 'CREATE OR REPLACE VIEW ' || \(schema) || '.' || \(name) || ' AS ' || chr(10) || pg_get_viewdef(c.oid, true)
                FROM pg_class c
                JOIN pg_namespace n ON c.relnamespace = n.oid
                WHERE n.nspname = \(schema) AND c.relname = \(name) AND c.relkind = 'v'
                """
        case .materializedView:
            return """
                SELECT 'CREATE MATERIALIZED VIEW ' || \(schema) || '.' || \(name) || ' AS ' || chr(10) || pg_get_viewdef(c.oid, true)
                FROM pg_class c
                JOIN pg_namespace n ON c.relnamespace = n.oid
                WHERE n.nspname = \(schema) AND c.relname = \(name) AND c.relkind = 'm'
                """
        case .sequence:
            return """
                SELECT 'CREATE SEQUENCE ' || \(schema) || '.' || \(name) || chr(10)
                    || '  INCREMENT ' || increment_by || chr(10)
                    || '  MINVALUE ' || min_value || chr(10)
                    || '  MAXVALUE ' || max_value || chr(10)
                    || '  START ' || start_value || chr(10)
                    || '  CACHE ' || cache_size
                    || CASE WHEN cycle THEN chr(10) || '  CYCLE' ELSE '' END || ';'
                FROM pg_sequences
                WHERE schemaname = \(schema) AND sequencename = \(name)
                """
        case .type:
            return """
                SELECT CASE t.typtype
                    WHEN 'e' THEN 'CREATE TYPE ' || \(schema) || '.' || \(name) || ' AS ENUM (' || chr(10)
                        || string_agg('  ' || quote_literal(e.enumlabel), ',' || chr(10) ORDER BY e.enumsortorder)
                        || chr(10) || ');'
                    WHEN 'c' THEN 'CREATE TYPE ' || \(schema) || '.' || \(name) || ' AS (' || chr(10)
                        || (SELECT string_agg('  ' || a.attname || ' ' || pg_catalog.format_type(a.atttypid, a.atttypmod), ',' || chr(10) ORDER BY a.attnum)
                            FROM pg_attribute a WHERE a.attrelid = t.typrelid AND a.attnum > 0 AND NOT a.attisdropped)
                        || chr(10) || ');'
                    WHEN 'd' THEN pg_catalog.format_type(t.oid, NULL)
                    ELSE '-- Type definition not available'
                END AS ddl
                FROM pg_type t
                JOIN pg_namespace n ON t.typnamespace = n.oid
                LEFT JOIN pg_enum e ON t.typtype = 'e' AND e.enumtypid = t.oid
                WHERE n.nspname = \(schema) AND t.typname = \(name)
                GROUP BY t.typtype, t.typrelid, t.oid
                """
        case .domain:
            return """
                SELECT 'CREATE DOMAIN ' || \(schema) || '.' || \(name) || ' AS '
                    || pg_catalog.format_type(t.typbasetype, t.typtypmod)
                    || COALESCE(' DEFAULT ' || t.typdefault, '')
                    || COALESCE(chr(10) || string_agg('  CONSTRAINT ' || con.conname || ' ' || pg_get_constraintdef(con.oid), chr(10)), '')
                    || ';'
                FROM pg_type t
                JOIN pg_namespace n ON t.typnamespace = n.oid
                LEFT JOIN pg_constraint con ON con.contypid = t.oid
                WHERE n.nspname = \(schema) AND t.typname = \(name)
                GROUP BY t.typbasetype, t.typtypmod, t.typdefault
                """
        case .collation:
            return """
                SELECT 'CREATE COLLATION ' || \(schema) || '.' || \(name) || ' ('
                    || 'LOCALE = ' || quote_literal(COALESCE(c.collcollate, ''))
                    || ');'
                FROM pg_collation c
                JOIN pg_namespace n ON c.collnamespace = n.oid
                WHERE n.nspname = \(schema) AND c.collname = \(name)
                """
        case .foreignTable:
            return """
                SELECT 'CREATE FOREIGN TABLE ' || \(schema) || '.' || \(name) || ' (' || chr(10)
                    || string_agg('  ' || a.attname || ' ' || pg_catalog.format_type(a.atttypid, a.atttypmod), ',' || chr(10) ORDER BY a.attnum)
                    || chr(10) || ') SERVER ' || s.srvname || ';'
                FROM pg_class c
                JOIN pg_namespace n ON c.relnamespace = n.oid
                JOIN pg_foreign_table ft ON ft.ftrelid = c.oid
                JOIN pg_foreign_server s ON ft.ftserver = s.oid
                JOIN pg_attribute a ON a.attrelid = c.oid AND a.attnum > 0 AND NOT a.attisdropped
                WHERE n.nspname = \(schema) AND c.relname = \(name)
                GROUP BY s.srvname
                """
        case .ftsConfiguration:
            return "SELECT '-- FTS Configuration: ' || \(name) || chr(10) || '-- Use pg_ts_config_map for details'"
        case .ftsDictionary:
            return "SELECT '-- FTS Dictionary: ' || \(name) || chr(10) || '-- Use pg_ts_dict for details'"
        case .ftsParser:
            return "SELECT '-- FTS Parser: ' || \(name) || chr(10) || '-- Use pg_ts_parser for details'"
        case .ftsTemplate:
            return "SELECT '-- FTS Template: ' || \(name) || chr(10) || '-- Use pg_ts_template for details'"
        case .operator:
            return """
                SELECT '-- Operator: ' || o.oprname || chr(10)
                    || '-- Left type: ' || COALESCE(lt.typname, 'NONE') || chr(10)
                    || '-- Right type: ' || COALESCE(rt.typname, 'NONE') || chr(10)
                    || '-- Result type: ' || res.typname || chr(10)
                    || '-- Function: ' || p.proname
                FROM pg_operator o
                JOIN pg_namespace n ON o.oprnamespace = n.oid
                LEFT JOIN pg_type lt ON o.oprleft = lt.oid
                LEFT JOIN pg_type rt ON o.oprright = rt.oid
                JOIN pg_type res ON o.oprresult = res.oid
                JOIN pg_proc p ON o.oprcode = p.oid
                WHERE n.nspname = \(schema) AND o.oprname = \(name)
                LIMIT 1
                """
        case .table:
            return "SELECT '-- Use Structure tab for table details'"
        }
    }

    // MARK: - Per-table Metadata (Indexes / Constraints / Triggers / Partitions)

    func listIndexes(schema: String, table: String) async throws -> [IndexInfo] {
        guard let client else { throw AppError.notConnected }
        // `regexp_replace` strips everything after USING … to keep the column
        // list separate from index method in `pg_get_indexdef`; instead we
        // rely on pg_catalog columns directly for structured fields.
        let query: PostgresQuery = """
            SELECT i.relname AS name,
                   am.amname AS method,
                   idx.indisunique AS is_unique,
                   idx.indisprimary AS is_primary,
                   idx.indpred IS NOT NULL AS is_partial,
                   pg_get_indexdef(idx.indexrelid) AS defn,
                   ARRAY(
                       SELECT pg_get_indexdef(idx.indexrelid, k + 1, true)
                       FROM generate_subscripts(idx.indkey, 1) AS k
                   ) AS cols
            FROM pg_index idx
            JOIN pg_class i ON i.oid = idx.indexrelid
            JOIN pg_class t ON t.oid = idx.indrelid
            JOIN pg_namespace n ON n.oid = t.relnamespace
            JOIN pg_am am ON am.oid = i.relam
            WHERE n.nspname = \(schema) AND t.relname = \(table)
            ORDER BY i.relname
            """
        var result: [IndexInfo] = []
        let rows = try await client.query(query)
        for try await row in rows {
            let ra = PostgresRandomAccessRow(row)
            let name = try ra["name"].decode(String.self)
            let method = try ra["method"].decode(String.self)
            let isUnique = try ra["is_unique"].decode(Bool.self)
            let isPrimary = try ra["is_primary"].decode(Bool.self)
            let isPartial = try ra["is_partial"].decode(Bool.self)
            let cols = (try? ra["cols"].decode([String].self)) ?? []
            result.append(IndexInfo(
                schema: schema, table: table, name: name, columns: cols,
                isUnique: isUnique, isPrimary: isPrimary, method: method, isPartial: isPartial
            ))
        }
        return result
    }

    func listConstraints(schema: String, table: String) async throws -> [ConstraintInfo] {
        guard let client else { throw AppError.notConnected }
        let query: PostgresQuery = """
            SELECT c.conname AS name,
                   c.contype AS kind,
                   pg_get_constraintdef(c.oid) AS defn,
                   (SELECT ARRAY_AGG(a.attname ORDER BY k.ord)
                      FROM unnest(c.conkey) WITH ORDINALITY AS k(attnum, ord)
                      JOIN pg_attribute a ON a.attrelid = c.conrelid AND a.attnum = k.attnum
                   ) AS cols,
                   rn.nspname AS ref_schema,
                   rc.relname AS ref_table,
                   (SELECT ARRAY_AGG(a.attname ORDER BY k.ord)
                      FROM unnest(COALESCE(c.confkey, '{}'::smallint[])) WITH ORDINALITY AS k(attnum, ord)
                      JOIN pg_attribute a ON a.attrelid = c.confrelid AND a.attnum = k.attnum
                   ) AS ref_cols
            FROM pg_constraint c
            JOIN pg_class t ON t.oid = c.conrelid
            JOIN pg_namespace n ON n.oid = t.relnamespace
            LEFT JOIN pg_class rc ON rc.oid = c.confrelid
            LEFT JOIN pg_namespace rn ON rn.oid = rc.relnamespace
            WHERE n.nspname = \(schema) AND t.relname = \(table)
            ORDER BY c.conname
            """
        var result: [ConstraintInfo] = []
        let rows = try await client.query(query)
        for try await row in rows {
            let ra = PostgresRandomAccessRow(row)
            let name = try ra["name"].decode(String.self)
            let rawKind = try ra["kind"].decode(String.self)
            let kind: ConstraintInfo.Kind
            switch rawKind {
            case "p": kind = .primaryKey
            case "f": kind = .foreignKey
            case "u": kind = .unique
            case "c": kind = .check
            case "x": kind = .exclude
            default: continue
            }
            let defn = try ra["defn"].decode(String.self)
            let cols = (try? ra["cols"].decode([String].self)) ?? []
            let refTable: String? = try? ra["ref_table"].decode(String?.self) ?? nil
            let refSchema: String? = try? ra["ref_schema"].decode(String?.self) ?? nil
            let refCols = (try? ra["ref_cols"].decode([String]?.self) ?? nil) ?? []
            result.append(ConstraintInfo(
                schema: schema, table: table, name: name, kind: kind,
                definition: defn, columns: cols,
                referencedTable: refTable.flatMap { t in refSchema.map { "\($0).\(t)" } ?? t },
                referencedColumns: refCols
            ))
        }
        return result
    }

    func listTriggers(schema: String, table: String) async throws -> [TriggerInfo] {
        guard let client else { throw AppError.notConnected }
        // `information_schema.triggers` emits one row per fired event; collapse
        // to one row per trigger so users see a single entry for `INSERT OR UPDATE`.
        let query: PostgresQuery = """
            SELECT t.tgname AS name,
                   CASE (t.tgtype::int & 66)
                     WHEN 2 THEN 'BEFORE'
                     WHEN 64 THEN 'INSTEAD OF'
                     ELSE 'AFTER'
                   END AS timing,
                   array_to_string(ARRAY(
                     SELECT e FROM (VALUES
                       (4,  'INSERT'),
                       (8,  'DELETE'),
                       (16, 'UPDATE'),
                       (32, 'TRUNCATE')
                     ) AS v(mask, e)
                     WHERE (t.tgtype::int & v.mask) <> 0
                   ), ' OR ') AS event,
                   pg_get_triggerdef(t.oid, true) AS action,
                   t.tgenabled = 'D' AS disabled
            FROM pg_trigger t
            JOIN pg_class c ON c.oid = t.tgrelid
            JOIN pg_namespace n ON n.oid = c.relnamespace
            WHERE NOT t.tgisinternal
              AND n.nspname = \(schema) AND c.relname = \(table)
            ORDER BY t.tgname
            """
        var result: [TriggerInfo] = []
        let rows = try await client.query(query)
        for try await row in rows {
            let ra = PostgresRandomAccessRow(row)
            let name = try ra["name"].decode(String.self)
            let timing = try ra["timing"].decode(String.self)
            let event = try ra["event"].decode(String.self)
            let action = try ra["action"].decode(String.self)
            let disabled = try ra["disabled"].decode(Bool.self)
            result.append(TriggerInfo(
                schema: schema, table: table, name: name,
                timing: timing, event: event,
                actionStatement: action, isDisabled: disabled
            ))
        }
        return result
    }

    func listPartitions(schema: String, table: String) async throws -> [DBObject] {
        guard let client else { throw AppError.notConnected }
        let query: PostgresQuery = """
            SELECT child_ns.nspname || '.' || child.relname AS name
            FROM pg_inherits ih
            JOIN pg_class parent ON parent.oid = ih.inhparent
            JOIN pg_namespace parent_ns ON parent_ns.oid = parent.relnamespace
            JOIN pg_class child ON child.oid = ih.inhrelid
            JOIN pg_namespace child_ns ON child_ns.oid = child.relnamespace
            WHERE parent_ns.nspname = \(schema) AND parent.relname = \(table)
              AND parent.relkind = 'p'
            ORDER BY child_ns.nspname, child.relname
            """
        return try await fetchNamedObjects(client: client, schema: schema, query: query, type: .table)
    }

    // MARK: - Database-Wide Metadata (Extensions / Roles)

    func listExtensions() async throws -> [ExtensionInfo] {
        guard let client else { throw AppError.notConnected }
        let sql = """
            SELECT e.extname, n.nspname AS schema, e.extversion,
                   ae.default_version, ae.comment
            FROM pg_extension e
            JOIN pg_namespace n ON n.oid = e.extnamespace
            LEFT JOIN pg_available_extensions ae ON ae.name = e.extname
            ORDER BY e.extname
            """
        var result: [ExtensionInfo] = []
        let rows = try await client.query(PostgresQuery(unsafeSQL: sql))
        for try await row in rows {
            let ra = PostgresRandomAccessRow(row)
            let name = try ra["extname"].decode(String.self)
            let schema = try? ra["schema"].decode(String?.self)
            let version = try? ra["extversion"].decode(String?.self)
            let defaultVersion = try? ra["default_version"].decode(String?.self)
            let comment = try? ra["comment"].decode(String?.self)
            result.append(ExtensionInfo(
                name: name, schema: schema ?? nil,
                installedVersion: version ?? nil,
                defaultVersion: defaultVersion ?? nil,
                comment: comment ?? nil
            ))
        }
        return result
    }

    func listAvailableExtensions() async throws -> [ExtensionInfo] {
        guard let client else { throw AppError.notConnected }
        let sql = """
            SELECT name, installed_version, default_version, comment
            FROM pg_available_extensions
            ORDER BY name
            """
        var result: [ExtensionInfo] = []
        let rows = try await client.query(PostgresQuery(unsafeSQL: sql))
        for try await row in rows {
            let ra = PostgresRandomAccessRow(row)
            let name = try ra["name"].decode(String.self)
            let installed = try? ra["installed_version"].decode(String?.self)
            let defaultVersion = try? ra["default_version"].decode(String?.self)
            let comment = try? ra["comment"].decode(String?.self)
            result.append(ExtensionInfo(
                name: name, schema: nil,
                installedVersion: installed ?? nil,
                defaultVersion: defaultVersion ?? nil,
                comment: comment ?? nil
            ))
        }
        return result
    }

    func listRoles() async throws -> [RoleInfo] {
        guard let client else { throw AppError.notConnected }
        let sql = """
            SELECT r.rolname, r.rolsuper, r.rolcanlogin, r.rolcreatedb,
                   r.rolcreaterole, r.rolreplication,
                   to_char(r.rolvaliduntil, 'YYYY-MM-DD HH24:MI:SSOF') AS valid_until,
                   ARRAY(
                       SELECT b.rolname FROM pg_auth_members m
                       JOIN pg_roles b ON b.oid = m.roleid
                       WHERE m.member = r.oid
                       ORDER BY b.rolname
                   ) AS member_of
            FROM pg_roles r
            ORDER BY r.rolname
            """
        var result: [RoleInfo] = []
        let rows = try await client.query(PostgresQuery(unsafeSQL: sql))
        for try await row in rows {
            let ra = PostgresRandomAccessRow(row)
            let name = try ra["rolname"].decode(String.self)
            let isSuper = try ra["rolsuper"].decode(Bool.self)
            let canLogin = try ra["rolcanlogin"].decode(Bool.self)
            let canCreateDB = try ra["rolcreatedb"].decode(Bool.self)
            let canCreateRole = try ra["rolcreaterole"].decode(Bool.self)
            let isReplication = try ra["rolreplication"].decode(Bool.self)
            let validUntil = try? ra["valid_until"].decode(String?.self)
            let memberOf = (try? ra["member_of"].decode([String].self)) ?? []
            result.append(RoleInfo(
                name: name, isSuperuser: isSuper, canLogin: canLogin,
                canCreateDB: canCreateDB, canCreateRole: canCreateRole,
                isReplication: isReplication, memberOf: memberOf,
                validUntil: validUntil ?? nil
            ))
        }
        return result
    }
}

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

        // Start SSH tunnel if configured
        var effectiveHost = profile.host
        var effectivePort = profile.port

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
            effectiveHost = "127.0.0.1"
            effectivePort = Int(localPort)
        }

        let tls = Self.makeTLS(for: profile.sslMode)

        let config = PostgresClient.Configuration(
            host: effectiveHost,
            port: effectivePort,
            username: profile.username,
            password: password,
            database: profile.database,
            tls: tls
        )

        let newClient = PostgresClient(configuration: config)
        self.client = newClient

        // Start the client's run loop in a background task
        runTask = Task {
            await newClient.run()
        }

        // Verify connection
        do {
            let rows = try await newClient.query("SELECT 1 AS ok")
            for try await _ in rows {}
        } catch {
            await disconnect()
            throw AppError.connectionFailed(error.localizedDescription)
        }

        Log.db.info("Connected to \(profile.host, privacy: .public):\(profile.port)/\(profile.database, privacy: .public)")
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

        let result: QueryResult
        do {
            result = try await withThrowingTaskGroup(of: QueryResult.self) { group in
                group.addTask { [client] in
                    try Task.checkCancellation()

                    // Set server-side statement timeout so the server cancels
                    // long-running queries even if the client-side cancellation
                    // doesn't reach the driver in time.
                    let timeoutMs = Int(timeout * 1000)
                    try await client.query(PostgresQuery(unsafeSQL: "SET statement_timeout = \(timeoutMs)"))

                    let rowSequence = try await client.query(PostgresQuery(unsafeSQL: sql))

                    var columns: [String] = []
                    var rows: [[CellValue]] = []
                    var isTruncated = false

                    for try await row in rowSequence {
                        try Task.checkCancellation()

                        let randomRow = PostgresRandomAccessRow(row)

                        // Capture column names from first row
                        if columns.isEmpty {
                            for i in 0 ..< randomRow.count {
                                columns.append(randomRow[i].columnName)
                            }
                        }

                        // Convert cells to CellValue using type-aware decoding
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

                // Timeout task
                group.addTask {
                    try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                    throw AppError.queryTimeout
                }

                guard let result = try await group.next() else {
                    throw AppError.queryTimeout
                }
                group.cancelAll()
                return result
            }
        } catch let error as AppError {
            // Always reset statement timeout, even on failure
            try? await client.query(PostgresQuery(unsafeSQL: "SET statement_timeout = 0"))
            throw error
        } catch let error as PSQLError {
            // Always reset statement timeout, even on failure
            try? await client.query(PostgresQuery(unsafeSQL: "SET statement_timeout = 0"))
            // Detect connection-loss conditions
            if error.code == .serverClosedConnection || error.code == .connectionError {
                self.client = nil
                self.runTask?.cancel()
                self.runTask = nil
                throw AppError.connectionFailed("Connection lost: \(Self.formatPSQLError(error))")
            }
            if error.serverInfo?[.sqlState] == "23503" {
                throw AppError.foreignKeyViolation(Self.formatPSQLError(error))
            }
            // Check for connection-loss SQL states (08xxx class)
            if let sqlState = error.serverInfo?[.sqlState], sqlState.hasPrefix("08") {
                self.client = nil
                self.runTask?.cancel()
                self.runTask = nil
                throw AppError.connectionFailed("Connection lost: \(Self.formatPSQLError(error))")
            }
            throw AppError.queryFailed(Self.formatPSQLError(error))
        } catch {
            // Always reset statement timeout, even on failure
            try? await client.query(PostgresQuery(unsafeSQL: "SET statement_timeout = 0"))
            throw AppError.queryFailed(error.localizedDescription)
        }

        // Reset statement timeout to avoid affecting introspection queries
        try? await client.query(PostgresQuery(unsafeSQL: "SET statement_timeout = 0"))

        return result
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

    /// Decode a PostgresCell to CellValue using type-aware decoding.
    /// Binary-encoded types (timestamps, numerics, etc.) need their native
    /// decoder; falling back to String on binary data produces garbled text.
    private static func decodeCellValue(_ cell: PostgresCell) -> CellValue {
        guard cell.bytes != nil else { return .null }

        switch cell.dataType {
        case .bool:
            if let v = try? cell.decode(Bool.self) { return .text(v ? "true" : "false") }
        case .int2:
            if let v = try? cell.decode(Int16.self) { return .text(String(v)) }
        case .int4:
            if let v = try? cell.decode(Int32.self) { return .text(String(v)) }
        case .int8:
            if let v = try? cell.decode(Int64.self) { return .text(String(v)) }
        case .float4:
            if let v = try? cell.decode(Float.self) { return .text(String(Double(v))) }
        case .float8:
            if let v = try? cell.decode(Double.self) { return .text(String(v)) }
        case .numeric:
            if let v = try? cell.decode(String.self) { return .text(v) }
        case .uuid:
            if let v = try? cell.decode(UUID.self) { return .text(v.uuidString) }
        case .timestamp, .timestamptz:
            if let v = try? cell.decode(Date.self) { return .text(dateFormatter.string(from: v)) }
        case .date:
            if let v = try? cell.decode(Date.self) {
                return .text(dateOnlyFormatter.string(from: v))
            }
        case .bytea:
            return .text("<binary>")
        default:
            break
        }

        // Fallback: try String decoding (works for text, varchar, json, jsonb, etc.)
        // Unknown binary-encoded types that can't be decoded as String fall through
        // to "<binary>". When adding support for new PostgreSQL types, add explicit
        // cases above to prevent them from hitting this fallback silently.
        if let v = try? cell.decode(String.self) {
            if v.count > 10_000 {
                return .text(String(v.prefix(10_000)) + "…")
            }
            return .text(v)
        }
        return .text("<binary>")
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

    func listTables(schema: String) async throws -> [DBObject] {
        if let cached = cachedTables[schema] { return cached }
        guard let client else { throw AppError.notConnected }

        let escapedSchema = schema.replacingOccurrences(of: "'", with: "''")
        let sql = """
            SELECT table_name
            FROM information_schema.tables
            WHERE table_schema = '\(escapedSchema)'
              AND table_type = 'BASE TABLE'
            ORDER BY table_name
            """
        var tables: [DBObject] = []
        let rows = try await client.query(PostgresQuery(unsafeSQL: sql))
        for try await row in rows {
            let (name,) = try row.decode(String.self)
            tables.append(DBObject(schema: schema, name: name, type: .table))
        }
        cachedTables[schema] = tables
        Log.db.info("Loaded \(tables.count) tables in schema \(schema, privacy: .public)")
        return tables
    }

    func listViews(schema: String) async throws -> [DBObject] {
        if let cached = cachedViews[schema] { return cached }
        guard let client else { throw AppError.notConnected }

        let escapedSchema = schema.replacingOccurrences(of: "'", with: "''")
        let sql = """
            SELECT table_name
            FROM information_schema.views
            WHERE table_schema = '\(escapedSchema)'
            ORDER BY table_name
            """
        var views: [DBObject] = []
        let rows = try await client.query(PostgresQuery(unsafeSQL: sql))
        for try await row in rows {
            let (name,) = try row.decode(String.self)
            views.append(DBObject(schema: schema, name: name, type: .view))
        }
        cachedViews[schema] = views
        Log.db.info("Loaded \(views.count) views in schema \(schema, privacy: .public)")
        return views
    }

    func listMaterializedViews(schema: String) async throws -> [DBObject] {
        if let cached = cachedMatViews[schema] { return cached }
        guard let client else { throw AppError.notConnected }

        let escapedSchema = schema.replacingOccurrences(of: "'", with: "''")
        let sql = """
            SELECT matviewname
            FROM pg_matviews
            WHERE schemaname = '\(escapedSchema)'
            ORDER BY matviewname
            """
        var matViews: [DBObject] = []
        let rows = try await client.query(PostgresQuery(unsafeSQL: sql))
        for try await row in rows {
            let (name,) = try row.decode(String.self)
            matViews.append(DBObject(schema: schema, name: name, type: .materializedView))
        }
        cachedMatViews[schema] = matViews
        Log.db.info("Loaded \(matViews.count) materialized views in schema \(schema, privacy: .public)")
        return matViews
    }

    func listFunctions(schema: String) async throws -> [DBObject] {
        if let cached = cachedFunctions[schema] { return cached }
        guard let client else { throw AppError.notConnected }

        let escapedSchema = schema.replacingOccurrences(of: "'", with: "''")
        let pgVersion = await detectServerVersion(client: client)
        let kindFilter = pgVersion >= 11
            ? "p.prokind = 'f'"
            : "NOT p.proisagg AND NOT p.proiswindow"
        let sql = """
            SELECT p.proname || '(' || COALESCE(pg_get_function_identity_arguments(p.oid), '') || ')' AS func_sig
            FROM pg_proc p
            JOIN pg_namespace n ON p.pronamespace = n.oid
            WHERE n.nspname = '\(escapedSchema)'
              AND \(kindFilter)
              AND NOT EXISTS (SELECT 1 FROM pg_type t WHERE t.oid = p.prorettype AND t.typname = 'trigger')
            ORDER BY p.proname
            """
        var functions: [DBObject] = []
        let rows = try await client.query(PostgresQuery(unsafeSQL: sql))
        for try await row in rows {
            let (name,) = try row.decode(String.self)
            functions.append(DBObject(schema: schema, name: name, type: .function))
        }
        cachedFunctions[schema] = functions
        Log.db.info("Loaded \(functions.count) functions in schema \(schema, privacy: .public)")
        return functions
    }

    func listSequences(schema: String) async throws -> [DBObject] {
        if let cached = cachedSequences[schema] { return cached }
        guard let client else { throw AppError.notConnected }

        let escapedSchema = schema.replacingOccurrences(of: "'", with: "''")
        let sql = """
            SELECT sequence_name
            FROM information_schema.sequences
            WHERE sequence_schema = '\(escapedSchema)'
            ORDER BY sequence_name
            """
        var sequences: [DBObject] = []
        let rows = try await client.query(PostgresQuery(unsafeSQL: sql))
        for try await row in rows {
            let (name,) = try row.decode(String.self)
            sequences.append(DBObject(schema: schema, name: name, type: .sequence))
        }
        cachedSequences[schema] = sequences
        Log.db.info("Loaded \(sequences.count) sequences in schema \(schema, privacy: .public)")
        return sequences
    }

    func listTypes(schema: String) async throws -> [DBObject] {
        if let cached = cachedTypes[schema] { return cached }
        guard let client else { throw AppError.notConnected }

        let escapedSchema = schema.replacingOccurrences(of: "'", with: "''")
        let sql = """
            SELECT t.typname
            FROM pg_type t
            JOIN pg_namespace n ON t.typnamespace = n.oid
            WHERE n.nspname = '\(escapedSchema)'
              AND t.typtype IN ('e', 'c', 'd', 'r')
              AND NOT EXISTS (SELECT 1 FROM pg_class c WHERE c.reltype = t.oid AND c.relkind IN ('r','v','m','S'))
            ORDER BY t.typname
            """
        var types: [DBObject] = []
        let rows = try await client.query(PostgresQuery(unsafeSQL: sql))
        for try await row in rows {
            let (name,) = try row.decode(String.self)
            types.append(DBObject(schema: schema, name: name, type: .type))
        }
        cachedTypes[schema] = types
        Log.db.info("Loaded \(types.count) types in schema \(schema, privacy: .public)")
        return types
    }

    func listAllSchemaObjects(schema: String) async throws -> SchemaObjects {
        let esc = schema.replacingOccurrences(of: "'", with: "''")
        guard let client else { throw AppError.notConnected }

        // Detect server version for version-dependent queries
        let pgVersion = await detectServerVersion(client: client)

        // Run all queries in parallel
        async let tables = listTables(schema: schema)
        async let views = listViews(schema: schema)
        async let matViews = listMaterializedViews(schema: schema)
        async let functions = listFunctions(schema: schema)
        async let sequences = listSequences(schema: schema)
        async let types = listTypes(schema: schema)

        // Aggregates
        async let aggregates: [DBObject] = {
            let aggFilter = pgVersion >= 11 ? "p.prokind = 'a'" : "p.proisagg = true"
            let sql = """
                SELECT p.proname FROM pg_proc p
                JOIN pg_namespace n ON p.pronamespace = n.oid
                WHERE n.nspname = '\(esc)' AND \(aggFilter)
                ORDER BY p.proname
                """
            var result: [DBObject] = []
            let rows = try await client.query(PostgresQuery(unsafeSQL: sql))
            for try await row in rows { let (name,) = try row.decode(String.self); result.append(DBObject(schema: schema, name: name, type: .aggregate)) }
            return result
        }()

        // Collations
        async let collations: [DBObject] = {
            let sql = """
                SELECT c.collname FROM pg_collation c
                JOIN pg_namespace n ON c.collnamespace = n.oid
                WHERE n.nspname = '\(esc)'
                ORDER BY c.collname
                """
            var result: [DBObject] = []
            let rows = try await client.query(PostgresQuery(unsafeSQL: sql))
            for try await row in rows { let (name,) = try row.decode(String.self); result.append(DBObject(schema: schema, name: name, type: .collation)) }
            return result
        }()

        // Domains
        async let domains: [DBObject] = {
            let sql = """
                SELECT domain_name FROM information_schema.domains
                WHERE domain_schema = '\(esc)'
                ORDER BY domain_name
                """
            var result: [DBObject] = []
            let rows = try await client.query(PostgresQuery(unsafeSQL: sql))
            for try await row in rows { let (name,) = try row.decode(String.self); result.append(DBObject(schema: schema, name: name, type: .domain)) }
            return result
        }()

        // FTS Configurations
        async let ftsConfigs: [DBObject] = {
            let sql = """
                SELECT cfgname FROM pg_ts_config c
                JOIN pg_namespace n ON c.cfgnamespace = n.oid
                WHERE n.nspname = '\(esc)'
                ORDER BY cfgname
                """
            var result: [DBObject] = []
            let rows = try await client.query(PostgresQuery(unsafeSQL: sql))
            for try await row in rows { let (name,) = try row.decode(String.self); result.append(DBObject(schema: schema, name: name, type: .ftsConfiguration)) }
            return result
        }()

        // FTS Dictionaries
        async let ftsDicts: [DBObject] = {
            let sql = """
                SELECT dictname FROM pg_ts_dict d
                JOIN pg_namespace n ON d.dictnamespace = n.oid
                WHERE n.nspname = '\(esc)'
                ORDER BY dictname
                """
            var result: [DBObject] = []
            let rows = try await client.query(PostgresQuery(unsafeSQL: sql))
            for try await row in rows { let (name,) = try row.decode(String.self); result.append(DBObject(schema: schema, name: name, type: .ftsDictionary)) }
            return result
        }()

        // FTS Parsers
        async let ftsParsers: [DBObject] = {
            let sql = """
                SELECT prsname FROM pg_ts_parser p
                JOIN pg_namespace n ON p.prsnamespace = n.oid
                WHERE n.nspname = '\(esc)'
                ORDER BY prsname
                """
            var result: [DBObject] = []
            let rows = try await client.query(PostgresQuery(unsafeSQL: sql))
            for try await row in rows { let (name,) = try row.decode(String.self); result.append(DBObject(schema: schema, name: name, type: .ftsParser)) }
            return result
        }()

        // FTS Templates
        async let ftsTemplates: [DBObject] = {
            let sql = """
                SELECT tmplname FROM pg_ts_template t
                JOIN pg_namespace n ON t.tmplnamespace = n.oid
                WHERE n.nspname = '\(esc)'
                ORDER BY tmplname
                """
            var result: [DBObject] = []
            let rows = try await client.query(PostgresQuery(unsafeSQL: sql))
            for try await row in rows { let (name,) = try row.decode(String.self); result.append(DBObject(schema: schema, name: name, type: .ftsTemplate)) }
            return result
        }()

        // Foreign Tables
        async let foreignTables: [DBObject] = {
            let sql = """
                SELECT c.relname FROM pg_class c
                JOIN pg_namespace n ON c.relnamespace = n.oid
                WHERE n.nspname = '\(esc)' AND c.relkind = 'f'
                ORDER BY c.relname
                """
            var result: [DBObject] = []
            let rows = try await client.query(PostgresQuery(unsafeSQL: sql))
            for try await row in rows { let (name,) = try row.decode(String.self); result.append(DBObject(schema: schema, name: name, type: .foreignTable)) }
            return result
        }()

        // Operators
        async let operators: [DBObject] = {
            let sql = """
                SELECT oprname FROM pg_operator o
                JOIN pg_namespace n ON o.oprnamespace = n.oid
                WHERE n.nspname = '\(esc)'
                ORDER BY oprname
                """
            var result: [DBObject] = []
            let rows = try await client.query(PostgresQuery(unsafeSQL: sql))
            for try await row in rows { let (name,) = try row.decode(String.self); result.append(DBObject(schema: schema, name: name, type: .operator)) }
            return result
        }()

        // Procedures (PG 11+, prokind = 'p')
        async let procedures: [DBObject] = {
            guard pgVersion >= 11 else { return [] }
            let sql = """
                SELECT p.proname FROM pg_proc p
                JOIN pg_namespace n ON p.pronamespace = n.oid
                WHERE n.nspname = '\(esc)' AND p.prokind = 'p'
                ORDER BY p.proname
                """
            var result: [DBObject] = []
            let rows = try await client.query(PostgresQuery(unsafeSQL: sql))
            for try await row in rows { let (name,) = try row.decode(String.self); result.append(DBObject(schema: schema, name: name, type: .procedure)) }
            return result
        }()

        // Trigger Functions (return type is trigger)
        async let triggerFunctions: [DBObject] = {
            let kindFilter = pgVersion >= 11 ? "AND p.prokind = 'f'" : "AND NOT p.proisagg"
            let sql = """
                SELECT p.proname FROM pg_proc p
                JOIN pg_namespace n ON p.pronamespace = n.oid
                JOIN pg_type t ON p.prorettype = t.oid
                WHERE n.nspname = '\(esc)' AND t.typname = 'trigger' \(kindFilter)
                ORDER BY p.proname
                """
            var result: [DBObject] = []
            let rows = try await client.query(PostgresQuery(unsafeSQL: sql))
            for try await row in rows { let (name,) = try row.decode(String.self); result.append(DBObject(schema: schema, name: name, type: .triggerFunction)) }
            return result
        }()

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

        let escapedSchema = schema.replacingOccurrences(of: "'", with: "''")
        let escapedTable = table.replacingOccurrences(of: "'", with: "''")

        let sql = """
            SELECT column_name, ordinal_position, data_type, is_nullable, column_default,
                   character_maximum_length, udt_name, numeric_precision, numeric_scale,
                   is_identity, identity_generation
            FROM information_schema.columns
            WHERE table_schema = '\(escapedSchema)'
              AND table_name = '\(escapedTable)'
            ORDER BY ordinal_position
            """
        var columns: [ColumnInfo] = []
        let rows = try await client.query(PostgresQuery(unsafeSQL: sql))
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

        let escapedSchema = schema.replacingOccurrences(of: "'", with: "''")
        let escapedTable = table.replacingOccurrences(of: "'", with: "''")

        let sql = """
            SELECT a.attname
            FROM pg_index i
            JOIN pg_attribute a ON a.attrelid = i.indrelid AND a.attnum = ANY(i.indkey)
            JOIN pg_class c ON c.oid = i.indrelid
            JOIN pg_namespace n ON n.oid = c.relnamespace
            WHERE i.indisprimary
              AND n.nspname = '\(escapedSchema)'
              AND c.relname = '\(escapedTable)'
            ORDER BY a.attnum
            """
        var keys: [String] = []
        let rows = try await client.query(PostgresQuery(unsafeSQL: sql))
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

        let escapedSchema = schema.replacingOccurrences(of: "'", with: "''")
        let escapedTable = table.replacingOccurrences(of: "'", with: "''")

        let sql = """
            SELECT reltuples::bigint AS approx_count
            FROM pg_class c
            JOIN pg_namespace n ON n.oid = c.relnamespace
            WHERE n.nspname = '\(escapedSchema)'
              AND c.relname = '\(escapedTable)'
            """
        let rows = try await client.query(PostgresQuery(unsafeSQL: sql))
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

        // Determine effective host/port: reuse the active tunnel if present.
        var effectiveHost = newProfile.host
        var effectivePort = newProfile.port

        let tunnelIsActive = await sshTunnel.isActive
        if newProfile.useSSHTunnel && tunnelIsActive {
            effectiveHost = "127.0.0.1"
            effectivePort = Int(await sshTunnel.tunnelLocalPort)
        } else if newProfile.useSSHTunnel {
            // Tunnel is not active — start it now.
            let localPort = try await sshTunnel.start(
                sshHost: newProfile.sshHost,
                sshPort: newProfile.sshPort,
                sshUser: newProfile.sshUser,
                sshAuthMethod: newProfile.sshAuthMethod,
                sshKeyPath: newProfile.sshKeyPath,
                sshPassword: sshPassword,
                remoteHost: newProfile.host,
                remotePort: newProfile.port
            )
            effectiveHost = "127.0.0.1"
            effectivePort = Int(localPort)
        }

        let tls = Self.makeTLS(for: newProfile.sslMode)

        let config = PostgresClient.Configuration(
            host: effectiveHost,
            port: effectivePort,
            username: newProfile.username,
            password: password,
            database: newProfile.database,
            tls: tls
        )

        let newClient = PostgresClient(configuration: config)
        self.client = newClient

        runTask = Task {
            await newClient.run()
        }

        do {
            let rows = try await newClient.query("SELECT 1 AS ok")
            for try await _ in rows {}
        } catch {
            runTask?.cancel()
            runTask = nil
            client = nil
            throw AppError.connectionFailed(error.localizedDescription)
        }

        Log.db.info("Switched to database \(database, privacy: .public) on \(effectiveHost, privacy: .public):\(effectivePort)")
    }
}

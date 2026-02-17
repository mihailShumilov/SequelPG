import Foundation
import OSLog
import PostgresNIO

/// Protocol for database operations, enabling test mocking.
protocol PostgresClientProtocol: Sendable {
    func connect(profile: ConnectionProfile, password: String?) async throws
    func disconnect() async
    var isConnected: Bool { get async }
    func runQuery(_ sql: String, maxRows: Int, timeout: TimeInterval) async throws -> QueryResult
    func listSchemas() async throws -> [String]
    func listTables(schema: String) async throws -> [DBObject]
    func listViews(schema: String) async throws -> [DBObject]
    func getColumns(schema: String, table: String) async throws -> [ColumnInfo]
    func getPrimaryKeys(schema: String, table: String) async throws -> [String]
    func getApproximateRowCount(schema: String, table: String) async throws -> Int64
    func invalidateCache() async
    func listDatabases() async throws -> [String]
    func switchDatabase(to database: String, profile: ConnectionProfile, password: String?) async throws
}

/// The sole component that communicates with PostgreSQL via PostgresNIO.
actor DatabaseClient: PostgresClientProtocol {
    private var client: PostgresClient?
    private var runTask: Task<Void, Never>?

    // Introspection cache
    private var cachedSchemas: [String]?
    private var cachedTables: [String: [DBObject]] = [:]
    private var cachedViews: [String: [DBObject]] = [:]
    private var cachedColumns: [String: [ColumnInfo]] = [:]
    private var cachedPrimaryKeys: [String: [String]] = [:]

    var isConnected: Bool {
        client != nil
    }

    func connect(profile: ConnectionProfile, password: String?) async throws {
        await disconnect()

        let tls: PostgresClient.Configuration.TLS
        switch profile.sslMode {
        case .off:
            tls = .disable
        case .prefer:
            tls = .prefer(.makeClientConfiguration())
        case .require:
            tls = .require(.makeClientConfiguration())
        }

        let config = PostgresClient.Configuration(
            host: profile.host,
            port: profile.port,
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

    func disconnect() async {
        guard client != nil else { return }
        runTask?.cancel()
        runTask = nil
        client = nil
        await invalidateCache()
        Log.db.info("Disconnected")
    }

    func invalidateCache() async {
        cachedSchemas = nil
        cachedTables.removeAll()
        cachedViews.removeAll()
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

        let result: QueryResult = try await withThrowingTaskGroup(of: QueryResult.self) { group in
            group.addTask { [client] in
                try Task.checkCancellation()

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

            do {
                guard let result = try await group.next() else {
                    throw AppError.queryTimeout
                }
                group.cancelAll()
                return result
            } catch let error as AppError {
                throw error
            } catch let error as PSQLError {
                // Note: PSQLError does not expose sqlState directly, so we
                // parse String(reflecting:). This may break if PostgresNIO
                // changes its debug description format.
                let reflected = String(reflecting: error)
                if reflected.contains("sqlState: 23503") {
                    throw AppError.foreignKeyViolation(Self.formatPSQLError(error))
                }
                throw AppError.queryFailed(Self.formatPSQLError(error))
            } catch {
                throw AppError.queryFailed(String(reflecting: error))
            }
        }

        return result
    }

    // MARK: - Cell Decoding

    private static let dateFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
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
            if let v = try? cell.decode(Float.self) { return .text(String(v)) }
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
                let fmt = DateFormatter()
                fmt.dateFormat = "yyyy-MM-dd"
                return .text(fmt.string(from: v))
            }
        case .bytea:
            return .text("<binary>")
        default:
            break
        }

        // Fallback: try String decoding (works for text, varchar, json, jsonb, etc.)
        if let v = try? cell.decode(String.self) { return .text(v) }
        return .text("<binary>")
    }

    // MARK: - Error Formatting

    /// Extracts the human-readable message and detail from a PSQLError,
    /// falling back to the full reflected description.
    private static func formatPSQLError(_ error: PSQLError) -> String {
        // PSQLError exposes server info via String(reflecting:).
        // Parse out just the message and detail fields for a clean UX.
        let full = String(reflecting: error)

        // Try to extract "message: ..." from serverInfo
        var parts: [String] = []
        if let msgRange = full.range(of: "message: ") {
            let start = msgRange.upperBound
            let rest = full[start...]
            if let end = rest.range(of: ", ")?.lowerBound ?? rest.range(of: "]")?.lowerBound {
                parts.append(String(rest[..<end]))
            }
        }
        if let detRange = full.range(of: "detail: ") {
            let start = detRange.upperBound
            let rest = full[start...]
            if let end = rest.range(of: ", ")?.lowerBound ?? rest.range(of: "]")?.lowerBound {
                parts.append(String(rest[..<end]))
            }
        }

        return parts.isEmpty ? full : parts.joined(separator: "\n")
    }

    // MARK: - Introspection

    func listSchemas() async throws -> [String] {
        if let cached = cachedSchemas { return cached }
        guard let client else { throw AppError.notConnected }

        let sql = """
            SELECT schema_name
            FROM information_schema.schemata
            WHERE schema_name NOT IN ('pg_catalog', 'information_schema')
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

        let sql = """
            SELECT table_name
            FROM information_schema.tables
            WHERE table_schema = '\(schema.replacingOccurrences(of: "'", with: "''"))'
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

        let sql = """
            SELECT table_name
            FROM information_schema.views
            WHERE table_schema = '\(schema.replacingOccurrences(of: "'", with: "''"))'
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

    func getColumns(schema: String, table: String) async throws -> [ColumnInfo] {
        let cacheKey = "\(schema).\(table)"
        if let cached = cachedColumns[cacheKey] { return cached }
        guard let client else { throw AppError.notConnected }

        let pkNames = try await getPrimaryKeys(schema: schema, table: table)
        let pkSet = Set(pkNames)

        let escapedSchema = schema.replacingOccurrences(of: "'", with: "''")
        let escapedTable = table.replacingOccurrences(of: "'", with: "''")

        let sql = """
            SELECT column_name, ordinal_position, data_type, is_nullable, column_default, character_maximum_length
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
            let ordinal = try randomRow["ordinal_position"].decode(Int.self)
            let dataType = try randomRow["data_type"].decode(String.self)
            let nullable = try randomRow["is_nullable"].decode(String.self)
            let defaultVal = try? randomRow["column_default"].decode(String?.self)
            let maxLength = try? randomRow["character_maximum_length"].decode(Int?.self)

            columns.append(ColumnInfo(
                name: name,
                ordinalPosition: ordinal,
                dataType: dataType,
                isNullable: nullable == "YES",
                columnDefault: defaultVal ?? nil,
                characterMaximumLength: maxLength ?? nil,
                isPrimaryKey: pkSet.contains(name)
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
            return max(count, 0)
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

    func switchDatabase(to database: String, profile: ConnectionProfile, password: String?) async throws {
        var newProfile = profile
        newProfile.database = database
        try await connect(profile: newProfile, password: password)
    }
}

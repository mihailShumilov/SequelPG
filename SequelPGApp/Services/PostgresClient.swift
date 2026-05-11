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

    /// Decode a PostgresCell to CellValue. Dispatches through `formatBinary`
    /// for binary-format cells, falls back to PostgresNIO's String decoder for
    /// text-format cells (and unknown binary types), and renders the wire bytes
    /// as `<binary>` only when both paths give up.
    ///
    /// When adding support for a new PostgreSQL type: add a case to
    /// `formatBinary(buffer:type:)` so the binary wire bytes get a proper
    /// textual rendering instead of leaking through as garbled UTF-8.
    private static func decodeCellValue(_ cell: PostgresCell) -> CellValue {
        guard let bytes = cell.bytes else { return .null }

        if cell.format == .binary {
            var buf = bytes
            if let s = formatBinary(buffer: &buf, type: cell.dataType) {
                return .text(truncate(s))
            }
        }

        guard let v = try? cell.decode(String.self) else { return .text("<binary>") }
        return .text(truncate(v))
    }

    private static func truncate(_ s: String) -> String {
        s.count > 10_000 ? String(s.prefix(10_000)) + "…" : s
    }

    /// Recursive binary decoder. Maps PG's wire format for one value of `type`
    /// to a textual representation that mirrors PG's standard text output as
    /// closely as possible. Recursive paths (range / multirange / array) call
    /// back into this function for the element / subtype.
    ///
    /// Returns nil on:
    /// - unknown OID (caller falls back to String decoding)
    /// - short/malformed buffer (caller surfaces "<binary>")
    private static func formatBinary(buffer: inout ByteBuffer, type: PostgresDataType) -> String? {
        switch type {
        // ── Scalars ────────────────────────────────────────────────────
        case .bool:
            return buffer.readInteger(as: UInt8.self).map { $0 == 0 ? "false" : "true" }
        case .int2:
            return buffer.readInteger(as: Int16.self).map(String.init)
        case .int4:
            return buffer.readInteger(as: Int32.self).map(String.init)
        case .int8:
            return buffer.readInteger(as: Int64.self).map(String.init)
        case .float4:
            return buffer.readInteger(as: UInt32.self).map { String(Double(Float(bitPattern: $0))) }
        case .float8:
            return buffer.readInteger(as: UInt64.self).map { String(Double(bitPattern: $0)) }
        case .oid, .regclass, .regproc, .regtype, .regrole, .regnamespace,
             .regprocedure, .regoper, .regoperator, .regconfig, .regdictionary,
             .regcollation, .xid, .cid:
            return buffer.readInteger(as: UInt32.self).map(String.init)
        case .xid8:
            return buffer.readInteger(as: UInt64.self).map(String.init)
        case .pgLSN:
            guard let v = buffer.readInteger(as: UInt64.self) else { return nil }
            return String(format: "%X/%X", UInt32(v >> 32), UInt32(v & 0xFFFFFFFF))

        case .numeric:
            return (try? Decimal(from: &buffer, type: .numeric, format: .binary, context: .default))?.description
        case .money:
            guard let raw = buffer.readInteger(as: Int64.self) else { return nil }
            let neg = raw < 0
            let abs = raw == .min ? UInt64(Int64.max) + 1 : UInt64(Swift.abs(raw))
            return String(format: "%@%llu.%02llu", neg ? "-" : "", abs / 100, abs % 100)
        case .uuid:
            return (try? UUID(from: &buffer, type: .uuid, format: .binary, context: .default))?.uuidString

        // ── Strings (treat as bytes-of-UTF-8) ──────────────────────────
        case .text, .varchar, .bpchar, .char, .name, .cstring, .json, .xml:
            return buffer.readString(length: buffer.readableBytes)
        case .jsonb:
            // jsonb prefixes a 1-byte version (currently always 1).
            guard let ver: UInt8 = buffer.readInteger(), ver == 1 else { return nil }
            return buffer.readString(length: buffer.readableBytes)

        // ── Date / time / interval ─────────────────────────────────────
        case .date:
            // 4-byte signed days from 2000-01-01 (PG epoch).
            guard let days = buffer.readInteger(as: Int32.self) else { return nil }
            if days == Int32.max { return "infinity" }
            if days == Int32.min { return "-infinity" }
            let sec = TimeInterval(days) * 86_400 - pgEpochOffsetFromAppleEpoch
            return dateOnlyFormatter.string(from: Date(timeIntervalSinceReferenceDate: sec))
        case .timestamp, .timestamptz:
            guard let us = buffer.readInteger(as: Int64.self) else { return nil }
            if us == Int64.max { return "infinity" }
            if us == Int64.min { return "-infinity" }
            let sec = TimeInterval(us) / 1_000_000 - pgEpochOffsetFromAppleEpoch
            return dateFormatter.string(from: Date(timeIntervalSinceReferenceDate: sec))
        case .time:
            guard let us = buffer.readInteger(as: Int64.self) else { return nil }
            return formatTimeOfDay(us: us)
        case .timetz:
            guard let us = buffer.readInteger(as: Int64.self),
                  let zoneSec = buffer.readInteger(as: Int32.self) else { return nil }
            // PG sends the offset as seconds *west* of UTC; "+05:00" is -18000.
            return formatTimeOfDay(us: us) + formatTZOffset(secondsWestOfUTC: Int(zoneSec))
        case .interval:
            // Layout: 8-byte microseconds + 4-byte days + 4-byte months.
            guard let us = buffer.readInteger(as: Int64.self),
                  let days = buffer.readInteger(as: Int32.self),
                  let months = buffer.readInteger(as: Int32.self) else { return nil }
            return formatInterval(us: us, days: Int(days), months: Int(months))

        // ── Bit string ─────────────────────────────────────────────────
        case .bit, .varbit:
            // 4-byte length (in bits) + ceil(bits/8) bytes, MSB first.
            guard let bits = buffer.readInteger(as: Int32.self), bits >= 0 else { return nil }
            let byteCount = (Int(bits) + 7) / 8
            guard let bytes = buffer.readBytes(length: byteCount) else { return nil }
            var s = ""
            s.reserveCapacity(Int(bits))
            for i in 0 ..< Int(bits) {
                let bit = (bytes[i / 8] >> (7 - (i % 8))) & 1
                s.append(bit == 1 ? "1" : "0")
            }
            return s

        // ── Network ────────────────────────────────────────────────────
        case .inet, .cidr:
            return formatInet(buffer: &buffer, alwaysShowMask: type == .cidr)
        case .macaddr:
            return formatMacaddr(buffer: &buffer, byteCount: 6)
        case .macaddr8:
            return formatMacaddr(buffer: &buffer, byteCount: 8)

        // ── Geometric ──────────────────────────────────────────────────
        case .point:
            guard let x = readDouble(&buffer), let y = readDouble(&buffer) else { return nil }
            return "(\(x),\(y))"
        case .line:
            guard let a = readDouble(&buffer),
                  let b = readDouble(&buffer),
                  let c = readDouble(&buffer) else { return nil }
            return "{\(a),\(b),\(c)}"
        case .lseg:
            guard let x1 = readDouble(&buffer), let y1 = readDouble(&buffer),
                  let x2 = readDouble(&buffer), let y2 = readDouble(&buffer) else { return nil }
            return "[(\(x1),\(y1)),(\(x2),\(y2))]"
        case .box:
            guard let x1 = readDouble(&buffer), let y1 = readDouble(&buffer),
                  let x2 = readDouble(&buffer), let y2 = readDouble(&buffer) else { return nil }
            return "(\(x1),\(y1)),(\(x2),\(y2))"
        case .circle:
            guard let x = readDouble(&buffer), let y = readDouble(&buffer),
                  let r = readDouble(&buffer) else { return nil }
            return "<(\(x),\(y)),\(r)>"
        case .path:
            guard let closed: UInt8 = buffer.readInteger(),
                  let n = buffer.readInteger(as: Int32.self), n >= 0 else { return nil }
            var pts: [String] = []
            pts.reserveCapacity(Int(n))
            for _ in 0 ..< Int(n) {
                guard let x = readDouble(&buffer), let y = readDouble(&buffer) else { return nil }
                pts.append("(\(x),\(y))")
            }
            let body = pts.joined(separator: ",")
            // closed=1 → parenthesized, closed=0 → bracketed (open path).
            return closed == 0 ? "[\(body)]" : "(\(body))"
        case .polygon:
            guard let n = buffer.readInteger(as: Int32.self), n >= 0 else { return nil }
            var pts: [String] = []
            pts.reserveCapacity(Int(n))
            for _ in 0 ..< Int(n) {
                guard let x = readDouble(&buffer), let y = readDouble(&buffer) else { return nil }
                pts.append("(\(x),\(y))")
            }
            return "(\(pts.joined(separator: ",")))"

        // ── Bytea — skip rendering raw bytes ───────────────────────────
        case .bytea:
            return "<binary>"

        // ── Range types ────────────────────────────────────────────────
        case .int4Range:    return formatRange(buffer: &buffer, subtype: .int4)
        case .int8Range:    return formatRange(buffer: &buffer, subtype: .int8)
        case .numrange:     return formatRange(buffer: &buffer, subtype: .numeric)
        case .tsrange:      return formatRange(buffer: &buffer, subtype: .timestamp)
        case .tstzrange:    return formatRange(buffer: &buffer, subtype: .timestamptz)
        case .daterange:    return formatRange(buffer: &buffer, subtype: .date)

        // ── Multirange types ───────────────────────────────────────────
        case .int4multirange:   return formatMultirange(buffer: &buffer, subtype: .int4)
        case .int8multirange:   return formatMultirange(buffer: &buffer, subtype: .int8)
        case .nummultirange:    return formatMultirange(buffer: &buffer, subtype: .numeric)
        case .tsmultirange:     return formatMultirange(buffer: &buffer, subtype: .timestamp)
        case .tstzmultirange:   return formatMultirange(buffer: &buffer, subtype: .timestamptz)
        case .datemultirange:   return formatMultirange(buffer: &buffer, subtype: .date)

        // ── Arrays ─────────────────────────────────────────────────────
        // Element type comes from the array binary header itself, so we don't
        // need a per-array-OID switch — anything matching the array OID list
        // (or, conservatively, anything whose binary header parses) is fed
        // through `formatArray`.
        default:
            if isArrayOID(type) {
                return formatArray(buffer: &buffer)
            }
            // Unknown OIDs are most often user-defined composite types
            // (CREATE TYPE x AS (...)). Try parsing as a composite — the
            // binary layout is self-describing so a header that doesn't
            // look like a composite naturally fails the validation guards
            // and we fall through to the bytea label.
            if let s = formatComposite(buffer: &buffer) {
                return s
            }
            return nil
        }
    }

    /// Seconds between Foundation's reference date (2001-01-01 UTC) and PG's
    /// epoch (2000-01-01 UTC). 366 days; 2000 was a leap year.
    private static let pgEpochOffsetFromAppleEpoch: TimeInterval = 31_622_400

    private static func readDouble(_ buf: inout ByteBuffer) -> Double? {
        buf.readInteger(as: UInt64.self).map { Double(bitPattern: $0) }
    }

    /// Formats `us` (microseconds since midnight) as "HH:MM:SS" or
    /// "HH:MM:SS.uuuuuu" when fractional seconds are present.
    private static func formatTimeOfDay(us: Int64) -> String {
        let totalSec = us / 1_000_000
        let frac = us % 1_000_000
        let hh = totalSec / 3600
        let mm = (totalSec % 3600) / 60
        let ss = totalSec % 60
        if frac == 0 {
            return String(format: "%02lld:%02lld:%02lld", hh, mm, ss)
        }
        // Trim trailing zeros from the fractional part (matches PG's display).
        var fracStr = String(format: "%06lld", frac)
        while fracStr.last == "0" { fracStr.removeLast() }
        return String(format: "%02lld:%02lld:%02lld.%@", hh, mm, ss, fracStr)
    }

    /// Converts PG's "seconds west of UTC" timezone offset to a "+HH:MM" /
    /// "-HH:MM" suffix.
    private static func formatTZOffset(secondsWestOfUTC: Int) -> String {
        // east of UTC = -secondsWest
        let east = -secondsWestOfUTC
        let sign = east >= 0 ? "+" : "-"
        let abs = Swift.abs(east)
        let hh = abs / 3600
        let mm = (abs % 3600) / 60
        return String(format: "%@%02d:%02d", sign, hh, mm)
    }

    /// Renders a PG interval (months / days / microseconds) in PG's standard
    /// text form, e.g. "1 year 2 mons 3 days 04:05:06.789".
    private static func formatInterval(us: Int64, days: Int, months: Int) -> String {
        var parts: [String] = []
        if months != 0 {
            let years = months / 12
            let mons = months % 12
            if years != 0 { parts.append("\(years) year\(Swift.abs(years) == 1 ? "" : "s")") }
            if mons != 0 { parts.append("\(mons) mon\(Swift.abs(mons) == 1 ? "" : "s")") }
        }
        if days != 0 { parts.append("\(days) day\(Swift.abs(days) == 1 ? "" : "s")") }
        if us != 0 {
            let neg = us < 0
            let absUs = neg ? -us : us
            let totalSec = absUs / 1_000_000
            let frac = absUs % 1_000_000
            let hh = totalSec / 3600
            let mm = (totalSec % 3600) / 60
            let ss = totalSec % 60
            let signed = (neg ? "-" : "") + String(format: "%02lld:%02lld:%02lld", hh, mm, ss)
            if frac == 0 {
                parts.append(signed)
            } else {
                var fracStr = String(format: "%06lld", frac)
                while fracStr.last == "0" { fracStr.removeLast() }
                parts.append("\(signed).\(fracStr)")
            }
        }
        return parts.isEmpty ? "00:00:00" : parts.joined(separator: " ")
    }

    /// Decodes a PG range value. Layout: 1-byte flags + (per non-infinite
    /// bound) 4-byte length + subtype payload. Empty ranges short-circuit
    /// before any bound bytes are read.
    private static func formatRange(buffer: inout ByteBuffer, subtype: PostgresDataType) -> String? {
        guard let flags: UInt8 = buffer.readInteger() else { return nil }
        if flags & 0x01 != 0 { return "empty" } // RANGE_EMPTY

        let lowerInc = flags & 0x02 != 0
        let upperInc = flags & 0x04 != 0
        let lowerInf = flags & 0x08 != 0
        let upperInf = flags & 0x10 != 0

        func readBound() -> String? {
            guard let len = buffer.readInteger(as: Int32.self), len >= 0 else { return nil }
            guard var sub = buffer.readSlice(length: Int(len)) else { return nil }
            return formatBinary(buffer: &sub, type: subtype)
        }

        let lo = lowerInf ? "" : (readBound() ?? "?")
        let hi = upperInf ? "" : (readBound() ?? "?")
        return "\(lowerInc ? "[" : "(")\(lo),\(hi)\(upperInc ? "]" : ")")"
    }

    /// Decodes a PG composite (record / row) binary payload. Layout:
    /// 4-byte field count, then per field: 4-byte type OID + 4-byte length
    /// (or -1 for NULL) + N bytes of subtype binary. Renders as PG's text
    /// form, e.g. `(field1,field2,...)`. NULL fields show as empty between
    /// commas to match PG's psql output.
    ///
    /// Field count is bounded to a sane upper limit so a buffer that *isn't*
    /// a composite (e.g. random bytea) doesn't sail through validation.
    /// Returns nil if the header looks wrong; caller falls back to `<binary>`.
    private static func formatComposite(buffer: inout ByteBuffer) -> String? {
        let start = buffer.readerIndex
        guard let fieldCount = buffer.readInteger(as: Int32.self),
              fieldCount >= 0, fieldCount <= 512
        else {
            buffer.moveReaderIndex(to: start)
            return nil
        }
        if fieldCount == 0 { return "()" }

        var fields: [String] = []
        fields.reserveCapacity(Int(fieldCount))
        for _ in 0 ..< Int(fieldCount) {
            guard let fieldOID = buffer.readInteger(as: UInt32.self),
                  let len = buffer.readInteger(as: Int32.self)
            else {
                buffer.moveReaderIndex(to: start)
                return nil
            }
            if len < 0 {
                fields.append("")
                continue
            }
            guard var sub = buffer.readSlice(length: Int(len)) else {
                buffer.moveReaderIndex(to: start)
                return nil
            }
            let raw = formatBinary(buffer: &sub, type: PostgresDataType(fieldOID)) ?? ""
            fields.append(quoteCompositeField(raw))
        }
        return "(\(fields.joined(separator: ",")))"
    }

    /// Quotes a composite field the way PG does in its text output: bare
    /// content for simple values, double-quoted with backslash escapes when
    /// the value contains a comma, parenthesis, quote, backslash, or
    /// whitespace.
    private static func quoteCompositeField(_ s: String) -> String {
        if s.isEmpty { return "" }
        let needsQuote = s.contains(where: { c in
            c == "," || c == "(" || c == ")" || c == "\"" || c == "\\" || c.isWhitespace
        })
        if !needsQuote { return s }
        let escaped = s
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }

    /// Decodes a PG multirange — count followed by length-prefixed range
    /// payloads. Renders as "{[a,b),[c,d)}".
    private static func formatMultirange(buffer: inout ByteBuffer, subtype: PostgresDataType) -> String? {
        guard let count = buffer.readInteger(as: Int32.self), count >= 0 else { return nil }
        var ranges: [String] = []
        ranges.reserveCapacity(Int(count))
        for _ in 0 ..< Int(count) {
            guard let len = buffer.readInteger(as: Int32.self), len >= 0,
                  var sub = buffer.readSlice(length: Int(len)),
                  let r = formatRange(buffer: &sub, subtype: subtype)
            else { return nil }
            ranges.append(r)
        }
        return "{\(ranges.joined(separator: ","))}"
    }

    /// Decodes a PG array. Header: ndim, hasnull, element OID, then per-dim
    /// (dim length, lower bound), then (length, payload) per element. NULL
    /// elements are signalled by length = -1.
    private static func formatArray(buffer: inout ByteBuffer) -> String? {
        guard let ndim = buffer.readInteger(as: Int32.self),
              let _ = buffer.readInteger(as: Int32.self), // hasnull flag — informational, we just check len == -1 per element
              let elemOID = buffer.readInteger(as: UInt32.self),
              ndim >= 0, ndim <= 6
        else { return nil }

        if ndim == 0 { return "{}" }

        var dims: [Int] = []
        dims.reserveCapacity(Int(ndim))
        for _ in 0 ..< Int(ndim) {
            guard let dimLen = buffer.readInteger(as: Int32.self),
                  let _ = buffer.readInteger(as: Int32.self), // lower bound — discarded; PG default is 1
                  dimLen >= 0
            else { return nil }
            dims.append(Int(dimLen))
        }

        let total = dims.reduce(1, *)
        let elemType = PostgresDataType(elemOID)
        var elements: [String] = []
        elements.reserveCapacity(total)
        for _ in 0 ..< total {
            guard let len = buffer.readInteger(as: Int32.self) else { return nil }
            if len < 0 {
                elements.append("NULL")
                continue
            }
            guard var sub = buffer.readSlice(length: Int(len)) else { return nil }
            elements.append(formatBinary(buffer: &sub, type: elemType) ?? "?")
        }

        return formatNestedArray(elements: elements[...], dims: dims, depth: 0)
    }

    /// Recursively reshapes a flat list of formatted elements into PG's nested
    /// `{{a,b},{c,d}}` array text form.
    private static func formatNestedArray(elements: ArraySlice<String>, dims: [Int], depth: Int) -> String {
        if depth == dims.count - 1 {
            return "{" + elements.map(quoteArrayElement).joined(separator: ",") + "}"
        }
        let chunkSize = dims.dropFirst(depth + 1).reduce(1, *)
        var pieces: [String] = []
        pieces.reserveCapacity(dims[depth])
        var idx = elements.startIndex
        for _ in 0 ..< dims[depth] {
            let next = elements.index(idx, offsetBy: chunkSize)
            pieces.append(formatNestedArray(elements: elements[idx ..< next], dims: dims, depth: depth + 1))
            idx = next
        }
        return "{" + pieces.joined(separator: ",") + "}"
    }

    /// Quotes an array element the way PG does: bare for plain content, double
    /// quoted with backslash escapes for content containing punctuation.
    private static func quoteArrayElement(_ s: String) -> String {
        if s == "NULL" { return "NULL" }
        let needsQuote = s.isEmpty || s.contains(where: { c in
            c == "," || c == "{" || c == "}" || c == "\"" || c == "\\" || c.isWhitespace
        })
        if !needsQuote { return s }
        let escaped = s
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }

    /// Decodes an `inet`/`cidr` payload from the supplied buffer (shared with
    /// the recursive range/array decoders).
    private static func formatInet(buffer: inout ByteBuffer, alwaysShowMask: Bool) -> String? {
        guard let family: UInt8 = buffer.readInteger(),
              let bits: UInt8 = buffer.readInteger(),
              let _: UInt8 = buffer.readInteger(),
              let nb: UInt8 = buffer.readInteger(),
              let bytes = buffer.readBytes(length: Int(nb))
        else { return nil }

        let address: String
        let maxBits: UInt8
        switch family {
        case 2:
            guard bytes.count == 4 else { return nil }
            address = bytes.map(String.init).joined(separator: ".")
            maxBits = 32
        case 3:
            guard bytes.count == 16 else { return nil }
            address = formatIPv6(bytes: bytes)
            maxBits = 128
        default:
            return nil
        }
        return (alwaysShowMask || bits != maxBits) ? "\(address)/\(bits)" : address
    }

    /// Formats 16 raw IPv6 bytes as a colon-separated string, collapsing the
    /// longest run of zero groups (length ≥ 2) to "::" per RFC 5952.
    static func formatIPv6(bytes: [UInt8]) -> String {
        var groups: [UInt16] = []
        groups.reserveCapacity(8)
        for i in stride(from: 0, to: 16, by: 2) {
            groups.append((UInt16(bytes[i]) << 8) | UInt16(bytes[i + 1]))
        }

        var bestStart = -1, bestLen = 0
        var curStart = -1, curLen = 0
        for (i, g) in groups.enumerated() {
            if g == 0 {
                if curStart == -1 { curStart = i }
                curLen += 1
                if curLen > bestLen { bestStart = curStart; bestLen = curLen }
            } else {
                curStart = -1; curLen = 0
            }
        }

        let hex: (UInt16) -> String = { String($0, radix: 16) }
        guard bestLen >= 2 else {
            return groups.map(hex).joined(separator: ":")
        }
        let head = groups[0 ..< bestStart].map(hex).joined(separator: ":")
        let tail = groups[(bestStart + bestLen) ..< groups.count].map(hex).joined(separator: ":")
        return "\(head)::\(tail)"
    }

    /// Formats a `macaddr`/`macaddr8` body (already past any preamble).
    private static func formatMacaddr(buffer: inout ByteBuffer, byteCount: Int) -> String? {
        guard let bytes = buffer.readBytes(length: byteCount), bytes.count == byteCount else { return nil }
        return bytes.map { String(format: "%02x", $0) }.joined(separator: ":")
    }

    /// Whether the given OID is a built-in array type. Composite/user-defined
    /// arrays (e.g. _user_role for an enum array) carry dynamic OIDs; for
    /// those we fall back to PostgresNIO's String decoder (PG happens to send
    /// arrays as text-format-friendly bytes for many common cases) rather
    /// than mis-parse a composite as an array.
    private static func isArrayOID(_ type: PostgresDataType) -> Bool {
        switch type {
        case .boolArray, .byteaArray, .charArray, .nameArray, .int2Array, .int2vectorArray,
             .int4Array, .regprocArray, .textArray, .tidArray, .xidArray, .cidArray,
             .oidvectorArray, .bpcharArray, .varcharArray, .int8Array, .pointArray,
             .lsegArray, .pathArray, .boxArray, .float4Array, .float8Array, .polygonArray,
             .oidArray, .aclitemArray, .macaddrArray, .inetArray, .timestampArray,
             .dateArray, .timeArray, .timestamptzArray, .intervalArray, .numericArray,
             .cstringArray, .timetzArray, .bitArray, .varbitArray, .refcursorArray,
             .regprocedureArray, .regoperArray, .regoperatorArray, .regclassArray,
             .regtypeArray, .recordArray, .pgLSNArray, .tsvectorArray, .gtsvectorArray,
             .tsqueryArray, .regconfigArray, .regdictionaryArray, .jsonbArray,
             .numrangeArray, .tsrangeArray, .tstzrangeArray, .daterangeArray,
             .jsonpathArray, .regnamespaceArray, .regroleArray, .regcollationArray,
             .int4multirangeArray, .nummultirangeArray, .tsmultirangeArray,
             .tstzmultirangeArray, .datemultirangeArray, .int8multirangeArray,
             .xid8Array, .xmlArray, .jsonArray, .lineArray, .cidrArray, .circleArray,
             .macaddr8Array, .moneyArray, .int4RangeArray, .int8RangeArray:
            return true
        default:
            return false
        }
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

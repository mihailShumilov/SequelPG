import Foundation
import OSLog
import PostgresNIO

/// Protocol for database operations, enabling test mocking.
protocol PostgresClientProtocol: Sendable {
    func connect(profile: ConnectionProfile, password: String?) async throws
    func disconnect() async
    var isConnected: Bool { get async }
    func runQuery(_ sql: String, maxRows: Int, timeout: TimeInterval) async throws -> QueryResult
}

/// The sole component that communicates with PostgreSQL via PostgresNIO.
actor DatabaseClient: PostgresClientProtocol {
    private var client: PostgresClient?
    private var runTask: Task<Void, Never>?

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
        Log.db.info("Disconnected")
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

                    // Convert cells to CellValue
                    var cellValues: [CellValue] = []
                    for i in 0 ..< randomRow.count {
                        let cell = randomRow[i]
                        if cell.bytes == nil {
                            cellValues.append(.null)
                        } else if let str = try? cell.decode(String.self) {
                            cellValues.append(.text(str))
                        } else {
                            cellValues.append(.text("<binary>"))
                        }
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

        return result
    }
}

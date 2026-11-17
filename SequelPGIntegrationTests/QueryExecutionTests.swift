import XCTest
@testable import SequelPG

/// `DatabaseClient.runQuery` / `explainQuery` against real servers: row caps,
/// timeouts, cancellation, error mapping, DML, identifiers, EXPLAIN.
final class QueryExecutionTests: IntegrationTestCase {
    func testSelectReturnsColumnsAndRowsOnEveryServer() async throws {
        for server in TestCluster.Server.allCases {
            let client = try await connect(server)
            let result = try await client.exec("SELECT id, name, age FROM qa.people WHERE id <= 3 ORDER BY id")
            XCTAssertEqual(result.columns, ["id", "name", "age"], "\(server)")
            XCTAssertEqual(result.column("name"), ["Person 01", "Person 02", "Person 03"], "\(server)")
            XCTAssertFalse(result.isTruncated, "\(server)")
        }
    }

    func testRowCapTruncatesLargeResults() async throws {
        let client = try await connect()
        let result = try await client.runQuery("SELECT * FROM qa.big_numbers ORDER BY id", maxRows: 2000, timeout: 30)
        XCTAssertEqual(result.rowCount, 2000)
        XCTAssertTrue(result.isTruncated)
        XCTAssertEqual(result.column("id").last ?? nil, "2000")
    }

    func testEmptyResultHasNoRows() async throws {
        let client = try await connect()
        let result = try await client.exec("SELECT * FROM qa.people WHERE false")
        XCTAssertEqual(result.rowCount, 0)
    }

    func testTimeoutCancelsLongQuery() async throws {
        let client = try await connect()
        let start = Date()
        let error = await assertThrowsAsync { try await client.runQuery("SELECT qa.slow(5)", maxRows: 1, timeout: 1) }
        guard case .queryTimeout? = error as? AppError else {
            // The server-side statement_timeout may win the race; both are acceptable.
            XCTAssertTrue(
                message(of: error).localizedCaseInsensitiveContains("statement timeout"),
                "Expected a timeout, got: \(message(of: error))"
            )
            return
        }
        XCTAssertLessThan(Date().timeIntervalSince(start), 4)
    }

    func testStatementTimeoutIsRestoredOnPooledConnections() async throws {
        let client = try await connect()
        // A few timed queries so several pool connections get a SET/RESET.
        for _ in 0 ..< 4 {
            _ = try await client.runQuery("SELECT 1", maxRows: 1, timeout: 2)
        }
        _ = await assertThrowsAsync { try await client.runQuery("SELECT qa.slow(3)", maxRows: 1, timeout: 1) }
        for _ in 0 ..< 6 {
            let value = try await client.runQuery("SHOW statement_timeout", maxRows: 1, timeout: 0)
            XCTAssertEqual(value.rows.first?.first, .text("0"), "statement_timeout leaked onto a pooled connection")
        }
    }

    func testCancellationStopsWaitingAndKeepsClientUsable() async throws {
        let client = try await connect()
        let task = Task { try await client.runQuery("SELECT qa.slow(3)", maxRows: 1, timeout: 0) }
        try await Task.sleep(nanoseconds: 300_000_000)
        let start = Date()
        task.cancel()
        let result = await task.result
        switch result {
        case .success:
            XCTFail("Cancelled query must not succeed")
        case let .failure(error):
            XCTAssertTrue(error is CancellationError, "Expected CancellationError, got \(error)")
        }
        let waited = Date().timeIntervalSince(start)
        XCTExpectFailure("Known issue: Stop cancels only the Swift task; without a server-side cancel the call returns when the query finishes") {
            XCTAssertLessThan(waited, 1.0, "Stop must return promptly")
        }
        let one = try await client.scalar("SELECT 1")
        XCTAssertEqual(one, "1")
    }

    func testSyntaxErrorIsReportedVerbatim() async throws {
        let client = try await connect()
        let error = await assertThrowsAsync { try await client.exec("SELEC 1") }
        guard case .queryFailed? = error as? AppError else {
            return XCTFail("Expected queryFailed, got \(String(describing: error))")
        }
        XCTAssertTrue(message(of: error).contains("syntax error"), message(of: error))
    }

    func testMultipleStatementsAreRejected() async throws {
        // The extended query protocol runs one statement per call; the editor
        // sends the buffer as-is. Pins the current behavior so a future
        // statement splitter is a deliberate change.
        let client = try await connect()
        let error = await assertThrowsAsync { try await client.exec("SELECT 1; SELECT 2") }
        XCTAssertTrue(message(of: error).localizedCaseInsensitiveContains("multiple commands"), message(of: error))
    }

    func testUnknownTableErrorNamesTheRelation() async throws {
        let client = try await connect()
        let error = await assertThrowsAsync { try await client.exec("SELECT * FROM qa.nope") }
        XCTAssertTrue(message(of: error).contains("qa.nope"), message(of: error))
    }

    func testDMLAndConstraintErrorsInScratchSchema() async throws {
        let client = try await connect()
        let s = quoteIdent(try await makeScratchSchema(on: client))
        try await client.exec("CREATE TABLE \(s).parent (id int PRIMARY KEY)")
        try await client.exec("CREATE TABLE \(s).child (id int PRIMARY KEY, parent_id int REFERENCES \(s).parent(id))")

        let inserted = try await client.exec("INSERT INTO \(s).parent VALUES (1), (2) RETURNING id")
        XCTAssertEqual(inserted.column("id"), ["1", "2"])
        try await client.exec("INSERT INTO \(s).child VALUES (10, 1)")

        let fkError = await assertThrowsAsync { try await client.exec("DELETE FROM \(s).parent WHERE id = 1") }
        guard case .foreignKeyViolation? = fkError as? AppError else {
            return XCTFail("Expected foreignKeyViolation, got \(String(describing: fkError))")
        }

        let dupError = await assertThrowsAsync { try await client.exec("INSERT INTO \(s).parent VALUES (2)") }
        XCTAssertTrue(message(of: dupError).contains("duplicate key"), message(of: dupError))

        let updated = try await client.exec("UPDATE \(s).parent SET id = 3 WHERE id = 2")
        XCTAssertEqual(updated.rowCount, 0, "UPDATE without RETURNING yields no rows")
        let ids = try await client.exec("SELECT id FROM \(s).parent ORDER BY id")
        XCTAssertEqual(ids.column("id"), ["1", "3"])
    }

    func testFailedStatementDoesNotPoisonPool() async throws {
        let client = try await connect()
        _ = await assertThrowsAsync { try await client.exec("SELECT 1/0") }
        for _ in 0 ..< 5 {
            let one = try await client.scalar("SELECT 1")
            XCTAssertEqual(one, "1")
        }
    }

    func testQuotedIdentifiersAndUnicodeRoundTrip() async throws {
        let client = try await connect()
        let result = try await client.exec("SELECT * FROM qa.\"Weird Table\" ORDER BY 1")
        XCTAssertEqual(result.columns, ["Mixed Case", "with space", "quote\"d", "кириллица"])
        XCTAssertEqual(result.column("кириллица"), ["привет", "мир", nil])
        XCTAssertEqual(result.column("with space").last ?? nil, "emoji 🐘")
        XCTAssertEqual(result.column("quote\"d"), ["it's", "\"dq\"", nil])
    }

    func testFunctionWithNoticeReturnsValue() async throws {
        let client = try await connect()
        let value = try await client.scalar("SELECT qa.noisy()")
        XCTAssertEqual(value, "7")
    }

    func testLongTextIsCappedForDisplay() async throws {
        let client = try await connect()
        let value = try await client.scalar("SELECT repeat('x', 20000)")
        XCTAssertEqual(value?.count, 10_001, "10 000 characters plus an ellipsis")
        XCTAssertTrue(value?.hasSuffix("…") == true)
    }

    func testExplainReturnsParsedPlan() async throws {
        for server in TestCluster.Server.allCases {
            let client = try await connect(server)
            let plan = try await client.explainQuery(
                "SELECT * FROM qa.people WHERE id = 1", analyze: false, buffers: false, timeout: 10
            )
            XCTAssertFalse(plan.root.nodeType.isEmpty, "\(server)")
            XCTAssertFalse(plan.didAnalyze, "\(server)")
            XCTAssertNil(plan.executionTime, "\(server)")
        }
    }

    func testExplainAnalyzeIncludesTimings() async throws {
        let client = try await connect()
        let plan = try await client.explainQuery(
            "SELECT count(*) FROM qa.big_numbers", analyze: true, buffers: true, timeout: 30
        )
        XCTAssertTrue(plan.didAnalyze)
        XCTAssertNotNil(plan.executionTime)
    }

    func testPoolRecoversAfterBackendTermination() async throws {
        // Use the md5 role so terminating its sessions can't hit other clients.
        let victim = try await connect(.pg18, role: .md5)
        let pidBefore = try await victim.scalar("SELECT pg_backend_pid()")
        let admin = try await connect(.pg18, role: .scram)
        _ = try await admin.exec(
            "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE usename = '\(TestCluster.user(.md5))'"
        )
        try await Task.sleep(nanoseconds: 300_000_000)

        // The pool drops the dead connection and dials a new one.
        let pidAfter = try await victim.scalar("SELECT pg_backend_pid()")
        XCTAssertNotEqual(pidBefore, pidAfter)
        let connected = await victim.isConnected
        XCTAssertTrue(connected)
    }

    func testServerShutdownOfSessionSurfacesAsError() async throws {
        // A statement that kills its own backend: the in-flight query must
        // fail with a connection error rather than hang.
        let client = try await connect(.pg18, role: .md5)
        let error = await assertThrowsAsync {
            try await client.exec("SELECT pg_terminate_backend(pg_backend_pid())")
        }
        XCTAssertFalse(message(of: error).isEmpty)
    }
}

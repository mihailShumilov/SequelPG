import XCTest
@testable import SequelPG

/// `DatabaseClient.runReadOnlyQuery` (the MCP server's query path) against
/// real servers: writes fail, nothing leaks onto pooled connections, and
/// cancellation never leaves a transaction open.
final class MCPReadOnlyQueryTests: IntegrationTestCase {
    func testReadsWorkAndRunInReadOnlyTransactionOnEveryServer() async throws {
        for server in TestCluster.Server.allCases {
            let client = try await connect(server)
            let rows = try await client.runReadOnlyQuery(
                "SELECT id FROM qa.people WHERE id <= 2 ORDER BY id", maxRows: 10, timeout: 5
            )
            XCTAssertEqual(rows.column("id"), ["1", "2"], "\(server)")
            let mode = try await client.runReadOnlyQuery("SHOW transaction_read_only", maxRows: 1, timeout: 5)
            XCTAssertEqual(mode.rows.first?.first, .text("on"), "\(server)")
        }
    }

    func testWritesAndDDLFailOnEveryServer() async throws {
        for server in TestCluster.Server.allCases {
            let client = try await connect(server)
            let schema = try await makeScratchSchema(on: client)
            try await client.exec("CREATE TABLE \(schema).t (id int)")
            for sql in [
                "INSERT INTO \(schema).t VALUES (1)",
                "UPDATE qa.people SET age = age",
                "CREATE TABLE \(schema).u (id int)",
                "WITH x AS (DELETE FROM \(schema).t RETURNING 1) SELECT * FROM x",
                "SELECT nextval('qa.people_id_seq')",
            ] {
                let error = await assertThrowsAsync { try await client.runReadOnlyQuery(sql, maxRows: 1, timeout: 5) }
                XCTAssertTrue(message(of: error).contains("read-only transaction"), "\(server) \(sql): \(message(of: error))")
            }
            let count = try await client.exec("SELECT count(*) FROM \(schema).t")
            XCTAssertEqual(count.rows.first?.first, .text("0"), "\(server)")
        }
    }

    func testGuardRejectsBeforeReachingTheServer() async throws {
        let client = try await connect(.pg18)
        for sql in ["SELECT 1; SELECT 2", "COMMIT", "COPY (SELECT 1) TO STDOUT", "SET search_path = qa"] {
            let error = await assertThrowsAsync { try await client.runReadOnlyQuery(sql, maxRows: 1, timeout: 5) }
            guard case .validationFailed? = error as? AppError else {
                return XCTFail("\(sql): expected a validation error, got \(message(of: error))")
            }
        }
    }

    func testTimeoutAndFailuresLeaveNoStateOnPooledConnections() async throws {
        let client = try await connect()
        _ = await assertThrowsAsync { try await client.runReadOnlyQuery("SELECT qa.slow(3)", maxRows: 1, timeout: 1) }
        _ = await assertThrowsAsync { try await client.runReadOnlyQuery("SELECT 1/0", maxRows: 1, timeout: 5) }
        for _ in 0 ..< 3 {
            _ = try await client.runReadOnlyQuery("SELECT 1", maxRows: 1, timeout: 2)
        }
        for _ in 0 ..< 6 {
            let timeout = try await client.runQuery("SHOW statement_timeout", maxRows: 1, timeout: 0)
            XCTAssertEqual(timeout.rows.first?.first, .text("0"), "statement_timeout leaked onto a pooled connection")
            let mode = try await client.runQuery("SHOW transaction_read_only", maxRows: 1, timeout: 0)
            XCTAssertEqual(mode.rows.first?.first, .text("off"), "a pooled connection stayed in a read-only transaction")
        }
        try await assertNoIdleTransactions(client)
    }

    func testCancellationRollsBack() async throws {
        let client = try await connect()
        let task = Task { try await client.runReadOnlyQuery("SELECT qa.slow(10)", maxRows: 1, timeout: 30) }
        try await Task.sleep(nanoseconds: 500_000_000)
        let start = Date()
        task.cancel()
        _ = await task.result
        XCTAssertLessThan(Date().timeIntervalSince(start), 3)
        try await Task.sleep(nanoseconds: 300_000_000)
        try await assertNoIdleTransactions(client)
        let after = try await client.runReadOnlyQuery("SELECT 42", maxRows: 1, timeout: 5)
        XCTAssertEqual(after.rows.first?.first, .text("42"))
    }

    func testCommentEndingInCarriageReturnCantSmuggleCopy() async throws {
        let client = try await connect()
        let sql = "--x\rCOPY (SELECT 1) TO PROGRAM 'true' /*\nSELECT */"
        let error = await assertThrowsAsync { try await client.runReadOnlyQuery(sql, maxRows: 1, timeout: 5) }
        guard case .validationFailed? = error as? AppError else {
            return XCTFail("expected a validation error, got \(message(of: error))")
        }
    }

    func testAdvisoryLocksAreReleasedAfterEachQuery() async throws {
        let client = try await connect()
        for _ in 0 ..< 4 {
            _ = try await client.runReadOnlyQuery("SELECT pg_advisory_lock(424242)", maxRows: 1, timeout: 5)
        }
        let held = try await client.exec(
            "SELECT count(*) FROM pg_locks WHERE locktype = 'advisory' AND objid = 424242 AND granted"
        )
        XCTAssertEqual(held.rows.first?.first, .text("0"), "an advisory lock outlived its MCP query")
    }

    func testPoolRefusesSuperusersAndAcceptsPlainRoles() async throws {
        try TestCluster.require([.pg18])
        let keychain = InMemoryKeychainService()
        let pool = MCPSessionPool(keychain: keychain)
        addTeardownBlock { await pool.closeAll() }

        let superuser = TestCluster.profile(.pg18, role: .scram)
        try keychain.save(password: TestCluster.password(.scram) ?? "", forKey: superuser.keychainKey)
        let error = await assertThrowsAsync { try await pool.client(for: superuser) }
        XCTAssertTrue(message(of: error).contains("superuser"), message(of: error))

        let plain = TestCluster.profile(.pg18, role: .readonly)
        try keychain.save(password: TestCluster.password(.readonly) ?? "", forKey: plain.keychainKey)
        let client = try await pool.client(for: plain)
        let rows = try await client.runReadOnlyQuery("SELECT count(*) FROM qa.people", maxRows: 1, timeout: 5)
        XCTAssertEqual(rows.rows.count, 1)
    }

    func testToolboxDescribesTableAsPlainRole() async throws {
        try TestCluster.require([.pg18])
        let keychain = InMemoryKeychainService()
        let suite = "MCPReadOnlyQueryTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        let profile = TestCluster.profile(.pg18, role: .readonly)
        try keychain.save(password: TestCluster.password(.readonly) ?? "", forKey: profile.keychainKey)
        let store = ConnectionStore(defaults: defaults)
        store.save([profile])
        let authorization = MCPAuthorizationStore(keychain: keychain)
        authorization.setAccess(.readOnly, for: profile.id)
        let pool = MCPSessionPool(keychain: keychain)
        addTeardownBlock { await pool.closeAll() }
        let toolbox = MCPToolbox(store: store, authorization: authorization, pool: pool)

        let result = await toolbox.callTool("describe_table", arguments: [
            "connection": .string(profile.id.uuidString), "schema": "qa", "table": "people",
        ], client: nil)
        XCTAssertFalse(result.isError, result.text)
        XCTAssertTrue(result.text.contains("- name text NOT NULL"), result.text)
        XCTAssertTrue(result.text.contains("people_pkey"), result.text)
    }

    /// No session of this user is left `idle in transaction`.
    private func assertNoIdleTransactions(_ client: DatabaseClient, file: StaticString = #filePath,
                                          line: UInt = #line) async throws
    {
        let idle = try await client.runQuery("""
            SELECT count(*) FROM pg_stat_activity
            WHERE usename = current_user AND pid <> pg_backend_pid() AND state LIKE 'idle in transaction%'
            """, maxRows: 1, timeout: 5)
        XCTAssertEqual(idle.rows.first?.first, .text("0"), "a pooled connection was left in a transaction",
                       file: file, line: line)
    }
}

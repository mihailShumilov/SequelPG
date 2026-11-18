@testable import SequelPG
import XCTest

// MARK: - ReadOnlySQLGuard

final class ReadOnlySQLGuardTests: XCTestCase {
    func testLeadingKeywordSkipsWhitespaceCommentsAndParentheses() {
        XCTAssertEqual(ReadOnlySQLGuard.leadingKeyword(of: "  select 1"), "SELECT")
        XCTAssertEqual(ReadOnlySQLGuard.leadingKeyword(of: "-- note\n  commit"), "COMMIT")
        XCTAssertEqual(ReadOnlySQLGuard.leadingKeyword(of: "/* a /* nested */ b */ copy t to stdout"), "COPY")
        XCTAssertEqual(ReadOnlySQLGuard.leadingKeyword(of: "((select 1))"), "SELECT")
        XCTAssertEqual(ReadOnlySQLGuard.leadingKeyword(of: "WITH x AS (select 1) select * from x"), "WITH")
        XCTAssertNil(ReadOnlySQLGuard.leadingKeyword(of: "-- only a comment"))
    }

    func testAllowsSingleReadStatements() throws {
        for sql in [
            "SELECT 1",
            "select * from t;",
            "WITH a AS (SELECT 1) SELECT * FROM a",
            "EXPLAIN SELECT 1",
            "VALUES (1), (2)",
            "SHOW search_path",
            "TABLE people",
        ] {
            XCTAssertNoThrow(try ReadOnlySQLGuard.validate(sql), sql)
        }
        XCTAssertEqual(try ReadOnlySQLGuard.validate("SELECT 1;"), "SELECT 1")
    }

    func testRejectsMultipleStatements() {
        XCTAssertThrowsError(try ReadOnlySQLGuard.validate("SELECT 1; SELECT 2"))
        XCTAssertThrowsError(try ReadOnlySQLGuard.validate("SELECT 1; COMMIT; DROP TABLE t"))
    }

    func testSemicolonInsideLiteralIsOneStatement() throws {
        XCTAssertNoThrow(try ReadOnlySQLGuard.validate("SELECT ';drop table t;'"))
        XCTAssertNoThrow(try ReadOnlySQLGuard.validate("SELECT $$a;b$$"))
    }

    func testRejectsEverythingButQueries() {
        for sql in [
            "COMMIT",
            "begin",
            "ROLLBACK",
            "start transaction read write",
            "end",
            "abort",
            "savepoint s",
            "copy (select 1) to program 'id'",
            "COPY t TO '/tmp/x'",
            "LOAD 'plugin'",
            "SET ROLE admin",
            "reset all",
            "DISCARD ALL",
            "prepare transaction 'x'",
            "checkpoint",
            "/* x */ commit",
            "notify chan",
            "lock table t",
            "vacuum t",
            "DO $$BEGIN NULL; END$$",
            "CALL p()",
            "CLUSTER t",
            "REINDEX TABLE t",
            "ANALYZE t",
            "INSERT INTO t VALUES (1)",
            "DELETE FROM t",
        ] {
            XCTAssertThrowsError(try ReadOnlySQLGuard.validate(sql), sql)
        }
    }

    func testCarriageReturnEndsLineComment() {
        // PostgreSQL ends `--` comments at CR too; the guard must agree, or
        // the comment could hide the real statement.
        XCTAssertEqual(ReadOnlySQLGuard.leadingKeyword(of: "--x\rCOPY t TO STDOUT"), "COPY")
        XCTAssertThrowsError(try ReadOnlySQLGuard.validate("--x\rCOPY (SELECT 1) TO PROGRAM 'id' /*\nSELECT */"))
        XCTAssertEqual(SQLStatementSplitter.split("--a\rSELECT 1; SELECT 2").count, 2)
    }

    func testUnicodeSpaceIsNotWhitespace() throws {
        XCTAssertNil(ReadOnlySQLGuard.leadingKeyword(of: "\u{00A0}SELECT"))
        // The splitter trims it, and the trimmed text is what runs.
        XCTAssertEqual(try ReadOnlySQLGuard.validate("\u{00A0}SELECT 1"), "SELECT 1")
        XCTAssertThrowsError(try ReadOnlySQLGuard.validate("SELECT\u{00A0}1; COPY t TO STDOUT"))
    }

    func testRejectsEmptyInput() {
        XCTAssertThrowsError(try ReadOnlySQLGuard.validate("   "))
        XCTAssertThrowsError(try ReadOnlySQLGuard.validate("-- nothing"))
    }
}

// MARK: - JSON & framing

final class MCPFramingTests: XCTestCase {
    func testJSONValueRoundTripsIntegersAndNesting() throws {
        let value: JSONValue = ["id": 7, "ok": true, "name": "x", "list": [1, "two", nil], "pi": .double(3.5)]
        let decoded = try JSONDecoder().decode(JSONValue.self, from: value.encoded())
        XCTAssertEqual(decoded, value)
        XCTAssertEqual(decoded["id"]?.intValue, 7)
        XCTAssertEqual(String(decoding: JSONValue.int(1).encoded(), as: UTF8.self), "1")
    }

    func testLineBufferSplitsAcrossChunks() {
        var buffer = LineBuffer()
        XCTAssertEqual(buffer.append(Data("{\"a\":".utf8)), [])
        XCTAssertEqual(buffer.append(Data("1}\n\r\n{\"b\"".utf8)), [Data("{\"a\":1}".utf8)])
        XCTAssertEqual(buffer.append(Data(":2}\r\n".utf8)), [Data("{\"b\":2}".utf8)])
    }

    func testLineBufferRejectsOversizedLine() {
        var buffer = LineBuffer()
        XCTAssertNil(buffer.append(Data(count: LineBuffer.maxLineLength + 1)))
    }

    func testProtocolVersionNegotiation() {
        XCTAssertEqual(MCPProtocol.negotiate("2025-06-18"), "2025-06-18")
        XCTAssertEqual(MCPProtocol.negotiate("1999-01-01"), MCPProtocol.supportedVersions[0])
        XCTAssertEqual(MCPProtocol.negotiate(nil), MCPProtocol.supportedVersions[0])
    }
}

// MARK: - Session

/// A tool handler with one tool, `echo`, and one that waits, `slow`.
private struct StubToolHandler: MCPToolHandling {
    var tools: [MCPTool] {
        [
            MCPTool(name: "echo", title: "Echo", description: "", inputSchema: ["type": "object"]),
            MCPTool(name: "slow", title: "Slow", description: "", inputSchema: ["type": "object"]),
        ]
    }

    func callTool(_ name: String, arguments: [String: JSONValue], client: MCPClientInfo?) async -> MCPToolResult {
        if name == "slow" {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            return MCPToolResult(text: "late")
        }
        return MCPToolResult(text: "\(client?.name ?? "-"):\(arguments["text"]?.stringValue ?? "")")
    }
}

/// Collects what a session sends.
private actor Outbox {
    private(set) var messages: [JSONValue] = []

    func append(_ data: Data) {
        if let value = try? JSONDecoder().decode(JSONValue.self, from: data) {
            messages.append(value)
        }
    }

    func waitForCount(_ count: Int, timeout: TimeInterval = 2) async -> [JSONValue] {
        let deadline = Date().addingTimeInterval(timeout)
        while messages.count < count, Date() < deadline {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return messages
    }
}

final class MCPSessionTests: XCTestCase {
    private func makeSession() -> (MCPSession, Outbox) {
        let outbox = Outbox()
        let session = MCPSession(handler: StubToolHandler()) { data in await outbox.append(data) }
        return (session, outbox)
    }

    private func send(_ session: MCPSession, _ message: JSONValue) async {
        await session.receive(message.encoded())
    }

    func testInitializeNegotiatesAndRecordsClient() async {
        let (session, outbox) = makeSession()
        await send(session, ["jsonrpc": "2.0", "id": 1, "method": "initialize", "params": [
            "protocolVersion": "2025-03-26", "capabilities": [:], "clientInfo": ["name": "tester", "version": "9"],
        ]])
        let reply = await outbox.waitForCount(1)[0]
        XCTAssertEqual(reply["id"], 1)
        XCTAssertEqual(reply["result"]?["protocolVersion"], "2025-03-26")
        XCTAssertEqual(reply["result"]?["serverInfo"]?["name"], "SequelPG")
        XCTAssertNotNil(reply["result"]?["capabilities"]?["tools"])
        let client = await session.client
        XCTAssertEqual(client, MCPClientInfo(name: "tester", version: "9"))
    }

    func testNotificationsGetNoReply() async {
        let (session, outbox) = makeSession()
        await send(session, ["jsonrpc": "2.0", "method": "notifications/initialized"])
        await send(session, ["jsonrpc": "2.0", "id": "p", "method": "ping"])
        let messages = await outbox.waitForCount(1)
        XCTAssertEqual(messages.count, 1)
        XCTAssertEqual(messages[0]["id"], "p")
        XCTAssertEqual(messages[0]["result"], [:])
    }

    func testToolsListAndCall() async {
        let (session, outbox) = makeSession()
        await send(session, ["jsonrpc": "2.0", "id": 1, "method": "initialize", "params": [
            "clientInfo": ["name": "c", "version": "1"],
        ]])
        await send(session, ["jsonrpc": "2.0", "id": 2, "method": "tools/list"])
        await send(session, ["jsonrpc": "2.0", "id": 3, "method": "tools/call", "params": [
            "name": "echo", "arguments": ["text": "hi"],
        ]])
        let messages = await outbox.waitForCount(3)
        let list = messages.first { $0["id"] == 2 }
        guard case let .array(tools)? = list?["result"]?["tools"] else { return XCTFail("no tools") }
        XCTAssertEqual(tools.compactMap { $0["name"]?.stringValue }, ["echo", "slow"])
        XCTAssertEqual(tools.first?["annotations"]?["readOnlyHint"], true)
        let call = messages.first { $0["id"] == 3 }
        XCTAssertEqual(call?["result"]?["isError"], false)
        XCTAssertEqual(call?["result"]?["content"], [["type": "text", "text": "c:hi"]])
    }

    func testErrorsForUnknownMethodToolAndBadJSON() async {
        let (session, outbox) = makeSession()
        await send(session, ["jsonrpc": "2.0", "id": 1, "method": "resources/list"])
        await send(session, ["jsonrpc": "2.0", "id": 2, "method": "tools/call", "params": ["name": "nope"]])
        await session.receive(Data("{not json".utf8))
        let messages = await outbox.waitForCount(3)
        let codes = Dictionary(uniqueKeysWithValues: messages.map { ($0["id"] ?? .null, $0["error"]?["code"]) })
        XCTAssertEqual(codes[1], .int(MCPProtocol.ErrorCode.methodNotFound))
        XCTAssertEqual(codes[2], .int(MCPProtocol.ErrorCode.invalidParams))
        XCTAssertEqual(codes[.null], .int(MCPProtocol.ErrorCode.parseError))
    }

    func testCancelledRequestGetsNoReply() async {
        let (session, outbox) = makeSession()
        await send(session, ["jsonrpc": "2.0", "id": 5, "method": "tools/call", "params": ["name": "slow"]])
        await send(session, ["jsonrpc": "2.0", "method": "notifications/cancelled", "params": ["requestId": 5]])
        await send(session, ["jsonrpc": "2.0", "id": 6, "method": "ping"])
        try? await Task.sleep(nanoseconds: 300_000_000)
        let messages = await outbox.messages
        XCTAssertEqual(messages.map { $0["id"] }, [6])
    }
}

// MARK: - Toolbox

final class MCPToolboxTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!
    private var store: ConnectionStore!
    private var keychain: InMemoryKeychainService!
    private var authorization: MCPAuthorizationStore!
    private var mock: MockDatabaseClient!

    private let shared = ConnectionProfile(
        id: UUID(uuidString: "AAAAAAAA-0000-0000-0000-000000000001")!,
        name: "Shared", host: "db", database: "app", username: "u", mcpAccess: .readOnly
    )
    private let hidden = ConnectionProfile(
        id: UUID(uuidString: "AAAAAAAA-0000-0000-0000-000000000002")!,
        name: "Hidden", host: "db", database: "app", username: "u"
    )

    override func setUp() {
        super.setUp()
        suiteName = "MCPToolboxTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        store = ConnectionStore(defaults: defaults)
        store.save([shared, hidden])
        keychain = InMemoryKeychainService()
        authorization = MCPAuthorizationStore(keychain: keychain)
        authorization.setAccess(.readOnly, for: shared.id)
        mock = MockDatabaseClient()
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    private func makeToolbox(authorize: @escaping @Sendable (MCPClientInfo?) async -> Bool = { _ in true })
        -> MCPToolbox {
        let mock = mock!
        let pool = MCPSessionPool(keychain: keychain) { mock }
        return MCPToolbox(store: store, authorization: authorization, pool: pool, authorize: authorize)
    }

    func testListConnectionsShowsOnlySharedProfiles() async {
        let result = await makeToolbox().callTool("list_connections", arguments: [:], client: nil)
        XCTAssertFalse(result.isError)
        XCTAssertTrue(result.text.contains(shared.id.uuidString))
        XCTAssertFalse(result.text.contains(hidden.id.uuidString))
        XCTAssertFalse(result.text.contains("Hidden"))
    }

    func testUserDefaultsAloneCantShareAConnection() async {
        // A process rewriting the app's preferences flips mcpAccess there;
        // the Keychain copy still says off.
        var tampered = hidden
        tampered.mcpAccess = .readOnly
        store.update(tampered)
        let result = await makeToolbox().callTool("list_connections", arguments: [:], client: nil)
        XCTAssertFalse(result.text.contains(hidden.id.uuidString))
    }

    func testPrivilegedRoleIsRefused() async {
        await mock.setRunQueryHandler { sql in
            if sql.contains("rolsuper") {
                return QueryResult(
                    columns: ["role", "privileged"],
                    rows: [[.text("postgres"), .text("true")]],
                    executionTime: 0,
                    rowsAffected: nil,
                    isTruncated: false
                )
            }
            return QueryResult(
                columns: ["n"],
                rows: [[.text("1")]],
                executionTime: 0,
                rowsAffected: nil,
                isTruncated: false
            )
        }
        let result = await makeToolbox().callTool(
            "run_query", arguments: ["connection": "Shared", "sql": "SELECT 1"], client: nil
        )
        XCTAssertTrue(result.isError)
        XCTAssertTrue(result.text.contains("\"postgres\" is a superuser"), result.text)
        let disconnects = await mock.disconnectCallCount
        XCTAssertEqual(disconnects, 1)
    }

    func testAllowSuperuserSkipsTheRoleCheck() async {
        authorization.setAccess(.readOnlyAnyRole, for: shared.id)
        await mock.setRunQueryHandler { sql in
            XCTAssertFalse(sql.contains("rolsuper"), "the role check ran despite readOnlyAnyRole")
            return QueryResult(
                columns: ["n"],
                rows: [[.text("1")]],
                executionTime: 0,
                rowsAffected: nil,
                isTruncated: false
            )
        }
        let result = await makeToolbox().callTool(
            "run_query", arguments: ["connection": "Shared", "sql": "SELECT 1"], client: nil
        )
        XCTAssertFalse(result.isError, result.text)
    }

    func testUnknownAccessValueDecodesAsOff() throws {
        let decoded = try JSONDecoder().decode([MCPAccess].self, from: Data(#"["readOnlyAnyRole","writeAll"]"#.utf8))
        XCTAssertEqual(decoded, [.readOnlyAnyRole, .off])
        XCTAssertFalse(MCPAccess.readOnlyAnyRole.refusesPrivilegedRoles)
        XCTAssertTrue(MCPAccess.readOnly.refusesPrivilegedRoles)
    }

    func testHiddenConnectionIsUnknown() async {
        let result = await makeToolbox().callTool(
            "run_query", arguments: ["connection": .string(hidden.id.uuidString), "sql": "SELECT 1"], client: nil
        )
        XCTAssertTrue(result.isError)
        XCTAssertTrue(result.text.contains("Unknown connection"))
        let connects = await mock.connectCallCount
        XCTAssertEqual(connects, 0)
    }

    func testRunQueryUsesReadOnlyPathAndClampsRows() async {
        await mock.setStubbedQueryResult(QueryResult(
            columns: ["n"], rows: [[.text("1")]], executionTime: 0.001, rowsAffected: nil, isTruncated: false
        ))
        let result = await makeToolbox().callTool("run_query", arguments: [
            "connection": "Shared", "sql": "SELECT 1", "max_rows": 999_999,
        ], client: nil)
        XCTAssertFalse(result.isError, result.text)
        XCTAssertTrue(result.text.hasPrefix("n\n1\n"))
        let readOnlySQL = await mock.lastReadOnlySQL
        let maxRows = await mock.lastRunQueryMaxRows
        XCTAssertEqual(readOnlySQL, "SELECT 1")
        XCTAssertEqual(maxRows, MCPToolbox.maxRowsLimit)
    }

    func testRejectedSQLNeverConnects() async {
        let result = await makeToolbox().callTool("run_query", arguments: [
            "connection": .string(shared.id.uuidString), "sql": "SELECT 1; DROP TABLE t",
        ], client: nil)
        XCTAssertTrue(result.isError)
        let connects = await mock.connectCallCount
        XCTAssertEqual(connects, 0)
    }

    func testMissingArgumentIsReported() async {
        let result = await makeToolbox().callTool("describe_table", arguments: ["connection": "Shared"], client: nil)
        XCTAssertTrue(result.isError)
        XCTAssertTrue(result.text.contains("\"schema\""))
    }

    func testDeniedClientGetsNothing() async {
        let toolbox = makeToolbox { _ in false }
        let result = await toolbox.callTool("list_connections", arguments: [:], client: MCPClientInfo(
            name: "evil", version: "1"
        ))
        XCTAssertTrue(result.isError)
        XCTAssertFalse(result.text.contains("Shared"))
    }

    func testSessionsAreReusedPerConnectionAndDatabase() async {
        let toolbox = makeToolbox()
        _ = await toolbox.callTool("list_schemas", arguments: ["connection": "Shared"], client: nil)
        _ = await toolbox.callTool("list_schemas", arguments: ["connection": "Shared"], client: nil)
        var connects = await mock.connectCallCount
        XCTAssertEqual(connects, 1)
        _ = await toolbox.callTool(
            "list_schemas",
            arguments: ["connection": "Shared", "database": "other"],
            client: nil
        )
        connects = await mock.connectCallCount
        let database = await mock.lastConnectedProfile?.database
        XCTAssertEqual(connects, 2)
        XCTAssertEqual(database, "other")
    }
}

// MARK: - Formatter

final class MCPResultFormatterTests: XCTestCase {
    func testEscapesSeparatorsAndNewlines() {
        let result = QueryResult(
            columns: ["a|b", "c"],
            rows: [[.text("x|y\nz"), .null]],
            executionTime: 0,
            rowsAffected: nil,
            isTruncated: false
        )
        let text = MCPResultFormatter.format(result, maxRowsRequested: 10)
        XCTAssertTrue(text.hasPrefix("a\\|b | c\nx\\|y\\nz | NULL\n"), text)
        XCTAssertTrue(text.contains("1 row"))
    }

    func testMentionsRowLimitAndCommandResults() {
        let truncated = QueryResult(
            columns: ["n"],
            rows: [[.text("1")]],
            executionTime: 0,
            rowsAffected: nil,
            isTruncated: true
        )
        XCTAssertTrue(MCPResultFormatter.format(truncated, maxRowsRequested: 1).contains("max_rows=1"))
        let command = QueryResult(columns: [], rows: [], executionTime: 0, rowsAffected: 3, isTruncated: false)
        XCTAssertTrue(MCPResultFormatter.format(command, maxRowsRequested: 1).hasPrefix("OK, 3 rows affected"))
    }

    func testCapsLongCellsAndOutput() {
        let long = String(repeating: "x", count: MCPResultFormatter.maxCellCharacters + 50)
        XCTAssertEqual(MCPResultFormatter.escape(long).count, MCPResultFormatter.maxCellCharacters + 1)
        let rows = Array(repeating: [CellValue.text(String(repeating: "y", count: 900))], count: 500)
        let big = QueryResult(columns: ["v"], rows: rows, executionTime: 0, rowsAffected: nil, isTruncated: false)
        let text = MCPResultFormatter.format(big, maxRowsRequested: 500)
        XCTAssertLessThan(text.count, MCPResultFormatter.maxOutputCharacters + 500)
        XCTAssertTrue(text.contains("output cut"))
    }
}

// MARK: - Approval

@MainActor
final class MCPServerControllerTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() {
        super.setUp()
        suiteName = "MCPServerControllerTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    private let keychain = InMemoryKeychainService()

    private func makeController(answer: Bool, asked: @escaping (String) -> Void = { _ in }) -> MCPServerController {
        let controller = MCPServerController(store: ConnectionStore(defaults: defaults), keychain: keychain)
        controller.askUser = { name in
            asked(name)
            return answer
        }
        return controller
    }

    func testSwitchAndApprovalsLiveInKeychainNotDefaults() async {
        let controller = makeController(answer: true)
        controller.isEnabled = true
        controller.isEnabled = false
        _ = await controller.authorize(MCPClientInfo(name: "claude-code", version: ""))
        XCTAssertEqual(MCPAuthorizationStore(keychain: keychain).load().approvedClients, ["claude-code"])
        XCTAssertTrue(defaults.dictionaryRepresentation().keys.allSatisfy { !$0.hasPrefix("com.sequelpg.mcp") })
    }

    func testServerIsOffByDefault() {
        let controller = makeController(answer: true)
        XCTAssertFalse(controller.isEnabled)
        XCTAssertEqual(controller.status, .stopped)
    }

    func testApprovalIsAskedOnceAndPersisted() async {
        var prompts: [String] = []
        let controller = makeController(answer: true) { prompts.append($0) }
        let client = MCPClientInfo(name: "claude-code", version: "2")
        let first = await controller.authorize(client)
        let second = await controller.authorize(client)
        XCTAssertTrue(first)
        XCTAssertTrue(second)
        XCTAssertEqual(prompts, ["claude-code"])
        XCTAssertEqual(controller.approvedClients, ["claude-code"])

        // A new controller (next launch) remembers the approval.
        let relaunched = makeController(answer: false)
        let allowed = await relaunched.authorize(client)
        XCTAssertTrue(allowed)
    }

    func testDenialIsRememberedForTheLaunch() async {
        var prompts = 0
        let controller = makeController(answer: false) { _ in prompts += 1 }
        let first = await controller.authorize(MCPClientInfo(name: "x", version: ""))
        let second = await controller.authorize(MCPClientInfo(name: "x", version: ""))
        XCTAssertFalse(first)
        XCTAssertFalse(second)
        XCTAssertEqual(prompts, 1)
        XCTAssertTrue(controller.approvedClients.isEmpty)
    }

    func testRevokeAsksAgain() async {
        var prompts = 0
        let controller = makeController(answer: true) { _ in prompts += 1 }
        let client = MCPClientInfo(name: "cursor", version: "")
        _ = await controller.authorize(client)
        controller.revoke("cursor")
        XCTAssertTrue(controller.approvedClients.isEmpty)
        _ = await controller.authorize(client)
        XCTAssertEqual(prompts, 2)
    }

    func testUnnamedClientsShareOneName() {
        XCTAssertEqual(MCPServerController.normalizedName(nil), "Unknown client")
        XCTAssertEqual(MCPServerController.normalizedName(MCPClientInfo(name: "  ", version: "")), "Unknown client")
        XCTAssertEqual(
            MCPServerController.normalizedName(MCPClientInfo(name: "evil\n\u{202E}name", version: "")), "evilname"
        )
    }
}

// MARK: - Profiles

final class MCPAccessDecodingTests: XCTestCase {
    func testMissingOrUnknownAccessDecodesAsOff() throws {
        let base = #"{"id":"AAAAAAAA-0000-0000-0000-000000000003","name":"n","host":"h","port":5432,"#
            + #""database":"d","username":"u","sslMode":"off""#
        let missing = try JSONDecoder().decode(ConnectionProfile.self, from: Data((base + "}").utf8))
        XCTAssertEqual(missing.mcpAccess, .off)
        let future = try JSONDecoder().decode(
            ConnectionProfile.self, from: Data((base + #","mcpAccess":"readWrite"}"#).utf8)
        )
        XCTAssertEqual(future.mcpAccess, .off)
        let shared = try JSONDecoder().decode(
            ConnectionProfile.self, from: Data((base + #","mcpAccess":"readOnly"}"#).utf8)
        )
        XCTAssertEqual(shared.mcpAccess, .readOnly)
    }
}

// MARK: - Installer

final class MCPClientInstallerTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("MCPInstaller-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func readJSON(_ url: URL) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    }

    func testMergeKeepsOtherSettingsAndWritesBackup() throws {
        let url = directory.appendingPathComponent("config.json")
        let original = #"{"theme":"dark","mcpServers":{"other":{"command":"x"},"sequelpg":{"command":"old"}}}"#
        try Data(original.utf8).write(to: url)

        try MCPClientInstaller.mergeEntry(into: url)

        let config = try readJSON(url)
        XCTAssertEqual(config["theme"] as? String, "dark")
        let servers = try XCTUnwrap(config["mcpServers"] as? [String: Any])
        XCTAssertNotNil(servers["other"])
        let entry = try XCTUnwrap(servers["sequelpg"] as? [String: Any])
        XCTAssertEqual(entry["command"] as? String, MCPClientInstaller.bridgeExecutable)
        XCTAssertEqual(entry["args"] as? [String], ["--mcp-stdio"])
        let backup = try String(contentsOf: url.appendingPathExtension("bak"), encoding: .utf8)
        XCTAssertEqual(backup, original)
    }

    func testMergeCreatesMissingFile() throws {
        let url = directory.appendingPathComponent("nested/mcp.json")
        try MCPClientInstaller.mergeEntry(into: url)
        let servers = try XCTUnwrap(readJSON(url)["mcpServers"] as? [String: Any])
        XCTAssertNotNil(servers["sequelpg"])
    }

    func testInvalidConfigIsLeftAlone() throws {
        let url = directory.appendingPathComponent("broken.json")
        try Data("{ not json".utf8).write(to: url)
        XCTAssertThrowsError(try MCPClientInstaller.mergeEntry(into: url))
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "{ not json")
    }

    func testMergeWritesThroughSymlink() throws {
        let target = directory.appendingPathComponent("dotfiles-mcp.json")
        try Data("{}".utf8).write(to: target)
        let link = directory.appendingPathComponent("mcp.json")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        try MCPClientInstaller.mergeEntry(into: link)
        let attributes = try FileManager.default.attributesOfItem(atPath: link.path)
        XCTAssertEqual(attributes[.type] as? FileAttributeType, .typeSymbolicLink)
        XCTAssertNotNil(try readJSON(target)["mcpServers"])
    }

    func testRefusesNonObjectServers() throws {
        let url = directory.appendingPathComponent("weird.json")
        try Data(#"{"mcpServers":[1]}"#.utf8).write(to: url)
        XCTAssertThrowsError(try MCPClientInstaller.mergeEntry(into: url))
    }

    func testShellQuoting() {
        XCTAssertEqual(MCPClientInstaller.shellQuoted("--mcp-stdio"), "--mcp-stdio")
        XCTAssertEqual(MCPClientInstaller.shellQuoted("/A b/c"), "'/A b/c'")
        XCTAssertEqual(MCPClientInstaller.shellQuoted("it's"), "'it'\\''s'")
        XCTAssertTrue(MCPClientInstaller.claudeCodeCommand.hasPrefix("claude mcp add --scope user sequelpg -- "))
    }
}

// MARK: - Socket server

final class MCPSocketServerTests: XCTestCase {
    func testServesSessionsOverUnixSocketAndCleansUp() throws {
        // Short path: sun_path holds ~103 bytes.
        let path = "/tmp/sqpg-test-\(getpid()).sock"
        let server = MCPSocketServer(path: path, handler: StubToolHandler(), requireTrustedPeer: false)
        try server.start()
        defer { server.stop() }

        // A second server on the same path refuses to take it over.
        let rival = MCPSocketServer(path: path, handler: StubToolHandler(), requireTrustedPeer: false)
        XCTAssertThrowsError(try rival.start())

        var attributes = stat()
        XCTAssertEqual(stat(path, &attributes), 0)
        XCTAssertEqual(attributes.st_mode & 0o777, 0o600)

        let fd = try XCTUnwrap(MCPSocket.connect(to: path))
        defer { close(fd) }
        let request: JSONValue = ["jsonrpc": "2.0", "id": 1, "method": "tools/call", "params": [
            "name": "echo", "arguments": ["text": "over socket"],
        ]]
        XCTAssertTrue(MCPSocket.writeAll(fd, request.encodedLine()))

        var lines = LineBuffer()
        var chunk = [UInt8](repeating: 0, count: 4096)
        var received: [Data] = []
        var timeout = timeval(tv_sec: 2, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        while received.isEmpty {
            let count = read(fd, &chunk, chunk.count)
            guard count > 0 else { break }
            received += lines.append(Data(chunk[0 ..< count])) ?? []
        }
        let reply = try JSONDecoder().decode(JSONValue.self, from: XCTUnwrap(received.first))
        XCTAssertEqual(reply["result"]?["content"], [["type": "text", "text": "-:over socket"]])

        server.stop()
        XCTAssertFalse(FileManager.default.fileExists(atPath: path))
    }

    func testRepliesArriveAfterClientHalfCloses() throws {
        let path = "/tmp/sqpg-half-\(getpid()).sock"
        let server = MCPSocketServer(path: path, handler: StubToolHandler(), requireTrustedPeer: false)
        try server.start()
        defer { server.stop() }
        let fd = try XCTUnwrap(MCPSocket.connect(to: path))
        defer { close(fd) }
        let request: JSONValue = ["jsonrpc": "2.0", "id": 9, "method": "tools/call", "params": ["name": "slow"]]
        XCTAssertTrue(MCPSocket.writeAll(fd, request.encodedLine()))
        shutdown(fd, SHUT_WR)

        var timeout = timeval(tv_sec: 5, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var data = Data()
        var chunk = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = read(fd, &chunk, chunk.count)
            guard count > 0 else { break }
            data.append(contentsOf: chunk[0 ..< count])
        }
        XCTAssertTrue(String(decoding: data, as: UTF8.self).contains("late"))
    }
}

final class MCPConcurrencyTests: XCTestCase {
    func testDuplicateRequestIdIsRejected() async {
        let outbox = Outbox()
        let session = MCPSession(handler: StubToolHandler()) { data in await outbox.append(data) }
        let call: JSONValue = ["jsonrpc": "2.0", "id": 1, "method": "tools/call", "params": ["name": "slow"]]
        await session.receive(call.encoded())
        await session.receive(call.encoded())
        let messages = await outbox.waitForCount(1)
        XCTAssertEqual(messages.first?["error"]?["code"], .int(MCPProtocol.ErrorCode.invalidRequest))
        await session.close()
    }

    func testLimiterBoundsConcurrency() async {
        let limiter = AsyncLimiter(limit: 2)
        let counter = Counter()
        await withTaskGroup(of: Void.self) { group in
            for _ in 0 ..< 8 {
                group.addTask {
                    await limiter.acquire()
                    await counter.enter()
                    try? await Task.sleep(nanoseconds: 20_000_000)
                    await counter.leave()
                    await limiter.release()
                }
            }
        }
        let peak = await counter.peak
        XCTAssertEqual(peak, 2)
    }

    func testPoolDisconnectsReplacedAndClosedSessions() async throws {
        let created = Created()
        let pool = MCPSessionPool(keychain: InMemoryKeychainService()) {
            let client = MockDatabaseClient()
            Task { await created.add(client) }
            return client
        }
        var profile = ConnectionProfile(name: "p", host: "h", database: "d", username: "u")
        _ = try await pool.client(for: profile)
        profile.host = "edited"
        _ = try await pool.client(for: profile)
        await pool.closeAll()
        try await Task.sleep(nanoseconds: 100_000_000)
        let clients = await created.clients
        XCTAssertEqual(clients.count, 2)
        for client in clients {
            let disconnects = await client.disconnectCallCount
            XCTAssertGreaterThanOrEqual(disconnects, 1)
        }
    }
}

private actor Counter {
    private var current = 0
    private(set) var peak = 0
    func enter() {
        current += 1
        peak = max(peak, current)
    }

    func leave() {
        current -= 1
    }
}

private actor Created {
    private(set) var clients: [MockDatabaseClient] = []
    func add(_ client: MockDatabaseClient) {
        clients.append(client)
    }
}

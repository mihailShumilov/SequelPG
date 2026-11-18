import XCTest
@testable import SequelPG

/// End-to-end flows through `AppViewModel` with a real `DatabaseClient` —
/// the same code paths the UI drives, minus the views.
final class AppViewModelIntegrationTests: IntegrationTestCase {
    private var suiteNames: [String] = []

    override func tearDown() async throws {
        for name in suiteNames {
            UserDefaults().removePersistentDomain(forName: name)
        }
        suiteNames.removeAll()
        try await super.tearDown()
    }

    @MainActor
    private func makeAppVM(timeoutSeconds: Int = 10) throws -> AppViewModel {
        let suite = "sequelpg.integration.\(UUID().uuidString)"
        suiteNames.append(suite)
        let prefs = EditorPreference(defaults: try XCTUnwrap(UserDefaults(suiteName: suite)))
        prefs.queryTimeoutSeconds = timeoutSeconds
        return AppViewModel(dbClient: DatabaseClient(), editorPreference: prefs)
    }

    @MainActor
    private func connectedAppVM(
        _ server: TestCluster.Server = .pg18,
        timeoutSeconds: Int = 10
    ) async throws -> AppViewModel {
        try TestCluster.require([server])
        let vm = try makeAppVM(timeoutSeconds: timeoutSeconds)
        await vm.connect(profile: TestCluster.profile(server), password: TestCluster.password(.scram), sshPassword: nil)
        XCTAssertTrue(vm.isConnected, vm.errorMessage ?? "")
        addTeardownBlock { await vm.disconnect() }
        return vm
    }

    /// An independent admin connection for setting up and verifying data.
    private func admin() async throws -> DatabaseClient {
        try await connect(.pg18)
    }

    /// Mirrors the UI: Run executes the editor's text, and table detection for
    /// inline editing parses that text.
    @MainActor
    private func run(_ vm: AppViewModel, _ sql: String) async {
        vm.queryVM.queryText = sql
        await vm.executeQuery(sql)
    }

    @MainActor
    private func openTable(_ vm: AppViewModel, schema: String, name: String) async throws {
        vm.selectedTab = .content
        await vm.selectObject(DBObject(schema: schema, name: name, type: .table))
        if vm.tableVM.contentResult == nil {
            await vm.loadContentPage()
        }
        XCTAssertNotNil(vm.tableVM.contentResult, vm.errorMessage ?? "no content")
    }

    // MARK: Connect

    @MainActor
    func testConnectLoadsServerVersionDatabasesAndSchemas() async throws {
        for server in TestCluster.Server.allCases {
            let vm = try await connectedAppVM(server)
            XCTAssertNil(vm.errorMessage, "\(server)")
            XCTAssertEqual(vm.navigatorVM.serverVersion, TestCluster.major(server), "\(server)")
            XCTAssertEqual(vm.navigatorVM.connectedDatabase, TestCluster.database, "\(server)")
            await vm.disconnect()
            XCTAssertFalse(vm.isConnected, "\(server)")
        }
    }

    @MainActor
    func testFailedConnectSurfacesErrorAndStaysDisconnected() async throws {
        try TestCluster.require([.pg18])
        let vm = try makeAppVM()
        let start = Date()
        await vm.connect(profile: TestCluster.profile(.pg18), password: "wrong", sshPassword: nil)
        XCTAssertFalse(vm.isConnected)
        XCTAssertTrue(vm.errorMessage?.contains("password authentication failed") == true, vm.errorMessage ?? "nil")
        XCTAssertLessThan(Date().timeIntervalSince(start), 5, "A wrong password must fail promptly")
    }

    // MARK: Query tab

    @MainActor
    func testRunQueryPopulatesResultAndEnablesEditingForPKTables() async throws {
        let vm = try await connectedAppVM()
        await run(vm, "SELECT * FROM qa.people ORDER BY id")
        XCTAssertNil(vm.queryVM.errorMessage)
        XCTAssertEqual(vm.queryVM.result?.rowCount, 50)
        XCTAssertNotNil(vm.queryVM.editableTableContext, "A full-PK SELECT from one table is editable")

        await run(vm, "SELECT * FROM qa.no_pk")
        XCTAssertNil(vm.queryVM.editableTableContext, "No PK → read-only")

        await run(vm, "SELECT * FROM qa.people WHERE false")
        XCTAssertEqual(vm.queryVM.result?.columns.first, "id", "Empty results still show the table's columns")
    }

    @MainActor
    func testQueryErrorIsShownInQueryPane() async throws {
        let vm = try await connectedAppVM()
        await vm.executeQuery("SELECT * FROM qa.missing_table")
        XCTAssertNotNil(vm.queryVM.errorMessage)
        XCTAssertFalse(vm.queryVM.isExecuting)
        XCTAssertTrue(vm.isConnected, "A query error must not drop the session")
    }

    @MainActor
    func testUserQueryTimeoutFromPreferences() async throws {
        let vm = try await connectedAppVM(timeoutSeconds: 1)
        await vm.executeQuery("SELECT qa.slow(4)")
        XCTAssertTrue(
            vm.queryVM.errorMessage?.localizedCaseInsensitiveContains("timed out") == true
                || vm.queryVM.errorMessage?.localizedCaseInsensitiveContains("timeout") == true,
            vm.queryVM.errorMessage ?? "nil"
        )
    }

    @MainActor
    func testStopCancelsRunningQuery() async throws {
        let vm = try await connectedAppVM(timeoutSeconds: 0)
        vm.runQueryAction("SELECT qa.slow(5)")
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertTrue(vm.queryVM.isExecuting)
        vm.cancelRunningQuery()
        for _ in 0 ..< 30 where vm.queryVM.isExecuting {
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        XCTAssertFalse(vm.queryVM.isExecuting, "Stop must clear the spinner")
        for _ in 0 ..< 60 where vm.queryVM.isExecuting {
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        XCTAssertNil(vm.queryVM.errorMessage, "Cancellation is not an error")
        await vm.executeQuery("SELECT 1")
        XCTAssertEqual(vm.queryVM.result?.rowCount, 1)
    }

    @MainActor
    func testExplainPopulatesPlan() async throws {
        let vm = try await connectedAppVM()
        await vm.explainQuery("SELECT * FROM qa.people WHERE age > 30", analyze: true)
        XCTAssertNil(vm.queryVM.errorMessage)
        XCTAssertNotNil(vm.queryVM.plan)
    }

    // MARK: Content tab editing

    @MainActor
    func testContentEditInsertDeleteRoundTrip() async throws {
        let db = try await admin()
        let schema = try await makeScratchSchema(on: db)
        let s = quoteIdent(schema)
        try await db.exec("CREATE TABLE \(s).notes (id int PRIMARY KEY, note text, n int)")
        try await db.exec("INSERT INTO \(s).notes VALUES (1, 'one', 1), (2, 'two', 2)")

        let vm = try await connectedAppVM()
        try await openTable(vm, schema: schema, name: "notes")
        XCTAssertEqual(vm.tableVM.contentResult?.rowCount, 2)

        // Update a cell; quotes must be escaped, NULL keyword honored.
        let noteColumn = try XCTUnwrap(vm.tableVM.contentResult?.columns.firstIndex(of: "note"))
        let rowOne = try XCTUnwrap(vm.tableVM.contentResult?.rows.firstIndex { $0.first == .text("1") })
        await vm.updateContentCell(rowIndex: rowOne, columnIndex: noteColumn, newText: "it's edited")
        XCTAssertNil(vm.errorMessage)
        let edited = try await db.scalar("SELECT note FROM \(s).notes WHERE id = 1")
        XCTAssertEqual(edited, "it's edited")

        let nColumn = try XCTUnwrap(vm.tableVM.contentResult?.columns.firstIndex(of: "n"))
        await vm.updateContentCell(rowIndex: rowOne, columnIndex: nColumn, newText: "NULL")
        let nulled = try await db.scalar("SELECT n FROM \(s).notes WHERE id = 1")
        XCTAssertNil(nulled)

        // Insert.
        vm.startInsertRow()
        vm.tableVM.newRowValues = ["id": "3", "note": "three", "n": ""]
        await vm.commitInsertRow()
        XCTAssertNil(vm.errorMessage)
        let inserted = try await db.scalar("SELECT note FROM \(s).notes WHERE id = 3")
        XCTAssertEqual(inserted, "three")

        // Delete.
        await vm.loadContentPage()
        let rowTwo = try XCTUnwrap(vm.tableVM.contentResult?.rows.firstIndex { $0.first == .text("2") })
        await vm.deleteContentRow(rowIndex: rowTwo)
        XCTAssertNil(vm.errorMessage)
        let count = try await db.scalar("SELECT count(*) FROM \(s).notes")
        XCTAssertEqual(count, "2")
    }

    @MainActor
    func testInvalidCellValueReportsServerError() async throws {
        let db = try await admin()
        let schema = try await makeScratchSchema(on: db)
        try await db.exec("CREATE TABLE \(quoteIdent(schema)).nums (id int PRIMARY KEY, n int)")
        try await db.exec("INSERT INTO \(quoteIdent(schema)).nums VALUES (1, 1)")

        let vm = try await connectedAppVM()
        try await openTable(vm, schema: schema, name: "nums")
        let col = try XCTUnwrap(vm.tableVM.contentResult?.columns.firstIndex(of: "n"))
        await vm.updateContentCell(rowIndex: 0, columnIndex: col, newText: "not a number")
        XCTAssertTrue(vm.errorMessage?.contains("invalid input syntax") == true, vm.errorMessage ?? "nil")
        let unchanged = try await db.scalar("SELECT n FROM \(quoteIdent(schema)).nums")
        XCTAssertEqual(unchanged, "1")
    }

    @MainActor
    func testDeleteWithReferencingRowsOffersCascade() async throws {
        let db = try await admin()
        let schema = try await makeScratchSchema(on: db)
        let s = quoteIdent(schema)
        try await db.exec("CREATE TABLE \(s).parent (id int PRIMARY KEY)")
        try await db.exec("CREATE TABLE \(s).child (id int PRIMARY KEY, parent_id int REFERENCES \(s).parent(id))")
        try await db.exec("INSERT INTO \(s).parent VALUES (1), (2)")
        try await db.exec("INSERT INTO \(s).child VALUES (10, 1), (11, 1), (20, 2)")

        let vm = try await connectedAppVM()
        try await openTable(vm, schema: schema, name: "parent")
        let row = try XCTUnwrap(vm.tableVM.contentResult?.rows.firstIndex { $0.first == .text("1") })
        await vm.deleteContentRow(rowIndex: row)
        XCTAssertNotNil(vm.cascadeDeleteContext, "FK violation must offer a cascade delete")

        await vm.executeCascadeDelete()
        XCTAssertNil(vm.errorMessage)
        let parents = try await db.exec("SELECT id FROM \(s).parent ORDER BY id")
        XCTAssertEqual(parents.column("id"), ["2"])
        let children = try await db.exec("SELECT id FROM \(s).child ORDER BY id")
        XCTAssertEqual(children.column("id"), ["20"], "Only the deleted parent's children go")
    }

    /// Cascade covers one level of referencing rows. Deeper chains must fail
    /// atomically with an explanation — never a partial delete.
    @MainActor
    func testMultiLevelCascadeFailsAtomically() async throws {
        let db = try await admin()
        let schema = try await makeScratchSchema(on: db)
        let s = quoteIdent(schema)
        try await db.exec("CREATE TABLE \(s).parent (id int PRIMARY KEY)")
        try await db.exec("CREATE TABLE \(s).child (id int PRIMARY KEY, parent_id int REFERENCES \(s).parent(id))")
        try await db.exec("CREATE TABLE \(s).grandchild (id int PRIMARY KEY, child_id int REFERENCES \(s).child(id))")
        try await db.exec("INSERT INTO \(s).parent VALUES (1)")
        try await db.exec("INSERT INTO \(s).child VALUES (10, 1)")
        try await db.exec("INSERT INTO \(s).grandchild VALUES (100, 10)")

        let vm = try await connectedAppVM()
        try await openTable(vm, schema: schema, name: "parent")
        await vm.deleteContentRow(rowIndex: 0)
        await vm.executeCascadeDelete()
        XCTAssertTrue(vm.errorMessage?.contains("grandchildren") == true, vm.errorMessage ?? "nil")
        let total = try await db.scalar(
            "SELECT (SELECT count(*) FROM \(s).parent) + (SELECT count(*) FROM \(s).child) + (SELECT count(*) FROM \(s).grandchild)"
        )
        XCTAssertEqual(total, "3", "Nothing may be deleted")
    }

    @MainActor
    func testEditFromQueryResult() async throws {
        let db = try await admin()
        let schema = try await makeScratchSchema(on: db)
        let s = quoteIdent(schema)
        try await db.exec("CREATE TABLE \(s).q (id int PRIMARY KEY, v text)")
        try await db.exec("INSERT INTO \(s).q VALUES (1, 'a'), (2, 'b')")

        let vm = try await connectedAppVM()
        await run(vm, "SELECT * FROM \(s).q ORDER BY id")
        XCTAssertNotNil(vm.queryVM.editableTableContext)
        await vm.updateQueryCell(rowIndex: 1, columnIndex: 1, newText: "B!")
        XCTAssertNil(vm.errorMessage)
        let value = try await db.scalar("SELECT v FROM \(s).q WHERE id = 2")
        XCTAssertEqual(value, "B!")
    }

    // MARK: Structure & navigation

    @MainActor
    func testCreateTableAndSchemaThroughViewModel() async throws {
        let db = try await admin()
        let vm = try await connectedAppVM()
        let schema = "it_vm_" + UUID().uuidString.prefix(6).lowercased()
        addTeardownBlock { _ = try? await db.exec("DROP SCHEMA IF EXISTS \(quoteIdent(schema)) CASCADE") }

        await vm.createSchema(name: schema)
        XCTAssertNil(vm.errorMessage)
        await vm.createTable(schema: schema, name: "made", columns: [
            NewColumnDef(name: "id", dataType: "integer", isNullable: false, isPrimaryKey: true, defaultValue: ""),
            NewColumnDef(name: "label", dataType: "text", isNullable: true, isPrimaryKey: false, defaultValue: "'x'"),
        ])
        XCTAssertNil(vm.errorMessage)
        let columns = try await db.getColumns(schema: schema, table: "made")
        XCTAssertEqual(columns.map(\.name), ["id", "label"])

        await vm.createTable(schema: schema, name: "bad", columns: [
            NewColumnDef(name: "id", dataType: "int; DROP TABLE x", isNullable: true, isPrimaryKey: false, defaultValue: ""),
        ])
        XCTAssertNotNil(vm.errorMessage, "Injected type names must be rejected client-side")
    }

    @MainActor
    func testSwitchDatabase() async throws {
        let vm = try await connectedAppVM()
        await vm.switchDatabase(TestCluster.otherDatabase)
        XCTAssertNil(vm.errorMessage)
        XCTAssertEqual(vm.navigatorVM.connectedDatabase, TestCluster.otherDatabase)
        await vm.executeQuery("SELECT label FROM other.marker")
        XCTAssertEqual(vm.queryVM.result?.rows.first?.first, .text("other-db"))
    }

    @MainActor
    func testExportQueryResultToCSVAndJSON() async throws {
        let vm = try await connectedAppVM()
        await vm.executeQuery("SELECT id, name FROM qa.people WHERE id <= 2 ORDER BY id")
        let result = try XCTUnwrap(vm.queryVM.result)
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("it-export-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let csv = dir.appendingPathComponent("r.csv")
        vm.exportResult(result, format: .csv, to: csv)
        let csvText = try String(contentsOf: csv, encoding: .utf8)
        XCTAssertTrue(csvText.hasPrefix("id,name"), csvText)
        XCTAssertTrue(csvText.contains("Person 02"))

        let json = dir.appendingPathComponent("r.json")
        vm.exportResult(result, format: .json, to: json)
        let decoded = try JSONSerialization.jsonObject(with: Data(contentsOf: json)) as? [[String: Any]]
        XCTAssertEqual(decoded?.count, 2)
    }

    @MainActor
    func testDiagramLoadsTablesAndRelationships() async throws {
        let vm = try await connectedAppVM()
        await vm.loadDiagram(schema: "qa")
        XCTAssertNil(vm.errorMessage)
        XCTAssertTrue(vm.erdVM.visibleNodes.contains { $0.name == "people" })
        XCTAssertFalse(vm.erdVM.visibleEdges.isEmpty, "child → parent FK must be drawn")
    }
}

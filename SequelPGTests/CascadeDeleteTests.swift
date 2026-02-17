import XCTest
@testable import SequelPG

// MARK: - Cascade Delete Tests

/// Tests for the cascade delete on foreign key violation feature:
/// - deleteContentRow/deleteQueryRow set cascadeDeleteContext on FK violation
/// - executeCascadeDelete builds CTE SQL, clears context, and refreshes data
/// - executeCascadeDelete handles errors and nil context gracefully
@MainActor
final class CascadeDeleteTests: XCTestCase {

    private var mockDB: MockDatabaseClient!
    private var mockKeychain: MockKeychainService!
    private var connectionStore: ConnectionStore!
    private var testDefaults: UserDefaults!
    private var vm: AppViewModel!

    override func setUp() {
        super.setUp()
        mockDB = MockDatabaseClient()
        mockKeychain = MockKeychainService()
        testDefaults = UserDefaults(suiteName: "com.sequelpg.cascadedelete.\(UUID().uuidString)")!
        connectionStore = ConnectionStore(defaults: testDefaults)
        vm = AppViewModel(
            connectionStore: connectionStore,
            keychainService: mockKeychain,
            dbClient: mockDB
        )
    }

    override func tearDown() {
        vm = nil
        connectionStore = nil
        testDefaults.removePersistentDomain(forName: testDefaults.volatileDomainNames.first ?? "")
        testDefaults = nil
        mockKeychain = nil
        mockDB = nil
        super.tearDown()
    }

    // MARK: - Helpers

    private func makeProfile(
        name: String = "Test DB",
        host: String = "localhost",
        port: Int = 5432,
        database: String = "testdb",
        username: String = "testuser",
        sslMode: SSLMode = .prefer
    ) -> ConnectionProfile {
        ConnectionProfile(
            name: name,
            host: host,
            port: port,
            database: database,
            username: username,
            sslMode: sslMode
        )
    }

    private func makeConnectedVM(profile: ConnectionProfile? = nil) async {
        let p = profile ?? makeProfile()
        mockKeychain.seed(password: "secret", forProfile: p)
        await vm.connect(profile: p)
    }

    private func makePKColumn(
        name: String,
        position: Int,
        dataType: String = "integer"
    ) -> ColumnInfo {
        ColumnInfo(
            name: name,
            ordinalPosition: position,
            dataType: dataType,
            isNullable: false,
            columnDefault: nil,
            characterMaximumLength: nil,
            isPrimaryKey: true
        )
    }

    private func makeColumn(
        name: String,
        position: Int,
        dataType: String = "text",
        isPrimaryKey: Bool = false
    ) -> ColumnInfo {
        ColumnInfo(
            name: name,
            ordinalPosition: position,
            dataType: dataType,
            isNullable: true,
            columnDefault: nil,
            characterMaximumLength: nil,
            isPrimaryKey: isPrimaryKey
        )
    }

    private func setupContentState(
        schema: String = "public",
        tableName: String = "users",
        columns: [ColumnInfo]? = nil,
        contentResult: QueryResult? = nil
    ) {
        let cols = columns ?? [
            makePKColumn(name: "id", position: 1),
            makeColumn(name: "name", position: 2),
        ]
        let result = contentResult ?? QueryResult(
            columns: ["id", "name"],
            rows: [
                [.text("1"), .text("Alice")],
                [.text("2"), .text("Bob")],
            ],
            executionTime: 0.05,
            rowsAffected: nil,
            isTruncated: false
        )

        vm.navigatorVM.selectedObject = DBObject(schema: schema, name: tableName, type: .table)
        vm.tableVM.setColumns(cols)
        vm.tableVM.setContentResult(result)
    }

    private func setupQueryState(
        schema: String = "public",
        tableName: String = "users",
        columns: [ColumnInfo]? = nil,
        queryResult: QueryResult? = nil
    ) {
        let cols = columns ?? [
            makePKColumn(name: "id", position: 1),
            makeColumn(name: "name", position: 2),
        ]
        let result = queryResult ?? QueryResult(
            columns: ["id", "name"],
            rows: [
                [.text("1"), .text("Alice")],
                [.text("2"), .text("Bob")],
            ],
            executionTime: 0.05,
            rowsAffected: nil,
            isTruncated: false
        )

        vm.queryVM.editableTableContext = (schema: schema, table: tableName)
        vm.queryVM.editableColumns = cols
        vm.queryVM.result = result
    }

    /// Returns a stubbed FK metadata result simulating one child table referencing
    /// the parent via a single-column FK.
    private func makeFKMetadataResult(
        childSchema: String = "public",
        childTable: String = "orders",
        childColumn: String = "user_id",
        parentColumn: String = "id"
    ) -> QueryResult {
        QueryResult(
            columns: ["child_schema", "child_table", "child_column", "parent_column"],
            rows: [
                [.text(childSchema), .text(childTable), .text(childColumn), .text(parentColumn)]
            ],
            executionTime: 0.01,
            rowsAffected: nil,
            isTruncated: false
        )
    }

    private func emptyQueryResult() -> QueryResult {
        QueryResult(
            columns: [],
            rows: [],
            executionTime: 0.01,
            rowsAffected: nil,
            isTruncated: false
        )
    }

    // MARK: - deleteContentRow sets cascadeDeleteContext on FK violation

    func testDeleteContentRowSetsCascadeDeleteContextOnFKViolation() async {
        await makeConnectedVM()
        setupContentState()

        // Configure mock to throw FK violation on the DELETE query
        await mockDB.setRunQueryHandler { sql in
            if sql.contains("DELETE FROM") {
                throw AppError.foreignKeyViolation("Key (id)=(1) is still referenced from table \"orders\"")
            }
            return QueryResult(columns: [], rows: [], executionTime: 0.01, rowsAffected: nil, isTruncated: false)
        }

        await vm.deleteContentRow(rowIndex: 0)

        // cascadeDeleteContext should be set instead of errorMessage
        XCTAssertNotNil(vm.cascadeDeleteContext)
        XCTAssertNil(vm.errorMessage)
        XCTAssertEqual(vm.cascadeDeleteContext?.schema, "public")
        XCTAssertEqual(vm.cascadeDeleteContext?.table, "users")
        XCTAssertEqual(vm.cascadeDeleteContext?.source, .content)
        XCTAssertTrue(vm.cascadeDeleteContext?.errorMessage.contains("orders") ?? false)
    }

    func testDeleteContentRowCascadeContextContainsPKValues() async {
        await makeConnectedVM()
        setupContentState()

        await mockDB.setRunQueryHandler { sql in
            if sql.contains("DELETE FROM") {
                throw AppError.foreignKeyViolation("FK error")
            }
            return QueryResult(columns: [], rows: [], executionTime: 0.01, rowsAffected: nil, isTruncated: false)
        }

        await vm.deleteContentRow(rowIndex: 0)

        XCTAssertNotNil(vm.cascadeDeleteContext)
        let pkValues = vm.cascadeDeleteContext?.pkValues ?? []
        XCTAssertEqual(pkValues.count, 1)
        XCTAssertEqual(pkValues[0].column, "id")
        XCTAssertEqual(pkValues[0].value, .text("1"))
    }

    func testDeleteContentRowCascadeContextWithCompositePK() async {
        await makeConnectedVM()
        setupContentState(
            columns: [
                makePKColumn(name: "order_id", position: 1),
                makePKColumn(name: "product_id", position: 2),
                makeColumn(name: "qty", position: 3),
            ],
            contentResult: QueryResult(
                columns: ["order_id", "product_id", "qty"],
                rows: [[.text("10"), .text("20"), .text("5")]],
                executionTime: 0.01,
                rowsAffected: nil,
                isTruncated: false
            )
        )

        await mockDB.setRunQueryHandler { sql in
            if sql.contains("DELETE FROM") {
                throw AppError.foreignKeyViolation("FK composite error")
            }
            return QueryResult(columns: [], rows: [], executionTime: 0.01, rowsAffected: nil, isTruncated: false)
        }

        await vm.deleteContentRow(rowIndex: 0)

        XCTAssertNotNil(vm.cascadeDeleteContext)
        let pkValues = vm.cascadeDeleteContext?.pkValues ?? []
        XCTAssertEqual(pkValues.count, 2)
        XCTAssertEqual(pkValues[0].column, "order_id")
        XCTAssertEqual(pkValues[0].value, .text("10"))
        XCTAssertEqual(pkValues[1].column, "product_id")
        XCTAssertEqual(pkValues[1].value, .text("20"))
    }

    func testDeleteContentRowNonFKErrorStillSetsErrorMessage() async {
        await makeConnectedVM()
        setupContentState()

        await mockDB.setRunQueryHandler { sql in
            if sql.contains("DELETE FROM") {
                throw AppError.queryFailed("permission denied")
            }
            return QueryResult(columns: [], rows: [], executionTime: 0.01, rowsAffected: nil, isTruncated: false)
        }

        await vm.deleteContentRow(rowIndex: 0)

        // Non-FK AppError goes to errorMessage, not cascadeDeleteContext
        XCTAssertNil(vm.cascadeDeleteContext)
        XCTAssertNotNil(vm.errorMessage)
        XCTAssertTrue(vm.errorMessage?.contains("permission denied") ?? false)
    }

    func testDeleteContentRowGenericErrorSetsErrorMessage() async {
        await makeConnectedVM()
        setupContentState()

        // A non-AppError should fall through to the generic catch
        await mockDB.setShouldThrowOnRunQuery(true)
        await mockDB.setRunQueryError(AppError.queryFailed("generic failure"))

        await vm.deleteContentRow(rowIndex: 0)

        XCTAssertNil(vm.cascadeDeleteContext)
        XCTAssertNotNil(vm.errorMessage)
    }

    // MARK: - deleteQueryRow sets cascadeDeleteContext on FK violation

    func testDeleteQueryRowSetsCascadeDeleteContextOnFKViolation() async {
        await makeConnectedVM()
        setupQueryState()

        await mockDB.setRunQueryHandler { sql in
            if sql.contains("DELETE FROM") {
                throw AppError.foreignKeyViolation("Key (id)=(1) referenced from \"orders\"")
            }
            return QueryResult(columns: [], rows: [], executionTime: 0.01, rowsAffected: nil, isTruncated: false)
        }

        await vm.deleteQueryRow(rowIndex: 0)

        XCTAssertNotNil(vm.cascadeDeleteContext)
        XCTAssertNil(vm.errorMessage)
        XCTAssertEqual(vm.cascadeDeleteContext?.schema, "public")
        XCTAssertEqual(vm.cascadeDeleteContext?.table, "users")
        XCTAssertEqual(vm.cascadeDeleteContext?.source, .query)
    }

    func testDeleteQueryRowCascadeContextContainsPKValues() async {
        await makeConnectedVM()
        setupQueryState()

        await mockDB.setRunQueryHandler { sql in
            if sql.contains("DELETE FROM") {
                throw AppError.foreignKeyViolation("FK error")
            }
            return QueryResult(columns: [], rows: [], executionTime: 0.01, rowsAffected: nil, isTruncated: false)
        }

        await vm.deleteQueryRow(rowIndex: 1)

        XCTAssertNotNil(vm.cascadeDeleteContext)
        let pkValues = vm.cascadeDeleteContext?.pkValues ?? []
        XCTAssertEqual(pkValues.count, 1)
        XCTAssertEqual(pkValues[0].column, "id")
        XCTAssertEqual(pkValues[0].value, .text("2"))
    }

    func testDeleteQueryRowNonFKErrorStillSetsErrorMessage() async {
        await makeConnectedVM()
        setupQueryState()

        await mockDB.setRunQueryHandler { sql in
            if sql.contains("DELETE FROM") {
                throw AppError.queryFailed("timeout")
            }
            return QueryResult(columns: [], rows: [], executionTime: 0.01, rowsAffected: nil, isTruncated: false)
        }

        await vm.deleteQueryRow(rowIndex: 0)

        XCTAssertNil(vm.cascadeDeleteContext)
        XCTAssertNotNil(vm.errorMessage)
        XCTAssertTrue(vm.errorMessage?.contains("timeout") ?? false)
    }

    func testDeleteQueryRowCascadeContextErrorMessagePreservesDetail() async {
        await makeConnectedVM()
        setupQueryState()

        let fkMsg = "update or delete on table \"users\" violates foreign key constraint"
        await mockDB.setRunQueryHandler { sql in
            if sql.contains("DELETE FROM") {
                throw AppError.foreignKeyViolation(fkMsg)
            }
            return QueryResult(columns: [], rows: [], executionTime: 0.01, rowsAffected: nil, isTruncated: false)
        }

        await vm.deleteQueryRow(rowIndex: 0)

        XCTAssertEqual(vm.cascadeDeleteContext?.errorMessage, fkMsg)
    }

    // MARK: - executeCascadeDelete returns early when context is nil

    func testExecuteCascadeDeleteReturnsEarlyWhenContextNil() async {
        await makeConnectedVM()
        vm.cascadeDeleteContext = nil

        await vm.executeCascadeDelete()

        // No queries should have been run (beyond those from connect)
        let allSQLs = await mockDB.getAllRunQuerySQLs()
        // connect runs listDatabases and listSchemas but not runQuery
        XCTAssertTrue(allSQLs.isEmpty)
        XCTAssertNil(vm.errorMessage)
    }

    // MARK: - executeCascadeDelete clears context and calls CTE SQL

    func testExecuteCascadeDeleteClearsContext() async {
        await makeConnectedVM()
        setupContentState()

        // Set up cascade context as if deleteContentRow had set it
        vm.cascadeDeleteContext = AppViewModel.CascadeDeleteContext(
            schema: "public",
            table: "users",
            pkValues: [(column: "id", value: .text("1"))],
            errorMessage: "FK error",
            source: .content
        )

        // Mock: FK query returns one child, cascade delete succeeds
        await mockDB.setRunQueryHandler { sql in
            if sql.contains("pg_constraint") {
                return QueryResult(
                    columns: ["child_schema", "child_table", "child_column", "parent_column"],
                    rows: [[.text("public"), .text("orders"), .text("user_id"), .text("id")]],
                    executionTime: 0.01,
                    rowsAffected: nil,
                    isTruncated: false
                )
            }
            // All other queries succeed with empty result
            return QueryResult(columns: [], rows: [], executionTime: 0.01, rowsAffected: nil, isTruncated: false)
        }

        await vm.executeCascadeDelete()

        XCTAssertNil(vm.cascadeDeleteContext)
    }

    func testExecuteCascadeDeleteRunsCTESQL() async {
        await makeConnectedVM()
        setupContentState()

        vm.cascadeDeleteContext = AppViewModel.CascadeDeleteContext(
            schema: "public",
            table: "users",
            pkValues: [(column: "id", value: .text("42"))],
            errorMessage: "FK error",
            source: .content
        )

        await mockDB.setRunQueryHandler { sql in
            if sql.contains("pg_constraint") {
                return QueryResult(
                    columns: ["child_schema", "child_table", "child_column", "parent_column"],
                    rows: [[.text("public"), .text("orders"), .text("user_id"), .text("id")]],
                    executionTime: 0.01,
                    rowsAffected: nil,
                    isTruncated: false
                )
            }
            return QueryResult(columns: [], rows: [], executionTime: 0.01, rowsAffected: nil, isTruncated: false)
        }

        await vm.executeCascadeDelete()

        let allSQLs = await mockDB.getAllRunQuerySQLs()
        // Should contain the CTE cascade SQL with "WITH del_child0 AS (DELETE FROM"
        let cascadeSQL = allSQLs.first { $0.contains("WITH") && $0.contains("del_child") }
        XCTAssertNotNil(cascadeSQL, "Expected a CTE cascade DELETE SQL")
        // Verify it deletes from child table
        XCTAssertTrue(cascadeSQL?.contains("\"orders\"") ?? false)
        XCTAssertTrue(cascadeSQL?.contains("\"user_id\" = '42'") ?? false)
        // Verify it deletes the parent row
        XCTAssertTrue(cascadeSQL?.contains("DELETE FROM \"public\".\"users\"") ?? false)
        XCTAssertTrue(cascadeSQL?.contains("\"id\" = '42'") ?? false)
    }

    func testExecuteCascadeDeleteWithNoChildrenRunsPlainDelete() async {
        await makeConnectedVM()
        setupContentState()

        vm.cascadeDeleteContext = AppViewModel.CascadeDeleteContext(
            schema: "public",
            table: "users",
            pkValues: [(column: "id", value: .text("1"))],
            errorMessage: "FK error",
            source: .content
        )

        // FK metadata query returns no children
        await mockDB.setRunQueryHandler { sql in
            if sql.contains("pg_constraint") {
                return QueryResult(
                    columns: ["child_schema", "child_table", "child_column", "parent_column"],
                    rows: [],
                    executionTime: 0.01,
                    rowsAffected: nil,
                    isTruncated: false
                )
            }
            return QueryResult(columns: [], rows: [], executionTime: 0.01, rowsAffected: nil, isTruncated: false)
        }

        await vm.executeCascadeDelete()

        let allSQLs = await mockDB.getAllRunQuerySQLs()
        // Should run a plain DELETE (no WITH clause) since no children found
        let deleteSQL = allSQLs.first { $0.contains("DELETE FROM") && !$0.contains("WITH") }
        XCTAssertNotNil(deleteSQL, "Expected a plain DELETE SQL when no children found")
        XCTAssertTrue(deleteSQL?.contains("\"public\".\"users\"") ?? false)
        XCTAssertTrue(deleteSQL?.contains("\"id\" = '1'") ?? false)
    }

    func testExecuteCascadeDeleteWithMultipleChildTables() async {
        await makeConnectedVM()
        setupContentState()

        vm.cascadeDeleteContext = AppViewModel.CascadeDeleteContext(
            schema: "public",
            table: "users",
            pkValues: [(column: "id", value: .text("1"))],
            errorMessage: "FK error",
            source: .content
        )

        // Two child tables referencing the parent
        await mockDB.setRunQueryHandler { sql in
            if sql.contains("pg_constraint") {
                return QueryResult(
                    columns: ["child_schema", "child_table", "child_column", "parent_column"],
                    rows: [
                        [.text("public"), .text("orders"), .text("user_id"), .text("id")],
                        [.text("public"), .text("comments"), .text("author_id"), .text("id")],
                    ],
                    executionTime: 0.01,
                    rowsAffected: nil,
                    isTruncated: false
                )
            }
            return QueryResult(columns: [], rows: [], executionTime: 0.01, rowsAffected: nil, isTruncated: false)
        }

        await vm.executeCascadeDelete()

        let allSQLs = await mockDB.getAllRunQuerySQLs()
        let cascadeSQL = allSQLs.first { $0.contains("WITH") && $0.contains("del_child") }
        XCTAssertNotNil(cascadeSQL, "Expected a CTE cascade DELETE SQL with multiple children")
        // Both child tables should appear in the CTE
        XCTAssertTrue(cascadeSQL?.contains("\"orders\"") ?? false)
        XCTAssertTrue(cascadeSQL?.contains("\"comments\"") ?? false)
        // Both CTEs should be present
        XCTAssertTrue(cascadeSQL?.contains("del_child0") ?? false)
        XCTAssertTrue(cascadeSQL?.contains("del_child1") ?? false)
    }

    // MARK: - executeCascadeDelete refreshes content page when source is .content

    func testExecuteCascadeDeleteRefreshesContentPage() async {
        await makeConnectedVM()
        setupContentState()

        vm.cascadeDeleteContext = AppViewModel.CascadeDeleteContext(
            schema: "public",
            table: "users",
            pkValues: [(column: "id", value: .text("1"))],
            errorMessage: "FK error",
            source: .content
        )

        await mockDB.setRunQueryHandler { _ in
            return QueryResult(columns: [], rows: [], executionTime: 0.01, rowsAffected: nil, isTruncated: false)
        }

        await vm.executeCascadeDelete()

        // After cascade delete with .content source, loadContentPage should run a SELECT
        let allSQLs = await mockDB.getAllRunQuerySQLs()
        let selectSQL = allSQLs.first { $0.contains("SELECT * FROM") }
        XCTAssertNotNil(selectSQL, "Expected loadContentPage to run a SELECT after cascade delete")
    }

    func testExecuteCascadeDeleteContentSourceRefreshesRowCount() async {
        await makeConnectedVM()
        setupContentState()
        vm.tableVM.approximateRowCount = 100
        await mockDB.setStubbedApproximateRowCount(99)

        vm.cascadeDeleteContext = AppViewModel.CascadeDeleteContext(
            schema: "public",
            table: "users",
            pkValues: [(column: "id", value: .text("1"))],
            errorMessage: "FK error",
            source: .content
        )

        await mockDB.setRunQueryHandler { _ in
            return QueryResult(columns: [], rows: [], executionTime: 0.01, rowsAffected: nil, isTruncated: false)
        }

        await vm.executeCascadeDelete()

        XCTAssertEqual(vm.tableVM.approximateRowCount, 99)
    }

    // MARK: - executeCascadeDelete re-executes query when source is .query

    func testExecuteCascadeDeleteReExecutesQueryForQuerySource() async {
        await makeConnectedVM()
        setupQueryState()
        vm.queryVM.queryText = "SELECT * FROM users"

        vm.cascadeDeleteContext = AppViewModel.CascadeDeleteContext(
            schema: "public",
            table: "users",
            pkValues: [(column: "id", value: .text("1"))],
            errorMessage: "FK error",
            source: .query
        )

        await mockDB.setRunQueryHandler { _ in
            return QueryResult(
                columns: ["id", "name"],
                rows: [[.text("2"), .text("Bob")]],
                executionTime: 0.01,
                rowsAffected: nil,
                isTruncated: false
            )
        }

        await vm.executeCascadeDelete()

        // The last SQL should be the re-executed user query
        let lastSQL = await mockDB.lastRunQuerySQL
        XCTAssertEqual(lastSQL, "SELECT * FROM users")
    }

    func testExecuteCascadeDeleteQuerySourceDoesNotRefreshRowCount() async {
        await makeConnectedVM()
        setupQueryState()
        vm.queryVM.queryText = "SELECT * FROM users"
        vm.tableVM.approximateRowCount = 100

        vm.cascadeDeleteContext = AppViewModel.CascadeDeleteContext(
            schema: "public",
            table: "users",
            pkValues: [(column: "id", value: .text("1"))],
            errorMessage: "FK error",
            source: .query
        )

        await mockDB.setRunQueryHandler { _ in
            return QueryResult(columns: [], rows: [], executionTime: 0.01, rowsAffected: nil, isTruncated: false)
        }

        await vm.executeCascadeDelete()

        // Row count should NOT have been refreshed for query source
        // (getApproximateRowCount is only called for .content source)
        XCTAssertEqual(vm.tableVM.approximateRowCount, 100)
    }

    // MARK: - executeCascadeDelete sets errorMessage on failure

    func testExecuteCascadeDeleteSetsErrorOnFKMetadataQueryFailure() async {
        await makeConnectedVM()

        vm.cascadeDeleteContext = AppViewModel.CascadeDeleteContext(
            schema: "public",
            table: "users",
            pkValues: [(column: "id", value: .text("1"))],
            errorMessage: "FK error",
            source: .content
        )

        // The FK metadata query (first runQuery call) fails
        await mockDB.setShouldThrowOnRunQuery(true)
        await mockDB.setRunQueryError(AppError.queryFailed("metadata query failed"))

        await vm.executeCascadeDelete()

        XCTAssertNotNil(vm.errorMessage)
        XCTAssertTrue(vm.errorMessage?.contains("metadata query failed") ?? false)
        // Context should have been cleared before the error
        XCTAssertNil(vm.cascadeDeleteContext)
    }

    func testExecuteCascadeDeleteSetsErrorOnCascadeSQLFailure() async {
        await makeConnectedVM()
        setupContentState()

        vm.cascadeDeleteContext = AppViewModel.CascadeDeleteContext(
            schema: "public",
            table: "users",
            pkValues: [(column: "id", value: .text("1"))],
            errorMessage: "FK error",
            source: .content
        )

        var callCount = 0
        await mockDB.setRunQueryHandler { sql in
            callCount += 1
            // First call: FK metadata query succeeds
            if sql.contains("pg_constraint") {
                return QueryResult(
                    columns: ["child_schema", "child_table", "child_column", "parent_column"],
                    rows: [[.text("public"), .text("orders"), .text("user_id"), .text("id")]],
                    executionTime: 0.01,
                    rowsAffected: nil,
                    isTruncated: false
                )
            }
            // Second call: cascade SQL fails
            if sql.contains("DELETE FROM") {
                throw AppError.queryFailed("cascade delete failed")
            }
            return QueryResult(columns: [], rows: [], executionTime: 0.01, rowsAffected: nil, isTruncated: false)
        }

        await vm.executeCascadeDelete()

        XCTAssertNotNil(vm.errorMessage)
        XCTAssertTrue(vm.errorMessage?.contains("cascade delete failed") ?? false)
    }

    // MARK: - executeCascadeDelete clears selected row

    func testExecuteCascadeDeleteClearsSelectedRow() async {
        await makeConnectedVM()
        setupContentState()
        vm.selectRow(index: 0, columns: ["id", "name"], values: [.text("1"), .text("Alice")])

        vm.cascadeDeleteContext = AppViewModel.CascadeDeleteContext(
            schema: "public",
            table: "users",
            pkValues: [(column: "id", value: .text("1"))],
            errorMessage: "FK error",
            source: .content
        )

        await mockDB.setRunQueryHandler { _ in
            return QueryResult(columns: [], rows: [], executionTime: 0.01, rowsAffected: nil, isTruncated: false)
        }

        await vm.executeCascadeDelete()

        XCTAssertNil(vm.tableVM.selectedRowIndex)
        XCTAssertNil(vm.tableVM.selectedRowData)
    }

    // MARK: - executeCascadeDelete with NULL PK values

    func testExecuteCascadeDeleteWithNullPKValue() async {
        await makeConnectedVM()
        setupContentState(
            contentResult: QueryResult(
                columns: ["id", "name"],
                rows: [[.null, .text("Alice")]],
                executionTime: 0.01,
                rowsAffected: nil,
                isTruncated: false
            )
        )

        vm.cascadeDeleteContext = AppViewModel.CascadeDeleteContext(
            schema: "public",
            table: "users",
            pkValues: [(column: "id", value: .null)],
            errorMessage: "FK error",
            source: .content
        )

        await mockDB.setRunQueryHandler { _ in
            return QueryResult(columns: [], rows: [], executionTime: 0.01, rowsAffected: nil, isTruncated: false)
        }

        await vm.executeCascadeDelete()

        let allSQLs = await mockDB.getAllRunQuerySQLs()
        // The cascade/delete SQL should use IS NULL for the null PK
        let deleteSQL = allSQLs.first { $0.contains("DELETE FROM") && $0.contains("IS NULL") }
        XCTAssertNotNil(deleteSQL, "Expected DELETE SQL with IS NULL for null PK value")
    }

    // MARK: - executeCascadeDelete with special characters

    func testExecuteCascadeDeleteWithSpecialCharactersInSchemaAndTable() async {
        await makeConnectedVM()
        setupContentState(schema: "my schema", tableName: "my table")

        vm.cascadeDeleteContext = AppViewModel.CascadeDeleteContext(
            schema: "my schema",
            table: "my table",
            pkValues: [(column: "id", value: .text("1"))],
            errorMessage: "FK error",
            source: .content
        )

        await mockDB.setRunQueryHandler { _ in
            return QueryResult(columns: [], rows: [], executionTime: 0.01, rowsAffected: nil, isTruncated: false)
        }

        await vm.executeCascadeDelete()

        let allSQLs = await mockDB.getAllRunQuerySQLs()
        // The FK metadata query should escape single quotes in schema/table
        let fkSQL = allSQLs.first { $0.contains("pg_constraint") || $0.contains("confrelid") }
        XCTAssertNotNil(fkSQL)
        XCTAssertTrue(fkSQL?.contains("my schema") ?? false)
        XCTAssertTrue(fkSQL?.contains("my table") ?? false)
    }

    // MARK: - CascadeDeleteContext initial state

    func testInitialCascadeDeleteContextIsNil() {
        XCTAssertNil(vm.cascadeDeleteContext)
    }

    // MARK: - Integration: delete -> FK violation -> cascade delete flow

    func testFullCascadeDeleteFlowFromContentTab() async {
        await makeConnectedVM()
        setupContentState()

        // Step 1: deleteContentRow throws FK violation
        await mockDB.setRunQueryHandler { sql in
            if sql.contains("DELETE FROM") {
                throw AppError.foreignKeyViolation("Key (id)=(1) referenced from orders")
            }
            return QueryResult(columns: [], rows: [], executionTime: 0.01, rowsAffected: nil, isTruncated: false)
        }

        await vm.deleteContentRow(rowIndex: 0)

        // Verify context was set
        XCTAssertNotNil(vm.cascadeDeleteContext)
        XCTAssertEqual(vm.cascadeDeleteContext?.source, .content)
        XCTAssertNil(vm.errorMessage)

        // Step 2: executeCascadeDelete succeeds
        await mockDB.setRunQueryHandler { sql in
            if sql.contains("pg_constraint") {
                return QueryResult(
                    columns: ["child_schema", "child_table", "child_column", "parent_column"],
                    rows: [[.text("public"), .text("orders"), .text("user_id"), .text("id")]],
                    executionTime: 0.01,
                    rowsAffected: nil,
                    isTruncated: false
                )
            }
            return QueryResult(columns: [], rows: [], executionTime: 0.01, rowsAffected: nil, isTruncated: false)
        }

        await vm.executeCascadeDelete()

        // Context should be cleared, no error
        XCTAssertNil(vm.cascadeDeleteContext)
        XCTAssertNil(vm.errorMessage)
    }

    func testFullCascadeDeleteFlowFromQueryTab() async {
        await makeConnectedVM()
        setupQueryState()
        vm.queryVM.queryText = "SELECT * FROM users"

        // Step 1: deleteQueryRow throws FK violation
        await mockDB.setRunQueryHandler { sql in
            if sql.contains("DELETE FROM") {
                throw AppError.foreignKeyViolation("FK violation on users")
            }
            return QueryResult(columns: [], rows: [], executionTime: 0.01, rowsAffected: nil, isTruncated: false)
        }

        await vm.deleteQueryRow(rowIndex: 0)

        XCTAssertNotNil(vm.cascadeDeleteContext)
        XCTAssertEqual(vm.cascadeDeleteContext?.source, .query)

        // Step 2: executeCascadeDelete re-executes the query
        await mockDB.setRunQueryHandler { _ in
            return QueryResult(
                columns: ["id", "name"],
                rows: [[.text("2"), .text("Bob")]],
                executionTime: 0.01,
                rowsAffected: nil,
                isTruncated: false
            )
        }

        await vm.executeCascadeDelete()

        XCTAssertNil(vm.cascadeDeleteContext)
        // The last SQL should be the re-executed user query
        let lastSQL = await mockDB.lastRunQuerySQL
        XCTAssertEqual(lastSQL, "SELECT * FROM users")
    }
}

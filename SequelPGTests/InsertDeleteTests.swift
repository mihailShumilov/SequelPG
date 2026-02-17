import XCTest
@testable import SequelPG

// MARK: - Insert & Delete Row Tests

/// Tests for the insert/delete row functionality in AppViewModel:
/// - buildDeleteSQL (tested indirectly via deleteContentRow/deleteQueryRow)
/// - deleteContentRow(rowIndex:)
/// - deleteQueryRow(rowIndex:)
/// - startInsertRow() / commitInsertRow() / cancelInsertRow()
/// - deleteInspectorRow()
/// - canDeleteContentRow, canDeleteQueryRow, canInsertContentRow
@MainActor
final class InsertDeleteTests: XCTestCase {

    private var mockDB: MockDatabaseClient!
    private var mockKeychain: MockKeychainService!
    private var connectionStore: ConnectionStore!
    private var testDefaults: UserDefaults!
    private var vm: AppViewModel!

    override func setUp() {
        super.setUp()
        mockDB = MockDatabaseClient()
        mockKeychain = MockKeychainService()
        testDefaults = UserDefaults(suiteName: "com.sequelpg.insertdelete.\(UUID().uuidString)")!
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

    /// Configures the VM with a selected table, columns with PK, and a content result
    /// so that deleteContentRow/insertContentRow can be tested.
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

    /// Configures the VM with a query result and editable table context so that
    /// deleteQueryRow can be tested.
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

    // MARK: - canDeleteContentRow

    func testCanDeleteContentRowReturnsFalseByDefault() {
        XCTAssertFalse(vm.canDeleteContentRow)
    }

    func testCanDeleteContentRowReturnsFalseWhenNoSelectedObject() {
        vm.navigatorVM.selectedObject = nil
        vm.tableVM.setColumns([makePKColumn(name: "id", position: 1)])
        XCTAssertFalse(vm.canDeleteContentRow)
    }

    func testCanDeleteContentRowReturnsFalseForView() {
        vm.navigatorVM.selectedObject = DBObject(schema: "public", name: "v_users", type: .view)
        vm.tableVM.setColumns([makePKColumn(name: "id", position: 1)])
        XCTAssertFalse(vm.canDeleteContentRow)
    }

    func testCanDeleteContentRowReturnsFalseWhenNoPrimaryKey() {
        vm.navigatorVM.selectedObject = DBObject(schema: "public", name: "users", type: .table)
        vm.tableVM.setColumns([
            makeColumn(name: "id", position: 1),
            makeColumn(name: "name", position: 2),
        ])
        XCTAssertFalse(vm.canDeleteContentRow)
    }

    func testCanDeleteContentRowReturnsTrueForTableWithPK() {
        vm.navigatorVM.selectedObject = DBObject(schema: "public", name: "users", type: .table)
        vm.tableVM.setColumns([
            makePKColumn(name: "id", position: 1),
            makeColumn(name: "name", position: 2),
        ])
        XCTAssertTrue(vm.canDeleteContentRow)
    }

    func testCanDeleteContentRowReturnsTrueForCompositePK() {
        vm.navigatorVM.selectedObject = DBObject(schema: "public", name: "order_items", type: .table)
        vm.tableVM.setColumns([
            makePKColumn(name: "order_id", position: 1),
            makePKColumn(name: "product_id", position: 2),
            makeColumn(name: "qty", position: 3),
        ])
        XCTAssertTrue(vm.canDeleteContentRow)
    }

    // MARK: - canDeleteQueryRow

    func testCanDeleteQueryRowReturnsFalseByDefault() {
        XCTAssertFalse(vm.canDeleteQueryRow)
    }

    func testCanDeleteQueryRowReturnsFalseWhenNoEditableContext() {
        vm.queryVM.editableTableContext = nil
        XCTAssertFalse(vm.canDeleteQueryRow)
    }

    func testCanDeleteQueryRowReturnsTrueWhenEditableContextExists() {
        vm.queryVM.editableTableContext = (schema: "public", table: "users")
        XCTAssertTrue(vm.canDeleteQueryRow)
    }

    // MARK: - canInsertContentRow

    func testCanInsertContentRowReturnsFalseByDefault() {
        XCTAssertFalse(vm.canInsertContentRow)
    }

    func testCanInsertContentRowReturnsFalseWhenNoSelectedObject() {
        vm.navigatorVM.selectedObject = nil
        XCTAssertFalse(vm.canInsertContentRow)
    }

    func testCanInsertContentRowReturnsFalseForView() {
        vm.navigatorVM.selectedObject = DBObject(schema: "public", name: "v_users", type: .view)
        XCTAssertFalse(vm.canInsertContentRow)
    }

    func testCanInsertContentRowReturnsTrueForTable() {
        vm.navigatorVM.selectedObject = DBObject(schema: "public", name: "users", type: .table)
        XCTAssertTrue(vm.canInsertContentRow)
    }

    func testCanInsertContentRowReturnsTrueEvenWithoutPK() {
        // Insert does not require PK columns -- only a table type is needed
        vm.navigatorVM.selectedObject = DBObject(schema: "public", name: "logs", type: .table)
        vm.tableVM.setColumns([makeColumn(name: "message", position: 1)])
        XCTAssertTrue(vm.canInsertContentRow)
    }

    // MARK: - deleteContentRow(rowIndex:) - SQL Generation
    // Since buildDeleteSQL is private, we verify the SQL by finding the DELETE statement
    // among all recorded SQL calls (deleteContentRow also runs loadContentPage afterward).

    func testDeleteContentRowGeneratesCorrectSQL() async {
        await makeConnectedVM()
        setupContentState()

        await vm.deleteContentRow(rowIndex: 0)

        let allSQLs = await mockDB.getAllRunQuerySQLs()
        let deleteSQL = allSQLs.first { $0.contains("DELETE FROM") }
        XCTAssertNotNil(deleteSQL)
        XCTAssertTrue(deleteSQL?.contains("\"public\".\"users\"") ?? false)
        XCTAssertTrue(deleteSQL?.contains("\"id\" = '1'") ?? false)
    }

    func testDeleteContentRowGeneratesCorrectSQLForSecondRow() async {
        await makeConnectedVM()
        setupContentState()

        await vm.deleteContentRow(rowIndex: 1)

        let allSQLs = await mockDB.getAllRunQuerySQLs()
        let deleteSQL = allSQLs.first { $0.contains("DELETE FROM") }
        XCTAssertNotNil(deleteSQL)
        XCTAssertTrue(deleteSQL?.contains("\"id\" = '2'") ?? false)
    }

    func testDeleteContentRowWithCompositePK() async {
        await makeConnectedVM()
        setupContentState(
            columns: [
                makePKColumn(name: "order_id", position: 1),
                makePKColumn(name: "product_id", position: 2),
                makeColumn(name: "qty", position: 3),
            ],
            contentResult: QueryResult(
                columns: ["order_id", "product_id", "qty"],
                rows: [
                    [.text("10"), .text("20"), .text("5")],
                ],
                executionTime: 0.01,
                rowsAffected: nil,
                isTruncated: false
            )
        )

        await vm.deleteContentRow(rowIndex: 0)

        let allSQLs = await mockDB.getAllRunQuerySQLs()
        let deleteSQL = allSQLs.first { $0.contains("DELETE FROM") }
        XCTAssertNotNil(deleteSQL)
        XCTAssertTrue(deleteSQL?.contains("\"order_id\" = '10'") ?? false)
        XCTAssertTrue(deleteSQL?.contains("\"product_id\" = '20'") ?? false)
        XCTAssertTrue(deleteSQL?.contains(" AND ") ?? false)
    }

    func testDeleteContentRowWithNullPKValue() async {
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

        await vm.deleteContentRow(rowIndex: 0)

        let allSQLs = await mockDB.getAllRunQuerySQLs()
        let deleteSQL = allSQLs.first { $0.contains("DELETE FROM") }
        XCTAssertNotNil(deleteSQL)
        XCTAssertTrue(deleteSQL?.contains("\"id\" IS NULL") ?? false)
    }

    func testDeleteContentRowWithSpecialCharactersInSchema() async {
        await makeConnectedVM()
        setupContentState(schema: "my schema", tableName: "my table")

        await vm.deleteContentRow(rowIndex: 0)

        let allSQLs = await mockDB.getAllRunQuerySQLs()
        let deleteSQL = allSQLs.first { $0.contains("DELETE FROM") }
        XCTAssertNotNil(deleteSQL)
        XCTAssertTrue(deleteSQL?.contains("\"my schema\".\"my table\"") ?? false)
    }

    func testDeleteContentRowWithSingleQuoteInValue() async {
        await makeConnectedVM()
        setupContentState(
            contentResult: QueryResult(
                columns: ["id", "name"],
                rows: [[.text("1"), .text("O'Brien")]],
                executionTime: 0.01,
                rowsAffected: nil,
                isTruncated: false
            )
        )

        await vm.deleteContentRow(rowIndex: 0)

        // The delete uses id=1, not the name, so quotes in name don't matter for WHERE
        let allSQLs = await mockDB.getAllRunQuerySQLs()
        let deleteSQL = allSQLs.first { $0.contains("DELETE FROM") }
        XCTAssertNotNil(deleteSQL)
        XCTAssertTrue(deleteSQL?.contains("\"id\" = '1'") ?? false)
    }

    // MARK: - deleteContentRow(rowIndex:) - State Changes

    func testDeleteContentRowClearsSelectedRow() async {
        await makeConnectedVM()
        setupContentState()
        vm.selectRow(index: 0, columns: ["id", "name"], values: [.text("1"), .text("Alice")])

        await vm.deleteContentRow(rowIndex: 0)

        XCTAssertNil(vm.tableVM.selectedRowIndex)
        XCTAssertNil(vm.tableVM.selectedRowData)
    }

    func testDeleteContentRowRefreshesRowCount() async {
        await makeConnectedVM()
        setupContentState()
        vm.tableVM.approximateRowCount = 100
        await mockDB.setStubbedApproximateRowCount(99)

        await vm.deleteContentRow(rowIndex: 0)

        XCTAssertEqual(vm.tableVM.approximateRowCount, 99)
    }

    func testDeleteContentRowReloadsContentPage() async {
        await makeConnectedVM()
        setupContentState()

        await vm.deleteContentRow(rowIndex: 0)

        // After delete, loadContentPage is called which runs a SELECT query.
        // The last SQL should be the SELECT (not the DELETE), since loadContentPage runs after.
        let lastSQL = await mockDB.lastRunQuerySQL
        XCTAssertNotNil(lastSQL)
        XCTAssertTrue(lastSQL?.contains("SELECT * FROM") ?? false)
    }

    // MARK: - deleteContentRow(rowIndex:) - Guard Clauses

    func testDeleteContentRowReturnsEarlyWhenNoSelectedObject() async {
        await makeConnectedVM()
        vm.navigatorVM.selectedObject = nil
        vm.tableVM.setColumns([makePKColumn(name: "id", position: 1)])
        vm.tableVM.setContentResult(QueryResult(
            columns: ["id"], rows: [[.text("1")]],
            executionTime: 0.01, rowsAffected: nil, isTruncated: false
        ))

        await vm.deleteContentRow(rowIndex: 0)

        // No query should be run for the delete
        let lastSQL = await mockDB.lastRunQuerySQL
        // lastRunQuerySQL would only be set by connect's calls, not a delete
        XCTAssertNil(lastSQL)
    }

    func testDeleteContentRowReturnsEarlyWhenNoContentResult() async {
        await makeConnectedVM()
        vm.navigatorVM.selectedObject = DBObject(schema: "public", name: "users", type: .table)
        vm.tableVM.setColumns([makePKColumn(name: "id", position: 1)])
        // No content result set

        await vm.deleteContentRow(rowIndex: 0)

        let lastSQL = await mockDB.lastRunQuerySQL
        XCTAssertNil(lastSQL)
    }

    func testDeleteContentRowReturnsEarlyWhenNoPKColumns() async {
        await makeConnectedVM()
        vm.navigatorVM.selectedObject = DBObject(schema: "public", name: "users", type: .table)
        vm.tableVM.setColumns([
            makeColumn(name: "id", position: 1),
            makeColumn(name: "name", position: 2),
        ])
        vm.tableVM.setContentResult(QueryResult(
            columns: ["id", "name"], rows: [[.text("1"), .text("Alice")]],
            executionTime: 0.01, rowsAffected: nil, isTruncated: false
        ))

        await vm.deleteContentRow(rowIndex: 0)

        let lastSQL = await mockDB.lastRunQuerySQL
        XCTAssertNil(lastSQL)
    }

    func testDeleteContentRowReturnsEarlyWhenRowIndexOutOfBounds() async {
        await makeConnectedVM()
        setupContentState()

        // Content has 2 rows (indices 0 and 1); index 5 is out of bounds
        await vm.deleteContentRow(rowIndex: 5)

        let lastSQL = await mockDB.lastRunQuerySQL
        XCTAssertNil(lastSQL)
    }

    func testDeleteContentRowSetsErrorWhenPKColumnMissingFromResult() async {
        await makeConnectedVM()
        // Columns declare "id" as PK, but the content result doesn't have "id" column
        vm.navigatorVM.selectedObject = DBObject(schema: "public", name: "users", type: .table)
        vm.tableVM.setColumns([makePKColumn(name: "id", position: 1)])
        vm.tableVM.setContentResult(QueryResult(
            columns: ["name", "email"],
            rows: [[.text("Alice"), .text("alice@test.com")]],
            executionTime: 0.01, rowsAffected: nil, isTruncated: false
        ))

        await vm.deleteContentRow(rowIndex: 0)

        XCTAssertEqual(vm.errorMessage, "Cannot delete: primary key columns missing from result")
    }

    // MARK: - deleteContentRow(rowIndex:) - Error Handling

    func testDeleteContentRowSetsErrorOnQueryFailure() async {
        await makeConnectedVM()
        setupContentState()
        await mockDB.setShouldThrowOnRunQuery(true)

        await vm.deleteContentRow(rowIndex: 0)

        XCTAssertNotNil(vm.errorMessage)
        XCTAssertTrue(vm.errorMessage?.contains("mock query error") ?? false)
    }

    // MARK: - deleteQueryRow(rowIndex:) - SQL Generation

    func testDeleteQueryRowGeneratesCorrectSQL() async {
        await makeConnectedVM()
        setupQueryState()

        await vm.deleteQueryRow(rowIndex: 0)

        let lastSQL = await mockDB.lastRunQuerySQL
        XCTAssertNotNil(lastSQL)
        // The last SQL might be the re-executed query, but the delete should have run.
        // Since executeQuery is called afterward with empty queryText, it will be a no-op.
        // So the last SQL should be the DELETE.
        XCTAssertTrue(lastSQL?.contains("DELETE FROM") ?? false)
        XCTAssertTrue(lastSQL?.contains("\"public\".\"users\"") ?? false)
        XCTAssertTrue(lastSQL?.contains("\"id\" = '1'") ?? false)
    }

    func testDeleteQueryRowWithCompositePK() async {
        await makeConnectedVM()
        setupQueryState(
            columns: [
                makePKColumn(name: "a_id", position: 1),
                makePKColumn(name: "b_id", position: 2),
                makeColumn(name: "val", position: 3),
            ],
            queryResult: QueryResult(
                columns: ["a_id", "b_id", "val"],
                rows: [[.text("100"), .text("200"), .text("x")]],
                executionTime: 0.01,
                rowsAffected: nil,
                isTruncated: false
            )
        )

        await vm.deleteQueryRow(rowIndex: 0)

        let lastSQL = await mockDB.lastRunQuerySQL
        XCTAssertNotNil(lastSQL)
        XCTAssertTrue(lastSQL?.contains("\"a_id\" = '100'") ?? false)
        XCTAssertTrue(lastSQL?.contains("\"b_id\" = '200'") ?? false)
    }

    func testDeleteQueryRowClearsSelectedRow() async {
        await makeConnectedVM()
        setupQueryState()
        vm.selectRow(index: 0, columns: ["id", "name"], values: [.text("1"), .text("Alice")])

        await vm.deleteQueryRow(rowIndex: 0)

        XCTAssertNil(vm.tableVM.selectedRowIndex)
        XCTAssertNil(vm.tableVM.selectedRowData)
    }

    func testDeleteQueryRowReExecutesQuery() async {
        await makeConnectedVM()
        setupQueryState()
        vm.queryVM.queryText = "SELECT * FROM users"

        await vm.deleteQueryRow(rowIndex: 0)

        // After delete, executeQuery is called with queryVM.queryText.
        // The last SQL should be the re-executed SELECT.
        let lastSQL = await mockDB.lastRunQuerySQL
        XCTAssertNotNil(lastSQL)
        XCTAssertEqual(lastSQL, "SELECT * FROM users")
    }

    // MARK: - deleteQueryRow(rowIndex:) - Guard Clauses

    func testDeleteQueryRowReturnsEarlyWhenNoEditableContext() async {
        await makeConnectedVM()
        vm.queryVM.editableTableContext = nil
        vm.queryVM.result = QueryResult(
            columns: ["id"], rows: [[.text("1")]],
            executionTime: 0.01, rowsAffected: nil, isTruncated: false
        )

        await vm.deleteQueryRow(rowIndex: 0)

        let lastSQL = await mockDB.lastRunQuerySQL
        XCTAssertNil(lastSQL)
    }

    func testDeleteQueryRowReturnsEarlyWhenNoResult() async {
        await makeConnectedVM()
        vm.queryVM.editableTableContext = (schema: "public", table: "users")
        vm.queryVM.editableColumns = [makePKColumn(name: "id", position: 1)]
        vm.queryVM.result = nil

        await vm.deleteQueryRow(rowIndex: 0)

        let lastSQL = await mockDB.lastRunQuerySQL
        XCTAssertNil(lastSQL)
    }

    func testDeleteQueryRowReturnsEarlyWhenNoPKColumns() async {
        await makeConnectedVM()
        vm.queryVM.editableTableContext = (schema: "public", table: "users")
        vm.queryVM.editableColumns = [
            makeColumn(name: "id", position: 1),
            makeColumn(name: "name", position: 2),
        ]
        vm.queryVM.result = QueryResult(
            columns: ["id", "name"], rows: [[.text("1"), .text("Alice")]],
            executionTime: 0.01, rowsAffected: nil, isTruncated: false
        )

        await vm.deleteQueryRow(rowIndex: 0)

        let lastSQL = await mockDB.lastRunQuerySQL
        XCTAssertNil(lastSQL)
    }

    func testDeleteQueryRowReturnsEarlyWhenRowIndexOutOfBounds() async {
        await makeConnectedVM()
        setupQueryState()

        await vm.deleteQueryRow(rowIndex: 10)

        let lastSQL = await mockDB.lastRunQuerySQL
        XCTAssertNil(lastSQL)
    }

    func testDeleteQueryRowSetsErrorWhenPKMissingFromResult() async {
        await makeConnectedVM()
        vm.queryVM.editableTableContext = (schema: "public", table: "users")
        vm.queryVM.editableColumns = [makePKColumn(name: "id", position: 1)]
        vm.queryVM.result = QueryResult(
            columns: ["name", "email"],
            rows: [[.text("Alice"), .text("alice@test.com")]],
            executionTime: 0.01, rowsAffected: nil, isTruncated: false
        )

        await vm.deleteQueryRow(rowIndex: 0)

        XCTAssertEqual(vm.errorMessage, "Cannot delete: primary key columns missing from result")
    }

    // MARK: - deleteQueryRow(rowIndex:) - Error Handling

    func testDeleteQueryRowSetsErrorOnQueryFailure() async {
        await makeConnectedVM()
        setupQueryState()
        await mockDB.setShouldThrowOnRunQuery(true)

        await vm.deleteQueryRow(rowIndex: 0)

        XCTAssertNotNil(vm.errorMessage)
        XCTAssertTrue(vm.errorMessage?.contains("mock query error") ?? false)
    }

    // MARK: - startInsertRow() / commitInsertRow() / cancelInsertRow()

    func testStartInsertRowSetsInsertingState() async {
        await makeConnectedVM()
        setupContentState()

        vm.startInsertRow()

        XCTAssertTrue(vm.tableVM.isInsertingRow)
        XCTAssertEqual(vm.tableVM.newRowValues.count, 2) // id, name
        XCTAssertEqual(vm.tableVM.newRowValues["id"], "")
        XCTAssertEqual(vm.tableVM.newRowValues["name"], "")
    }

    func testStartInsertRowClearsSelectedRow() async {
        await makeConnectedVM()
        setupContentState()
        vm.selectRow(index: 0, columns: ["id"], values: [.text("1")])

        vm.startInsertRow()

        XCTAssertNil(vm.tableVM.selectedRowIndex)
        XCTAssertNil(vm.tableVM.selectedRowData)
    }

    func testStartInsertRowReturnsEarlyWhenNoSelectedObject() async {
        await makeConnectedVM()
        vm.navigatorVM.selectedObject = nil

        vm.startInsertRow()

        XCTAssertFalse(vm.tableVM.isInsertingRow)
    }

    func testStartInsertRowReturnsEarlyForView() async {
        await makeConnectedVM()
        vm.navigatorVM.selectedObject = DBObject(schema: "public", name: "v_users", type: .view)

        vm.startInsertRow()

        XCTAssertFalse(vm.tableVM.isInsertingRow)
    }

    func testCancelInsertRowClearsState() async {
        await makeConnectedVM()
        setupContentState()
        vm.startInsertRow()

        vm.cancelInsertRow()

        XCTAssertFalse(vm.tableVM.isInsertingRow)
        XCTAssertTrue(vm.tableVM.newRowValues.isEmpty)
    }

    func testCommitInsertRowWithValuesGeneratesSQL() async {
        await makeConnectedVM()
        setupContentState()
        vm.startInsertRow()
        vm.tableVM.newRowValues["id"] = "42"
        vm.tableVM.newRowValues["name"] = "Charlie"

        await vm.commitInsertRow()

        XCTAssertNil(vm.errorMessage)
        XCTAssertFalse(vm.tableVM.isInsertingRow)
    }

    func testCommitInsertRowWithEmptyValuesUsesDefaults() async {
        await makeConnectedVM()
        setupContentState()
        vm.startInsertRow()
        // Leave all values empty — should generate INSERT INTO ... DEFAULT VALUES

        await vm.commitInsertRow()

        XCTAssertNil(vm.errorMessage)
        XCTAssertFalse(vm.tableVM.isInsertingRow)
    }

    func testCommitInsertRowWithSpecialSchemaAndTable() async {
        await makeConnectedVM()
        vm.navigatorVM.selectedObject = DBObject(schema: "my schema", name: "my table", type: .table)
        vm.tableVM.setColumns([
            makePKColumn(name: "id", position: 1),
        ])
        vm.startInsertRow()
        vm.tableVM.newRowValues["id"] = "1"

        await vm.commitInsertRow()

        XCTAssertNil(vm.errorMessage)
    }

    func testCommitInsertRowRefreshesRowCount() async {
        await makeConnectedVM()
        setupContentState()
        vm.tableVM.approximateRowCount = 10
        await mockDB.setStubbedApproximateRowCount(11)
        vm.startInsertRow()
        vm.tableVM.newRowValues["id"] = "3"

        await vm.commitInsertRow()

        XCTAssertEqual(vm.tableVM.approximateRowCount, 11)
    }

    func testCommitInsertRowNavigatesToLastPage() async {
        await makeConnectedVM()
        setupContentState()
        vm.tableVM.pageSize = 50
        await mockDB.setStubbedApproximateRowCount(150)
        vm.startInsertRow()
        vm.tableVM.newRowValues["id"] = "3"

        await vm.commitInsertRow()

        // 150 rows / 50 per page = 3 pages (indices 0, 1, 2); last page is 2
        XCTAssertEqual(vm.tableVM.currentPage, 2)
    }

    func testCommitInsertRowReloadsContentPage() async {
        await makeConnectedVM()
        setupContentState()
        vm.startInsertRow()
        vm.tableVM.newRowValues["id"] = "3"

        await vm.commitInsertRow()

        // The last SQL should be from loadContentPage (a SELECT)
        let lastSQL = await mockDB.lastRunQuerySQL
        XCTAssertNotNil(lastSQL)
        XCTAssertTrue(lastSQL?.contains("SELECT * FROM") ?? false)
    }

    func testCommitInsertRowReturnsEarlyWhenNoSelectedObject() async {
        await makeConnectedVM()
        vm.navigatorVM.selectedObject = nil

        await vm.commitInsertRow()

        let lastSQL = await mockDB.lastRunQuerySQL
        XCTAssertNil(lastSQL)
    }

    func testCommitInsertRowReturnsEarlyForView() async {
        await makeConnectedVM()
        vm.navigatorVM.selectedObject = DBObject(schema: "public", name: "v_users", type: .view)

        await vm.commitInsertRow()

        let lastSQL = await mockDB.lastRunQuerySQL
        XCTAssertNil(lastSQL)
    }

    func testCommitInsertRowKeepsInsertRowOnError() async {
        await makeConnectedVM()
        setupContentState()
        vm.startInsertRow()
        vm.tableVM.newRowValues["id"] = "bad"
        await mockDB.setShouldThrowOnRunQuery(true)

        await vm.commitInsertRow()

        XCTAssertNotNil(vm.errorMessage)
        // Insert row should remain visible so user can fix values
        XCTAssertTrue(vm.tableVM.isInsertingRow)
    }

    func testCommitInsertRowWithNullValue() async {
        await makeConnectedVM()
        setupContentState()
        vm.startInsertRow()
        vm.tableVM.newRowValues["id"] = "1"
        vm.tableVM.newRowValues["name"] = "NULL"

        await vm.commitInsertRow()

        XCTAssertNil(vm.errorMessage)
    }

    // MARK: - deleteInspectorRow()

    func testDeleteInspectorRowReturnsEarlyWhenNoRowSelected() async {
        await makeConnectedVM()
        vm.tableVM.selectedRowIndex = nil

        await vm.deleteInspectorRow()

        let lastSQL = await mockDB.lastRunQuerySQL
        XCTAssertNil(lastSQL)
    }

    func testDeleteInspectorRowRoutesToContentTabDelete() async {
        await makeConnectedVM()
        setupContentState()
        vm.selectedTab = .content
        vm.tableVM.selectedRowIndex = 0

        await vm.deleteInspectorRow()

        // Verify the delete was attempted (will end with SELECT from reload)
        let lastSQL = await mockDB.lastRunQuerySQL
        XCTAssertNotNil(lastSQL)
    }

    func testDeleteInspectorRowRoutesToQueryTabDelete() async {
        await makeConnectedVM()
        setupQueryState()
        vm.selectedTab = .query
        vm.tableVM.selectedRowIndex = 1

        await vm.deleteInspectorRow()

        // The delete SQL targets the query context (row index 1)
        let lastSQL = await mockDB.lastRunQuerySQL
        XCTAssertNotNil(lastSQL)
    }

    func testDeleteInspectorRowDoesNothingOnStructureTab() async {
        await makeConnectedVM()
        setupContentState()
        vm.selectedTab = .structure
        vm.tableVM.selectedRowIndex = 0

        await vm.deleteInspectorRow()

        // Structure tab is neither .content nor .query, so no delete occurs
        let lastSQL = await mockDB.lastRunQuerySQL
        XCTAssertNil(lastSQL)
    }

    func testDeleteInspectorRowClearsSelectionViaContentTab() async {
        await makeConnectedVM()
        setupContentState()
        vm.selectedTab = .content
        vm.selectRow(index: 0, columns: ["id", "name"], values: [.text("1"), .text("Alice")])

        await vm.deleteInspectorRow()

        XCTAssertNil(vm.tableVM.selectedRowIndex)
        XCTAssertNil(vm.tableVM.selectedRowData)
    }

    func testDeleteInspectorRowClearsSelectionViaQueryTab() async {
        await makeConnectedVM()
        setupQueryState()
        vm.selectedTab = .query
        vm.selectRow(index: 0, columns: ["id", "name"], values: [.text("1"), .text("Alice")])

        await vm.deleteInspectorRow()

        XCTAssertNil(vm.tableVM.selectedRowIndex)
        XCTAssertNil(vm.tableVM.selectedRowData)
    }

    // MARK: - buildDeleteSQL Edge Cases (via deleteContentRow)

    func testDeleteSQLWithSingleQuoteInPKValue() async {
        await makeConnectedVM()
        setupContentState(
            columns: [makePKColumn(name: "name", position: 1, dataType: "text")],
            contentResult: QueryResult(
                columns: ["name"],
                rows: [[.text("O'Reilly")]],
                executionTime: 0.01,
                rowsAffected: nil,
                isTruncated: false
            )
        )

        await vm.deleteContentRow(rowIndex: 0)

        // deleteContentRow runs DELETE then loadContentPage runs SELECT,
        // so we check allRunQuerySQLs for the DELETE statement.
        let allSQLs = await mockDB.getAllRunQuerySQLs()
        let deleteSQL = allSQLs.first { $0.contains("DELETE FROM") }
        XCTAssertNotNil(deleteSQL)
        // quoteLiteral escapes ' to ''
        XCTAssertTrue(deleteSQL?.contains("'O''Reilly'") ?? false)
    }

    func testDeleteSQLWithDoubleQuoteInColumnName() async {
        await makeConnectedVM()
        setupContentState(
            columns: [makePKColumn(name: "col\"name", position: 1)],
            contentResult: QueryResult(
                columns: ["col\"name"],
                rows: [[.text("42")]],
                executionTime: 0.01,
                rowsAffected: nil,
                isTruncated: false
            )
        )

        await vm.deleteContentRow(rowIndex: 0)

        let allSQLs = await mockDB.getAllRunQuerySQLs()
        let deleteSQL = allSQLs.first { $0.contains("DELETE FROM") }
        XCTAssertNotNil(deleteSQL)
        // quoteIdent doubles internal double-quotes
        XCTAssertTrue(deleteSQL?.contains("\"col\"\"name\"") ?? false)
    }

    func testDeleteSQLWithAllNullPKValuesStillGeneratesISNULL() async {
        await makeConnectedVM()
        setupContentState(
            columns: [
                makePKColumn(name: "a", position: 1),
                makePKColumn(name: "b", position: 2),
            ],
            contentResult: QueryResult(
                columns: ["a", "b"],
                rows: [[.null, .null]],
                executionTime: 0.01,
                rowsAffected: nil,
                isTruncated: false
            )
        )

        await vm.deleteContentRow(rowIndex: 0)

        let allSQLs = await mockDB.getAllRunQuerySQLs()
        let deleteSQL = allSQLs.first { $0.contains("DELETE FROM") }
        XCTAssertNotNil(deleteSQL)
        XCTAssertTrue(deleteSQL?.contains("\"a\" IS NULL") ?? false)
        XCTAssertTrue(deleteSQL?.contains("\"b\" IS NULL") ?? false)
    }

    // MARK: - commitInsertRow Edge Cases

    func testCommitInsertRowQuotesIdentifiers() async {
        await makeConnectedVM()
        vm.navigatorVM.selectedObject = DBObject(schema: "my\"schema", name: "my\"table", type: .table)
        vm.tableVM.setColumns([
            makePKColumn(name: "id", position: 1),
        ])
        vm.startInsertRow()
        vm.tableVM.newRowValues["id"] = "1"

        await vm.commitInsertRow()

        XCTAssertNil(vm.errorMessage)
    }

    // MARK: - Integration Scenarios

    func testDeleteThenInsertContentRow() async {
        await makeConnectedVM()
        setupContentState()
        vm.tableVM.approximateRowCount = 10

        // Delete row
        await mockDB.setStubbedApproximateRowCount(9)
        await vm.deleteContentRow(rowIndex: 0)
        XCTAssertEqual(vm.tableVM.approximateRowCount, 9)

        // Reset mock to not throw
        await mockDB.setShouldThrowOnRunQuery(false)

        // Insert row via new flow
        await mockDB.setStubbedApproximateRowCount(10)
        vm.startInsertRow()
        vm.tableVM.newRowValues["id"] = "3"
        await vm.commitInsertRow()
        XCTAssertEqual(vm.tableVM.approximateRowCount, 10)
    }

    func testDeleteContentRowThenSelectNewRow() async {
        await makeConnectedVM()
        setupContentState()
        vm.selectRow(index: 0, columns: ["id", "name"], values: [.text("1"), .text("Alice")])

        await vm.deleteContentRow(rowIndex: 0)

        // After delete, selection is cleared
        XCTAssertNil(vm.tableVM.selectedRowIndex)

        // Select a new row
        vm.selectRow(index: 0, columns: ["id", "name"], values: [.text("2"), .text("Bob")])
        XCTAssertEqual(vm.tableVM.selectedRowIndex, 0)
        XCTAssertEqual(vm.tableVM.selectedRowData?[0].value, .text("2"))
    }

    func testDeleteInspectorRowContentThenSwitchToQuery() async {
        await makeConnectedVM()
        setupContentState()
        vm.selectedTab = .content
        vm.selectRow(index: 0, columns: ["id", "name"], values: [.text("1"), .text("Alice")])

        await vm.deleteInspectorRow()

        // Switch tab
        vm.selectedTab = .query
        setupQueryState()

        // Verify query state is independent
        XCTAssertNotNil(vm.queryVM.result)
        XCTAssertTrue(vm.canDeleteQueryRow)
    }
}

// MARK: - MockDatabaseClient Additional Setter Helpers

extension MockDatabaseClient {
    func setStubbedApproximateRowCount(_ value: Int64) {
        stubbedApproximateRowCount = value
    }
}

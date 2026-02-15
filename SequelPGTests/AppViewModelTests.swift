import XCTest
@testable import SequelPG

// MARK: - Mock Database Client

/// Mock actor conforming to PostgresClientProtocol for testing AppViewModel
/// without a real PostgreSQL connection.
actor MockDatabaseClient: PostgresClientProtocol {
    // MARK: - Recorded state

    private(set) var connectCallCount = 0
    private(set) var disconnectCallCount = 0
    private(set) var lastConnectedProfile: ConnectionProfile?
    private(set) var lastConnectedPassword: String?
    private(set) var lastSwitchDatabase: String?
    private(set) var lastRunQuerySQL: String?
    private(set) var lastRunQueryMaxRows: Int?
    private(set) var lastGetColumnsSchema: String?
    private(set) var lastGetColumnsTable: String?
    private(set) var lastListTablesSchema: String?
    private(set) var lastListViewsSchema: String?
    private(set) var invalidateCacheCallCount = 0

    // MARK: - Configurable responses

    var connected = false
    var shouldThrowOnConnect = false
    var connectError: Error = AppError.connectionFailed("mock connection refused")
    var shouldThrowOnRunQuery = false
    var runQueryError: Error = AppError.queryFailed("mock query error")
    var shouldThrowOnListSchemas = false
    var shouldThrowOnListTables = false
    var shouldThrowOnListViews = false
    var shouldThrowOnGetColumns = false
    var shouldThrowOnGetApproximateRowCount = false
    var shouldThrowOnSwitchDatabase = false

    var stubbedDatabases: [String] = ["postgres", "testdb", "devdb"]
    var stubbedSchemas: [String] = ["public", "auth"]
    var stubbedTables: [DBObject] = [
        DBObject(schema: "public", name: "users", type: .table),
        DBObject(schema: "public", name: "posts", type: .table),
    ]
    var stubbedViews: [DBObject] = [
        DBObject(schema: "public", name: "active_users", type: .view)
    ]
    var stubbedColumns: [ColumnInfo] = [
        ColumnInfo(name: "id", ordinalPosition: 1, dataType: "integer", isNullable: false, columnDefault: nil, characterMaximumLength: nil, isPrimaryKey: true),
        ColumnInfo(name: "name", ordinalPosition: 2, dataType: "character varying", isNullable: true, columnDefault: nil, characterMaximumLength: 255),
    ]
    var stubbedPrimaryKeys: [String] = ["id"]
    var shouldThrowOnGetPrimaryKeys = false
    var stubbedApproximateRowCount: Int64 = 42
    var stubbedQueryResult = QueryResult(
        columns: ["id", "name"],
        rows: [[.text("1"), .text("Alice")], [.text("2"), .text("Bob")]],
        executionTime: 0.05,
        rowsAffected: nil,
        isTruncated: false
    )

    var isConnected: Bool { connected }

    func connect(profile: ConnectionProfile, password: String?) async throws {
        connectCallCount += 1
        lastConnectedProfile = profile
        lastConnectedPassword = password
        if shouldThrowOnConnect { throw connectError }
        connected = true
    }

    func disconnect() async {
        disconnectCallCount += 1
        connected = false
    }

    func runQuery(_ sql: String, maxRows: Int, timeout: TimeInterval) async throws -> QueryResult {
        lastRunQuerySQL = sql
        lastRunQueryMaxRows = maxRows
        if shouldThrowOnRunQuery { throw runQueryError }
        return stubbedQueryResult
    }

    func listSchemas() async throws -> [String] {
        if shouldThrowOnListSchemas { throw AppError.queryFailed("mock schema error") }
        return stubbedSchemas
    }

    func listTables(schema: String) async throws -> [DBObject] {
        lastListTablesSchema = schema
        if shouldThrowOnListTables { throw AppError.queryFailed("mock tables error") }
        return stubbedTables
    }

    func listViews(schema: String) async throws -> [DBObject] {
        lastListViewsSchema = schema
        if shouldThrowOnListViews { throw AppError.queryFailed("mock views error") }
        return stubbedViews
    }

    func getColumns(schema: String, table: String) async throws -> [ColumnInfo] {
        lastGetColumnsSchema = schema
        lastGetColumnsTable = table
        if shouldThrowOnGetColumns { throw AppError.queryFailed("mock columns error") }
        return stubbedColumns
    }

    func getPrimaryKeys(schema: String, table: String) async throws -> [String] {
        if shouldThrowOnGetPrimaryKeys { throw AppError.queryFailed("mock pk error") }
        return stubbedPrimaryKeys
    }

    func getApproximateRowCount(schema: String, table: String) async throws -> Int64 {
        if shouldThrowOnGetApproximateRowCount { throw AppError.queryFailed("mock count error") }
        return stubbedApproximateRowCount
    }

    func invalidateCache() async {
        invalidateCacheCallCount += 1
    }

    func listDatabases() async throws -> [String] {
        return stubbedDatabases
    }

    func switchDatabase(to database: String, profile: ConnectionProfile, password: String?) async throws {
        lastSwitchDatabase = database
        if shouldThrowOnSwitchDatabase { throw AppError.connectionFailed("mock switch error") }
        connected = true
    }
}

// MARK: - Mock Keychain Service

/// Mock KeychainService that stores passwords in memory.
final class MockKeychainService: KeychainServiceProtocol, @unchecked Sendable {
    private var store: [String: String] = [:]
    var shouldThrowOnLoad = false

    func save(password: String, forKey key: String) throws {
        store[key] = password
    }

    func load(forKey key: String) throws -> String? {
        if shouldThrowOnLoad { throw AppError.keychainError("mock load error") }
        return store[key]
    }

    func delete(forKey key: String) throws {
        store.removeValue(forKey: key)
    }

    /// Convenience to pre-seed a password for a profile.
    func seed(password: String, forProfile profile: ConnectionProfile) {
        store[profile.keychainKey] = password
    }
}

// MARK: - Tests

@MainActor
final class AppViewModelTests: XCTestCase {

    private var mockDB: MockDatabaseClient!
    private var mockKeychain: MockKeychainService!
    private var connectionStore: ConnectionStore!
    private var testDefaults: UserDefaults!
    private var vm: AppViewModel!

    override func setUp() {
        super.setUp()
        mockDB = MockDatabaseClient()
        mockKeychain = MockKeychainService()
        testDefaults = UserDefaults(suiteName: "com.sequelpg.tests.\(UUID().uuidString)")!
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

    // MARK: - Initialization

    func testInitialStateDefaults() {
        XCTAssertFalse(vm.isConnected)
        XCTAssertNil(vm.connectedProfileName)
        XCTAssertNil(vm.errorMessage)
        XCTAssertEqual(vm.selectedTab, .query)
        XCTAssertTrue(vm.showInspector)
    }

    func testInitCreatesChildViewModels() {
        XCTAssertNotNil(vm.connectionListVM)
        XCTAssertNotNil(vm.navigatorVM)
        XCTAssertNotNil(vm.tableVM)
        XCTAssertNotNil(vm.queryVM)
    }

    // MARK: - connect(profile:)

    func testConnectSetsIsConnectedTrue() async {
        let profile = makeProfile()
        await vm.connect(profile: profile)

        XCTAssertTrue(vm.isConnected)
    }

    func testConnectSetsConnectedProfileName() async {
        let profile = makeProfile(name: "My Production DB")
        await vm.connect(profile: profile)

        XCTAssertEqual(vm.connectedProfileName, "My Production DB")
    }

    func testConnectClearsErrorMessage() async {
        // Simulate a prior error
        vm.errorMessage = "previous error"

        let profile = makeProfile()
        await vm.connect(profile: profile)

        XCTAssertNil(vm.errorMessage)
    }

    func testConnectSwitchesSelectedTabToQuery() async {
        vm.selectedTab = .content
        let profile = makeProfile()
        await vm.connect(profile: profile)

        XCTAssertEqual(vm.selectedTab, .query)
    }

    func testConnectPassesPasswordFromKeychain() async {
        let profile = makeProfile()
        mockKeychain.seed(password: "s3cret", forProfile: profile)

        await vm.connect(profile: profile)

        let lastPassword = await mockDB.lastConnectedPassword
        XCTAssertEqual(lastPassword, "s3cret")
    }

    func testConnectPassesNilPasswordWhenKeychainEmpty() async {
        let profile = makeProfile()
        // No password seeded in mockKeychain

        await vm.connect(profile: profile)

        let lastPassword = await mockDB.lastConnectedPassword
        XCTAssertNil(lastPassword)
    }

    func testConnectPassesProfileToDbClient() async {
        let profile = makeProfile(name: "ProdDB", host: "db.example.com", port: 5433, database: "prod")
        await vm.connect(profile: profile)

        let lastProfile = await mockDB.lastConnectedProfile
        XCTAssertEqual(lastProfile?.name, "ProdDB")
        XCTAssertEqual(lastProfile?.host, "db.example.com")
        XCTAssertEqual(lastProfile?.port, 5433)
        XCTAssertEqual(lastProfile?.database, "prod")
    }

    func testConnectLoadsDatabases() async {
        let profile = makeProfile(database: "testdb")
        await vm.connect(profile: profile)

        XCTAssertEqual(vm.navigatorVM.databases, ["postgres", "testdb", "devdb"])
        XCTAssertEqual(vm.navigatorVM.selectedDatabase, "testdb")
    }

    func testConnectLoadsSchemas() async {
        let profile = makeProfile()
        await vm.connect(profile: profile)

        XCTAssertEqual(vm.navigatorVM.schemas, ["public", "auth"])
        // NavigatorViewModel.setSchemas defaults to "public" when available
        XCTAssertEqual(vm.navigatorVM.selectedSchema, "public")
    }

    func testConnectSetsConnectionStatusOnConnectionListVM() async {
        let profile = makeProfile()
        await vm.connect(profile: profile)

        XCTAssertEqual(vm.connectionListVM.connectionStatuses[profile.id], .connected)
    }

    func testConnectFailureSetsErrorMessage() async {
        await mockDB.setShouldThrowOnConnect(true)

        let profile = makeProfile()
        await vm.connect(profile: profile)

        XCTAssertFalse(vm.isConnected)
        XCTAssertNotNil(vm.errorMessage)
        XCTAssertTrue(vm.errorMessage?.contains("mock connection refused") ?? false)
    }

    func testConnectFailureSetsErrorStatusOnConnectionListVM() async {
        await mockDB.setShouldThrowOnConnect(true)

        let profile = makeProfile()
        await vm.connect(profile: profile)

        XCTAssertEqual(vm.connectionListVM.connectionStatuses[profile.id], .error)
    }

    func testConnectFailureDoesNotSetIsConnected() async {
        await mockDB.setShouldThrowOnConnect(true)

        let profile = makeProfile()
        await vm.connect(profile: profile)

        XCTAssertFalse(vm.isConnected)
        XCTAssertNil(vm.connectedProfileName)
    }

    func testConnectWithKeychainErrorStillConnectsWithNilPassword() async {
        mockKeychain.shouldThrowOnLoad = true

        let profile = makeProfile()
        await vm.connect(profile: profile)

        // keychainService.load throws, so password is nil (try? returns nil)
        let lastPassword = await mockDB.lastConnectedPassword
        XCTAssertNil(lastPassword)
        // Connection should still succeed since dbClient.connect was called with nil password
        XCTAssertTrue(vm.isConnected)
    }

    // MARK: - disconnect()

    func testDisconnectClearsIsConnected() async {
        await makeConnectedVM()
        XCTAssertTrue(vm.isConnected)

        await vm.disconnect()

        XCTAssertFalse(vm.isConnected)
    }

    func testDisconnectClearsConnectedProfileName() async {
        await makeConnectedVM()
        XCTAssertNotNil(vm.connectedProfileName)

        await vm.disconnect()

        XCTAssertNil(vm.connectedProfileName)
    }

    func testDisconnectClearsNavigator() async {
        await makeConnectedVM()
        XCTAssertFalse(vm.navigatorVM.databases.isEmpty)

        await vm.disconnect()

        XCTAssertTrue(vm.navigatorVM.databases.isEmpty)
        XCTAssertEqual(vm.navigatorVM.selectedDatabase, "")
        XCTAssertTrue(vm.navigatorVM.schemas.isEmpty)
        XCTAssertEqual(vm.navigatorVM.selectedSchema, "")
        XCTAssertTrue(vm.navigatorVM.tables.isEmpty)
        XCTAssertTrue(vm.navigatorVM.views.isEmpty)
        XCTAssertNil(vm.navigatorVM.selectedObject)
    }

    func testDisconnectClearsTableVM() async {
        await makeConnectedVM()
        // Populate tableVM with some data
        vm.tableVM.setColumns([
            ColumnInfo(name: "id", ordinalPosition: 1, dataType: "integer", isNullable: false, columnDefault: nil, characterMaximumLength: nil)
        ])

        await vm.disconnect()

        XCTAssertTrue(vm.tableVM.columns.isEmpty)
        XCTAssertNil(vm.tableVM.contentResult)
        XCTAssertEqual(vm.tableVM.approximateRowCount, 0)
    }

    func testDisconnectResetsSelectedTabToQuery() async {
        await makeConnectedVM()
        vm.selectedTab = .content

        await vm.disconnect()

        XCTAssertEqual(vm.selectedTab, .query)
    }

    func testDisconnectCallsDbClientDisconnect() async {
        await makeConnectedVM()

        await vm.disconnect()

        let callCount = await mockDB.disconnectCallCount
        XCTAssertEqual(callCount, 1)
    }

    func testDisconnectClearsConnectionListVMStatuses() async {
        await makeConnectedVM()
        XCTAssertFalse(vm.connectionListVM.connectionStatuses.isEmpty)

        await vm.disconnect()

        XCTAssertTrue(vm.connectionListVM.connectionStatuses.isEmpty)
    }

    // MARK: - switchDatabase(_:)

    func testSwitchDatabaseReconnectsWithNewDatabase() async {
        let profile = makeProfile(database: "testdb")
        await makeConnectedVM(profile: profile)

        await vm.switchDatabase("newdb")

        let lastSwitch = await mockDB.lastSwitchDatabase
        XCTAssertEqual(lastSwitch, "newdb")
    }

    func testSwitchDatabaseReloadsSchemas() async {
        let profile = makeProfile(database: "testdb")
        await makeConnectedVM(profile: profile)

        // Clear schemas to verify reload
        vm.navigatorVM.schemas = []
        vm.navigatorVM.selectedSchema = ""

        await vm.switchDatabase("newdb")

        XCTAssertEqual(vm.navigatorVM.schemas, ["public", "auth"])
    }

    func testSwitchDatabaseUpdatesSelectedDatabase() async {
        let profile = makeProfile(database: "testdb")
        await makeConnectedVM(profile: profile)

        await vm.switchDatabase("newdb")

        XCTAssertEqual(vm.navigatorVM.selectedDatabase, "newdb")
    }

    func testSwitchDatabaseClearsOldTablesAndViews() async {
        let profile = makeProfile(database: "testdb")
        await makeConnectedVM(profile: profile)

        // Pre-populate tables
        vm.navigatorVM.tables = [DBObject(schema: "public", name: "old_table", type: .table)]
        vm.navigatorVM.views = [DBObject(schema: "public", name: "old_view", type: .view)]
        vm.navigatorVM.selectedObject = DBObject(schema: "public", name: "old_table", type: .table)

        await vm.switchDatabase("newdb")

        // After switching, setSchemas is called which sets selectedSchema to "public".
        // But tables/views should have been cleared, then potentially reloaded.
        XCTAssertNil(vm.navigatorVM.selectedObject)
    }

    func testSwitchDatabaseClearsTableVM() async {
        let profile = makeProfile(database: "testdb")
        await makeConnectedVM(profile: profile)

        vm.tableVM.setColumns([
            ColumnInfo(name: "id", ordinalPosition: 1, dataType: "integer", isNullable: false, columnDefault: nil, characterMaximumLength: nil)
        ])

        await vm.switchDatabase("newdb")

        // tableVM.clear() is called during switch
        XCTAssertNil(vm.tableVM.contentResult)
        XCTAssertEqual(vm.tableVM.approximateRowCount, 0)
    }

    func testSwitchDatabaseClearsErrorMessageOnSuccess() async {
        let profile = makeProfile(database: "testdb")
        await makeConnectedVM(profile: profile)
        vm.errorMessage = "stale error"

        await vm.switchDatabase("newdb")

        XCTAssertNil(vm.errorMessage)
    }

    func testSwitchDatabaseSetsErrorOnFailure() async {
        let profile = makeProfile(database: "testdb")
        await makeConnectedVM(profile: profile)
        await mockDB.setShouldThrowOnSwitchDatabase(true)

        await vm.switchDatabase("newdb")

        XCTAssertNotNil(vm.errorMessage)
        XCTAssertTrue(vm.errorMessage?.contains("mock switch error") ?? false)
    }

    func testSwitchDatabaseDoesNothingWhenNotConnected() async {
        // Not connected, connectedProfile is nil
        await vm.switchDatabase("newdb")

        let lastSwitch = await mockDB.lastSwitchDatabase
        XCTAssertNil(lastSwitch)
    }

    func testSwitchDatabaseDoesNothingWhenSameDatabase() async {
        let profile = makeProfile(database: "testdb")
        await makeConnectedVM(profile: profile)

        // Reset the mock to detect if switchDatabase is called
        let switchCountBefore = await mockDB.lastSwitchDatabase
        // switchDatabase should be nil from the initial connect flow (connect doesn't call switchDatabase)
        _ = switchCountBefore

        await vm.switchDatabase("testdb")

        // Should not have called switchDatabase since name == profile.database
        let lastSwitch = await mockDB.lastSwitchDatabase
        XCTAssertNil(lastSwitch)
    }

    func testSwitchDatabaseLoadsTablesWhenSchemaSelected() async {
        let profile = makeProfile(database: "testdb")
        await makeConnectedVM(profile: profile)

        // After connect, selectedSchema should be "public" due to setSchemas
        XCTAssertEqual(vm.navigatorVM.selectedSchema, "public")

        await vm.switchDatabase("newdb")

        // setSchemas is called during switch, which sets selectedSchema to "public".
        // Then loadTablesAndViews is called because selectedSchema is not empty.
        let lastTablesSchema = await mockDB.lastListTablesSchema
        XCTAssertEqual(lastTablesSchema, "public")
    }

    // MARK: - selectObject(_:)

    func testSelectObjectSetsSelectedObjectOnNavigatorVM() async {
        await makeConnectedVM()
        let object = DBObject(schema: "public", name: "users", type: .table)

        await vm.selectObject(object)

        XCTAssertEqual(vm.navigatorVM.selectedObject, object)
    }

    func testSelectObjectClearsTableVM() async {
        await makeConnectedVM()
        vm.tableVM.setColumns([
            ColumnInfo(name: "old_col", ordinalPosition: 1, dataType: "text", isNullable: true, columnDefault: nil, characterMaximumLength: nil)
        ])

        let object = DBObject(schema: "public", name: "users", type: .table)
        await vm.selectObject(object)

        // Old columns should be replaced by new ones from mock
        XCTAssertEqual(vm.tableVM.columns.count, 2)
        XCTAssertEqual(vm.tableVM.columns[0].name, "id")
    }

    func testSelectObjectSwitchesFromQueryTabToStructure() async {
        await makeConnectedVM()
        vm.selectedTab = .query

        let object = DBObject(schema: "public", name: "users", type: .table)
        await vm.selectObject(object)

        XCTAssertEqual(vm.selectedTab, .structure)
    }

    func testSelectObjectKeepsContentTabWhenActive() async {
        await makeConnectedVM()
        vm.selectedTab = .content

        let object = DBObject(schema: "public", name: "users", type: .table)
        await vm.selectObject(object)

        XCTAssertEqual(vm.selectedTab, .content)
    }

    func testSelectObjectKeepsStructureTabWhenActive() async {
        await makeConnectedVM()
        vm.selectedTab = .structure

        let object = DBObject(schema: "public", name: "users", type: .table)
        await vm.selectObject(object)

        XCTAssertEqual(vm.selectedTab, .structure)
    }

    func testSelectObjectLoadsColumns() async {
        await makeConnectedVM()
        let object = DBObject(schema: "public", name: "users", type: .table)

        await vm.selectObject(object)

        XCTAssertEqual(vm.tableVM.columns.count, 2)
        XCTAssertEqual(vm.tableVM.columns[0].name, "id")
        XCTAssertEqual(vm.tableVM.columns[1].name, "name")
    }

    func testSelectObjectLoadsApproximateRowCount() async {
        await makeConnectedVM()
        let object = DBObject(schema: "public", name: "users", type: .table)

        await vm.selectObject(object)

        XCTAssertEqual(vm.tableVM.approximateRowCount, 42)
    }

    func testSelectObjectSetsSelectedObjectNameOnTableVM() async {
        await makeConnectedVM()
        let object = DBObject(schema: "public", name: "users", type: .table)

        await vm.selectObject(object)

        XCTAssertEqual(vm.tableVM.selectedObjectName, "users")
    }

    func testSelectObjectSetsSelectedObjectColumnCount() async {
        await makeConnectedVM()
        let object = DBObject(schema: "public", name: "users", type: .table)

        await vm.selectObject(object)

        XCTAssertEqual(vm.tableVM.selectedObjectColumnCount, 2)
    }

    func testSelectObjectPassesCorrectSchemaAndTableToDbClient() async {
        await makeConnectedVM()
        let object = DBObject(schema: "auth", name: "sessions", type: .table)

        await vm.selectObject(object)

        let lastSchema = await mockDB.lastGetColumnsSchema
        let lastTable = await mockDB.lastGetColumnsTable
        XCTAssertEqual(lastSchema, "auth")
        XCTAssertEqual(lastTable, "sessions")
    }

    func testSelectObjectLoadsContentWhenContentTabActive() async {
        await makeConnectedVM()
        vm.selectedTab = .content
        let object = DBObject(schema: "public", name: "users", type: .table)

        await vm.selectObject(object)

        // Content should have been loaded because tab is .content
        XCTAssertNotNil(vm.tableVM.contentResult)
        XCTAssertEqual(vm.tableVM.contentResult?.rowCount, 2)
    }

    func testSelectObjectDoesNotLoadContentWhenStructureTabActive() async {
        await makeConnectedVM()
        vm.selectedTab = .structure
        let object = DBObject(schema: "public", name: "users", type: .table)

        await vm.selectObject(object)

        // loadContentPage is only called when selectedTab == .content
        // The content result may still be nil since we're on structure tab
        // (selectObject calls tableVM.clear() first, then only loads content if on content tab)
        // Since the mock returns content for any query, we verify by checking the SQL
        // wasn't a SELECT * query if structure tab was active.
        // Actually, since we cleared and selectedTab is structure, contentResult should be nil.
        XCTAssertNil(vm.tableVM.contentResult)
    }

    func testSelectObjectSetsErrorWhenGetColumnsFails() async {
        await makeConnectedVM()
        await mockDB.setShouldThrowOnGetColumns(true)
        let object = DBObject(schema: "public", name: "users", type: .table)

        await vm.selectObject(object)

        XCTAssertNotNil(vm.errorMessage)
        XCTAssertTrue(vm.errorMessage?.contains("mock columns error") ?? false)
    }

    func testSelectObjectWithView() async {
        await makeConnectedVM()
        let object = DBObject(schema: "public", name: "active_users", type: .view)

        await vm.selectObject(object)

        XCTAssertEqual(vm.navigatorVM.selectedObject, object)
        XCTAssertEqual(vm.tableVM.selectedObjectName, "active_users")
    }

    // MARK: - loadTablesAndViews(forSchema:)

    func testLoadTablesAndViewsPopulatesNavigatorVM() async {
        await makeConnectedVM()

        await vm.loadTablesAndViews(forSchema: "public")

        XCTAssertEqual(vm.navigatorVM.tables.count, 2)
        XCTAssertEqual(vm.navigatorVM.tables[0].name, "users")
        XCTAssertEqual(vm.navigatorVM.tables[1].name, "posts")
        XCTAssertEqual(vm.navigatorVM.views.count, 1)
        XCTAssertEqual(vm.navigatorVM.views[0].name, "active_users")
    }

    func testLoadTablesAndViewsPassesSchemaToDbClient() async {
        await makeConnectedVM()

        await vm.loadTablesAndViews(forSchema: "auth")

        let lastTablesSchema = await mockDB.lastListTablesSchema
        let lastViewsSchema = await mockDB.lastListViewsSchema
        XCTAssertEqual(lastTablesSchema, "auth")
        XCTAssertEqual(lastViewsSchema, "auth")
    }

    func testLoadTablesAndViewsSetsErrorOnFailure() async {
        await makeConnectedVM()
        await mockDB.setShouldThrowOnListTables(true)

        await vm.loadTablesAndViews(forSchema: "public")

        XCTAssertNotNil(vm.errorMessage)
        XCTAssertTrue(vm.errorMessage?.contains("mock tables error") ?? false)
    }

    func testLoadTablesAndViewsSetsErrorWhenViewsFail() async {
        await makeConnectedVM()
        await mockDB.setShouldThrowOnListViews(true)

        await vm.loadTablesAndViews(forSchema: "public")

        XCTAssertNotNil(vm.errorMessage)
        XCTAssertTrue(vm.errorMessage?.contains("mock views error") ?? false)
    }

    // MARK: - loadContentPage()

    func testLoadContentPageSetsContentResult() async {
        await makeConnectedVM()
        let object = DBObject(schema: "public", name: "users", type: .table)
        vm.navigatorVM.selectedObject = object

        await vm.loadContentPage()

        XCTAssertNotNil(vm.tableVM.contentResult)
        XCTAssertEqual(vm.tableVM.contentResult?.columns, ["id", "name"])
        XCTAssertEqual(vm.tableVM.contentResult?.rowCount, 2)
    }

    func testLoadContentPageReturnsEarlyWhenNoSelectedObject() async {
        await makeConnectedVM()
        vm.navigatorVM.selectedObject = nil

        await vm.loadContentPage()

        XCTAssertNil(vm.tableVM.contentResult)
        let lastSQL = await mockDB.lastRunQuerySQL
        // No query should be run after connect's schema query
        // (connect calls listDatabases/listSchemas but not runQuery)
        XCTAssertNil(lastSQL)
    }

    func testLoadContentPageUsesPagination() async {
        await makeConnectedVM()
        let object = DBObject(schema: "public", name: "users", type: .table)
        vm.navigatorVM.selectedObject = object
        vm.tableVM.currentPage = 2
        vm.tableVM.pageSize = 100

        await vm.loadContentPage()

        let lastSQL = await mockDB.lastRunQuerySQL
        XCTAssertNotNil(lastSQL)
        XCTAssertTrue(lastSQL?.contains("LIMIT 100") ?? false)
        XCTAssertTrue(lastSQL?.contains("OFFSET 200") ?? false)
    }

    func testLoadContentPageSetsIsLoadingContentFalseOnSuccess() async {
        await makeConnectedVM()
        let object = DBObject(schema: "public", name: "users", type: .table)
        vm.navigatorVM.selectedObject = object

        await vm.loadContentPage()

        XCTAssertFalse(vm.tableVM.isLoadingContent)
    }

    func testLoadContentPageSetsIsLoadingContentFalseOnError() async {
        await makeConnectedVM()
        let object = DBObject(schema: "public", name: "users", type: .table)
        vm.navigatorVM.selectedObject = object
        await mockDB.setShouldThrowOnRunQuery(true)

        await vm.loadContentPage()

        XCTAssertFalse(vm.tableVM.isLoadingContent)
    }

    func testLoadContentPageSetsErrorOnFailure() async {
        await makeConnectedVM()
        let object = DBObject(schema: "public", name: "users", type: .table)
        vm.navigatorVM.selectedObject = object
        await mockDB.setShouldThrowOnRunQuery(true)

        await vm.loadContentPage()

        XCTAssertNotNil(vm.errorMessage)
        XCTAssertTrue(vm.errorMessage?.contains("mock query error") ?? false)
    }

    func testLoadContentPageFallsBackToStructureColumnsWhenResultColumnsEmpty() async {
        await makeConnectedVM()
        let object = DBObject(schema: "public", name: "users", type: .table)
        vm.navigatorVM.selectedObject = object

        // Pre-populate structure columns
        vm.tableVM.setColumns([
            ColumnInfo(name: "id", ordinalPosition: 1, dataType: "integer", isNullable: false, columnDefault: nil, characterMaximumLength: nil),
            ColumnInfo(name: "email", ordinalPosition: 2, dataType: "text", isNullable: true, columnDefault: nil, characterMaximumLength: nil),
        ])

        // Stub empty query result (simulating a table with zero rows)
        await mockDB.setStubbedQueryResult(QueryResult(
            columns: [],
            rows: [],
            executionTime: 0.01,
            rowsAffected: nil,
            isTruncated: false
        ))

        await vm.loadContentPage()

        // Should fall back to column names from tableVM.columns
        XCTAssertEqual(vm.tableVM.contentResult?.columns, ["id", "email"])
        XCTAssertEqual(vm.tableVM.contentResult?.rowCount, 0)
        XCTAssertFalse(vm.tableVM.contentResult?.isTruncated ?? true)
    }

    func testLoadContentPageDoesNotFallBackWhenNoStructureColumns() async {
        await makeConnectedVM()
        let object = DBObject(schema: "public", name: "users", type: .table)
        vm.navigatorVM.selectedObject = object
        vm.tableVM.columns = [] // No structure columns loaded

        // Stub empty query result
        await mockDB.setStubbedQueryResult(QueryResult(
            columns: [],
            rows: [],
            executionTime: 0.01,
            rowsAffected: nil,
            isTruncated: false
        ))

        await vm.loadContentPage()

        // No fallback, columns remain empty
        XCTAssertEqual(vm.tableVM.contentResult?.columns, [])
    }

    func testLoadContentPageQuotesSchemaAndTableNames() async {
        await makeConnectedVM()
        let object = DBObject(schema: "my schema", name: "my table", type: .table)
        vm.navigatorVM.selectedObject = object

        await vm.loadContentPage()

        let lastSQL = await mockDB.lastRunQuerySQL
        XCTAssertNotNil(lastSQL)
        // quoteIdent wraps in double quotes
        XCTAssertTrue(lastSQL?.contains("\"my schema\"") ?? false)
        XCTAssertTrue(lastSQL?.contains("\"my table\"") ?? false)
    }

    func testLoadContentPageFirstPageOffset() async {
        await makeConnectedVM()
        let object = DBObject(schema: "public", name: "users", type: .table)
        vm.navigatorVM.selectedObject = object
        vm.tableVM.currentPage = 0
        vm.tableVM.pageSize = 50

        await vm.loadContentPage()

        let lastSQL = await mockDB.lastRunQuerySQL
        XCTAssertTrue(lastSQL?.contains("OFFSET 0") ?? false)
        XCTAssertTrue(lastSQL?.contains("LIMIT 50") ?? false)
    }

    // MARK: - executeQuery(_:)

    func testExecuteQuerySetsResultOnSuccess() async {
        await makeConnectedVM()

        await vm.executeQuery("SELECT 1")

        XCTAssertNotNil(vm.queryVM.result)
        XCTAssertEqual(vm.queryVM.result?.columns, ["id", "name"])
    }

    func testExecuteQuerySetsIsExecutingFalseOnSuccess() async {
        await makeConnectedVM()

        await vm.executeQuery("SELECT 1")

        XCTAssertFalse(vm.queryVM.isExecuting)
    }

    func testExecuteQueryClearsErrorOnSuccess() async {
        await makeConnectedVM()
        vm.queryVM.errorMessage = "old error"

        await vm.executeQuery("SELECT 1")

        XCTAssertNil(vm.queryVM.errorMessage)
    }

    func testExecuteQueryClearsPreviousResult() async {
        await makeConnectedVM()
        vm.queryVM.result = QueryResult(
            columns: ["old"],
            rows: [],
            executionTime: 0,
            rowsAffected: nil,
            isTruncated: false
        )

        await vm.executeQuery("SELECT 1")

        // After execution, result should be the new one
        XCTAssertEqual(vm.queryVM.result?.columns, ["id", "name"])
    }

    func testExecuteQuerySetsErrorOnFailure() async {
        await makeConnectedVM()
        await mockDB.setShouldThrowOnRunQuery(true)

        await vm.executeQuery("SELECT bad_query")

        XCTAssertNotNil(vm.queryVM.errorMessage)
        XCTAssertTrue(vm.queryVM.errorMessage?.contains("mock query error") ?? false)
        XCTAssertNil(vm.queryVM.result)
    }

    func testExecuteQuerySetsIsExecutingFalseOnError() async {
        await makeConnectedVM()
        await mockDB.setShouldThrowOnRunQuery(true)

        await vm.executeQuery("SELECT bad_query")

        XCTAssertFalse(vm.queryVM.isExecuting)
    }

    func testExecuteQueryIgnoresEmptyString() async {
        await makeConnectedVM()

        await vm.executeQuery("")

        XCTAssertNil(vm.queryVM.result)
        XCTAssertFalse(vm.queryVM.isExecuting)
    }

    func testExecuteQueryIgnoresWhitespaceOnlyString() async {
        await makeConnectedVM()

        await vm.executeQuery("   \n\t  ")

        XCTAssertNil(vm.queryVM.result)
        XCTAssertFalse(vm.queryVM.isExecuting)
    }

    func testExecuteQueryPassesSQLToDbClient() async {
        await makeConnectedVM()

        await vm.executeQuery("SELECT * FROM users WHERE id = 42")

        let lastSQL = await mockDB.lastRunQuerySQL
        XCTAssertEqual(lastSQL, "SELECT * FROM users WHERE id = 42")
    }

    func testExecuteQueryUsesCorrectMaxRowsAndTimeout() async {
        await makeConnectedVM()

        await vm.executeQuery("SELECT 1")

        let lastMaxRows = await mockDB.lastRunQueryMaxRows
        XCTAssertEqual(lastMaxRows, 2000)
    }

    // MARK: - selectRow(index:columns:values:)

    func testSelectRowSetsSelectedRowIndex() {
        vm.selectRow(index: 2, columns: ["id"], values: [.text("42")])

        XCTAssertEqual(vm.tableVM.selectedRowIndex, 2)
    }

    func testSelectRowBuildsSelectedRowData() {
        vm.selectRow(
            index: 0,
            columns: ["id", "name", "email"],
            values: [.text("1"), .text("Alice"), .text("alice@example.com")]
        )

        XCTAssertEqual(vm.tableVM.selectedRowData?.count, 3)
        XCTAssertEqual(vm.tableVM.selectedRowData?[0].column, "id")
        XCTAssertEqual(vm.tableVM.selectedRowData?[0].value, .text("1"))
        XCTAssertEqual(vm.tableVM.selectedRowData?[1].column, "name")
        XCTAssertEqual(vm.tableVM.selectedRowData?[1].value, .text("Alice"))
        XCTAssertEqual(vm.tableVM.selectedRowData?[2].column, "email")
        XCTAssertEqual(vm.tableVM.selectedRowData?[2].value, .text("alice@example.com"))
    }

    func testSelectRowWithSingleColumnAndValue() {
        vm.selectRow(index: 0, columns: ["count"], values: [.text("99")])

        XCTAssertEqual(vm.tableVM.selectedRowIndex, 0)
        XCTAssertEqual(vm.tableVM.selectedRowData?.count, 1)
        XCTAssertEqual(vm.tableVM.selectedRowData?[0].column, "count")
        XCTAssertEqual(vm.tableVM.selectedRowData?[0].value, .text("99"))
    }

    func testSelectRowWithNullValues() {
        vm.selectRow(
            index: 1,
            columns: ["id", "deleted_at"],
            values: [.text("5"), .null]
        )

        XCTAssertEqual(vm.tableVM.selectedRowData?.count, 2)
        XCTAssertEqual(vm.tableVM.selectedRowData?[0].value, .text("5"))
        XCTAssertEqual(vm.tableVM.selectedRowData?[1].column, "deleted_at")
        XCTAssertEqual(vm.tableVM.selectedRowData?[1].value, .null)
    }

    func testSelectRowWithAllNullValues() {
        vm.selectRow(
            index: 0,
            columns: ["a", "b"],
            values: [.null, .null]
        )

        XCTAssertEqual(vm.tableVM.selectedRowData?.count, 2)
        XCTAssertEqual(vm.tableVM.selectedRowData?[0].value, .null)
        XCTAssertEqual(vm.tableVM.selectedRowData?[1].value, .null)
    }

    func testSelectRowWithEmptyArrays() {
        vm.selectRow(index: 0, columns: [], values: [])

        XCTAssertEqual(vm.tableVM.selectedRowIndex, 0)
        XCTAssertEqual(vm.tableVM.selectedRowData?.count, 0)
    }

    func testSelectRowWithMoreColumnsThanValues() {
        // zip truncates to the shorter array
        vm.selectRow(
            index: 0,
            columns: ["id", "name", "email"],
            values: [.text("1")]
        )

        XCTAssertEqual(vm.tableVM.selectedRowData?.count, 1)
        XCTAssertEqual(vm.tableVM.selectedRowData?[0].column, "id")
        XCTAssertEqual(vm.tableVM.selectedRowData?[0].value, .text("1"))
    }

    func testSelectRowWithMoreValuesThanColumns() {
        // zip truncates to the shorter array
        vm.selectRow(
            index: 0,
            columns: ["id"],
            values: [.text("1"), .text("extra"), .text("ignored")]
        )

        XCTAssertEqual(vm.tableVM.selectedRowData?.count, 1)
        XCTAssertEqual(vm.tableVM.selectedRowData?[0].column, "id")
        XCTAssertEqual(vm.tableVM.selectedRowData?[0].value, .text("1"))
    }

    func testSelectRowReplacesExistingSelection() {
        vm.selectRow(index: 0, columns: ["old"], values: [.text("old_val")])
        XCTAssertEqual(vm.tableVM.selectedRowIndex, 0)
        XCTAssertEqual(vm.tableVM.selectedRowData?[0].column, "old")

        vm.selectRow(index: 5, columns: ["new"], values: [.text("new_val")])
        XCTAssertEqual(vm.tableVM.selectedRowIndex, 5)
        XCTAssertEqual(vm.tableVM.selectedRowData?.count, 1)
        XCTAssertEqual(vm.tableVM.selectedRowData?[0].column, "new")
        XCTAssertEqual(vm.tableVM.selectedRowData?[0].value, .text("new_val"))
    }

    func testSelectRowWithLargeIndex() {
        vm.selectRow(index: 999_999, columns: ["x"], values: [.text("v")])

        XCTAssertEqual(vm.tableVM.selectedRowIndex, 999_999)
    }

    func testSelectRowPreservesColumnOrder() {
        let columns = ["z_col", "a_col", "m_col"]
        let values: [CellValue] = [.text("z"), .text("a"), .text("m")]
        vm.selectRow(index: 0, columns: columns, values: values)

        // Order must match input, not sorted
        XCTAssertEqual(vm.tableVM.selectedRowData?[0].column, "z_col")
        XCTAssertEqual(vm.tableVM.selectedRowData?[1].column, "a_col")
        XCTAssertEqual(vm.tableVM.selectedRowData?[2].column, "m_col")
    }

    // MARK: - clearSelectedRow()

    func testClearSelectedRowNilsSelectedRowIndex() {
        vm.selectRow(index: 3, columns: ["id"], values: [.text("1")])
        XCTAssertNotNil(vm.tableVM.selectedRowIndex)

        vm.clearSelectedRow()

        XCTAssertNil(vm.tableVM.selectedRowIndex)
    }

    func testClearSelectedRowNilsSelectedRowData() {
        vm.selectRow(index: 0, columns: ["id", "name"], values: [.text("1"), .text("Bob")])
        XCTAssertNotNil(vm.tableVM.selectedRowData)

        vm.clearSelectedRow()

        XCTAssertNil(vm.tableVM.selectedRowData)
    }

    func testClearSelectedRowWhenAlreadyNil() {
        // Both properties start as nil
        XCTAssertNil(vm.tableVM.selectedRowIndex)
        XCTAssertNil(vm.tableVM.selectedRowData)

        vm.clearSelectedRow()

        XCTAssertNil(vm.tableVM.selectedRowIndex)
        XCTAssertNil(vm.tableVM.selectedRowData)
    }

    func testClearSelectedRowIsIdempotent() {
        vm.selectRow(index: 1, columns: ["a"], values: [.text("v")])

        vm.clearSelectedRow()
        vm.clearSelectedRow()

        XCTAssertNil(vm.tableVM.selectedRowIndex)
        XCTAssertNil(vm.tableVM.selectedRowData)
    }

    func testSelectRowAfterClearSelectedRow() {
        vm.selectRow(index: 2, columns: ["x"], values: [.text("first")])
        vm.clearSelectedRow()

        vm.selectRow(index: 7, columns: ["y"], values: [.text("second")])

        XCTAssertEqual(vm.tableVM.selectedRowIndex, 7)
        XCTAssertEqual(vm.tableVM.selectedRowData?.count, 1)
        XCTAssertEqual(vm.tableVM.selectedRowData?[0].column, "y")
        XCTAssertEqual(vm.tableVM.selectedRowData?[0].value, .text("second"))
    }

    // MARK: - Row selection cleared by disconnect / tableVM.clear()

    func testDisconnectClearsRowSelection() async {
        await makeConnectedVM()
        vm.selectRow(index: 1, columns: ["id"], values: [.text("10")])
        XCTAssertNotNil(vm.tableVM.selectedRowIndex)

        await vm.disconnect()

        XCTAssertNil(vm.tableVM.selectedRowIndex)
        XCTAssertNil(vm.tableVM.selectedRowData)
    }

    func testSelectObjectClearsRowSelection() async {
        await makeConnectedVM()
        vm.selectRow(index: 4, columns: ["name"], values: [.text("Alice")])

        let object = DBObject(schema: "public", name: "users", type: .table)
        await vm.selectObject(object)

        // selectObject calls tableVM.clear(), which resets row selection
        XCTAssertNil(vm.tableVM.selectedRowIndex)
        XCTAssertNil(vm.tableVM.selectedRowData)
    }

    // MARK: - MainTab enum

    func testMainTabRawValues() {
        XCTAssertEqual(AppViewModel.MainTab.structure.rawValue, "Structure")
        XCTAssertEqual(AppViewModel.MainTab.content.rawValue, "Content")
        XCTAssertEqual(AppViewModel.MainTab.query.rawValue, "Query")
    }

    func testMainTabAllCases() {
        XCTAssertEqual(AppViewModel.MainTab.allCases.count, 3)
    }

    // MARK: - Integration-style scenarios

    func testFullConnectThenSelectObjectFlow() async {
        let profile = makeProfile(name: "Integration Test", database: "mydb")
        mockKeychain.seed(password: "pass123", forProfile: profile)

        await vm.connect(profile: profile)

        XCTAssertTrue(vm.isConnected)
        XCTAssertEqual(vm.connectedProfileName, "Integration Test")
        XCTAssertEqual(vm.navigatorVM.databases, ["postgres", "testdb", "devdb"])
        XCTAssertEqual(vm.navigatorVM.selectedDatabase, "mydb")
        XCTAssertEqual(vm.navigatorVM.schemas, ["public", "auth"])
        XCTAssertEqual(vm.navigatorVM.selectedSchema, "public")

        // Select an object
        let table = DBObject(schema: "public", name: "users", type: .table)
        await vm.selectObject(table)

        XCTAssertEqual(vm.navigatorVM.selectedObject, table)
        XCTAssertEqual(vm.tableVM.columns.count, 2)
        XCTAssertEqual(vm.tableVM.approximateRowCount, 42)
        XCTAssertEqual(vm.selectedTab, .structure)
    }

    func testFullConnectThenSwitchDatabaseThenDisconnect() async {
        let profile = makeProfile(database: "db1")
        await vm.connect(profile: profile)

        XCTAssertTrue(vm.isConnected)
        XCTAssertEqual(vm.navigatorVM.selectedDatabase, "db1")

        // Switch database
        await vm.switchDatabase("db2")

        XCTAssertEqual(vm.navigatorVM.selectedDatabase, "db2")
        XCTAssertNil(vm.errorMessage)

        // Disconnect
        await vm.disconnect()

        XCTAssertFalse(vm.isConnected)
        XCTAssertNil(vm.connectedProfileName)
        XCTAssertTrue(vm.navigatorVM.databases.isEmpty)
    }

    func testSelectObjectThenLoadContentPage() async {
        await makeConnectedVM()
        vm.selectedTab = .structure

        let object = DBObject(schema: "public", name: "posts", type: .table)
        await vm.selectObject(object)

        // On structure tab, content is not auto-loaded
        XCTAssertNil(vm.tableVM.contentResult)

        // Now switch to content tab and manually load
        vm.selectedTab = .content
        await vm.loadContentPage()

        XCTAssertNotNil(vm.tableVM.contentResult)
        XCTAssertEqual(vm.tableVM.contentResult?.rowCount, 2)
    }

    func testExecuteQueryThenDisconnect() async {
        await makeConnectedVM()

        await vm.executeQuery("SELECT NOW()")

        XCTAssertNotNil(vm.queryVM.result)

        await vm.disconnect()

        // queryVM result is NOT cleared by disconnect (only navigator and table are cleared)
        // This is by design since disconnect clears navigator and table state
        XCTAssertFalse(vm.isConnected)
    }

    func testReconnectAfterDisconnect() async {
        let profile = makeProfile()
        await vm.connect(profile: profile)
        XCTAssertTrue(vm.isConnected)

        await vm.disconnect()
        XCTAssertFalse(vm.isConnected)

        // Reconnect
        await vm.connect(profile: profile)
        XCTAssertTrue(vm.isConnected)

        let connectCount = await mockDB.connectCallCount
        XCTAssertEqual(connectCount, 2)
    }
}

// MARK: - MockDatabaseClient setter helpers

// Actor-isolated setters for configuring mock behavior from @MainActor test methods.
extension MockDatabaseClient {
    func setShouldThrowOnConnect(_ value: Bool) {
        shouldThrowOnConnect = value
    }

    func setShouldThrowOnRunQuery(_ value: Bool) {
        shouldThrowOnRunQuery = value
    }

    func setShouldThrowOnListSchemas(_ value: Bool) {
        shouldThrowOnListSchemas = value
    }

    func setShouldThrowOnListTables(_ value: Bool) {
        shouldThrowOnListTables = value
    }

    func setShouldThrowOnListViews(_ value: Bool) {
        shouldThrowOnListViews = value
    }

    func setShouldThrowOnGetColumns(_ value: Bool) {
        shouldThrowOnGetColumns = value
    }

    func setShouldThrowOnGetApproximateRowCount(_ value: Bool) {
        shouldThrowOnGetApproximateRowCount = value
    }

    func setShouldThrowOnSwitchDatabase(_ value: Bool) {
        shouldThrowOnSwitchDatabase = value
    }

    func setShouldThrowOnGetPrimaryKeys(_ value: Bool) {
        shouldThrowOnGetPrimaryKeys = value
    }

    func setStubbedQueryResult(_ result: QueryResult) {
        stubbedQueryResult = result
    }
}

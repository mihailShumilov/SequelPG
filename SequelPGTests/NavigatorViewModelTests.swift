import XCTest
@testable import SequelPG

@MainActor
final class NavigatorViewModelTests: XCTestCase {

    private var sut: NavigatorViewModel!
    /// Default database name used throughout these tests.
    private let db = "testdb"

    override func setUp() {
        super.setUp()
        sut = NavigatorViewModel()
    }

    override func tearDown() {
        sut = nil
        super.tearDown()
    }

    // MARK: - Initial State

    func testInitialDatabasesIsEmpty() {
        XCTAssertEqual(sut.databases, [])
    }

    func testInitialConnectedDatabaseIsEmpty() {
        XCTAssertEqual(sut.connectedDatabase, "")
    }

    func testInitialSchemasIsEmpty() {
        XCTAssertEqual(sut.schemas(for: db), [])
    }

    func testInitialObjectsPerKeyIsEmpty() {
        XCTAssertTrue(sut.objectsPerKey.isEmpty)
    }

    func testInitialLoadedKeysIsEmpty() {
        XCTAssertTrue(sut.loadedKeys.isEmpty)
    }

    func testInitialExpandedDatabasesIsEmpty() {
        XCTAssertTrue(sut.expandedDatabases.isEmpty)
    }

    func testInitialExpandedSchemasIsEmpty() {
        XCTAssertTrue(sut.expandedSchemas.isEmpty)
    }

    func testInitialExpandedCategoriesIsEmpty() {
        XCTAssertTrue(sut.expandedCategories.isEmpty)
    }

    func testInitialSelectedObjectIsNil() {
        XCTAssertNil(sut.selectedObject)
    }

    // MARK: - setDatabases(_:current:)

    func testSetDatabasesUpdatesDatabasesList() {
        sut.setDatabases(["db1", "db2", "db3"], current: "db1")

        XCTAssertEqual(sut.databases, ["db1", "db2", "db3"])
    }

    func testSetDatabasesSetsConnectedDatabase() {
        sut.setDatabases(["db1", "db2"], current: "db2")

        XCTAssertEqual(sut.connectedDatabase, "db2")
    }

    func testSetDatabasesExpandsCurrentDatabase() {
        sut.setDatabases(["db1", "db2"], current: "db2")

        XCTAssertTrue(sut.expandedDatabases.contains("db2"))
    }

    func testSetDatabasesWithCurrentNotInList() {
        sut.setDatabases(["db1", "db2"], current: "db_other")

        XCTAssertEqual(sut.databases, ["db1", "db2"])
        XCTAssertEqual(sut.connectedDatabase, "db_other")
        XCTAssertTrue(sut.expandedDatabases.contains("db_other"))
    }

    func testSetDatabasesWithEmptyList() {
        sut.setDatabases([], current: "")

        XCTAssertEqual(sut.databases, [])
        XCTAssertEqual(sut.connectedDatabase, "")
    }

    func testSetDatabasesWithSingleDatabase() {
        sut.setDatabases(["only_db"], current: "only_db")

        XCTAssertEqual(sut.databases, ["only_db"])
        XCTAssertEqual(sut.connectedDatabase, "only_db")
    }

    func testSetDatabasesOverwritesPreviousState() {
        sut.setDatabases(["old_db"], current: "old_db")
        sut.setDatabases(["new_db1", "new_db2"], current: "new_db2")

        XCTAssertEqual(sut.databases, ["new_db1", "new_db2"])
        XCTAssertEqual(sut.connectedDatabase, "new_db2")
    }

    func testSetDatabasesWithEmptyCurrentString() {
        sut.setDatabases(["db1", "db2"], current: "")

        XCTAssertEqual(sut.databases, ["db1", "db2"])
        XCTAssertEqual(sut.connectedDatabase, "")
    }

    // MARK: - setSchemas(_:forDatabase:)

    func testSetSchemasUpdatesSchemasList() {
        sut.setSchemas(["public", "private", "analytics"], forDatabase: db)

        XCTAssertEqual(sut.schemas(for: db), ["public", "private", "analytics"])
    }

    func testSetSchemasAutoExpandsPublicWhenAvailable() {
        sut.setSchemas(["private", "public", "analytics"], forDatabase: db)

        XCTAssertTrue(sut.expandedSchemas.contains(sut.schemaKey(db, "public")))
    }

    func testSetSchemasAutoExpandsPublicTablesCategory() {
        sut.setSchemas(["private", "public", "analytics"], forDatabase: db)

        let tablesKey = sut.categoryKey(db, "public", .tables)
        XCTAssertTrue(sut.expandedCategories.contains(tablesKey))
    }

    func testSetSchemasExpandsFirstWhenPublicNotAvailable() {
        sut.setSchemas(["custom_schema", "analytics"], forDatabase: db)

        XCTAssertTrue(sut.expandedSchemas.contains(sut.schemaKey(db, "custom_schema")))
    }

    func testSetSchemasExpandsFirstTablesCategory() {
        sut.setSchemas(["custom_schema", "analytics"], forDatabase: db)

        let tablesKey = sut.categoryKey(db, "custom_schema", .tables)
        XCTAssertTrue(sut.expandedCategories.contains(tablesKey))
    }

    func testSetSchemasWithOnlyPublic() {
        sut.setSchemas(["public"], forDatabase: db)

        XCTAssertEqual(sut.schemas(for: db), ["public"])
        XCTAssertTrue(sut.expandedSchemas.contains(sut.schemaKey(db, "public")))
    }

    func testSetSchemasWithEmptyList() {
        sut.setSchemas([], forDatabase: db)

        XCTAssertEqual(sut.schemas(for: db), [])
        // Nothing should be expanded
        XCTAssertTrue(sut.expandedSchemas.isEmpty)
    }

    func testSetSchemasWithSingleNonPublicSchema() {
        sut.setSchemas(["custom"], forDatabase: db)

        XCTAssertEqual(sut.schemas(for: db), ["custom"])
        XCTAssertTrue(sut.expandedSchemas.contains(sut.schemaKey(db, "custom")))
    }

    func testSetSchemasPublicIsFirstInList() {
        sut.setSchemas(["public", "other"], forDatabase: db)

        XCTAssertTrue(sut.expandedSchemas.contains(sut.schemaKey(db, "public")))
    }

    func testSetSchemasPublicIsLastInList() {
        sut.setSchemas(["alpha", "beta", "public"], forDatabase: db)

        XCTAssertTrue(sut.expandedSchemas.contains(sut.schemaKey(db, "public")))
    }

    func testSetSchemasOverwritesPreviousSchemas() {
        sut.setSchemas(["old_schema"], forDatabase: db)
        XCTAssertTrue(sut.expandedSchemas.contains(sut.schemaKey(db, "old_schema")))

        sut.setSchemas(["new_schema1", "public"], forDatabase: db)
        XCTAssertEqual(sut.schemas(for: db), ["new_schema1", "public"])
        XCTAssertTrue(sut.expandedSchemas.contains(sut.schemaKey(db, "public")))
    }

    func testSetSchemasCaseSensitivity() {
        // "Public" (uppercase P) is not "public"
        sut.setSchemas(["Public", "PRIVATE"], forDatabase: db)

        XCTAssertTrue(sut.expandedSchemas.contains(sut.schemaKey(db, "Public")))
        XCTAssertFalse(sut.expandedSchemas.contains(sut.schemaKey(db, "public")))
    }

    // MARK: - setSchemaObjects(db:schema:objects:)

    func testSetSchemaObjectsUpdatesTables() {
        let tables = [makeTable("users"), makeTable("orders")]
        sut.setSchemaObjects(db: db, schema: "public", objects: SchemaObjects(tables: tables))

        let key = sut.schemaKey(db, "public")
        XCTAssertEqual(sut.objectsPerKey[key]?.tables, tables)
    }

    func testSetSchemaObjectsUpdatesViews() {
        let views = [makeView("active_users"), makeView("order_summary")]
        sut.setSchemaObjects(db: db, schema: "public", objects: SchemaObjects(views: views))

        let key = sut.schemaKey(db, "public")
        XCTAssertEqual(sut.objectsPerKey[key]?.views, views)
    }

    func testSetSchemaObjectsUpdatesMatViews() {
        let matViews = [makeMatView("monthly_stats")]
        sut.setSchemaObjects(db: db, schema: "public", objects: SchemaObjects(materializedViews: matViews))

        let key = sut.schemaKey(db, "public")
        XCTAssertEqual(sut.objectsPerKey[key]?.materializedViews, matViews)
    }

    func testSetSchemaObjectsUpdatesFunctions() {
        let functions = [makeFunction("get_user")]
        sut.setSchemaObjects(db: db, schema: "public", objects: SchemaObjects(functions: functions))

        let key = sut.schemaKey(db, "public")
        XCTAssertEqual(sut.objectsPerKey[key]?.functions, functions)
    }

    func testSetSchemaObjectsWithAllTypes() {
        let tables = [makeTable("users")]
        let views = [makeView("user_stats")]
        let matViews = [makeMatView("daily_summary")]
        let functions = [makeFunction("calc_total")]
        sut.setSchemaObjects(db: db, schema: "public", objects: SchemaObjects(functions: functions, materializedViews: matViews, tables: tables, views: views))

        let key = sut.schemaKey(db, "public")
        XCTAssertEqual(sut.objectsPerKey[key]?.tables, tables)
        XCTAssertEqual(sut.objectsPerKey[key]?.views, views)
        XCTAssertEqual(sut.objectsPerKey[key]?.materializedViews, matViews)
        XCTAssertEqual(sut.objectsPerKey[key]?.functions, functions)
    }

    func testSetSchemaObjectsMarksSchemaAsLoaded() {
        sut.setSchemaObjects(db: db, schema: "public", objects: SchemaObjects())

        let key = sut.schemaKey(db, "public")
        XCTAssertTrue(sut.loadedKeys.contains(key))
    }

    func testSetSchemaObjectsWithEmptyAll() {
        sut.setSchemaObjects(db: db, schema: "public", objects: SchemaObjects())

        let key = sut.schemaKey(db, "public")
        XCTAssertEqual(sut.objectsPerKey[key]?.tables, [])
        XCTAssertEqual(sut.objectsPerKey[key]?.views, [])
        XCTAssertEqual(sut.objectsPerKey[key]?.materializedViews, [])
        XCTAssertEqual(sut.objectsPerKey[key]?.functions, [])
    }

    func testSetSchemaObjectsOverwritesPreviousState() {
        let oldTables = [makeTable("old_table")]
        sut.setSchemaObjects(db: db, schema: "public", objects: SchemaObjects(tables: oldTables))

        let newTables = [makeTable("new_table")]
        sut.setSchemaObjects(db: db, schema: "public", objects: SchemaObjects(tables: newTables))

        let key = sut.schemaKey(db, "public")
        XCTAssertEqual(sut.objectsPerKey[key]?.tables, newTables)
    }

    func testSetSchemaObjectsMultipleSchemas() {
        let publicTables = [makeTable("users")]
        let authTables = [makeTable("sessions")]
        sut.setSchemaObjects(db: db, schema: "public", objects: SchemaObjects(tables: publicTables))
        sut.setSchemaObjects(db: db, schema: "auth", objects: SchemaObjects(tables: authTables))

        let publicKey = sut.schemaKey(db, "public")
        let authKey = sut.schemaKey(db, "auth")
        XCTAssertEqual(sut.objectsPerKey[publicKey]?.tables, publicTables)
        XCTAssertEqual(sut.objectsPerKey[authKey]?.tables, authTables)
        XCTAssertTrue(sut.loadedKeys.contains(publicKey))
        XCTAssertTrue(sut.loadedKeys.contains(authKey))
    }

    func testSetSchemaObjectsDoesNotAffectSelectedObject() {
        let table = makeTable("users")
        sut.selectedObject = table
        sut.setSchemaObjects(db: db, schema: "public", objects: SchemaObjects(tables: [makeTable("orders")]))

        // setSchemaObjects does not clear selectedObject
        XCTAssertEqual(sut.selectedObject, table)
    }

    // MARK: - objects(for:schema:category:)

    func testObjectsForSchemaCategory() {
        let tables = [makeTable("users"), makeTable("orders")]
        let views = [makeView("stats")]
        let matViews = [makeMatView("summary")]
        let functions = [makeFunction("calc")]
        sut.setSchemaObjects(db: db, schema: "public", objects: SchemaObjects(functions: functions, materializedViews: matViews, tables: tables, views: views))

        XCTAssertEqual(sut.objects(for: db, schema: "public", category: .tables), tables)
        XCTAssertEqual(sut.objects(for: db, schema: "public", category: .views), views)
        XCTAssertEqual(sut.objects(for: db, schema: "public", category: .materializedViews), matViews)
        XCTAssertEqual(sut.objects(for: db, schema: "public", category: .functions), functions)
    }

    func testObjectsForUnloadedSchemaReturnsEmpty() {
        XCTAssertEqual(sut.objects(for: db, schema: "nonexistent", category: .tables), [])
        XCTAssertEqual(sut.objects(for: db, schema: "nonexistent", category: .views), [])
        XCTAssertEqual(sut.objects(for: db, schema: "nonexistent", category: .materializedViews), [])
        XCTAssertEqual(sut.objects(for: db, schema: "nonexistent", category: .functions), [])
    }

    // MARK: - categoryKey(_:_:_:)

    func testCategoryKeyFormat() {
        XCTAssertEqual(sut.categoryKey(db, "public", .tables), "\(db)\0public\0Tables")
        XCTAssertEqual(sut.categoryKey(db, "auth", .views), "\(db)\0auth\0Views")
        XCTAssertEqual(sut.categoryKey(db, "public", .materializedViews), "\(db)\0public\0Materialized Views")
        XCTAssertEqual(sut.categoryKey(db, "public", .functions), "\(db)\0public\0Functions")
    }

    // MARK: - Expansion helpers

    func testSetDatabaseExpanded() {
        sut.setDatabaseExpanded("mydb", true)
        XCTAssertTrue(sut.isDatabaseExpanded("mydb"))

        sut.setDatabaseExpanded("mydb", false)
        XCTAssertFalse(sut.isDatabaseExpanded("mydb"))
    }

    func testSetSchemaExpanded() {
        sut.setSchemaExpanded(db, "public", true)
        XCTAssertTrue(sut.isSchemaExpanded(db, "public"))

        sut.setSchemaExpanded(db, "public", false)
        XCTAssertFalse(sut.isSchemaExpanded(db, "public"))
    }

    func testSetCategoryExpanded() {
        sut.setCategoryExpanded(db, "public", .tables, true)
        XCTAssertTrue(sut.isCategoryExpanded(db, "public", .tables))

        sut.setCategoryExpanded(db, "public", .tables, false)
        XCTAssertFalse(sut.isCategoryExpanded(db, "public", .tables))
    }

    // MARK: - clear()

    func testClearResetsDatabases() {
        sut.setDatabases(["db1", "db2"], current: "db1")
        sut.clear()

        XCTAssertEqual(sut.databases, [])
    }

    func testClearResetsConnectedDatabase() {
        sut.setDatabases(["db1"], current: "db1")
        sut.clear()

        XCTAssertEqual(sut.connectedDatabase, "")
    }

    func testClearResetsSchemas() {
        sut.setSchemas(["public", "custom"], forDatabase: db)
        sut.clear()

        XCTAssertEqual(sut.schemas(for: db), [])
    }

    func testClearResetsObjectsPerKey() {
        sut.setSchemaObjects(db: db, schema: "public", objects: SchemaObjects(tables: [makeTable("users")]))
        sut.clear()

        XCTAssertTrue(sut.objectsPerKey.isEmpty)
    }

    func testClearResetsLoadedKeys() {
        sut.setSchemaObjects(db: db, schema: "public", objects: SchemaObjects())
        sut.clear()

        XCTAssertTrue(sut.loadedKeys.isEmpty)
    }

    func testClearResetsExpandedDatabases() {
        sut.setDatabases(["db1"], current: "db1")
        sut.clear()

        XCTAssertTrue(sut.expandedDatabases.isEmpty)
    }

    func testClearResetsExpandedSchemas() {
        sut.setSchemas(["public"], forDatabase: db)
        sut.clear()

        XCTAssertTrue(sut.expandedSchemas.isEmpty)
    }

    func testClearResetsExpandedCategories() {
        sut.setSchemas(["public"], forDatabase: db)
        sut.clear()

        XCTAssertTrue(sut.expandedCategories.isEmpty)
    }

    func testClearResetsSelectedObject() {
        sut.selectedObject = makeTable("users")
        sut.clear()

        XCTAssertNil(sut.selectedObject)
    }

    func testClearResetsAllStateAtOnce() {
        // Populate everything
        sut.setDatabases(["db1", "db2"], current: "db1")
        sut.setSchemas(["public", "analytics"], forDatabase: "db1")
        sut.setSchemaObjects(
            db: "db1",
            schema: "public",
            objects: SchemaObjects(
                functions: [makeFunction("calc")],
                materializedViews: [makeMatView("summary")],
                tables: [makeTable("users"), makeTable("orders")],
                views: [makeView("stats")]
            )
        )
        sut.selectedObject = makeTable("users")

        sut.clear()

        XCTAssertEqual(sut.databases, [])
        XCTAssertEqual(sut.connectedDatabase, "")
        XCTAssertEqual(sut.schemas(for: "db1"), [])
        XCTAssertTrue(sut.objectsPerKey.isEmpty)
        XCTAssertTrue(sut.loadedKeys.isEmpty)
        XCTAssertTrue(sut.expandedDatabases.isEmpty)
        XCTAssertTrue(sut.expandedSchemas.isEmpty)
        XCTAssertTrue(sut.expandedCategories.isEmpty)
        XCTAssertNil(sut.selectedObject)
    }

    func testClearOnAlreadyClearedStateIsHarmless() {
        sut.clear()

        XCTAssertEqual(sut.databases, [])
        XCTAssertEqual(sut.connectedDatabase, "")
        XCTAssertEqual(sut.schemas(for: db), [])
        XCTAssertTrue(sut.objectsPerKey.isEmpty)
        XCTAssertTrue(sut.loadedKeys.isEmpty)
        XCTAssertTrue(sut.expandedDatabases.isEmpty)
        XCTAssertTrue(sut.expandedSchemas.isEmpty)
        XCTAssertTrue(sut.expandedCategories.isEmpty)
        XCTAssertNil(sut.selectedObject)
    }

    func testClearThenRepopulate() {
        sut.setDatabases(["db1"], current: "db1")
        sut.setSchemas(["public"], forDatabase: "db1")
        sut.clear()

        sut.setDatabases(["new_db"], current: "new_db")
        sut.setSchemas(["custom"], forDatabase: "new_db")

        XCTAssertEqual(sut.databases, ["new_db"])
        XCTAssertEqual(sut.connectedDatabase, "new_db")
        XCTAssertEqual(sut.schemas(for: "new_db"), ["custom"])
        XCTAssertTrue(sut.expandedSchemas.contains(sut.schemaKey("new_db", "custom")))
    }

    // MARK: - clearDatabase(_:)

    func testClearDatabasePreservesDatabaseList() {
        sut.setDatabases(["db1", "db2"], current: "db1")
        sut.setSchemas(["public"], forDatabase: "db1")
        sut.setSchemaObjects(db: "db1", schema: "public", objects: SchemaObjects(tables: [makeTable("users")]))

        sut.clearDatabase("db1")

        XCTAssertEqual(sut.databases, ["db1", "db2"])
        XCTAssertEqual(sut.connectedDatabase, "db1")
        XCTAssertTrue(sut.expandedDatabases.contains("db1"))
    }

    func testClearDatabaseClearsSchemaState() {
        sut.setSchemas(["public", "auth"], forDatabase: db)
        sut.setSchemaObjects(db: db, schema: "public", objects: SchemaObjects(functions: [makeFunction("f1")], materializedViews: [makeMatView("m1")], tables: [makeTable("users")], views: [makeView("v1")]))
        sut.selectedObject = makeTable("users")

        sut.clearDatabase(db)

        XCTAssertEqual(sut.schemas(for: db), [])
        XCTAssertTrue(sut.objectsPerKey.isEmpty)
        XCTAssertTrue(sut.loadedKeys.isEmpty)
        XCTAssertTrue(sut.expandedSchemas.isEmpty)
        XCTAssertTrue(sut.expandedCategories.isEmpty)
        // Note: clearDatabase does not clear selectedObject; only clear() does.
    }

    // MARK: - objectCount via objects(for:schema:category:).count

    func testObjectCountForSchemaCategory() {
        sut.setSchemaObjects(
            db: db,
            schema: "public",
            objects: SchemaObjects(
                functions: [makeFunction("f1"), makeFunction("f2")],
                tables: [makeTable("a"), makeTable("b"), makeTable("c")],
                views: [makeView("v1")]
            )
        )

        XCTAssertEqual(sut.objects(for: db, schema: "public", category: .tables).count, 3)
        XCTAssertEqual(sut.objects(for: db, schema: "public", category: .views).count, 1)
        XCTAssertEqual(sut.objects(for: db, schema: "public", category: .materializedViews).count, 0)
        XCTAssertEqual(sut.objects(for: db, schema: "public", category: .functions).count, 2)
    }

    // MARK: - Helpers

    private func makeTable(_ name: String) -> DBObject {
        DBObject(schema: "public", name: name, type: .table)
    }

    private func makeView(_ name: String) -> DBObject {
        DBObject(schema: "public", name: name, type: .view)
    }

    private func makeMatView(_ name: String) -> DBObject {
        DBObject(schema: "public", name: name, type: .materializedView)
    }

    private func makeFunction(_ name: String) -> DBObject {
        DBObject(schema: "public", name: name, type: .function)
    }
}

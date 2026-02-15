import XCTest
@testable import SequelPG

@MainActor
final class NavigatorViewModelTests: XCTestCase {

    private var sut: NavigatorViewModel!

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

    func testInitialSelectedDatabaseIsEmpty() {
        XCTAssertEqual(sut.selectedDatabase, "")
    }

    func testInitialSchemasIsEmpty() {
        XCTAssertEqual(sut.schemas, [])
    }

    func testInitialSelectedSchemaIsEmpty() {
        XCTAssertEqual(sut.selectedSchema, "")
    }

    func testInitialTablesIsEmpty() {
        XCTAssertEqual(sut.tables, [])
    }

    func testInitialViewsIsEmpty() {
        XCTAssertEqual(sut.views, [])
    }

    func testInitialSelectedObjectIsNil() {
        XCTAssertNil(sut.selectedObject)
    }

    // MARK: - setDatabases(_:current:)

    func testSetDatabasesUpdatesDatabasesList() {
        sut.setDatabases(["db1", "db2", "db3"], current: "db1")

        XCTAssertEqual(sut.databases, ["db1", "db2", "db3"])
    }

    func testSetDatabasesSetsSelectedDatabase() {
        sut.setDatabases(["db1", "db2"], current: "db2")

        XCTAssertEqual(sut.selectedDatabase, "db2")
    }

    func testSetDatabasesWithCurrentNotInList() {
        // The method sets selectedDatabase to whatever `current` is,
        // even if it is not in the databases list.
        sut.setDatabases(["db1", "db2"], current: "db_other")

        XCTAssertEqual(sut.databases, ["db1", "db2"])
        XCTAssertEqual(sut.selectedDatabase, "db_other")
    }

    func testSetDatabasesWithEmptyList() {
        sut.setDatabases([], current: "")

        XCTAssertEqual(sut.databases, [])
        XCTAssertEqual(sut.selectedDatabase, "")
    }

    func testSetDatabasesWithSingleDatabase() {
        sut.setDatabases(["only_db"], current: "only_db")

        XCTAssertEqual(sut.databases, ["only_db"])
        XCTAssertEqual(sut.selectedDatabase, "only_db")
    }

    func testSetDatabasesOverwritesPreviousState() {
        sut.setDatabases(["old_db"], current: "old_db")
        sut.setDatabases(["new_db1", "new_db2"], current: "new_db2")

        XCTAssertEqual(sut.databases, ["new_db1", "new_db2"])
        XCTAssertEqual(sut.selectedDatabase, "new_db2")
    }

    func testSetDatabasesWithEmptyCurrentString() {
        sut.setDatabases(["db1", "db2"], current: "")

        XCTAssertEqual(sut.databases, ["db1", "db2"])
        XCTAssertEqual(sut.selectedDatabase, "")
    }

    // MARK: - setSchemas(_:)

    func testSetSchemasUpdatesSchemasList() {
        sut.setSchemas(["public", "private", "analytics"])

        XCTAssertEqual(sut.schemas, ["public", "private", "analytics"])
    }

    func testSetSchemasDefaultsToPublicWhenAvailable() {
        sut.setSchemas(["private", "public", "analytics"])

        XCTAssertEqual(sut.selectedSchema, "public")
    }

    func testSetSchemasSelectsFirstWhenPublicNotAvailable() {
        sut.setSchemas(["custom_schema", "analytics"])

        XCTAssertEqual(sut.selectedSchema, "custom_schema")
    }

    func testSetSchemasWithOnlyPublic() {
        sut.setSchemas(["public"])

        XCTAssertEqual(sut.schemas, ["public"])
        XCTAssertEqual(sut.selectedSchema, "public")
    }

    func testSetSchemasWithEmptyList() {
        // When the list is empty there is no "public" and no first element,
        // so selectedSchema should remain unchanged (empty from initial state).
        sut.setSchemas([])

        XCTAssertEqual(sut.schemas, [])
        XCTAssertEqual(sut.selectedSchema, "")
    }

    func testSetSchemasWithSingleNonPublicSchema() {
        sut.setSchemas(["custom"])

        XCTAssertEqual(sut.schemas, ["custom"])
        XCTAssertEqual(sut.selectedSchema, "custom")
    }

    func testSetSchemasPublicIsFirstInList() {
        sut.setSchemas(["public", "other"])

        XCTAssertEqual(sut.selectedSchema, "public")
    }

    func testSetSchemasPublicIsLastInList() {
        sut.setSchemas(["alpha", "beta", "public"])

        XCTAssertEqual(sut.selectedSchema, "public")
    }

    func testSetSchemasOverwritesPreviousSchemas() {
        sut.setSchemas(["old_schema"])
        XCTAssertEqual(sut.selectedSchema, "old_schema")

        sut.setSchemas(["new_schema1", "public"])
        XCTAssertEqual(sut.schemas, ["new_schema1", "public"])
        XCTAssertEqual(sut.selectedSchema, "public")
    }

    func testSetSchemasDoesNotChangeSelectedSchemaWhenEmpty() {
        // First set a schema, then pass an empty list
        sut.setSchemas(["public"])
        XCTAssertEqual(sut.selectedSchema, "public")

        sut.setSchemas([])
        // selectedSchema remains "public" because neither branch executes
        XCTAssertEqual(sut.selectedSchema, "public")
    }

    func testSetSchemasCaseSensitivity() {
        // "Public" (uppercase P) is not "public"
        sut.setSchemas(["Public", "PRIVATE"])

        XCTAssertEqual(sut.selectedSchema, "Public")
    }

    // MARK: - setObjects(tables:views:)

    func testSetObjectsUpdatesTables() {
        let tables = [makeTable("users"), makeTable("orders")]
        sut.setObjects(tables: tables, views: [])

        XCTAssertEqual(sut.tables, tables)
    }

    func testSetObjectsUpdatesViews() {
        let views = [makeView("active_users"), makeView("order_summary")]
        sut.setObjects(tables: [], views: views)

        XCTAssertEqual(sut.views, views)
    }

    func testSetObjectsWithBothTablesAndViews() {
        let tables = [makeTable("users")]
        let views = [makeView("user_stats")]
        sut.setObjects(tables: tables, views: views)

        XCTAssertEqual(sut.tables, tables)
        XCTAssertEqual(sut.views, views)
    }

    func testSetObjectsWithEmptyTablesAndViews() {
        sut.setObjects(tables: [], views: [])

        XCTAssertEqual(sut.tables, [])
        XCTAssertEqual(sut.views, [])
    }

    func testSetObjectsOverwritesPreviousState() {
        let oldTables = [makeTable("old_table")]
        let oldViews = [makeView("old_view")]
        sut.setObjects(tables: oldTables, views: oldViews)

        let newTables = [makeTable("new_table")]
        let newViews = [makeView("new_view")]
        sut.setObjects(tables: newTables, views: newViews)

        XCTAssertEqual(sut.tables, newTables)
        XCTAssertEqual(sut.views, newViews)
    }

    func testSetObjectsWithMultipleTables() {
        let tables = [
            makeTable("users"),
            makeTable("orders"),
            makeTable("products"),
            makeTable("categories")
        ]
        sut.setObjects(tables: tables, views: [])

        XCTAssertEqual(sut.tables.count, 4)
        XCTAssertEqual(sut.tables, tables)
    }

    func testSetObjectsDoesNotAffectSelectedObject() {
        let table = makeTable("users")
        sut.selectedObject = table
        sut.setObjects(tables: [makeTable("orders")], views: [])

        // setObjects does not clear selectedObject
        XCTAssertEqual(sut.selectedObject, table)
    }

    // MARK: - clear()

    func testClearResetsDatabases() {
        sut.setDatabases(["db1", "db2"], current: "db1")
        sut.clear()

        XCTAssertEqual(sut.databases, [])
    }

    func testClearResetsSelectedDatabase() {
        sut.setDatabases(["db1"], current: "db1")
        sut.clear()

        XCTAssertEqual(sut.selectedDatabase, "")
    }

    func testClearResetsSchemas() {
        sut.setSchemas(["public", "custom"])
        sut.clear()

        XCTAssertEqual(sut.schemas, [])
    }

    func testClearResetsSelectedSchema() {
        sut.setSchemas(["public"])
        sut.clear()

        XCTAssertEqual(sut.selectedSchema, "")
    }

    func testClearResetsTables() {
        sut.setObjects(tables: [makeTable("users")], views: [])
        sut.clear()

        XCTAssertEqual(sut.tables, [])
    }

    func testClearResetsViews() {
        sut.setObjects(tables: [], views: [makeView("stats")])
        sut.clear()

        XCTAssertEqual(sut.views, [])
    }

    func testClearResetsSelectedObject() {
        sut.selectedObject = makeTable("users")
        sut.clear()

        XCTAssertNil(sut.selectedObject)
    }

    func testClearResetsAllStateAtOnce() {
        // Populate everything
        sut.setDatabases(["db1", "db2"], current: "db1")
        sut.setSchemas(["public", "analytics"])
        sut.setObjects(
            tables: [makeTable("users"), makeTable("orders")],
            views: [makeView("stats")]
        )
        sut.selectedObject = makeTable("users")

        sut.clear()

        XCTAssertEqual(sut.databases, [])
        XCTAssertEqual(sut.selectedDatabase, "")
        XCTAssertEqual(sut.schemas, [])
        XCTAssertEqual(sut.selectedSchema, "")
        XCTAssertEqual(sut.tables, [])
        XCTAssertEqual(sut.views, [])
        XCTAssertNil(sut.selectedObject)
    }

    func testClearOnAlreadyClearedStateIsHarmless() {
        sut.clear()

        XCTAssertEqual(sut.databases, [])
        XCTAssertEqual(sut.selectedDatabase, "")
        XCTAssertEqual(sut.schemas, [])
        XCTAssertEqual(sut.selectedSchema, "")
        XCTAssertEqual(sut.tables, [])
        XCTAssertEqual(sut.views, [])
        XCTAssertNil(sut.selectedObject)
    }

    func testClearThenRepopulate() {
        sut.setDatabases(["db1"], current: "db1")
        sut.setSchemas(["public"])
        sut.clear()

        sut.setDatabases(["new_db"], current: "new_db")
        sut.setSchemas(["custom"])

        XCTAssertEqual(sut.databases, ["new_db"])
        XCTAssertEqual(sut.selectedDatabase, "new_db")
        XCTAssertEqual(sut.schemas, ["custom"])
        XCTAssertEqual(sut.selectedSchema, "custom")
    }

    // MARK: - Helpers

    private func makeTable(_ name: String) -> DBObject {
        DBObject(schema: "public", name: name, type: .table)
    }

    private func makeView(_ name: String) -> DBObject {
        DBObject(schema: "public", name: name, type: .view)
    }
}

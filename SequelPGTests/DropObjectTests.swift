import XCTest
@testable import SequelPG

// MARK: - Drop Object Tests

/// Tests for AppViewModel.dropObject and the catalog lookup behind
/// DatabaseClient.dropOverloadableObject:
/// - simple object types are dropped with quoted identifiers via runQuery
/// - routines, aggregates, and operators go through dropOverloadableObject
/// - success logs history, refreshes the navigator, and clears only a stale selection
/// - failures surface the error without refreshing
/// - the lookup query binds names as parameters and filters by object kind
@MainActor
final class DropObjectTests: AppViewModelTestCase {

    // MARK: - Simple types

    func testDropTableQuotesSchemaAndNameAndLogsHistory() async {
        await makeConnectedVM()

        await vm.dropObject(DBObject(schema: "My Schema", name: "odd\"name", type: .table))

        let expected = "DROP TABLE \"My Schema\".\"odd\"\"name\" CASCADE"
        let sqls = await mockDB.getAllRunQuerySQLs()
        XCTAssertEqual(sqls, [expected])
        XCTAssertNil(vm.errorMessage)
        let entry = vm.queryHistoryVM.entries.first { $0.sql == expected }
        XCTAssertEqual(entry?.success, true)
        XCTAssertEqual(entry?.source, .system)
    }

    func testDropTableFailureLogsHistoryAndSetsError() async {
        await makeConnectedVM()
        await mockDB.setRunQueryHandler { _ in throw AppError.queryFailed("permission denied") }

        await vm.dropObject(DBObject(schema: "app", name: "t", type: .table))

        XCTAssertTrue(vm.errorMessage?.contains("permission denied") ?? false)
        let entry = vm.queryHistoryVM.entries.first { $0.sql.hasPrefix("DROP TABLE") }
        XCTAssertEqual(entry?.success, false)
    }

    // MARK: - Overloadable types

    func testOverloadableTypesUseDropOverloadableObject() async {
        await makeConnectedVM()
        let objects = [
            DBObject(schema: "app", name: "f(integer)", type: .function),
            DBObject(schema: "app", name: "trg", type: .triggerFunction),
            DBObject(schema: "app", name: "do_work", type: .procedure),
            DBObject(schema: "app", name: "mysum", type: .aggregate),
            DBObject(schema: "app", name: "===(text, text)", type: .operator),
        ]

        for object in objects {
            await vm.dropObject(object)
        }

        let dropped = await mockDB.getDroppedOverloadableObjects()
        XCTAssertEqual(dropped, objects)
        let sqls = await mockDB.getAllRunQuerySQLs()
        XCTAssertFalse(sqls.contains { $0.hasPrefix("DROP") }, "overloadable drops must not go through runQuery")
        XCTAssertNil(vm.errorMessage)
    }

    func testOverloadableDropLogsTheExecutedStatement() async {
        await makeConnectedVM()
        await mockDB.setDropOverloadableHandler { _ in "DROP OPERATOR app.=== (text, text) CASCADE" }

        await vm.dropObject(DBObject(schema: "app", name: "===(text, text)", type: .operator))

        let entry = vm.queryHistoryVM.entries.first { $0.sql.hasPrefix("DROP OPERATOR") }
        XCTAssertEqual(entry?.sql, "DROP OPERATOR app.=== (text, text) CASCADE")
        XCTAssertEqual(entry?.success, true)
    }

    func testOverloadableDropFailureSetsErrorAndSkipsRefresh() async {
        await makeConnectedVM()
        await mockDB.setDropOverloadableHandler { _ in
            throw AppError.validationFailed(["agg has several overloads."])
        }

        await vm.dropObject(DBObject(schema: "app", name: "agg", type: .aggregate))

        XCTAssertEqual(vm.errorMessage, "agg has several overloads.")
        let invalidations = await mockDB.invalidateCacheCallCount
        XCTAssertEqual(invalidations, 0)
    }

    // MARK: - Refresh after drop

    func testDropClearsSelectionOnlyWhenItIsTheDroppedObject() async {
        await makeConnectedVM()
        let dropped = DBObject(schema: "app", name: "t", type: .table)
        let other = DBObject(schema: "app", name: "other", type: .table)

        vm.navigatorVM.selectedObject = dropped
        await vm.dropObject(dropped)
        XCTAssertNil(vm.navigatorVM.selectedObject)

        vm.navigatorVM.selectedObject = other
        await vm.dropObject(dropped)
        XCTAssertEqual(vm.navigatorVM.selectedObject, other)
    }

    func testDropInvalidatesCacheAfterSuccess() async {
        await makeConnectedVM()

        await vm.dropObject(DBObject(schema: "app", name: "t", type: .view))

        let invalidations = await mockDB.invalidateCacheCallCount
        XCTAssertEqual(invalidations, 1)
    }

    // MARK: - Lookup query

    private func lookup(_ name: String, _ type: DBObjectType, version: Int = 18) -> String? {
        DatabaseClient.dropTargetLookupQuery(
            for: DBObject(schema: "app", name: name, type: type), serverVersion: version
        )?.sql
    }

    func testLookupBindsSchemaAndNameAsParameters() {
        let query = DatabaseClient.dropTargetLookupQuery(
            for: DBObject(schema: "app", name: "f(text)'; DROP TABLE users; --", type: .function),
            serverVersion: 18
        )

        XCTAssertEqual(query?.binds.count, 2)
        XCTAssertFalse(query?.sql.contains("DROP TABLE users") ?? true)
    }

    func testFunctionLookupMatchesSignatureAndExcludesTriggerFunctions() throws {
        let sql = try XCTUnwrap(lookup("f(integer)", .function))
        XCTAssertTrue(sql.contains("\(CatalogSignature.routine) = $2"))
        XCTAssertTrue(sql.contains("p.prokind = 'f'"))
        XCTAssertTrue(sql.contains("NOT p.prorettype = 'pg_catalog.trigger'"))
    }

    func testFunctionLookupBeforePG11UsesLegacyKindColumns() throws {
        let sql = try XCTUnwrap(lookup("f(integer)", .function, version: 10))
        XCTAssertFalse(sql.contains("prokind"))
        XCTAssertTrue(sql.contains("NOT p.proisagg AND NOT p.proiswindow"))
    }

    func testTriggerFunctionLookupMatchesBareNameAndTriggerReturnType() throws {
        let sql = try XCTUnwrap(lookup("audit", .triggerFunction))
        XCTAssertTrue(sql.contains("p.proname = $2"))
        XCTAssertTrue(sql.contains("AND p.prorettype = 'pg_catalog.trigger'"))
    }

    func testProcedureLookupRequiresPG11() throws {
        let sql = try XCTUnwrap(lookup("do_work", .procedure))
        XCTAssertTrue(sql.contains("p.prokind = 'p'"))
        XCTAssertNil(lookup("do_work", .procedure, version: 10))
    }

    func testAggregateLookupFiltersAggregatesAndSpellsZeroArgsAsStar() throws {
        let sql = try XCTUnwrap(lookup("mysum", .aggregate))
        XCTAssertTrue(sql.contains("p.prokind = 'a'"))
        XCTAssertTrue(sql.contains("WHEN p.pronargs = 0 THEN '*'"))
        XCTAssertTrue(try XCTUnwrap(lookup("mysum", .aggregate, version: 10)).contains("p.proisagg"))
    }

    func testOperatorLookupMatchesSignature() throws {
        let sql = try XCTUnwrap(lookup("===(text, text)", .operator))
        XCTAssertTrue(sql.contains("\(CatalogSignature.operator) = $2"))
        XCTAssertTrue(sql.contains("FROM pg_operator o"))
    }

    func testNonOverloadableTypesHaveNoLookupOrKeyword() {
        XCTAssertNil(lookup("t", .table))
        XCTAssertNil(DatabaseClient.dropKeyword(for: .table))
        XCTAssertEqual(DatabaseClient.dropKeyword(for: .triggerFunction), "FUNCTION")
    }
}

import XCTest
@testable import SequelPG

// MARK: - Drop Object Tests

/// Tests for AppViewModel.dropObject:
/// - simple object types are dropped with quoted identifiers
/// - overloadable objects (routines, aggregates, operators) are resolved by a
///   catalog lookup and dropped with the server-rendered target verbatim
/// - zero or multiple lookup matches abort without issuing a DROP
@MainActor
final class DropObjectTests: AppViewModelTestCase {

    // MARK: - Helpers (file-specific)

    private func result(_ targets: [String]) -> QueryResult {
        QueryResult(
            columns: ["format"],
            rows: targets.map { [.text($0)] },
            executionTime: 0.01,
            rowsAffected: nil,
            isTruncated: false
        )
    }

    /// Answers catalog lookups with `targets` and every other statement with an empty result.
    private func stubLookup(returning targets: [String]) async {
        let lookup = result(targets)
        let empty = result([])
        await mockDB.setRunQueryHandler { sql in
            sql.hasPrefix("SELECT format(") ? lookup : empty
        }
    }

    private func dropStatements() async -> [String] {
        await mockDB.getAllRunQuerySQLs().filter { $0.hasPrefix("DROP ") }
    }

    // MARK: - Simple types

    func testDropTableQuotesSchemaAndName() async {
        await makeConnectedVM()

        await vm.dropObject(DBObject(schema: "My Schema", name: "odd\"name", type: .table))

        let drops = await dropStatements()
        XCTAssertEqual(drops, ["DROP TABLE \"My Schema\".\"odd\"\"name\" CASCADE"])
        XCTAssertNil(vm.errorMessage)
    }

    // MARK: - Overloadable types

    func testDropFunctionUsesServerRenderedTarget() async {
        await makeConnectedVM()
        let target = "app.\"MyFn\"(integer, \"app\".\"weird) CASCADE; --\")"
        await stubLookup(returning: [target])

        await vm.dropObject(DBObject(schema: "app", name: "MyFn(integer, app.\"weird) CASCADE; --\")", type: .function))

        let drops = await dropStatements()
        XCTAssertEqual(drops, ["DROP FUNCTION \(target) CASCADE"])
        XCTAssertNil(vm.errorMessage)
    }

    func testFunctionLookupMatchesFullSignatureAsEscapedLiteral() {
        let object = DBObject(schema: "app", name: "f(text, \"x'; DROP TABLE users; --\\\")", type: .function)

        let sql = AppViewModel.dropTargetLookupSQL(for: object)

        XCTAssertTrue(sql.contains("\(CatalogSignature.routine) = E'f(text, \"x''; DROP TABLE users; --\\\\\")'"))
        XCTAssertTrue(sql.contains("n.nspname = E'app'"))
        XCTAssertTrue(sql.contains("NOT EXISTS (SELECT 1 FROM pg_aggregate"))
    }

    func testProcedureLookupMatchesBareName() {
        let sql = AppViewModel.dropTargetLookupSQL(for: DBObject(schema: "app", name: "do_work", type: .procedure))

        XCTAssertTrue(sql.contains("p.proname = E'do_work'"))
        XCTAssertFalse(sql.contains("oidvectortypes(p.proargtypes) || ')' ="))
    }

    func testAggregateLookupSelectsAggregatesAndStarForZeroArgs() {
        let sql = AppViewModel.dropTargetLookupSQL(for: DBObject(schema: "app", name: "mysum", type: .aggregate))

        XCTAssertTrue(sql.contains("AND EXISTS (SELECT 1 FROM pg_aggregate"))
        XCTAssertFalse(sql.contains("NOT EXISTS"))
        XCTAssertTrue(sql.contains("WHEN p.pronargs = 0 THEN '*'"))
    }

    func testDropAggregateUsesAggregateKeyword() async {
        await makeConnectedVM()
        await stubLookup(returning: ["app.mysum(integer)"])

        await vm.dropObject(DBObject(schema: "app", name: "mysum", type: .aggregate))

        let drops = await dropStatements()
        XCTAssertEqual(drops, ["DROP AGGREGATE app.mysum(integer) CASCADE"])
    }

    func testDropOperatorMatchesSignatureAndUsesArgumentTypes() async {
        await makeConnectedVM()
        await stubLookup(returning: ["app.=== (text, text)"])
        let object = DBObject(schema: "app", name: "===(text, text)", type: .operator)

        await vm.dropObject(object)

        let lookup = AppViewModel.dropTargetLookupSQL(for: object)
        XCTAssertTrue(lookup.contains("\(CatalogSignature.operator) = E'===(text, text)'"))
        let drops = await dropStatements()
        XCTAssertEqual(drops, ["DROP OPERATOR app.=== (text, text) CASCADE"])
        XCTAssertNil(vm.errorMessage)
    }

    // MARK: - Lookup failures

    func testDropAbortsWhenObjectNoLongerExists() async {
        await makeConnectedVM()
        await stubLookup(returning: [])

        await vm.dropObject(DBObject(schema: "app", name: "gone(integer)", type: .function))

        let drops = await dropStatements()
        XCTAssertTrue(drops.isEmpty)
        XCTAssertTrue(vm.errorMessage?.contains("no longer exists") ?? false)
    }

    func testDropAbortsWhenNameMatchesSeveralOverloads() async {
        await makeConnectedVM()
        await stubLookup(returning: ["app.agg(integer)", "app.agg(text)"])

        await vm.dropObject(DBObject(schema: "app", name: "agg", type: .aggregate))

        let drops = await dropStatements()
        XCTAssertTrue(drops.isEmpty)
        XCTAssertTrue(vm.errorMessage?.contains("several overloads") ?? false)
    }

    func testDropReportsLookupError() async {
        await makeConnectedVM()
        await mockDB.setRunQueryHandler { _ in throw AppError.queryFailed("permission denied") }

        await vm.dropObject(DBObject(schema: "app", name: "f()", type: .function))

        let drops = await dropStatements()
        XCTAssertTrue(drops.isEmpty)
        XCTAssertTrue(vm.errorMessage?.contains("permission denied") ?? false)
    }
}

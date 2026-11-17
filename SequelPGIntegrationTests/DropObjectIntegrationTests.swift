import XCTest
@testable import SequelPG

/// Sidebar DROP for every droppable object kind, on every server version,
/// resolved from real `listAllSchemaObjects` names (the round trip that broke
/// for operators/aggregates/overloads before v0.3.7).
final class DropObjectIntegrationTests: IntegrationTestCase {
    private func populate(_ client: DatabaseClient, schema: String, major: Int) async throws {
        let s = quoteIdent(schema)
        let statements = [
            "CREATE TABLE \(s).t (id int PRIMARY KEY)",
            "CREATE VIEW \(s).v AS SELECT 1 AS x",
            "CREATE MATERIALIZED VIEW \(s).mv AS SELECT 1 AS x",
            "CREATE SEQUENCE \(s).seq",
            "CREATE TYPE \(s).color AS ENUM ('red', 'green')",
            "CREATE DOMAIN \(s).pos AS int CHECK (VALUE > 0)",
            "CREATE FUNCTION \(s).f(a int) RETURNS int LANGUAGE sql AS 'SELECT a'",
            "CREATE FUNCTION \(s).f(a text) RETURNS text LANGUAGE sql AS 'SELECT a'",
            "CREATE FUNCTION \(s).f(a \(s).color) RETURNS int LANGUAGE sql AS 'SELECT 1'",
            "CREATE PROCEDURE \(s).p() LANGUAGE sql AS 'SELECT 1'",
            "CREATE AGGREGATE \(s).agg(int) (SFUNC = int4pl, STYPE = int, INITCOND = '0')",
            "CREATE FUNCTION \(s).eq(text, text) RETURNS boolean LANGUAGE sql AS 'SELECT $1 = $2'",
            "CREATE OPERATOR \(s).=== (LEFTARG = text, RIGHTARG = text, FUNCTION = \(s).eq)",
            "CREATE FUNCTION \(s).trg() RETURNS trigger LANGUAGE plpgsql AS 'BEGIN RETURN NEW; END'",
        ]
        for sql in statements {
            try await client.exec(sql)
        }
        _ = major
    }

    private func allObjects(_ client: DatabaseClient, schema: String) async throws -> [DBObject] {
        await client.invalidateCache()
        let o = try await client.listAllSchemaObjects(schema: schema)
        return o.tables + o.views + o.materializedViews + o.sequences + o.types + o.domains + o.functions
            + o.procedures + o.aggregates + o.operators + o.triggerFunctions
    }

    func testDropEveryObjectKindOnEveryServer() async throws {
        for server in TestCluster.Server.allCases {
            let client = try await connect(server)
            let schema = try await makeScratchSchema(on: client)
            try await populate(client, schema: schema, major: TestCluster.major(server))

            let objects = try await allObjects(client, schema: schema)
            let functionOverloads = objects.filter { $0.type == .function && $0.name.hasPrefix("f(") }
            XCTAssertEqual(functionOverloads.count, 3, "\(server): \(objects.map(\.name))")

            // Drop one overload first: exactly that one must disappear.
            let intOverload = try XCTUnwrap(functionOverloads.first { $0.name == "f(integer)" }, "\(server)")
            let sql = try await client.drop(intOverload, inDatabase: TestCluster.database, timeout: 10)
            XCTAssertTrue(sql.hasPrefix("DROP FUNCTION"), "\(server): \(sql)")
            let remaining = try await allObjects(client, schema: schema).filter { $0.name.hasPrefix("f(") }
            XCTAssertEqual(remaining.count, 2, "\(server): \(remaining.map(\.name))")

            // Then everything else. Dropping a type cascades to dependents,
            // so re-list before each drop and skip what is already gone.
            for object in objects where object != intOverload {
                let live = try await allObjects(client, schema: schema)
                guard live.contains(object) else { continue }
                do {
                    _ = try await client.drop(object, inDatabase: TestCluster.database, timeout: 10)
                } catch {
                    XCTFail("\(server): DROP \(object.type) \(object.name) failed: \(message(of: error))")
                }
            }
            let left = try await allObjects(client, schema: schema)
            XCTAssertTrue(left.isEmpty, "\(server): left behind \(left.map { "\($0.type) \($0.name)" })")
        }
    }

    func testDropRefusesWhenConnectedToAnotherDatabase() async throws {
        let client = try await connect()
        let object = DBObject(schema: "qa", name: "people", type: .table)
        let error = await assertThrowsAsync {
            try await client.drop(object, inDatabase: TestCluster.otherDatabase, timeout: 10)
        }
        guard case .validationFailed? = error as? AppError else {
            return XCTFail("Expected validationFailed, got \(String(describing: error))")
        }
        let still = try await client.scalar("SELECT count(*) FROM qa.people")
        XCTAssertEqual(still, "50", "Nothing may be dropped")
    }

    func testDropQuotesIdentifiers() async throws {
        let client = try await connect()
        let schema = try await makeScratchSchema(on: client)
        try await client.exec("CREATE TABLE \(quoteIdent(schema)).\"Robert'); DROP TABLE x;--\" (id int)")
        let tables = try await client.listTables(schema: schema)
        let table = try XCTUnwrap(tables.first)
        _ = try await client.drop(table, inDatabase: TestCluster.database, timeout: 10)
        await client.invalidateCache()
        let after = try await client.listTables(schema: schema)
        XCTAssertTrue(after.isEmpty)
    }
}

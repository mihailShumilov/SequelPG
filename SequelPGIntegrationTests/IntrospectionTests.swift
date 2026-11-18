import XCTest
@testable import SequelPG

/// Catalog introspection behind the navigator, Structure tab and ERD, run on
/// every server version — `pg_catalog` differs between majors (prokind,
/// postfix operators, partitioning columns…), so each query must hold on all.
final class IntrospectionTests: IntegrationTestCase {
    private func names(_ objects: [DBObject]) -> Set<String> { Set(objects.map(\.name)) }

    func testSchemasOnEveryServer() async throws {
        for server in TestCluster.Server.allCases {
            let client = try await connect(server)
            let schemas = try await client.listSchemas()
            XCTAssertTrue(schemas.contains("qa"), "\(server): \(schemas)")
            XCTAssertTrue(schemas.contains("public"), "\(server)")
            XCTAssertFalse(schemas.contains("pg_toast"), "\(server): system schemas must be hidden")
        }
    }

    func testRelationsOnEveryServer() async throws {
        for server in TestCluster.Server.allCases {
            let client = try await connect(server)
            let tables = names(try await client.listTables(schema: "qa"))
            for expected in ["people", "big_numbers", "Weird Table", "type_samples", "parent", "child",
                             "editable", "no_pk", "measurements"]
            {
                XCTAssertTrue(tables.contains(expected), "\(server): table \(expected) missing from \(tables)")
            }
            let views = names(try await client.listViews(schema: "qa"))
            XCTAssertEqual(views, ["adults"], "\(server)")
            let matviews = names(try await client.listMaterializedViews(schema: "qa"))
            XCTAssertEqual(matviews, ["mood_counts"], "\(server)")
            let sequences = names(try await client.listSequences(schema: "qa"))
            XCTAssertTrue(sequences.contains("ticket_seq"), "\(server): \(sequences)")
        }
    }

    func testRoutinesAndTypesOnEveryServer() async throws {
        for server in TestCluster.Server.allCases {
            let client = try await connect(server)
            let functions = names(try await client.listFunctions(schema: "qa"))
            XCTAssertTrue(functions.contains("add(integer, integer)"), "\(server): \(functions)")
            XCTAssertTrue(functions.contains("add(numeric, numeric)"), "\(server): overloads must be distinct")
            XCTAssertTrue(functions.contains("slow(double precision)"), "\(server)")
            XCTAssertFalse(functions.contains { $0.hasPrefix("audit_trigger") }, "\(server): trigger functions listed separately")

            let all = try await client.listAllSchemaObjects(schema: "qa")
            XCTAssertTrue(names(all.procedures).contains { $0.hasPrefix("touch_people") }, "\(server): \(names(all.procedures))")
            XCTAssertTrue(names(all.aggregates).contains { $0.hasPrefix("sum_sq") }, "\(server): \(names(all.aggregates))")
            XCTAssertTrue(names(all.operators).contains { $0.hasPrefix("===") }, "\(server): \(names(all.operators))")
            XCTAssertTrue(names(all.triggerFunctions).contains { $0.hasPrefix("audit_trigger") }, "\(server)")
            XCTAssertTrue(names(all.domains).contains("positive_int"), "\(server): \(names(all.domains))")

            let types = names(try await client.listTypes(schema: "qa"))
            XCTAssertTrue(types.contains("mood"), "\(server): \(types)")
            XCTAssertTrue(types.contains("point2"), "\(server): \(types)")
        }
    }

    func testColumnsAndKeysOnEveryServer() async throws {
        for server in TestCluster.Server.allCases {
            let client = try await connect(server)
            let columns = try await client.getColumns(schema: "qa", table: "people")
            XCTAssertEqual(columns.map(\.name), ["id", "name", "email", "age", "mood", "created_at"], "\(server)")
            let id = try XCTUnwrap(columns.first { $0.name == "id" })
            XCTAssertTrue(id.isPrimaryKey, "\(server)")
            XCTAssertNotNil(id.columnDefault, "\(server): serial default")
            XCTAssertFalse(try XCTUnwrap(columns.first { $0.name == "name" }).isNullable, "\(server)")
            XCTAssertTrue(try XCTUnwrap(columns.first { $0.name == "age" }).isNullable, "\(server)")

            let pk = try await client.getPrimaryKeys(schema: "qa", table: "people")
            XCTAssertEqual(pk, ["id"], "\(server)")
            let noPK = try await client.getPrimaryKeys(schema: "qa", table: "no_pk")
            XCTAssertEqual(noPK, [], "\(server)")

            let weird = try await client.getColumns(schema: "qa", table: "Weird Table")
            XCTAssertEqual(weird.map(\.name), ["Mixed Case", "with space", "quote\"d", "кириллица"], "\(server)")
        }
    }

    func testApproximateRowCount() async throws {
        for server in TestCluster.Server.allCases {
            let client = try await connect(server)
            let approx = try await client.getApproximateRowCount(schema: "qa", table: "big_numbers")
            XCTAssertEqual(Double(approx), 100_000, accuracy: 10_000, "\(server)")
        }
    }

    func testIndexesConstraintsTriggersPartitionsOnEveryServer() async throws {
        for server in TestCluster.Server.allCases {
            let client = try await connect(server)
            let indexes = try await client.listIndexes(schema: "qa", table: "people")
            let indexNames = Set(indexes.map(\.name))
            XCTAssertTrue(indexNames.isSuperset(of: ["people_pkey", "people_email_key", "people_age_idx"]), "\(server): \(indexNames)")
            XCTAssertTrue(indexes.first { $0.name == "people_pkey" }?.isPrimary == true, "\(server)")
            XCTAssertTrue(indexes.first { $0.name == "people_email_key" }?.isUnique == true, "\(server)")

            let constraints = try await client.listConstraints(schema: "qa", table: "child")
            let fk = constraints.first { $0.kind == .foreignKey }
            XCTAssertNotNil(fk, "\(server)")
            XCTAssertEqual(fk?.columns, ["parent_id"], "\(server)")
            XCTAssertEqual(fk?.referencedColumns, ["id"], "\(server)")

            let triggers = try await client.listTriggers(schema: "qa", table: "people")
            XCTAssertEqual(triggers.map(\.name), ["people_audit"], "\(server)")

            let partitions = try await client.listPartitions(schema: "qa", table: "measurements")
            XCTAssertEqual(Set(partitions.map(\.name)), ["qa.measurements_2026_h1", "qa.measurements_2026_h2"], "\(server)")

            let fks = try await client.listForeignKeys(schema: "qa")
            XCTAssertTrue(fks.contains { $0.table == "child" && $0.kind == .foreignKey }, "\(server)")
        }
    }

    func testDatabaseWideMetadataOnEveryServer() async throws {
        for server in TestCluster.Server.allCases {
            let client = try await connect(server)
            let databases = try await client.listDatabases()
            XCTAssertTrue(Set(databases).isSuperset(of: [TestCluster.database, TestCluster.otherDatabase]), "\(server): \(databases)")
            XCTAssertFalse(databases.contains("template0"), "\(server): templates hidden")

            let extensions = try await client.listExtensions()
            XCTAssertTrue(extensions.contains { $0.name == "plpgsql" && $0.isInstalled }, "\(server)")
            let available = try await client.listAvailableExtensions()
            XCTAssertFalse(available.isEmpty, "\(server)")

            let roles = try await client.listRoles()
            let readonly = roles.first { $0.name == TestCluster.user(.readonly) }
            XCTAssertNotNil(readonly, "\(server)")
            XCTAssertEqual(readonly?.isSuperuser, false, "\(server)")
            XCTAssertEqual(readonly?.canLogin, true, "\(server)")
        }
    }

    func testObjectDefinitionsOnEveryServer() async throws {
        for server in TestCluster.Server.allCases {
            let client = try await connect(server)
            let table = try await client.getObjectDDL(schema: "qa", name: "people", type: .table)
            XCTAssertTrue(table.contains("CREATE TABLE"), "\(server): \(table)")
            XCTAssertTrue(table.contains("email"), "\(server)")

            let view = try await client.getObjectDDL(schema: "qa", name: "adults", type: .view)
            XCTAssertTrue(view.localizedCaseInsensitiveContains("select"), "\(server): \(view)")

            let function = try await client.getObjectDDL(schema: "qa", name: "add(numeric, numeric)", type: .function)
            XCTAssertTrue(function.contains("FUNCTION"), "\(server): \(function)")
            XCTAssertTrue(function.contains("numeric"), "\(server): must resolve the right overload")

            let sequence = try await client.getObjectDDL(schema: "qa", name: "ticket_seq", type: .sequence)
            XCTAssertFalse(sequence.hasPrefix("-- Error"), "\(server): \(sequence)")

            let weird = try await client.getObjectDDL(schema: "qa", name: "Weird Table", type: .table)
            XCTAssertFalse(weird.hasPrefix("-- Error"), "\(server): \(weird)")

            for object in [DBObject(schema: "qa", name: "mood", type: .type),
                           DBObject(schema: "qa", name: "mood_counts", type: .materializedView)]
            {
                let ddl = try await client.getObjectDDL(schema: object.schema, name: object.name, type: object.type)
                XCTAssertFalse(ddl.hasPrefix("-- Error"), "\(server) \(object.name): \(ddl)")
            }
        }
    }

    func testFunctionMetadataForRunSheet() async throws {
        for server in TestCluster.Server.allCases {
            let client = try await connect(server)
            let meta = try await client.getFunctionMetadata(schema: "qa", name: "add(integer, integer)")
            XCTAssertEqual(meta.parameters.count, 2, "\(server)")
        }
    }

    func testCacheIsInvalidatedAfterDDL() async throws {
        let client = try await connect()
        let schema = try await makeScratchSchema(on: client)
        let before = try await client.listTables(schema: schema)
        XCTAssertTrue(before.isEmpty)
        try await client.exec("CREATE TABLE \(quoteIdent(schema)).fresh (id int)")
        let cached = try await client.listTables(schema: schema)
        XCTAssertTrue(cached.isEmpty, "Listing is cached until invalidated")
        await client.invalidateCache()
        let after = try await client.listTables(schema: schema)
        XCTAssertEqual(after.map(\.name), ["fresh"])
    }
}

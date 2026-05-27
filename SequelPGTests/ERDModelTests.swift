import CoreGraphics
import XCTest
@testable import SequelPG

final class ERDModelTests: XCTestCase {

    // MARK: - Fixtures

    private func col(_ name: String, type: String = "int4", pk: Bool = false, nullable: Bool = true) -> ColumnInfo {
        ColumnInfo(
            name: name,
            ordinalPosition: 1,
            dataType: type,
            isNullable: nullable,
            columnDefault: nil,
            characterMaximumLength: nil,
            isPrimaryKey: pk
        )
    }

    private func table(_ name: String, schema: String = "public") -> DBObject {
        DBObject(schema: schema, name: name, type: .table)
    }

    private func fk(
        table: String,
        name: String,
        columns: [String],
        refTable: String,
        refCols: [String]
    ) -> ConstraintInfo {
        ConstraintInfo(
            schema: "public",
            table: table,
            name: name,
            kind: .foreignKey,
            definition: "FOREIGN KEY (\(columns.joined(separator: ", "))) REFERENCES \(refTable)",
            columns: columns,
            referencedTable: refTable,
            referencedColumns: refCols
        )
    }

    // MARK: - build

    func testBuildCreatesNodeForEachTable() {
        let diagram = ERDDiagram.build(
            schema: "public",
            tables: [table("users"), table("orders")],
            columnsByTable: ["users": [col("id", pk: true)], "orders": [col("id", pk: true), col("user_id")]],
            foreignKeys: []
        )
        XCTAssertEqual(Set(diagram.nodes.map(\.id)), ["public.users", "public.orders"])
        XCTAssertTrue(diagram.edges.isEmpty)
    }

    func testBuildMarksForeignKeyColumns() {
        let diagram = ERDDiagram.build(
            schema: "public",
            tables: [table("users"), table("orders")],
            columnsByTable: ["users": [col("id", pk: true)], "orders": [col("id", pk: true), col("user_id")]],
            foreignKeys: [fk(table: "orders", name: "orders_user_fk", columns: ["user_id"], refTable: "public.users", refCols: ["id"])]
        )
        let orders = try? XCTUnwrap(diagram.node(id: "public.orders"))
        XCTAssertEqual(orders?.columns.first { $0.name == "user_id" }?.isForeignKey, true)
        XCTAssertEqual(orders?.columns.first { $0.name == "id" }?.isForeignKey, false)
    }

    func testBuildCreatesManyToOneEdge() {
        let diagram = ERDDiagram.build(
            schema: "public",
            tables: [table("users"), table("orders")],
            columnsByTable: ["users": [col("id", pk: true)], "orders": [col("id", pk: true), col("user_id")]],
            foreignKeys: [fk(table: "orders", name: "orders_user_fk", columns: ["user_id"], refTable: "public.users", refCols: ["id"])]
        )
        XCTAssertEqual(diagram.edges.count, 1)
        let edge = diagram.edges[0]
        XCTAssertEqual(edge.sourceNodeID, "public.orders")
        XCTAssertEqual(edge.targetNodeID, "public.users")
        XCTAssertEqual(edge.cardinality, .manyToOne)
    }

    func testBuildDropsEdgeToTableOutsideSchema() {
        let diagram = ERDDiagram.build(
            schema: "public",
            tables: [table("orders")],
            columnsByTable: ["orders": [col("id", pk: true), col("user_id")]],
            foreignKeys: [fk(table: "orders", name: "fk", columns: ["user_id"], refTable: "auth.users", refCols: ["id"])]
        )
        XCTAssertTrue(diagram.edges.isEmpty, "Edge to a table not on the canvas should be dropped")
    }

    func testBuildDetectsOneToOneWhenForeignKeyIsPrimaryKey() {
        let diagram = ERDDiagram.build(
            schema: "public",
            tables: [table("users"), table("profiles")],
            columnsByTable: ["users": [col("id", pk: true)], "profiles": [col("user_id", pk: true)]],
            foreignKeys: [fk(table: "profiles", name: "fk", columns: ["user_id"], refTable: "public.users", refCols: ["id"])]
        )
        XCTAssertEqual(diagram.edges.first?.cardinality, .oneToOne)
    }

    func testDisplayTypeAddsCharacterLength() {
        let varcharCol = ColumnInfo(
            name: "name",
            ordinalPosition: 1,
            dataType: "character varying",
            isNullable: true,
            columnDefault: nil,
            characterMaximumLength: 255
        )
        let diagram = ERDDiagram.build(
            schema: "public",
            tables: [table("t")],
            columnsByTable: ["t": [varcharCol]],
            foreignKeys: []
        )
        XCTAssertEqual(diagram.node(id: "public.t")?.columns.first?.type, "character varying(255)")
    }

    // MARK: - ERDLayout

    func testLayoutCodableRoundTrip() throws {
        var layout = ERDLayout()
        layout.positions = ["public.users": CGPoint(x: 10, y: 20)]
        layout.collapsed = ["public.users"]
        layout.hidden = ["public.orders"]
        layout.scale = 1.5
        layout.offset = CGPoint(x: 5, y: 6)

        let data = try JSONEncoder().encode(layout)
        let decoded = try JSONDecoder().decode(ERDLayout.self, from: data)
        XCTAssertEqual(decoded, layout)
    }

    func testLayoutFromFutureVersionIsUnreadable() {
        var layout = ERDLayout()
        layout.schemaVersion = ERDLayout.currentVersion + 1
        XCTAssertFalse(layout.isReadable)
    }
}

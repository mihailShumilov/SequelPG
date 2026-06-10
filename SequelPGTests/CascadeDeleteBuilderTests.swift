import XCTest
@testable import SequelPG

final class CascadeDeleteBuilderTests: XCTestCase {
    private func builder(
        schema: String = "public",
        table: String = "orders",
        pkValues: [(column: String, value: CellValue)] = [("id", .text("42"))]
    ) -> CascadeDeleteBuilder {
        CascadeDeleteBuilder(schema: schema, table: table, pkValues: pkValues)
    }

    // MARK: - hasPrimaryKeyValues

    func testHasPrimaryKeyValuesFalseWhenEmpty() {
        XCTAssertFalse(builder(pkValues: []).hasPrimaryKeyValues)
        XCTAssertTrue(builder().hasPrimaryKeyValues)
    }

    // MARK: - foreignKeyMetadataSQL

    func testForeignKeyMetadataSQLEmbedsQuotedLiterals() {
        let sql = builder(schema: "sales", table: "orders").foreignKeyMetadataSQL
        XCTAssertTrue(sql.contains("c.relname = E'orders'"))
        XCTAssertTrue(sql.contains("n.nspname = E'sales'"))
    }

    func testForeignKeyMetadataSQLEscapesQuotesInNames() {
        let sql = builder(schema: "we'ird", table: "ta'ble").foreignKeyMetadataSQL
        XCTAssertTrue(sql.contains("'ta''ble'"))
        XCTAssertTrue(sql.contains("'we''ird'"))
    }

    // MARK: - makeDeleteSQL, no children

    func testPlainParentDeleteWhenNoChildren() {
        let sql = builder().makeDeleteSQL(from: [])
        XCTAssertEqual(sql, #"DELETE FROM "public"."orders" WHERE "id" = E'42'"#)
    }

    func testParentDeleteWithCompositePK() {
        let sql = builder(pkValues: [("a", .text("1")), ("b", .text("x"))]).makeDeleteSQL(from: [])
        XCTAssertEqual(sql, #"DELETE FROM "public"."orders" WHERE "a" = E'1' AND "b" = E'x'"#)
    }

    func testNullPKValueUsesIsNull() {
        let sql = builder(pkValues: [("id", .null)]).makeDeleteSQL(from: [])
        XCTAssertEqual(sql, #"DELETE FROM "public"."orders" WHERE "id" IS NULL"#)
    }

    func testPKValueWithQuoteIsEscaped() {
        let sql = builder(pkValues: [("name", .text("O'Brien"))]).makeDeleteSQL(from: [])
        XCTAssertEqual(sql, #"DELETE FROM "public"."orders" WHERE "name" = E'O''Brien'"#)
    }

    // MARK: - makeDeleteSQL, with children

    /// One FK metadata row: (child_schema, child_table, child_column, parent_column).
    private func fkRow(_ schema: String, _ table: String, _ childCol: String, _ parentCol: String) -> [CellValue] {
        [.text(schema), .text(table), .text(childCol), .text(parentCol)]
    }

    func testSingleChildBecomesCTE() {
        let sql = builder().makeDeleteSQL(from: [fkRow("public", "order_items", "order_id", "id")])
        XCTAssertEqual(
            sql,
            #"WITH del_child0 AS (DELETE FROM "public"."order_items" WHERE "order_id" = E'42') "#
                + #"DELETE FROM "public"."orders" WHERE "id" = E'42'"#
        )
    }

    func testCompositeForeignKeyMatchesAllColumns() {
        let sql = builder(pkValues: [("a", .text("1")), ("b", .text("2"))]).makeDeleteSQL(from: [
            fkRow("public", "child", "fa", "a"),
            fkRow("public", "child", "fb", "b"),
        ])
        XCTAssertTrue(sql.contains(#"DELETE FROM "public"."child" WHERE "fa" = E'1' AND "fb" = E'2'"#), sql)
        XCTAssertTrue(sql.hasSuffix(#"DELETE FROM "public"."orders" WHERE "a" = E'1' AND "b" = E'2'"#), sql)
    }

    func testChildSkippedWhenCompositeFKCannotBeFullyMatched() {
        // FK references parent column "other" that isn't among the PK values —
        // emitting a partial WHERE could delete unrelated rows, so the child
        // must be skipped entirely.
        let sql = builder().makeDeleteSQL(from: [fkRow("public", "child", "fk_col", "other")])
        XCTAssertEqual(sql, #"DELETE FROM "public"."orders" WHERE "id" = E'42'"#)
    }

    func testMultipleChildrenEachGetACTE() {
        let sql = builder().makeDeleteSQL(from: [
            fkRow("public", "order_items", "order_id", "id"),
            fkRow("billing", "invoices", "order_ref", "id"),
        ])
        // Dictionary grouping makes CTE order nondeterministic — assert
        // presence, not position.
        XCTAssertTrue(sql.hasPrefix("WITH del_child"), sql)
        XCTAssertTrue(sql.contains(#"DELETE FROM "public"."order_items" WHERE "order_id" = E'42'"#), sql)
        XCTAssertTrue(sql.contains(#"DELETE FROM "billing"."invoices" WHERE "order_ref" = E'42'"#), sql)
        XCTAssertTrue(sql.hasSuffix(#"DELETE FROM "public"."orders" WHERE "id" = E'42'"#), sql)
    }

    func testMalformedFKRowsAreIgnored() {
        let sql = builder().makeDeleteSQL(from: [
            [.text("public"), .text("short_row")], // too few columns
            [.null, .null, .null, .null], // non-text cells
        ])
        XCTAssertEqual(sql, #"DELETE FROM "public"."orders" WHERE "id" = E'42'"#)
    }

    func testChildIdentifiersAreQuoted() {
        let sql = builder().makeDeleteSQL(from: [fkRow("Sa les", "Chi\"ld", "ref id", "id")])
        XCTAssertTrue(sql.contains(#"DELETE FROM "Sa les"."Chi""ld" WHERE "ref id" = E'42'"#), sql)
    }
}

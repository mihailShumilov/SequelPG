import XCTest
@testable import SequelPG

final class SQLStatementSplitterTests: XCTestCase {
    private func split(_ sql: String) -> [String] {
        SQLStatementSplitter.split(sql)
    }

    func testSingleStatementWithAndWithoutSemicolon() {
        XCTAssertEqual(split("SELECT 1"), ["SELECT 1"])
        XCTAssertEqual(split("  SELECT 1;  \n"), ["SELECT 1"])
    }

    func testSplitsOnSemicolons() {
        XCTAssertEqual(split("SELECT 1; SELECT 2;SELECT 3"), ["SELECT 1", "SELECT 2", "SELECT 3"])
    }

    func testDropsEmptyAndCommentOnlyStatements() {
        XCTAssertEqual(split(";;  ; -- nothing\n/* still nothing */;"), [])
        XCTAssertEqual(split("SELECT 1;\n-- trailing comment"), ["SELECT 1"])
    }

    func testSemicolonsInLiteralsAndIdentifiersDoNotSplit() {
        XCTAssertEqual(split("SELECT 'a;b', 'it''s;'; SELECT 2"), ["SELECT 'a;b', 'it''s;'", "SELECT 2"])
        XCTAssertEqual(split(#"SELECT "we;ird" FROM "t;""x"""; SELECT 2"#), [#"SELECT "we;ird" FROM "t;""x""""#, "SELECT 2"])
        XCTAssertEqual(split(#"SELECT E'it\'s; fine'; SELECT 2"#), [#"SELECT E'it\'s; fine'"#, "SELECT 2"])
    }

    func testBackslashIsLiteralOutsideEStrings() {
        // Standard strings: a backslash doesn't escape the closing quote.
        XCTAssertEqual(split(#"SELECT 'C:\'; SELECT 2"#), [#"SELECT 'C:\'"#, "SELECT 2"])
    }

    func testCommentsDoNotSplit() {
        XCTAssertEqual(split("SELECT 1 -- x; y\n, 2; SELECT 3"), ["SELECT 1 -- x; y\n, 2", "SELECT 3"])
        XCTAssertEqual(split("SELECT /* a; /* nested; */ b; */ 1; SELECT 2"),
                       ["SELECT /* a; /* nested; */ b; */ 1", "SELECT 2"])
    }

    func testDollarQuotedBodies() {
        let fn = """
            CREATE FUNCTION f() RETURNS int LANGUAGE plpgsql AS $$
            BEGIN
                PERFORM 1;
                RETURN 2;
            END;
            $$
            """
        XCTAssertEqual(split(fn + "; SELECT f();"), [fn, "SELECT f()"])
        XCTAssertEqual(split("SELECT $tag$ a; $$ b; $tag$; SELECT 2"), ["SELECT $tag$ a; $$ b; $tag$", "SELECT 2"])
    }

    func testPositionalParametersAreNotDollarQuotes() {
        XCTAssertEqual(split("PREPARE p AS SELECT $1; SELECT 2"), ["PREPARE p AS SELECT $1", "SELECT 2"])
    }

    func testBeginAtomicBodies() {
        let proc = """
            CREATE OR REPLACE PROCEDURE p() LANGUAGE sql
            BEGIN ATOMIC
                INSERT INTO t VALUES (1);
                SELECT CASE WHEN true THEN 1 ELSE 2 END;
            END
            """
        XCTAssertEqual(split(proc + ";\nCALL p();"), [proc, "CALL p()"])
    }

    func testTransactionBlocksStillSplit() {
        XCTAssertEqual(split("BEGIN; UPDATE t SET a = 1; END;"), ["BEGIN", "UPDATE t SET a = 1", "END"])
    }

    func testUnterminatedLiteralKeepsTheRest() {
        XCTAssertEqual(split("SELECT 'oops; SELECT 2"), ["SELECT 'oops; SELECT 2"])
    }
}

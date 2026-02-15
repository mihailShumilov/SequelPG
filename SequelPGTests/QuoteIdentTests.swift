import XCTest
@testable import SequelPG

final class QuoteIdentTests: XCTestCase {

    func testSimpleIdentifier() {
        XCTAssertEqual(quoteIdent("users"), "\"users\"")
    }

    func testIdentifierWithSpaces() {
        XCTAssertEqual(quoteIdent("my table"), "\"my table\"")
    }

    func testIdentifierWithDoubleQuotes() {
        XCTAssertEqual(quoteIdent("my\"table"), "\"my\"\"table\"")
    }

    func testIdentifierWithMultipleDoubleQuotes() {
        XCTAssertEqual(quoteIdent("a\"b\"c"), "\"a\"\"b\"\"c\"")
    }

    func testEmptyIdentifier() {
        XCTAssertEqual(quoteIdent(""), "\"\"")
    }

    func testIdentifierWithSpecialCharacters() {
        XCTAssertEqual(quoteIdent("table-name.v2"), "\"table-name.v2\"")
    }

    func testIdentifierWithUnicode() {
        XCTAssertEqual(quoteIdent("таблица"), "\"таблица\"")
    }

    func testIdentifierOnlyDoubleQuotes() {
        XCTAssertEqual(quoteIdent("\""), "\"\"\"\"")
    }
}

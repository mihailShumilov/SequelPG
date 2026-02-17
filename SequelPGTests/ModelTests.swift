import XCTest
@testable import SequelPG

final class CellValueTests: XCTestCase {

    func testNullDisplayString() {
        XCTAssertEqual(CellValue.null.displayString, "NULL")
    }

    func testTextDisplayString() {
        XCTAssertEqual(CellValue.text("hello").displayString, "hello")
    }

    func testLargeTextTruncation() {
        let largeText = String(repeating: "x", count: 15_000)
        let display = CellValue.text(largeText).displayString
        XCTAssertEqual(display.count, 10_003) // 10000 + "..."
        XCTAssertTrue(display.hasSuffix("..."))
    }

    func testIsNull() {
        XCTAssertTrue(CellValue.null.isNull)
        XCTAssertFalse(CellValue.text("").isNull)
    }

    func testEquality() {
        XCTAssertEqual(CellValue.null, CellValue.null)
        XCTAssertEqual(CellValue.text("a"), CellValue.text("a"))
        XCTAssertNotEqual(CellValue.null, CellValue.text(""))
    }
}

final class AppErrorTests: XCTestCase {

    func testConnectionFailedMessage() {
        let error = AppError.connectionFailed("refused")
        XCTAssertTrue(error.userMessage.contains("Connection failed"))
        XCTAssertTrue(error.userMessage.contains("refused"))
    }

    func testQueryTimeoutMessage() {
        let error = AppError.queryTimeout
        XCTAssertTrue(error.userMessage.contains("timed out"))
    }

    func testValidationFailedMessage() {
        let error = AppError.validationFailed(["Name is required.", "Host is required."])
        let message = error.userMessage
        XCTAssertTrue(message.contains("Name is required."))
        XCTAssertTrue(message.contains("Host is required."))
    }

    func testNotConnectedMessage() {
        let error = AppError.notConnected
        XCTAssertTrue(error.userMessage.contains("Not connected"))
    }

    func testForeignKeyViolationErrorDescription() {
        let error = AppError.foreignKeyViolation("Key (id)=(1) is still referenced from table \"orders\"")
        XCTAssertEqual(
            error.errorDescription,
            "Foreign key violation: Key (id)=(1) is still referenced from table \"orders\""
        )
    }

    func testForeignKeyViolationUserMessage() {
        let error = AppError.foreignKeyViolation("referenced row")
        XCTAssertEqual(error.userMessage, "Foreign key violation: referenced row")
    }

    func testForeignKeyViolationUserMessageContainsForeignKey() {
        let error = AppError.foreignKeyViolation("detail text")
        XCTAssertTrue(error.userMessage.contains("Foreign key violation"))
        XCTAssertTrue(error.userMessage.contains("detail text"))
    }

    func testForeignKeyViolationWithEmptyMessage() {
        let error = AppError.foreignKeyViolation("")
        XCTAssertEqual(error.errorDescription, "Foreign key violation: ")
    }

    func testUnderlyingErrorMessage() {
        let error = AppError.underlying("something went wrong")
        XCTAssertEqual(error.userMessage, "something went wrong")
    }

    func testKeychainErrorMessage() {
        let error = AppError.keychainError("access denied")
        XCTAssertTrue(error.userMessage.contains("Keychain error"))
        XCTAssertTrue(error.userMessage.contains("access denied"))
    }

    func testQueryFailedMessage() {
        let error = AppError.queryFailed("syntax error")
        XCTAssertTrue(error.userMessage.contains("Query failed"))
        XCTAssertTrue(error.userMessage.contains("syntax error"))
    }
}

final class SSLModeTests: XCTestCase {

    func testAllCases() {
        XCTAssertEqual(SSLMode.allCases.count, 3)
    }

    func testDisplayNames() {
        XCTAssertEqual(SSLMode.off.displayName, "Off")
        XCTAssertEqual(SSLMode.prefer.displayName, "Prefer")
        XCTAssertEqual(SSLMode.require.displayName, "Require")
    }

    func testCodable() throws {
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        for mode in SSLMode.allCases {
            let data = try encoder.encode(mode)
            let decoded = try decoder.decode(SSLMode.self, from: data)
            XCTAssertEqual(decoded, mode)
        }
    }
}

final class DBObjectTests: XCTestCase {

    func testIdentity() {
        let obj = DBObject(schema: "public", name: "users", type: .table)
        XCTAssertEqual(obj.id, "public.users")
    }

    func testEquality() {
        let a = DBObject(schema: "public", name: "users", type: .table)
        let b = DBObject(schema: "public", name: "users", type: .table)
        XCTAssertEqual(a, b)
    }

    func testInequality() {
        let a = DBObject(schema: "public", name: "users", type: .table)
        let b = DBObject(schema: "public", name: "posts", type: .table)
        XCTAssertNotEqual(a, b)
    }
}

final class ColumnInfoTests: XCTestCase {

    func testIdentity() {
        let col = ColumnInfo(
            name: "id",
            ordinalPosition: 1,
            dataType: "integer",
            isNullable: false,
            columnDefault: nil,
            characterMaximumLength: nil
        )
        XCTAssertEqual(col.id, "1_id")
    }

    func testNullableColumn() {
        let col = ColumnInfo(
            name: "email",
            ordinalPosition: 3,
            dataType: "character varying",
            isNullable: true,
            columnDefault: nil,
            characterMaximumLength: 255
        )
        XCTAssertTrue(col.isNullable)
        XCTAssertEqual(col.characterMaximumLength, 255)
    }
}

final class QueryResultTests: XCTestCase {

    func testRowAndColumnCount() {
        let result = QueryResult(
            columns: ["a", "b"],
            rows: [[.text("1"), .text("2")], [.text("3"), .text("4")]],
            executionTime: 0.5,
            rowsAffected: nil,
            isTruncated: false
        )
        XCTAssertEqual(result.rowCount, 2)
        XCTAssertEqual(result.columnCount, 2)
    }

    func testTruncatedResult() {
        let result = QueryResult(
            columns: ["x"],
            rows: [],
            executionTime: 1.0,
            rowsAffected: nil,
            isTruncated: true
        )
        XCTAssertTrue(result.isTruncated)
    }
}

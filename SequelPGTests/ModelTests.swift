import XCTest
@testable import SequelPG

final class CellValueTests: XCTestCase {

    func testNullDisplayString() {
        XCTAssertEqual(CellValue.null.displayString, "NULL")
    }

    func testTextDisplayString() {
        XCTAssertEqual(CellValue.text("hello").displayString, "hello")
    }

    func testLargeTextDisplayString() {
        // Truncation now happens at decode time in PostgresClient, not in displayString.
        // CellValue.displayString returns the stored text as-is.
        let largeText = String(repeating: "x", count: 15_000)
        let display = CellValue.text(largeText).displayString
        XCTAssertEqual(display.count, 15_000)
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
        XCTAssertEqual(SSLMode.allCases.count, 5)
    }

    func testDisplayNames() {
        XCTAssertEqual(SSLMode.off.displayName, "Off")
        XCTAssertEqual(SSLMode.prefer.displayName, "Prefer")
        XCTAssertEqual(SSLMode.require.displayName, "Require")
        XCTAssertEqual(SSLMode.verifyCa.displayName, "Verify CA")
        XCTAssertEqual(SSLMode.verifyFull.displayName, "Verify Full")
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

final class ConnectionFailureTests: XCTestCase {

    private let hbaPrefix = #"no pg_hba.conf entry for host "10.0.0.5", user "app", database "db""#
    private var hbaNoEncryption: String { hbaPrefix + ", no encryption" }
    private var hbaSSLEncryption: String { hbaPrefix + ", SSL encryption" }

    func testSSLUnsupportedSuggestsPreferOrOff() {
        let message = ConnectionFailure.sslUnsupported.message(sslMode: .require, endpoint: "localhost:5432")
        XCTAssertTrue(message.contains("localhost:5432"))
        XCTAssertTrue(message.contains("Set SSL Mode to Prefer or Off"))
    }

    func testCertificateRejectedSuggestsRequire() {
        let message = ConnectionFailure.certificateRejected("CERTIFICATE_VERIFY_FAILED")
            .message(sslMode: .verifyFull, endpoint: "db:5432")
        XCTAssertTrue(message.contains("CERTIFICATE_VERIFY_FAILED"))
        XCTAssertTrue(message.contains("set SSL Mode to Require"))
    }

    func testHandshakeHintOnlyWhenSSLIsRequired() {
        let failure = ConnectionFailure.tlsHandshakeFailed("WRONG_VERSION_NUMBER")
        XCTAssertTrue(failure.message(sslMode: .require, endpoint: "db:5432").contains("Try SSL Mode Prefer or Off"))
        XCTAssertFalse(failure.message(sslMode: .prefer, endpoint: "db:5432").contains("Try SSL Mode"))
    }

    func testServerMessageIsShownAsIs() {
        let failure = ConnectionFailure.server(
            message: #"password authentication failed for user "dbo""#, sqlState: "28P01"
        )
        XCTAssertEqual(
            failure.message(sslMode: .prefer, endpoint: "localhost:5432"),
            #"password authentication failed for user "dbo""#
        )
    }

    func testHbaRequiringSSLSuggestsRequire() {
        let failure = ConnectionFailure.server(message: hbaNoEncryption, sqlState: "28000")
        XCTAssertTrue(failure.message(sslMode: .off, endpoint: "db:5432").contains("Set SSL Mode to Require"))
        XCTAssertFalse(failure.message(sslMode: .require, endpoint: "db:5432").contains("Set SSL Mode"))
    }

    func testHbaRejectingSSLSuggestsPreferOrOff() {
        let failure = ConnectionFailure.server(message: hbaSSLEncryption, sqlState: "28000")
        XCTAssertTrue(
            failure.message(sslMode: .verifyFull, endpoint: "db:5432").contains("Set SSL Mode to Prefer or Off")
        )
        XCTAssertFalse(failure.message(sslMode: .off, endpoint: "db:5432").contains("Set SSL Mode"))
    }

    func testUnreachableNamesEndpoint() {
        let message = ConnectionFailure.unreachable("Connection refused")
            .message(sslMode: .prefer, endpoint: "localhost:5433")
        XCTAssertTrue(message.contains("Could not reach localhost:5433 (Connection refused)"))
    }

    func testPlaintextRetryOnlyForSSLNegotiationFailures() {
        XCTAssertTrue(ConnectionFailure.certificateRejected("x").allowsPlaintextRetry)
        XCTAssertTrue(ConnectionFailure.tlsHandshakeFailed("x").allowsPlaintextRetry)
        XCTAssertTrue(ConnectionFailure.server(message: hbaSSLEncryption, sqlState: "28000").allowsPlaintextRetry)

        XCTAssertFalse(ConnectionFailure.server(message: hbaNoEncryption, sqlState: "28000").allowsPlaintextRetry)
        XCTAssertFalse(ConnectionFailure.server(message: "password authentication failed", sqlState: "28P01")
            .allowsPlaintextRetry)
        XCTAssertFalse(ConnectionFailure.sslUnsupported.allowsPlaintextRetry)
        XCTAssertFalse(ConnectionFailure.unreachable("Connection refused").allowsPlaintextRetry)
    }
}

final class DBObjectTests: XCTestCase {

    func testIdentity() {
        let obj = DBObject(schema: "public", name: "users", type: .table)
        XCTAssertEqual(obj.id, "public\0users\0table")
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

final class PostgresArrayTextTests: XCTestCase {

    // MARK: - Serialize

    func testSerializeKeepsControlCharactersRawInsideQuotes() {
        let text = serializePostgresArray([ArrayItem(value: "a\nb"), ArrayItem(value: "c\td")])
        XCTAssertEqual(text, "{\"a\nb\",\"c\td\"}")
    }

    func testSerializeEscapesBackslashAndQuote() {
        let text = serializePostgresArray([ArrayItem(value: "x\\y\"z")])
        XCTAssertEqual(text, "{\"x\\\\y\\\"z\"}")
    }

    func testSerializeQuotesStringNullAndEmitsBareNull() {
        let text = serializePostgresArray([ArrayItem(value: "NULL"), ArrayItem(value: "", isNull: true)])
        XCTAssertEqual(text, "{\"NULL\",NULL}")
    }

    // MARK: - Parse

    func testParseQuotedNullIsAString() {
        let items = parsePostgresArray("{\"NULL\",NULL,null}")
        XCTAssertEqual(items.map(\.value), ["NULL", "", ""])
        XCTAssertEqual(items.map(\.isNull), [false, true, true])
    }

    func testParseQuotedElementKeepsSurroundingSpaces() {
        let items = parsePostgresArray("{\" a \",b}")
        XCTAssertEqual(items.map(\.value), [" a ", "b"])
    }

    func testParseQuotedEmptyString() {
        let items = parsePostgresArray("{\"\",x}")
        XCTAssertEqual(items.map(\.value), ["", "x"])
        XCTAssertFalse(items[0].isNull)
    }

    func testParseIgnoresWhitespaceAroundQuotedElements() {
        let items = parsePostgresArray("{ \"a\" , b}")
        XCTAssertEqual(items.map(\.value), ["a", "b"])
    }

    func testParseEscapedQuoteAndBackslashInsideQuotes() {
        let items = parsePostgresArray("{\"a\\\"b\",\"c\\\\d\"}")
        XCTAssertEqual(items.map(\.value), ["a\"b", "c\\d"])
    }

    func testParseUnquotedNullIsCaseInsensitiveAndTrimmed() {
        let items = parsePostgresArray("{ NuLl , x }")
        XCTAssertEqual(items.map(\.isNull), [true, false])
        XCTAssertEqual(items[1].value, "x")
    }

    func testSerializeQuotesVerticalTabAndFormFeed() {
        XCTAssertEqual(serializePostgresArray([ArrayItem(value: "\u{0B}x\u{0C}")]), "{\"\u{0B}x\u{0C}\"}")
    }

    // MARK: - Round trip

    func testRoundTripPreservesTrickyValues() {
        let values = ["a\nb", "tab\there", " padded ", "NULL", "", "q\"uote", "back\\slash", "{brace}", "a,b", "\u{0C}ff"]
        let parsed = parsePostgresArray(serializePostgresArray(values.map { ArrayItem(value: $0) }))
        XCTAssertEqual(parsed.map(\.value), values)
        XCTAssertTrue(parsed.allSatisfy { !$0.isNull })
    }
}

final class ConnectionProfileDisplayNameTests: XCTestCase {

    func testDisplayNameFallsBackToUntitled() {
        XCTAssertEqual(ConnectionProfile(name: "", host: "h", port: 5432, database: "d", username: "u").displayName, "Untitled")
        XCTAssertEqual(ConnectionProfile(name: "Prod", host: "h", port: 5432, database: "d", username: "u").displayName, "Prod")
    }
}

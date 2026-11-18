import PostgresNIO
import XCTest
@testable import SequelPG

/// Timestamp rendering, command-tag parsing and the import compatibility
/// rewrite — the pure parts of query execution and transfer.
final class QueryOutputFormattingTests: XCTestCase {
    // PG epoch 2000-01-01 00:00:00 UTC; 2026-03-15 13:45:30 UTC in µs.
    private let base: Int64 = 826_897_530 * 1_000_000

    func testTimestampKeepsMicroseconds() {
        XCTAssertEqual(DatabaseClient.formatTimestamp(us: base + 123_456), "2026-03-15T13:45:30.123456Z")
        XCTAssertEqual(DatabaseClient.formatTimestamp(us: base + 1), "2026-03-15T13:45:30.000001Z")
    }

    func testTimestampWithoutSubMillisecondDigitsUsesMilliseconds() {
        XCTAssertEqual(DatabaseClient.formatTimestamp(us: base), "2026-03-15T13:45:30.000Z")
        XCTAssertEqual(DatabaseClient.formatTimestamp(us: base + 123_000), "2026-03-15T13:45:30.123Z")
    }

    func testTimestampBeforePGEpoch() {
        // 1999-12-31 23:59:59.5 UTC
        XCTAssertEqual(DatabaseClient.formatTimestamp(us: -500_000), "1999-12-31T23:59:59.500Z")
        XCTAssertEqual(DatabaseClient.formatTimestamp(us: -1), "1999-12-31T23:59:59.999999Z")
    }

    // MARK: Import compatibility

    private func rewrite(_ script: String) -> (head: String, consumed: Int)? {
        DatabaseTransferService.compatibilityRewrite(ofHead: Data(script.utf8))
            .map { (String(decoding: $0.head, as: UTF8.self), $0.consumed) }
    }

    private let preamble = """
        --
        -- PostgreSQL database dump
        --

        \\restrict abc
        SET statement_timeout = 0;
        SET lock_timeout = 0;
        SET idle_in_transaction_session_timeout = 0;
        SET transaction_timeout = 0;
        SET client_encoding = 'UTF8';
        SELECT pg_catalog.set_config('search_path', '', false);

        CREATE TABLE t (a text);

        """

    func testGuardsTransactionTimeoutInPreamble() throws {
        let result = try XCTUnwrap(rewrite(preamble))
        XCTAssertTrue(result.head.hasSuffix("""
            SET idle_in_transaction_session_timeout = 0;
            DO $sequelpg$ BEGIN IF pg_catalog.current_setting('server_version_num')::int >= 170000 \
            THEN PERFORM pg_catalog.set_config('transaction_timeout', '0', false); END IF; END $sequelpg$;

            """), result.head)
        // The rest of the script continues right after the replaced line.
        let rest = String(preamble.utf8.dropFirst(result.consumed))!
        XCTAssertTrue(rest.hasPrefix("SET client_encoding"), rest)
    }

    func testScriptsWithoutTheLineAreLeftAlone() {
        XCTAssertNil(rewrite(preamble.replacingOccurrences(of: "SET transaction_timeout = 0;\n", with: "")))
    }

    func testLineAfterThePreambleIsNotTouched() {
        // Same text as user data (e.g. in a COPY block) must never be rewritten.
        XCTAssertNil(rewrite("CREATE TABLE t (a text);\nCOPY t (a) FROM stdin;\nSET transaction_timeout = 0;\n\\.\n"))
    }
}

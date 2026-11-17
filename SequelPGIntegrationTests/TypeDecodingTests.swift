import XCTest
@testable import SequelPG

/// Cell rendering for every column type in `qa.type_samples`. Runs on every
/// server version: the binary wire formats are stable, but this is where a
/// decoder regression would show up first.
///
/// The expected strings follow psql's text output except where the app
/// deliberately renders differently (marked "app format").
final class TypeDecodingTests: IntegrationTestCase {
    /// Rendering of row id = 1 (session TimeZone = UTC).
    static let expected: [String: String] = [
        "c_bool": "true", // app format (psql: t)
        "c_int2": "-12",
        "c_int4": "123456",
        "c_int8": "9007199254740993",
        "c_numeric": "1234.5678",
        "c_float4": "1.5",
        "c_float8": "2.25",
        "c_text": "hello, world",
        "c_varchar": "varchar",
        "c_char": "abc",
        "c_bytea": "<binary>", // app format: raw bytes are not rendered
        "c_date": "2026-03-15",
        "c_time": "13:45:30",
        "c_timetz": "13:45:30+02:00", // app format (psql: +02)
        // app format: ISO 8601. Sub-millisecond digits are dropped — see
        // testTimestampKeepsMicroseconds (known issue).
        "c_ts": "2026-03-15T13:45:30.123Z",
        "c_tstz": "2026-03-15T13:45:30.000Z", // app format: ISO 8601
        "c_interval": "1 year 2 mons 3 days 04:05:06",
        "c_uuid": "A0EEBC99-9C0B-4EF8-BB6D-6BB9BD380A11", // app format: Foundation UUID casing
        "c_json": "{\"a\": 1}",
        "c_jsonb": "{\"b\": [1, 2, 3]}",
        "c_inet": "192.168.0.1/24",
        "c_cidr": "10.0.0.0/8",
        "c_macaddr": "08:00:2b:01:02:03",
        "c_int_arr": "{1,2,3}",
        "c_text_arr": "{x,\"y z\",NULL}",
        "c_int_range": "[1,10)",
        "c_ts_range": "[2026-01-01T00:00:00.000Z,2026-02-01T00:00:00.000Z)", // app format
        "c_mood": "happy",
        "c_domain": "42",
        "c_composite": "(3,4)",
        "c_money": "12.34", // app format: no currency symbol
        "c_bit": "1010",
        "c_xml": "<a>1</a>",
        "c_point": "(1.5,2.5)",
    ]

    func testEveryTypeRendersLikePsqlOnEveryServer() async throws {
        for server in TestCluster.Server.allCases {
            let client = try await connect(server)
            try await client.exec("SET TimeZone = 'UTC'")
            let result = try await client.exec("SELECT * FROM qa.type_samples WHERE id = 1")
            XCTAssertEqual(result.rowCount, 1)
            for (column, expected) in Self.expected.sorted(by: { $0.key < $1.key }) {
                let actual = result.column(column).first ?? nil
                XCTAssertEqual(actual, expected, "\(server).\(column)")
            }
        }
    }

    /// KNOWN ISSUE: timestamps go through ISO8601DateFormatter, which keeps
    /// milliseconds only — `.123456` is shown (and copied, and written back
    /// by inspector edits) as `.123`.
    func testTimestampKeepsMicroseconds() async throws {
        let client = try await connect()
        let value = try await client.scalar("SELECT c_ts FROM qa.type_samples WHERE id = 1")
        XCTExpectFailure("Known issue: timestamp rendering truncates to milliseconds") {
            XCTAssertTrue(value?.contains("123456") == true, value ?? "nil")
        }
    }

    func testNullsDecodeAsNullForEveryType() async throws {
        for server in TestCluster.Server.allCases {
            let client = try await connect(server)
            let result = try await client.exec("SELECT * FROM qa.type_samples WHERE id = 2")
            let row = try XCTUnwrap(result.rows.first)
            for (column, cell) in zip(result.columns, row) where column != "id" {
                XCTAssertEqual(cell, .null, "\(server).\(column)")
            }
        }
    }

    func testEnumDomainAndCompositeColumnsReportTheirTypes() async throws {
        let client = try await connect()
        let columns = try await client.getColumns(schema: "qa", table: "type_samples")
        let byName = Dictionary(uniqueKeysWithValues: columns.map { ($0.name, $0) })
        XCTAssertEqual(byName["c_mood"]?.udtName, "mood")
        // information_schema reports a domain column by its base type.
        XCTAssertEqual(byName["c_domain"]?.udtName, "int4")
        XCTAssertEqual(byName["c_composite"]?.udtName, "point2")
        XCTAssertEqual(byName["c_numeric"]?.numericPrecision, 12)
        XCTAssertEqual(byName["c_numeric"]?.numericScale, 4)
        XCTAssertEqual(byName["c_varchar"]?.characterMaximumLength, 20)
    }
}

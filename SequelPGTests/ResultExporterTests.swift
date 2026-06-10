import XCTest
@testable import SequelPG

final class ResultExporterTests: XCTestCase {
    // MARK: - CSV

    func testCSVSimpleRows() {
        let data = ResultExporter.csvData(
            columns: ["id", "name"],
            rows: [
                [.text("1"), .text("alice")],
                [.text("2"), .text("bob")],
            ]
        )
        XCTAssertEqual(String(data: data, encoding: .utf8), "id,name\n1,alice\n2,bob\n")
    }

    func testCSVQuotesFieldsWithCommaQuoteAndNewline() {
        let data = ResultExporter.csvData(
            columns: ["a"],
            rows: [
                [.text("has,comma")],
                [.text("has \"quote\"")],
                [.text("has\nnewline")],
            ]
        )
        XCTAssertEqual(
            String(data: data, encoding: .utf8),
            "a\n\"has,comma\"\n\"has \"\"quote\"\"\"\n\"has\nnewline\"\n"
        )
    }

    func testCSVQuotesHeaderWhenNeeded() {
        let data = ResultExporter.csvData(columns: ["weird,col"], rows: [])
        XCTAssertEqual(String(data: data, encoding: .utf8), "\"weird,col\"\n")
    }

    func testCSVNullBecomesEmptyField() {
        let data = ResultExporter.csvData(
            columns: ["a", "b", "c"],
            rows: [[.text("x"), .null, .text("z")]]
        )
        XCTAssertEqual(String(data: data, encoding: .utf8), "a,b,c\nx,,z\n")
    }

    func testCSVEmptyResultIsHeaderOnly() {
        let data = ResultExporter.csvData(columns: ["only"], rows: [])
        XCTAssertEqual(String(data: data, encoding: .utf8), "only\n")
    }

    // MARK: - JSON

    private func decode(_ data: Data) throws -> [[String: Any]] {
        let any = try JSONSerialization.jsonObject(with: data)
        return try XCTUnwrap(any as? [[String: Any]])
    }

    func testJSONRowsAreObjectsKeyedByColumn() throws {
        let data = try ResultExporter.jsonData(
            columns: ["id", "name"],
            rows: [
                [.text("1"), .text("alice")],
                [.text("2"), .text("bob")],
            ]
        )
        let objects = try decode(data)
        XCTAssertEqual(objects.count, 2)
        XCTAssertEqual(objects[0]["id"] as? String, "1")
        XCTAssertEqual(objects[0]["name"] as? String, "alice")
        XCTAssertEqual(objects[1]["name"] as? String, "bob")
    }

    func testJSONNullCellEncodesAsNull() throws {
        let data = try ResultExporter.jsonData(
            columns: ["a", "b"],
            rows: [[.null, .text("x")]]
        )
        let objects = try decode(data)
        XCTAssertEqual(objects.count, 1)
        XCTAssertTrue(objects[0]["a"] is NSNull)
        XCTAssertEqual(objects[0]["b"] as? String, "x")
    }

    func testJSONEmptyResultIsEmptyArray() throws {
        let data = try ResultExporter.jsonData(columns: ["a"], rows: [])
        XCTAssertEqual(try decode(data).count, 0)
    }

    func testJSONEscapesSpecialCharacters() throws {
        let nasty = "line1\nline2 \"quoted\" \\backslash"
        let data = try ResultExporter.jsonData(columns: ["v"], rows: [[.text(nasty)]])
        let objects = try decode(data)
        XCTAssertEqual(objects[0]["v"] as? String, nasty)
    }

    // MARK: - Duplicate column names

    func testDedupedKeysSuffixesDuplicates() {
        XCTAssertEqual(
            ResultExporter.dedupedKeys(["id", "name", "id", "id"]),
            ["id", "name", "id_2", "id_3"]
        )
    }

    func testJSONDuplicateColumnsKeepAllCells() throws {
        let data = try ResultExporter.jsonData(
            columns: ["id", "id"],
            rows: [[.text("left"), .text("right")]]
        )
        let objects = try decode(data)
        XCTAssertEqual(objects[0]["id"] as? String, "left")
        XCTAssertEqual(objects[0]["id_2"] as? String, "right")
    }

    // MARK: - Format metadata

    func testFormatFileExtensions() {
        XCTAssertEqual(ResultExportFormat.csv.fileExtension, "csv")
        XCTAssertEqual(ResultExportFormat.json.fileExtension, "json")
    }
}

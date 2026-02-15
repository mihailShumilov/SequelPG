import Foundation

/// Result of a SQL query execution.
struct QueryResult: Sendable {
    let columns: [String]
    let rows: [[CellValue]]
    let executionTime: TimeInterval
    let rowsAffected: Int?
    let isTruncated: Bool

    var rowCount: Int { rows.count }
    var columnCount: Int { columns.count }
}

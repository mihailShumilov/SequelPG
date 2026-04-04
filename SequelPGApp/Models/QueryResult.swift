import Foundation

/// Result of a SQL query execution.
struct QueryResult: Sendable {
    let columns: [String]
    var rows: [[CellValue]]
    let executionTime: TimeInterval
    let rowsAffected: Int?
    let isTruncated: Bool

    var rowCount: Int { rows.count }
    var columnCount: Int { columns.count }

    /// Returns a copy with the cell at the given position replaced.
    func replacingCell(row: Int, column: Int, with value: CellValue) -> QueryResult {
        var newRows = rows
        newRows[row][column] = value
        return QueryResult(
            columns: columns,
            rows: newRows,
            executionTime: executionTime,
            rowsAffected: rowsAffected,
            isTruncated: isTruncated
        )
    }
}

import Foundation

/// Result of a SQL query execution.
///
/// `revision` is a stable identity that's regenerated on each new result and
/// on each `replacingCell` mutation. UI code (AppKit-backed table grids,
/// caches, diffing) uses it as a cheap "have I already drawn this?" check —
/// without it, distinguishing "same result re-shown" from "same shape but
/// edited" would require hashing every cell. Existing call sites that use
/// the memberwise-style init don't need to pass `revision`; it defaults to a
/// fresh UUID on each construction.
struct QueryResult: Sendable {
    let columns: [String]
    var rows: [[CellValue]]
    let executionTime: TimeInterval
    let rowsAffected: Int?
    let isTruncated: Bool
    let revision: UUID

    init(
        columns: [String],
        rows: [[CellValue]],
        executionTime: TimeInterval,
        rowsAffected: Int?,
        isTruncated: Bool,
        revision: UUID = UUID()
    ) {
        self.columns = columns
        self.rows = rows
        self.executionTime = executionTime
        self.rowsAffected = rowsAffected
        self.isTruncated = isTruncated
        self.revision = revision
    }

    var rowCount: Int { rows.count }
    var columnCount: Int { columns.count }

    /// Returns a copy with the cell at the given position replaced. The result
    /// gets a fresh `revision` so downstream observers (the AppKit grid) can
    /// tell this apart from the pre-edit value without diffing every row.
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

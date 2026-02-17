import Foundation

/// Manages the query editor state and results.
@MainActor
final class QueryViewModel: ObservableObject {
    @Published var queryText = ""
    @Published var result: QueryResult?
    @Published var isExecuting = false
    @Published var errorMessage: String?
    @Published var showErrorDetail = false

    /// Table context detected from the last executed query (for inline editing).
    @Published var editableTableContext: (schema: String, table: String)?
    /// Column metadata for the detected table (includes PK info).
    @Published var editableColumns: [ColumnInfo] = []

    /// Row index pending delete confirmation in query results.
    @Published var deleteConfirmationRowIndex: Int?

    /// Client-side sort state for query results.
    @Published var sortColumn: String?
    @Published var sortAscending: Bool = true

    /// Returns the result rows sorted client-side when a sort column is set.
    var sortedResult: QueryResult? {
        guard let result else { return nil }
        guard let sortCol = sortColumn,
              let colIdx = result.columns.firstIndex(of: sortCol)
        else { return result }

        // Use enumerated + stable tiebreaker so the order is identical
        // to originalRowIndex() even when values compare equal.
        let sorted = result.rows.enumerated().sorted { a, b in
            let lhs = a.element[colIdx]
            let rhs = b.element[colIdx]
            if lhs.isNull && rhs.isNull { return a.offset < b.offset }
            if lhs.isNull { return !sortAscending }
            if rhs.isNull { return sortAscending }
            let cmp = lhs.displayString.localizedStandardCompare(rhs.displayString)
            if cmp == .orderedSame { return a.offset < b.offset }
            return sortAscending ? (cmp == .orderedAscending) : (cmp == .orderedDescending)
        }
        return QueryResult(
            columns: result.columns,
            rows: sorted.map(\.element),
            executionTime: result.executionTime,
            rowsAffected: result.rowsAffected,
            isTruncated: result.isTruncated
        )
    }

    /// Maps a display row index (from `sortedResult`) back to the original
    /// row index in `result`. When no client-side sort is active, returns
    /// the index unchanged.
    func originalRowIndex(_ displayIndex: Int) -> Int {
        guard let result,
              let sortCol = sortColumn,
              let colIdx = result.columns.firstIndex(of: sortCol)
        else { return displayIndex }

        let indexed = result.rows.enumerated().map { ($0.offset, $0.element) }
        // Must use the same stable tiebreaker as sortedResult so the
        // mapping is consistent even when values compare equal.
        let sorted = indexed.sorted { a, b in
            let lhs = a.1[colIdx]
            let rhs = b.1[colIdx]
            if lhs.isNull && rhs.isNull { return a.0 < b.0 }
            if lhs.isNull { return !sortAscending }
            if rhs.isNull { return sortAscending }
            let cmp = lhs.displayString.localizedStandardCompare(rhs.displayString)
            if cmp == .orderedSame { return a.0 < b.0 }
            return sortAscending ? (cmp == .orderedAscending) : (cmp == .orderedDescending)
        }

        guard displayIndex < sorted.count else { return displayIndex }
        return sorted[displayIndex].0
    }

    /// Attempts to extract a single table reference from a simple SELECT query.
    /// Returns nil for JOINs, subqueries, or queries without a FROM clause.
    func parseTableFromQuery() -> (schema: String, table: String)? {
        let trimmed = queryText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        // Reject queries with JOINs or subqueries
        let upper = trimmed.uppercased()
        if upper.contains(" JOIN ") || upper.contains("(SELECT") {
            return nil
        }

        // Match: FROM [schema.]table — supports both quoted and unquoted identifiers
        // Group 1: quoted schema, Group 2: unquoted schema
        // Group 3: quoted table, Group 4: unquoted table
        let pattern = #"(?i)\bFROM\s+(?:(?:"([^"]+)"|(\w+))\.)?(?:"([^"]+)"|(\w+))"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: trimmed, range: NSRange(trimmed.startIndex..., in: trimmed))
        else {
            return nil
        }

        // Table name: group 3 (quoted) or group 4 (unquoted)
        let table: String
        if let r = Range(match.range(at: 3), in: trimmed) {
            table = String(trimmed[r])
        } else if let r = Range(match.range(at: 4), in: trimmed) {
            table = String(trimmed[r])
        } else {
            return nil
        }

        // Schema name: group 1 (quoted) or group 2 (unquoted), default "public"
        let schema: String
        if let r = Range(match.range(at: 1), in: trimmed) {
            schema = String(trimmed[r])
        } else if let r = Range(match.range(at: 2), in: trimmed) {
            schema = String(trimmed[r])
        } else {
            schema = "public"
        }

        return (schema: schema, table: table)
    }
}

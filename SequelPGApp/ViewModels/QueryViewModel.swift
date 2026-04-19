import Foundation

/// Manages the query editor state and results.
@MainActor
@Observable final class QueryViewModel: RowDeleteConfirming {
    var queryText = ""
    var isExecuting = false
    var errorMessage: String?

    /// Table context detected from the last executed query (for inline editing).
    var editableTableContext: (schema: String, table: String)?
    /// Column metadata for the detected table (includes PK info).
    var editableColumns: [ColumnInfo] = []

    /// Row index pending delete confirmation in query results.
    var deleteConfirmationRowIndex: Int?

    /// Client-side sort state for query results.
    var sortColumn: String?
    var sortAscending: Bool = true

    var result: QueryResult?

    /// Cached sorted result, rebuilt lazily when accessed after invalidation.
    @ObservationIgnored private var _sortedResult: QueryResult?
    @ObservationIgnored private var _sortedIndexMap: [Int] = []
    @ObservationIgnored private var _sortCacheValid = false

    var sortedResult: QueryResult? {
        if !_sortCacheValid {
            rebuildSortCache()
        }
        return _sortedResult
    }

    /// Maps a display row index (from `sortedResult`) back to the original
    /// row index in `result`. O(1) lookup into the cached index map.
    func originalRowIndex(_ displayIndex: Int) -> Int {
        if !_sortCacheValid {
            rebuildSortCache()
        }
        guard displayIndex < _sortedIndexMap.count else { return displayIndex }
        return _sortedIndexMap[displayIndex]
    }

    /// Invalidates the sort cache. Call when result, sortColumn, or sortAscending change.
    func invalidateSortCache() {
        _sortCacheValid = false
    }

    private func rebuildSortCache() {
        guard let result else {
            _sortedResult = nil
            _sortedIndexMap = []
            _sortCacheValid = true
            return
        }
        guard let sortCol = sortColumn,
              let colIdx = result.columns.firstIndex(of: sortCol)
        else {
            _sortedResult = result
            _sortedIndexMap = Array(0 ..< result.rows.count)
            _sortCacheValid = true
            return
        }

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

        _sortedResult = QueryResult(
            columns: result.columns,
            rows: sorted.map(\.element),
            executionTime: result.executionTime,
            rowsAffected: result.rowsAffected,
            isTruncated: result.isTruncated
        )
        _sortedIndexMap = sorted.map(\.offset)
        _sortCacheValid = true
    }

    /// Formats the current query text using the SQL formatter.
    func beautify() {
        let formatted = SQLFormatter.format(queryText)
        if formatted != queryText {
            queryText = formatted
        }
    }

    private static let tableRefRegex: NSRegularExpression? = try? NSRegularExpression(
        pattern: #"(?i)\bFROM\s+(?:(?:"([^"]+)"|([^\s".,;()\[\]]+))\.)?(?:"([^"]+)"|([^\s".,;()\[\]]+))"#
    )

    /// Attempts to extract a single table reference from a simple SELECT query.
    /// Returns nil for JOINs, subqueries, or queries without a FROM clause.
    /// Also returns nil for CTEs (`WITH ... SELECT`), `UNION`, `UPDATE ... RETURNING`,
    /// `DELETE ... RETURNING`, and multi-table `FROM` clauses.
    func parseTableFromQuery() -> (schema: String, table: String)? {
        let trimmed = queryText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        // Reject queries with JOINs or subqueries
        let upper = trimmed.uppercased()
        if upper.contains(" JOIN ") || upper.contains("(SELECT") {
            return nil
        }

        // Match: FROM [schema.]table — supports both quoted and unquoted identifiers
        // Group 1: quoted schema, Group 2: unquoted schema (Unicode-safe)
        // Group 3: quoted table, Group 4: unquoted table (Unicode-safe)
        guard let regex = Self.tableRefRegex,
              let match = regex.firstMatch(in: trimmed, range: NSRange(trimmed.startIndex..., in: trimmed))
        else {
            return nil
        }

        guard let table = firstCaptureGroup(in: trimmed, match: match, groups: [3, 4]) else { return nil }
        let schema = firstCaptureGroup(in: trimmed, match: match, groups: [1, 2]) ?? "public"
        return (schema: schema, table: table)
    }

    /// Returns the first non-empty captured substring from the given group indices,
    /// or nil if none matched. Used by `parseTableFromQuery` to pick between the
    /// quoted (group N) / unquoted (group N+1) identifier alternatives.
    private func firstCaptureGroup(in source: String, match: NSTextCheckingResult, groups: [Int]) -> String? {
        for group in groups {
            if let range = Range(match.range(at: group), in: source) {
                return String(source[range])
            }
        }
        return nil
    }
}

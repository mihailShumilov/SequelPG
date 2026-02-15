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

        // Match: FROM [schema.]table
        let pattern = #"(?i)\bFROM\s+(?:"?(\w+)"?\.)?"?(\w+)"?"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: trimmed, range: NSRange(trimmed.startIndex..., in: trimmed))
        else {
            return nil
        }

        let tableRange = Range(match.range(at: 2), in: trimmed)!
        let table = String(trimmed[tableRange])

        let schema: String
        if let schemaRange = Range(match.range(at: 1), in: trimmed) {
            schema = String(trimmed[schemaRange])
        } else {
            schema = "public"
        }

        return (schema: schema, table: table)
    }
}

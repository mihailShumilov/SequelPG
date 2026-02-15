import Foundation

/// Quotes a PostgreSQL identifier (schema, table, column name) to prevent SQL injection.
/// Doubles any internal double-quote characters and wraps in double quotes.
func quoteIdent(_ identifier: String) -> String {
    let escaped = identifier.replacingOccurrences(of: "\"", with: "\"\"")
    return "\"\(escaped)\""
}

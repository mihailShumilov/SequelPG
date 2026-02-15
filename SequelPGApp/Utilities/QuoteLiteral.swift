import Foundation

/// Quotes a PostgreSQL string literal to prevent SQL injection.
/// Escapes single-quote characters and wraps in single quotes.
/// Returns "NULL" for null cell values.
func quoteLiteral(_ value: CellValue) -> String {
    switch value {
    case .null:
        return "NULL"
    case .text(let str):
        let escaped = str.replacingOccurrences(of: "'", with: "''")
        return "'\(escaped)'"
    }
}

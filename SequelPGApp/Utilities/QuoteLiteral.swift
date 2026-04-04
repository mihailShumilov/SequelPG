import Foundation

/// Quotes a PostgreSQL string literal to prevent SQL injection.
/// Escapes single-quote characters and wraps in single quotes.
/// Returns "NULL" for null cell values.
func quoteLiteral(_ value: CellValue) -> String {
    switch value {
    case .null:
        return "NULL"
    case .text(let str):
        let escaped = str
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "'", with: "''")
        return "E'\(escaped)'"
    }
}

/// Text-only PostgreSQL data types that don't need an explicit type cast.
private let textLikeTypes: Set<String> = [
    "text", "character varying", "varchar", "character", "char", "name",
]

/// Quotes a PostgreSQL literal with an explicit type cast for non-text columns.
/// This ensures correct implicit conversion for numeric, boolean, array, UUID,
/// and other typed columns when writing values back via DML.
func quoteLiteralTyped(_ value: CellValue, dataType: String) -> String {
    let literal = quoteLiteral(value)
    guard case .text = value else { return literal } // NULL needs no cast

    let normalizedType = dataType.lowercased().trimmingCharacters(in: .whitespaces)
    if textLikeTypes.contains(normalizedType) {
        return literal
    }
    // Append explicit cast so PostgreSQL doesn't rely on implicit coercion
    return "\(literal)::\(dataType)"
}

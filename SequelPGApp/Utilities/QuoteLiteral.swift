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
    // Validate type name to prevent injection via hostile column metadata
    guard isValidTypeName(dataType) else { return literal }
    // Append explicit cast so PostgreSQL doesn't rely on implicit coercion
    return "\(literal)::\(dataType)"
}

// MARK: - SQL Expression Validation

/// True when `haystack` contains any of `keywords` as a whole word.
/// Case-insensitive. Used to detect injection attempts that try to piggyback
/// DDL onto a DEFAULT/CHECK/function-params fragment.
private func containsDangerousKeyword(_ haystack: String, keywords: Set<String>) -> Bool {
    let lower = haystack.lowercased()
    for keyword in keywords {
        if lower.range(of: "\\b\(keyword)\\b", options: .regularExpression) != nil {
            return true
        }
    }
    return false
}

/// Validates a SQL expression field (DEFAULT value, CHECK constraint) to prevent
/// multi-statement injection. Rejects semicolons and dangerous keywords outside
/// of string context. Returns true if the expression appears safe.
func isValidSQLExpression(_ expr: String) -> Bool {
    let trimmed = expr.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return true }
    if trimmed.contains(";") { return false }
    let dangerousKeywords: Set<String> = [
        "drop", "alter", "create", "grant", "revoke", "truncate",
        "insert", "update", "delete", "exec", "execute", "copy",
    ]
    return !containsDangerousKeyword(trimmed, keywords: dangerousKeywords)
}

/// Validates a function parameters string (e.g. "p1 integer, p2 text").
/// Rejects semicolons and dangerous keywords that could inject clauses
/// like SECURITY DEFINER.
func isValidFunctionParams(_ params: String) -> Bool {
    let trimmed = params.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return true }
    if trimmed.contains(";") { return false }
    // Reject closing paren — prevents escaping the parameter list
    if trimmed.contains(")") { return false }
    let dangerousKeywords: Set<String> = [
        "security", "definer", "invoker", "drop", "alter", "create",
        "grant", "revoke", "truncate", "exec", "execute",
    ]
    return !containsDangerousKeyword(trimmed, keywords: dangerousKeywords)
}

// MARK: - Type Name Validation

/// SQL keywords that indicate injection when found as whole words in a type name.
private let dangerousTypePatterns: Set<String> = [
    "select", "insert", "update", "delete", "drop", "alter",
    "create", "grant", "revoke", "truncate", "exec",
]

/// Validates a PostgreSQL type name to prevent SQL injection.
/// Allows alphanumeric, underscores, spaces (for "character varying"), parentheses
/// (for precision like "numeric(10,2)"), commas, brackets, and dots.
/// Rejects semicolons, quotes, and SQL keywords that indicate injection.
func isValidTypeName(_ type: String) -> Bool {
    let trimmed = type.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return false }
    // Must match safe character pattern
    let safePattern = /^[a-zA-Z_][a-zA-Z0-9_ ,.()\[\]]*$/
    guard trimmed.wholeMatch(of: safePattern) != nil else { return false }
    // Must not contain dangerous SQL keywords as whole words
    let lower = trimmed.lowercased()
    for keyword in dangerousTypePatterns {
        if lower.range(of: "\\b\(keyword)\\b", options: .regularExpression) != nil { return false }
    }
    return true
}

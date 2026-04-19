import Foundation

/// Represents a single query entry in the history/log.
struct QueryHistoryEntry: Identifiable {
    let id = UUID()
    let timestamp: Date
    let sql: String
    let source: QuerySource
    let duration: TimeInterval?
    let success: Bool
    let errorMessage: String?
    let rowCount: Int?
    let isRedacted: Bool

    enum QuerySource: String {
        case manual = "Manual"
        case system = "System"
    }
}

/// Manages query history and system query log.
@MainActor
@Observable final class QueryHistoryViewModel {
    var entries: [QueryHistoryEntry] = []
    var filterSource: QueryHistoryEntry.QuerySource?

    /// When true (the default), system-generated DML queries have their string
    /// literals replaced with `***` before they are stored. Protects PII from
    /// shoulder-surfing and screenshots. Users can disable it when debugging.
    var redactSystemDMLValues: Bool = true

    private let maxEntries = 500

    var filteredEntries: [QueryHistoryEntry] {
        if let filter = filterSource {
            return entries.filter { $0.source == filter }
        }
        return entries
    }

    func logQuery(
        sql: String,
        source: QueryHistoryEntry.QuerySource,
        duration: TimeInterval? = nil,
        success: Bool = true,
        errorMessage: String? = nil,
        rowCount: Int? = nil
    ) {
        let shouldRedact = redactSystemDMLValues
            && source == .system
            && Self.isDMLQuery(sql)
        let loggedSQL = shouldRedact ? Self.redactLiterals(in: sql) : sql
        let loggedError = shouldRedact ? errorMessage.map(Self.redactLiterals) : errorMessage
        let entry = QueryHistoryEntry(
            timestamp: Date(),
            sql: loggedSQL,
            source: source,
            duration: duration,
            success: success,
            errorMessage: loggedError,
            rowCount: rowCount,
            isRedacted: shouldRedact
        )
        entries.insert(entry, at: 0)
        if entries.count > maxEntries {
            entries.removeLast(entries.count - maxEntries)
        }
    }

    func clear() {
        entries.removeAll()
    }

    /// Detects whether a SQL statement's leading keyword is INSERT/UPDATE/DELETE.
    /// Only checks the prefix — good enough to decide if literal redaction is worth applying.
    private static func isDMLQuery(_ sql: String) -> Bool {
        let trimmed = sql.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        return trimmed.hasPrefix("INSERT") || trimmed.hasPrefix("UPDATE") || trimmed.hasPrefix("DELETE")
            || trimmed.hasPrefix("WITH")  // cascade delete CTE
    }

    /// Replaces the bodies of single-quoted string literals with `***`.
    /// Understands `E'...'` escape-string syntax and doubled `''` escapes so
    /// values containing quote characters aren't split across fragments.
    static func redactLiterals(in sql: String) -> String {
        var out = ""
        out.reserveCapacity(sql.count)
        var i = sql.startIndex
        while i < sql.endIndex {
            let c = sql[i]
            if c == "'" || (c == "E" && sql.index(after: i) < sql.endIndex && sql[sql.index(after: i)] == "'") {
                // Opening quote (with optional E prefix)
                if c == "E" {
                    out.append("E")
                    i = sql.index(after: i)
                }
                out.append("'***'")
                i = sql.index(after: i)  // skip opening '
                while i < sql.endIndex {
                    let ch = sql[i]
                    if ch == "'" {
                        // Doubled '' is an embedded quote, not a terminator
                        let next = sql.index(after: i)
                        if next < sql.endIndex, sql[next] == "'" {
                            i = sql.index(after: next)
                            continue
                        }
                        i = next
                        break
                    }
                    // `E'...\''` supports backslash-escaped quote
                    if ch == "\\" {
                        let next = sql.index(after: i)
                        if next < sql.endIndex {
                            i = sql.index(after: next)
                            continue
                        }
                    }
                    i = sql.index(after: i)
                }
            } else {
                out.append(c)
                i = sql.index(after: i)
            }
        }
        return out
    }
}

import Foundation

/// Renders tool output as compact text for a language model: a pipe-separated
/// table for query results, short line lists for metadata. Output is capped
/// so one call can't flood the client's context.
enum MCPResultFormatter {
    /// Longest text returned by a single tool call.
    static let maxOutputCharacters = 100_000
    /// Longest single cell; longer values end with "…".
    static let maxCellCharacters = 1000

    static func format(_ result: QueryResult, maxRowsRequested: Int) -> String {
        let elapsed = String(format: "%.0f ms", result.executionTime * 1000)
        guard !result.columns.isEmpty else {
            if let affected = result.rowsAffected {
                return "OK, \(affected) row\(affected == 1 ? "" : "s") affected (\(elapsed))."
            }
            return "OK (\(elapsed))."
        }

        var lines = [result.columns.map(escape).joined(separator: " | ")]
        var length = lines[0].count
        var shownRows = 0
        var cutByOutputCap = false
        for row in result.rows {
            let line = row.map(render).joined(separator: " | ")
            if length + line.count + 1 > maxOutputCharacters {
                cutByOutputCap = true
                break
            }
            lines.append(line)
            length += line.count + 1
            shownRows += 1
        }

        var summary = "\(shownRows) row\(shownRows == 1 ? "" : "s") (\(elapsed))"
        if cutByOutputCap {
            summary += "; output cut at \(maxOutputCharacters) characters — narrow the query or select fewer columns"
        } else if result.isTruncated {
            summary += "; more rows exist beyond max_rows=\(maxRowsRequested) — add LIMIT/WHERE or raise max_rows"
        }
        return lines.joined(separator: "\n") + "\n\n" + summary + "."
    }

    static func render(_ value: CellValue) -> String {
        switch value {
        case .null: return "NULL"
        case let .text(text): return escape(text)
        }
    }

    /// Keeps each row on one line and the column separator unambiguous.
    static func escape(_ text: String) -> String {
        var value = text
        if value.count > maxCellCharacters {
            value = String(value.prefix(maxCellCharacters)) + "…"
        }
        return value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\r\n", with: "\\n")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\n")
            .replacingOccurrences(of: "|", with: "\\|")
    }

    /// Caps free-form text (DDL, plans) at the output limit.
    static func capped(_ text: String) -> String {
        guard text.count > maxOutputCharacters else { return text }
        return String(text.prefix(maxOutputCharacters)) + "\n… (output cut at \(maxOutputCharacters) characters)"
    }
}

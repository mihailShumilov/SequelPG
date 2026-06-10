import Foundation
import UniformTypeIdentifiers

/// File formats the result grid can be exported to.
enum ResultExportFormat: String, CaseIterable, Identifiable {
    case csv
    case json

    var id: String { rawValue }

    var label: String {
        switch self {
        case .csv: return "CSV"
        case .json: return "JSON"
        }
    }

    var fileExtension: String { rawValue }

    var contentType: UTType {
        switch self {
        case .csv: return .commaSeparatedText
        case .json: return .json
        }
    }
}

/// Serializes a result grid (column names + `CellValue` rows) to CSV or JSON.
/// Pure functions over in-memory data — file I/O stays with the caller.
enum ResultExporter {
    static func data(columns: [String], rows: [[CellValue]], format: ResultExportFormat) throws -> Data {
        switch format {
        case .csv: return csvData(columns: columns, rows: rows)
        case .json: return try jsonData(columns: columns, rows: rows)
        }
    }

    // MARK: - CSV

    /// RFC 4180-style CSV: header row, LF line endings, fields quoted when
    /// they contain a comma, quote, or newline. NULL becomes an empty field —
    /// indistinguishable from the empty string, which is the conventional
    /// CSV trade-off.
    static func csvData(columns: [String], rows: [[CellValue]]) -> Data {
        var out = columns.map(csvField).joined(separator: ",")
        out += "\n"
        for row in rows {
            let fields = row.map { cell -> String in
                switch cell {
                case .null: return ""
                case let .text(value): return csvField(value)
                }
            }
            out += fields.joined(separator: ",")
            out += "\n"
        }
        return Data(out.utf8)
    }

    private static func csvField(_ value: String) -> String {
        guard value.contains(where: { $0 == "," || $0 == "\"" || $0 == "\n" || $0 == "\r" }) else {
            return value
        }
        return "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    // MARK: - JSON

    /// Array of objects keyed by column name; NULL cells encode as JSON null.
    /// All values are strings — the wire data is already stringly typed by the
    /// time it reaches `CellValue`. Duplicate column names (e.g. a join
    /// selecting two `id`s) get `_2`, `_3`… suffixes so no cell is lost.
    static func jsonData(columns: [String], rows: [[CellValue]]) throws -> Data {
        let keys = dedupedKeys(columns)
        let objects = rows.map { row in
            JSONRow(pairs: Array(zip(keys, row)))
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
        return try encoder.encode(objects)
    }

    static func dedupedKeys(_ columns: [String]) -> [String] {
        var seen: [String: Int] = [:]
        return columns.map { name in
            let count = (seen[name] ?? 0) + 1
            seen[name] = count
            return count == 1 ? name : "\(name)_\(count)"
        }
    }

    /// Encodes one row as a JSON object with per-row dynamic keys.
    private struct JSONRow: Encodable {
        let pairs: [(String, CellValue)]

        struct Key: CodingKey {
            var stringValue: String
            var intValue: Int? { nil }
            init(stringValue: String) { self.stringValue = stringValue }
            init?(intValue _: Int) { nil }
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: Key.self)
            for (name, cell) in pairs {
                let key = Key(stringValue: name)
                switch cell {
                case .null: try container.encodeNil(forKey: key)
                case let .text(value): try container.encode(value, forKey: key)
                }
            }
        }
    }
}

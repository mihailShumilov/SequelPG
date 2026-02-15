import Foundation

/// Represents a single cell value from a query result.
enum CellValue: Sendable, Equatable {
    case null
    case text(String)

    var displayString: String {
        switch self {
        case .null:
            return "NULL"
        case let .text(value):
            // Truncate large text values for UI display
            if value.count > 10_000 {
                return String(value.prefix(10_000)) + "..."
            }
            return value
        }
    }

    var isNull: Bool {
        if case .null = self { return true }
        return false
    }
}

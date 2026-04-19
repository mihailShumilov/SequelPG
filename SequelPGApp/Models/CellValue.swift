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
            return value
        }
    }

    var isNull: Bool {
        switch self {
        case .null: return true
        case .text: return false
        }
    }
}

import Foundation

/// A single filter condition for the content tab.
struct ContentFilter: Identifiable {
    let id = UUID()
    var column: String = ""    // empty = "Any Column"
    var op: FilterOperator = .contains
    var value: String = ""
}

/// Filter comparison operators.
enum FilterOperator: String, CaseIterable {
    case contains = "contains"
    case equals = "equals"
    case notEquals = "not equals"
    case greaterThan = "greater than"
    case lessThan = "less than"
    case greaterOrEqual = ">="
    case lessOrEqual = "<="
    case startsWith = "starts with"
    case endsWith = "ends with"
    case isNull = "is null"
    case isNotNull = "is not null"

    /// Whether this operator needs a value text field.
    var needsValue: Bool {
        switch self {
        case .isNull, .isNotNull: return false
        default: return true
        }
    }
}

/// Manages structure and content tab state for a selected table/view.
@MainActor
@Observable final class TableViewModel {
    var columns: [ColumnInfo] = []
    var contentResult: QueryResult?
    var isLoadingContent = false
    var currentPage = 0
    var pageSize = 50
    var approximateRowCount: Int64 = 0
    var selectedObjectName: String?
    var selectedObjectColumnCount = 0
    var selectedRowIndex: Int?
    var selectedRowData: [(column: String, value: CellValue)]?
    var sortColumn: String?
    var sortAscending: Bool = true
    var deleteConfirmationRowIndex: Int?
    var isInsertingRow = false
    var newRowValues: [String: String] = [:]

    // Filter state
    var showFilterBar = false
    var filters: [ContentFilter] = [ContentFilter()]
    var activeFilterSQL: String?

    var totalPages: Int {
        guard pageSize > 0 else { return 0 }
        return max(1, Int(ceil(Double(approximateRowCount) / Double(pageSize))))
    }

    var pageSizeOptions: [Int] { [50, 100, 200] }

    /// Whether any column is a primary key (cached on setColumns).
    private(set) var hasPrimaryKey = false

    func setColumns(_ cols: [ColumnInfo]) {
        columns = cols
        hasPrimaryKey = cols.contains { $0.isPrimaryKey }
    }

    func setContentResult(_ result: QueryResult) {
        contentResult = result
    }

    func clear() {
        columns = []
        contentResult = nil
        isLoadingContent = false
        currentPage = 0
        approximateRowCount = 0
        selectedObjectName = nil
        selectedObjectColumnCount = 0
        selectedRowIndex = nil
        selectedRowData = nil
        sortColumn = nil
        sortAscending = true
        deleteConfirmationRowIndex = nil
        isInsertingRow = false
        newRowValues = [:]
        showFilterBar = false
        filters = [ContentFilter()]
        activeFilterSQL = nil
    }
}

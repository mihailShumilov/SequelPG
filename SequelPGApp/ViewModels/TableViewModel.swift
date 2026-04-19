import Foundation

/// Adopted by every view model that surfaces a per-row delete confirmation prompt.
/// The shared property keeps both content-tab and query-tab views using the same
/// binding shape: setting an `Int?` opens the confirmation alert; nil dismisses it.
@MainActor
protocol RowDeleteConfirming: AnyObject {
    var deleteConfirmationRowIndex: Int? { get set }
}

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
@Observable final class TableViewModel: RowDeleteConfirming {
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

    // Per-table metadata populated alongside columns on object selection.
    var indexes: [IndexInfo] = []
    var constraints: [ConstraintInfo] = []
    var triggers: [TriggerInfo] = []
    var partitions: [DBObject] = []

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

    /// Resets every field back to its default. Written as a transactional
    /// reset so observers (SwiftUI views) redraw at most once per call even
    /// though @Observable coalesces most mutations on the same run loop.
    func clear() {
        let defaults = TableViewModel.defaults
        columns = defaults.columns
        contentResult = defaults.contentResult
        isLoadingContent = defaults.isLoadingContent
        currentPage = defaults.currentPage
        approximateRowCount = defaults.approximateRowCount
        selectedObjectName = defaults.selectedObjectName
        selectedObjectColumnCount = defaults.selectedObjectColumnCount
        selectedRowIndex = defaults.selectedRowIndex
        selectedRowData = defaults.selectedRowData
        sortColumn = defaults.sortColumn
        sortAscending = defaults.sortAscending
        deleteConfirmationRowIndex = defaults.deleteConfirmationRowIndex
        isInsertingRow = defaults.isInsertingRow
        newRowValues = defaults.newRowValues
        showFilterBar = defaults.showFilterBar
        filters = [ContentFilter()]
        activeFilterSQL = defaults.activeFilterSQL
        indexes = []
        constraints = []
        triggers = []
        partitions = []
        hasPrimaryKey = false
    }

    /// Canonical "empty" defaults. Centralizing them keeps `clear()` and the
    /// stored-property defaults from drifting apart.
    private struct Defaults {
        let columns: [ColumnInfo] = []
        let contentResult: QueryResult? = nil
        let isLoadingContent = false
        let currentPage = 0
        let approximateRowCount: Int64 = 0
        let selectedObjectName: String? = nil
        let selectedObjectColumnCount = 0
        let selectedRowIndex: Int? = nil
        let selectedRowData: [(column: String, value: CellValue)]? = nil
        let sortColumn: String? = nil
        let sortAscending = true
        let deleteConfirmationRowIndex: Int? = nil
        let isInsertingRow = false
        let newRowValues: [String: String] = [:]
        let showFilterBar = false
        let activeFilterSQL: String? = nil
    }

    private static let defaults = Defaults()
}

import Foundation

/// Manages structure and content tab state for a selected table/view.
@MainActor
final class TableViewModel: ObservableObject {
    @Published var columns: [ColumnInfo] = []
    @Published var contentResult: QueryResult?
    @Published var isLoadingContent = false
    @Published var currentPage = 0
    @Published var pageSize = 50
    @Published var approximateRowCount: Int64 = 0
    @Published var selectedObjectName: String?
    @Published var selectedObjectColumnCount = 0
    @Published var selectedRowIndex: Int?
    @Published var selectedRowData: [(column: String, value: CellValue)]?
    @Published var sortColumn: String?
    @Published var sortAscending: Bool = true
    @Published var deleteConfirmationRowIndex: Int?
    @Published var isInsertingRow = false
    @Published var newRowValues: [String: String] = [:]

    var totalPages: Int {
        guard pageSize > 0 else { return 0 }
        return max(1, Int(ceil(Double(approximateRowCount) / Double(pageSize))))
    }

    var pageSizeOptions: [Int] { [50, 100, 200] }

    func setColumns(_ cols: [ColumnInfo]) {
        columns = cols
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
    }
}

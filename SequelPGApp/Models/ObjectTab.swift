import Foundation

/// One opened object in the per-object tab strip above the main area. Holds
/// the per-tab snapshot of state that would otherwise be erased when the user
/// switches to a different object: page, sort, filters, the most recent
/// content result, and per-table metadata (columns, indexes, constraints, …).
///
/// `TableViewModel` always reflects the *active* tab; switching tabs writes the
/// current `TableViewModel` state into this snapshot for the outgoing tab and
/// then rehydrates `TableViewModel` from the incoming tab.
struct ObjectTab: Identifiable, Equatable {
    let id: UUID
    var dbObject: DBObject
    var contentResult: QueryResult?
    var columns: [ColumnInfo]
    var constraints: [ConstraintInfo]
    var indexes: [IndexInfo]
    var triggers: [TriggerInfo]
    var partitions: [DBObject]
    var currentPage: Int
    var pageSize: Int
    var approximateRowCount: Int64
    var sortColumn: String?
    var sortAscending: Bool
    var filters: [ContentFilter]
    var activeFilterSQL: String?
    var selectedRowIndex: Int?
    var showFilterBar: Bool

    init(dbObject: DBObject, pageSize: Int = 50) {
        self.id = UUID()
        self.dbObject = dbObject
        self.contentResult = nil
        self.columns = []
        self.constraints = []
        self.indexes = []
        self.triggers = []
        self.partitions = []
        self.currentPage = 0
        self.pageSize = pageSize
        self.approximateRowCount = 0
        self.sortColumn = nil
        self.sortAscending = true
        self.filters = [ContentFilter()]
        self.activeFilterSQL = nil
        self.selectedRowIndex = nil
        self.showFilterBar = false
    }

    static func == (lhs: ObjectTab, rhs: ObjectTab) -> Bool {
        lhs.id == rhs.id
    }
}

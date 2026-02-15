import XCTest
@testable import SequelPG

@MainActor
final class TableViewModelTests: XCTestCase {

    private var sut: TableViewModel!

    override func setUp() {
        super.setUp()
        sut = TableViewModel()
    }

    override func tearDown() {
        sut = nil
        super.tearDown()
    }

    // MARK: - Initial State

    func testInitialColumnsIsEmpty() {
        XCTAssertTrue(sut.columns.isEmpty)
    }

    func testInitialContentResultIsNil() {
        XCTAssertNil(sut.contentResult)
    }

    func testInitialIsLoadingContentIsFalse() {
        XCTAssertFalse(sut.isLoadingContent)
    }

    func testInitialCurrentPageIsZero() {
        XCTAssertEqual(sut.currentPage, 0)
    }

    func testInitialPageSizeIsFifty() {
        XCTAssertEqual(sut.pageSize, 50)
    }

    func testInitialApproximateRowCountIsZero() {
        XCTAssertEqual(sut.approximateRowCount, 0)
    }

    func testInitialSelectedObjectNameIsNil() {
        XCTAssertNil(sut.selectedObjectName)
    }

    func testInitialSelectedObjectColumnCountIsZero() {
        XCTAssertEqual(sut.selectedObjectColumnCount, 0)
    }

    // MARK: - totalPages (computed property)
    // Tests the pagination calculation: ceil(approximateRowCount / pageSize), minimum 1.
    // Special case: returns 0 when pageSize is 0 (guard clause).

    func testTotalPagesReturnsOneWhenRowCountIsZero() {
        sut.approximateRowCount = 0
        sut.pageSize = 50
        XCTAssertEqual(sut.totalPages, 1)
    }

    func testTotalPagesReturnsOneWhenRowsFitInOnePage() {
        sut.approximateRowCount = 50
        sut.pageSize = 50
        XCTAssertEqual(sut.totalPages, 1)
    }

    func testTotalPagesRoundsUpForPartialPage() {
        sut.approximateRowCount = 51
        sut.pageSize = 50
        XCTAssertEqual(sut.totalPages, 2)
    }

    func testTotalPagesExactMultiple() {
        sut.approximateRowCount = 100
        sut.pageSize = 50
        XCTAssertEqual(sut.totalPages, 2)
    }

    func testTotalPagesLargeRowCount() {
        sut.approximateRowCount = 10_001
        sut.pageSize = 100
        XCTAssertEqual(sut.totalPages, 101)
    }

    func testTotalPagesWithPageSizeOne() {
        sut.approximateRowCount = 5
        sut.pageSize = 1
        XCTAssertEqual(sut.totalPages, 5)
    }

    func testTotalPagesReturnsZeroWhenPageSizeIsZero() {
        sut.pageSize = 0
        sut.approximateRowCount = 100
        XCTAssertEqual(sut.totalPages, 0)
    }

    func testTotalPagesWithSingleRow() {
        sut.approximateRowCount = 1
        sut.pageSize = 50
        XCTAssertEqual(sut.totalPages, 1)
    }

    func testTotalPagesWithPageSizeLargerThanRowCount() {
        sut.approximateRowCount = 10
        sut.pageSize = 200
        XCTAssertEqual(sut.totalPages, 1)
    }

    func testTotalPagesWithPageSize200() {
        sut.approximateRowCount = 401
        sut.pageSize = 200
        XCTAssertEqual(sut.totalPages, 3)
    }

    // MARK: - pageSizeOptions (computed property)

    func testPageSizeOptionsContainsExpectedValues() {
        XCTAssertEqual(sut.pageSizeOptions, [50, 100, 200])
    }

    func testPageSizeOptionsHasThreeEntries() {
        XCTAssertEqual(sut.pageSizeOptions.count, 3)
    }

    // MARK: - setColumns(_:)

    func testSetColumnsStoresColumns() {
        let cols = makeColumns(count: 3)
        sut.setColumns(cols)
        XCTAssertEqual(sut.columns.count, 3)
        XCTAssertEqual(sut.columns[0].name, "col_0")
        XCTAssertEqual(sut.columns[1].name, "col_1")
        XCTAssertEqual(sut.columns[2].name, "col_2")
    }

    func testSetColumnsWithEmptyArray() {
        sut.setColumns(makeColumns(count: 2))
        XCTAssertEqual(sut.columns.count, 2)

        sut.setColumns([])
        XCTAssertTrue(sut.columns.isEmpty)
    }

    func testSetColumnsReplacesExistingColumns() {
        sut.setColumns(makeColumns(count: 5))
        XCTAssertEqual(sut.columns.count, 5)

        let newCols = [makeColumn(name: "replaced", position: 1)]
        sut.setColumns(newCols)
        XCTAssertEqual(sut.columns.count, 1)
        XCTAssertEqual(sut.columns.first?.name, "replaced")
    }

    func testSetColumnsSingleColumn() {
        let col = makeColumn(name: "only", position: 1)
        sut.setColumns([col])
        XCTAssertEqual(sut.columns.count, 1)
        XCTAssertEqual(sut.columns.first?.name, "only")
    }

    // MARK: - setContentResult(_:)

    func testSetContentResultStoresResult() {
        let result = makeQueryResult(columns: ["a", "b"], rowCount: 2)
        sut.setContentResult(result)

        XCTAssertNotNil(sut.contentResult)
        XCTAssertEqual(sut.contentResult?.columnCount, 2)
        XCTAssertEqual(sut.contentResult?.rowCount, 2)
    }

    func testSetContentResultWithEmptyResult() {
        let result = makeQueryResult(columns: [], rowCount: 0)
        sut.setContentResult(result)

        XCTAssertNotNil(sut.contentResult)
        XCTAssertEqual(sut.contentResult?.rowCount, 0)
        XCTAssertEqual(sut.contentResult?.columnCount, 0)
    }

    func testSetContentResultReplacesExistingResult() {
        let first = makeQueryResult(columns: ["x"], rowCount: 1)
        sut.setContentResult(first)
        XCTAssertEqual(sut.contentResult?.columnCount, 1)

        let second = makeQueryResult(columns: ["a", "b", "c"], rowCount: 5)
        sut.setContentResult(second)
        XCTAssertEqual(sut.contentResult?.columnCount, 3)
        XCTAssertEqual(sut.contentResult?.rowCount, 5)
    }

    func testSetContentResultPreservesExecutionTime() {
        let result = QueryResult(
            columns: ["id"],
            rows: [[.text("1")]],
            executionTime: 1.234,
            rowsAffected: nil,
            isTruncated: false
        )
        sut.setContentResult(result)
        XCTAssertEqual(sut.contentResult?.executionTime, 1.234)
    }

    func testSetContentResultPreservesTruncatedFlag() {
        let result = QueryResult(
            columns: ["id"],
            rows: [],
            executionTime: 0.1,
            rowsAffected: nil,
            isTruncated: true
        )
        sut.setContentResult(result)
        XCTAssertEqual(sut.contentResult?.isTruncated, true)
    }

    // MARK: - clear()

    func testClearResetsColumnsToEmpty() {
        sut.setColumns(makeColumns(count: 3))
        sut.clear()
        XCTAssertTrue(sut.columns.isEmpty)
    }

    func testClearResetsContentResultToNil() {
        sut.setContentResult(makeQueryResult(columns: ["a"], rowCount: 1))
        sut.clear()
        XCTAssertNil(sut.contentResult)
    }

    func testClearResetsIsLoadingContentToFalse() {
        sut.isLoadingContent = true
        sut.clear()
        XCTAssertFalse(sut.isLoadingContent)
    }

    func testClearResetsCurrentPageToZero() {
        sut.currentPage = 5
        sut.clear()
        XCTAssertEqual(sut.currentPage, 0)
    }

    func testClearResetsApproximateRowCountToZero() {
        sut.approximateRowCount = 1000
        sut.clear()
        XCTAssertEqual(sut.approximateRowCount, 0)
    }

    func testClearResetsSelectedObjectNameToNil() {
        sut.selectedObjectName = "users"
        sut.clear()
        XCTAssertNil(sut.selectedObjectName)
    }

    func testClearResetsSelectedObjectColumnCountToZero() {
        sut.selectedObjectColumnCount = 10
        sut.clear()
        XCTAssertEqual(sut.selectedObjectColumnCount, 0)
    }

    func testClearResetsAllFieldsAtOnce() {
        // Set every field to a non-default value
        sut.setColumns(makeColumns(count: 2))
        sut.setContentResult(makeQueryResult(columns: ["a"], rowCount: 1))
        sut.isLoadingContent = true
        sut.currentPage = 3
        sut.approximateRowCount = 500
        sut.selectedObjectName = "orders"
        sut.selectedObjectColumnCount = 7

        sut.clear()

        XCTAssertTrue(sut.columns.isEmpty)
        XCTAssertNil(sut.contentResult)
        XCTAssertFalse(sut.isLoadingContent)
        XCTAssertEqual(sut.currentPage, 0)
        XCTAssertEqual(sut.approximateRowCount, 0)
        XCTAssertNil(sut.selectedObjectName)
        XCTAssertEqual(sut.selectedObjectColumnCount, 0)
    }

    func testClearDoesNotChangePageSize() {
        sut.pageSize = 100
        sut.clear()
        XCTAssertEqual(sut.pageSize, 100)
    }

    func testClearIsIdempotent() {
        sut.clear()
        sut.clear()

        XCTAssertTrue(sut.columns.isEmpty)
        XCTAssertNil(sut.contentResult)
        XCTAssertFalse(sut.isLoadingContent)
        XCTAssertEqual(sut.currentPage, 0)
        XCTAssertEqual(sut.approximateRowCount, 0)
        XCTAssertNil(sut.selectedObjectName)
        XCTAssertEqual(sut.selectedObjectColumnCount, 0)
    }

    // MARK: - @Published property mutation

    func testPageSizeCanBeSetToAnyValue() {
        sut.pageSize = 200
        XCTAssertEqual(sut.pageSize, 200)
    }

    func testCurrentPageCanBeSet() {
        sut.currentPage = 10
        XCTAssertEqual(sut.currentPage, 10)
    }

    func testApproximateRowCountCanBeSet() {
        sut.approximateRowCount = 999_999
        XCTAssertEqual(sut.approximateRowCount, 999_999)
    }

    func testSelectedObjectNameCanBeSet() {
        sut.selectedObjectName = "my_table"
        XCTAssertEqual(sut.selectedObjectName, "my_table")
    }

    func testSelectedObjectColumnCountCanBeSet() {
        sut.selectedObjectColumnCount = 42
        XCTAssertEqual(sut.selectedObjectColumnCount, 42)
    }

    func testIsLoadingContentCanBeSet() {
        sut.isLoadingContent = true
        XCTAssertTrue(sut.isLoadingContent)
    }

    // MARK: - totalPages reacts to property changes

    func testTotalPagesUpdatesWhenPageSizeChanges() {
        sut.approximateRowCount = 200
        sut.pageSize = 50
        XCTAssertEqual(sut.totalPages, 4)

        sut.pageSize = 100
        XCTAssertEqual(sut.totalPages, 2)

        sut.pageSize = 200
        XCTAssertEqual(sut.totalPages, 1)
    }

    func testTotalPagesUpdatesWhenRowCountChanges() {
        sut.pageSize = 50

        sut.approximateRowCount = 0
        XCTAssertEqual(sut.totalPages, 1)

        sut.approximateRowCount = 49
        XCTAssertEqual(sut.totalPages, 1)

        sut.approximateRowCount = 50
        XCTAssertEqual(sut.totalPages, 1)

        sut.approximateRowCount = 51
        XCTAssertEqual(sut.totalPages, 2)

        sut.approximateRowCount = 100
        XCTAssertEqual(sut.totalPages, 2)

        sut.approximateRowCount = 101
        XCTAssertEqual(sut.totalPages, 3)
    }

    // MARK: - Helpers

    private func makeColumn(name: String, position: Int) -> ColumnInfo {
        ColumnInfo(
            name: name,
            ordinalPosition: position,
            dataType: "text",
            isNullable: true,
            columnDefault: nil,
            characterMaximumLength: nil
        )
    }

    private func makeColumns(count: Int) -> [ColumnInfo] {
        (0..<count).map { i in
            makeColumn(name: "col_\(i)", position: i + 1)
        }
    }

    private func makeQueryResult(columns: [String], rowCount: Int) -> QueryResult {
        let rows: [[CellValue]] = (0..<rowCount).map { _ in
            columns.map { _ in .text("value") }
        }
        return QueryResult(
            columns: columns,
            rows: rows,
            executionTime: 0.01,
            rowsAffected: nil,
            isTruncated: false
        )
    }
}

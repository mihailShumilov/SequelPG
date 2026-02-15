import Combine
import XCTest
@testable import SequelPG

@MainActor
final class QueryViewModelTests: XCTestCase {

    private var vm: QueryViewModel!

    override func setUp() {
        super.setUp()
        vm = QueryViewModel()
    }

    override func tearDown() {
        vm = nil
        super.tearDown()
    }

    // MARK: - Initial State

    func testInitialQueryTextIsEmpty() {
        XCTAssertEqual(vm.queryText, "")
    }

    func testInitialResultIsNil() {
        XCTAssertNil(vm.result)
    }

    func testInitialIsExecutingIsFalse() {
        XCTAssertFalse(vm.isExecuting)
    }

    func testInitialErrorMessageIsNil() {
        XCTAssertNil(vm.errorMessage)
    }

    func testInitialShowErrorDetailIsFalse() {
        XCTAssertFalse(vm.showErrorDetail)
    }

    // MARK: - queryText

    func testSetQueryText() {
        vm.queryText = "SELECT 1"
        XCTAssertEqual(vm.queryText, "SELECT 1")
    }

    func testSetQueryTextToMultilineSQL() {
        let sql = """
        SELECT *
        FROM users
        WHERE active = true
        ORDER BY created_at DESC
        """
        vm.queryText = sql
        XCTAssertEqual(vm.queryText, sql)
    }

    func testSetQueryTextToEmptyString() {
        vm.queryText = "SELECT 1"
        vm.queryText = ""
        XCTAssertEqual(vm.queryText, "")
    }

    func testSetQueryTextWithUnicode() {
        let sql = "SELECT * FROM \"таблица\" WHERE name = 'cafe'"
        vm.queryText = sql
        XCTAssertEqual(vm.queryText, sql)
    }

    func testSetQueryTextWithSpecialCharacters() {
        let sql = "SELECT '\\n', E'\\t', $$dollar$$"
        vm.queryText = sql
        XCTAssertEqual(vm.queryText, sql)
    }

    // MARK: - result

    func testSetResult() {
        let result = makeQueryResult(columns: ["id"], rows: [[.text("1")]])
        vm.result = result
        XCTAssertNotNil(vm.result)
        XCTAssertEqual(vm.result?.columnCount, 1)
        XCTAssertEqual(vm.result?.rowCount, 1)
    }

    func testClearResult() {
        vm.result = makeQueryResult(columns: ["id"], rows: [[.text("1")]])
        vm.result = nil
        XCTAssertNil(vm.result)
    }

    func testSetResultWithEmptyColumnsAndRows() {
        let result = makeQueryResult(columns: [], rows: [])
        vm.result = result
        XCTAssertNotNil(vm.result)
        XCTAssertEqual(vm.result?.rowCount, 0)
        XCTAssertEqual(vm.result?.columnCount, 0)
    }

    func testSetResultWithMultipleColumnsAndRows() {
        let result = makeQueryResult(
            columns: ["id", "name", "email"],
            rows: [
                [.text("1"), .text("Alice"), .text("alice@example.com")],
                [.text("2"), .text("Bob"), .null],
            ]
        )
        vm.result = result
        XCTAssertEqual(vm.result?.columnCount, 3)
        XCTAssertEqual(vm.result?.rowCount, 2)
    }

    func testSetResultWithTruncatedFlag() {
        let result = QueryResult(
            columns: ["x"],
            rows: [[.text("1")]],
            executionTime: 0.1,
            rowsAffected: nil,
            isTruncated: true
        )
        vm.result = result
        XCTAssertTrue(vm.result?.isTruncated == true)
    }

    func testSetResultWithRowsAffected() {
        let result = QueryResult(
            columns: [],
            rows: [],
            executionTime: 0.05,
            rowsAffected: 42,
            isTruncated: false
        )
        vm.result = result
        XCTAssertEqual(vm.result?.rowsAffected, 42)
    }

    func testSetResultPreservesExecutionTime() {
        let result = makeQueryResult(
            columns: ["a"],
            rows: [[.text("x")]],
            executionTime: 3.14
        )
        vm.result = result
        XCTAssertEqual(vm.result?.executionTime ?? 0, 3.14, accuracy: 0.001)
    }

    func testReplaceResultWithNewResult() {
        let first = makeQueryResult(columns: ["a"], rows: [[.text("1")]])
        let second = makeQueryResult(columns: ["b", "c"], rows: [[.text("2"), .text("3")]])
        vm.result = first
        XCTAssertEqual(vm.result?.columnCount, 1)

        vm.result = second
        XCTAssertEqual(vm.result?.columnCount, 2)
        XCTAssertEqual(vm.result?.rowCount, 1)
    }

    // MARK: - isExecuting

    func testSetIsExecutingToTrue() {
        vm.isExecuting = true
        XCTAssertTrue(vm.isExecuting)
    }

    func testSetIsExecutingToFalse() {
        vm.isExecuting = true
        vm.isExecuting = false
        XCTAssertFalse(vm.isExecuting)
    }

    // MARK: - errorMessage

    func testSetErrorMessage() {
        vm.errorMessage = "Connection refused"
        XCTAssertEqual(vm.errorMessage, "Connection refused")
    }

    func testClearErrorMessage() {
        vm.errorMessage = "Some error"
        vm.errorMessage = nil
        XCTAssertNil(vm.errorMessage)
    }

    func testSetEmptyErrorMessage() {
        vm.errorMessage = ""
        XCTAssertEqual(vm.errorMessage, "")
    }

    func testSetLongErrorMessage() {
        let longMessage = String(repeating: "Error occurred. ", count: 500)
        vm.errorMessage = longMessage
        XCTAssertEqual(vm.errorMessage, longMessage)
    }

    // MARK: - showErrorDetail

    func testSetShowErrorDetailToTrue() {
        vm.showErrorDetail = true
        XCTAssertTrue(vm.showErrorDetail)
    }

    func testSetShowErrorDetailToFalse() {
        vm.showErrorDetail = true
        vm.showErrorDetail = false
        XCTAssertFalse(vm.showErrorDetail)
    }

    // MARK: - State Management (Simulating Query Execution Workflow)

    /// Tests the state transitions that occur during a successful query execution,
    /// mirroring the pattern used in AppViewModel.executeQuery.
    func testSuccessfulQueryExecutionWorkflow() {
        // Step 1: Begin execution
        vm.isExecuting = true
        vm.errorMessage = nil
        vm.result = nil

        XCTAssertTrue(vm.isExecuting)
        XCTAssertNil(vm.errorMessage)
        XCTAssertNil(vm.result)

        // Step 2: Receive result
        let result = makeQueryResult(
            columns: ["id", "name"],
            rows: [[.text("1"), .text("Alice")]]
        )
        vm.result = result
        vm.isExecuting = false

        XCTAssertFalse(vm.isExecuting)
        XCTAssertNil(vm.errorMessage)
        XCTAssertNotNil(vm.result)
        XCTAssertEqual(vm.result?.rowCount, 1)
    }

    /// Tests the state transitions that occur during a failed query execution,
    /// mirroring the error path in AppViewModel.executeQuery.
    func testFailedQueryExecutionWorkflow() {
        // Step 1: Begin execution
        vm.isExecuting = true
        vm.errorMessage = nil
        vm.result = nil

        XCTAssertTrue(vm.isExecuting)

        // Step 2: Receive error
        vm.errorMessage = "relation \"nonexistent\" does not exist"
        vm.isExecuting = false

        XCTAssertFalse(vm.isExecuting)
        XCTAssertEqual(vm.errorMessage, "relation \"nonexistent\" does not exist")
        XCTAssertNil(vm.result)
    }

    func testConsecutiveQueryExecutions() {
        // First query succeeds
        vm.isExecuting = true
        vm.errorMessage = nil
        vm.result = nil
        vm.result = makeQueryResult(columns: ["a"], rows: [[.text("1")]])
        vm.isExecuting = false

        XCTAssertNotNil(vm.result)
        XCTAssertNil(vm.errorMessage)

        // Second query fails -- result from first query should be cleared
        vm.isExecuting = true
        vm.errorMessage = nil
        vm.result = nil
        vm.errorMessage = "timeout"
        vm.isExecuting = false

        XCTAssertNil(vm.result)
        XCTAssertEqual(vm.errorMessage, "timeout")

        // Third query succeeds -- error from second query should be cleared
        vm.isExecuting = true
        vm.errorMessage = nil
        vm.result = nil
        vm.result = makeQueryResult(columns: ["b"], rows: [[.text("2")]])
        vm.isExecuting = false

        XCTAssertNotNil(vm.result)
        XCTAssertNil(vm.errorMessage)
        XCTAssertEqual(vm.result?.columns, ["b"])
    }

    func testErrorDetailToggleDuringExecution() {
        vm.showErrorDetail = true
        vm.isExecuting = true
        vm.errorMessage = nil
        vm.result = nil

        // showErrorDetail remains independently controlled
        XCTAssertTrue(vm.showErrorDetail)

        vm.isExecuting = false
        vm.errorMessage = "Some error"
        XCTAssertTrue(vm.showErrorDetail)
        XCTAssertEqual(vm.errorMessage, "Some error")
    }

    // MARK: - ObservableObject / Combine Publisher

    func testObjectWillChangePublishesOnQueryTextChange() {
        let expectation = expectation(description: "objectWillChange fires for queryText")
        let cancellable = vm.objectWillChange.sink { _ in
            expectation.fulfill()
        }

        vm.queryText = "SELECT 1"

        wait(for: [expectation], timeout: 1.0)
        cancellable.cancel()
    }

    func testObjectWillChangePublishesOnResultChange() {
        let expectation = expectation(description: "objectWillChange fires for result")
        let cancellable = vm.objectWillChange.sink { _ in
            expectation.fulfill()
        }

        vm.result = makeQueryResult(columns: ["x"], rows: [])

        wait(for: [expectation], timeout: 1.0)
        cancellable.cancel()
    }

    func testObjectWillChangePublishesOnIsExecutingChange() {
        let expectation = expectation(description: "objectWillChange fires for isExecuting")
        let cancellable = vm.objectWillChange.sink { _ in
            expectation.fulfill()
        }

        vm.isExecuting = true

        wait(for: [expectation], timeout: 1.0)
        cancellable.cancel()
    }

    func testObjectWillChangePublishesOnErrorMessageChange() {
        let expectation = expectation(description: "objectWillChange fires for errorMessage")
        let cancellable = vm.objectWillChange.sink { _ in
            expectation.fulfill()
        }

        vm.errorMessage = "error"

        wait(for: [expectation], timeout: 1.0)
        cancellable.cancel()
    }

    func testObjectWillChangePublishesOnShowErrorDetailChange() {
        let expectation = expectation(description: "objectWillChange fires for showErrorDetail")
        let cancellable = vm.objectWillChange.sink { _ in
            expectation.fulfill()
        }

        vm.showErrorDetail = true

        wait(for: [expectation], timeout: 1.0)
        cancellable.cancel()
    }

    // MARK: - Multiple Instances

    func testMultipleInstancesAreIndependent() {
        let vm2 = QueryViewModel()

        vm.queryText = "SELECT 1"
        vm.isExecuting = true
        vm.errorMessage = "error"

        XCTAssertEqual(vm2.queryText, "")
        XCTAssertFalse(vm2.isExecuting)
        XCTAssertNil(vm2.errorMessage)
    }

    // MARK: - Result with Null Cell Values

    func testResultWithNullValues() {
        let result = makeQueryResult(
            columns: ["id", "name"],
            rows: [[.text("1"), .null]]
        )
        vm.result = result
        XCTAssertEqual(vm.result?.rowCount, 1)
    }

    func testResultWithAllNullRow() {
        let result = makeQueryResult(
            columns: ["a", "b", "c"],
            rows: [[.null, .null, .null]]
        )
        vm.result = result
        XCTAssertEqual(vm.result?.rowCount, 1)
        XCTAssertEqual(vm.result?.columnCount, 3)
    }

    // MARK: - Helpers

    private func makeQueryResult(
        columns: [String],
        rows: [[CellValue]],
        executionTime: TimeInterval = 0.1
    ) -> QueryResult {
        QueryResult(
            columns: columns,
            rows: rows,
            executionTime: executionTime,
            rowsAffected: nil,
            isTruncated: false
        )
    }
}

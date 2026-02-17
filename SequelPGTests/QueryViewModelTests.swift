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

    // MARK: - deleteConfirmationRowIndex

    func testInitialDeleteConfirmationRowIndexIsNil() {
        XCTAssertNil(vm.deleteConfirmationRowIndex)
    }

    func testDeleteConfirmationRowIndexCanBeSet() {
        vm.deleteConfirmationRowIndex = 2
        XCTAssertEqual(vm.deleteConfirmationRowIndex, 2)
    }

    func testDeleteConfirmationRowIndexCanBeSetToZero() {
        vm.deleteConfirmationRowIndex = 0
        XCTAssertEqual(vm.deleteConfirmationRowIndex, 0)
    }

    func testDeleteConfirmationRowIndexCanBeSetBackToNil() {
        vm.deleteConfirmationRowIndex = 4
        vm.deleteConfirmationRowIndex = nil
        XCTAssertNil(vm.deleteConfirmationRowIndex)
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

    // MARK: - sortedResult

    func testSortedResultReturnsNilWhenResultIsNil() {
        vm.result = nil
        vm.sortColumn = "name"
        XCTAssertNil(vm.sortedResult)
    }

    func testSortedResultReturnsResultUnchangedWhenNoSortColumn() {
        vm.result = makeQueryResult(
            columns: ["id", "name"],
            rows: [[.text("2"), .text("Bob")], [.text("1"), .text("Alice")]]
        )
        vm.sortColumn = nil

        let sorted = vm.sortedResult
        XCTAssertNotNil(sorted)
        // Rows should be in original order
        XCTAssertEqual(sorted?.rows[0][0], .text("2"))
        XCTAssertEqual(sorted?.rows[1][0], .text("1"))
    }

    func testSortedResultReturnsResultUnchangedWhenSortColumnNotInResult() {
        vm.result = makeQueryResult(
            columns: ["id", "name"],
            rows: [[.text("2"), .text("Bob")], [.text("1"), .text("Alice")]]
        )
        vm.sortColumn = "nonexistent"

        let sorted = vm.sortedResult
        XCTAssertNotNil(sorted)
        XCTAssertEqual(sorted?.rows[0][0], .text("2"))
        XCTAssertEqual(sorted?.rows[1][0], .text("1"))
    }

    func testSortedResultAscending() {
        vm.result = makeQueryResult(
            columns: ["id", "name"],
            rows: [
                [.text("2"), .text("Charlie")],
                [.text("1"), .text("Alice")],
                [.text("3"), .text("Bob")],
            ]
        )
        vm.sortColumn = "name"
        vm.sortAscending = true

        let sorted = vm.sortedResult
        XCTAssertEqual(sorted?.rows[0][1], .text("Alice"))
        XCTAssertEqual(sorted?.rows[1][1], .text("Bob"))
        XCTAssertEqual(sorted?.rows[2][1], .text("Charlie"))
    }

    func testSortedResultDescending() {
        vm.result = makeQueryResult(
            columns: ["id", "name"],
            rows: [
                [.text("2"), .text("Charlie")],
                [.text("1"), .text("Alice")],
                [.text("3"), .text("Bob")],
            ]
        )
        vm.sortColumn = "name"
        vm.sortAscending = false

        let sorted = vm.sortedResult
        XCTAssertEqual(sorted?.rows[0][1], .text("Charlie"))
        XCTAssertEqual(sorted?.rows[1][1], .text("Bob"))
        XCTAssertEqual(sorted?.rows[2][1], .text("Alice"))
    }

    func testSortedResultNullsSortLastInAscending() {
        vm.result = makeQueryResult(
            columns: ["id", "name"],
            rows: [
                [.text("1"), .null],
                [.text("2"), .text("Alice")],
                [.text("3"), .text("Bob")],
            ]
        )
        vm.sortColumn = "name"
        vm.sortAscending = true

        let sorted = vm.sortedResult
        XCTAssertEqual(sorted?.rows[0][1], .text("Alice"))
        XCTAssertEqual(sorted?.rows[1][1], .text("Bob"))
        XCTAssertEqual(sorted?.rows[2][1], .null)
    }

    func testSortedResultNullsSortFirstInDescending() {
        vm.result = makeQueryResult(
            columns: ["id", "name"],
            rows: [
                [.text("2"), .text("Alice")],
                [.text("1"), .null],
                [.text("3"), .text("Bob")],
            ]
        )
        vm.sortColumn = "name"
        vm.sortAscending = false

        let sorted = vm.sortedResult
        XCTAssertEqual(sorted?.rows[0][1], .null)
        XCTAssertEqual(sorted?.rows[1][1], .text("Bob"))
        XCTAssertEqual(sorted?.rows[2][1], .text("Alice"))
    }

    func testSortedResultPreservesMetadata() {
        vm.result = QueryResult(
            columns: ["x"],
            rows: [[.text("b")], [.text("a")]],
            executionTime: 1.23,
            rowsAffected: 5,
            isTruncated: true
        )
        vm.sortColumn = "x"
        vm.sortAscending = true

        let sorted = vm.sortedResult
        XCTAssertEqual(sorted?.executionTime ?? 0, 1.23, accuracy: 0.001)
        XCTAssertEqual(sorted?.rowsAffected, 5)
        XCTAssertTrue(sorted?.isTruncated == true)
    }

    // MARK: - originalRowIndex(_:)

    /// Tests that originalRowIndex returns the display index unchanged when
    /// no sort column is active.
    func testOriginalRowIndexReturnsSameIndexWhenNoSort() {
        vm.result = makeQueryResult(
            columns: ["id", "name"],
            rows: [
                [.text("1"), .text("Alice")],
                [.text("2"), .text("Bob")],
                [.text("3"), .text("Charlie")],
            ]
        )
        vm.sortColumn = nil

        XCTAssertEqual(vm.originalRowIndex(0), 0)
        XCTAssertEqual(vm.originalRowIndex(1), 1)
        XCTAssertEqual(vm.originalRowIndex(2), 2)
    }

    func testOriginalRowIndexReturnsSameIndexWhenResultIsNil() {
        vm.result = nil
        vm.sortColumn = "name"

        XCTAssertEqual(vm.originalRowIndex(0), 0)
        XCTAssertEqual(vm.originalRowIndex(5), 5)
    }

    func testOriginalRowIndexReturnsSameIndexWhenSortColumnNotFound() {
        vm.result = makeQueryResult(
            columns: ["id", "name"],
            rows: [[.text("1"), .text("Alice")]]
        )
        vm.sortColumn = "nonexistent"

        XCTAssertEqual(vm.originalRowIndex(0), 0)
    }

    func testOriginalRowIndexReturnsDisplayIndexWhenOutOfBounds() {
        vm.result = makeQueryResult(
            columns: ["id"],
            rows: [[.text("1")], [.text("2")]]
        )
        vm.sortColumn = "id"
        vm.sortAscending = true

        // Index 10 is out of bounds (only 2 rows)
        XCTAssertEqual(vm.originalRowIndex(10), 10)
    }

    func testOriginalRowIndexReturnsSameIndexWithEmptyResult() {
        vm.result = makeQueryResult(columns: ["id"], rows: [])
        vm.sortColumn = "id"
        vm.sortAscending = true

        XCTAssertEqual(vm.originalRowIndex(0), 0)
    }

    /// When sorted ascending by name: Alice(orig 1), Bob(orig 2), Charlie(orig 0)
    /// Display index 0 -> original 1, display 1 -> original 2, display 2 -> original 0
    func testOriginalRowIndexWithAscendingSort() {
        vm.result = makeQueryResult(
            columns: ["id", "name"],
            rows: [
                [.text("3"), .text("Charlie")],  // original index 0
                [.text("1"), .text("Alice")],     // original index 1
                [.text("2"), .text("Bob")],       // original index 2
            ]
        )
        vm.sortColumn = "name"
        vm.sortAscending = true

        // Ascending by name: Alice (orig 1), Bob (orig 2), Charlie (orig 0)
        XCTAssertEqual(vm.originalRowIndex(0), 1)  // Alice -> original row 1
        XCTAssertEqual(vm.originalRowIndex(1), 2)  // Bob -> original row 2
        XCTAssertEqual(vm.originalRowIndex(2), 0)  // Charlie -> original row 0
    }

    /// When sorted descending by name: Charlie(orig 0), Bob(orig 2), Alice(orig 1)
    /// Display index 0 -> original 0, display 1 -> original 2, display 2 -> original 1
    func testOriginalRowIndexWithDescendingSort() {
        vm.result = makeQueryResult(
            columns: ["id", "name"],
            rows: [
                [.text("3"), .text("Charlie")],  // original index 0
                [.text("1"), .text("Alice")],     // original index 1
                [.text("2"), .text("Bob")],       // original index 2
            ]
        )
        vm.sortColumn = "name"
        vm.sortAscending = false

        // Descending by name: Charlie (orig 0), Bob (orig 2), Alice (orig 1)
        XCTAssertEqual(vm.originalRowIndex(0), 0)  // Charlie -> original row 0
        XCTAssertEqual(vm.originalRowIndex(1), 2)  // Bob -> original row 2
        XCTAssertEqual(vm.originalRowIndex(2), 1)  // Alice -> original row 1
    }

    /// NULLs sort last in ascending order. Original rows:
    /// [0] NULL, [1] Alice, [2] Bob
    /// Sorted ascending: Alice(orig 1), Bob(orig 2), NULL(orig 0)
    func testOriginalRowIndexWithNullsAscending() {
        vm.result = makeQueryResult(
            columns: ["name"],
            rows: [
                [.null],           // original index 0
                [.text("Alice")],  // original index 1
                [.text("Bob")],    // original index 2
            ]
        )
        vm.sortColumn = "name"
        vm.sortAscending = true

        // Ascending: Alice (orig 1), Bob (orig 2), NULL (orig 0)
        XCTAssertEqual(vm.originalRowIndex(0), 1)  // Alice
        XCTAssertEqual(vm.originalRowIndex(1), 2)  // Bob
        XCTAssertEqual(vm.originalRowIndex(2), 0)  // NULL last
    }

    /// NULLs sort first in descending order. Original rows:
    /// [0] Alice, [1] NULL, [2] Bob
    /// Sorted descending: NULL(orig 1), Bob(orig 2), Alice(orig 0)
    func testOriginalRowIndexWithNullsDescending() {
        vm.result = makeQueryResult(
            columns: ["name"],
            rows: [
                [.text("Alice")],  // original index 0
                [.null],           // original index 1
                [.text("Bob")],    // original index 2
            ]
        )
        vm.sortColumn = "name"
        vm.sortAscending = false

        // Descending: NULL (orig 1), Bob (orig 2), Alice (orig 0)
        XCTAssertEqual(vm.originalRowIndex(0), 1)  // NULL first
        XCTAssertEqual(vm.originalRowIndex(1), 2)  // Bob
        XCTAssertEqual(vm.originalRowIndex(2), 0)  // Alice
    }

    /// Multiple NULLs: original rows [0] NULL, [1] NULL, [2] Alice
    /// Ascending: Alice(orig 2), NULL(orig 0), NULL(orig 1) -- NULLs last
    func testOriginalRowIndexWithMultipleNulls() {
        vm.result = makeQueryResult(
            columns: ["name"],
            rows: [
                [.null],           // original index 0
                [.null],           // original index 1
                [.text("Alice")],  // original index 2
            ]
        )
        vm.sortColumn = "name"
        vm.sortAscending = true

        // Ascending: Alice (orig 2), then the two NULLs
        XCTAssertEqual(vm.originalRowIndex(0), 2)  // Alice
        // The two NULLs maintain their relative order (stable sort for both-null returns false)
        let null1 = vm.originalRowIndex(1)
        let null2 = vm.originalRowIndex(2)
        // Both should map to 0 or 1, and together cover {0, 1}
        XCTAssertTrue(Set([null1, null2]) == Set([0, 1]),
                       "Expected NULL rows to map to {0, 1}, got {\(null1), \(null2)}")
    }

    /// Equal values maintain relative order. Original rows:
    /// [0] "Bob", [1] "Alice", [2] "Bob"
    /// Ascending: Alice(orig 1), Bob(orig 0), Bob(orig 2)
    func testOriginalRowIndexWithEqualValues() {
        vm.result = makeQueryResult(
            columns: ["name"],
            rows: [
                [.text("Bob")],    // original index 0
                [.text("Alice")],  // original index 1
                [.text("Bob")],    // original index 2
            ]
        )
        vm.sortColumn = "name"
        vm.sortAscending = true

        // Ascending: Alice (orig 1), Bob (orig 0), Bob (orig 2)
        XCTAssertEqual(vm.originalRowIndex(0), 1)  // Alice
        // The two Bobs -- verify both display positions map to original indices 0 and 2
        let bob1 = vm.originalRowIndex(1)
        let bob2 = vm.originalRowIndex(2)
        XCTAssertTrue(Set([bob1, bob2]) == Set([0, 2]),
                       "Expected Bob rows to map to {0, 2}, got {\(bob1), \(bob2)}")
    }

    /// Verify that originalRowIndex produces the same mapping as sortedResult.
    /// For each display index i, sortedResult.rows[i] should equal
    /// result.rows[originalRowIndex(i)].
    func testOriginalRowIndexConsistentWithSortedResult() {
        vm.result = makeQueryResult(
            columns: ["id", "name"],
            rows: [
                [.text("5"), .text("Eve")],
                [.text("1"), .text("Alice")],
                [.text("3"), .text("Charlie")],
                [.text("2"), .text("Bob")],
                [.text("4"), .null],
            ]
        )
        vm.sortColumn = "name"
        vm.sortAscending = true

        guard let sorted = vm.sortedResult, let original = vm.result else {
            XCTFail("Expected non-nil result and sortedResult")
            return
        }

        for displayIdx in 0..<sorted.rowCount {
            let origIdx = vm.originalRowIndex(displayIdx)
            XCTAssertEqual(sorted.rows[displayIdx], original.rows[origIdx],
                           "Mismatch at display index \(displayIdx): sortedResult row != result.rows[\(origIdx)]")
        }
    }

    func testOriginalRowIndexWithSingleRow() {
        vm.result = makeQueryResult(columns: ["id"], rows: [[.text("1")]])
        vm.sortColumn = "id"
        vm.sortAscending = true

        XCTAssertEqual(vm.originalRowIndex(0), 0)
    }

    // MARK: - Sort Stability (tiebreaker = original index)

    /// When multiple rows share the same sort-column value, ascending sort
    /// must preserve their original relative order (stable sort).
    func testSortStabilityDuplicateValuesAscending() {
        // Original: [0] "B", [1] "A", [2] "B", [3] "B"
        // Expected ascending: A(1), B(0), B(2), B(3) -- Bs keep original order
        vm.result = makeQueryResult(
            columns: ["name"],
            rows: [
                [.text("B")],  // original 0
                [.text("A")],  // original 1
                [.text("B")],  // original 2
                [.text("B")],  // original 3
            ]
        )
        vm.sortColumn = "name"
        vm.sortAscending = true

        let sorted = vm.sortedResult
        XCTAssertEqual(sorted?.rows[0][0], .text("A"))
        XCTAssertEqual(sorted?.rows[1][0], .text("B"))
        XCTAssertEqual(sorted?.rows[2][0], .text("B"))
        XCTAssertEqual(sorted?.rows[3][0], .text("B"))

        // Verify exact original indices via originalRowIndex -- the key stability check
        XCTAssertEqual(vm.originalRowIndex(0), 1)  // A -> original 1
        XCTAssertEqual(vm.originalRowIndex(1), 0)  // first B -> original 0
        XCTAssertEqual(vm.originalRowIndex(2), 2)  // second B -> original 2
        XCTAssertEqual(vm.originalRowIndex(3), 3)  // third B -> original 3
    }

    /// When multiple rows share the same sort-column value, descending sort
    /// must preserve their original relative order among equal elements.
    func testSortStabilityDuplicateValuesDescending() {
        // Original: [0] "B", [1] "A", [2] "B", [3] "B"
        // Expected descending: B(0), B(2), B(3), A(1) -- Bs keep original order
        vm.result = makeQueryResult(
            columns: ["name"],
            rows: [
                [.text("B")],  // original 0
                [.text("A")],  // original 1
                [.text("B")],  // original 2
                [.text("B")],  // original 3
            ]
        )
        vm.sortColumn = "name"
        vm.sortAscending = false

        let sorted = vm.sortedResult
        XCTAssertEqual(sorted?.rows[0][0], .text("B"))
        XCTAssertEqual(sorted?.rows[1][0], .text("B"))
        XCTAssertEqual(sorted?.rows[2][0], .text("B"))
        XCTAssertEqual(sorted?.rows[3][0], .text("A"))

        XCTAssertEqual(vm.originalRowIndex(0), 0)  // first B -> original 0
        XCTAssertEqual(vm.originalRowIndex(1), 2)  // second B -> original 2
        XCTAssertEqual(vm.originalRowIndex(2), 3)  // third B -> original 3
        XCTAssertEqual(vm.originalRowIndex(3), 1)  // A -> original 1
    }

    /// The consistency guarantee: for every display index i,
    /// sortedResult.rows[i] == result.rows[originalRowIndex(i)]
    /// -- tested specifically with duplicate values where a naive sort
    /// could produce different orderings in the two code paths.
    func testSortStabilityConsistencyWithDuplicates() {
        // Five rows with deliberate duplicates and different secondary columns
        // to make each row distinguishable even though the sort column is equal.
        vm.result = makeQueryResult(
            columns: ["score", "tag"],
            rows: [
                [.text("100"), .text("row-0")],  // original 0
                [.text("100"), .text("row-1")],  // original 1
                [.text("50"),  .text("row-2")],  // original 2
                [.text("100"), .text("row-3")],  // original 3
                [.text("50"),  .text("row-4")],  // original 4
            ]
        )
        vm.sortColumn = "score"
        vm.sortAscending = true

        guard let sorted = vm.sortedResult, let original = vm.result else {
            XCTFail("Expected non-nil result and sortedResult")
            return
        }

        for i in 0..<sorted.rowCount {
            let origIdx = vm.originalRowIndex(i)
            XCTAssertEqual(
                sorted.rows[i], original.rows[origIdx],
                "Consistency violated at display index \(i): "
                + "sortedResult row \(sorted.rows[i]) != result.rows[\(origIdx)] \(original.rows[origIdx])"
            )
        }
    }

    /// When every row has the exact same value in the sort column, the sorted
    /// order must match the original order (tiebreaker = original index).
    func testSortStabilityAllEqualValuesAscending() {
        vm.result = makeQueryResult(
            columns: ["val", "id"],
            rows: [
                [.text("X"), .text("row-0")],
                [.text("X"), .text("row-1")],
                [.text("X"), .text("row-2")],
                [.text("X"), .text("row-3")],
            ]
        )
        vm.sortColumn = "val"
        vm.sortAscending = true

        let sorted = vm.sortedResult
        // All values equal -- output order must be original order
        for i in 0..<4 {
            XCTAssertEqual(sorted?.rows[i][1], .text("row-\(i)"),
                           "Row at display index \(i) should be row-\(i)")
            XCTAssertEqual(vm.originalRowIndex(i), i,
                           "originalRowIndex(\(i)) should be \(i) when all values are equal")
        }
    }

    /// All-equal values in descending: tiebreaker still uses original index
    /// ascending, so the order should be identical to the original order.
    func testSortStabilityAllEqualValuesDescending() {
        vm.result = makeQueryResult(
            columns: ["val", "id"],
            rows: [
                [.text("X"), .text("row-0")],
                [.text("X"), .text("row-1")],
                [.text("X"), .text("row-2")],
            ]
        )
        vm.sortColumn = "val"
        vm.sortAscending = false

        let sorted = vm.sortedResult
        for i in 0..<3 {
            XCTAssertEqual(sorted?.rows[i][1], .text("row-\(i)"),
                           "Row at display index \(i) should be row-\(i)")
            XCTAssertEqual(vm.originalRowIndex(i), i)
        }
    }

    /// Duplicates mixed with NULLs: the non-NULL duplicates should maintain
    /// original relative order, and the NULLs should also maintain relative order.
    func testSortStabilityDuplicatesWithNullsAscending() {
        // Original: [0] "A", [1] NULL, [2] "A", [3] NULL, [4] "B"
        // Ascending (NULLs last): A(0), A(2), B(4), NULL(1), NULL(3)
        vm.result = makeQueryResult(
            columns: ["name", "id"],
            rows: [
                [.text("A"), .text("row-0")],  // original 0
                [.null,      .text("row-1")],  // original 1
                [.text("A"), .text("row-2")],  // original 2
                [.null,      .text("row-3")],  // original 3
                [.text("B"), .text("row-4")],  // original 4
            ]
        )
        vm.sortColumn = "name"
        vm.sortAscending = true

        let sorted = vm.sortedResult
        // Non-NULL values sorted ascending: A, A, B
        XCTAssertEqual(sorted?.rows[0][0], .text("A"))
        XCTAssertEqual(sorted?.rows[1][0], .text("A"))
        XCTAssertEqual(sorted?.rows[2][0], .text("B"))
        // NULLs last
        XCTAssertEqual(sorted?.rows[3][0], .null)
        XCTAssertEqual(sorted?.rows[4][0], .null)

        // Stable ordering: first A is original 0, second A is original 2
        XCTAssertEqual(vm.originalRowIndex(0), 0)  // first A -> original 0
        XCTAssertEqual(vm.originalRowIndex(1), 2)  // second A -> original 2
        XCTAssertEqual(vm.originalRowIndex(2), 4)  // B -> original 4
        // Stable ordering among NULLs: first NULL is original 1, second is original 3
        XCTAssertEqual(vm.originalRowIndex(3), 1)  // first NULL -> original 1
        XCTAssertEqual(vm.originalRowIndex(4), 3)  // second NULL -> original 3
    }

    /// Descending sort with duplicates and NULLs: NULLs sort first in
    /// descending, duplicates keep relative order.
    func testSortStabilityDuplicatesWithNullsDescending() {
        // Original: [0] "A", [1] NULL, [2] "A", [3] NULL, [4] "B"
        // Descending (NULLs first): NULL(1), NULL(3), B(4), A(0), A(2)
        vm.result = makeQueryResult(
            columns: ["name", "id"],
            rows: [
                [.text("A"), .text("row-0")],  // original 0
                [.null,      .text("row-1")],  // original 1
                [.text("A"), .text("row-2")],  // original 2
                [.null,      .text("row-3")],  // original 3
                [.text("B"), .text("row-4")],  // original 4
            ]
        )
        vm.sortColumn = "name"
        vm.sortAscending = false

        let sorted = vm.sortedResult
        // NULLs first in descending
        XCTAssertEqual(sorted?.rows[0][0], .null)
        XCTAssertEqual(sorted?.rows[1][0], .null)
        // Then values descending: B, A, A
        XCTAssertEqual(sorted?.rows[2][0], .text("B"))
        XCTAssertEqual(sorted?.rows[3][0], .text("A"))
        XCTAssertEqual(sorted?.rows[4][0], .text("A"))

        // Stable ordering among NULLs
        XCTAssertEqual(vm.originalRowIndex(0), 1)  // first NULL -> original 1
        XCTAssertEqual(vm.originalRowIndex(1), 3)  // second NULL -> original 3
        XCTAssertEqual(vm.originalRowIndex(2), 4)  // B -> original 4
        // Stable ordering among As
        XCTAssertEqual(vm.originalRowIndex(3), 0)  // first A -> original 0
        XCTAssertEqual(vm.originalRowIndex(4), 2)  // second A -> original 2
    }

    /// Full consistency check with duplicates and NULLs in both directions.
    /// sortedResult.rows[i] must equal result.rows[originalRowIndex(i)] for all i.
    func testSortStabilityConsistencyWithDuplicatesAndNulls() {
        let rows: [[CellValue]] = [
            [.text("C"), .text("row-0")],
            [.null,      .text("row-1")],
            [.text("A"), .text("row-2")],
            [.text("C"), .text("row-3")],
            [.null,      .text("row-4")],
            [.text("A"), .text("row-5")],
            [.text("B"), .text("row-6")],
        ]
        vm.result = makeQueryResult(columns: ["val", "id"], rows: rows)

        for ascending in [true, false] {
            vm.sortColumn = "val"
            vm.sortAscending = ascending

            guard let sorted = vm.sortedResult, let original = vm.result else {
                XCTFail("Expected non-nil result and sortedResult (ascending=\(ascending))")
                continue
            }

            for i in 0..<sorted.rowCount {
                let origIdx = vm.originalRowIndex(i)
                XCTAssertEqual(
                    sorted.rows[i], original.rows[origIdx],
                    "Consistency violated at display index \(i) (ascending=\(ascending)): "
                    + "sorted row \(sorted.rows[i]) != original[\(origIdx)] \(original.rows[origIdx])"
                )
            }
        }
    }

    /// Larger dataset: 10 rows with only 2 distinct values to stress-test
    /// that the tiebreaker produces a deterministic stable order.
    func testSortStabilityLargerDatasetWithFewDistinctValues() {
        var rows: [[CellValue]] = []
        for i in 0..<10 {
            let value = (i % 2 == 0) ? "Even" : "Odd"
            rows.append([.text(value), .text("row-\(i)")])
        }
        vm.result = makeQueryResult(columns: ["parity", "id"], rows: rows)
        vm.sortColumn = "parity"
        vm.sortAscending = true

        guard let sorted = vm.sortedResult, let original = vm.result else {
            XCTFail("Expected non-nil result and sortedResult")
            return
        }

        // All "Even" rows should come first (ascending), then "Odd"
        // Within each group, original order must be preserved
        // Even indices in original: 0, 2, 4, 6, 8
        // Odd indices in original: 1, 3, 5, 7, 9
        let expectedOrder = [0, 2, 4, 6, 8, 1, 3, 5, 7, 9]
        for i in 0..<10 {
            XCTAssertEqual(vm.originalRowIndex(i), expectedOrder[i],
                           "At display index \(i): expected original \(expectedOrder[i])")
            XCTAssertEqual(sorted.rows[i], original.rows[expectedOrder[i]])
        }
    }

    // MARK: - Sort Column / Sort Ascending Published Properties

    func testInitialSortColumnIsNil() {
        XCTAssertNil(vm.sortColumn)
    }

    func testInitialSortAscendingIsTrue() {
        XCTAssertTrue(vm.sortAscending)
    }

    func testSetSortColumn() {
        vm.sortColumn = "name"
        XCTAssertEqual(vm.sortColumn, "name")
    }

    func testSetSortAscendingToFalse() {
        vm.sortAscending = false
        XCTAssertFalse(vm.sortAscending)
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

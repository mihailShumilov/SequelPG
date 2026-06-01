import AppKit
import XCTest
@testable import SequelPG

@MainActor
final class CompletionTextViewTests: XCTestCase {

    private func makeTextView(_ text: String) -> CompletionTextView {
        let tv = CompletionTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 100))
        tv.string = text
        return tv
    }

    // MARK: - completionRange

    func testCompletionRangeCoversIdentifierUnderCaret() {
        let tv = makeTextView("DROP SCHEMA val")
        tv.setSelectedRange(NSRange(location: 15, length: 0)) // end of "val"
        XCTAssertEqual(tv.completionRange, NSRange(location: 12, length: 3))
    }

    func testCompletionRangeIncludesUnderscores() {
        let tv = makeTextView("SELECT user_id")
        tv.setSelectedRange(NSRange(location: 14, length: 0)) // end of "user_id"
        XCTAssertEqual(tv.completionRange, NSRange(location: 7, length: 7))
    }

    func testCompletionRangeNilAfterDelimiter() {
        let tv = makeTextView("DROP SCHEMA val ")
        tv.setSelectedRange(NSRange(location: 16, length: 0)) // after the space
        XCTAssertNil(tv.completionRange)
    }

    // MARK: - commitCompletion

    /// Accepting a completion leaves the caret at the END of the inserted word
    /// with nothing selected, so the next keystroke continues the statement
    /// instead of overwriting the just-accepted word (the JetBrains behaviour).
    func testCommitLeavesCaretAtEndNoSelection() {
        let tv = makeTextView("DROP SCHEMA val")
        let word = "validate_20260526071310"
        tv.commitCompletion(word, replacing: NSRange(location: 12, length: 3))
        XCTAssertEqual(tv.string, "DROP SCHEMA \(word)")
        let expectedCaret = 12 + (word as NSString).length
        XCTAssertEqual(tv.selectedRange(), NSRange(location: expectedCaret, length: 0))
    }

    func testTypingAfterCommitAppendsInsteadOfOverwriting() {
        let tv = makeTextView("DROP SCHEMA val")
        tv.commitCompletion("validate_x", replacing: NSRange(location: 12, length: 3))
        tv.insertText(" CASCADE", replacementRange: tv.selectedRange())
        XCTAssertEqual(tv.string, "DROP SCHEMA validate_x CASCADE")
    }

    func testCommitSuppressesImmediateRetrigger() {
        let tv = makeTextView("SELECT cou")
        tv.commitCompletion("count", replacing: NSRange(location: 7, length: 3))
        // The commit arms a one-shot suppression so the resulting textDidChange
        // doesn't re-pop the popup for the freshly inserted word.
        XCTAssertTrue(tv.consumeAutoCompleteSuppression())
        XCTAssertFalse(tv.consumeAutoCompleteSuppression(), "Suppression must be one-shot")
    }
}

@MainActor
final class SQLCompletionControllerTests: XCTestCase {

    private func item(_ name: String, kind: CompletionItem.Kind = .schema) -> CompletionItem {
        CompletionItem(insertText: name, label: name, kind: kind, detail: "\(kind)")
    }

    func testMoveSelectionWrapsBothDirections() {
        let controller = SQLCompletionController()
        controller.model.items = [item("a"), item("b"), item("c")]
        controller.model.selectedIndex = 0

        controller.moveSelection(by: -1)
        XCTAssertEqual(controller.model.selectedIndex, 2, "Up from the first item wraps to the last")

        controller.moveSelection(by: 1)
        XCTAssertEqual(controller.model.selectedIndex, 0, "Down from the last item wraps to the first")

        controller.moveSelection(by: 1)
        XCTAssertEqual(controller.model.selectedIndex, 1)
    }

    func testAcceptSelectedInsertsHighlightedItem() {
        let tv = CompletionTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 100))
        tv.string = "DROP SCHEMA val"
        let controller = SQLCompletionController()
        controller.attach(to: tv)
        controller.model.items = [item("validate_x"), item("other_schema")]
        controller.model.selectedIndex = 0
        controller.partialRange = NSRange(location: 12, length: 3)

        XCTAssertTrue(controller.acceptSelected())
        XCTAssertEqual(tv.string, "DROP SCHEMA validate_x")
        XCTAssertEqual(tv.selectedRange(), NSRange(location: 22, length: 0))
    }

    func testAcceptSelectedReturnsFalseWhenEmpty() {
        let controller = SQLCompletionController()
        controller.model.items = []
        XCTAssertFalse(controller.acceptSelected())
    }
}

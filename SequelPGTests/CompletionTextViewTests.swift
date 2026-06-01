import AppKit
import XCTest
@testable import SequelPG

@MainActor
final class CompletionTextViewTests: XCTestCase {

    /// After committing a completion with Tab, the inserted word must NOT be
    /// left selected — the caret has to sit at its end so the next keystroke
    /// continues the statement instead of overwriting the just-accepted word
    /// (JetBrains-style acceptance).
    func testCommitWithTabLeavesCaretAtEndNoSelection() {
        let tv = CompletionTextView(frame: .zero)
        tv.string = "DROP SCHEMA val"
        let word = "validate_20260526071310"
        tv.insertCompletion(
            word,
            forPartialWordRange: NSRange(location: 12, length: 3), // "val"
            movement: Int(NSTextMovement.tab.rawValue),
            isFinal: true
        )
        XCTAssertEqual(tv.string, "DROP SCHEMA \(word)")
        let expectedCaret = 12 + (word as NSString).length
        XCTAssertEqual(
            tv.selectedRange(),
            NSRange(location: expectedCaret, length: 0),
            "Caret should be collapsed at the end of the inserted word, nothing selected"
        )
    }

    /// With the caret collapsed at the end, continuing to type appends rather
    /// than replacing the completion.
    func testTypingAfterCommitAppendsInsteadOfOverwriting() {
        let tv = CompletionTextView(frame: .zero)
        tv.string = "DROP SCHEMA val"
        tv.insertCompletion(
            "validate_x",
            forPartialWordRange: NSRange(location: 12, length: 3),
            movement: Int(NSTextMovement.return.rawValue),
            isFinal: true
        )
        tv.insertText(" CASCADE", replacementRange: tv.selectedRange())
        XCTAssertEqual(tv.string, "DROP SCHEMA validate_x CASCADE")
    }

    /// While the popup is still open and the user is navigating it
    /// (`isFinal == false`), we defer entirely to NSTextView's preview
    /// behaviour and must not truncate the inserted word.
    func testNonFinalInsertionDefersToSuperclass() {
        let tv = CompletionTextView(frame: .zero)
        tv.string = "se"
        tv.insertCompletion(
            "SELECT",
            forPartialWordRange: NSRange(location: 0, length: 2),
            movement: Int(NSTextMovement.other.rawValue),
            isFinal: false
        )
        XCTAssertEqual(tv.string, "SELECT")
    }
}

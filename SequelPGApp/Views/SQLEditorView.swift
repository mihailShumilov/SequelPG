import AppKit
import SwiftUI

/// NSViewRepresentable wrapping NSTextView with SQL syntax highlighting and
/// context-aware autocompletion. Uses NSTextView's native `complete(_:)` popup
/// — its UI is plain by macOS standards (system list, no themed chips) but it
/// participates correctly in the text view's responder chain, which a custom
/// floating panel does not. A previous custom-panel implementation could steal
/// key focus mid-typing and corrupt input; falling back to the native popup
/// trades visual polish for input reliability.
///
/// The smart part of completion lives in `SQLCompletionProvider`: prefix-first
/// ranking with fuzzy fallback, JetBrains-style, and context detection that
/// biases the candidate pool based on whether the cursor is after FROM,
/// WHERE, ON, etc.
struct SQLEditorView: NSViewRepresentable {
    @Binding var text: String
    var completionMetadata: SQLCompletionProvider.Metadata
    /// When false, the completion popup is never triggered automatically while
    /// typing (GH #4). On-demand completion via Escape still works. Defaults to
    /// true so callers that don't care keep the original behaviour.
    var autocompleteWhileTyping: Bool = true

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let textStorage = SQLTextStorage()
        let layoutManager = NSLayoutManager()
        textStorage.addLayoutManager(layoutManager)

        let textContainer = NSTextContainer()
        textContainer.widthTracksTextView = true
        textContainer.heightTracksTextView = false
        layoutManager.addTextContainer(textContainer)

        let textView = CompletionTextView(frame: .zero, textContainer: textContainer)
        textView.isEditable = true
        textView.isSelectable = true
        textView.isRichText = false
        textView.allowsUndo = true
        let jbm = NSFont(name: "JetBrainsMono-Regular", size: 13.5)
            ?? NSFont.monospacedSystemFont(ofSize: 13.5, weight: .regular)
        textView.font = jbm
        textView.textColor = Theme.inkNS
        textView.backgroundColor = Theme.bgNS
        textView.insertionPointColor = Theme.accentNS
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticLinkDetectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.isGrammarCheckingEnabled = false
        textView.autoresizingMask = [.width]
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.delegate = context.coordinator

        // Set initial text
        if !text.isEmpty {
            textStorage.replaceCharacters(in: NSRange(location: 0, length: 0), with: text)
        }
        context.coordinator.resetGrowthBaseline(to: (text as NSString).length)

        context.coordinator.autocompleteWhileTyping = autocompleteWhileTyping

        textStorage.onChange = { [weak coordinator = context.coordinator] newText in
            coordinator?.storageDidChange(newText)
        }

        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.documentView = textView
        scrollView.drawsBackground = true
        scrollView.backgroundColor = Theme.bgNS

        context.coordinator.textStorage = textStorage

        return scrollView
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        guard let textView = nsView.documentView as? NSTextView,
              let storage = textView.textStorage as? SQLTextStorage
        else { return }

        // Sync the auto-trigger preference unconditionally — it can change
        // independently of the metadata, and the metadata guard below returns
        // early when only the text (not the metadata) differs.
        context.coordinator.autocompleteWhileTyping = autocompleteWhileTyping

        guard context.coordinator.metadata != completionMetadata else {
            // Still check text sync even if metadata hasn't changed
            if storage.string != text {
                let savedRange = textView.selectedRange()
                storage.replaceCharacters(
                    in: NSRange(location: 0, length: storage.length),
                    with: text
                )
                let clamped = NSRange(
                    location: min(savedRange.location, storage.length),
                    length: 0
                )
                textView.setSelectedRange(clamped)
            }
            return
        }

        // Only update when the binding changed externally (e.g., beautify, clear)
        if storage.string != text {
            let savedRange = textView.selectedRange()
            storage.replaceCharacters(
                in: NSRange(location: 0, length: storage.length),
                with: text
            )
            let clamped = NSRange(
                location: min(savedRange.location, storage.length),
                length: 0
            )
            textView.setSelectedRange(clamped)
        }

        context.coordinator.metadata = completionMetadata
    }

    // MARK: - Coordinator

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        @Binding var text: String
        var metadata = SQLCompletionProvider.Metadata(schemas: [], tables: [], columns: [])
        /// Mirrors `SQLEditorView.autocompleteWhileTyping`. When false, the
        /// popup never fires on its own (GH #4); on-demand completion (Escape)
        /// still routes through `textView(_:completions:…)`.
        var autocompleteWhileTyping = true
        weak var textStorage: SQLTextStorage?
        private var isUpdatingFromStorage = false

        /// Minimum partial length before completion auto-fires. Two chars
        /// avoids the popup flickering on every single keystroke.
        private let autoTriggerMinChars = 2

        /// Length of the document as of the previous `textDidChange`. We auto-
        /// trigger the completion popup only when the text *grows* — typing,
        /// not deleting. Without this guard, every backspace would re-fire
        /// `complete(nil)` and re-suggest whatever the user was trying to
        /// remove ("public" reappearing while the user tries to delete it).
        private var lastTextLength: Int = 0

        init(text: Binding<String>) {
            _text = text
        }

        func storageDidChange(_ newText: String) {
            guard !isUpdatingFromStorage else { return }
            isUpdatingFromStorage = true
            text = newText
            isUpdatingFromStorage = false
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            let currentLength = (textView.string as NSString).length
            let didGrow = currentLength > lastTextLength
            lastTextLength = currentLength
            // Don't auto-trigger on deletion — the user is correcting input,
            // not asking for suggestions. Don't auto-trigger on equal-length
            // changes either (most common case: undo / programmatic
            // replacement). The popup can still be manually invoked with
            // NSTextView's ESC-then-F5 (or via the completion menu item).
            guard didGrow else { return }
            maybeAutoComplete(in: textView)
        }

        /// Called from `makeNSView` after the initial text is set, so the
        /// growth-detection baseline starts at the actual document length
        /// rather than 0 (which would cause the popup to fire on first edit
        /// even if the user is deleting from pre-loaded content).
        func resetGrowthBaseline(to length: Int) {
            lastTextLength = length
        }

        /// Triggers NSTextView's native completion popup when the user is
        /// inside an identifier of at least `autoTriggerMinChars` characters
        /// and not inside a string/comment.
        private func maybeAutoComplete(in textView: NSTextView) {
            // Respect the user's preference — when auto-trigger is off we never
            // pop the list while typing (GH #4). The user can still invoke
            // completion on demand with Escape, which goes through
            // `textView(_:completions:…)` directly without this path.
            guard autocompleteWhileTyping else { return }

            let cursor = textView.selectedRange().location
            guard cursor > 0 else { return }

            let string = textView.string
            guard cursor <= (string as NSString).length else { return }

            // Find start of the current identifier.
            let nsString = string as NSString
            var partialStart = cursor
            while partialStart > 0 {
                let prev = nsString.substring(with: NSRange(location: partialStart - 1, length: 1))
                guard let ch = prev.unicodeScalars.first,
                      Character(ch).isLetter || Character(ch).isNumber || ch == "_"
                else { break }
                partialStart -= 1
            }
            let partialLen = cursor - partialStart
            guard partialLen >= autoTriggerMinChars else { return }

            // Don't pop inside string literals or comments.
            if let tokens = textStorage?.lastTokens, !shouldShowCompletion(tokens: tokens, at: cursor) {
                return
            }
            textView.complete(nil)
        }

        // MARK: NSTextViewDelegate

        /// Asked by NSTextView when its native completion popup needs items.
        /// We ignore the supplied `words` (system-generated guesses) and
        /// compute our own ranked list from `SQLCompletionProvider`.
        ///
        /// Returns **bare identifiers only** — no category suffix. An earlier
        /// version appended `  ·  category` and stripped it on accept, but
        /// the strip path bypassed NSTextView's undo manager, leaving the
        /// user unable to Cmd-Z a wrong completion. We accept a less
        /// informative popup in exchange for correct undo.
        ///
        /// Pre-selection: index 0 only when there's a confident prefix
        /// match. For fuzzy-only fallbacks we deliberately leave index at -1
        /// so the user has to actively arrow-down before Tab/Return commits
        /// — that prevents a stray Tab from inserting a marginal match (the
        /// `li → public` problem).
        func textView(
            _ textView: NSTextView,
            completions words: [String],
            forPartialWordRange charRange: NSRange,
            indexOfSelectedItem index: UnsafeMutablePointer<Int>?
        ) -> [String] {
            guard charRange.length >= 1,
                  let range = Range(charRange, in: textView.string)
            else { return [] }

            let partial = String(textView.string[range])
            let tokens = textStorage?.lastTokens ?? []
            let context = CompletionContext.detect(tokens: tokens, cursorUTF16Offset: charRange.location + charRange.length)
            let result = SQLCompletionProvider.result(for: partial, metadata: metadata, context: context)

            if result.items.isEmpty {
                index?.pointee = -1
                return []
            }
            index?.pointee = result.preselectTop ? 0 : -1
            return result.items.map(\.insertText)
        }

        /// Check if the cursor is at a position where completion makes sense
        /// (not inside a string literal or comment). Uses pre-computed tokens.
        private func shouldShowCompletion(tokens: [SQLFormatter.Token], at offset: Int) -> Bool {
            var pos = 0
            for token in tokens {
                let tokenEnd = pos + token.text.utf16.count
                if offset >= pos, offset <= tokenEnd {
                    switch token.kind {
                    case .stringLiteral, .dollarQuoted, .lineComment, .blockComment:
                        return false
                    default:
                        return true
                    }
                }
                pos = tokenEnd
            }
            return true
        }
    }
}

/// NSTextView subclass that reports a sensible `rangeForUserCompletion` for
/// SQL identifiers — NSTextView's default treats `_` as a word boundary, which
/// truncates `my_column` to just `column`.
final class CompletionTextView: NSTextView {
    override var rangeForUserCompletion: NSRange {
        let cursorLocation = selectedRange().location
        guard cursorLocation > 0,
              let cursorIdx = Range(NSRange(location: 0, length: cursorLocation), in: string)?.upperBound
        else { return NSRange(location: 0, length: 0) }

        var startIdx = cursorIdx
        while startIdx > string.startIndex {
            let prev = string.index(before: startIdx)
            let ch = string[prev]
            guard ch.isLetter || ch.isNumber || ch == "_" else { break }
            startIdx = prev
        }

        return NSRange(startIdx ..< cursorIdx, in: string)
    }
}

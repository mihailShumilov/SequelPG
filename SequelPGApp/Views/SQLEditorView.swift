import SwiftUI

/// NSViewRepresentable wrapping NSTextView with SQL syntax highlighting and autocompletion.
struct SQLEditorView: NSViewRepresentable {
    @Binding var text: String
    var completionMetadata: SQLCompletionProvider.Metadata

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
        textView.font = NSFont.monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        textView.textColor = .labelColor
        textView.backgroundColor = .textBackgroundColor
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

        textStorage.onChange = { [weak coordinator = context.coordinator] newText in
            coordinator?.storageDidChange(newText)
        }

        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.documentView = textView
        scrollView.drawsBackground = true

        context.coordinator.textStorage = textStorage

        return scrollView
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        guard let textView = nsView.documentView as? NSTextView,
              let storage = textView.textStorage as? SQLTextStorage
        else { return }

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

    final class Coordinator: NSObject, NSTextViewDelegate {
        @Binding var text: String
        var metadata = SQLCompletionProvider.Metadata(schemas: [], tables: [], columns: [])
        weak var textStorage: SQLTextStorage?
        private var isUpdatingFromStorage = false

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

            // Use cached tokens from the highlighting pass to avoid double tokenization
            let cursorLocation = textView.selectedRange().location
            if cursorLocation > 0,
               let tokens = textStorage?.lastTokens,
               shouldShowCompletion(tokens: tokens, at: cursorLocation) {
                textView.complete(nil)
            }
        }

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
            index?.pointee = -1

            return SQLCompletionProvider.completions(for: partial, metadata: metadata)
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

/// NSTextView subclass that overrides rangeForUserCompletion to work correctly
/// with SQL identifiers containing underscores.
private final class CompletionTextView: NSTextView {
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

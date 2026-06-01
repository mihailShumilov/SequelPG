import AppKit
import SwiftUI

/// NSViewRepresentable wrapping NSTextView with SQL syntax highlighting and a
/// custom, JetBrains-style autocompletion popup (`SQLCompletionController`).
///
/// The popup is a non-activating panel that never becomes key, so the text
/// view stays first responder and every keystroke is typed normally — the
/// popup just re-queries afterwards. While it's visible the text view forwards
/// ↑/↓/Tab/Return/Esc to the controller; nothing intercepts or rewrites
/// character events. (An earlier custom panel that *did* take key focus
/// corrupted input — see the `SQLCompletionWindow.swift` tombstone.)
///
/// The smart part of completion lives in `SQLCompletionProvider`: prefix-first
/// ranking with fuzzy fallback and context detection that biases candidates by
/// whether the cursor is after FROM, WHERE, ON, DROP SCHEMA, etc.
struct SQLEditorView: NSViewRepresentable {
    @Binding var text: String
    var completionMetadata: SQLCompletionProvider.Metadata
    /// When false, the completion popup is never triggered automatically while
    /// typing (GH #4). On-demand completion (Escape / ⌃Space) still works.
    /// Defaults to true so callers that don't care keep the original behaviour.
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

        // Wire the completion popup: the controller is owned by the coordinator
        // (lives as long as the view), holds the text view weakly, and the text
        // view holds the controller weakly — no retain cycle.
        let coordinator = context.coordinator
        coordinator.completion.attach(to: textView)
        textView.completion = coordinator.completion
        textView.onManualTrigger = { [weak coordinator, weak textView] in
            guard let coordinator, let textView else { return }
            coordinator.forceCompletion(in: textView)
        }

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
        guard let textView = nsView.documentView as? CompletionTextView,
              let storage = textView.textStorage as? SQLTextStorage
        else { return }

        // Sync the auto-trigger preference unconditionally — it can change
        // independently of the metadata, and the metadata guard below returns
        // early when only the text (not the metadata) differs.
        context.coordinator.autocompleteWhileTyping = autocompleteWhileTyping

        guard context.coordinator.metadata != completionMetadata else {
            // Still check text sync even if metadata hasn't changed
            if storage.string != text {
                replaceText(in: textView, storage: storage, with: text)
            }
            return
        }

        // Only update when the binding changed externally (e.g., beautify, clear)
        if storage.string != text {
            replaceText(in: textView, storage: storage, with: text)
        }

        context.coordinator.metadata = completionMetadata
    }

    /// Tear-down hook — make sure the popup's child window doesn't outlive the
    /// editor it was attached to.
    static func dismantleNSView(_ nsView: NSScrollView, coordinator: Coordinator) {
        coordinator.completion.hide()
    }

    /// Replace the whole document with `newText` while preserving the caret as
    /// best we can. Hides any open popup — the text changed out from under it.
    private func replaceText(in textView: CompletionTextView, storage: SQLTextStorage, with newText: String) {
        textView.completion?.hide()
        let savedRange = textView.selectedRange()
        storage.replaceCharacters(in: NSRange(location: 0, length: storage.length), with: newText)
        let clamped = NSRange(location: min(savedRange.location, storage.length), length: 0)
        textView.setSelectedRange(clamped)
        textView.completionBaselineDidReset()
    }

    // MARK: - Coordinator

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        @Binding var text: String
        var metadata = SQLCompletionProvider.Metadata(schemas: [], tables: [], columns: [])
        /// Mirrors `SQLEditorView.autocompleteWhileTyping` (GH #4). When false,
        /// the popup never pops on its own; Escape / ⌃Space still work.
        var autocompleteWhileTyping = true
        weak var textStorage: SQLTextStorage?
        /// The popup controller, owned here for the lifetime of the view.
        let completion = SQLCompletionController()
        private var isUpdatingFromStorage = false

        /// Minimum partial length before completion auto-fires. Two chars
        /// avoids the popup flickering on every single keystroke.
        private let autoTriggerMinChars = 2

        /// Length of the document as of the previous `textDidChange`, used to
        /// detect typing (growth) vs deleting.
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
            guard let textView = notification.object as? CompletionTextView else { return }
            let currentLength = (textView.string as NSString).length
            let didGrow = currentLength > lastTextLength
            lastTextLength = currentLength

            // A just-accepted completion leaves a full, valid identifier under
            // the caret; without this guard `refreshCompletion` would
            // immediately re-pop the popup for the word we just inserted.
            if textView.consumeAutoCompleteSuppression() {
                completion.hide()
                return
            }
            refreshCompletion(in: textView, autoShow: didGrow)
        }

        func resetGrowthBaseline(to length: Int) {
            lastTextLength = length
        }

        /// On-demand completion (Escape / ⌃Space): show regardless of the
        /// auto-trigger preference and minimum-length gate.
        func forceCompletion(in textView: CompletionTextView) {
            refreshCompletion(in: textView, autoShow: true, force: true)
        }

        /// Compute the partial word + clause context under the caret, rank
        /// candidates, and present/update/hide the popup accordingly.
        ///
        /// - `autoShow`: this change was growth (typing), so an auto-trigger is
        ///   permitted (subject to the preference + min-length gate).
        /// - `force`: an explicit on-demand request — bypass the gate.
        private func refreshCompletion(in textView: CompletionTextView, autoShow: Bool, force: Bool = false) {
            guard let range = textView.completionRange else { completion.hide(); return }
            let nsString = textView.string as NSString
            let partial = nsString.substring(with: range)
            guard !partial.isEmpty else { completion.hide(); return }

            let tokens = textStorage?.lastTokens ?? []
            let cursorEnd = range.location + range.length
            guard shouldShowCompletion(tokens: tokens, at: cursorEnd) else { completion.hide(); return }

            let context = CompletionContext.detect(tokens: tokens, cursorUTF16Offset: cursorEnd)
            let result = SQLCompletionProvider.result(for: partial, metadata: metadata, context: context)
            guard !result.items.isEmpty else { completion.hide(); return }

            // Show when: explicitly requested, already open (keep filtering as
            // the user types/deletes), or this is a fresh auto-trigger that
            // clears the preference + min-length gate.
            let canAutoShow = autoShow && autocompleteWhileTyping && partial.utf16.count >= autoTriggerMinChars
            if force || completion.isVisible || canAutoShow {
                completion.present(items: result.items, partialRange: range, in: textView)
            }
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

/// NSTextView subclass for the SQL editor. Hosts the custom completion popup:
/// it keeps key focus, computes the identifier range under the caret, commits
/// accepted completions (caret left at the end, nothing selected), and routes
/// navigation keys to the controller while the popup is visible.
final class CompletionTextView: NSTextView {
    /// The popup controller (owned by the coordinator). Weak to avoid a cycle.
    weak var completion: SQLCompletionController?
    /// Invoked for an on-demand completion request (Escape / ⌃Space).
    var onManualTrigger: (() -> Void)?

    /// Set for one edit cycle after a commit so the delegate's `textDidChange`
    /// doesn't immediately re-pop the popup for the word just inserted.
    private var suppressAutoCompleteOnce = false

    /// The range of the identifier currently under the caret (letters, digits,
    /// `_`), or nil when the caret isn't at the trailing edge of one. Unlike
    /// NSTextView's default word logic, `_` is treated as part of the word so
    /// `my_column` stays whole.
    var completionRange: NSRange? {
        let selection = selectedRange()
        guard selection.length == 0 else { return nil }
        let caret = selection.location
        let nsString = string as NSString
        guard caret > 0, caret <= nsString.length else { return nil }

        var start = caret
        while start > 0 {
            let ch = nsString.substring(with: NSRange(location: start - 1, length: 1))
            guard let scalar = ch.unicodeScalars.first,
                  Character(scalar).isLetter || Character(scalar).isNumber || scalar == "_"
            else { break }
            start -= 1
        }
        guard start < caret else { return nil }
        return NSRange(location: start, length: caret - start)
    }

    /// Replace `range` with `word`, leaving the caret collapsed at the END with
    /// nothing selected, and registering the edit with the undo manager so a
    /// wrong completion can be undone with ⌘Z. Leaving no selection is what
    /// lets the user keep typing the next token without overwriting the word
    /// they just accepted.
    func commitCompletion(_ word: String, replacing range: NSRange) {
        guard shouldChangeText(in: range, replacementString: word) else { return }
        suppressAutoCompleteOnce = true
        textStorage?.replaceCharacters(in: range, with: word)
        didChangeText()
        let caret = min(range.location + (word as NSString).length, (string as NSString).length)
        setSelectedRange(NSRange(location: caret, length: 0))
    }

    /// Reads and clears the one-shot suppression flag (see `commitCompletion`).
    func consumeAutoCompleteSuppression() -> Bool {
        defer { suppressAutoCompleteOnce = false }
        return suppressAutoCompleteOnce
    }

    /// Called after a programmatic full-document replacement so a stale
    /// suppression flag doesn't swallow the next real auto-trigger.
    func completionBaselineDidReset() {
        suppressAutoCompleteOnce = false
    }

    override func keyDown(with event: NSEvent) {
        if let completion, completion.isVisible {
            // Let modifier combinations through untouched — ⌘↵ (run query),
            // ⌘A, ⌘C, ⌥-arrows, etc. should never be swallowed by the popup.
            guard event.modifierFlags.intersection([.command, .option, .control]).isEmpty else {
                super.keyDown(with: event)
                return
            }
            switch event.keyCode {
            case 126: // ↑
                completion.moveSelection(by: -1)
                return
            case 125: // ↓
                completion.moveSelection(by: 1)
                return
            case 36, 76, 48: // Return, keypad Enter, Tab → accept
                if completion.acceptSelected() { return }
                completion.hide()
                super.keyDown(with: event)
                return
            case 53: // Esc → dismiss
                completion.hide()
                return
            case 123, 124: // ←/→ → dismiss, then move the caret normally
                completion.hide()
                super.keyDown(with: event)
                return
            default:
                // Type the character normally; the delegate's textDidChange
                // re-queries and updates the list.
                super.keyDown(with: event)
                return
            }
        }

        // Popup hidden — on-demand triggers.
        if event.keyCode == 53 { // Esc
            onManualTrigger?()
            return
        }
        if event.modifierFlags.contains(.control), event.charactersIgnoringModifiers == " " {
            onManualTrigger?()
            return
        }
        super.keyDown(with: event)
    }

    override func mouseDown(with event: NSEvent) {
        completion?.hide()
        super.mouseDown(with: event)
    }

    override func resignFirstResponder() -> Bool {
        completion?.hide()
        return super.resignFirstResponder()
    }
}

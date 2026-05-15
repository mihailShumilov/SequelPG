import AppKit
import SwiftUI

/// Read-only SwiftUI wrapper around NSTextView + `SQLTextStorage` for displaying
/// syntax-highlighted SQL (used by the Definition tab for every object type).
/// Selection, copy, and scrolling are enabled; editing and completion are not.
struct SQLSyntaxView: NSViewRepresentable {
    let text: String

    func makeNSView(context _: Context) -> NSScrollView {
        let textStorage = SQLTextStorage()
        let layoutManager = NSLayoutManager()
        textStorage.addLayoutManager(layoutManager)

        let textContainer = NSTextContainer()
        textContainer.widthTracksTextView = true
        textContainer.heightTracksTextView = false
        layoutManager.addTextContainer(textContainer)

        let textView = NSTextView(frame: .zero, textContainer: textContainer)
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = false
        // Prefer the bundled JetBrains Mono face when present, fall back to the
        // system monospaced font otherwise.
        let jbm = NSFont(name: "JetBrainsMono-Regular", size: 13)
            ?? NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        textView.font = jbm
        textView.textColor = Theme.inkNS
        textView.backgroundColor = Theme.bgNS
        textView.drawsBackground = true
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
        textView.textContainerInset = NSSize(width: 8, height: 8)

        if !text.isEmpty {
            textStorage.replaceCharacters(in: NSRange(location: 0, length: 0), with: text)
        }

        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.documentView = textView
        scrollView.drawsBackground = true
        scrollView.backgroundColor = Theme.bgNS
        return scrollView
    }

    func updateNSView(_ nsView: NSScrollView, context _: Context) {
        guard let textView = nsView.documentView as? NSTextView,
              let storage = textView.textStorage as? SQLTextStorage
        else { return }
        if storage.string != text {
            storage.replaceCharacters(
                in: NSRange(location: 0, length: storage.length),
                with: text
            )
        }
    }
}

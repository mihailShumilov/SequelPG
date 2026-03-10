import AppKit

/// Custom NSTextStorage that applies SQL syntax highlighting via the SQLFormatter tokenizer.
final class SQLTextStorage: NSTextStorage {
    var onChange: ((String) -> Void)?

    /// Cached tokens from the last highlighting pass, available for external consumers
    /// (e.g., completion context checks) to avoid redundant tokenization.
    private(set) var lastTokens: [SQLFormatter.Token] = []

    private let backing = NSMutableAttributedString()
    private var isHighlighting = false
    private let monoFont = NSFont.monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)

    // MARK: - NSTextStorage Required Overrides

    override var string: String {
        backing.string
    }

    override func attributes(at location: Int, effectiveRange range: NSRangePointer?) -> [NSAttributedString.Key: Any] {
        backing.attributes(at: location, effectiveRange: range)
    }

    override func replaceCharacters(in range: NSRange, with str: String) {
        beginEditing()
        backing.replaceCharacters(in: range, with: str)
        edited(.editedCharacters, range: range, changeInLength: str.count - range.length)
        endEditing()
    }

    override func setAttributes(_ attrs: [NSAttributedString.Key: Any]?, range: NSRange) {
        beginEditing()
        backing.setAttributes(attrs, range: range)
        edited(.editedAttributes, range: range, changeInLength: 0)
        endEditing()
    }

    // MARK: - Highlighting

    override func processEditing() {
        let mask = editedMask
        super.processEditing()

        guard !isHighlighting else { return }
        isHighlighting = true
        defer { isHighlighting = false }
        applyHighlighting()

        if mask.contains(.editedCharacters) {
            onChange?(string)
        }
    }

    private func applyHighlighting() {
        let fullRange = NSRange(location: 0, length: length)
        guard fullRange.length > 0 else {
            lastTokens = []
            return
        }

        // Set font on the full range (not set per-token)
        addAttribute(.font, value: monoFont, range: fullRange)

        // Tokenize and apply colors per token
        let tokens = SQLFormatter.tokenize(string)
        lastTokens = tokens
        var offset = 0

        for token in tokens {
            let tokenLength = token.text.utf16.count
            guard offset + tokenLength <= fullRange.length else { break }
            let range = NSRange(location: offset, length: tokenLength)

            let color: NSColor
            switch token.kind {
            case .keyword:
                color = SQLSyntaxColors.keyword
            case .stringLiteral, .dollarQuoted:
                color = SQLSyntaxColors.string
            case .lineComment, .blockComment:
                color = SQLSyntaxColors.comment
            case .number:
                color = SQLSyntaxColors.number
            case .op:
                color = SQLSyntaxColors.op
            case .identifier, .quotedIdentifier:
                color = SQLSyntaxColors.identifier
            case .punctuation, .whitespace:
                color = SQLSyntaxColors.plain
            }

            addAttribute(.foregroundColor, value: color, range: range)
            offset += tokenLength
        }
    }
}

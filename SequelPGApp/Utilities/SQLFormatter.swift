import Foundation

/// A lightweight SQL formatter that uppercases keywords, adds line breaks
/// at clause boundaries, and applies consistent indentation.
/// Preserves string literals, quoted identifiers, dollar-quoted blocks,
/// and comments verbatim.
enum SQLFormatter {
    // MARK: - Token Types

    enum TokenKind {
        case keyword
        case identifier
        case quotedIdentifier
        case stringLiteral
        case dollarQuoted
        case lineComment
        case blockComment
        case number
        case punctuation
        case op
        case whitespace
    }

    struct Token {
        let kind: TokenKind
        let text: String
    }

    // MARK: - Keywords

    static let keywords: Set<String> = [
        "select", "from", "where", "and", "or", "not", "in", "exists",
        "between", "like", "ilike", "is", "null", "true", "false",
        "as", "on", "using", "case", "when", "then", "else", "end",
        "join", "inner", "left", "right", "full", "outer", "cross",
        "natural", "lateral",
        "group", "by", "order", "having", "limit", "offset", "fetch",
        "union", "intersect", "except", "all", "distinct",
        "insert", "into", "values", "update", "set", "delete",
        "create", "alter", "drop", "table", "index", "view",
        "if", "returning", "with", "recursive", "cascade", "restrict",
        "primary", "key", "foreign", "references", "constraint",
        "unique", "check", "default",
        "asc", "desc", "nulls", "first", "last",
        "begin", "commit", "rollback", "savepoint",
        "grant", "revoke", "explain", "analyze", "vacuum",
        "coalesce", "cast", "any", "some", "array",
        "over", "partition", "window", "rows", "range", "unbounded",
        "preceding", "following", "current", "row", "filter",
        "do", "nothing", "conflict", "excluded",
        "schema", "database", "type", "enum", "domain",
        "trigger", "function", "procedure", "returns", "language",
        "security", "definer", "invoker",
        "temporary", "temp", "unlogged", "materialized",
        "rename", "to", "add", "column",
        "truncate", "only", "nowait", "for", "share", "no",
    ]

    /// Clause-starting keywords that get a new line.
    private static let clauseKeywords: Set<String> = [
        "select", "from", "where", "having", "limit", "offset",
        "returning", "values", "set", "union", "intersect", "except",
        "insert", "update", "delete", "with",
    ]

    /// Keywords that get a newline with indentation.
    private static let indentedKeywords: Set<String> = [
        "join", "inner", "left", "right", "full", "cross", "natural",
        "on", "and", "or",
    ]

    /// Multi-word clause prefixes.
    private static let multiWordClauses: [(first: String, second: String)] = [
        ("order", "by"),
        ("group", "by"),
        ("partition", "by"),
        ("insert", "into"),
        ("delete", "from"),
    ]

    // MARK: - Public API

    static func format(_ sql: String) -> String {
        let trimmed = sql.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return sql }
        let tokens = tokenize(trimmed)
        return reconstruct(tokens)
    }

    // MARK: - Tokenizer

    static func tokenize(_ sql: String) -> [Token] {
        var tokens: [Token] = []
        var index = sql.startIndex

        while index < sql.endIndex {
            let c = sql[index]

            // Line comment: --
            if c == "-", nextChar(sql, after: index) == "-" {
                var end = sql.index(index, offsetBy: 2, limitedBy: sql.endIndex) ?? sql.endIndex
                while end < sql.endIndex, sql[end] != "\n" { end = sql.index(after: end) }
                tokens.append(Token(kind: .lineComment, text: String(sql[index ..< end])))
                index = end
                continue
            }

            // Block comment: /* ... */
            if c == "/", nextChar(sql, after: index) == "*" {
                var end = sql.index(index, offsetBy: 2, limitedBy: sql.endIndex) ?? sql.endIndex
                while end < sql.endIndex {
                    let next = sql.index(after: end)
                    if sql[end] == "*", next < sql.endIndex, sql[next] == "/" {
                        end = sql.index(after: next)
                        break
                    }
                    end = next
                }
                tokens.append(Token(kind: .blockComment, text: String(sql[index ..< end])))
                index = end
                continue
            }

            // String literal: '...'
            if c == "'" {
                var end = sql.index(after: index)
                while end < sql.endIndex {
                    if sql[end] == "'" {
                        let next = sql.index(after: end)
                        if next < sql.endIndex, sql[next] == "'" {
                            end = sql.index(after: next) // escaped ''
                        } else {
                            end = next
                            break
                        }
                    } else {
                        end = sql.index(after: end)
                    }
                }
                tokens.append(Token(kind: .stringLiteral, text: String(sql[index ..< end])))
                index = end
                continue
            }

            // Dollar-quoted string: $$...$$ or $tag$...$tag$
            if c == "$" {
                var tagEnd = sql.index(after: index)
                while tagEnd < sql.endIndex, sql[tagEnd].isLetter || sql[tagEnd].isNumber || sql[tagEnd] == "_" {
                    tagEnd = sql.index(after: tagEnd)
                }
                if tagEnd < sql.endIndex, sql[tagEnd] == "$" {
                    tagEnd = sql.index(after: tagEnd)
                    let tag = String(sql[index ..< tagEnd])
                    var end = tagEnd
                    while end < sql.endIndex {
                        if sql[end] == "$", sql[end...].hasPrefix(tag) {
                            end = sql.index(end, offsetBy: tag.count, limitedBy: sql.endIndex) ?? sql.endIndex
                            break
                        }
                        end = sql.index(after: end)
                    }
                    tokens.append(Token(kind: .dollarQuoted, text: String(sql[index ..< end])))
                    index = end
                    continue
                }
            }

            // Quoted identifier: "..."
            if c == "\"" {
                var end = sql.index(after: index)
                while end < sql.endIndex {
                    if sql[end] == "\"" {
                        let next = sql.index(after: end)
                        if next < sql.endIndex, sql[next] == "\"" {
                            end = sql.index(after: next) // escaped ""
                        } else {
                            end = next
                            break
                        }
                    } else {
                        end = sql.index(after: end)
                    }
                }
                tokens.append(Token(kind: .quotedIdentifier, text: String(sql[index ..< end])))
                index = end
                continue
            }

            // Whitespace
            if c.isWhitespace || c.isNewline {
                var end = sql.index(after: index)
                while end < sql.endIndex, sql[end].isWhitespace || sql[end].isNewline { end = sql.index(after: end) }
                tokens.append(Token(kind: .whitespace, text: String(sql[index ..< end])))
                index = end
                continue
            }

            // Number
            if c.isNumber || (c == "." && (nextChar(sql, after: index)?.isNumber ?? false)) {
                var end = sql.index(after: index)
                var hasDot = c == "."
                while end < sql.endIndex {
                    if sql[end].isNumber {
                        end = sql.index(after: end)
                    } else if sql[end] == ".", !hasDot {
                        hasDot = true
                        end = sql.index(after: end)
                    } else {
                        break
                    }
                }
                tokens.append(Token(kind: .number, text: String(sql[index ..< end])))
                index = end
                continue
            }

            // Word (keyword or identifier)
            if c.isLetter || c == "_" {
                var end = sql.index(after: index)
                while end < sql.endIndex, sql[end].isLetter || sql[end].isNumber || sql[end] == "_" {
                    end = sql.index(after: end)
                }
                let word = String(sql[index ..< end])
                let lower = word.lowercased()
                tokens.append(Token(
                    kind: keywords.contains(lower) ? .keyword : .identifier,
                    text: word
                ))
                index = end
                continue
            }

            // Punctuation
            if "(),;.".contains(c) {
                tokens.append(Token(kind: .punctuation, text: String(c)))
                index = sql.index(after: index)
                continue
            }

            // Operators
            let opChars: Set<Character> = ["=", "<", ">", "!", "+", "-", "*", "/", "%", "~", "@", "#", "&", "|", "^", ":"]
            if opChars.contains(c) {
                var end = sql.index(after: index)
                while end < sql.endIndex, opChars.contains(sql[end]) { end = sql.index(after: end) }
                tokens.append(Token(kind: .op, text: String(sql[index ..< end])))
                index = end
                continue
            }

            // Fallback
            tokens.append(Token(kind: .punctuation, text: String(c)))
            index = sql.index(after: index)
        }

        return tokens
    }

    // MARK: - Reconstructor

    private static func reconstruct(_ tokens: [Token]) -> String {
        var output = ""
        let indent = "    "
        var depth = 0
        var prevKeyword = ""
        var isFirstClause = true

        // Collect non-whitespace tokens
        let meaningful = tokens.filter { $0.kind != .whitespace }

        for (mi, token) in meaningful.enumerated() {
            let nextToken: Token? = mi + 1 < meaningful.count ? meaningful[mi + 1] : nil

            switch token.kind {
            case .keyword:
                let lower = token.text.lowercased()
                let upper = token.text.uppercased()

                let isMultiWordSecond = multiWordClauses.contains { $0.second == lower && prevKeyword == $0.first }

                if isMultiWordSecond {
                    output += " " + upper
                } else if clauseKeywords.contains(lower) || multiWordClauses.contains(where: { $0.first == lower }) {
                    if isFirstClause {
                        output += String(repeating: indent, count: depth) + upper
                        isFirstClause = false
                    } else {
                        output += "\n" + String(repeating: indent, count: depth) + upper
                    }
                } else if indentedKeywords.contains(lower) {
                    output += "\n" + String(repeating: indent, count: depth) + indent + upper
                } else {
                    appendSpaceIfNeeded(&output)
                    output += upper
                }
                prevKeyword = lower

            case .identifier, .quotedIdentifier, .stringLiteral, .dollarQuoted, .number:
                let text = token.kind == .identifier ? quoteIfNeeded(token.text) : token.text
                if !output.isEmpty, output.last == "." {
                    output += text
                } else {
                    appendSpaceIfNeeded(&output)
                    output += text
                }
                prevKeyword = ""

            case .punctuation:
                switch token.text {
                case "(":
                    appendSpaceIfNeeded(&output)
                    output += "("
                    depth += 1
                case ")":
                    depth = max(0, depth - 1)
                    output += ")"
                case ",":
                    output += ","
                case ";":
                    output += ";"
                    isFirstClause = true
                    depth = 0
                    prevKeyword = ""
                    if nextToken != nil {
                        output += "\n\n"
                    }
                case ".":
                    output += "."
                default:
                    output += token.text
                }
                if token.text != ";" { prevKeyword = "" }

            case .op:
                if token.text == "::" {
                    output += "::"
                } else {
                    appendSpaceIfNeeded(&output)
                    output += token.text
                }
                prevKeyword = ""

            case .lineComment:
                appendSpaceIfNeeded(&output)
                output += token.text
                if !token.text.hasSuffix("\n") {
                    output += "\n" + String(repeating: indent, count: depth)
                }

            case .blockComment:
                appendSpaceIfNeeded(&output)
                output += token.text

            case .whitespace:
                break
            }
        }

        return output.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Helpers

    private static func nextChar(_ s: String, after i: String.Index) -> Character? {
        let next = s.index(after: i)
        return next < s.endIndex ? s[next] : nil
    }

    private static func appendSpaceIfNeeded(_ output: inout String) {
        guard let last = output.last else { return }
        if last != " ", last != "\n", last != "(", last != "." {
            output += " "
        }
    }

    /// Wraps an identifier in double quotes if it contains uppercase letters,
    /// since PostgreSQL folds unquoted identifiers to lowercase.
    private static func quoteIfNeeded(_ identifier: String) -> String {
        guard identifier != identifier.lowercased() else { return identifier }
        return quoteIdent(identifier)
    }
}

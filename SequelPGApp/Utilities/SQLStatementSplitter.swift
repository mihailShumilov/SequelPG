import Foundation

/// Splits an editor buffer into individual SQL statements the way `psql`
/// does, so "Run" can execute a script one statement at a time over the
/// extended query protocol (which accepts only one statement per call).
///
/// Semicolons inside string literals (`'…'`, `E'…'`), quoted identifiers,
/// dollar-quoted bodies (`$$…$$`, `$tag$…$tag$`), line and nested block
/// comments, and SQL-standard routine bodies (`BEGIN ATOMIC … END`) do not
/// end a statement. Statements that are empty or only comments are dropped.
enum SQLStatementSplitter {
    static func split(_ sql: String) -> [String] {
        let chars = Array(sql.unicodeScalars)
        var statements: [String] = []
        var start = 0
        var i = 0
        // BEGIN/CASE … END nesting, tracked only inside CREATE FUNCTION /
        // PROCEDURE statements (where BEGIN ATOMIC bodies contain semicolons).
        var blockDepth = 0
        var words: [String] = []
        var hasCode = false

        func flush(upTo end: Int) {
            if hasCode {
                let text = String(String.UnicodeScalarView(chars[start ..< end]))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty { statements.append(text) }
            }
            start = end + 1
            blockDepth = 0
            words.removeAll()
            hasCode = false
        }

        var isRoutineDefinition: Bool {
            guard words.first == "CREATE" else { return false }
            return words.prefix(6).contains("FUNCTION") || words.prefix(6).contains("PROCEDURE")
        }

        while i < chars.count {
            let c = chars[i]
            let next: Unicode.Scalar? = i + 1 < chars.count ? chars[i + 1] : nil

            // Comments.
            if c == "-", next == "-" {
                while i < chars.count, chars[i] != "\n" { i += 1 }
                continue
            }
            if c == "/", next == "*" {
                var depth = 1
                i += 2
                while i < chars.count, depth > 0 {
                    if chars[i] == "/", i + 1 < chars.count, chars[i + 1] == "*" {
                        depth += 1
                        i += 2
                    } else if chars[i] == "*", i + 1 < chars.count, chars[i + 1] == "/" {
                        depth -= 1
                        i += 2
                    } else {
                        i += 1
                    }
                }
                continue
            }

            if c == ";" {
                if blockDepth > 0 {
                    i += 1
                    continue
                }
                flush(upTo: i)
                i += 1
                continue
            }

            if !c.properties.isWhitespace { hasCode = true }

            // String literals. E'…' honors backslash escapes; '' is an escaped quote.
            if c == "'" {
                let escapes = i > 0 && (chars[i - 1] == "E" || chars[i - 1] == "e")
                    && (i < 2 || !isIdentifierChar(chars[i - 2]))
                i += 1
                while i < chars.count {
                    if escapes, chars[i] == "\\" {
                        i += 2
                        continue
                    }
                    if chars[i] == "'" {
                        if i + 1 < chars.count, chars[i + 1] == "'" {
                            i += 2
                            continue
                        }
                        break
                    }
                    i += 1
                }
                i += 1
                continue
            }

            // Quoted identifiers.
            if c == "\"" {
                i += 1
                while i < chars.count {
                    if chars[i] == "\"" {
                        if i + 1 < chars.count, chars[i + 1] == "\"" {
                            i += 2
                            continue
                        }
                        break
                    }
                    i += 1
                }
                i += 1
                continue
            }

            // Dollar quotes: $$ or $tag$ (tag = identifier not starting with a digit).
            if c == "$", i == 0 || !isIdentifierChar(chars[i - 1]) {
                var j = i + 1
                while j < chars.count, isIdentifierChar(chars[j]), chars[j] != "$" { j += 1 }
                let tagIsValid = j == i + 1 || !("0" ... "9").contains(chars[i + 1])
                if j < chars.count, chars[j] == "$", tagIsValid {
                    let tag = Array(chars[i ... j])
                    var k = j + 1
                    var closed = false
                    while k + tag.count <= chars.count {
                        if chars[k] == "$", Array(chars[k ..< k + tag.count]) == tag {
                            closed = true
                            break
                        }
                        k += 1
                    }
                    i = closed ? k + tag.count : chars.count
                    continue
                }
            }

            // Words: track the statement head and BEGIN/CASE … END nesting.
            if isIdentifierStart(c), i == 0 || !isIdentifierChar(chars[i - 1]) {
                var j = i
                while j < chars.count, isIdentifierChar(chars[j]) { j += 1 }
                let word = String(String.UnicodeScalarView(chars[i ..< j])).uppercased()
                if words.count < 8 { words.append(word) }
                if isRoutineDefinition {
                    if word == "BEGIN" || word == "CASE" {
                        blockDepth += 1
                    } else if word == "END", blockDepth > 0 {
                        blockDepth -= 1
                    }
                }
                i = j
                continue
            }

            i += 1
        }
        flush(upTo: chars.count)
        return statements
    }

    private static func isIdentifierStart(_ c: Unicode.Scalar) -> Bool {
        c == "_" || c.properties.isAlphabetic
    }

    private static func isIdentifierChar(_ c: Unicode.Scalar) -> Bool {
        c == "_" || c == "$" || c.properties.isAlphabetic || ("0" ... "9").contains(c)
    }
}

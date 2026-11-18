import Foundation

/// Checks SQL handed to `runReadOnlyQuery` (the MCP server's query path)
/// before it reaches the server.
///
/// Two layers keep MCP queries from changing anything:
/// - this guard admits exactly one statement whose leading keyword is on an
///   allowlist of query statements (`SELECT`, `WITH`, `VALUES`, `TABLE`,
///   `SHOW`, `EXPLAIN`). Everything else — `DO`, `CALL`, `COPY`, `LOAD`,
///   `SET`, transaction control, maintenance commands such as `CLUSTER` or
///   `REINDEX` that a read-only transaction still allows — is refused;
/// - the statement runs in a `READ ONLY` transaction that is always rolled
///   back, which refuses data-modifying CTEs and other writes.
///
/// Neither is a sandbox for functions with side effects
/// (`pg_terminate_backend`, `dblink_exec`, `lo_export`, …). The MCP server
/// therefore also refuses roles with superuser or server file/program
/// privileges, and a role with only the needed privileges is the
/// dependable boundary.
enum ReadOnlySQLGuard {
    /// Leading keywords that are accepted.
    static let allowedKeywords: Set<String> = ["SELECT", "WITH", "VALUES", "TABLE", "SHOW", "EXPLAIN"]

    /// Returns the single statement in `sql`, or throws why it can't run.
    static func validate(_ sql: String) throws -> String {
        let statements = SQLStatementSplitter.split(sql)
        guard let statement = statements.first else {
            throw AppError.validationFailed(["There is no SQL statement to run."])
        }
        guard statements.count == 1 else {
            throw AppError.validationFailed([
                "Run one statement at a time (got \(statements.count)).",
            ])
        }
        guard let keyword = leadingKeyword(of: statement), allowedKeywords.contains(keyword) else {
            let shown = leadingKeyword(of: statement) ?? "This"
            throw AppError.validationFailed([
                "\(shown) statements are not allowed. Only SELECT, WITH, VALUES, TABLE, SHOW and EXPLAIN run, "
                    + "in a read-only transaction.",
            ])
        }
        return statement
    }

    /// PostgreSQL's whitespace (space, tab, LF, CR, FF, VT). Other Unicode
    /// spaces are identifier characters to PostgreSQL, not separators.
    private static let pgWhitespace: Set<Unicode.Scalar> = [" ", "\t", "\n", "\r", "\u{0C}", "\u{0B}"]

    /// The first keyword of `statement`, uppercased, after leading
    /// whitespace, comments and opening parentheses.
    static func leadingKeyword(of statement: String) -> String? {
        let scalars = Array(statement.unicodeScalars)
        var index = 0
        while index < scalars.count {
            let c = scalars[index]
            if pgWhitespace.contains(c) || c == "(" {
                index += 1
            } else if c == "-", index + 1 < scalars.count, scalars[index + 1] == "-" {
                // PostgreSQL ends a line comment at CR as well as LF.
                while index < scalars.count, scalars[index] != "\n", scalars[index] != "\r" {
                    index += 1
                }
            } else if c == "/", index + 1 < scalars.count, scalars[index + 1] == "*" {
                // Block comments nest in PostgreSQL.
                var depth = 0
                while index < scalars.count {
                    if scalars[index] == "/", index + 1 < scalars.count, scalars[index + 1] == "*" {
                        depth += 1
                        index += 2
                    } else if scalars[index] == "*", index + 1 < scalars.count, scalars[index + 1] == "/" {
                        depth -= 1
                        index += 2
                        if depth == 0 { break }
                    } else {
                        index += 1
                    }
                }
            } else {
                break
            }
        }
        var word = ""
        while index < scalars.count, CharacterSet.letters.contains(scalars[index]) || scalars[index] == "_" {
            word.unicodeScalars.append(scalars[index])
            index += 1
        }
        return word.isEmpty ? nil : word.uppercased()
    }
}

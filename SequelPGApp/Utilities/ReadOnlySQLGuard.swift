import Foundation

/// Checks SQL handed to `runReadOnlyQuery` (the MCP server's query path)
/// before it reaches the server.
///
/// The real guarantee is the `READ ONLY` transaction that is always rolled
/// back. This guard closes the gaps that transaction leaves open:
/// - several statements, or transaction control, could end the read-only
///   transaction and run later statements outside it;
/// - `COPY … TO` (including `TO PROGRAM`) is allowed in a read-only
///   transaction and can write server files or run commands as the server;
/// - `LOAD`, `CHECKPOINT`, `SET`/`RESET`/`DISCARD` and `PREPARE TRANSACTION`
///   change server or session state outside the transaction's data.
///
/// It is not a sandbox: functions with side effects (`pg_terminate_backend`,
/// `dblink_exec`, `lo_export`, …) still run. A database role with only the
/// needed privileges is the dependable boundary.
enum ReadOnlySQLGuard {
    /// Leading keywords that are refused.
    static let blockedKeywords: Set<String> = [
        "BEGIN", "START", "COMMIT", "END", "ROLLBACK", "ABORT", "SAVEPOINT", "RELEASE", "PREPARE",
        "COPY", "LOAD", "CHECKPOINT", "SET", "RESET", "DISCARD", "LISTEN", "UNLISTEN", "NOTIFY",
        "VACUUM", "LOCK",
    ]

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
        if let keyword = leadingKeyword(of: statement), blockedKeywords.contains(keyword) {
            throw AppError.validationFailed([
                "\(keyword) statements are not allowed: queries run in a read-only transaction.",
            ])
        }
        return statement
    }

    /// The first keyword of `statement`, uppercased, after leading
    /// whitespace, comments and opening parentheses.
    static func leadingKeyword(of statement: String) -> String? {
        let scalars = Array(statement.unicodeScalars)
        var index = 0
        while index < scalars.count {
            let c = scalars[index]
            if CharacterSet.whitespacesAndNewlines.contains(c) || c == "(" {
                index += 1
            } else if c == "-", index + 1 < scalars.count, scalars[index + 1] == "-" {
                while index < scalars.count, scalars[index] != "\n" {
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

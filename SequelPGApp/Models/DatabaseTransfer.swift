import Foundation

/// The effective network endpoint a child process (`pg_dump` / `psql`) should
/// dial to reach the active connection. For SSH-tunneled profiles this is the
/// loopback forwarding port owned by `DatabaseClient`, not the remote server —
/// so it must be read from the live client rather than the saved profile.
struct PGConnectionEndpoint: Sendable, Equatable {
    var host: String
    var port: Int
}

/// One line of streamed tool output. The `id` is a monotonic counter assigned
/// when the line is appended, so trimming the front of the progress buffer
/// never reshuffles ids — SwiftUI sees one insertion (and at most one removal)
/// per line instead of re-diffing the whole window.
struct ProgressLine: Identifiable, Sendable, Equatable {
    let id: Int
    let text: String
}

/// Everything a PostgreSQL client binary needs to connect, gathered from the
/// live connection. Kept separate from `ConnectionProfile` so the argument
/// builders can be exercised in tests without constructing a full profile.
struct PGToolConnection: Sendable, Equatable {
    var host: String
    var port: Int
    var database: String
    var username: String
    var sslMode: SSLMode

    /// The value `pg_dump`/`psql` expect in `PGSSLMODE`.
    var pgSSLMode: String {
        switch sslMode {
        case .off: return "disable"
        case .prefer: return "prefer"
        case .require: return "require"
        case .verifyCa: return "verify-ca"
        case .verifyFull: return "verify-full"
        }
    }
}

/// `pg_dump` output format (`-F`). Plain produces a SQL script restorable with
/// `psql`; the others are archives restored with `pg_restore`.
enum ExportFormat: String, CaseIterable, Identifiable, Sendable {
    case plain
    case custom
    case directory
    case tar

    var id: String { rawValue }

    /// The single-letter argument passed to `pg_dump -F`.
    var flag: String {
        switch self {
        case .plain: return "p"
        case .custom: return "c"
        case .directory: return "d"
        case .tar: return "t"
        }
    }

    var displayName: String {
        switch self {
        case .plain: return "Plain SQL"
        case .custom: return "Custom (compressed)"
        case .directory: return "Directory"
        case .tar: return "Tar archive"
        }
    }

    var detail: String {
        switch self {
        case .plain: return "A .sql script. Re-import with this app's “Import SQL File”."
        case .custom: return "Compressed archive. Selective, parallel restore with pg_restore."
        case .directory: return "One file per table in a folder. Supports parallel restore."
        case .tar: return "A tar archive restorable with pg_restore."
        }
    }

    /// Default file extension for the save panel, or `nil` for directory format
    /// (the target is a folder `pg_dump` creates).
    var fileExtension: String? {
        switch self {
        case .plain: return "sql"
        case .custom: return "dump"
        case .tar: return "tar"
        case .directory: return nil
        }
    }

    /// Plain dumps are SQL scripts; the rest are archives needing `pg_restore`.
    var isPlainSQL: Bool { self == .plain }

    /// Only the archive formats accept a `-Z` compression level.
    var supportsCompression: Bool { self == .custom || self == .directory }
}

/// Which part of the database to dump.
enum ExportContent: String, CaseIterable, Identifiable, Sendable {
    case all
    case schemaOnly
    case dataOnly

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .all: return "Schema + data"
        case .schemaOnly: return "Schema only"
        case .dataOnly: return "Data only"
        }
    }

    /// The `pg_dump` flag, or `nil` for a full dump.
    var flag: String? {
        switch self {
        case .all: return nil
        case .schemaOnly: return "--schema-only"
        case .dataOnly: return "--data-only"
        }
    }
}

/// All `pg_dump` options the export sheet exposes. Renders itself into a
/// `pg_dump` argument vector so the (security-sensitive) command construction is
/// unit-testable without a live database — mirroring `CascadeDeleteBuilder`.
struct ExportOptions: Sendable, Equatable {
    var format: ExportFormat = .plain
    var content: ExportContent = .all

    // Object selection. Empty `selectedSchemas` means "all schemas".
    var selectedSchemas: [String] = []
    var excludedSchemas: [String] = []
    var includeTables: [String] = []
    var excludeTables: [String] = []

    // Ownership & privileges
    var noOwner = false
    var noPrivileges = false

    // DROP / CREATE preamble
    var clean = false
    var ifExists = false
    var createDatabase = false

    // Data representation (portable, slower restores)
    var useInserts = false
    var useColumnInserts = false

    // Miscellaneous
    var noComments = false
    var includeLargeObjects = true
    var quoteAllIdentifiers = false
    var noTablespaces = false
    var compressionLevel = 0 // 0 = pg_dump default; only used for archive formats
    var encoding = "" // empty = server default
    var verbose = true // surfaces per-object progress on stderr

    /// Builds the complete `pg_dump` argument vector (the executable path is
    /// supplied separately). The password and SSL mode are passed via the
    /// environment by `DatabaseTransferService`, never on the command line.
    ///
    /// Every value-bearing option uses the `--name=value` long form. A bare
    /// `--name value` pair would let a value that begins with `-` (e.g. an
    /// unusually named schema coming from the database) be re-parsed by
    /// `pg_dump`'s `getopt_long` as another flag; the `=` form forecloses that.
    func arguments(connection: PGToolConnection, outputPath: String) -> [String] {
        var args: [String] = [
            "--host=\(connection.host)",
            "--port=\(connection.port)",
            "--username=\(connection.username)",
            "--no-password", // never prompt for a password (no controlling tty here)
            "--format=\(format.flag)",
        ]

        if let contentFlag = content.flag {
            args.append(contentFlag)
        }

        for schema in selectedSchemas { args.append("--schema=\(schema)") }
        for schema in excludedSchemas { args.append("--exclude-schema=\(schema)") }
        for table in includeTables { args.append("--table=\(table)") }
        for table in excludeTables { args.append("--exclude-table=\(table)") }

        if noOwner { args.append("--no-owner") }
        if noPrivileges { args.append("--no-privileges") }

        // `--if-exists` only has meaning together with `--clean`; the UI gates
        // the toggle the same way.
        if clean { args.append("--clean") }
        if clean, ifExists { args.append("--if-exists") }
        if createDatabase { args.append("--create") }

        // `--column-inserts` implies `--inserts`; don't pass both.
        if useColumnInserts {
            args.append("--column-inserts")
        } else if useInserts {
            args.append("--inserts")
        }

        if noComments { args.append("--no-comments") }
        if !includeLargeObjects { args.append("--no-large-objects") }
        if quoteAllIdentifiers { args.append("--quote-all-identifiers") }
        if noTablespaces { args.append("--no-tablespaces") }
        if format.supportsCompression, compressionLevel > 0 {
            args.append("--compress=\(compressionLevel)")
        }
        if !encoding.isEmpty { args.append("--encoding=\(encoding)") }
        if verbose { args.append("--verbose") }

        args.append("--file=\(outputPath)")
        args.append("--dbname=\(connection.database)")
        return args
    }
}

/// Per-import behaviour for running a `.sql` file through `psql`. Recreated for
/// every import (never persisted) so the user chooses safety semantics each time.
struct ImportOptions: Sendable, Equatable {
    /// Wrap the whole file in one transaction (`--single-transaction`): any
    /// error rolls everything back.
    var singleTransaction = true
    /// Abort on the first error (`ON_ERROR_STOP=1`) instead of continuing.
    var stopOnError = true

    /// Builds the complete `psql` argument vector. Password/SSL go via the
    /// environment, set by `DatabaseTransferService`. Value-bearing options use
    /// the `--name=value` long form so a value beginning with `-` cannot be
    /// re-parsed as a flag.
    func arguments(connection: PGToolConnection, inputPath: String) -> [String] {
        var args: [String] = [
            "--host=\(connection.host)",
            "--port=\(connection.port)",
            "--username=\(connection.username)",
            "--no-password", // never prompt for a password
            "--no-psqlrc", // ignore ~/.psqlrc so imports are reproducible
            "--dbname=\(connection.database)",
        ]

        if singleTransaction { args.append("--single-transaction") }
        if stopOnError { args.append("--set=ON_ERROR_STOP=1") }

        args.append("--file=\(inputPath)")
        return args
    }
}

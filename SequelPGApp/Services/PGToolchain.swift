import Foundation
import OSLog

/// A PostgreSQL client binary the app shells out to.
enum PGTool: String, Sendable {
    case pgDump = "pg_dump"
    case psql
}

/// Locates the PostgreSQL client binaries (`pg_dump` / `psql`) on the host.
///
/// The app is intentionally non-sandboxed (see `SequelPGApp.entitlements`), so
/// it can exec these directly — the same mechanism `SSHTunnelService` uses for
/// `/usr/bin/ssh`. The binaries are not bundled because they must match the
/// server's major version; instead we discover the user's existing install.
///
/// Search order: a directory the user set in Settings, then the common install
/// locations for Homebrew (arm64 and x86_64, including the keg-only `libpq` and
/// versioned `postgresql@N` formulae), Postgres.app and the EDB installer, then
/// whatever is already on `$PATH`.
///
/// Note: the keg-only locations matter because a GUI app launched from Finder
/// inherits `launchd`'s minimal `$PATH` — not the shell `$PATH` — and keg-only
/// formulae like `libpq` are never symlinked into `<prefix>/bin`, so relying on
/// `$PATH` alone would miss an otherwise valid `brew install libpq`.
enum PGToolchain {
    static let configuredDirectoryKey = "com.sequelpg.pgToolsDirectory"

    /// User-chosen directory containing the client binaries, or `nil` to rely
    /// on auto-detection. Persisted in `UserDefaults`.
    static var configuredDirectory: String? {
        get {
            let value = UserDefaults.standard.string(forKey: configuredDirectoryKey)?
                .trimmingCharacters(in: .whitespaces)
            return (value?.isEmpty ?? true) ? nil : value
        }
        set {
            let trimmed = newValue?.trimmingCharacters(in: .whitespaces)
            if let trimmed, !trimmed.isEmpty {
                UserDefaults.standard.set(trimmed, forKey: configuredDirectoryKey)
            } else {
                UserDefaults.standard.removeObject(forKey: configuredDirectoryKey)
            }
        }
    }

    /// Candidate `bin` directories in priority order, configured one first.
    static func searchDirectories() -> [String] {
        var dirs: [String] = []

        if let configured = configuredDirectory {
            dirs.append((configured as NSString).expandingTildeInPath)
        }

        // Homebrew default prefixes.
        dirs.append("/opt/homebrew/bin") // Apple Silicon
        dirs.append("/usr/local/bin") // Intel / older installs

        // `libpq` is the client-only keg the app recommends (`brew install
        // libpq`). Being keg-only, it is never symlinked into <prefix>/bin, so
        // include its well-known location for both prefixes unconditionally.
        dirs.append("/opt/homebrew/opt/libpq/bin")
        dirs.append("/usr/local/opt/libpq/bin")

        // A full `postgresql@N` keg also ships the client tools but likewise
        // isn't linked into <prefix>/bin; discover installed ones, newest first.
        dirs += homebrewPostgresKegBinDirectories()

        // Postgres.app keeps each major version under Versions/<n>/bin; prefer
        // the highest version number, with the "latest" symlink as a fallback.
        dirs += versionedBinDirectories(
            base: "/Applications/Postgres.app/Contents/Versions",
            fallbackSymlink: "latest"
        )

        // EDB / BigSQL installer layout: /Library/PostgreSQL/<n>/bin.
        dirs += versionedBinDirectories(base: "/Library/PostgreSQL", fallbackSymlink: nil)

        // Anything already on the inherited PATH.
        if let path = ProcessInfo.processInfo.environment["PATH"] {
            dirs += path.split(separator: ":").map(String.init)
        }

        // De-duplicate while preserving order.
        var seen = Set<String>()
        return dirs.filter { seen.insert($0).inserted }
    }

    /// Absolute path to `tool`, or `nil` when it can't be found.
    static func locate(_ tool: PGTool) -> String? {
        let fm = FileManager.default
        for dir in searchDirectories() {
            let candidate = (dir as NSString).appendingPathComponent(tool.rawValue)
            if fm.isExecutableFile(atPath: candidate) {
                return candidate
            }
        }
        return nil
    }

    /// Runs `<tool> --version` and returns its trimmed output (e.g.
    /// "pg_dump (PostgreSQL) 16.2"), or `nil` if the tool is missing or errors.
    /// Synchronous and quick; call it off the main actor.
    static func version(of tool: PGTool) -> String? {
        guard let path = locate(tool) else { return nil }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = ["--version"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            Log.app.error("Failed to probe \(tool.rawValue, privacy: .public) version: \(error.localizedDescription)")
            return nil
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let output = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (output?.isEmpty ?? true) ? nil : output
    }

    // MARK: - Private

    /// Bin directories of any keg-only `postgresql` / `postgresql@N` formulae
    /// found under each Homebrew prefix's `opt`, sorted newest major first.
    private static func homebrewPostgresKegBinDirectories() -> [String] {
        let fm = FileManager.default
        var result: [String] = []

        for prefix in ["/opt/homebrew", "/usr/local"] {
            let optDir = "\(prefix)/opt"
            guard let entries = try? fm.contentsOfDirectory(atPath: optDir) else { continue }
            let kegs = entries
                .filter { $0 == "postgresql" || $0.hasPrefix("postgresql@") }
                .sorted { postgresMajor($0) > postgresMajor($1) }
            result += kegs.map { "\(optDir)/\($0)/bin" }
        }
        return result
    }

    /// Major version encoded in a `postgresql@N` keg name; unversioned
    /// `postgresql` sorts first as it tracks the current release.
    private static func postgresMajor(_ formula: String) -> Int {
        guard let at = formula.firstIndex(of: "@") else { return .max }
        return Int(formula[formula.index(after: at)...]) ?? 0
    }

    /// Returns `<base>/<version>/bin` directories sorted newest-version first,
    /// optionally appending `<base>/<fallbackSymlink>/bin`.
    private static func versionedBinDirectories(base: String, fallbackSymlink: String?) -> [String] {
        let fm = FileManager.default
        var result: [String] = []

        if let entries = try? fm.contentsOfDirectory(atPath: base) {
            // Numeric-aware descending sort so "16" beats "9" and "10".
            let versions = entries
                .filter { Int($0) != nil }
                .sorted { (Int($0) ?? 0) > (Int($1) ?? 0) }
            for version in versions {
                result.append("\(base)/\(version)/bin")
            }
        }

        if let fallbackSymlink {
            result.append("\(base)/\(fallbackSymlink)/bin")
        }
        return result
    }
}

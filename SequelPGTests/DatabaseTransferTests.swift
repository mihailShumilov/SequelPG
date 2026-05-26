import XCTest
@testable import SequelPG

/// Unit tests for the export/import command builders and the toolchain locator.
/// Pure logic — no live database or child process is spawned (mirrors the
/// project's mock-only testing approach).
final class DatabaseTransferTests: XCTestCase {
    private let connection = PGToolConnection(
        host: "db.example.com",
        port: 6432,
        database: "shop",
        username: "alice",
        sslMode: .require
    )

    // MARK: - pg_dump arguments

    func testExportDefaultArguments() {
        let args = ExportOptions().arguments(connection: connection, outputPath: "/tmp/out.sql")

        // Connection options always present, password never on the command line.
        XCTAssertTrue(args.contains("--host=db.example.com"))
        XCTAssertTrue(args.contains("--port=6432"))
        XCTAssertTrue(args.contains("--username=alice"))
        XCTAssertTrue(args.contains("--dbname=shop"))
        XCTAssertTrue(args.contains("--no-password"))
        XCTAssertFalse(args.contains("-W"))
        XCTAssertFalse(args.contains { $0.hasPrefix("--password") })

        // Default format is plain, full contents, verbose on, output set.
        XCTAssertTrue(args.contains("--format=p"))
        XCTAssertTrue(args.contains("--file=/tmp/out.sql"))
        XCTAssertTrue(args.contains("--verbose"))
        XCTAssertFalse(args.contains("--schema-only"))
        XCTAssertFalse(args.contains("--data-only"))
    }

    func testExportContentFlags() {
        var schemaOnly = ExportOptions()
        schemaOnly.content = .schemaOnly
        XCTAssertTrue(schemaOnly.arguments(connection: connection, outputPath: "/x").contains("--schema-only"))

        var dataOnly = ExportOptions()
        dataOnly.content = .dataOnly
        XCTAssertTrue(dataOnly.arguments(connection: connection, outputPath: "/x").contains("--data-only"))
    }

    func testExportSchemaAndTableSelection() {
        var options = ExportOptions()
        options.selectedSchemas = ["public", "auth"]
        options.excludedSchemas = ["temp"]
        options.includeTables = ["users"]
        options.excludeTables = ["audit_log"]
        let args = options.arguments(connection: connection, outputPath: "/x")

        XCTAssertEqual(args.filter { $0.hasPrefix("--schema=") }.count, 2)
        XCTAssertTrue(args.contains("--schema=public"))
        XCTAssertTrue(args.contains("--schema=auth"))
        XCTAssertTrue(args.contains("--exclude-schema=temp"))
        XCTAssertTrue(args.contains("--table=users"))
        XCTAssertTrue(args.contains("--exclude-table=audit_log"))
    }

    /// A schema/table name beginning with "-" must stay attached to its option
    /// via "=" so pg_dump's getopt_long can't re-parse it as a flag.
    func testExportDashPrefixedIdentifierIsNotParsedAsFlag() {
        var options = ExportOptions()
        options.selectedSchemas = ["-n"]
        let args = options.arguments(connection: connection, outputPath: "/x")
        XCTAssertTrue(args.contains("--schema=-n"))
        // The dangerous bare-pair form must never appear.
        XCTAssertFalse(consecutive(args, "--schema", "-n"))
    }

    func testExportOwnershipAndPrivilegeFlags() {
        var options = ExportOptions()
        options.noOwner = true
        options.noPrivileges = true
        let args = options.arguments(connection: connection, outputPath: "/x")
        XCTAssertTrue(args.contains("--no-owner"))
        XCTAssertTrue(args.contains("--no-privileges"))
    }

    func testExportIfExistsRequiresClean() {
        // --if-exists alone (no --clean) emits nothing; the UI gates it the same way.
        var withoutClean = ExportOptions()
        withoutClean.ifExists = true
        let a = withoutClean.arguments(connection: connection, outputPath: "/x")
        XCTAssertFalse(a.contains("--if-exists"))
        XCTAssertFalse(a.contains("--clean"))

        // With --clean, both flags appear.
        var withClean = ExportOptions()
        withClean.clean = true
        withClean.ifExists = true
        let b = withClean.arguments(connection: connection, outputPath: "/x")
        XCTAssertTrue(b.contains("--clean"))
        XCTAssertTrue(b.contains("--if-exists"))
    }

    func testExportSchemaNameWithSpaceIsOneArgument() {
        var options = ExportOptions()
        options.selectedSchemas = ["my schema"]
        let args = options.arguments(connection: connection, outputPath: "/x")
        // A name with whitespace must remain a single argv element, not split.
        XCTAssertTrue(args.contains("--schema=my schema"))
        XCTAssertEqual(args.filter { $0 == "--schema=my schema" }.count, 1)
    }

    func testExportColumnInsertsDoesNotAlsoEmitInserts() {
        var options = ExportOptions()
        options.useInserts = true
        options.useColumnInserts = true
        let args = options.arguments(connection: connection, outputPath: "/x")
        XCTAssertTrue(args.contains("--column-inserts"))
        XCTAssertFalse(args.contains("--inserts"), "--column-inserts already implies --inserts")
    }

    func testExportCompressionOnlyForArchiveFormats() {
        var plain = ExportOptions()
        plain.format = .plain
        plain.compressionLevel = 5
        XCTAssertFalse(plain.arguments(connection: connection, outputPath: "/x").contains { $0.hasPrefix("--compress=") })

        var custom = ExportOptions()
        custom.format = .custom
        custom.compressionLevel = 5
        XCTAssertTrue(custom.arguments(connection: connection, outputPath: "/x").contains("--compress=5"))
    }

    func testExportEncodingAndLargeObjects() {
        var options = ExportOptions()
        options.encoding = "UTF8"
        options.includeLargeObjects = false
        let args = options.arguments(connection: connection, outputPath: "/x")
        XCTAssertTrue(args.contains("--encoding=UTF8"))
        XCTAssertTrue(args.contains("--no-large-objects"))
    }

    // MARK: - psql arguments

    func testImportDefaultArguments() {
        let args = ImportOptions().arguments(connection: connection, inputPath: "/tmp/in.sql")
        XCTAssertTrue(args.contains("--host=db.example.com"))
        XCTAssertTrue(args.contains("--dbname=shop"))
        XCTAssertTrue(args.contains("--file=/tmp/in.sql"))
        XCTAssertTrue(args.contains("--no-password"))
        XCTAssertTrue(args.contains("--no-psqlrc"))
        XCTAssertTrue(args.contains("--single-transaction"))
        XCTAssertTrue(args.contains("--set=ON_ERROR_STOP=1"))
    }

    func testImportWithoutSafetyFlags() {
        var options = ImportOptions()
        options.singleTransaction = false
        options.stopOnError = false
        let args = options.arguments(connection: connection, inputPath: "/tmp/in.sql")
        XCTAssertFalse(args.contains("--single-transaction"))
        XCTAssertFalse(args.contains { $0.contains("ON_ERROR_STOP") })
    }

    func testPGSSLModeMapping() {
        XCTAssertEqual(endpointSSL(.off), "disable")
        XCTAssertEqual(endpointSSL(.prefer), "prefer")
        XCTAssertEqual(endpointSSL(.require), "require")
        XCTAssertEqual(endpointSSL(.verifyCa), "verify-ca")
        XCTAssertEqual(endpointSSL(.verifyFull), "verify-full")
    }

    // MARK: - Toolchain

    func testConfiguredDirectoryIsSearchedFirst() {
        let previous = PGToolchain.configuredDirectory
        defer { PGToolchain.configuredDirectory = previous }

        let temp = NSTemporaryDirectory()
        PGToolchain.configuredDirectory = temp
        XCTAssertEqual(PGToolchain.searchDirectories().first, (temp as NSString).expandingTildeInPath)
    }

    func testKegOnlyLibpqDirectoriesAreSearched() {
        let previous = PGToolchain.configuredDirectory
        defer { PGToolchain.configuredDirectory = previous }
        PGToolchain.configuredDirectory = nil

        // Keg-only `libpq` is never symlinked into <prefix>/bin and a GUI app
        // doesn't inherit the shell $PATH, so its opt location must be searched
        // explicitly — otherwise `brew install libpq` goes undetected.
        let dirs = PGToolchain.searchDirectories()
        XCTAssertTrue(dirs.contains("/opt/homebrew/opt/libpq/bin"))
        XCTAssertTrue(dirs.contains("/usr/local/opt/libpq/bin"))
    }

    func testLocateFindsExecutableInConfiguredDirectory() throws {
        let previous = PGToolchain.configuredDirectory
        defer { PGToolchain.configuredDirectory = previous }

        // A configured directory is searched first, so a fake executable placed
        // there must be found ahead of any real system install.
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("sequelpg-tools-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let toolURL = dir.appendingPathComponent("pg_dump")
        try "#!/bin/sh\n".write(to: toolURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: toolURL.path)

        PGToolchain.configuredDirectory = dir.path
        XCTAssertEqual(PGToolchain.locate(.pgDump), toolURL.path)
    }

    // MARK: - Helpers

    private func endpointSSL(_ mode: SSLMode) -> String {
        PGToolConnection(host: "h", port: 1, database: "d", username: "u", sslMode: mode).pgSSLMode
    }

    /// True if `value` directly follows some occurrence of `flag`.
    private func consecutive(_ args: [String], _ flag: String, _ value: String) -> Bool {
        for (index, element) in args.enumerated() where element == flag {
            if index + 1 < args.count, args[index + 1] == value { return true }
        }
        return false
    }
}

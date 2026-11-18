import XCTest
@testable import SequelPG

/// Database export (`pg_dump`) and SQL import (`psql`) through
/// `DatabaseTransferService` — real binaries against real servers.
final class TransferIntegrationTests: IntegrationTestCase {
    private var workDir: URL!

    override func setUp() async throws {
        try await super.setUp()
        workDir = FileManager.default.temporaryDirectory.appendingPathComponent("it-transfer-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: workDir)
        try await super.tearDown()
    }

    private func tool(_ tool: PGTool) throws -> String {
        guard let path = PGToolchain.locate(tool) else {
            throw XCTSkip("\(tool.rawValue) not installed (brew install libpq or postgresql@18)")
        }
        return path
    }

    private func connection(_ server: TestCluster.Server, database: String? = nil) -> PGToolConnection {
        PGToolConnection(
            host: TestCluster.host,
            port: TestCluster.port(server),
            database: database ?? TestCluster.database,
            username: TestCluster.user(.scram),
            sslMode: .prefer
        )
    }

    /// Drains a transfer stream, returning its output lines.
    @discardableResult
    private func drain(_ stream: AsyncThrowingStream<String, Error>) async throws -> [String] {
        var lines: [String] = []
        for try await line in stream {
            lines.append(line)
        }
        return lines
    }

    func testExportSchemaThenImportIntoFreshDatabaseOnEveryServer() async throws {
        let pgDump = try tool(.pgDump)
        let psql = try tool(.psql)
        for server in TestCluster.Server.allCases {
            let client = try await connect(server)
            let schema = try await makeScratchSchema(on: client)
            let s = quoteIdent(schema)
            try await client.exec("CREATE TABLE \(s).items (id int PRIMARY KEY, label text)")
            try await client.exec("INSERT INTO \(s).items VALUES (1, 'it''s'), (2, 'юникод'), (3, NULL)")

            let dump = workDir.appendingPathComponent("\(server).sql").path
            var options = ExportOptions()
            options.selectedSchemas = [schema]
            options.noOwner = true
            options.noPrivileges = true
            try await drain(DatabaseTransferService().export(
                options: options, connection: connection(server),
                password: TestCluster.password(.scram), toolPath: pgDump, outputPath: dump
            ))
            let sql = try String(contentsOfFile: dump, encoding: .utf8)
            XCTAssertTrue(sql.contains("CREATE TABLE \(schema).items") || sql.contains("CREATE TABLE \(s).items"), "\(server)")

            let target = "it_restore_" + UUID().uuidString.prefix(6).lowercased()
            try await client.exec("CREATE DATABASE \(quoteIdent(target))")
            addTeardownBlock { _ = try? await client.exec("DROP DATABASE IF EXISTS \(quoteIdent(target)) WITH (FORCE)") }

            do {
                try await drain(DatabaseTransferService().runImport(
                    options: ImportOptions(), connection: connection(server, database: target),
                    password: TestCluster.password(.scram), toolPath: psql, inputPath: dump
                ))
            } catch {
                XCTFail("\(server): import failed: \(message(of: error))")
                continue
            }

            let restored = try await connect(server, database: target)
            let rows = try await restored.exec("SELECT label FROM \(s).items ORDER BY id")
            XCTAssertEqual(rows.column("label"), ["it's", "юникод", nil], "\(server)")
            await restored.disconnect()
        }
    }

    func testCustomFormatArchiveIsWritten() async throws {
        let pgDump = try tool(.pgDump)
        try TestCluster.require([.pg18])
        var options = ExportOptions()
        options.format = .custom
        options.selectedSchemas = ["qa"]
        let out = workDir.appendingPathComponent("qa.dump").path
        try await drain(DatabaseTransferService().export(
            options: options, connection: connection(.pg18),
            password: TestCluster.password(.scram), toolPath: pgDump, outputPath: out
        ))
        let header = try FileHandle(forReadingFrom: URL(fileURLWithPath: out)).readData(ofLength: 5)
        XCTAssertEqual(String(data: header, encoding: .ascii), "PGDMP")
    }

    func testImportStopsAndRollsBackOnError() async throws {
        let psql = try tool(.psql)
        let client = try await connect(.pg18)
        let schema = try await makeScratchSchema(on: client)
        let s = quoteIdent(schema)
        let file = workDir.appendingPathComponent("bad.sql")
        try """
        CREATE TABLE \(s).ok (id int);
        INSERT INTO \(s).ok VALUES (1);
        THIS IS NOT SQL;
        INSERT INTO \(s).ok VALUES (2);
        """.write(to: file, atomically: true, encoding: .utf8)

        let error = await assertThrowsAsync {
            try await self.drain(DatabaseTransferService().runImport(
                options: ImportOptions(), connection: self.connection(.pg18),
                password: TestCluster.password(.scram), toolPath: psql, inputPath: file.path
            ))
        }
        guard case .importFailed? = error as? AppError else {
            return XCTFail("Expected importFailed, got \(String(describing: error))")
        }
        await client.invalidateCache()
        let tables = try await client.listTables(schema: schema)
        XCTAssertTrue(tables.isEmpty, "--single-transaction must roll back the CREATE TABLE")
    }

    func testWrongPasswordFailsExport() async throws {
        let pgDump = try tool(.pgDump)
        try TestCluster.require([.pg18])
        let error = await assertThrowsAsync {
            try await self.drain(DatabaseTransferService().export(
                options: ExportOptions(), connection: self.connection(.pg18),
                password: "wrong", toolPath: pgDump,
                outputPath: self.workDir.appendingPathComponent("x.sql").path
            ))
        }
        guard case .exportFailed? = error as? AppError else {
            return XCTFail("Expected exportFailed, got \(String(describing: error))")
        }
        XCTAssertTrue(message(of: error).contains("password authentication failed"), message(of: error))
    }
}

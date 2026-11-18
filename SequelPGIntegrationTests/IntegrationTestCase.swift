import XCTest
@testable import SequelPG

/// Base class for tests that talk to the live Docker test cluster.
///
/// * Points the SSH tunnel at the test-only known_hosts (DEBUG hook), so the
///   developer's ~/.ssh/known_hosts is never consulted or modified.
/// * Tracks every client opened via `connect(...)` and disconnects it in
///   `tearDown`, so no test leaks pool connections or ssh processes.
/// * `makeScratchSchema` gives mutating tests a private schema that is
///   dropped afterwards — fixtures in `qa` stay untouched and tests can be
///   re-run without `make reset`.
class IntegrationTestCase: XCTestCase {
    private var openClients: [DatabaseClient] = []

    override func setUp() async throws {
        try await super.setUp()
        setenv(TestingHooks.Env.sshKnownHostsFile, TestCluster.sshKnownHostsPath, 1)
    }

    override func tearDown() async throws {
        for client in openClients {
            await client.disconnect()
        }
        openClients.removeAll()
        try await super.tearDown()
    }

    /// Opens a tracked connection, skipping the test when the server is down.
    func connect(
        _ server: TestCluster.Server = .pg18,
        role: TestCluster.Role = .scram,
        sslMode: SSLMode = .off,
        database: String? = nil
    ) async throws -> DatabaseClient {
        try TestCluster.require([server])
        let client = try await TestCluster.connect(server, role: role, sslMode: sslMode, database: database)
        openClients.append(client)
        return client
    }

    /// Registers an externally created client for automatic disconnect.
    func track(_ client: DatabaseClient) {
        openClients.append(client)
    }

    /// Creates `it_<random>` on `client`'s database and drops it (CASCADE)
    /// after the test.
    func makeScratchSchema(on client: DatabaseClient) async throws -> String {
        let name = "it_" + UUID().uuidString.prefix(8).lowercased()
        try await client.exec("CREATE SCHEMA \(quoteIdent(name))")
        addTeardownBlock {
            _ = try? await client.exec("DROP SCHEMA IF EXISTS \(quoteIdent(name)) CASCADE")
        }
        return name
    }

    /// Asserts that `body` throws and returns the error for further checks.
    @discardableResult
    func assertThrowsAsync<T>(
        _ body: () async throws -> T,
        _ message: String = "",
        file: StaticString = #filePath,
        line: UInt = #line
    ) async -> Error? {
        do {
            _ = try await body()
            XCTFail("Expected an error. \(message)", file: file, line: line)
            return nil
        } catch {
            return error
        }
    }

    /// The user-facing message of `error` (what the app shows in alerts).
    func message(of error: Error?) -> String {
        guard let error else { return "" }
        return (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }
}

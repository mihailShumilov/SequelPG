import XCTest
@testable import SequelPG

// MARK: - Shared Base Class for AppViewModel Tests

/// Base test case providing shared setup, teardown, and helpers for
/// AppViewModelTests, CascadeDeleteTests, and InsertDeleteTests.
@MainActor
class AppViewModelTestCase: XCTestCase {

    var mockDB: MockDatabaseClient!
    var vm: AppViewModel!

    override func setUp() {
        super.setUp()
        mockDB = MockDatabaseClient()
        vm = AppViewModel(dbClient: mockDB)
    }

    override func tearDown() {
        vm = nil
        mockDB = nil
        super.tearDown()
    }

    // MARK: - Helpers

    func makeProfile(
        name: String = "Test DB",
        host: String = "localhost",
        port: Int = 5432,
        database: String = "testdb",
        username: String = "testuser",
        sslMode: SSLMode = .prefer
    ) -> ConnectionProfile {
        ConnectionProfile(
            name: name,
            host: host,
            port: port,
            database: database,
            username: username,
            sslMode: sslMode
        )
    }

    func makeConnectedVM(profile: ConnectionProfile? = nil) async {
        let p = profile ?? makeProfile()
        await vm.connect(profile: p, password: "secret", sshPassword: nil)
    }
}

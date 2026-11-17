import XCTest
@testable import SequelPG

/// Authentication variants against every server version in the cluster.
final class ConnectionAuthTests: IntegrationTestCase {
    func testScramPasswordAuthOnEveryServer() async throws {
        for server in TestCluster.Server.allCases {
            let client = try await connect(server, role: .scram)
            let user = try await client.scalar("SELECT current_user")
            XCTAssertEqual(user, TestCluster.user(.scram), "\(server)")
        }
    }

    func testMD5PasswordAuthOnEveryServer() async throws {
        for server in TestCluster.Server.allCases {
            let client = try await connect(server, role: .md5)
            let user = try await client.scalar("SELECT current_user")
            XCTAssertEqual(user, TestCluster.user(.md5), "\(server)")
        }
    }

    func testTrustAuthWithoutPasswordOnEveryServer() async throws {
        for server in TestCluster.Server.allCases {
            let client = try await connect(server, role: .trust)
            let user = try await client.scalar("SELECT current_user")
            XCTAssertEqual(user, TestCluster.user(.trust), "\(server)")
        }
    }

    func testServerVersionMatchesCluster() async throws {
        for server in TestCluster.Server.allCases {
            let client = try await connect(server)
            let versionNum = try await client.scalar("SHOW server_version_num")
            XCTAssertEqual((Int(versionNum ?? "") ?? 0) / 10000, TestCluster.major(server), "\(server)")
        }
    }

    func testLocalhostHostNameConnects() async throws {
        try TestCluster.require([.pg18])
        let client = DatabaseClient()
        track(client)
        try await client.connect(
            profile: TestCluster.profile(.pg18, host: "localhost"),
            password: TestCluster.password(.scram),
            sshPassword: nil
        )
        let endpoint = await client.currentEndpoint()
        XCTAssertEqual(endpoint?.host, "127.0.0.1", "localhost is pinned to IPv4")
        XCTAssertEqual(endpoint?.port, TestCluster.port(.pg18))
    }

    func testWrongPasswordIsRejectedWithReadableMessage() async throws {
        try TestCluster.require([.pg18])
        let client = DatabaseClient()
        let error = await assertThrowsAsync {
            try await client.connect(profile: TestCluster.profile(.pg18), password: "nope", sshPassword: nil)
        }
        guard case .connectionFailed? = error as? AppError else {
            return XCTFail("Expected AppError.connectionFailed, got \(String(describing: error))")
        }
        XCTAssertTrue(
            message(of: error).localizedCaseInsensitiveContains("password authentication failed"),
            "Message should name the cause, got: \(message(of: error))"
        )
        let connected = await client.isConnected
        XCTAssertFalse(connected)
    }

    func testMissingPasswordForPasswordRoleFails() async throws {
        try TestCluster.require([.pg18])
        let client = DatabaseClient()
        _ = await assertThrowsAsync {
            try await client.connect(profile: TestCluster.profile(.pg18), password: nil, sshPassword: nil)
        }
        let connected = await client.isConnected
        XCTAssertFalse(connected)
    }

    func testUnknownDatabaseIsReported() async throws {
        try TestCluster.require([.pg18])
        let client = DatabaseClient()
        let error = await assertThrowsAsync {
            try await client.connect(
                profile: TestCluster.profile(.pg18, database: "no_such_db"),
                password: TestCluster.password(.scram),
                sshPassword: nil
            )
        }
        XCTAssertTrue(
            message(of: error).contains("no_such_db"),
            "Message should name the missing database, got: \(message(of: error))"
        )
    }

    func testUnknownRoleIsReported() async throws {
        try TestCluster.require([.pg18])
        var profile = TestCluster.profile(.pg18)
        profile.username = "no_such_role"
        let client = DatabaseClient()
        let error = await assertThrowsAsync {
            try await client.connect(profile: profile, password: "x", sshPassword: nil)
        }
        XCTAssertFalse(message(of: error).isEmpty)
    }

    func testClosedPortFailsFast() async throws {
        var profile = TestCluster.profile(.pg18)
        profile.port = 55499 // nothing listens here
        let client = DatabaseClient()
        let start = Date()
        let error = await assertThrowsAsync {
            try await client.connect(profile: profile, password: "x", sshPassword: nil)
        }
        guard case .connectionFailed? = error as? AppError else {
            return XCTFail("Expected AppError.connectionFailed, got \(String(describing: error))")
        }
        XCTAssertLessThan(Date().timeIntervalSince(start), 15, "Refused connections must not hang")
    }

    func testUnresolvableHostFails() async throws {
        var profile = TestCluster.profile(.pg18)
        profile.host = "sequelpg-no-such-host.invalid"
        let client = DatabaseClient()
        let error = await assertThrowsAsync {
            try await client.connect(profile: profile, password: "x", sshPassword: nil)
        }
        XCTAssertNotNil(error)
    }

    func testReadonlyRoleCanReadGrantedTableOnly() async throws {
        for server in TestCluster.Server.allCases {
            let client = try await connect(server, role: .readonly)
            let count = try await client.scalar("SELECT count(*) FROM qa.people")
            XCTAssertEqual(count, "50", "\(server)")

            let error = await assertThrowsAsync { try await client.exec("SELECT * FROM qa.big_numbers") }
            XCTAssertTrue(
                message(of: error).localizedCaseInsensitiveContains("permission denied"),
                "\(server): \(message(of: error))"
            )
            // A failed statement must not poison the session.
            let again = try await client.scalar("SELECT 1")
            XCTAssertEqual(again, "1", "\(server)")
        }
    }

    func testReconnectReplacesPreviousSession() async throws {
        let client = try await connect(.pg18, role: .scram)
        try await client.connect(profile: TestCluster.profile(.pg16), password: TestCluster.password(.scram), sshPassword: nil)
        let versionNum = try await client.scalar("SHOW server_version_num")
        XCTAssertEqual((Int(versionNum ?? "") ?? 0) / 10000, 16)
    }

    func testDisconnectDropsSession() async throws {
        let client = try await connect(.pg18)
        await client.disconnect()
        let connected = await client.isConnected
        XCTAssertFalse(connected)
        let endpoint = await client.currentEndpoint()
        XCTAssertNil(endpoint)
        let error = await assertThrowsAsync { try await client.exec("SELECT 1") }
        guard case .notConnected? = error as? AppError else {
            return XCTFail("Expected AppError.notConnected, got \(String(describing: error))")
        }
    }

    // MARK: Connection list "Test Connection"

    @MainActor
    func testConnectionListTestConnectionReportsSuccessAndFailure() async throws {
        try TestCluster.require([.pg18])
        let suite = "sequelpg.integration.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let vm = ConnectionListViewModel(store: ConnectionStore(defaults: defaults), keychainService: InMemoryKeychainService())

        let ok = await vm.testConnection(
            profile: TestCluster.profile(.pg18),
            password: TestCluster.password(.scram),
            sshPassword: nil
        )
        XCTAssertNil(ok)

        let failure = await vm.testConnection(profile: TestCluster.profile(.pg18), password: "wrong", sshPassword: nil)
        XCTAssertNotNil(failure)
    }
}

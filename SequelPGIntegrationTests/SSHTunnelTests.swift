import XCTest
@testable import SequelPG

/// SSH tunnel through the test bastion (`sshd` service) to pg18.
///
/// Host-key trust comes from `test-db/.generated/ssh/known_hosts` via the
/// DEBUG-only `SEQUELPG_SSH_KNOWN_HOSTS_FILE` hook (set in
/// `IntegrationTestCase.setUp`); tests that need a different trust state
/// point it at a temporary file instead.
final class SSHTunnelTests: IntegrationTestCase {
    override func setUp() async throws {
        try await super.setUp()
        try TestCluster.require([.pg18], ssh: true)
    }

    private func connectViaSSH(
        _ profile: ConnectionProfile,
        sshPassword: String? = nil
    ) async throws -> DatabaseClient {
        let client = DatabaseClient()
        track(client)
        try await client.connect(profile: profile, password: TestCluster.password(.scram), sshPassword: sshPassword)
        return client
    }

    private func withKnownHosts(_ contents: String, _ body: () async throws -> Void) async rethrows {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("kh-\(UUID().uuidString)")
        try? contents.write(to: url, atomically: true, encoding: .utf8)
        setenv(TestingHooks.Env.sshKnownHostsFile, url.path, 1)
        defer {
            setenv(TestingHooks.Env.sshKnownHostsFile, TestCluster.sshKnownHostsPath, 1)
            try? FileManager.default.removeItem(at: url)
        }
        try await body()
    }

    func testKeyFileTunnelReachesDatabase() async throws {
        let client = try await connectViaSSH(TestCluster.sshProfile(auth: .keyFile))
        let count = try await client.scalar("SELECT count(*) FROM qa.people")
        XCTAssertEqual(count, "50")

        let endpoint = await client.currentEndpoint()
        XCTAssertEqual(endpoint?.host, "127.0.0.1")
        XCTAssertNotEqual(endpoint?.port, TestCluster.config.ssh.targetPort, "Must dial the local forward, not the remote port")
        XCTAssertNotEqual(endpoint?.port, TestCluster.port(.pg18), "Must not bypass the tunnel via the host port mapping")
    }

    func testPasswordTunnelReachesDatabase() async throws {
        let client = try await connectViaSSH(
            TestCluster.sshProfile(auth: .password),
            sshPassword: TestCluster.config.ssh.password
        )
        let one = try await client.scalar("SELECT 1")
        XCTAssertEqual(one, "1")
    }

    func testTLSInsideTunnel() async throws {
        let client = try await connectViaSSH(TestCluster.sshProfile(auth: .keyFile, sslMode: .require))
        let ssl = try await client.scalar("SELECT ssl FROM pg_stat_ssl WHERE pid = pg_backend_pid()")
        XCTAssertEqual(ssl, "true")
    }

    func testWrongSSHPasswordFails() async throws {
        let client = DatabaseClient()
        let error = await assertThrowsAsync {
            try await client.connect(
                profile: TestCluster.sshProfile(auth: .password),
                password: TestCluster.password(.scram),
                sshPassword: "definitely-wrong"
            )
        }
        guard case .sshTunnelFailed? = error as? AppError else {
            return XCTFail("Expected sshTunnelFailed, got \(String(describing: error))")
        }
    }

    func testUnauthorizedKeyFails() async throws {
        let client = DatabaseClient()
        let error = await assertThrowsAsync {
            try await client.connect(
                profile: TestCluster.sshProfile(auth: .keyFile, keyPath: TestCluster.sshWrongKeyPath),
                password: TestCluster.password(.scram),
                sshPassword: nil
            )
        }
        guard case .sshTunnelFailed? = error as? AppError else {
            return XCTFail("Expected sshTunnelFailed, got \(String(describing: error))")
        }
        XCTAssertTrue(
            message(of: error).localizedCaseInsensitiveContains("denied"),
            "Expected a permission-denied explanation, got: \(message(of: error))"
        )
    }

    func testMissingKeyFileIsReportedBeforeLaunchingSSH() async throws {
        let client = DatabaseClient()
        let error = await assertThrowsAsync {
            try await client.connect(
                profile: TestCluster.sshProfile(auth: .keyFile, keyPath: "/nonexistent/id_ed25519"),
                password: TestCluster.password(.scram),
                sshPassword: nil
            )
        }
        XCTAssertTrue(message(of: error).contains("not found"), message(of: error))
    }

    func testSymlinkedKeyFileIsRefused() async throws {
        let link = FileManager.default.temporaryDirectory.appendingPathComponent("key-link-\(UUID().uuidString)")
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: TestCluster.sshClientKeyPath)
        defer { try? FileManager.default.removeItem(at: link) }

        let client = DatabaseClient()
        let error = await assertThrowsAsync {
            try await client.connect(
                profile: TestCluster.sshProfile(auth: .keyFile, keyPath: link.path),
                password: TestCluster.password(.scram),
                sshPassword: nil
            )
        }
        XCTAssertTrue(message(of: error).contains("symlink"), message(of: error))
    }

    func testUnknownHostKeyExplainsHowToTrustIt() async throws {
        try await withKnownHosts("") {
            let client = DatabaseClient()
            let error = await assertThrowsAsync {
                try await client.connect(
                    profile: TestCluster.sshProfile(auth: .keyFile),
                    password: TestCluster.password(.scram),
                    sshPassword: nil
                )
            }
            XCTAssertTrue(message(of: error).contains("ssh-keyscan"), message(of: error))
        }
    }

    func testChangedHostKeyIsFlaggedAsPossibleMITM() async throws {
        // A syntactically valid but different ed25519 key for the same host.
        let wrongKey = try String(contentsOfFile: TestCluster.sshWrongKeyPath + ".pub", encoding: .utf8)
            .split(separator: " ").prefix(2).joined(separator: " ")
        try await withKnownHosts("[127.0.0.1]:\(TestCluster.config.ssh.port) \(wrongKey)\n") {
            let client = DatabaseClient()
            let error = await assertThrowsAsync {
                try await client.connect(
                    profile: TestCluster.sshProfile(auth: .keyFile),
                    password: TestCluster.password(.scram),
                    sshPassword: nil
                )
            }
            XCTAssertTrue(message(of: error).contains("CHANGED"), message(of: error))
            XCTAssertFalse(message(of: error).contains("ssh-keyscan"), "Must not suggest blindly re-trusting")
        }
    }

    func testUnreachableBastionFails() async throws {
        var profile = TestCluster.sshProfile(auth: .keyFile)
        profile.sshPort = 55498 // nothing listens here
        let client = DatabaseClient()
        let error = await assertThrowsAsync {
            try await client.connect(profile: profile, password: TestCluster.password(.scram), sshPassword: nil)
        }
        guard case .sshTunnelFailed? = error as? AppError else {
            return XCTFail("Expected sshTunnelFailed, got \(String(describing: error))")
        }
    }

    func testDisconnectClosesTunnelPort() async throws {
        let client = try await connectViaSSH(TestCluster.sshProfile(auth: .keyFile))
        let current = await client.currentEndpoint()
        let endpoint = try XCTUnwrap(current)
        XCTAssertTrue(TestCluster.isPortOpen(endpoint.port))

        await client.disconnect()
        // ssh exits on SIGTERM; give the kernel a moment to release the port.
        for _ in 0 ..< 20 where TestCluster.isPortOpen(endpoint.port) {
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        XCTAssertFalse(TestCluster.isPortOpen(endpoint.port), "Tunnel port still open after disconnect")
    }

    func testDatabaseSwitchKeepsTunnel() async throws {
        let profile = TestCluster.sshProfile(auth: .keyFile)
        let client = try await connectViaSSH(profile)
        let before = await client.currentEndpoint()

        try await client.switchDatabase(
            to: TestCluster.otherDatabase,
            profile: profile,
            password: TestCluster.password(.scram),
            sshPassword: nil
        )
        let label = try await client.scalar("SELECT label FROM other.marker WHERE id = 1")
        XCTAssertEqual(label, "other-db")
        let after = await client.currentEndpoint()
        XCTAssertEqual(before, after, "Switching databases must reuse the existing tunnel")
    }

    @MainActor
    func testConnectionListTestConnectionThroughTunnel() async throws {
        let suite = "sequelpg.integration.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let vm = ConnectionListViewModel(store: ConnectionStore(defaults: defaults), keychainService: InMemoryKeychainService())
        let result = await vm.testConnection(
            profile: TestCluster.sshProfile(auth: .password),
            password: TestCluster.password(.scram),
            sshPassword: TestCluster.config.ssh.password
        )
        XCTAssertNil(result)
    }
}

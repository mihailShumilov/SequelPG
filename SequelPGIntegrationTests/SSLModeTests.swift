import XCTest
@testable import SequelPG

/// Every `SSLMode` against a TLS-enabled server (pg18) and a plain one (pg16).
///
/// pg18's certificate comes from a private test CA: verification succeeds
/// only with the profile's CA file, or with "Don't verify server certificate"
/// (Prefer/Require). `connect(…)` turns verification off unless asked.
final class SSLModeTests: IntegrationTestCase {
    private func connectError(_ profile: ConnectionProfile, password: String? = nil) async -> Error? {
        let client = DatabaseClient()
        return await assertThrowsAsync {
            try await client.connect(
                profile: profile,
                password: password ?? TestCluster.password(.scram),
                sshPassword: nil
            )
        }
    }

    private func connectVerified(_ mode: SSLMode, host: String? = nil) async throws -> DatabaseClient {
        try TestCluster.require([.pg18])
        let client = DatabaseClient()
        try await client.connect(
            profile: TestCluster.profile(
                .pg18, sslMode: mode, host: host, verifyCertificate: true, caCertPath: TestCluster.caCertPath
            ),
            password: TestCluster.password(.scram),
            sshPassword: nil
        )
        addTeardownBlock { await client.disconnect() }
        return client
    }

    private func isSessionEncrypted(_ client: DatabaseClient) async throws -> Bool {
        let value = try await client.scalar("SELECT ssl FROM pg_stat_ssl WHERE pid = pg_backend_pid()")
        return value == "t" || value == "true"
    }

    func testOffUsesPlainConnectionOnTLSServer() async throws {
        let client = try await connect(.pg18, sslMode: .off)
        let encrypted = try await isSessionEncrypted(client)
        XCTAssertFalse(encrypted)
    }

    func testPreferUsesTLSWhenServerSupportsIt() async throws {
        let client = try await connect(.pg18, sslMode: .prefer)
        let encrypted = try await isSessionEncrypted(client)
        XCTAssertTrue(encrypted)
    }

    func testRequireUsesTLS() async throws {
        let client = try await connect(.pg18, sslMode: .require)
        let encrypted = try await isSessionEncrypted(client)
        XCTAssertTrue(encrypted)
        let version = try await client.scalar("SELECT version FROM pg_stat_ssl WHERE pid = pg_backend_pid()")
        XCTAssertTrue(version?.hasPrefix("TLSv1.") == true, "Got TLS version \(version ?? "nil")")
    }

    func testPreferFallsBackToPlainOnNonTLSServer() async throws {
        let client = try await connect(.pg16, sslMode: .prefer)
        let encrypted = try await isSessionEncrypted(client)
        XCTAssertFalse(encrypted)
    }

    func testRequireFailsOnNonTLSServer() async throws {
        try TestCluster.require([.pg16])
        let client = DatabaseClient()
        let error = await assertThrowsAsync {
            try await client.connect(
                profile: TestCluster.profile(.pg16, sslMode: .require),
                password: TestCluster.password(.scram),
                sshPassword: nil
            )
        }
        guard case .connectionFailed? = error as? AppError else {
            return XCTFail("Expected connectionFailed, got \(String(describing: error))")
        }
    }

    func testVerifyModesRejectCertificateFromUntrustedCA() async throws {
        try TestCluster.require([.pg18])
        for mode in [SSLMode.require, .verifyCa, .verifyFull] {
            let error = await connectError(TestCluster.profile(.pg18, sslMode: mode, verifyCertificate: true))
            XCTAssertTrue(
                message(of: error).contains("could not be verified"),
                "\(mode): expected a certificate-verification explanation, got: \(message(of: error))"
            )
        }
    }

    func testPreferFallsBackToPlainWhenCertificateIsRejected() async throws {
        // libpq's prefer: an SSL attempt that fails is retried without SSL.
        try TestCluster.require([.pg18])
        let client = DatabaseClient()
        try await client.connect(
            profile: TestCluster.profile(.pg18, sslMode: .prefer, verifyCertificate: true),
            password: TestCluster.password(.scram),
            sshPassword: nil
        )
        addTeardownBlock { await client.disconnect() }
        let encrypted = try await isSessionEncrypted(client)
        XCTAssertFalse(encrypted)
    }

    func testVerifyModesSucceedWithProfileCA() async throws {
        for mode in [SSLMode.prefer, .require, .verifyCa, .verifyFull] {
            let client = try await connectVerified(mode)
            let encrypted = try await isSessionEncrypted(client)
            XCTAssertTrue(encrypted, "\(mode)")
        }
    }

    func testVerifyFullThroughSSHTunnel() async throws {
        // The tunnel dials 127.0.0.1; the certificate is checked with the
        // profile's real host as the expected name (and the peer address).
        try TestCluster.require([.pg18])
        for mode in [SSLMode.verifyCa, .verifyFull] {
            var profile = TestCluster.sshProfile(auth: .keyFile, sslMode: mode)
            profile.sslSkipVerification = false
            profile.sslRootCertPath = TestCluster.caCertPath
            let client = DatabaseClient()
            try await client.connect(profile: profile, password: TestCluster.password(.scram), sshPassword: nil)
            let encrypted = try await isSessionEncrypted(client)
            XCTAssertTrue(encrypted, "\(mode)")
            await client.disconnect()
        }
    }

    func testUnreadableCAFileIsExplained() async throws {
        try TestCluster.require([.pg18])
        let bogus = FileManager.default.temporaryDirectory.appendingPathComponent("not-a-cert-\(UUID()).pem")
        try Data("not a certificate".utf8).write(to: bogus)
        defer { try? FileManager.default.removeItem(at: bogus) }
        let error = await connectError(TestCluster.profile(
            .pg18, sslMode: .verifyFull, verifyCertificate: true, caCertPath: bogus.path
        ))
        XCTAssertNotNil(error)
        XCTAssertFalse(message(of: error).isEmpty)
    }

    func testSSLOnlyRoleIsRejectedWithoutTLS() async throws {
        try TestCluster.require([.pg18])
        let client = DatabaseClient()
        let error = await assertThrowsAsync {
            try await client.connect(
                profile: TestCluster.profile(.pg18, role: .sslonly, sslMode: .off),
                password: TestCluster.password(.sslonly),
                sshPassword: nil
            )
        }
        XCTAssertTrue(
            message(of: error).localizedCaseInsensitiveContains("pg_hba.conf"),
            "Expected the server's pg_hba rejection, got: \(message(of: error))"
        )
    }

    func testSSLOnlyRoleConnectsWithRequire() async throws {
        let client = try await connect(.pg18, role: .sslonly, sslMode: .require)
        let user = try await client.scalar("SELECT current_user")
        XCTAssertEqual(user, TestCluster.user(.sslonly))
    }
}

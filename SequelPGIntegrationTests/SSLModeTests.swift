import XCTest
@testable import SequelPG

/// Every `SSLMode` against a TLS-enabled server (pg18) and a plain one (pg16).
///
/// The test CA is private, so `verify-ca` / `verify-full` are expected to
/// fail: the app validates against the system trust store only and has no
/// per-connection root-certificate setting. Those tests pin that behavior.
final class SSLModeTests: IntegrationTestCase {
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
        for mode in [SSLMode.verifyCa, .verifyFull] {
            let client = DatabaseClient()
            let error = await assertThrowsAsync({
                try await client.connect(
                    profile: TestCluster.profile(.pg18, sslMode: mode),
                    password: TestCluster.password(.scram),
                    sshPassword: nil
                )
            }, "\(mode) must not trust a private CA")
            XCTAssertTrue(
                message(of: error).contains("could not be verified"),
                "\(mode): expected a certificate-verification explanation, got: \(message(of: error))"
            )
        }
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

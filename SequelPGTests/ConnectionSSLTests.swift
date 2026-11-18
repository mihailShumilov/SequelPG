import NIOSSL
import XCTest
@testable import SequelPG

/// SSL settings of a profile and the TLS policy built from them.
final class ConnectionSSLTests: XCTestCase {
    private func profile(_ mode: SSLMode, skip: Bool = false, ca: String = "") -> ConnectionProfile {
        ConnectionProfile(
            name: "n", host: "h", database: "d", username: "u",
            sslMode: mode, sslSkipVerification: skip, sslRootCertPath: ca
        )
    }

    func testOldProfilesDecodeWithVerificationOn() throws {
        let json = #"{"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","name":"n","host":"h","port":5432,"#
            + #""database":"d","username":"u","sslMode":"require"}"#
        let decoded = try JSONDecoder().decode(ConnectionProfile.self, from: Data(json.utf8))
        XCTAssertFalse(decoded.sslSkipVerification)
        XCTAssertEqual(decoded.sslRootCertPath, "")
        XCTAssertTrue(decoded.sslSettings.verifiesCertificate)
    }

    func testRoundTripKeepsSSLFields() throws {
        let original = profile(.require, skip: true, ca: "~/ca.pem")
        let decoded = try JSONDecoder().decode(ConnectionProfile.self, from: JSONEncoder().encode(original))
        XCTAssertEqual(decoded, original)
    }

    func testVerificationPolicyPerMode() throws {
        func verification(_ p: ConnectionProfile) -> CertificateVerification? {
            DatabaseClient.tlsConfiguration(for: p.sslSettings)?.certificateVerification
        }
        XCTAssertNil(verification(profile(.off)))
        XCTAssertEqual(verification(profile(.prefer)), .fullVerification)
        XCTAssertEqual(verification(profile(.require)), .fullVerification)
        XCTAssertEqual(verification(profile(.prefer, skip: true)), CertificateVerification.none)
        XCTAssertEqual(verification(profile(.require, skip: true)), CertificateVerification.none)
        // The opt-out applies to Prefer/Require only.
        XCTAssertEqual(verification(profile(.verifyCa, skip: true)), .noHostnameVerification)
        XCTAssertEqual(verification(profile(.verifyFull, skip: true)), .fullVerification)
    }

    func testCAFileReplacesSystemTrustStore() {
        let settings = profile(.verifyFull, ca: "~/certs/ca.pem").sslSettings
        let expected = (("~/certs/ca.pem" as NSString).expandingTildeInPath)
        XCTAssertEqual(settings.rootCertificatePath, expected)
        guard case let .file(path)? = DatabaseClient.tlsConfiguration(for: settings)?.trustRoots else {
            return XCTFail("Expected file trust roots")
        }
        XCTAssertEqual(path, expected)
        XCTAssertEqual(profile(.verifyFull).sslSettings.rootCertificatePath, nil)
        // Without verification the CA file is irrelevant.
        let unverified = DatabaseClient.tlsConfiguration(for: profile(.require, skip: true, ca: "/x.pem").sslSettings)
        if case .file? = unverified?.trustRoots { XCTFail("CA file must not matter when not verifying") }
    }

    func testTLSServerNameIsTheRealHostOnlyThroughATunnel() {
        var p = profile(.verifyFull)
        p.host = "db.example.com"
        XCTAssertNil(DatabaseClient.tlsServerName(for: p), "Direct connections let the driver use the host")
        p.useSSHTunnel = true
        XCTAssertEqual(DatabaseClient.tlsServerName(for: p), "db.example.com")
        p.host = "10.0.0.5"
        XCTAssertNil(DatabaseClient.tlsServerName(for: p), "IP addresses are not valid SNI")
        p.host = "::1"
        XCTAssertNil(DatabaseClient.tlsServerName(for: p))
    }

    func testValidationRequiresAnExistingCAFile() throws {
        XCTAssertTrue(profile(.verifyFull, ca: "/no/such/ca.pem").validate().contains("CA certificate file not found."))
        XCTAssertFalse(profile(.off, ca: "/no/such/ca.pem").validate().contains("CA certificate file not found."))
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("ca-\(UUID()).pem")
        try Data("x".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        XCTAssertEqual(profile(.verifyFull, ca: file.path).validate(), [])
    }

    func testFormModelRoundTripsSSLFields() {
        var form = ConnectionFormModel()
        form.load(from: profile(.require, skip: true, ca: "/ca.pem"), password: "", sshPassword: "")
        let built = form.buildProfile(id: UUID())
        XCTAssertTrue(built.sslSkipVerification)
        XCTAssertEqual(built.sslRootCertPath, "/ca.pem")
    }
}

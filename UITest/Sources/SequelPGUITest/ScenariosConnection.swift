import Foundation

/// Every way of connecting: auth methods, server versions, SSL modes, SSH
/// tunnels, and the failures a person must be told about clearly.
extension Scenarios {
    static var connection: [Scenario] {
        [
            Scenario(name: "smoke", summary: "connect, run a query, disconnect") { ui in
                try ui.step("connect PG18") { try ui.connect("PG18 scram") }
                try ui.step("count people") {
                    try ui.expectEqual(try ui.scalar("SELECT count(*) FROM qa.people"), "50", "row count")
                }
                try ui.step("disconnect") { try ui.disconnect() }
            },

            Scenario(name: "start-page", summary: "saved connections list, switching, add and delete") { ui in
                try ui.step("all saved connections listed") {
                    let list = try ui.expect(id: A11yID.StartPage.connectionList)
                    try ui.session.waitUntil("4 rows") { list.rows.count == 4 }
                }
                try ui.step("switching fills the form") {
                    try ui.selectProfile("PG16 md5")
                    try ui.expectText(id: A11yID.Form.port, "port 55416") { $0 == "\(Cluster.port("pg16"))" }
                    try ui.expectText(id: A11yID.Form.username, "md5 user") { $0 == Cluster.role("md5").user }
                    try ui.selectProfile("PG18 via SSH")
                    try ui.expectText(id: A11yID.Form.useSSH, "SSH on") { $0 == "1" }
                    try ui.expectText(id: A11yID.Form.sshPort, "ssh port") { $0 == "\(Cluster.config.ssh.port)" }
                }
                try ui.step("add a connection") {
                    try ui.press(id: A11yID.StartPage.addConnection)
                    let list = try ui.expect(id: A11yID.StartPage.connectionList)
                    try ui.session.waitUntil("5 rows") { list.rows.count == 5 }
                }
                try ui.step("delete it") {
                    try ui.press(id: A11yID.StartPage.deleteConnection)
                    try ui.press(Query(role: "AXButton", label: "Delete"))
                    let list = try ui.expect(id: A11yID.StartPage.connectionList)
                    try ui.session.waitUntil("4 rows") { list.rows.count == 4 }
                }
            },

            Scenario(name: "auth-methods", summary: "scram on PG18, md5 on PG16, trust on PG13") { ui in
                for (profile, role, major) in [("PG18 scram", "scram", "18"), ("PG16 md5", "md5", "16"),
                                               ("PG13 trust", "trust", "13")]
                {
                    try ui.step("connect \(profile)") { try ui.connect(profile) }
                    try ui.step("\(profile) identity") {
                        try ui.expectEqual(try ui.scalar("SELECT current_user"), Cluster.role(role).user, "user")
                        let version = try ui.scalar("SELECT current_setting('server_version_num')")
                        try ui.expect(version.hasPrefix(major), "server_version_num \(version) is not PG\(major)")
                    }
                    try ui.step("disconnect \(profile)") { try ui.disconnect() }
                }
            },

            Scenario(
                name: "connect-errors",
                summary: "wrong password, unreachable port, unknown database, pg_hba rejection",
                profiles: {
                    var wrongPassword = SeedProfile("Wrong password")
                    wrongPassword.password = "nope"
                    var unreachable = SeedProfile("Unreachable")
                    unreachable.port = 1
                    var noDB = SeedProfile("No database")
                    noDB.database = "does_not_exist"
                    let rejected = SeedProfile("SSL-only without SSL", role: "sslonly")
                    return [wrongPassword, unreachable, noDB, rejected]
                }()
            ) { ui in
                try ui.step("wrong password") {
                    let text = try ui.connectExpectingError("Wrong password")
                    try ui.expect(text.contains("password authentication failed"), "message: \(text)")
                }
                try ui.step("unreachable port") {
                    let text = try ui.connectExpectingError("Unreachable")
                    try ui.expect(text.contains("Could not reach") || text.localizedCaseInsensitiveContains("refused"),
                                  "message: \(text)")
                }
                try ui.step("unknown database") {
                    let text = try ui.connectExpectingError("No database")
                    try ui.expect(text.contains("does_not_exist"), "message: \(text)")
                }
                try ui.step("pg_hba rejects plain connection") {
                    let text = try ui.connectExpectingError("SSL-only without SSL")
                    try ui.expect(text.contains("pg_hba.conf") || text.contains("rejects"), "message: \(text)")
                }
            },

            Scenario(name: "test-connection", summary: "Test Connection reports success and failure inline") { ui in
                try ui.step("test succeeds") {
                    try ui.selectProfile("PG18 scram")
                    try ui.press(id: A11yID.StartPage.testConnection)
                    try ui.expect(id: A11yID.StartPage.testSucceeded, timeout: 20)
                }
                try ui.step("edit port, test fails") {
                    try ui.fill(id: A11yID.Form.port, "1")
                    try ui.press(id: A11yID.StartPage.testConnection)
                    try ui.expect(id: A11yID.StartPage.testFailed, timeout: 20)
                }
            },

            Scenario(
                name: "ssl-modes",
                summary: "certificate verification: on by default, CA file, \u{201C}Don't verify\u{201D}, SSL-only role",
                profiles: {
                    var unverified = SeedProfile("SSL require, no verify")
                    unverified.sslMode = "require"
                    unverified.sslSkipVerification = true
                    var verified = SeedProfile("SSL require, system CA")
                    verified.sslMode = "require"
                    var withCA = SeedProfile("SSL CA file, verify-full")
                    withCA.sslMode = "verify-full"
                    withCA.sslRootCertPath = Cluster.caCert
                    var sslOnly = SeedProfile("SSL-only role", role: "sslonly")
                    sslOnly.sslMode = "require"
                    sslOnly.sslSkipVerification = true
                    var verifyFull = SeedProfile("SSL verify-full")
                    verifyFull.sslMode = "verify-full"
                    return [unverified, verified, withCA, sslOnly, verifyFull]
                }()
            ) { ui in
                try ui.step("the form offers \u{201C}Don't verify\u{201D} and a CA file") {
                    try ui.selectProfile("SSL require, no verify")
                    try ui.expect(id: A11yID.Form.sslSkipVerification)
                    try ui.selectProfile("SSL CA file, verify-full")
                    try ui.expectText(id: A11yID.Form.sslRootCert, "the CA path") { $0.hasSuffix("ca.crt") }
                }
                try ui.step("require without verification is encrypted") {
                    try ui.connect("SSL require, no verify")
                    let ssl = try ui.scalar("SELECT ssl FROM pg_stat_ssl WHERE pid = pg_backend_pid()")
                    try ui.expectEqual(ssl, "true", "pg_stat_ssl.ssl")
                    try ui.disconnect()
                }
                try ui.step("require verifies the certificate by default") {
                    let text = try ui.connectExpectingError("SSL require, system CA")
                    try ui.expect(text.contains("Don\u{2019}t verify") || text.contains("Don't verify"), "message: \(text)")
                }
                try ui.step("verify-full succeeds with the profile's CA file") {
                    try ui.connect("SSL CA file, verify-full")
                    let ssl = try ui.scalar("SELECT ssl FROM pg_stat_ssl WHERE pid = pg_backend_pid()")
                    try ui.expectEqual(ssl, "true", "pg_stat_ssl.ssl")
                    try ui.disconnect()
                }
                try ui.step("SSL-only role over SSL") {
                    try ui.connect("SSL-only role")
                    try ui.expectEqual(try ui.scalar("SELECT current_user"), Cluster.role("sslonly").user, "user")
                    try ui.disconnect()
                }
                try ui.step("verify-full without the CA fails with a readable message") {
                    let text = try ui.connectExpectingError("SSL verify-full")
                    try ui.expect(text.localizedCaseInsensitiveContains("certificate"), "message: \(text)")
                }
            },

            Scenario(
                name: "ssh-tunnel",
                summary: "SSH key and password auth through the bastion; wrong key fails",
                profiles: {
                    var password = SeedProfile.viaSSH("SSH password")
                    password.sshAuthMethod = "password"
                    password.sshKeyPath = ""
                    password.sshPassword = Cluster.config.ssh.password
                    return [
                        SeedProfile.viaSSH("SSH key"),
                        password,
                        SeedProfile.viaSSH("SSH wrong key", keyPath: Cluster.sshWrongKey),
                    ]
                }()
            ) { ui in
                try ui.step("key auth") {
                    try ui.connect("SSH key")
                    try ui.expectEqual(try ui.scalar("SELECT count(*) FROM qa.people"), "50", "rows via tunnel")
                    try ui.disconnect()
                }
                try ui.step("password auth") {
                    try ui.connect("SSH password")
                    try ui.expectEqual(try ui.scalar("SELECT current_user"), Cluster.role("scram").user, "user")
                    try ui.disconnect()
                }
                try ui.step("wrong key is refused") {
                    let text = try ui.connectExpectingError("SSH wrong key")
                    try ui.expect(text.localizedCaseInsensitiveContains("ssh"), "message: \(text)")
                }
            },
        ]
    }
}

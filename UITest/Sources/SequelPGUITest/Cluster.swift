import Foundation

/// Paths and the Docker test cluster's settings (test-db/test-env.json).
enum Repo {
    /// …/UITest/Sources/SequelPGUITest/Cluster.swift → repo root.
    static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent()
    static let testDB = root.appending(path: "test-db")

    /// The Debug app built by `make -C test-db build-app`.
    static var appBinary: URL {
        if let path = ProcessInfo.processInfo.environment["SEQUELPG_BINARY"], !path.isEmpty {
            return URL(fileURLWithPath: path)
        }
        return root.appending(path: "build/DerivedData/Build/Products/Debug/SequelPG.app/Contents/MacOS/SequelPG")
    }
}

enum Cluster {
    struct Config: Decodable {
        struct Credentials: Decodable { let user: String; let password: String }
        struct Server: Decodable { let port: Int }
        struct SSH: Decodable { let port: Int; let user: String; let password: String; let targetHost: String; let targetPort: Int }
        let host: String
        let database: String
        let admin: Credentials
        let roles: [String: Credentials]
        let servers: [String: Server]
        let ssh: SSH
    }

    static let config: Config = {
        let url = Repo.testDB.appending(path: "test-env.json")
        guard let data = try? Data(contentsOf: url), let config = try? JSONDecoder().decode(Config.self, from: data)
        else { fatalError("cannot read \(url.path)") }
        return config
    }()

    static func port(_ server: String = "pg18") -> Int { config.servers[server]!.port }
    static func role(_ name: String) -> Config.Credentials { config.roles[name]! }
    static var sshClientKey: String { Repo.testDB.appending(path: ".generated/ssh/client_ed25519").path }
    static var sshWrongKey: String { Repo.testDB.appending(path: ".generated/ssh/wrong_ed25519").path }
    /// Private CA that signed pg18's certificate.
    static var caCert: String { Repo.testDB.appending(path: ".generated/certs/ca.crt").path }
    static var sshKnownHosts: String { Repo.testDB.appending(path: ".generated/ssh/known_hosts").path }

    static func isPortOpen(_ port: Int) -> Bool {
        let fd = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = UInt16(port).bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        return withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0
            }
        }
    }

    static var isUp: Bool { ["pg18", "pg16", "pg13"].allSatisfy { isPortOpen(port($0)) } && isPortOpen(config.ssh.port) }

    /// Runs SQL on a server as the admin role via `docker exec … psql` (no
    /// local client needed) and returns the unaligned output.
    @discardableResult
    static func sql(_ sql: String, server: String = "pg18", database: String? = nil) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [
            "docker", "exec", "-i", "sequelpg_test_\(server)", "psql", "-X", "-At", "-v", "ON_ERROR_STOP=1",
            "-U", config.admin.user, "-d", database ?? config.database, "-c", sql,
        ]
        let out = Pipe()
        let err = Pipe()
        process.standardOutput = out
        process.standardError = err
        try process.run()
        process.waitUntilExit()
        let stdout = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        guard process.terminationStatus == 0 else {
            throw Failure("psql: " + String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self))
        }
        return stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// JSON for `SEQUELPG_UITEST_PROFILES` (the app's `ConnectionProfile` + secrets).
struct SeedProfile: Encodable {
    var id = UUID()
    var name: String
    var host = "127.0.0.1"
    var port = Cluster.port()
    var database = Cluster.config.database
    var username = Cluster.role("scram").user
    var sslMode = "off"
    var sslSkipVerification = false
    var sslRootCertPath = ""
    var useSSHTunnel = false
    var sshHost = ""
    var sshPort = 22
    var sshUser = ""
    var sshAuthMethod = "keyFile"
    var sshKeyPath = ""
    var password: String? = Cluster.role("scram").password
    var sshPassword: String?

    init(_ name: String, server: String = "pg18", role: String = "scram") {
        self.name = name
        port = Cluster.port(server)
        username = Cluster.role(role).user
        password = Cluster.role(role).password
    }

    /// pg18 reached through the SSH bastion with the test key.
    static func viaSSH(_ name: String, keyPath: String = Cluster.sshClientKey) -> SeedProfile {
        var seed = SeedProfile(name)
        seed.host = Cluster.config.ssh.targetHost
        seed.port = Cluster.config.ssh.targetPort
        seed.useSSHTunnel = true
        seed.sshHost = Cluster.config.host
        seed.sshPort = Cluster.config.ssh.port
        seed.sshUser = Cluster.config.ssh.user
        seed.sshKeyPath = keyPath
        return seed
    }

    private enum ProfileKeys: String, CodingKey {
        case id, name, host, port, database, username, sslMode, sslSkipVerification, sslRootCertPath,
             useSSHTunnel, sshHost, sshPort, sshUser, sshAuthMethod, sshKeyPath
    }

    private enum Keys: String, CodingKey { case profile, password, sshPassword }

    func encode(to encoder: Encoder) throws {
        var outer = encoder.container(keyedBy: Keys.self)
        var profile = outer.nestedContainer(keyedBy: ProfileKeys.self, forKey: .profile)
        try profile.encode(id, forKey: .id)
        try profile.encode(name, forKey: .name)
        try profile.encode(host, forKey: .host)
        try profile.encode(port, forKey: .port)
        try profile.encode(database, forKey: .database)
        try profile.encode(username, forKey: .username)
        try profile.encode(sslMode, forKey: .sslMode)
        try profile.encode(sslSkipVerification, forKey: .sslSkipVerification)
        try profile.encode(sslRootCertPath, forKey: .sslRootCertPath)
        try profile.encode(useSSHTunnel, forKey: .useSSHTunnel)
        try profile.encode(sshHost, forKey: .sshHost)
        try profile.encode(sshPort, forKey: .sshPort)
        try profile.encode(sshUser, forKey: .sshUser)
        try profile.encode(sshAuthMethod, forKey: .sshAuthMethod)
        try profile.encode(sshKeyPath, forKey: .sshKeyPath)
        try outer.encodeIfPresent(password, forKey: .password)
        try outer.encodeIfPresent(sshPassword, forKey: .sshPassword)
    }
}

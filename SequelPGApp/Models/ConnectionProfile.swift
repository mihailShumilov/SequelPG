import Foundation

/// SSL mode for PostgreSQL connections.
enum SSLMode: String, Codable, CaseIterable, Sendable {
    case off = "off"
    case prefer = "prefer"
    case require = "require"

    var displayName: String {
        switch self {
        case .off: return "Off"
        case .prefer: return "Prefer"
        case .require: return "Require"
        }
    }
}

/// SSH authentication method for tunnel connections.
enum SSHAuthMethod: String, Codable, CaseIterable, Sendable {
    case keyFile = "keyFile"
    case password = "password"

    var displayName: String {
        switch self {
        case .keyFile: return "Key File"
        case .password: return "Password"
        }
    }
}

/// A saved database connection profile. Password is stored separately in Keychain.
struct ConnectionProfile: Identifiable, Codable, Sendable, Equatable {
    let id: UUID
    var name: String
    var host: String
    var port: Int
    var database: String
    var username: String
    var sslMode: SSLMode

    // SSH tunnel settings
    var useSSHTunnel: Bool
    var sshHost: String
    var sshPort: Int
    var sshUser: String
    var sshAuthMethod: SSHAuthMethod
    var sshKeyPath: String

    init(
        id: UUID = UUID(),
        name: String,
        host: String,
        port: Int = 5432,
        database: String,
        username: String,
        sslMode: SSLMode = .prefer,
        useSSHTunnel: Bool = false,
        sshHost: String = "",
        sshPort: Int = 22,
        sshUser: String = "",
        sshAuthMethod: SSHAuthMethod = .keyFile,
        sshKeyPath: String = ""
    ) {
        self.id = id
        self.name = name
        self.host = host
        self.port = port
        self.database = database
        self.username = username
        self.sslMode = sslMode
        self.useSSHTunnel = useSSHTunnel
        self.sshHost = sshHost
        self.sshPort = sshPort
        self.sshUser = sshUser
        self.sshAuthMethod = sshAuthMethod
        self.sshKeyPath = sshKeyPath
    }

    /// Backward-compatible decoding: SSH fields default if absent.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        host = try container.decode(String.self, forKey: .host)
        port = try container.decode(Int.self, forKey: .port)
        database = try container.decode(String.self, forKey: .database)
        username = try container.decode(String.self, forKey: .username)
        sslMode = try container.decode(SSLMode.self, forKey: .sslMode)
        useSSHTunnel = try container.decodeIfPresent(Bool.self, forKey: .useSSHTunnel) ?? false
        sshHost = try container.decodeIfPresent(String.self, forKey: .sshHost) ?? ""
        sshPort = try container.decodeIfPresent(Int.self, forKey: .sshPort) ?? 22
        sshUser = try container.decodeIfPresent(String.self, forKey: .sshUser) ?? ""
        sshAuthMethod = try container.decodeIfPresent(SSHAuthMethod.self, forKey: .sshAuthMethod) ?? .keyFile
        sshKeyPath = try container.decodeIfPresent(String.self, forKey: .sshKeyPath) ?? ""
    }

    /// Keychain key for storing the database password.
    var keychainKey: String {
        "SequelPG:\(id.uuidString)"
    }

    /// Keychain key for storing the SSH password.
    var sshKeychainKey: String {
        "SequelPGSSH:\(id.uuidString)"
    }

    /// Validates that required fields are non-empty and port is valid.
    func validate() -> [String] {
        var errors: [String] = []
        if name.trimmingCharacters(in: .whitespaces).isEmpty {
            errors.append("Name is required.")
        }
        if host.trimmingCharacters(in: .whitespaces).isEmpty {
            errors.append("Host is required.")
        }
        if database.trimmingCharacters(in: .whitespaces).isEmpty {
            errors.append("Database is required.")
        }
        if username.trimmingCharacters(in: .whitespaces).isEmpty {
            errors.append("Username is required.")
        }
        if port < 1 || port > 65535 {
            errors.append("Port must be between 1 and 65535.")
        }
        if useSSHTunnel {
            if sshHost.trimmingCharacters(in: .whitespaces).isEmpty {
                errors.append("SSH Host is required when using SSH tunnel.")
            }
            if sshUser.trimmingCharacters(in: .whitespaces).isEmpty {
                errors.append("SSH User is required when using SSH tunnel.")
            }
            if sshPort < 1 || sshPort > 65535 {
                errors.append("SSH Port must be between 1 and 65535.")
            }
        }
        return errors
    }
}

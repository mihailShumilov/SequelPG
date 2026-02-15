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

/// A saved database connection profile. Password is stored separately in Keychain.
struct ConnectionProfile: Identifiable, Codable, Sendable, Equatable {
    let id: UUID
    var name: String
    var host: String
    var port: Int
    var database: String
    var username: String
    var sslMode: SSLMode

    init(
        id: UUID = UUID(),
        name: String,
        host: String,
        port: Int = 5432,
        database: String,
        username: String,
        sslMode: SSLMode = .prefer
    ) {
        self.id = id
        self.name = name
        self.host = host
        self.port = port
        self.database = database
        self.username = username
        self.sslMode = sslMode
    }

    /// Keychain key for storing the password.
    var keychainKey: String {
        "SequelPG:\(id.uuidString)"
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
        return errors
    }
}

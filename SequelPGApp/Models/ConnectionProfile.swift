import Foundation

/// SSL mode for PostgreSQL connections.
enum SSLMode: String, Codable, CaseIterable, Sendable {
    case off = "off"
    case prefer = "prefer"
    case require = "require"
    case verifyCa = "verify-ca"
    case verifyFull = "verify-full"

    var displayName: String {
        switch self {
        case .off: return "Off"
        case .prefer: return "Prefer"
        case .require: return "Require"
        case .verifyCa: return "Verify CA"
        case .verifyFull: return "Verify Full"
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
///
/// SSH fields use `@DecodableDefault` so older profiles (stored before SSH support
/// was added) decode cleanly without a custom `init(from:)`.
struct ConnectionProfile: Identifiable, Codable, Sendable, Equatable {
    let id: UUID
    var name: String
    var host: String
    var port: Int
    var database: String
    var username: String
    var sslMode: SSLMode

    @DecodableDefault.False var useSSHTunnel: Bool
    @DecodableDefault.EmptyString var sshHost: String
    @DecodableDefault.SSHPort var sshPort: Int
    @DecodableDefault.EmptyString var sshUser: String
    @DecodableDefault.KeyFileAuth var sshAuthMethod: SSHAuthMethod
    @DecodableDefault.EmptyString var sshKeyPath: String

    init(
        id: UUID = UUID(),
        name: String,
        host: String,
        port: Int = 5432,
        database: String,
        username: String,
        sslMode: SSLMode = .require,
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

/// Property wrapper that supplies a default value when a Codable key is missing.
/// Lets `ConnectionProfile` use synthesized `Codable` instead of a manual
/// `init(from:)` while still accepting profiles saved before SSH fields existed.
enum DecodableDefault {
    protocol Source {
        associatedtype Value: Codable & Sendable & Equatable
        static var defaultValue: Value { get }
    }

    @propertyWrapper
    struct Wrapper<S: DecodableDefault.Source>: Codable, Sendable, Equatable {
        typealias Value = S.Value
        var wrappedValue: Value

        init(wrappedValue: Value = S.defaultValue) {
            self.wrappedValue = wrappedValue
        }

        init(from decoder: Decoder) throws {
            wrappedValue = try Value(from: decoder)
        }

        func encode(to encoder: Encoder) throws {
            try wrappedValue.encode(to: encoder)
        }
    }

    typealias False = Wrapper<Sources.False>
    typealias EmptyString = Wrapper<Sources.EmptyString>
    typealias SSHPort = Wrapper<Sources.SSHPort>
    typealias KeyFileAuth = Wrapper<Sources.KeyFileAuth>

    enum Sources {
        enum False: Source {
            static let defaultValue = false
        }
        enum EmptyString: Source {
            static let defaultValue = ""
        }
        enum SSHPort: Source {
            static let defaultValue = 22
        }
        enum KeyFileAuth: Source {
            static let defaultValue: SSHAuthMethod = .keyFile
        }
    }
}

extension KeyedDecodingContainer {
    /// Supplies the wrapper's default value when the key is absent from the payload.
    func decode<S>(_ type: DecodableDefault.Wrapper<S>.Type, forKey key: Key) throws -> DecodableDefault.Wrapper<S> {
        try decodeIfPresent(type, forKey: key) ?? .init()
    }
}

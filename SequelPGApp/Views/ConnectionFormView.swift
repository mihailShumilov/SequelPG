import SwiftUI

/// Consolidates the 14 form fields the start page's connection editor works
/// with so loading, serialising, and defaulting a profile live in one place.
///
/// Port values live as `String` because the UI exposes them through `TextField`;
/// they're coerced to `Int` via `buildProfile(id:fallbackPort:)`.
struct ConnectionFormModel {
    var name: String = ""
    var host: String = ""
    var port: String = "5432"
    var database: String = ""
    var username: String = ""
    var password: String = ""
    var sslMode: SSLMode = .prefer

    var useSSHTunnel: Bool = false
    var sshHost: String = ""
    var sshPort: String = "22"
    var sshUser: String = ""
    var sshAuthMethod: SSHAuthMethod = .keyFile
    var sshKeyPath: String = ""
    var sshPassword: String = ""

    mutating func load(
        from profile: ConnectionProfile,
        password: String,
        sshPassword: String
    ) {
        name = profile.name
        host = profile.host
        port = String(profile.port)
        database = profile.database
        username = profile.username
        sslMode = profile.sslMode
        self.password = password

        useSSHTunnel = profile.useSSHTunnel
        sshHost = profile.sshHost
        sshPort = String(profile.sshPort)
        sshUser = profile.sshUser
        sshAuthMethod = profile.sshAuthMethod
        sshKeyPath = profile.sshKeyPath
        self.sshPassword = sshPassword
    }

    /// Builds a `ConnectionProfile` from the current field values.
    /// - Parameters:
    ///   - id: Profile ID to preserve; pass a new UUID for add flows.
    ///   - fallbackPort: Value to use when `port` isn't a valid integer. Defaults
    ///     to 5432 to match the PostgreSQL default.
    func buildProfile(id: UUID, fallbackPort: Int = 5432) -> ConnectionProfile {
        let portInt = Int(port) ?? fallbackPort
        let sshPortInt = Int(sshPort) ?? 22
        return ConnectionProfile(
            id: id,
            name: name.trimmingCharacters(in: .whitespaces),
            host: host.trimmingCharacters(in: .whitespaces),
            port: portInt,
            database: database.trimmingCharacters(in: .whitespaces),
            username: username.trimmingCharacters(in: .whitespaces),
            sslMode: sslMode,
            useSSHTunnel: useSSHTunnel,
            sshHost: sshHost.trimmingCharacters(in: .whitespaces),
            sshPort: sshPortInt,
            sshUser: sshUser.trimmingCharacters(in: .whitespaces),
            sshAuthMethod: sshAuthMethod,
            sshKeyPath: sshKeyPath.trimmingCharacters(in: .whitespaces)
        )
    }

    /// `sshPassword` wrapped as optional, honoring the tunnel toggle.
    var effectiveSSHPassword: String? { useSSHTunnel ? sshPassword : nil }
}

import Foundation

/// What the user allowed MCP clients to do: whether the server runs, which
/// clients were approved and which connections are shared.
struct MCPAuthorizationState: Codable, Equatable, Sendable {
    var enabled = false
    var approvedClients: [String] = []
    var sharedConnections: [UUID: MCPAccess] = [:]

    func access(for profileID: UUID) -> MCPAccess {
        sharedConnections[profileID] ?? .off
    }
}

/// Keeps `MCPAuthorizationState` in the Keychain rather than in UserDefaults.
///
/// Any process running as the user can rewrite the app's preferences with
/// `defaults write`; it can't silently change the app's Keychain items. So
/// another program can't switch the server on, approve itself or share a
/// connection behind the user's back. `ConnectionProfile.mcpAccess` mirrors
/// this state for the UI; the Keychain copy is the one that counts. A missing
/// or unreadable item reads as "everything off".
final class MCPAuthorizationStore: @unchecked Sendable {
    static let keychainKey = "SequelPGMCP:authorization"

    private let keychain: KeychainServiceProtocol
    private let lock = NSLock()

    init(keychain: KeychainServiceProtocol) {
        self.keychain = keychain
    }

    func load() -> MCPAuthorizationState {
        lock.withLock { unlockedLoad() }
    }

    /// Applies `change` and saves the result atomically with respect to
    /// other callers in this process.
    @discardableResult
    func update(_ change: (inout MCPAuthorizationState) -> Void) -> MCPAuthorizationState {
        lock.withLock {
            var state = unlockedLoad()
            change(&state)
            do {
                let data = try JSONEncoder().encode(state)
                try keychain.save(password: String(decoding: data, as: UTF8.self), forKey: Self.keychainKey)
            } catch {
                Log.mcp.error("Failed to save MCP settings to Keychain: \(error.localizedDescription, privacy: .public)")
            }
            return state
        }
    }

    /// Records `access` for a connection. Writes only when it changes, so
    /// users who never share a connection get no Keychain item at all.
    func setAccess(_ access: MCPAccess, for profileID: UUID) {
        guard load().access(for: profileID) != access else { return }
        update { $0.sharedConnections[profileID] = access == .off ? nil : access }
    }

    private func unlockedLoad() -> MCPAuthorizationState {
        guard let json = try? keychain.load(forKey: Self.keychainKey),
              let state = try? JSONDecoder().decode(MCPAuthorizationState.self, from: Data(json.utf8))
        else { return MCPAuthorizationState() }
        return state
    }
}

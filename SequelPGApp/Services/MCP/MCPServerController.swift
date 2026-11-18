import Foundation
import Observation

/// Owns the in-app MCP server: the persisted on/off switch, starting and
/// stopping the socket listener, and the status shown in Settings.
@MainActor
@Observable
final class MCPServerController {
    static let shared = MCPServerController(
        defaults: TestingHooks.userDefaults,
        store: ConnectionStore(defaults: TestingHooks.userDefaults),
        keychain: TestingHooks.keychainService
    )

    enum Status: Equatable {
        case stopped
        case running
        case failed(String)
    }

    private static let enabledKey = "com.sequelpg.mcp.enabled"

    private let defaults: UserDefaults
    private let store: ConnectionStoreProtocol
    private let pool: MCPSessionPool
    private var server: MCPSocketServer?

    private(set) var status: Status = .stopped

    /// Off by default: the user opts in from Settings → MCP.
    var isEnabled: Bool {
        didSet {
            guard oldValue != isEnabled else { return }
            defaults.set(isEnabled, forKey: Self.enabledKey)
            apply()
        }
    }

    init(defaults: UserDefaults, store: ConnectionStoreProtocol, keychain: KeychainServiceProtocol) {
        self.defaults = defaults
        self.store = store
        pool = MCPSessionPool(keychain: keychain)
        isEnabled = defaults.bool(forKey: Self.enabledKey) || TestingHooks.forcesMCPEnabled
    }

    /// Starts or stops the listener to match `isEnabled`.
    func apply() {
        if isEnabled {
            guard server == nil else { return }
            let server = MCPSocketServer(handler: MCPToolbox(store: store, pool: pool))
            do {
                try server.start()
                self.server = server
                status = .running
            } catch {
                Log.mcp.error("MCP server failed to start: \(error.localizedDescription, privacy: .public)")
                status = .failed(error.localizedDescription)
            }
        } else {
            server?.stop()
            server = nil
            status = .stopped
            let pool = pool
            Task { await pool.closeAll() }
        }
    }

    func shutdown() {
        server?.stop()
        server = nil
    }
}

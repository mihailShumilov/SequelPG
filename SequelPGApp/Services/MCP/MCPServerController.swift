import AppKit
import Foundation
import Observation

/// Owns the in-app MCP server: the persisted on/off switch, starting and
/// stopping the socket listener, which MCP clients the user approved, and
/// the status shown in Settings.
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
    private static let approvedClientsKey = "com.sequelpg.mcp.approvedClients"

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

    /// Client names (from MCP `clientInfo`) the user allowed. Sorted.
    private(set) var approvedClients: [String]

    /// Clients the user turned down; asked again after a relaunch.
    @ObservationIgnored private var deniedClients: Set<String> = []
    @ObservationIgnored private var pendingApprovals: [String: Task<Bool, Never>] = [:]
    /// Shows the approval prompt; replaced in tests.
    @ObservationIgnored var askUser: @MainActor (String) -> Bool = MCPServerController.runApprovalAlert

    init(defaults: UserDefaults, store: ConnectionStoreProtocol, keychain: KeychainServiceProtocol) {
        self.defaults = defaults
        self.store = store
        pool = MCPSessionPool(keychain: keychain)
        isEnabled = defaults.bool(forKey: Self.enabledKey) || TestingHooks.forcesMCPEnabled
        approvedClients = (defaults.stringArray(forKey: Self.approvedClientsKey) ?? []).sorted()
    }

    /// Number of MCP clients connected right now.
    var connectedClientCount: Int { server?.clientCount ?? 0 }

    /// Starts or stops the listener to match `isEnabled`.
    func apply() {
        if isEnabled {
            guard server == nil else { return }
            let toolbox = MCPToolbox(store: store, pool: pool) { [weak self] client in
                await self?.authorize(client) ?? false
            }
            let server = MCPSocketServer(handler: toolbox)
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

    // MARK: - Client approval

    /// Whether `client` may use the tools. The first call from a client the
    /// user hasn't approved shows a prompt; concurrent calls share it.
    ///
    /// The name is what the client reports about itself, so this guards
    /// against surprise, not against a local process that impersonates an
    /// approved client.
    func authorize(_ client: MCPClientInfo?) async -> Bool {
        let name = Self.normalizedName(client)
        if approvedClients.contains(name) || TestingHooks.forcesMCPEnabled { return true }
        if deniedClients.contains(name) { return false }
        if let pending = pendingApprovals[name] { return await pending.value }

        let task = Task { @MainActor in self.askUser(name) }
        pendingApprovals[name] = task
        let allowed = await task.value
        pendingApprovals[name] = nil
        if allowed {
            approvedClients = (approvedClients + [name]).sorted()
            defaults.set(approvedClients, forKey: Self.approvedClientsKey)
        } else {
            deniedClients.insert(name)
        }
        return allowed
    }

    /// Forgets an approval; the client is asked again on its next call.
    func revoke(_ name: String) {
        approvedClients.removeAll { $0 == name }
        defaults.set(approvedClients, forKey: Self.approvedClientsKey)
    }

    nonisolated static func normalizedName(_ client: MCPClientInfo?) -> String {
        let name = client?.name.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return name.isEmpty ? "Unknown client" : String(name.prefix(100))
    }

    private static func runApprovalAlert(_ name: String) -> Bool {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Allow “\(name)” to use your SequelPG connections?"
        alert.informativeText = """
            An AI assistant connected through MCP wants to browse the schemas and run read-only queries \
            on the connections you shared with MCP. Query results are sent to the assistant's model provider.

            You can revoke access in Settings → MCP.
            """
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Allow")
        alert.addButton(withTitle: "Don’t Allow")
        return alert.runModal() == .alertFirstButtonReturn
    }
}

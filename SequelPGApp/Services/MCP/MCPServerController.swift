import AppKit
import Foundation
import Observation

/// Owns the in-app MCP server: the on/off switch, starting and stopping the
/// socket listener, which MCP clients the user approved, and the status
/// shown in Settings. Switch and approvals live in `MCPAuthorizationStore`
/// (the Keychain), not in UserDefaults.
@MainActor
@Observable
final class MCPServerController {
    static let shared = MCPServerController(
        store: ConnectionStore(defaults: TestingHooks.userDefaults),
        keychain: TestingHooks.keychainService
    )

    enum Status: Equatable {
        case stopped
        case running
        case failed(String)
    }

    private let authorization: MCPAuthorizationStore
    private let store: ConnectionStoreProtocol
    private let keychain: KeychainServiceProtocol
    /// Sessions of the running server; a new pool per start, so a pool
    /// being closed after a stop can't touch the next server's sessions.
    private var pool: MCPSessionPool?
    private var server: MCPSocketServer?

    private(set) var status: Status = .stopped

    /// Off by default: the user opts in from Settings → MCP.
    var isEnabled: Bool {
        didSet {
            guard oldValue != isEnabled else { return }
            let enabled = isEnabled
            authorization.update { $0.enabled = enabled }
            apply()
        }
    }

    /// Client names (from MCP `clientInfo`) the user allowed. Sorted.
    private(set) var approvedClients: [String]

    /// Clients the user turned down; asked again after a relaunch.
    @ObservationIgnored private var deniedClients: Set<String> = []
    @ObservationIgnored private var pendingApprovals: [String: Task<Bool, Never>] = [:]
    /// The last prompt shown or queued; prompts appear one at a time.
    @ObservationIgnored private var lastPrompt: Task<Bool, Never>?
    /// Shows the approval prompt; replaced in tests.
    @ObservationIgnored var askUser: @MainActor (String) -> Bool = MCPServerController.runApprovalAlert

    init(store: ConnectionStoreProtocol, keychain: KeychainServiceProtocol) {
        self.store = store
        self.keychain = keychain
        authorization = MCPAuthorizationStore(keychain: keychain)
        let state = authorization.load()
        isEnabled = state.enabled || TestingHooks.forcesMCPEnabled
        approvedClients = state.approvedClients.sorted()
    }

    /// Number of MCP clients connected right now.
    var connectedClientCount: Int { server?.clientCount ?? 0 }

    /// Starts or stops the listener to match `isEnabled`.
    func apply() {
        if isEnabled {
            guard server == nil else { return }
            let pool = MCPSessionPool(keychain: keychain)
            let toolbox = MCPToolbox(store: store, authorization: authorization, pool: pool) { [weak self] client in
                await self?.authorize(client) ?? false
            }
            let server = MCPSocketServer(handler: toolbox)
            do {
                try server.start()
                self.server = server
                self.pool = pool
                status = .running
            } catch {
                Log.mcp.error("MCP server failed to start: \(error.localizedDescription, privacy: .public)")
                status = .failed(error.localizedDescription)
            }
        } else {
            server?.stop()
            server = nil
            status = .stopped
            if let pool {
                Task { await pool.closeAll() }
            }
            pool = nil
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

        let previous = lastPrompt
        let task = Task { @MainActor in
            _ = await previous?.value
            return self.askUser(name)
        }
        lastPrompt = task
        pendingApprovals[name] = task
        let allowed = await task.value
        pendingApprovals[name] = nil
        if allowed {
            let state = authorization.update { state in
                if !state.approvedClients.contains(name) { state.approvedClients.append(name) }
            }
            approvedClients = state.approvedClients.sorted()
        } else {
            deniedClients.insert(name)
        }
        return allowed
    }

    /// Forgets an approval; the client is asked again on its next call.
    func revoke(_ name: String) {
        let state = authorization.update { state in state.approvedClients.removeAll { $0 == name } }
        approvedClients = state.approvedClients.sorted()
    }

    nonisolated static func normalizedName(_ client: MCPClientInfo?) -> String {
        // Self-reported and shown in an alert: keep it to one short line of
        // printable characters.
        let printable = (client?.name ?? "").unicodeScalars.filter {
            !CharacterSet.controlCharacters.contains($0) && !CharacterSet.newlines.contains($0)
                && $0.properties.generalCategory != .format
        }
        let name = String(String.UnicodeScalarView(printable)).trimmingCharacters(in: .whitespaces)
        return name.isEmpty ? "Unknown client" : String(name.prefix(60))
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

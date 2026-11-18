import Foundation

/// Database sessions used by MCP tool calls, one per (connection, database).
/// They are separate from the UI's: an AI client never switches the user's
/// database, invalidates their caches or competes with their Stop button.
/// Idle sessions are closed after `idleTimeout`.
actor MCPSessionPool {
    typealias ClientFactory = @Sendable () -> any PostgresClientProtocol

    struct Key: Hashable {
        let profileID: UUID
        let database: String
    }

    private struct Entry {
        let client: any PostgresClientProtocol
        /// The profile as it was when connecting; an edited profile reconnects.
        let profile: ConnectionProfile
        var lastUsed: Date
    }

    private let keychain: KeychainServiceProtocol
    private let makeClient: ClientFactory
    private let idleTimeout: TimeInterval
    private var entries: [Key: Entry] = [:]
    private var connecting: [Key: Task<any PostgresClientProtocol, Error>] = [:]
    private var sweeper: Task<Void, Never>?

    init(
        keychain: KeychainServiceProtocol,
        idleTimeout: TimeInterval = 300,
        makeClient: @escaping ClientFactory = { DatabaseClient() }
    ) {
        self.keychain = keychain
        self.idleTimeout = idleTimeout
        self.makeClient = makeClient
    }

    /// A connected client for `profile`, on `database` (the profile's own by
    /// default). Concurrent callers for the same key share one connect.
    func client(for profile: ConnectionProfile, database: String? = nil) async throws -> any PostgresClientProtocol {
        let database = (database?.isEmpty == false ? database : nil) ?? profile.database
        let key = Key(profileID: profile.id, database: database)

        var target = profile
        target.database = database

        if let entry = entries[key] {
            if entry.profile == target, await entry.client.isConnected {
                entries[key]?.lastUsed = Date()
                return entry.client
            }
            entries[key] = nil
            await entry.client.disconnect()
        }

        if let pending = connecting[key] {
            return try await pending.value
        }

        let password = try? keychain.load(forKey: profile.keychainKey)
        let sshPassword = profile.useSSHTunnel && profile.sshAuthMethod == .password
            ? try? keychain.load(forKey: profile.sshKeychainKey)
            : nil
        let client = makeClient()
        let task = Task<any PostgresClientProtocol, Error> {
            try await client.connect(profile: target, password: password, sshPassword: sshPassword)
            return client
        }
        connecting[key] = task
        defer { connecting[key] = nil }
        let connected = try await task.value
        entries[key] = Entry(client: connected, profile: target, lastUsed: Date())
        startSweeper()
        return connected
    }

    /// Disconnects every session.
    func closeAll() async {
        sweeper?.cancel()
        sweeper = nil
        let clients = entries.values.map(\.client)
        entries.removeAll()
        for client in clients {
            await client.disconnect()
        }
    }

    var openSessionCount: Int { entries.count }

    // MARK: - Idle sweep

    private func startSweeper() {
        guard sweeper == nil else { return }
        let interval = max(idleTimeout / 4, 1)
        sweeper = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
                guard let self, await self.sweep() else { return }
            }
        }
    }

    /// Closes idle sessions. Returns `false` once none are left, ending the sweeper.
    private func sweep() async -> Bool {
        let cutoff = Date().addingTimeInterval(-idleTimeout)
        let idle = entries.filter { $0.value.lastUsed < cutoff }
        for (key, entry) in idle {
            entries[key] = nil
            await entry.client.disconnect()
        }
        if entries.isEmpty {
            sweeper = nil
            return false
        }
        return true
    }
}

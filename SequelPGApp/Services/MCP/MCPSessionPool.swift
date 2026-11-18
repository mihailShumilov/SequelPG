import Foundation

/// Database sessions used by MCP tool calls, one per (connection, database).
/// They are separate from the UI's: an AI client never switches the user's
/// database, invalidates their caches or competes with their Stop button.
/// Idle sessions are closed after `idleTimeout`.
///
/// Actor reentrancy: state may change across every `await`, so entries are
/// compared by identity before they are replaced or removed, and clients
/// that lose a race are disconnected in the background rather than awaited.
actor MCPSessionPool {
    typealias ClientFactory = @Sendable () -> any PostgresClientProtocol

    struct Key: Hashable {
        let profileID: UUID
        let database: String
    }

    private struct Entry {
        let client: any PostgresClientProtocol
        let token: UUID
        /// The profile as it was when connecting; an edited profile reconnects.
        let profile: ConnectionProfile
        var lastUsed: Date
    }

    private struct PendingConnect {
        let token: UUID
        let profile: ConnectionProfile
        let task: Task<any PostgresClientProtocol, Error>
    }

    /// Most sessions kept open at once (each holds a small connection pool,
    /// and an SSH tunnel when configured); the least recently used is closed.
    static let maxSessions = 6

    private let keychain: KeychainServiceProtocol
    private let makeClient: ClientFactory
    private let idleTimeout: TimeInterval
    private var entries: [Key: Entry] = [:]
    private var connecting: [Key: PendingConnect] = [:]
    private var sweeper: Task<Void, Never>?
    /// Bumped by `closeAll`; a connect that started earlier is discarded.
    private var generation = 0

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
    /// default). Concurrent callers for the same settings share one connect.
    func client(for profile: ConnectionProfile, database: String? = nil) async throws -> any PostgresClientProtocol {
        let database = (database?.isEmpty == false ? database : nil) ?? profile.database
        let key = Key(profileID: profile.id, database: database)
        var target = profile
        target.database = database

        if let entry = entries[key] {
            let usable = entry.profile == target ? await entry.client.isConnected : false
            if usable, entries[key]?.token == entry.token {
                entries[key]?.lastUsed = Date()
                return entry.client
            }
            if !usable {
                discard(key, token: entry.token)
            } else {
                // Replaced while we checked it: look again.
                return try await client(for: profile, database: database)
            }
        }

        if let pending = connecting[key], pending.profile == target {
            return try await pending.task.value
        }

        let startedGeneration = generation
        let password = try? keychain.load(forKey: profile.keychainKey)
        let sshPassword = profile.useSSHTunnel && profile.sshAuthMethod == .password
            ? try? keychain.load(forKey: profile.sshKeychainKey)
            : nil
        let client = makeClient()
        let token = UUID()
        let task = Task<any PostgresClientProtocol, Error> {
            try await client.connect(profile: target, password: password, sshPassword: sshPassword)
            do {
                if target.mcpAccess.refusesPrivilegedRoles {
                    try await Self.verifyRole(of: client)
                }
            } catch {
                await client.disconnect()
                throw error
            }
            return client
        }
        connecting[key] = PendingConnect(token: token, profile: target, task: task)
        defer {
            if connecting[key]?.token == token {
                connecting[key] = nil
            }
        }
        let connected = try await task.value

        guard generation == startedGeneration else {
            Task { await connected.disconnect() }
            throw CancellationError()
        }
        if let previous = entries[key] {
            discard(key, token: previous.token)
        }
        while entries.count >= Self.maxSessions,
              let oldest = entries.min(by: { $0.value.lastUsed < $1.value.lastUsed }) {
            discard(oldest.key, token: oldest.value.token)
        }
        entries[key] = Entry(client: connected, token: token, profile: target, lastUsed: Date())
        startSweeper()
        return connected
    }

    /// Refuses roles for which a read-only transaction is no real limit:
    /// superusers, and members of the roles that run programs or read and
    /// write files on the database server (`COPY … PROGRAM`, `lo_export`,
    /// `pg_read_file`…).
    static func verifyRole(of client: any PostgresClientProtocol) async throws {
        let result = try await client.runReadOnlyQuery(privilegeQuery, maxRows: 1, timeout: 10)
        guard let row = result.rows.first,
              let flagIndex = result.columns.firstIndex(of: "privileged"),
              case let .text(flag) = row[flagIndex],
              ["t", "true"].contains(flag.lowercased()) else { return }
        var role = "This role"
        if let nameIndex = result.columns.firstIndex(of: "role"), case let .text(name) = row[nameIndex] {
            role = "The role \"\(name)\""
        }
        throw ToolError(
            "\(role) is a superuser or can run programs or read and write files on the database server, so "
                + "SequelPG doesn't let AI assistants use it: a read-only transaction can't contain those "
                + "privileges. In SequelPG, point this connection at a role with only the privileges the "
                + "assistant needs (for example SELECT on your schemas). For a local development database, "
                + "the user can instead set the connection's MCP Access to "
                + "\"\(MCPAccess.readOnlyAnyRole.displayName)\"."
        )
    }

    static let privilegeQuery = """
    SELECT r.rolname AS role,
           r.rolsuper OR EXISTS (
               SELECT 1 FROM pg_catalog.pg_roles g
               WHERE g.rolname IN ('pg_execute_server_program', 'pg_write_server_files', 'pg_read_server_files')
                 AND pg_catalog.pg_has_role(r.oid, g.oid, 'MEMBER')
           ) AS privileged
    FROM pg_catalog.pg_roles r
    WHERE r.rolname = current_user
    """

    /// Disconnects every session, including connects still in progress.
    func closeAll() async {
        generation += 1
        sweeper?.cancel()
        sweeper = nil
        let clients = entries.values.map(\.client)
        entries.removeAll()
        for client in clients {
            await client.disconnect()
        }
    }

    var openSessionCount: Int {
        entries.count
    }

    /// Removes the entry if it is still `token`'s, disconnecting in the background.
    private func discard(_ key: Key, token: UUID) {
        guard let entry = entries[key], entry.token == token else { return }
        entries[key] = nil
        let client = entry.client
        Task { await client.disconnect() }
    }

    // MARK: - Idle sweep

    private func startSweeper() {
        guard sweeper == nil else { return }
        let interval = max(idleTimeout / 4, 1)
        sweeper = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
                guard let self, await sweep() else { return }
            }
        }
    }

    /// Closes idle sessions. Returns `false` once none are left, ending the sweeper.
    private func sweep() -> Bool {
        let cutoff = Date().addingTimeInterval(-idleTimeout)
        for (key, entry) in entries where entry.lastUsed < cutoff {
            discard(key, token: entry.token)
        }
        if entries.isEmpty {
            sweeper = nil
            return false
        }
        return true
    }
}

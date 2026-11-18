import Darwin
import Foundation

/// Listens on the MCP Unix socket inside the app and runs one `MCPSession`
/// per connected bridge. Accepting and reading use blocking calls on
/// dedicated threads; each client's writes and its final close go through
/// that client's serial queue.
final class MCPSocketServer: @unchecked Sendable {
    private let path: String
    private let handler: MCPToolHandling
    /// Accept only the app's own `--mcp-stdio` bridge. Tests turn it off.
    private let requireTrustedPeer: Bool

    private let lock = NSLock()
    private var listenFD: Int32 = -1
    private var clients: [ObjectIdentifier: ClientConnection] = [:]

    init(path: String = MCPSocket.defaultPath, handler: MCPToolHandling, requireTrustedPeer: Bool = true) {
        self.path = path
        self.handler = handler
        self.requireTrustedPeer = requireTrustedPeer
    }

    deinit { stop() }

    var isRunning: Bool { lock.withLock { listenFD >= 0 } }

    /// Number of connected clients.
    var clientCount: Int { lock.withLock { clients.count } }

    enum StartError: LocalizedError {
        case alreadyInUse(String)

        var errorDescription: String? {
            switch self {
            case let .alreadyInUse(path):
                return "Another SequelPG instance is already serving MCP at \(path)."
            }
        }
    }

    /// Binds the socket (owner-only permissions in an owner-only folder) and
    /// starts accepting. Refuses to take over a socket another running
    /// instance still serves; a stale file from a crash is replaced.
    func start() throws {
        guard !isRunning else { return }
        let directory = (path as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        if FileManager.default.fileExists(atPath: path) {
            if let probe = MCPSocket.connect(to: path) {
                close(probe)
                throw StartError.alreadyInUse(path)
            }
            unlink(path)
        }

        let fd = try MCPSocket.makeSocket()
        do {
            // umask keeps the socket file private from the moment it exists.
            let oldMask = umask(0o077)
            let bound = try MCPSocket.withAddress(path) { bind(fd, $0, $1) }
            umask(oldMask)
            guard bound == 0 else { throw MCPSocket.SocketError.system("bind", errno) }
            chmod(path, 0o600)
            guard listen(fd, 8) == 0 else { throw MCPSocket.SocketError.system("listen", errno) }
        } catch {
            close(fd)
            throw error
        }

        lock.withLock { listenFD = fd }
        let thread = Thread { [weak self] in self?.acceptLoop(fd) }
        thread.name = "MCP accept"
        thread.start()
        Log.mcp.info("MCP server listening at \(self.path, privacy: .public)")
    }

    /// Stops listening, disconnects every client (cancelling their running
    /// tool calls) and removes the socket file.
    func stop() {
        let (fd, connections): (Int32, [ClientConnection]) = lock.withLock {
            let state = (listenFD, Array(clients.values))
            listenFD = -1
            clients.removeAll()
            return state
        }
        guard fd >= 0 else { return }
        // shutdown() wakes the threads blocked in accept()/read().
        shutdown(fd, SHUT_RDWR)
        close(fd)
        for connection in connections {
            connection.shutdown(cancelling: true)
        }
        unlink(path)
        Log.mcp.info("MCP server stopped")
    }

    // MARK: - Private

    private func acceptLoop(_ fd: Int32) {
        while true {
            let clientFD = accept(fd, nil, nil)
            if clientFD < 0 {
                if errno == EINTR { continue }
                return // listening socket closed by stop()
            }
            MCPSocket.disableSIGPIPE(clientFD)
            if requireTrustedPeer, !MCPSocket.isTrustedPeer(clientFD) {
                let pid = MCPSocket.peerPID(clientFD).map(String.init) ?? "?"
                Log.mcp.error("Rejected MCP connection from untrusted process \(pid, privacy: .public)")
                close(clientFD)
                continue
            }
            let connection = ClientConnection(fd: clientFD, handler: handler)
            let accepted = lock.withLock { () -> Bool in
                guard listenFD >= 0 else { return false }
                clients[ObjectIdentifier(connection)] = connection
                return true
            }
            guard accepted else {
                connection.closeAfterPendingWrites()
                return
            }
            let thread = Thread { [weak self] in
                connection.readLoop()
                _ = self?.lock.withLock { self?.clients.removeValue(forKey: ObjectIdentifier(connection)) }
            }
            thread.name = "MCP client \(clientFD)"
            thread.start()
        }
    }
}

/// One accepted client: owns its file descriptor and session.
///
/// The fd is closed only on `writeQueue`, after every reply queued before
/// it, and nothing touches it once `closed` is set — so a reply finishing
/// late can't write into a descriptor number the system has handed to
/// something else.
private final class ClientConnection: @unchecked Sendable {
    private let fd: Int32
    private let writeQueue: DispatchQueue
    private let lock = NSLock()
    private var closed = false
    private var cancelOnEOF = false
    private(set) var session: MCPSession!

    init(fd: Int32, handler: MCPToolHandling) {
        self.fd = fd
        writeQueue = DispatchQueue(label: "com.sequelpg.mcp.client.\(fd)")
        session = MCPSession(handler: handler) { [weak self] data in
            await self?.write(data)
        }
    }

    private func write(_ data: Data) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            writeQueue.async { [self] in
                if !lock.withLock({ closed }) {
                    MCPSocket.writeAll(fd, data)
                }
                continuation.resume()
            }
        }
    }

    /// Wakes the reader. With `cancelling`, running tool calls are dropped
    /// instead of answered (the server is stopping).
    func shutdown(cancelling: Bool) {
        lock.withLock {
            cancelOnEOF = cancelOnEOF || cancelling
            if !closed { Darwin.shutdown(fd, SHUT_RDWR) }
        }
        if cancelling, let session {
            Task { await session.close() }
        }
    }

    func closeAfterPendingWrites() {
        writeQueue.async { [self] in
            lock.withLock {
                guard !closed else { return }
                closed = true
                close(fd)
            }
        }
    }

    /// Reads requests until EOF, then lets running tool calls reply (the
    /// bridge half-closes after its client's last request) and closes.
    func readLoop() {
        var lines = LineBuffer()
        var chunk = [UInt8](repeating: 0, count: 64 * 1024)
        let session = session!
        // Messages are handed to the session strictly in order.
        let (stream, continuation) = AsyncStream<Data>.makeStream()
        let pump = Task {
            for await line in stream {
                await session.receive(line)
            }
        }
        while true {
            let count = read(fd, &chunk, chunk.count)
            if count < 0, errno == EINTR { continue }
            guard count > 0, let complete = lines.append(Data(chunk[0 ..< count])) else { break }
            for line in complete {
                continuation.yield(line)
            }
        }
        continuation.finish()
        let cancel = lock.withLock { cancelOnEOF }
        Task {
            await pump.value
            if cancel {
                await session.close()
            } else {
                await session.drain()
            }
            closeAfterPendingWrites()
        }
    }
}

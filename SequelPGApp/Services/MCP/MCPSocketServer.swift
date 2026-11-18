import Darwin
import Foundation

/// Listens on the MCP Unix socket inside the app and runs one `MCPSession`
/// per connected bridge. Accepting and reading use blocking calls on
/// dedicated threads; writes go through a per-client serial queue.
final class MCPSocketServer: @unchecked Sendable {
    private let path: String
    private let handler: MCPToolHandling
    /// Accept only the app's own `--mcp-stdio` bridge. Tests turn it off.
    private let requireTrustedPeer: Bool

    private let lock = NSLock()
    private var listenFD: Int32 = -1
    private var clients: [Int32: MCPSession] = [:]

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

    /// Stops listening, disconnects every client and removes the socket file.
    func stop() {
        let (fd, sessions): (Int32, [Int32: MCPSession]) = lock.withLock {
            let state = (listenFD, clients)
            listenFD = -1
            clients.removeAll()
            return state
        }
        guard fd >= 0 else { return }
        // shutdown() wakes the threads blocked in accept()/read().
        shutdown(fd, SHUT_RDWR)
        close(fd)
        for (clientFD, session) in sessions {
            shutdown(clientFD, SHUT_RDWR)
            Task { await session.close() }
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
            let writeQueue = DispatchQueue(label: "com.sequelpg.mcp.write.\(clientFD)")
            let session = MCPSession(handler: handler) { data in
                await withCheckedContinuation { continuation in
                    writeQueue.async {
                        MCPSocket.writeAll(clientFD, data)
                        continuation.resume()
                    }
                }
            }
            let accepted = lock.withLock { () -> Bool in
                guard listenFD >= 0 else { return false }
                clients[clientFD] = session
                return true
            }
            guard accepted else {
                close(clientFD)
                return
            }
            let thread = Thread { [weak self] in self?.readLoop(clientFD, session: session, writeQueue: writeQueue) }
            thread.name = "MCP client \(clientFD)"
            thread.start()
        }
    }

    private func readLoop(_ fd: Int32, session: MCPSession, writeQueue: DispatchQueue) {
        var lines = LineBuffer()
        var chunk = [UInt8](repeating: 0, count: 64 * 1024)
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
        Task {
            await pump.value
            await session.close()
            // Close only after queued replies are written.
            writeQueue.async { close(fd) }
        }
        lock.withLock { _ = clients.removeValue(forKey: fd) }
    }
}

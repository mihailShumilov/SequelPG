import Darwin
import Foundation

/// Unix-domain socket plumbing shared by the in-app MCP server and the
/// `--mcp-stdio` bridge. Messages are newline-delimited JSON-RPC, exactly as
/// on the stdio transport, so the bridge forwards bytes without parsing them.
enum MCPSocket {
    /// DEBUG-only override of the socket path, so tests and a development
    /// build can run beside an installed SequelPG.
    static let socketPathEnvironmentKey = "SEQUELPG_MCP_SOCKET"

    /// Longest path `sockaddr_un.sun_path` holds, minus the terminator.
    static let maxPathLength = MemoryLayout.size(ofValue: sockaddr_un().sun_path) - 1

    /// Where the app listens: `~/Library/Application Support/SequelPG/mcp.sock`.
    static var defaultPath: String {
        #if DEBUG
        if let override = ProcessInfo.processInfo.environment[socketPathEnvironmentKey], !override.isEmpty {
            return override
        }
        #endif
        return TestingHooks.applicationSupportDirectory()
            .appendingPathComponent("SequelPG", isDirectory: true)
            .appendingPathComponent("mcp.sock")
            .path
    }

    enum SocketError: LocalizedError {
        case pathTooLong(String)
        case system(String, Int32)

        var errorDescription: String? {
            switch self {
            case let .pathTooLong(path):
                return "The MCP socket path is too long: \(path)"
            case let .system(call, code):
                return "\(call) failed: \(String(cString: strerror(code)))"
            }
        }
    }

    /// Fills a `sockaddr_un` for `path` and calls `body` with it.
    static func withAddress<T>(_ path: String, _ body: (UnsafePointer<sockaddr>, socklen_t) -> T) throws -> T {
        let bytes = Array(path.utf8)
        guard bytes.count <= maxPathLength else { throw SocketError.pathTooLong(path) }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            raw.copyBytes(from: bytes)
            raw[bytes.count] = 0
        }
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        return withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                body($0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
    }

    /// Opens a stream socket that never raises SIGPIPE.
    static func makeSocket() throws -> Int32 {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw SocketError.system("socket", errno) }
        disableSIGPIPE(fd)
        return fd
    }

    static func disableSIGPIPE(_ fd: Int32) {
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
    }

    /// Connects to `path`; `nil` when nothing listens there.
    static func connect(to path: String) -> Int32? {
        guard let fd = try? makeSocket() else { return nil }
        let result = (try? withAddress(path) { Darwin.connect(fd, $0, $1) }) ?? -1
        guard result == 0 else {
            close(fd)
            return nil
        }
        return fd
    }

    /// Writes all of `data`, retrying short writes. `false` once the peer is gone.
    @discardableResult
    static func writeAll(_ fd: Int32, _ data: Data) -> Bool {
        data.withUnsafeBytes { raw -> Bool in
            guard var pointer = raw.baseAddress else { return true }
            var remaining = raw.count
            while remaining > 0 {
                let written = write(fd, pointer, remaining)
                if written < 0 {
                    if errno == EINTR { continue }
                    return false
                }
                remaining -= written
                pointer += written
            }
            return true
        }
    }

    /// Process id of the connected peer.
    static func peerPID(_ fd: Int32) -> pid_t? {
        var pid: pid_t = 0
        var length = socklen_t(MemoryLayout<pid_t>.size)
        guard getsockopt(fd, SOL_LOCAL, LOCAL_PEERPID, &pid, &length) == 0 else { return nil }
        return pid
    }

    /// Executable path of a process, symlinks resolved.
    static func executablePath(of pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: 4096)
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return nil }
        return URL(fileURLWithPath: String(cString: buffer)).resolvingSymlinksInPath().path
    }

    /// The peer runs as the same user and is this app's own executable — the
    /// `--mcp-stdio` bridge — not some other local process.
    static func isTrustedPeer(_ fd: Int32) -> Bool {
        var uid: uid_t = 0
        var gid: gid_t = 0
        guard getpeereid(fd, &uid, &gid) == 0, uid == getuid() else { return false }
        guard let pid = peerPID(fd), let peerPath = executablePath(of: pid),
              let ownPath = Bundle.main.executableURL?.resolvingSymlinksInPath().path
        else { return false }
        return peerPath == ownPath
    }
}

/// Splits a byte stream into newline-terminated lines.
struct LineBuffer {
    /// Longest accepted line; a peer sending more is dropped.
    static let maxLineLength = 16 * 1024 * 1024

    private var buffer = Data()

    /// Appends `chunk` and returns the complete lines it finished (without
    /// the newline, blank lines skipped). `nil` when a line grew too long.
    mutating func append(_ chunk: Data) -> [Data]? {
        buffer.append(chunk)
        var lines: [Data] = []
        while let newline = buffer.firstIndex(of: 0x0A) {
            var line = buffer[buffer.startIndex ..< newline]
            if line.last == 0x0D { line = line.dropLast() }
            if !line.isEmpty { lines.append(Data(line)) }
            buffer.removeSubrange(buffer.startIndex ... newline)
        }
        if buffer.count > Self.maxLineLength { return nil }
        return lines
    }
}

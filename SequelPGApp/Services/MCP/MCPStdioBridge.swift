import Darwin
import Foundation

/// The process an MCP client (Claude Code, Claude Desktop, Cursor…) starts:
/// `SequelPG.app/Contents/MacOS/SequelPG --mcp-stdio`. It never starts the UI;
/// it connects to the MCP socket of the running app — launching the app in
/// the background when needed — and copies bytes between stdio and the
/// socket. All database work, passwords included, stays inside the app.
enum MCPStdioBridge {
    /// Runs the bridge instead of the app.
    static let argument = "--mcp-stdio"
    /// Passed to the app when the bridge launches it.
    static let launchArgument = "--mcp-launch"

    /// How long to wait for a freshly launched app to start listening.
    static let launchTimeout: TimeInterval = 15

    static var isBridgeInvocation: Bool {
        CommandLine.arguments.contains(argument)
    }

    static func run() -> Never {
        signal(SIGPIPE, SIG_IGN)
        let path = MCPSocket.defaultPath
        guard let fd = connectOrLaunch(path) else {
            failUnavailable(path)
        }

        let upstream = Thread {
            pump(from: STDIN_FILENO, to: fd)
            // Tell the app no more requests are coming; it still writes the
            // pending replies before closing its end.
            shutdown(fd, SHUT_WR)
        }
        upstream.start()
        pump(from: fd, to: STDOUT_FILENO)
        exit(0)
    }

    // MARK: - Private

    private static func connectOrLaunch(_ path: String) -> Int32? {
        if let fd = MCPSocket.connect(to: path) {
            return fd
        }
        launchApp()
        let deadline = Date().addingTimeInterval(launchTimeout)
        while Date() < deadline {
            if let fd = MCPSocket.connect(to: path) {
                return fd
            }
            usleep(200_000)
        }
        return nil
    }

    /// Opens this bundle in the background without activating it.
    private static func launchApp() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = ["-g", "-j", Bundle.main.bundleURL.path, "--args", launchArgument]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            log("Could not launch SequelPG: \(error.localizedDescription)")
        }
    }

    /// Copies bytes until EOF or an error on either side.
    private static func pump(from source: Int32, to destination: Int32) {
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let count = read(source, &buffer, buffer.count)
            if count < 0, errno == EINTR {
                continue
            }
            guard count > 0, MCPSocket.writeAll(destination, Data(buffer[0 ..< count])) else { return }
        }
    }

    static let unavailableMessage = """
    SequelPG's MCP server is not available. Open SequelPG, choose Settings → MCP, \
    and turn on "Enable MCP server".
    """

    /// Answers the client's first request with an explanation, so it shows
    /// the user why the server failed, then exits.
    private static func failUnavailable(_ path: String) -> Never {
        log("No MCP server at \(path). \(unavailableMessage)")
        var lines = LineBuffer()
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let count = read(STDIN_FILENO, &buffer, buffer.count)
            if count < 0, errno == EINTR {
                continue
            }
            guard count > 0, let complete = lines.append(Data(buffer[0 ..< count])) else { break }
            for line in complete {
                guard let message = try? JSONDecoder().decode(JSONValue.self, from: line),
                      let id = message["id"], !id.isNull
                else { continue }
                let response = MCPProtocol.errorResponse(
                    id: id, code: MCPProtocol.ErrorCode.serverUnavailable, message: unavailableMessage
                )
                MCPSocket.writeAll(STDOUT_FILENO, response.encodedLine())
                exit(1)
            }
        }
        exit(1)
    }

    private static func log(_ message: String) {
        FileHandle.standardError.write(Data("sequelpg-mcp: \(message)\n".utf8))
    }
}

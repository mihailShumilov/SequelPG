import Foundation
import OSLog

/// Manages an SSH tunnel process for local port forwarding.
/// Launches `ssh -N -L localPort:remoteHost:remotePort user@sshHost` and
/// monitors the process lifetime.
actor SSHTunnelService {
    private var process: Process?
    private var localPort: UInt16 = 0
    private var askpassURL: URL?

    var isActive: Bool {
        process?.isRunning == true
    }

    var tunnelLocalPort: UInt16 {
        localPort
    }

    /// Starts an SSH tunnel and returns the local port to connect through.
    func start(
        sshHost: String,
        sshPort: Int,
        sshUser: String,
        sshAuthMethod: SSHAuthMethod,
        sshKeyPath: String,
        sshPassword: String?,
        remoteHost: String,
        remotePort: Int
    ) async throws -> UInt16 {
        await stop()

        let port = try Self.findAvailablePort()
        localPort = port

        var args: [String] = [
            "-N", // No remote command
            "-o", "ExitOnForwardFailure=yes",
            "-o", "ServerAliveInterval=30",
            "-o", "ServerAliveCountMax=3",
            "-o", "ConnectTimeout=10",
            "-o", "StrictHostKeyChecking=accept-new",
            "-L", "\(port):\(remoteHost):\(remotePort)",
            "-p", "\(sshPort)",
        ]

        // Auth configuration
        switch sshAuthMethod {
        case .keyFile:
            if !sshKeyPath.isEmpty {
                let expandedPath = NSString(string: sshKeyPath).expandingTildeInPath
                args += ["-i", expandedPath]
            }
            // Disable password auth when using key file
            args += ["-o", "PasswordAuthentication=no"]
        case .password:
            // Disable key-based auth when using password
            args += [
                "-o", "PubkeyAuthentication=no",
                "-o", "PreferredAuthentications=password,keyboard-interactive",
            ]
        }

        args.append("\(sshUser)@\(sshHost)")

        let sshProcess = Process()
        sshProcess.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        sshProcess.arguments = args

        // Capture stderr for error reporting
        let stderrPipe = Pipe()
        sshProcess.standardError = stderrPipe
        sshProcess.standardOutput = FileHandle.nullDevice

        // Set up SSH_ASKPASS for password-based auth
        var environment = ProcessInfo.processInfo.environment
        if sshAuthMethod == .password, let password = sshPassword, !password.isEmpty {
            let askpassFile = try Self.createAskpassScript(password: password)
            askpassURL = askpassFile
            environment["SSH_ASKPASS"] = askpassFile.path
            environment["SSH_ASKPASS_REQUIRE"] = "force"
            // Unset DISPLAY to avoid X11 askpass dialogs
            environment.removeValue(forKey: "DISPLAY")
        }
        // Ensure no terminal prompt by detaching from controlling terminal
        environment["TERM"] = "dumb"
        sshProcess.environment = environment

        // Launch in a new process group so it doesn't inherit our terminal
        sshProcess.qualityOfService = .userInitiated

        do {
            try sshProcess.run()
        } catch {
            cleanupAskpass()
            throw AppError.sshTunnelFailed("Failed to start SSH process: \(error.localizedDescription)")
        }

        process = sshProcess
        Log.ssh.info("SSH tunnel process started (PID: \(sshProcess.processIdentifier)), forwarding localhost:\(port) → \(remoteHost, privacy: .public):\(remotePort) via \(sshUser, privacy: .public)@\(sshHost, privacy: .public):\(sshPort)")

        // Wait for the tunnel to become ready by probing the local port
        do {
            try await waitForPort(port, timeout: 15.0)
        } catch {
            // Read stderr for diagnostics
            let stderrData = stderrPipe.fileHandleForReading.availableData
            let stderrText = String(data: stderrData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            await stop()
            let detail = stderrText.isEmpty ? error.localizedDescription : stderrText
            throw AppError.sshTunnelFailed(detail)
        }

        // Clean up askpass script after connection is established
        cleanupAskpass()

        Log.ssh.info("SSH tunnel ready on localhost:\(port)")
        return port
    }

    func stop() async {
        if let process, process.isRunning {
            process.terminate()
            process.waitUntilExit()
            Log.ssh.info("SSH tunnel process terminated")
        }
        process = nil
        localPort = 0
        cleanupAskpass()
    }

    // MARK: - Private

    private func cleanupAskpass() {
        if let url = askpassURL {
            try? FileManager.default.removeItem(at: url)
            askpassURL = nil
        }
    }

    /// Finds an available TCP port by binding to port 0.
    private static func findAvailablePort() throws -> UInt16 {
        let socketFD = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP)
        guard socketFD >= 0 else {
            throw AppError.sshTunnelFailed("Failed to create socket for port allocation.")
        }
        defer { close(socketFD) }

        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = 0 // Let OS assign
        addr.sin_addr.s_addr = INADDR_LOOPBACK.bigEndian

        let bindResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                bind(socketFD, sockPtr, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0 else {
            throw AppError.sshTunnelFailed("Failed to bind socket for port allocation.")
        }

        var boundAddr = sockaddr_in()
        var addrLen = socklen_t(MemoryLayout<sockaddr_in>.size)
        let nameResult = withUnsafeMutablePointer(to: &boundAddr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                getsockname(socketFD, sockPtr, &addrLen)
            }
        }
        guard nameResult == 0 else {
            throw AppError.sshTunnelFailed("Failed to get assigned port.")
        }

        return UInt16(bigEndian: boundAddr.sin_port)
    }

    /// Creates a temporary executable script that echoes the password for SSH_ASKPASS.
    private static func createAskpassScript(password: String) throws -> URL {
        let tempDir = FileManager.default.temporaryDirectory
        let scriptURL = tempDir.appendingPathComponent("sequelpg-askpass-\(UUID().uuidString).sh")

        // Escape single quotes in password for shell safety
        let escapedPassword = password.replacingOccurrences(of: "'", with: "'\\''")
        let script = "#!/bin/sh\necho '\(escapedPassword)'\n"

        try script.write(to: scriptURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: scriptURL.path
        )
        return scriptURL
    }

    /// Polls the local port until a TCP connection succeeds or timeout expires.
    private func waitForPort(_ port: UInt16, timeout: TimeInterval) async throws {
        let deadline = CFAbsoluteTimeGetCurrent() + timeout
        let interval: UInt64 = 200_000_000 // 200ms

        while CFAbsoluteTimeGetCurrent() < deadline {
            // Check that the SSH process hasn't exited
            if let process, !process.isRunning {
                throw AppError.sshTunnelFailed("SSH process exited with code \(process.terminationStatus).")
            }

            if Self.canConnectToPort(port) {
                return
            }
            try await Task.sleep(nanoseconds: interval)
        }

        throw AppError.sshTunnelFailed("Timed out waiting for SSH tunnel on port \(port).")
    }

    /// Attempts a TCP connection to localhost:port and returns immediately.
    private static func canConnectToPort(_ port: UInt16) -> Bool {
        let socketFD = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP)
        guard socketFD >= 0 else { return false }
        defer { close(socketFD) }

        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr.s_addr = INADDR_LOOPBACK.bigEndian

        let result = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                Darwin.connect(socketFD, sockPtr, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        return result == 0
    }
}

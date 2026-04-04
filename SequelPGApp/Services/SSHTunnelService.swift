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
            "-o", "StrictHostKeyChecking=yes",
            "-L", "\(port):\(remoteHost):\(remotePort)",
            "-p", "\(sshPort)",
        ]

        // Auth configuration
        switch sshAuthMethod {
        case .keyFile:
            if !sshKeyPath.isEmpty {
                let expandedPath = NSString(string: sshKeyPath).expandingTildeInPath
                guard FileManager.default.isReadableFile(atPath: expandedPath) else {
                    throw AppError.sshTunnelFailed("SSH key file not found or not readable: \(sshKeyPath)")
                }
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

            // Log full stderr for diagnostics
            if !stderrText.isEmpty {
                Log.ssh.error("SSH stderr: \(stderrText, privacy: .private)")
            }

            // Detect unknown host key and provide actionable guidance
            if stderrText.contains("Host key verification failed") || stderrText.contains("No matching host key") {
                throw AppError.sshTunnelFailed(
                    "SSH host key verification failed for \(sshHost). "
                        + "The server's host key is not in your known_hosts file. "
                        + "To trust this host, run in Terminal:\n"
                        + "  ssh-keyscan -p \(sshPort) \(sshHost) >> ~/.ssh/known_hosts\n"
                        + "Then retry the connection."
                )
            }

            // Filter out SSH banner/debug lines — only surface error-indicative lines
            let errorLines = stderrText.components(separatedBy: .newlines).filter { line in
                let lower = line.lowercased()
                return lower.contains("error") || lower.contains("denied") || lower.contains("refused")
                    || lower.contains("failed") || lower.contains("timeout") || lower.contains("no route")
                    || lower.contains("could not") || lower.contains("permission")
            }
            let filteredStderr = errorLines.isEmpty ? stderrText : errorLines.joined(separator: "\n")

            let detail = filteredStderr.isEmpty ? error.localizedDescription : filteredStderr
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
            // Remove the entire askpass directory (contains the script and FIFO)
            let dir = url.deletingLastPathComponent()
            try? FileManager.default.removeItem(at: dir)
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

    /// Creates a temporary executable script that reads the password from a FIFO
    /// for SSH_ASKPASS. The password is never written to a regular file on disk.
    private static func createAskpassScript(password: String) throws -> URL {
        let tempDir = FileManager.default.temporaryDirectory
        let uniqueID = UUID().uuidString

        // Create a private directory to hold the FIFO and script
        let askpassDir = tempDir.appendingPathComponent("sequelpg-askpass-\(uniqueID)")
        try FileManager.default.createDirectory(
            at: askpassDir,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )

        let fifoPath = askpassDir.appendingPathComponent("pw").path
        guard mkfifo(fifoPath, 0o600) == 0 else {
            throw AppError.sshTunnelFailed("Failed to create FIFO for SSH_ASKPASS.")
        }

        // The script reads the password from the FIFO instead of embedding it
        let scriptURL = askpassDir.appendingPathComponent("askpass.sh")
        let script = "#!/bin/sh\ncat '\(fifoPath.replacingOccurrences(of: "'", with: "'\\''"))'\n"
        try script.write(to: scriptURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: scriptURL.path
        )

        // Write the password to the FIFO in a background thread.
        // The write blocks until SSH reads from the FIFO via the askpass script,
        // so the password only exists transiently in memory, never on disk.
        let pw = password
        DispatchQueue.global(qos: .userInitiated).async {
            guard let fd = fopen(fifoPath, "w") else { return }
            defer { fclose(fd) }
            pw.withCString { ptr in
                _ = fputs(ptr, fd)
            }
        }

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

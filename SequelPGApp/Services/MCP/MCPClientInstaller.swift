import Foundation

/// Registers SequelPG's MCP bridge with AI clients: Claude Code through its
/// CLI, Claude Desktop and Cursor by merging an entry into their JSON config.
enum MCPClientInstaller {
    /// Server name used in every client's config.
    static let serverName = "sequelpg"

    /// The executable an MCP client launches.
    static var bridgeExecutable: String {
        Bundle.main.executableURL?.path ?? "/Applications/SequelPG.app/Contents/MacOS/SequelPG"
    }

    static var bridgeArguments: [String] { [MCPStdioBridge.argument] }

    /// macOS runs a downloaded app from a randomized read-only location until
    /// it is moved; a path written from there breaks on the next launch.
    static var isTranslocated: Bool {
        bridgeExecutable.contains("/AppTranslocation/")
    }

    enum Client: String, CaseIterable, Identifiable {
        case claudeCode
        case claudeDesktop
        case cursor

        var id: String { rawValue }

        var displayName: String {
            switch self {
            case .claudeCode: return "Claude Code"
            case .claudeDesktop: return "Claude Desktop"
            case .cursor: return "Cursor"
            }
        }

        /// JSON config file, for the clients configured that way.
        var configURL: URL? {
            let home = FileManager.default.homeDirectoryForCurrentUser
            switch self {
            case .claudeCode: return nil
            case .claudeDesktop:
                return home.appendingPathComponent("Library/Application Support/Claude/claude_desktop_config.json")
            case .cursor:
                return home.appendingPathComponent(".cursor/mcp.json")
            }
        }
    }

    // MARK: - Snippets

    /// The `mcpServers` entry, as JSON clients expect it.
    static var serverEntry: [String: Any] {
        ["command": bridgeExecutable, "args": bridgeArguments]
    }

    /// `{"mcpServers": {"sequelpg": {...}}}`, pretty-printed for copying.
    static var jsonSnippet: String {
        let object: [String: Any] = ["mcpServers": [serverName: serverEntry]]
        let data = (try? JSONSerialization.data(
            withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        )) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }

    /// The command that registers the bridge with Claude Code.
    static var claudeCodeCommand: String {
        let parts = ["claude", "mcp", "add", "--scope", "user", serverName, "--", bridgeExecutable]
            + bridgeArguments
        return parts.map(shellQuoted).joined(separator: " ")
    }

    static func shellQuoted(_ value: String) -> String {
        let safe = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_./=:@"))
        if !value.isEmpty, value.unicodeScalars.allSatisfy({ safe.contains($0) }) { return value }
        return "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    // MARK: - Install

    enum InstallError: LocalizedError {
        case claudeCLIFailed(String)
        case invalidConfig(String)

        var errorDescription: String? {
            switch self {
            case let .claudeCLIFailed(output):
                return output.isEmpty
                    ? "The claude command failed. Is Claude Code installed?"
                    : output
            case let .invalidConfig(path):
                return "\(path) isn't valid JSON, so it was left unchanged. Fix it or add the entry by hand."
            }
        }
    }

    /// Adds (or replaces) the SequelPG entry. Returns a message for the user.
    /// Runs processes and file I/O: call off the main actor.
    static func install(_ client: Client) throws -> String {
        switch client {
        case .claudeCode:
            try installInClaudeCode()
            return "Added to Claude Code. Start a new Claude Code session to use it."
        case .claudeDesktop, .cursor:
            guard let url = client.configURL else { return "" }
            try mergeEntry(into: url)
            return "Added to \(client.displayName). Restart \(client.displayName) to use it."
        }
    }

    /// Runs `claude mcp add` through a login shell, so the PATH set up in the
    /// user's shell profile finds the CLI. An existing entry is replaced.
    private static func installInClaudeCode() throws {
        let remove = ["claude", "mcp", "remove", "--scope", "user", serverName].map(shellQuoted).joined(separator: " ")
        let script = "\(remove) >/dev/null 2>&1; \(claudeCodeCommand)"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-lc", script]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        process.standardInput = FileHandle.nullDevice
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            let message = process.terminationStatus == 127
                ? "The claude command wasn't found. Install Claude Code, or run this in Terminal:\n\(claudeCodeCommand)"
                : text
            throw InstallError.claudeCLIFailed(message)
        }
    }

    /// Sets `mcpServers.sequelpg` in a JSON config, keeping everything else.
    /// The previous file is kept next to it as `<name>.bak`.
    static func mergeEntry(into url: URL, fileManager: FileManager = .default) throws {
        var root: [String: Any] = [:]
        if let data = fileManager.contents(atPath: url.path), !data.isEmpty {
            guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw InstallError.invalidConfig(url.path)
            }
            root = object
            let backup = url.appendingPathExtension("bak")
            try? fileManager.removeItem(at: backup)
            try fileManager.copyItem(at: url, to: backup)
        } else {
            try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        }
        var servers = root["mcpServers"] as? [String: Any] ?? [:]
        servers[serverName] = serverEntry
        root["mcpServers"] = servers
        let data = try JSONSerialization.data(
            withJSONObject: root, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        )
        try data.write(to: url, options: .atomic)
    }
}

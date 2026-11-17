import AppKit
import Foundation

/// Hooks that let the automated suites (`test-db/`, `SequelPGIntegrationTests`,
/// `SequelPGUITests`) drive the app deterministically.
///
/// Every hook is active only in DEBUG builds. Release builds compile the same
/// API down to the production behavior, so nothing here can be switched on in
/// a shipped app — not by a launch argument, not by an environment variable.
enum TestingHooks {
    /// Launch argument that puts the app into UI-test mode.
    static let uiTestModeArgument = "-SequelPGUITestMode"

    /// Environment variables read by the hooks. Mirrored in the UI test target
    /// (`UITestEnv.swift`) — keep the two in sync.
    enum Env {
        /// Path to a known_hosts file passed to `ssh` as `UserKnownHostsFile`,
        /// so tests can trust the test bastion without editing ~/.ssh.
        static let sshKnownHostsFile = "SEQUELPG_SSH_KNOWN_HOSTS_FILE"
        /// JSON `[SeedProfile]` written into the empty UI-test store at launch.
        static let seedProfiles = "SEQUELPG_UITEST_PROFILES"
        /// Directory a save panel "chooses" in UI-test mode (file name = the
        /// panel's suggested name).
        static let saveDirectory = "SEQUELPG_UITEST_SAVE_DIR"
        /// File an open panel "chooses" in UI-test mode.
        static let openFile = "SEQUELPG_UITEST_OPEN_FILE"
    }

    /// A connection profile plus its secrets, as handed to the app by UI tests.
    struct SeedProfile: Codable {
        var profile: ConnectionProfile
        var password: String?
        var sshPassword: String?
    }

    #if DEBUG
    static let isUITestMode = ProcessInfo.processInfo.arguments.contains(uiTestModeArgument)
    #else
    static let isUITestMode = false
    #endif

    private static var environment: [String: String] { ProcessInfo.processInfo.environment }

    // MARK: - SSH

    /// Extra `ssh` options for the tunnel. Empty in Release builds and when
    /// the variable is unset.
    static func sshKnownHostsArguments() -> [String] {
        #if DEBUG
        guard let path = environment[Env.sshKnownHostsFile], !path.isEmpty else { return [] }
        return ["-o", "UserKnownHostsFile=\(path)", "-o", "GlobalKnownHostsFile=/dev/null"]
        #else
        return []
        #endif
    }

    // MARK: - Persistence

    /// Suite used instead of the standard defaults in UI-test mode. Wiped at
    /// every launch so each test starts from a clean slate and the developer's
    /// real profiles and preferences are never read or written.
    static let uiTestDefaultsSuite = "com.sequelpg.app.uitests"

    /// The `UserDefaults` every app component should use.
    static let userDefaults: UserDefaults = {
        guard isUITestMode, let suite = UserDefaults(suiteName: uiTestDefaultsSuite) else {
            return .standard
        }
        suite.removePersistentDomain(forName: uiTestDefaultsSuite)
        return suite
    }()

    /// Keychain stand-in: in-memory in UI-test mode (no system prompts, no
    /// leftovers), the real Keychain otherwise.
    static let keychainService: KeychainServiceProtocol = isUITestMode
        ? InMemoryKeychainService()
        : KeychainService.shared

    /// Builds the connection store and, in UI-test mode, seeds it (and the
    /// in-memory keychain) from `SEQUELPG_UITEST_PROFILES`.
    static func makeConnectionStore() -> ConnectionStore {
        let store = ConnectionStore(defaults: userDefaults)
        guard isUITestMode,
              let json = environment[Env.seedProfiles],
              let data = json.data(using: .utf8),
              let seeds = try? JSONDecoder().decode([SeedProfile].self, from: data)
        else { return store }

        store.save(seeds.map(\.profile))
        for seed in seeds {
            if let password = seed.password, !password.isEmpty {
                try? keychainService.save(password: password, forKey: seed.profile.keychainKey)
            }
            if let sshPassword = seed.sshPassword, !sshPassword.isEmpty {
                try? keychainService.save(password: sshPassword, forKey: seed.profile.sshKeychainKey)
            }
        }
        return store
    }

    /// Application Support root for file-based stores (ERD layouts). A
    /// throwaway temp directory in UI-test mode.
    static func applicationSupportDirectory(fileManager: FileManager = .default) -> URL {
        if isUITestMode {
            return fileManager.temporaryDirectory.appendingPathComponent("SequelPGUITests-\(ProcessInfo.processInfo.processIdentifier)")
        }
        return (try? fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )) ?? fileManager.temporaryDirectory
    }
}

/// Keychain replacement for UI-test mode. Thread-safe; lives for one launch.
final class InMemoryKeychainService: KeychainServiceProtocol, @unchecked Sendable {
    private var items: [String: String] = [:]
    private let lock = NSLock()

    func save(password: String, forKey key: String) throws {
        lock.withLock { items[key] = password }
    }

    func load(forKey key: String) throws -> String? {
        lock.withLock { items[key] }
    }

    func delete(forKey key: String) throws {
        lock.withLock { _ = items.removeValue(forKey: key) }
    }
}

/// Runs open/save panels. In UI-test mode the panel is skipped and the path
/// comes from the environment, because XCUITest can't reliably drive the
/// out-of-process system file panels.
@MainActor
enum FilePanels {
    static func chooseSaveURL(_ panel: NSSavePanel) -> URL? {
        #if DEBUG
        if TestingHooks.isUITestMode,
           let dir = ProcessInfo.processInfo.environment[TestingHooks.Env.saveDirectory], !dir.isEmpty
        {
            return URL(fileURLWithPath: dir, isDirectory: true)
                .appendingPathComponent(panel.nameFieldStringValue)
        }
        #endif
        guard panel.runModal() == .OK else { return nil }
        return panel.url
    }

    static func chooseOpenURL(_ panel: NSOpenPanel) -> URL? {
        #if DEBUG
        if TestingHooks.isUITestMode,
           let file = ProcessInfo.processInfo.environment[TestingHooks.Env.openFile], !file.isEmpty
        {
            return URL(fileURLWithPath: file)
        }
        #endif
        guard panel.runModal() == .OK else { return nil }
        return panel.url
    }
}

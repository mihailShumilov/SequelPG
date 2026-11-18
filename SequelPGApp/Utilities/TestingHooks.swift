import AppKit
import Foundation

/// Hooks that let the automated suites (`test-db/`, `SequelPGIntegrationTests`,
/// `UITest/`) drive the app deterministically.
///
/// Every hook is active only in DEBUG builds. Release builds compile the same
/// API down to the production behavior, so nothing here can be switched on in
/// a shipped app — not by a launch argument, not by an environment variable.
enum TestingHooks {
    /// Launch argument that puts the app into UI-test mode.
    static let uiTestModeArgument = "-SequelPGUITestMode"

    /// Environment variables read by the hooks. Mirrored by the UI scenario
    /// driver (`UITest/Sources/SequelPGUITest/Session.swift`) — keep in sync.
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
        /// "1" turns the MCP server on in UI-test mode (its preference is
        /// wiped at launch). Pair with `SEQUELPG_MCP_SOCKET` for the path.
        static let enableMCP = "SEQUELPG_UITEST_MCP"
    }

    #if DEBUG
    /// A connection profile plus its secrets, as handed to the app by UI tests.
    struct SeedProfile: Codable {
        var profile: ConnectionProfile
        var password: String?
        var sshPassword: String?
    }
    #endif

    #if DEBUG
    static let isUITestMode = ProcessInfo.processInfo.arguments.contains(uiTestModeArgument)
    /// The app is the host of a unit/integration test bundle.
    static let isTestHost = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
        || NSClassFromString("XCTestCase") != nil
    #else
    static let isUITestMode = false
    static let isTestHost = false
    #endif

    /// Any automated run: never touch the real Keychain or the developer's
    /// saved profiles and preferences.
    static let isAutomatedTestRun = isUITestMode || isTestHost

    private static var environment: [String: String] { ProcessInfo.processInfo.environment }

    /// UI-test mode asked for the MCP server to be on.
    static var forcesMCPEnabled: Bool {
        #if DEBUG
        return isUITestMode && environment[Env.enableMCP] == "1"
        #else
        return false
        #endif
    }

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

    /// Suite actually used: XCTest hosts get one per process, so test runs
    /// in parallel (or beside a UI-test app) can't wipe each other's settings.
    static let automatedDefaultsSuite = isTestHost
        ? "\(uiTestDefaultsSuite).\(ProcessInfo.processInfo.processIdentifier)"
        : uiTestDefaultsSuite

    /// The `UserDefaults` every app component should use.
    static let userDefaults: UserDefaults = {
        guard isAutomatedTestRun, let suite = UserDefaults(suiteName: automatedDefaultsSuite) else {
            return .standard
        }
        suite.removePersistentDomain(forName: automatedDefaultsSuite)
        if isTestHost { removeStaleTestHostSuites() }
        return suite
    }()

    /// Test hosts are killed rather than quit, so their per-process suites
    /// are removed by the next run once the owning process is gone.
    private static func removeStaleTestHostSuites() {
        let prefs = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Preferences")
        let prefix = uiTestDefaultsSuite + "."
        let files = (try? FileManager.default.contentsOfDirectory(atPath: prefs.path)) ?? []
        for file in files where file.hasPrefix(prefix) && file.hasSuffix(".plist") {
            let domain = String(file.dropLast(".plist".count))
            guard let pid = Int32(domain.dropFirst(prefix.count)),
                  pid != ProcessInfo.processInfo.processIdentifier,
                  kill(pid, 0) != 0
            else { continue }
            UserDefaults.standard.removePersistentDomain(forName: domain)
            try? FileManager.default.removeItem(at: prefs.appendingPathComponent(file))
        }
    }

    /// Keychain stand-in: in-memory for every automated run (no system
    /// prompts, no leftovers), the real Keychain otherwise.
    #if DEBUG
    static let keychainService: KeychainServiceProtocol = isAutomatedTestRun
        ? InMemoryKeychainService()
        : KeychainService.shared
    #else
    static let keychainService: KeychainServiceProtocol = KeychainService.shared
    #endif

    /// Builds the connection store and, in UI-test mode, seeds it (and the
    /// in-memory keychain) from `SEQUELPG_UITEST_PROFILES`.
    static func makeConnectionStore() -> ConnectionStore {
        let store = ConnectionStore(defaults: userDefaults)
        #if DEBUG
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
        #endif
        return store
    }

    /// Application Support root for file-based stores (ERD layouts). A
    /// throwaway temp directory for automated runs.
    static func applicationSupportDirectory(fileManager: FileManager = .default) -> URL {
        if isAutomatedTestRun {
            let pid = ProcessInfo.processInfo.processIdentifier
            return fileManager.temporaryDirectory.appendingPathComponent("SequelPGTests-\(pid)")
        }
        return (try? fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )) ?? fileManager.temporaryDirectory
    }
}

#if DEBUG
/// Keychain replacement for automated test runs. Thread-safe; lives for one launch.
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
#endif

/// Runs open/save panels. In UI-test mode the panel is skipped and the path
/// comes from the environment: the system file panels run out of process and
/// can't be driven reliably by the UI scenario driver.
@MainActor
enum FilePanels {
    static func chooseSaveURL(_ panel: NSSavePanel) -> URL? {
        #if DEBUG
        if TestingHooks.isUITestMode,
           let dir = ProcessInfo.processInfo.environment[TestingHooks.Env.saveDirectory], !dir.isEmpty
        {
            return URL(fileURLWithPath: dir, isDirectory: true)
                .appendingPathComponent((panel.nameFieldStringValue as NSString).lastPathComponent)
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

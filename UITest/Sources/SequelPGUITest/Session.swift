import AppKit
import ApplicationServices
import Foundation

/// A running SequelPG under test. The app is started in UI-test mode
/// (isolated defaults, in-memory Keychain, seeded profiles) and **in the
/// background**: controls are pressed through accessibility and keys are
/// posted to its process, so it never needs the focus, the pointer or the
/// screen. The session folder keeps the pid, so separate CLI commands talk to
/// the same app.
@MainActor
final class Session {
    let folder: URL
    let pid: pid_t
    let app: AXNode
    private(set) var shotIndex = 0

    var shots: URL { folder.appending(path: "shots") }
    var saveDirectory: URL { folder.appending(path: "files") }

    static func defaultFolder() -> URL {
        if let path = ProcessInfo.processInfo.environment["SEQUELPG_UITEST_DIR"], !path.isEmpty {
            return URL(fileURLWithPath: path)
        }
        return Repo.root.appending(path: "build/uitest")
    }

    private init(folder: URL, pid: pid_t) {
        self.folder = folder
        self.pid = pid
        app = AXNode(element: AXUIElementCreateApplication(pid))
        AXUIElementSetMessagingTimeout(app.element, 5)
        shotIndex = (try? FileManager.default.contentsOfDirectory(atPath: shots.path).count) ?? 0
    }

    // MARK: - Launch and attach

    static func launch(
        folder: URL,
        profiles: [SeedProfile] = [],
        openFile: URL? = nil,
        binary: URL = Repo.appBinary
    ) throws -> Session {
        guard AXIsProcessTrusted() else {
            throw Failure("this terminal has no Accessibility permission (System Settings ▸ Privacy & Security ▸ Accessibility)")
        }
        guard FileManager.default.isExecutableFile(atPath: binary.path) else {
            throw Failure("app not built at \(binary.path); run `make -C test-db build-app`")
        }
        if let old = try? attach(folder: folder) { old.quit() }
        try? FileManager.default.removeItem(at: folder)
        for sub in ["shots", "files"] {
            try FileManager.default.createDirectory(at: folder.appending(path: sub), withIntermediateDirectories: true)
        }
        var environment: [String: String] = [
            "SEQUELPG_SSH_KNOWN_HOSTS_FILE": Cluster.sshKnownHosts,
            "SEQUELPG_UITEST_SAVE_DIR": folder.appending(path: "files").path,
        ]
        if !profiles.isEmpty {
            environment["SEQUELPG_UITEST_PROFILES"] = String(decoding: try JSONEncoder().encode(profiles), as: UTF8.self)
        }
        if let openFile { environment["SEQUELPG_UITEST_OPEN_FILE"] = openFile.path }

        // Launched with `open -g -n` (LaunchServices, not a bare exec) so
        // SwiftUI gets the "open application" event and opens its first
        // window, while `-g` keeps it behind whatever the person is working in.
        // (NSWorkspace.openApplication with activates=false skips that window.)
        let bundle = binary.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let before = Set(Self.running(bundle).map(\.processIdentifier))
        let opener = Process()
        opener.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        var openArguments = ["-n", "--stderr", folder.appending(path: "app.log").path]
        if inBackground { openArguments.append("-g") }
        for (key, value) in environment.sorted(by: { $0.key < $1.key }) { openArguments += ["--env", "\(key)=\(value)"] }
        openArguments += [bundle.path, "--args",
                          "-SequelPGUITestMode",
                          "-ApplePersistenceIgnoreState", "YES",
                          "-NSQuitAlwaysKeepsWindows", "NO",
                          "-AppleLanguages", "(en)"]
        opener.arguments = openArguments
        try opener.run()
        opener.waitUntilExit()
        guard opener.terminationStatus == 0 else { throw Failure("open failed with status \(opener.terminationStatus)") }
        var launched: NSRunningApplication?
        let deadline = Date().addingTimeInterval(20)
        while launched == nil, Date() < deadline {
            launched = Self.running(bundle).first { !before.contains($0.processIdentifier) }
            if launched == nil { RunLoop.current.run(until: Date().addingTimeInterval(0.1)) }
        }
        guard let process = launched else { throw Failure("the app did not start") }
        try String(process.processIdentifier).write(to: folder.appending(path: "pid"), atomically: true, encoding: .utf8)
        let session = Session(folder: folder, pid: process.processIdentifier)
        // A SwiftUI app launched in the background (and without restored
        // state) doesn't open its first window; ask for one through the menu.
        if (try? session.waitUntil("the first window", timeout: 4) { !session.windows.isEmpty }) == nil {
            try session.waitUntil("the File menu", timeout: 15) {
                (try? session.menu(["File", "New Connection Window"])) != nil
            }
        }
        try session.waitUntil("the main window", timeout: 20) { !session.windows.isEmpty }
        Thread.sleep(forTimeInterval: 0.5)
        return session
    }

    static func attach(folder: URL) throws -> Session {
        guard let text = try? String(contentsOf: folder.appending(path: "pid"), encoding: .utf8),
              let pid = pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines)),
              let running = NSRunningApplication(processIdentifier: pid), !running.isTerminated
        else { throw Failure("no app running for \(folder.path); run `launch` first") }
        return Session(folder: folder, pid: pid)
    }

    private static func running(_ bundle: URL) -> [NSRunningApplication] {
        NSWorkspace.shared.runningApplications.filter { $0.bundleURL?.standardizedFileURL == bundle.standardizedFileURL }
    }

    func quit() {
        NSRunningApplication(processIdentifier: pid)?.terminate()
        for _ in 0 ..< 50 where NSRunningApplication(processIdentifier: pid)?.isTerminated == false {
            Thread.sleep(forTimeInterval: 0.1)
        }
        NSRunningApplication(processIdentifier: pid)?.forceTerminate()
    }

    /// Runs stay behind the person's windows unless SEQUELPG_UITEST_FOREGROUND=1.
    static let inBackground = ProcessInfo.processInfo.environment["SEQUELPG_UITEST_FOREGROUND"] == nil

    // MARK: - Windows and elements

    var windows: [AXNode] {
        ((app.attribute(kAXWindowsAttribute) as? [AXUIElement]) ?? []).map(AXNode.init)
    }

    var focusedWindow: AXNode? {
        guard let value = app.attribute(kAXFocusedWindowAttribute), CFGetTypeID(value) == AXUIElementGetTypeID()
        else { return windows.first }
        // The type ID was just checked.
        return AXNode(element: unsafeBitCast(value, to: AXUIElement.self))
    }

    /// Element with keyboard focus in the app.
    var focused: AXNode? {
        guard let value = app.attribute(kAXFocusedUIElementAttribute), CFGetTypeID(value) == AXUIElementGetTypeID()
        else { return nil }
        // The type ID was just checked.
        return AXNode(element: unsafeBitCast(value, to: AXUIElement.self))
    }

    func find(_ query: Query) -> [AXNode] {
        windows.flatMap { $0.descendants().map(\.node) }.filter(query.matches)
    }

    /// First element matching `query`, waiting up to `timeout` for it.
    func element(_ query: Query, timeout: TimeInterval = 5) throws -> AXNode {
        var found: AXNode?
        try waitUntil("\(query)", timeout: timeout) {
            let all = self.find(query)
            found = all.first { $0.isEnabled } ?? all.first
            return found != nil
        }
        return found!
    }

    func waitUntil(_ what: String, timeout: TimeInterval = 5, _ condition: () throws -> Bool) throws {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if try condition() { return }
            RunLoop.current.run(until: Date().addingTimeInterval(0.15))
        }
        throw Failure("timed out after \(Int(timeout))s waiting for \(what)")
    }

    // MARK: - Menus

    /// Picks a menu-bar item by path, such as `["File", "Export Database…"]`.
    func menu(_ path: [String]) throws {
        guard let bar = app.attribute(kAXMenuBarAttribute), CFGetTypeID(bar) == AXUIElementGetTypeID() else {
            throw Failure("no menu bar")
        }
        // The type ID was just checked.
        var current = AXNode(element: unsafeBitCast(bar, to: AXUIElement.self))
        for (index, title) in path.enumerated() {
            guard let item = current.descendants(maxDepth: 2).map(\.node).first(where: {
                ($0.role == "AXMenuBarItem" || $0.role == "AXMenuItem") && $0.title == title
            }) else { throw Failure("no menu item “\(title)” in \(path.joined(separator: " ▸ "))") }
            if index == path.count - 1 {
                guard item.isEnabled else { throw Failure("menu item “\(title)” is disabled") }
                item.press()
            } else {
                current = item
            }
        }
    }

    // MARK: - Screenshots

    /// Captures the focused window into `shots/NNN-name.png` (works while the
    /// window is behind others: `screencapture -l` grabs that window only).
    @discardableResult
    func screenshot(_ name: String) -> URL? {
        guard let target = focusedWindow ?? windows.first,
              let number = Self.windowNumber(pid: pid, frame: target.frame)
        else { return nil }
        shotIndex += 1
        let safe = name.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: " ", with: "_")
        let url = shots.appending(path: String(format: "%03d-%@.png", shotIndex, safe))
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        process.arguments = ["-x", "-o", "-l", String(number), url.path]
        try? process.run()
        process.waitUntilExit()
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    static func windowNumber(pid: pid_t, frame: CGRect) -> CGWindowID? {
        let list = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] ?? []
        let mine = list.filter {
            ($0[kCGWindowOwnerPID as String] as? pid_t) == pid && ($0[kCGWindowLayer as String] as? Int) == 0
        }
        func bounds(_ info: [String: Any]) -> CGRect {
            let d = info[kCGWindowBounds as String] as? [String: CGFloat] ?? [:]
            return CGRect(x: d["X"] ?? 0, y: d["Y"] ?? 0, width: d["Width"] ?? 0, height: d["Height"] ?? 0)
        }
        func distance(_ a: CGRect) -> CGFloat {
            abs(a.minX - frame.minX) + abs(a.minY - frame.minY) + abs(a.width - frame.width) + abs(a.height - frame.height)
        }
        return mine.min { distance(bounds($0)) < distance(bounds($1)) }?[kCGWindowNumber as String] as? CGWindowID
    }

    // MARK: - Inspection

    /// Indented outline of the windows (controls and texts; everything with `all`).
    func outline(all: Bool = false) -> String {
        let interesting: Set<String> = [
            "AXButton", "AXCheckBox", "AXRadioButton", "AXPopUpButton", "AXMenuButton", "AXTextField",
            "AXTextArea", "AXStaticText", "AXTable", "AXOutline", "AXRow", "AXSegmentedControl", "AXSheet",
            "AXWindow", "AXList", "AXGroup", "AXCell", "AXSearchField", "AXDisclosureTriangle", "AXTabGroup",
        ]
        var lines: [String] = []
        for window in windows {
            for (node, depth) in window.descendants() where all || interesting.contains(node.role) {
                if !all, node.role == "AXGroup", node.identifier.isEmpty { continue }
                lines.append(String(repeating: "  ", count: depth) + node.description)
            }
        }
        return lines.joined(separator: "\n")
    }
}

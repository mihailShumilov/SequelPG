import AppKit
import SwiftUI

@main
struct SequelPGApp: App {
    /// Shared connection list — all windows read/write the same saved profiles.
    @State private var connectionListVM = ConnectionListViewModel(
        store: ConnectionStore(),
        keychainService: KeychainService.shared
    )

    /// User's chosen appearance (Auto / Light / Dark). Shared across all
    /// windows and the Settings scene.
    @State private var themePreference = ThemePreference.shared

    /// SQL-editor preferences (completion, timeout, font). Shared across all
    /// windows and the Settings scene.
    @State private var editorPreference = EditorPreference.shared

    init() {
        // Register bundled JetBrains Mono so the editor-font preference can
        // offer it; SF Mono remains the default.
        Theme.registerBundledFonts()
    }

    var body: some Scene {
        // One window per connection. Windows are native macOS window tabs:
        // ⌘T opens a new one as a tab of the current window, and the system
        // tab bar handles reordering, tearing off, and merging.
        WindowGroup(id: ConnectionWindowView.windowID) {
            ConnectionWindowView()
                .environment(connectionListVM)
                .environment(themePreference)
                .environment(editorPreference)
                .preferredColorScheme(themePreference.colorScheme)
        }
        .commands {
            AppCommands(themePreference: themePreference)
        }

        Settings {
            SettingsView()
                .environment(themePreference)
                .environment(editorPreference)
                .preferredColorScheme(themePreference.colorScheme)
        }
    }
}

// MARK: - Menu bar

/// Application menus. Every action targets the *key* window's session via the
/// focused `AppViewModel`, so menu items and their shortcuts never fire in a
/// background window.
struct AppCommands: Commands {
    let themePreference: ThemePreference

    @FocusedValue(\.appViewModel) private var appVM
    @Environment(\.openWindow) private var openWindow

    private var isConnected: Bool { appVM?.isConnected ?? false }

    var body: some Commands {
        CommandGroup(after: .newItem) {
            Button("New Tab") {
                WindowTabbing.openNewTab(openWindow: openWindow)
            }
            .keyboardShortcut("t", modifiers: .command)
        }

        CommandGroup(replacing: .importExport) {
            Button("Export Database…") { appVM?.showExportSheet = true }
                .keyboardShortcut("e", modifiers: [.command, .shift])
                .disabled(!isConnected)
            Button("Import SQL File…") { appVM?.showImportSheet = true }
                .keyboardShortcut("i", modifiers: [.command, .shift])
                .disabled(!isConnected)
        }

        CommandGroup(replacing: .textEditing) {
            // ⌘F is contextual: the row filter on the Content tab, the
            // editor's native find bar everywhere else.
            Button(appVM?.selectedTab == .content && isConnected ? "Filter Rows" : "Find…") {
                if let appVM, appVM.isConnected, appVM.selectedTab == .content {
                    appVM.tableVM.showFilterBar.toggle()
                } else {
                    TextFinderAction.send(.showFindInterface)
                }
            }
            .keyboardShortcut("f", modifiers: .command)

            Button("Find Next") { TextFinderAction.send(.nextMatch) }
                .keyboardShortcut("g", modifiers: .command)
            Button("Find Previous") { TextFinderAction.send(.previousMatch) }
                .keyboardShortcut("g", modifiers: [.command, .shift])
            Button("Use Selection for Find") { TextFinderAction.send(.setSearchString) }
                .keyboardShortcut("e", modifiers: .command)
        }

        CommandGroup(after: .sidebar) {
            Divider()
            ForEach(Array(AppViewModel.MainTab.allCases.enumerated()), id: \.element) { index, tab in
                Button(tab.rawValue) { appVM?.selectedTab = tab }
                    .keyboardShortcut(KeyEquivalent(Character(String(index + 1))), modifiers: .command)
                    .disabled(!isConnected)
            }
            Divider()
            Button(appVM?.showInspector == true ? "Hide Inspector" : "Show Inspector") {
                appVM?.showInspector.toggle()
            }
            .keyboardShortcut("i", modifiers: [.command, .option])
            .disabled(!isConnected)

            Button(appVM?.showQueryHistory == true ? "Hide Query History" : "Show Query History") {
                appVM?.showQueryHistory.toggle()
            }
            .keyboardShortcut("y", modifiers: [.command, .shift])
            .disabled(!isConnected)

            Divider()
            Toggle("Show Advanced Objects", isOn: Binding(
                get: { appVM?.navigatorVM.complexity == .advanced },
                set: { appVM?.navigatorVM.complexity = $0 ? .advanced : .simple }
            ))
            .disabled(!isConnected)

            Divider()
            Menu("Appearance") {
                Picker("Appearance", selection: Binding(
                    get: { themePreference.mode },
                    set: { themePreference.mode = $0 }
                )) {
                    ForEach(ThemeMode.allCases) { mode in
                        Text(mode.label).tag(mode)
                    }
                }
                .pickerStyle(.inline)
            }
        }

        CommandMenu("Database") {
            Button("Refresh") {
                guard let appVM else { return }
                Task { await appVM.refreshNavigator() }
            }
            .keyboardShortcut("r", modifiers: .command)
            .disabled(!isConnected)

            Divider()
            Button("New Database…") { appVM?.showCreateDatabaseSheet = true }
                .disabled(!isConnected)
            Button("New Schema…") { appVM?.showCreateSchemaSheet = true }
                .disabled(!isConnected)

            Divider()
            Button("Extensions…") { appVM?.showExtensionsSheet = true }
                .disabled(!isConnected)
            Button("Roles & Privileges…") { appVM?.showRolesSheet = true }
                .disabled(!isConnected)
            Button("Function Library…") { appVM?.showFunctionLibrary = true }
                .disabled(!isConnected)

            Divider()
            Button("Disconnect") {
                guard let appVM else { return }
                Task { await appVM.disconnect() }
            }
            .keyboardShortcut("w", modifiers: [.command, .shift])
            .disabled(!isConnected)
        }

        CommandMenu("Query") {
            Button("Run Query") {
                guard let appVM else { return }
                appVM.runQueryAction(appVM.queryVM.queryText)
            }
            .keyboardShortcut(.return, modifiers: .command)
            .disabled(!isConnected || appVM?.queryVM.isExecuting == true)

            Button("Stop") { appVM?.cancelRunningQuery() }
                .keyboardShortcut(".", modifiers: .command)
                .disabled(appVM?.queryVM.isExecuting != true)

            Divider()
            Button("Explain") {
                guard let appVM else { return }
                appVM.runExplainAction(appVM.queryVM.queryText, analyze: false)
            }
            .keyboardShortcut("e", modifiers: [.command, .option])
            .disabled(!isConnected || appVM?.queryVM.isExecuting == true)

            Button("Explain Analyze") {
                guard let appVM else { return }
                appVM.runExplainAction(appVM.queryVM.queryText, analyze: true)
            }
            .keyboardShortcut("e", modifiers: [.command, .option, .shift])
            .disabled(!isConnected || appVM?.queryVM.isExecuting == true)

            Divider()
            Button("Beautify") { appVM?.queryVM.beautify() }
                .keyboardShortcut("f", modifiers: [.command, .shift])
                .disabled(!isConnected)
            Button("Clear Query") { appVM?.clearQuery() }
                .keyboardShortcut("k", modifiers: .command)
                .disabled(!isConnected)
        }
    }
}

// MARK: - Focused session

struct AppViewModelFocusedKey: FocusedValueKey {
    typealias Value = AppViewModel
}

extension FocusedValues {
    /// The session behind the key window. Set by `ConnectionWindowView` so
    /// menu commands act on the window the user is looking at.
    var appViewModel: AppViewModel? {
        get { self[AppViewModelFocusedKey.self] }
        set { self[AppViewModelFocusedKey.self] = newValue }
    }
}

// MARK: - Text finder bridge

/// Sends a standard `performTextFinderAction:` down the responder chain so the
/// first responder (the SQL editor, the Definition view) shows or drives its
/// native find bar.
enum TextFinderAction {
    static func send(_ action: NSTextFinder.Action) {
        let sender = NSMenuItem()
        sender.tag = action.rawValue
        NSApp.sendAction(#selector(NSResponder.performTextFinderAction(_:)), to: nil, from: sender)
    }
}

// MARK: - Window tabbing

/// Opens connection windows as native tabs of the current window. `openNewTab`
/// records the anchor window and asks SwiftUI for a new scene; the new
/// window's `WindowAccessor` then attaches itself to that anchor's tab group.
@MainActor
enum WindowTabbing {
    private static weak var anchorWindow: NSWindow?

    static func openNewTab(openWindow: OpenWindowAction) {
        anchorWindow = NSApp.keyWindow ?? NSApp.mainWindow
        openWindow(id: ConnectionWindowView.windowID)
    }

    /// Called by every new connection window once it has an `NSWindow`.
    static func attachIfRequested(_ window: NSWindow) {
        guard let anchor = anchorWindow, anchor !== window, anchor.isVisible else {
            anchorWindow = nil
            return
        }
        anchorWindow = nil
        if !(anchor.tabbedWindows?.contains(window) ?? false) {
            anchor.addTabbedWindow(window, ordered: .above)
        }
        window.makeKeyAndOrderFront(nil)
    }
}

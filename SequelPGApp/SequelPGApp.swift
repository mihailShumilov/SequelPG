import SwiftUI

@main
struct SequelPGApp: App {
    /// Shared connection list — all tabs read/write the same saved profiles.
    @State private var connectionListVM = ConnectionListViewModel(
        store: ConnectionStore(),
        keychainService: KeychainService.shared
    )

    /// User's chosen appearance (Auto / Light / Dark). Shared across all
    /// windows and the Settings scene.
    @State private var themePreference = ThemePreference.shared

    /// SQL-editor preferences (e.g. whether completion auto-pops while
    /// typing). Shared across all windows and the Settings scene.
    @State private var editorPreference = EditorPreference.shared

    init() {
        // Register bundled JetBrains Mono so Theme.display / Theme.mono pick
        // it up at runtime rather than falling back to the system monospace.
        Theme.registerBundledFonts()
    }

    var body: some Scene {
        WindowGroup {
            TabRootView()
                .environment(connectionListVM)
                .environment(themePreference)
                .environment(editorPreference)
                .preferredColorScheme(themePreference.colorScheme)
                .tint(Theme.accent)
                .background(Theme.bg)
        }
        .commands {
            CommandGroup(after: .newItem) {
                Divider()

                Button("New Tab") {
                    NotificationCenter.default.post(name: .newTabRequested, object: nil)
                }
                .keyboardShortcut("t", modifiers: .command)
            }

            CommandGroup(replacing: .importExport) {
                Button("Export Database…") {
                    NotificationCenter.default.post(name: .exportDatabaseRequested, object: nil)
                }
                .keyboardShortcut("e", modifiers: [.command, .shift])

                Button("Import SQL File…") {
                    NotificationCenter.default.post(name: .importSQLRequested, object: nil)
                }
                .keyboardShortcut("i", modifiers: [.command, .shift])
            }

            CommandGroup(replacing: .textEditing) {
                Button("Find...") {
                    NotificationCenter.default.post(name: .toggleFilterBar, object: nil)
                }
                .keyboardShortcut("f", modifiers: .command)
            }

            CommandGroup(after: .toolbar) {
                Button("Toggle Query History") {
                    NotificationCenter.default.post(name: .toggleQueryHistory, object: nil)
                }
                .keyboardShortcut("y", modifiers: [.command, .shift])
            }

            CommandGroup(after: .appSettings) {
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
        }

        Settings {
            SettingsView()
                .environment(themePreference)
                .environment(editorPreference)
                .preferredColorScheme(themePreference.colorScheme)
                .tint(Theme.accent)
        }
    }
}

extension Notification.Name {
    static let newTabRequested = Notification.Name("com.sequelpg.newTabRequested")
    static let toggleFilterBar = Notification.Name("com.sequelpg.toggleFilterBar")
    static let toggleQueryHistory = Notification.Name("com.sequelpg.toggleQueryHistory")
    static let exportDatabaseRequested = Notification.Name("com.sequelpg.exportDatabaseRequested")
    static let importSQLRequested = Notification.Name("com.sequelpg.importSQLRequested")
}

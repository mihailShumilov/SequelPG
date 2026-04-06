import SwiftUI

@main
struct SequelPGApp: App {
    /// Shared connection list — all tabs read/write the same saved profiles.
    @State private var connectionListVM = ConnectionListViewModel(
        store: ConnectionStore(),
        keychainService: KeychainService.shared
    )

    var body: some Scene {
        WindowGroup {
            TabRootView()
                .environment(connectionListVM)
        }
        .commands {
            CommandGroup(after: .newItem) {
                Divider()

                Button("New Tab") {
                    NotificationCenter.default.post(name: .newTabRequested, object: nil)
                }
                .keyboardShortcut("t", modifiers: .command)
            }

            CommandGroup(replacing: .textEditing) {
                Button("Find...") {
                    NotificationCenter.default.post(name: .toggleFilterBar, object: nil)
                }
                .keyboardShortcut("f", modifiers: .command)
            }
        }
    }
}

extension Notification.Name {
    static let newTabRequested = Notification.Name("com.sequelpg.newTabRequested")
    static let toggleFilterBar = Notification.Name("com.sequelpg.toggleFilterBar")
}

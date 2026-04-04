import SwiftUI

@main
struct SequelPGApp: App {
    @State private var appVM = AppViewModel()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(appVM)
                .environment(appVM.connectionListVM)
                .environment(appVM.navigatorVM)
                .environment(appVM.tableVM)
                .environment(appVM.queryVM)
        }
        .commands {
            CommandGroup(after: .newItem) {
                Divider()

                Button("Disconnect") {
                    Task {
                        await appVM.disconnect()
                    }
                }
                .keyboardShortcut("w", modifiers: [.command, .shift])
                .disabled(!appVM.isConnected)
            }
        }
    }
}

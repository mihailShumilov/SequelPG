import SwiftUI

@main
struct SequelPGApp: App {
    @StateObject private var appVM = AppViewModel()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(appVM)
                .environmentObject(appVM.connectionListVM)
                .environmentObject(appVM.navigatorVM)
                .environmentObject(appVM.tableVM)
                .environmentObject(appVM.queryVM)
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

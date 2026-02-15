import SwiftUI

struct ContentView: View {
    @StateObject private var appVM = AppViewModel()

    var body: some View {
        NavigationSplitView {
            SidebarView()
                .environmentObject(appVM)
        } content: {
            MainAreaView()
                .environmentObject(appVM)
        } detail: {
            if appVM.showInspector {
                InspectorView()
                    .environmentObject(appVM)
            }
        }
        .frame(minWidth: 900, minHeight: 600)
        .toolbar {
            ToolbarItem(placement: .automatic) {
                Button {
                    appVM.showInspector.toggle()
                } label: {
                    Image(systemName: "sidebar.right")
                }
                .help("Toggle Inspector")
            }
        }
        .alert("Error", isPresented: .init(
            get: { appVM.errorMessage != nil },
            set: { if !$0 { appVM.errorMessage = nil } }
        )) {
            Button("OK") { appVM.errorMessage = nil }
        } message: {
            Text(appVM.errorMessage ?? "")
        }
    }
}

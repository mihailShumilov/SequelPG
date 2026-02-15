import SwiftUI

struct ContentView: View {
    @StateObject private var appVM = AppViewModel()

    var body: some View {
        HStack(spacing: 0) {
            SidebarView()
                .environmentObject(appVM)
                .frame(minWidth: 200, idealWidth: 250, maxWidth: 350)

            Divider()

            MainAreaView()
                .environmentObject(appVM)
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            if appVM.showInspector {
                Divider()

                InspectorView()
                    .environmentObject(appVM)
                    .frame(minWidth: 180, idealWidth: 220, maxWidth: 300)
            }
        }
        .frame(minWidth: 900, minHeight: 600)
        .toolbar {
            ToolbarItem(placement: .automatic) {
                Button {
                    withAnimation {
                        appVM.showInspector.toggle()
                    }
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

import SwiftUI

struct ContentView: View {
    @Environment(AppViewModel.self) var appVM

    var body: some View {
        Group {
            if appVM.isConnected {
                HStack(spacing: 0) {
                    SidebarView()
                        .frame(minWidth: 200, idealWidth: 250, maxWidth: 350)

                    Divider()

                    MainAreaView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)

                    if appVM.showInspector {
                        Divider()

                        InspectorView()
                            .frame(minWidth: 180, idealWidth: 220, maxWidth: 300)
                    }
                }
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
            } else {
                StartPageView()
            }
        }
        .frame(minWidth: 900, minHeight: 600)
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

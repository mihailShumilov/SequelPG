import SwiftUI

struct SidebarView: View {
    @EnvironmentObject var appVM: AppViewModel

    var body: some View {
        VStack(spacing: 0) {
            ConnectionListView()
                .environmentObject(appVM)

            Divider()

            if appVM.isConnected {
                NavigatorView()
                    .environmentObject(appVM)
            } else {
                Spacer()
                Text("Connect to browse")
                    .foregroundStyle(.secondary)
                    .font(.caption)
                Spacer()
            }
        }
        .frame(minWidth: 200)
    }
}

import SwiftUI

struct SidebarView: View {
    @EnvironmentObject var appVM: AppViewModel

    var body: some View {
        VStack(spacing: 0) {
            ConnectionListView()
                .environmentObject(appVM)

            Divider()

            NavigatorView()
                .environmentObject(appVM)
        }
        .frame(minWidth: 200)
    }
}

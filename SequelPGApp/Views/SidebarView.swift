import SwiftUI

struct SidebarView: View {
    @Environment(AppViewModel.self) var appVM

    var body: some View {
        VStack(spacing: 0) {
            ConnectionListView()

            Divider()

            NavigatorView()
        }
        .frame(minWidth: 200)
    }
}

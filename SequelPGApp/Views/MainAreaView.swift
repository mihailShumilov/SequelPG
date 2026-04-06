import SwiftUI

struct MainAreaView: View {
    @Environment(AppViewModel.self) var appVM
    @Environment(NavigatorViewModel.self) var navigatorVM

    var body: some View {
        VStack(spacing: 0) {
            // Tab bar
            HStack(spacing: 0) {
                ForEach(AppViewModel.MainTab.allCases, id: \.self) { tab in
                    Button {
                        if isTabEnabled(tab) {
                            appVM.selectedTab = tab
                        }
                    } label: {
                        Text(tab.rawValue)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 8)
                            .background(appVM.selectedTab == tab ? Color.accentColor.opacity(0.15) : Color.clear)
                            .foregroundStyle(isTabEnabled(tab) ? .primary : .tertiary)
                    }
                    .buttonStyle(.plain)
                    .disabled(!isTabEnabled(tab))
                }
                Spacer()
            }
            .background(Color(nsColor: .controlBackgroundColor))

            Divider()

            // Tab content
            Group {
                switch appVM.selectedTab {
                case .structure:
                    StructureTabView()
                case .content:
                    ContentTabView()
                case .definition:
                    ObjectDefinitionView()
                case .query:
                    QueryTabView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func isTabEnabled(_ tab: AppViewModel.MainTab) -> Bool {
        switch tab {
        case .structure, .content:
            return navigatorVM.selectedObject != nil
        case .definition:
            return navigatorVM.selectedObject != nil
        case .query:
            return appVM.isConnected
        }
    }
}

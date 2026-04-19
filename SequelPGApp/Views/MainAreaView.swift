import SwiftUI

struct MainAreaView: View {
    @Environment(AppViewModel.self) var appVM
    @Environment(NavigatorViewModel.self) var navigatorVM

    var body: some View {
        VStack(spacing: 0) {
            // Tab bar
            HStack(spacing: 0) {
                ForEach(Array(AppViewModel.MainTab.allCases.enumerated()), id: \.element) { index, tab in
                    let isActive = appVM.selectedTab == tab
                    let enabled = isTabEnabled(tab)
                    Button {
                        if enabled {
                            appVM.selectedTab = tab
                        }
                    } label: {
                        Text(tab.rawValue)
                            .font(.body)
                            .fontWeight(isActive ? .semibold : .regular)
                            .padding(.horizontal, 20)
                            .padding(.vertical, 12)
                            .background(isActive ? Color.accentColor.opacity(0.1) : Color.clear)
                            .foregroundColor(enabled ? (isActive ? Color.accentColor : .primary) : Color.secondary.opacity(0.5))
                    }
                    .buttonStyle(.plain)
                    .overlay(alignment: .bottom) {
                        if isActive {
                            Rectangle()
                                .fill(Color.accentColor)
                                .frame(height: 2)
                        }
                    }
                    .disabled(!enabled)
                    .accessibilityLabel(tab.rawValue)
                    .accessibilityHint(enabled ? "Switch to the \(tab.rawValue) tab" : "Select an object in the Navigator to enable")
                    .keyboardShortcut(tabShortcut(for: index), modifiers: .command)
                }
                Spacer()
            }
            .background(Color(nsColor: .controlBackgroundColor))

            Divider()

            // Tab content + optional bottom history panel
            if appVM.showQueryHistory {
                VSplitView {
                    tabContent
                        .frame(minHeight: 100)

                    QueryHistoryView()
                        .frame(minHeight: 120, idealHeight: 220)
                }
            } else {
                tabContent
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .toggleQueryHistory)) { _ in
            appVM.showQueryHistory.toggle()
        }
    }

    // Only mount the active tab. Inactive tabs were previously kept in a ZStack
    // with opacity 0, which forced SwiftUI to keep their observation wiring and
    // redraw them whenever any shared view model changed.
    @ViewBuilder
    private var tabContent: some View {
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

    private func isTabEnabled(_ tab: AppViewModel.MainTab) -> Bool {
        switch tab {
        case .structure, .content, .definition:
            return navigatorVM.selectedObject != nil
        case .query:
            return appVM.isConnected
        }
    }

    /// Cmd+1…4 for the four main tabs. Returns `.defaultAction` for anything
    /// beyond that so the modifier is a no-op and doesn't clash with defaults.
    private func tabShortcut(for index: Int) -> KeyEquivalent {
        switch index {
        case 0: return "1"
        case 1: return "2"
        case 2: return "3"
        case 3: return "4"
        default: return .return
        }
    }
}

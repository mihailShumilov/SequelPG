import SwiftUI

/// Represents a single tab — either showing the start page or a connected session.
@MainActor
struct TabItem: Identifiable {
    let id = UUID()
    var appVM = AppViewModel()
}


/// Root view managing tabs within a single window, similar to iTerm2.
/// Cmd+T adds a new tab. Each tab starts at the start page and transitions
/// to the connected interface on connect.
struct TabRootView: View {
    @Environment(ConnectionListViewModel.self) var connectionListVM
    @State private var tabs: [TabItem] = [TabItem()]
    @State private var selectedTabId: UUID?

    var body: some View {
        Group {
            if tabs.count == 1, let tab = tabs.first {
                // Single tab — no tab bar, just the content
                tabContent(tab)
            } else {
                // Multiple tabs — show tab bar
                VStack(spacing: 0) {
                    tabBar
                    Divider()
                    ZStack {
                        ForEach(tabs) { tab in
                            tabContent(tab)
                                .opacity(tab.id == selectedTabId ? 1 : 0)
                                .allowsHitTesting(tab.id == selectedTabId)
                        }
                    }
                }
            }
        }
        .frame(minWidth: 900, minHeight: 600)
        .onAppear {
            selectedTabId = tabs.first?.id
        }
        .onReceive(NotificationCenter.default.publisher(for: .newTabRequested)) { _ in
            addTab()
        }
    }

    private var tabBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 0) {
                ForEach(tabs) { tab in
                    tabButton(tab)
                }
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private func tabButton(_ tab: TabItem) -> some View {
        let isSelected = tab.id == selectedTabId
        return HStack(spacing: 6) {
            if tab.appVM.isConnected {
                Circle()
                    .fill(.green)
                    .frame(width: 6, height: 6)
            }
            Text(tab.appVM.connectedProfileName ?? "New Connection")
                .lineLimit(1)
                .font(.caption)

            if tabs.count > 1 {
                Button {
                    closeTab(tab.id)
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Close tab")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(isSelected ? Color.accentColor.opacity(0.15) : Color.clear)
        .contentShape(Rectangle())
        .onTapGesture {
            selectedTabId = tab.id
        }
    }

    @ViewBuilder
    private func tabContent(_ tab: TabItem) -> some View {
        Group {
            if tab.appVM.isConnected {
                connectedView(tab)
            } else {
                StartPageView()
                    .environment(tab.appVM)
            }
        }
        .environment(tab.appVM)
        .environment(tab.appVM.navigatorVM)
        .environment(tab.appVM.tableVM)
        .environment(tab.appVM.queryVM)
        .environment(connectionListVM)
    }

    private func connectedView(_ tab: TabItem) -> some View {
        HStack(spacing: 0) {
            NavigatorView()
                .frame(minWidth: 200, idealWidth: 250, maxWidth: 350)

            Divider()

            MainAreaView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            if tab.appVM.showInspector {
                Divider()

                InspectorView()
                    .frame(minWidth: 180, idealWidth: 220, maxWidth: 300)
            }
        }
        .toolbar {
            ToolbarItem(placement: .automatic) {
                Button {
                    withAnimation {
                        tab.appVM.showInspector.toggle()
                    }
                } label: {
                    Image(systemName: "sidebar.right")
                }
                .help("Toggle Inspector")
            }
        }
        .alert("Error", isPresented: .init(
            get: { tab.appVM.errorMessage != nil },
            set: { if !$0 { tab.appVM.errorMessage = nil } }
        )) {
            Button("OK") { tab.appVM.errorMessage = nil }
        } message: {
            Text(tab.appVM.errorMessage ?? "")
        }
    }

    private func addTab() {
        let newTab = TabItem()
        tabs.append(newTab)
        selectedTabId = newTab.id
    }

    private func closeTab(_ id: UUID) {
        guard tabs.count > 1 else { return }
        if let tab = tabs.first(where: { $0.id == id }), tab.appVM.isConnected {
            Task { await tab.appVM.disconnect() }
        }
        tabs.removeAll { $0.id == id }
        if selectedTabId == id {
            selectedTabId = tabs.first?.id
        }
    }
}

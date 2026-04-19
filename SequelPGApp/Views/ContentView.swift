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
                    .frame(width: 7, height: 7)
            }
            Text(tab.appVM.connectedProfileName ?? "New Connection")
                .lineLimit(1)
                .font(.subheadline)

            if tabs.count > 1 {
                Button {
                    closeTab(tab.id)
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Close tab")
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(isSelected ? Color.accentColor.opacity(0.12) : Color.clear)
        .overlay(alignment: .bottom) {
            if isSelected {
                Rectangle()
                    .fill(Color.accentColor)
                    .frame(height: 2)
            }
        }
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
                    .alert("Connection Error", isPresented: .init(
                        get: { tab.appVM.errorMessage != nil },
                        set: { if !$0 { tab.appVM.errorMessage = nil } }
                    )) {
                        Button("OK") { tab.appVM.errorMessage = nil }
                    } message: {
                        Text(tab.appVM.errorMessage ?? "")
                    }
            }
        }
        .environment(tab.appVM)
        .environment(tab.appVM.navigatorVM)
        .environment(tab.appVM.tableVM)
        .environment(tab.appVM.queryVM)
        .environment(tab.appVM.queryHistoryVM)
        .environment(connectionListVM)
    }

    private func connectedView(_ tab: TabItem) -> some View {
        @Bindable var appVM = tab.appVM
        return HStack(spacing: 0) {
            NavigatorView()
                .frame(width: appVM.sidebarWidth)
                .clipped()

            SidebarResizeHandle(width: $appVM.sidebarWidth)

            MainAreaView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            if tab.appVM.showInspector {
                Divider()

                InspectorView()
                    .frame(minWidth: 180, idealWidth: 220, maxWidth: 300)
            }
        }
        .onGeometryChange(for: CGFloat.self, of: { $0.size.width }) { width in
            guard !SidebarWidthStore.hasSavedWidth else { return }
            let defaultWidth = max(200, min(width / 3, 500))
            appVM.sidebarWidth = defaultWidth
            SidebarWidthStore.save(defaultWidth)
        }
        .toolbar {
            ToolbarItem(placement: .automatic) {
                Menu {
                    Button("Extensions…") { appVM.showExtensionsSheet = true }
                    Button("Roles & Privileges…") { appVM.showRolesSheet = true }
                    Button("Function Library…") { appVM.showFunctionLibrary = true }
                } label: {
                    Image(systemName: "server.rack")
                }
                .help("Database tools")
            }
            ToolbarItem(placement: .automatic) {
                Button {
                    tab.appVM.showInspector.toggle()
                } label: {
                    Image(systemName: "sidebar.right")
                }
                .help("Toggle Inspector")
            }
        }
        .sheet(isPresented: $appVM.showExtensionsSheet) {
            ExtensionsSheet()
                .environment(tab.appVM)
        }
        .sheet(isPresented: $appVM.showRolesSheet) {
            RolesSheet()
                .environment(tab.appVM)
        }
        .sheet(isPresented: $appVM.showFunctionLibrary) {
            FunctionLibrarySheet()
                .environment(tab.appVM.queryVM)
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

// MARK: - Sidebar Resize Handle

struct SidebarResizeHandle: View {
    @Binding var width: CGFloat
    @State private var isDragging = false
    @State private var dragStartWidth: CGFloat = 0

    var body: some View {
        // Invisible drag target overlaid on a standard divider
        Divider()
            .overlay {
                Color.clear
                    .frame(width: 12)
                    .contentShape(Rectangle())
                    .onHover { hovering in
                        if hovering {
                            NSCursor.resizeLeftRight.push()
                        } else {
                            NSCursor.pop()
                        }
                    }
                    .gesture(
                        DragGesture(minimumDistance: 1, coordinateSpace: .global)
                            .onChanged { value in
                                if !isDragging {
                                    isDragging = true
                                    dragStartWidth = width
                                }
                                let newWidth = dragStartWidth + value.translation.width
                                width = min(max(newWidth, 160), 500)
                            }
                            .onEnded { _ in
                                isDragging = false
                                SidebarWidthStore.save(width)
                            }
                    )
            }
    }
}

// MARK: - Sidebar Width Persistence

enum SidebarWidthStore {
    private static let key = "com.sequelpg.sidebarWidth"

    static var hasSavedWidth: Bool {
        UserDefaults.standard.object(forKey: key) != nil
    }

    static func load() -> CGFloat {
        let value = UserDefaults.standard.double(forKey: key)
        return value > 0 ? value : 250
    }

    static func save(_ width: CGFloat) {
        UserDefaults.standard.set(Double(width), forKey: key)
    }
}

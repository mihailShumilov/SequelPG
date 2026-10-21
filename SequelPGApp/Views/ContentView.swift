import AppKit
import SwiftUI

/// Root of one connection window. Shows the start page until a connection is
/// established, then the three-column workspace: navigator sidebar, main area,
/// and an inspector. Each window owns its own `AppViewModel`, so several
/// connections can be open side by side as native window tabs.
struct ConnectionWindowView: View {
    static let windowID = "connection"

    @Environment(ConnectionListViewModel.self) private var connectionListVM
    @Environment(\.openWindow) private var openWindow
    @State private var appVM = AppViewModel()
    @State private var sidebarVisibility: NavigationSplitViewVisibility = .all

    var body: some View {
        Group {
            if appVM.isConnected {
                workspace
            } else {
                StartPageView()
                    .navigationTitle("SequelPG")
                    .alert("Connection Error", isPresented: errorBinding) {
                        Button("OK") { appVM.errorMessage = nil }
                    } message: {
                        Text(appVM.errorMessage ?? "")
                    }
            }
        }
        .environment(appVM)
        .environment(appVM.navigatorVM)
        .environment(appVM.tableVM)
        .environment(appVM.queryVM)
        .environment(appVM.queryHistoryVM)
        .environment(appVM.erdVM)
        .environment(connectionListVM)
        .focusedSceneValue(\.appViewModel, appVM)
        .frame(minWidth: 900, minHeight: 600)
        .background(WindowAccessor { window in
            WindowTabbing.attachIfRequested(window)
        })
        // Opened via "Open Connection in New Tab": connect straight away.
        .task {
            if let profileID = WindowTabbing.takePendingProfileID() {
                await connectToSavedProfile(profileID)
            }
        }
        // Closing the window (or its tab) ends the session it owned.
        .onDisappear {
            if appVM.isConnected {
                Task { await appVM.disconnect() }
            }
        }
    }

    private func connectToSavedProfile(_ id: UUID) async {
        guard let profile = connectionListVM.profiles.first(where: { $0.id == id }) else { return }
        let password = connectionListVM.loadPasswordForProfile(profile)
        let sshPassword = connectionListVM.loadSSHPasswordForProfile(profile)
        await appVM.connect(
            profile: profile,
            password: password.isEmpty ? nil : password,
            sshPassword: profile.useSSHTunnel ? sshPassword : nil
        )
    }

    private var errorBinding: Binding<Bool> {
        Binding(
            get: { appVM.errorMessage != nil },
            set: { if !$0 { appVM.errorMessage = nil } }
        )
    }

    // MARK: - Connected workspace

    private var workspace: some View {
        @Bindable var appVM = appVM
        return NavigationSplitView(columnVisibility: $sidebarVisibility) {
            NavigatorView()
                .navigationSplitViewColumnWidth(min: 200, ideal: 260, max: 480)
        } detail: {
            MainAreaView()
                .inspector(isPresented: $appVM.showInspector) {
                    InspectorView()
                        .inspectorColumnWidth(min: 220, ideal: 280, max: 440)
                }
        }
        .navigationTitle(appVM.connectedProfileName ?? "SequelPG")
        .navigationSubtitle(appVM.navigatorVM.connectedDatabase)
        .toolbar {
            ToolbarItem(placement: .navigation) {
                connectionMenu
            }

            ToolbarItem(placement: .principal) {
                Picker("Mode", selection: $appVM.selectedTab) {
                    ForEach(AppViewModel.MainTab.allCases, id: \.self) { tab in
                        Text(tab.rawValue).tag(tab)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .help("Switch between Structure, Content, Definition, Query, and Diagram (⌘1–⌘5)")
            }

            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    Task { await appVM.refreshNavigator() }
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .help("Reload schemas and objects (⌘R)")

                Menu {
                    Button("Extensions…") { appVM.showExtensionsSheet = true }
                    Button("Roles & Privileges…") { appVM.showRolesSheet = true }
                    Button("Function Library…") { appVM.showFunctionLibrary = true }
                    Divider()
                    Button("Export Database…") { appVM.showExportSheet = true }
                    Button("Import SQL File…") { appVM.showImportSheet = true }
                    Divider()
                    Button("Disconnect") { Task { await appVM.disconnect() } }
                } label: {
                    Label("Database", systemImage: "cylinder.split.1x2")
                }
                .help("Database tools")

                Button {
                    appVM.showInspector.toggle()
                } label: {
                    Label("Inspector", systemImage: "sidebar.trailing")
                }
                .help("Show or hide the Inspector (⌥⌘I)")
            }
        }
        .sheet(isPresented: $appVM.showEditConnectionSheet) {
            if let profileID = appVM.connectedProfileID {
                EditConnectionSheet(profileID: profileID)
                    .environment(appVM)
                    .environment(connectionListVM)
            }
        }
        .sheet(isPresented: $appVM.showExtensionsSheet) {
            ExtensionsSheet().environment(appVM)
        }
        .sheet(isPresented: $appVM.showRolesSheet) {
            RolesSheet().environment(appVM)
        }
        .sheet(isPresented: $appVM.showFunctionLibrary) {
            FunctionLibrarySheet().environment(appVM.queryVM)
        }
        .sheet(isPresented: $appVM.showExportSheet) {
            ExportSheet().environment(appVM)
        }
        .sheet(isPresented: $appVM.showImportSheet) {
            ImportSheet().environment(appVM)
        }
        .alert("Error", isPresented: errorBinding) {
            Button("OK") { appVM.errorMessage = nil }
        } message: {
            Text(appVM.errorMessage ?? "")
        }
    }
}

// MARK: - Connection menu

private extension ConnectionWindowView {
    /// Toolbar menu for this window's connection and for opening others.
    var connectionMenu: some View {
        Menu {
            Section(appVM.connectedProfileName ?? "Connection") {
                Button("Edit Connection…") { appVM.showEditConnectionSheet = true }
                    .disabled(appVM.connectedProfileID == nil)
                Button("Disconnect") { Task { await appVM.disconnect() } }
            }
            Section("Open in New Tab") {
                ForEach(connectionListVM.profiles) { profile in
                    Button(profile.displayName) {
                        WindowTabbing.openNewTab(openWindow: openWindow, connectingTo: profile.id)
                    }
                }
                Button("New Connection Tab") {
                    WindowTabbing.openNewTab(openWindow: openWindow)
                }
            }
        } label: {
            Label("Connections", systemImage: "server.rack")
        }
        .help("Edit this connection, or open another one in a new tab")
    }
}

// MARK: - Window access

/// Hands the hosting `NSWindow` to a callback once the view is in a window.
/// Used to join a freshly opened window to the current window's tab group.
struct WindowAccessor: NSViewRepresentable {
    let onWindow: (NSWindow) -> Void

    func makeNSView(context _: Context) -> NSView {
        let view = HostView()
        view.onWindow = onWindow
        return view
    }

    func updateNSView(_: NSView, context _: Context) {}

    private final class HostView: NSView {
        var onWindow: ((NSWindow) -> Void)?
        private var reported = false

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard !reported, let window else { return }
            reported = true
            onWindow?(window)
        }
    }
}

import SwiftUI

/// Pre-connection window content: saved connections in a sidebar, the
/// selected connection's settings in the detail column. Edits are saved when
/// switching connections or connecting; Test opens a throwaway connection.
struct StartPageView: View {
    @Environment(AppViewModel.self) var appVM
    @Environment(ConnectionListViewModel.self) var connectionListVM

    // MARK: - Form State

    @State private var form = ConnectionFormModel()
    @State private var validationErrors: [String] = []
    @State private var deleteTarget: ConnectionProfile?
    /// The profile whose settings `form` currently holds. Saves always target
    /// this id, never the sidebar selection, so a form is never written into
    /// a different profile than the one it was loaded from.
    @State private var formProfileId: UUID?
    @State private var isTestingConnection = false
    @State private var testResult: TestConnectionResult?
    @State private var isConnecting = false
    @State private var columnVisibility: NavigationSplitViewVisibility = .all

    private enum TestConnectionResult: Equatable {
        case success
        case failure(String)
    }

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            connectionList
                .navigationSplitViewColumnWidth(min: 200, ideal: 240, max: 360)
        } detail: {
            detailColumn
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    createNewProfile()
                } label: {
                    Label("New Connection", systemImage: "plus")
                }
                .help("Add a new connection")
            }
        }
        .onChange(of: appVM.isConnected) { _, connected in
            if connected { isConnecting = false }
        }
        .onChange(of: appVM.errorMessage) { _, message in
            if message != nil { isConnecting = false }
        }
        .alert("Delete Connection?", isPresented: .init(
            get: { deleteTarget != nil },
            set: { if !$0 { deleteTarget = nil } }
        )) {
            Button("Cancel", role: .cancel) {}
            Button("Delete", role: .destructive) {
                if let target = deleteTarget {
                    connectionListVM.deleteProfile(target)
                }
            }
        } message: {
            Text("\u{201C}\(deleteTarget?.name ?? "")\u{201D} and its saved password will be removed.")
        }
    }

    // MARK: - Sidebar: Connection List

    private var connectionList: some View {
        @Bindable var connectionListVM = connectionListVM
        return VStack(spacing: 0) {
            List(connectionListVM.filteredProfiles, selection: $connectionListVM.selectedProfileId) { profile in
                Label {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(profile.displayName)
                            .lineLimit(1)
                        Text(profileSummary(profile))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                } icon: {
                    Image(systemName: profile.useSSHTunnel ? "lock.shield" : "server.rack")
                }
                .tag(profile.id)
            }
            .listStyle(.sidebar)
            // Row-level tap gestures swallow the click the List needs to change
            // its selection on macOS, so double-click (and Return) is handled by
            // the List's own primary action instead.
            .contextMenu(forSelectionType: UUID.self) { ids in
                if let id = ids.first, ids.count == 1,
                   let profile = connectionListVM.profiles.first(where: { $0.id == id })
                {
                    Button("Connect") { connect(profileId: id) }
                    Button("Duplicate") { duplicateProfile(profile) }
                    Divider()
                    Button("Delete…", role: .destructive) {
                        deleteTarget = profile
                    }
                }
            } primaryAction: { ids in
                if let id = ids.first, ids.count == 1 {
                    connect(profileId: id)
                }
            }
            .overlay {
                if connectionListVM.profiles.isEmpty {
                    ContentUnavailableView {
                        Label("No Connections", systemImage: "server.rack")
                    } description: {
                        Text("Click + to add your first PostgreSQL server.")
                    }
                } else if connectionListVM.filteredProfiles.isEmpty {
                    ContentUnavailableView.search(text: connectionListVM.filterText)
                }
            }

            Divider()

            HStack(spacing: 6) {
                SearchField(text: $connectionListVM.filterText, prompt: "Filter")
                    .frame(maxWidth: .infinity)
                Button {
                    createNewProfile()
                } label: {
                    Image(systemName: "plus")
                }
                .help("Add connection")
                .accessibilityLabel("Add connection")
                Button {
                    if let profile = connectionListVM.selectedProfile {
                        deleteTarget = profile
                    }
                } label: {
                    Image(systemName: "minus")
                }
                .disabled(connectionListVM.selectedProfile == nil)
                .help("Delete the selected connection")
                .accessibilityLabel("Delete connection")
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(.bar)
        }
        .onChange(of: connectionListVM.selectedProfileId) { _, newId in
            switchForm(to: newId)
        }
        .onAppear {
            switchForm(to: connectionListVM.selectedProfileId)
        }
    }

    /// Saves the form back to the profile it was loaded from, then loads the
    /// profile `id` into it. A no-op when the form already holds `id`, so it is
    /// safe to call from both the selection observer and explicit actions.
    private func switchForm(to id: UUID?) {
        guard id != formProfileId else { return }
        if let currentId = formProfileId {
            saveFormToProfile(id: currentId)
        }
        formProfileId = id
        if let id, let profile = connectionListVM.profiles.first(where: { $0.id == id }) {
            loadFormFromProfile(profile)
        }
        validationErrors = []
        testResult = nil
    }

    private func profileSummary(_ profile: ConnectionProfile) -> String {
        if profile.useSSHTunnel {
            return "\(profile.database) via \(profile.sshHost)"
        }
        return "\(profile.host):\(profile.port)/\(profile.database)"
    }

    // MARK: - Detail: Connection Form

    @ViewBuilder
    private var detailColumn: some View {
        if connectionListVM.selectedProfile != nil {
            VStack(spacing: 0) {
                ConnectionSettingsForm(form: $form)
                    // Fresh password-visibility state for each profile.
                    .id(formProfileId)

                if !validationErrors.isEmpty {
                    InlineBanner(kind: .warning, message: validationErrors.joined(separator: "\n")) {
                        validationErrors = []
                    }
                }

                if let testResult {
                    switch testResult {
                    case .success:
                        InlineBanner(kind: .info, message: "Connection test succeeded.") { self.testResult = nil }
                    case let .failure(message):
                        InlineBanner(kind: .error, message: message) { self.testResult = nil }
                    }
                }

                Divider()

                HStack(spacing: 10) {
                    Button {
                        testSelected()
                    } label: {
                        if isTestingConnection {
                            ProgressView()
                                .controlSize(.small)
                                .frame(width: 60)
                        } else {
                            Text("Test Connection")
                                .frame(minWidth: 60)
                        }
                    }
                    .disabled(isTestingConnection || isConnecting)
                    .help("Open a throwaway connection to verify these settings")

                    Spacer()

                    Text("Tip: ⌘T opens another connection in a new tab.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)

                    Spacer()

                    Button {
                        connectSelected()
                    } label: {
                        if isConnecting {
                            ProgressView()
                                .controlSize(.small)
                                .frame(width: 70)
                        } else {
                            Text("Connect")
                                .frame(minWidth: 70)
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(isTestingConnection || isConnecting)
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
                .background(.bar)
            }
        } else {
            ContentUnavailableView {
                Label("No Connection Selected", systemImage: "server.rack")
            } description: {
                Text("Choose a saved connection, or add a new one with the + button.")
            } actions: {
                Button("New Connection") { createNewProfile() }
            }
        }
    }

    // MARK: - Actions

    private func createNewProfile() {
        // Save current form before creating new
        if let currentId = formProfileId {
            saveFormToProfile(id: currentId)
        }

        let profile = ConnectionProfile(
            name: "New Connection",
            host: "localhost",
            port: 5432,
            database: "postgres",
            username: "postgres"
        )
        connectionListVM.addProfile(profile, password: nil)
    }

    private func duplicateProfile(_ source: ConnectionProfile) {
        if let currentId = formProfileId {
            saveFormToProfile(id: currentId)
        }
        var copy = source
        copy.name = "\(source.name) copy"
        let password = connectionListVM.loadPasswordForProfile(source)
        let sshPassword = connectionListVM.loadSSHPasswordForProfile(source)
        connectionListVM.addProfile(
            ConnectionProfile(
                name: copy.name,
                host: copy.host,
                port: copy.port,
                database: copy.database,
                username: copy.username,
                sslMode: copy.sslMode,
                useSSHTunnel: copy.useSSHTunnel,
                sshHost: copy.sshHost,
                sshPort: copy.sshPort,
                sshUser: copy.sshUser,
                sshAuthMethod: copy.sshAuthMethod,
                sshKeyPath: copy.sshKeyPath
            ),
            password: password.isEmpty ? nil : password,
            sshPassword: copy.useSSHTunnel && !sshPassword.isEmpty ? sshPassword : nil
        )
    }

    private func loadFormFromProfile(_ profile: ConnectionProfile) {
        form.load(
            from: profile,
            password: connectionListVM.loadPasswordForProfile(profile),
            sshPassword: connectionListVM.loadSSHPasswordForProfile(profile)
        )
    }

    private func saveFormToProfile(id: UUID) {
        guard let existing = connectionListVM.profiles.first(where: { $0.id == id }) else { return }
        let updated = form.buildProfile(id: id, fallbackPort: existing.port)
        connectionListVM.updateProfile(updated, password: form.password, sshPassword: form.effectiveSSHPassword)
    }

    private func testSelected() {
        guard let id = formProfileId else { return }

        let profile = form.buildProfile(id: id, fallbackPort: 0)
        let errors = profile.validate()
        if !errors.isEmpty {
            validationErrors = errors
            testResult = nil
            return
        }
        validationErrors = []
        testResult = nil

        let password: String? = form.password.isEmpty ? nil : form.password
        let sshPassword = form.effectiveSSHPassword
        isTestingConnection = true

        Task {
            let errorMessage = await connectionListVM.testConnection(
                profile: profile,
                password: password,
                sshPassword: sshPassword
            )
            isTestingConnection = false
            testResult = errorMessage.map { .failure($0) } ?? .success
        }
    }

    /// Selects `profileId`, loads it into the form (saving any edits to the
    /// previous profile first), and connects with it.
    private func connect(profileId: UUID) {
        connectionListVM.selectedProfileId = profileId
        switchForm(to: profileId)
        connectSelected()
    }

    private func connectSelected() {
        guard let id = formProfileId else { return }

        let profile = form.buildProfile(id: id)

        let errors = profile.validate()
        if !errors.isEmpty {
            validationErrors = errors
            return
        }

        // Save before connecting
        connectionListVM.updateProfile(profile, password: form.password, sshPassword: form.effectiveSSHPassword)
        validationErrors = []
        testResult = nil

        // Connect in the current window
        let password: String? = form.password.isEmpty ? nil : form.password
        isConnecting = true
        Task {
            await appVM.connect(profile: profile, password: password, sshPassword: form.effectiveSSHPassword)
            isConnecting = false
        }
    }
}

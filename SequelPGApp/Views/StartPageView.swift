import SwiftUI

/// Pre-connection window content: saved connections in a sidebar, the
/// selected connection's settings in the detail column. Edits are saved when
/// switching connections or connecting; Test opens a throwaway connection.
struct StartPageView: View {
    @Environment(AppViewModel.self) var appVM
    @Environment(ConnectionListViewModel.self) var connectionListVM

    // MARK: - Form State

    @State private var form = ConnectionFormModel()
    @State private var showPassword = false
    @State private var showSSHPassword = false
    @State private var validationErrors: [String] = []
    @State private var deleteTarget: ConnectionProfile?
    @State private var previousSelectedId: UUID?
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
                        Text(profile.name.isEmpty ? "Untitled" : profile.name)
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
                .contentShape(Rectangle())
                // Two separate tap gestures race each other and cause selection
                // flicker before the double-tap resolves. Use a `simultaneousGesture`
                // so the selection-on-single-tap behavior is a side effect of the
                // List's native selection while double-tap triggers connect.
                .simultaneousGesture(
                    TapGesture(count: 2).onEnded {
                        connectionListVM.selectedProfileId = profile.id
                        loadFormFromProfile(profile)
                        connectSelected()
                    }
                )
                .contextMenu {
                    Button("Connect") {
                        connectionListVM.selectedProfileId = profile.id
                        loadFormFromProfile(profile)
                        connectSelected()
                    }
                    Button("Duplicate") { duplicateProfile(profile) }
                    Divider()
                    Button("Delete…", role: .destructive) {
                        deleteTarget = profile
                    }
                }
            }
            .listStyle(.sidebar)
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
            // Auto-save previous profile before switching
            if let prevId = previousSelectedId, prevId != newId {
                saveFormToProfile(id: prevId)
            }
            // Load new profile into form
            if let newId, let profile = connectionListVM.profiles.first(where: { $0.id == newId }) {
                loadFormFromProfile(profile)
            }
            previousSelectedId = newId
            validationErrors = []
            testResult = nil
        }
        .onAppear {
            if let profile = connectionListVM.selectedProfile {
                loadFormFromProfile(profile)
                previousSelectedId = profile.id
            }
        }
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
                Form {
                    Section {
                        TextField("Name", text: $form.name)
                        TextField("Host", text: $form.host, prompt: Text("localhost"))
                        TextField("Port", text: $form.port, prompt: Text("5432"))
                        TextField("Database", text: $form.database)
                        TextField("Username", text: $form.username)
                        HStack {
                            if showPassword {
                                TextField("Password", text: $form.password)
                            } else {
                                SecureField("Password", text: $form.password)
                            }
                            Button {
                                showPassword.toggle()
                            } label: {
                                Image(systemName: showPassword ? "eye.slash" : "eye")
                            }
                            .buttonStyle(.borderless)
                            .help(showPassword ? "Hide password" : "Show password")
                        }
                        Picker("SSL Mode", selection: $form.sslMode) {
                            ForEach(SSLMode.allCases, id: \.self) { mode in
                                Text(mode.displayName).tag(mode)
                            }
                        }
                    } header: {
                        Text("PostgreSQL Server")
                    } footer: {
                        Text("postgresql://\(form.username)@\(form.host):\(form.port)/\(form.database)")
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .textSelection(.enabled)
                    }

                    Section("SSH Tunnel") {
                        SSHTunnelFormSection(
                            useSSHTunnel: $form.useSSHTunnel,
                            sshHost: $form.sshHost,
                            sshPort: $form.sshPort,
                            sshUser: $form.sshUser,
                            sshAuthMethod: $form.sshAuthMethod,
                            sshKeyPath: $form.sshKeyPath,
                            sshPassword: $form.sshPassword,
                            showSSHPassword: $showSSHPassword
                        )
                    }
                }
                .formStyle(.grouped)

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
        if let prevId = connectionListVM.selectedProfileId {
            saveFormToProfile(id: prevId)
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
        if let prevId = connectionListVM.selectedProfileId {
            saveFormToProfile(id: prevId)
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
        showPassword = false
        showSSHPassword = false
    }

    private func saveFormToProfile(id: UUID) {
        guard let existing = connectionListVM.profiles.first(where: { $0.id == id }) else { return }
        let updated = form.buildProfile(id: id, fallbackPort: existing.port)
        connectionListVM.updateProfile(updated, password: form.password, sshPassword: form.effectiveSSHPassword)
    }

    private func testSelected() {
        guard let id = connectionListVM.selectedProfileId else { return }

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

    private func connectSelected() {
        guard let id = connectionListVM.selectedProfileId else { return }

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

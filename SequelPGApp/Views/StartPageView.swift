import SwiftUI

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

    private enum TestConnectionResult: Equatable {
        case success
        case failure(String)
    }

    var body: some View {
        HStack(spacing: 0) {
            brandingColumn
            Divider()
            connectionListColumn
            Divider()
            detailColumn
        }
    }

    // MARK: - Left Column: Branding

    private var brandingColumn: some View {
        @Bindable var connectionListVM = connectionListVM
        return VStack(spacing: 12) {
            Spacer()

            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 80, height: 80)

            Text("SequelPG")
                .font(.title2)
                .fontWeight(.semibold)

            if let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String {
                Text("v\(version)")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }

            Spacer()

            TextField("Filter...", text: $connectionListVM.filterText)
                .textFieldStyle(.roundedBorder)
                .padding(.horizontal, 12)

            Button {
                createNewProfile()
            } label: {
                Label("New Server", systemImage: "plus")
                    .frame(maxWidth: .infinity)
            }
            .controlSize(.large)
            .padding(.horizontal, 12)
            .padding(.bottom, 16)
        }
        .frame(width: 180)
        .background(.background)
    }

    // MARK: - Center Column: Connection List

    private var connectionListColumn: some View {
        @Bindable var connectionListVM = connectionListVM
        return List(connectionListVM.filteredProfiles, selection: $connectionListVM.selectedProfileId) { profile in
            HStack(spacing: 8) {
                Image(systemName: "server.rack")
                    .foregroundStyle(.secondary)
                Text(profile.name)
                    .lineLimit(1)
                Spacer()
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
                Divider()
                Button("Delete", role: .destructive) {
                    deleteTarget = profile
                }
            }
        }
        .listStyle(.sidebar)
        .frame(minWidth: 250)
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
            Text("Are you sure you want to delete \"\(deleteTarget?.name ?? "")\"?")
        }
    }

    // MARK: - Right Column: Detail Form

    private var detailColumn: some View {
        Group {
            if connectionListVM.selectedProfile != nil {
                VStack(spacing: 0) {
                    Form {
                        Section {
                            TextField("Name:", text: $form.name)
                            HStack {
                                TextField("Host:", text: $form.host)
                                TextField("Port:", text: $form.port)
                                    .frame(width: 70)
                            }
                            TextField("Database:", text: $form.database)
                            TextField("Username:", text: $form.username)
                            HStack {
                                if showPassword {
                                    TextField("Password:", text: $form.password)
                                } else {
                                    SecureField("Password:", text: $form.password)
                                }
                                Button {
                                    showPassword.toggle()
                                } label: {
                                    Image(systemName: showPassword ? "eye.slash" : "eye")
                                }
                                .buttonStyle(.borderless)
                            }
                            Picker("SSL Mode:", selection: $form.sslMode) {
                                ForEach(SSLMode.allCases, id: \.self) { mode in
                                    Text(mode.displayName).tag(mode)
                                }
                            }
                        }

                        Section {
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
                        } header: {
                            Text("SSH Tunnel")
                        }
                    }
                    .formStyle(.grouped)

                    if !validationErrors.isEmpty {
                        VStack(alignment: .leading, spacing: 2) {
                            ForEach(validationErrors, id: \.self) { error in
                                Text(error)
                                    .foregroundStyle(.red)
                                    .font(.caption)
                            }
                        }
                        .padding(.horizontal)
                        .padding(.bottom, 8)
                    }

                    if let testResult {
                        testResultBanner(testResult)
                    }

                    Divider()

                    HStack {
                        Button(role: .destructive) {
                            if let profile = connectionListVM.selectedProfile {
                                deleteTarget = profile
                            }
                        } label: {
                            Image(systemName: "trash")
                        }
                        .help("Delete Connection")

                        Spacer()

                        Button {
                            testSelected()
                        } label: {
                            if isTestingConnection {
                                ProgressView()
                                    .controlSize(.small)
                                    .frame(width: 32)
                            } else {
                                Text("Test")
                            }
                        }
                        .disabled(isTestingConnection)
                        .help("Test connection")

                        Button("Connect") {
                            connectSelected()
                        }
                        .keyboardShortcut(.return, modifiers: .command)
                        .buttonStyle(.borderedProminent)
                        .disabled(isTestingConnection)
                    }
                    .padding(16)
                }
            } else {
                VStack {
                    Spacer()
                    Text("Select or create a connection")
                        .foregroundStyle(.secondary)
                    Spacer()
                }
            }
        }
        .frame(minWidth: 300, idealWidth: 350)
    }

    // MARK: - Actions

    private func createNewProfile() {
        // Save current form before creating new
        if let prevId = connectionListVM.selectedProfileId {
            saveFormToProfile(id: prevId)
        }

        let profile = ConnectionProfile(
            name: "New Server",
            host: "localhost",
            port: 5432,
            database: "postgres",
            username: "postgres"
        )
        connectionListVM.addProfile(profile, password: nil)
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

    @ViewBuilder
    private func testResultBanner(_ result: TestConnectionResult) -> some View {
        switch result {
        case .success:
            HStack(spacing: 6) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Text("Connection successful")
                    .font(.caption)
                    .foregroundStyle(.green)
            }
            .padding(.horizontal)
            .padding(.bottom, 8)
        case .failure(let message):
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.red)
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
                Spacer(minLength: 0)
            }
            .padding(.horizontal)
            .padding(.bottom, 8)
        }
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

        // Connect in the current tab
        let password: String? = form.password.isEmpty ? nil : form.password
        Task {
            await appVM.connect(profile: profile, password: password, sshPassword: form.effectiveSSHPassword)
        }
    }
}

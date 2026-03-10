import SwiftUI

struct StartPageView: View {
    @EnvironmentObject var appVM: AppViewModel

    // MARK: - Form State

    @State private var formName = ""
    @State private var formHost = ""
    @State private var formPort = "5432"
    @State private var formDatabase = ""
    @State private var formUsername = ""
    @State private var formPassword = ""
    @State private var formSSLMode: SSLMode = .prefer
    @State private var showPassword = false
    @State private var validationErrors: [String] = []
    @State private var deleteTarget: ConnectionProfile?
    @State private var previousSelectedId: UUID?

    // SSH tunnel form state
    @State private var formUseSSHTunnel = false
    @State private var formSSHHost = ""
    @State private var formSSHPort = "22"
    @State private var formSSHUser = ""
    @State private var formSSHAuthMethod: SSHAuthMethod = .keyFile
    @State private var formSSHKeyPath = ""
    @State private var formSSHPassword = ""
    @State private var showSSHPassword = false

    private var connectionListVM: ConnectionListViewModel {
        appVM.connectionListVM
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
        VStack(spacing: 12) {
            Spacer()

            Image(systemName: "cylinder.split.1x2")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)

            Text("SequelPG")
                .font(.title2)
                .fontWeight(.semibold)

            if let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String {
                Text("v\(version)")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }

            Spacer()

            TextField("Filter...", text: $appVM.connectionListVM.filterText)
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
        List(connectionListVM.filteredProfiles, selection: $appVM.connectionListVM.selectedProfileId) { profile in
            HStack(spacing: 8) {
                Image(systemName: "server.rack")
                    .foregroundStyle(.secondary)
                Text(profile.name)
                    .lineLimit(1)
                Spacer()
            }
            .tag(profile.id)
            .contentShape(Rectangle())
            .onTapGesture(count: 2) {
                connectionListVM.selectedProfileId = profile.id
                loadFormFromProfile(profile)
                connectSelected()
            }
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
        .onChange(of: connectionListVM.selectedProfileId) { newId in
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
                            TextField("Name:", text: $formName)
                            HStack {
                                TextField("Host:", text: $formHost)
                                TextField("Port:", text: $formPort)
                                    .frame(width: 70)
                            }
                            TextField("Database:", text: $formDatabase)
                            TextField("Username:", text: $formUsername)
                            HStack {
                                if showPassword {
                                    TextField("Password:", text: $formPassword)
                                } else {
                                    SecureField("Password:", text: $formPassword)
                                }
                                Button {
                                    showPassword.toggle()
                                } label: {
                                    Image(systemName: showPassword ? "eye.slash" : "eye")
                                }
                                .buttonStyle(.borderless)
                            }
                            Picker("SSL Mode:", selection: $formSSLMode) {
                                ForEach(SSLMode.allCases, id: \.self) { mode in
                                    Text(mode.displayName).tag(mode)
                                }
                            }
                        }

                        Section {
                            Toggle("Connect via SSH Tunnel", isOn: $formUseSSHTunnel.animation())

                            if formUseSSHTunnel {
                                HStack {
                                    TextField("SSH Host:", text: $formSSHHost)
                                    TextField("SSH Port:", text: $formSSHPort)
                                        .frame(width: 70)
                                }
                                TextField("SSH User:", text: $formSSHUser)
                                Picker("Auth Method:", selection: $formSSHAuthMethod) {
                                    ForEach(SSHAuthMethod.allCases, id: \.self) { method in
                                        Text(method.displayName).tag(method)
                                    }
                                }

                                if formSSHAuthMethod == .keyFile {
                                    TextField("Key Path:", text: $formSSHKeyPath)
                                        .help("Path to SSH private key (e.g. ~/.ssh/id_rsa). Leave empty to use SSH agent.")
                                }

                                if formSSHAuthMethod == .password {
                                    HStack {
                                        if showSSHPassword {
                                            TextField("SSH Password:", text: $formSSHPassword)
                                        } else {
                                            SecureField("SSH Password:", text: $formSSHPassword)
                                        }
                                        Button {
                                            showSSHPassword.toggle()
                                        } label: {
                                            Image(systemName: showSSHPassword ? "eye.slash" : "eye")
                                        }
                                        .buttonStyle(.borderless)
                                    }
                                }
                            }
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

                        Button("Test") {}
                            .disabled(true)
                            .help("Connection test (coming soon)")

                        Button("Connect") {
                            connectSelected()
                        }
                        .keyboardShortcut(.return, modifiers: .command)
                        .buttonStyle(.borderedProminent)
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
        formName = profile.name
        formHost = profile.host
        formPort = String(profile.port)
        formDatabase = profile.database
        formUsername = profile.username
        formSSLMode = profile.sslMode
        formPassword = connectionListVM.loadPasswordForProfile(profile)
        showPassword = false

        formUseSSHTunnel = profile.useSSHTunnel
        formSSHHost = profile.sshHost
        formSSHPort = String(profile.sshPort)
        formSSHUser = profile.sshUser
        formSSHAuthMethod = profile.sshAuthMethod
        formSSHKeyPath = profile.sshKeyPath
        formSSHPassword = connectionListVM.loadSSHPasswordForProfile(profile)
        showSSHPassword = false
    }

    private func saveFormToProfile(id: UUID) {
        guard let existing = connectionListVM.profiles.first(where: { $0.id == id }) else { return }
        let portInt = Int(formPort) ?? existing.port
        let sshPortInt = Int(formSSHPort) ?? 22
        let updated = ConnectionProfile(
            id: id,
            name: formName.trimmingCharacters(in: .whitespaces),
            host: formHost.trimmingCharacters(in: .whitespaces),
            port: portInt,
            database: formDatabase.trimmingCharacters(in: .whitespaces),
            username: formUsername.trimmingCharacters(in: .whitespaces),
            sslMode: formSSLMode,
            useSSHTunnel: formUseSSHTunnel,
            sshHost: formSSHHost.trimmingCharacters(in: .whitespaces),
            sshPort: sshPortInt,
            sshUser: formSSHUser.trimmingCharacters(in: .whitespaces),
            sshAuthMethod: formSSHAuthMethod,
            sshKeyPath: formSSHKeyPath.trimmingCharacters(in: .whitespaces)
        )
        let sshPass: String? = formUseSSHTunnel ? formSSHPassword : nil
        connectionListVM.updateProfile(updated, password: formPassword, sshPassword: sshPass)
    }

    private func connectSelected() {
        guard let id = connectionListVM.selectedProfileId else { return }

        let portInt = Int(formPort) ?? 5432
        let sshPortInt = Int(formSSHPort) ?? 22
        let profile = ConnectionProfile(
            id: id,
            name: formName.trimmingCharacters(in: .whitespaces),
            host: formHost.trimmingCharacters(in: .whitespaces),
            port: portInt,
            database: formDatabase.trimmingCharacters(in: .whitespaces),
            username: formUsername.trimmingCharacters(in: .whitespaces),
            sslMode: formSSLMode,
            useSSHTunnel: formUseSSHTunnel,
            sshHost: formSSHHost.trimmingCharacters(in: .whitespaces),
            sshPort: sshPortInt,
            sshUser: formSSHUser.trimmingCharacters(in: .whitespaces),
            sshAuthMethod: formSSHAuthMethod,
            sshKeyPath: formSSHKeyPath.trimmingCharacters(in: .whitespaces)
        )

        let errors = profile.validate()
        if !errors.isEmpty {
            validationErrors = errors
            return
        }

        // Save before connecting
        let sshPass: String? = formUseSSHTunnel ? formSSHPassword : nil
        connectionListVM.updateProfile(profile, password: formPassword, sshPassword: sshPass)
        validationErrors = []

        Task {
            await appVM.connect(profile: profile)
        }
    }
}

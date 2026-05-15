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
            Rectangle().fill(Theme.line).frame(width: 1)
            connectionListColumn
            Rectangle().fill(Theme.line).frame(width: 1)
            detailColumn
        }
        .background(Theme.bg)
    }

    // MARK: - Left Column: Branding

    private var brandingColumn: some View {
        @Bindable var connectionListVM = connectionListVM
        return VStack(alignment: .leading, spacing: 14) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 56, height: 56)

            VStack(alignment: .leading, spacing: 2) {
                Text("SequelPG")
                    .appDisplayItalic(24)
                if let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String {
                    Text("v\(version) · macOS 14+")
                        .appMono(10.5, color: Theme.ink4)
                        .tracking(0.6)
                }
            }

            Text("MIT · No telemetry\nFree, forever")
                .appMono(10.5, color: Theme.ink4)
                .lineSpacing(2)

            Spacer()

            TextField("Filter…", text: $connectionListVM.filterText)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .foregroundStyle(Theme.ink2)
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(Theme.bg)
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(Theme.line, lineWidth: 1)
                )

            Button {
                createNewProfile()
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "plus")
                        .font(.system(size: 11, weight: .bold))
                    Text("New server")
                        .font(.system(size: 12.5, weight: .semibold))
                }
                .foregroundStyle(Theme.onAccent)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 9)
                .background(Theme.accent)
                .clipShape(.rect(cornerRadius: 6))
            }
            .buttonStyle(.plain)
        }
        .padding(22)
        .frame(width: 220)
        .background(Theme.bg2)
    }

    // MARK: - Center Column: Connection List

    private var connectionListColumn: some View {
        @Bindable var connectionListVM = connectionListVM
        return List(connectionListVM.filteredProfiles, selection: $connectionListVM.selectedProfileId) { profile in
            HStack(spacing: 10) {
                Image(systemName: profile.useSSHTunnel ? "lock.shield.fill" : "server.rack")
                    .foregroundStyle(Theme.ink3)
                    .font(.system(size: 12))
                Text(profile.name)
                    .font(.system(size: 13))
                    .lineLimit(1)
                Spacer()
                Text(profile.useSSHTunnel ? "ssh" : "\(profile.port)")
                    .font(Theme.mono(size: 10.5))
                    .foregroundStyle(Theme.ink4)
            }
            .padding(.vertical, 4)
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
        .scrollContentBackground(.hidden)
        .background(Theme.bg)
        .frame(minWidth: 280)
        .safeAreaInset(edge: .top, spacing: 0) {
            HStack {
                Text("i. — saved servers")
                    .appSectionLabel()
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.top, 14)
            .padding(.bottom, 8)
            .background(Theme.bg)
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
            if let selected = connectionListVM.selectedProfile {
                VStack(spacing: 0) {
                    // Editorial header above the form
                    HStack(alignment: .firstTextBaseline) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("ii. — connection")
                                .appSectionLabel()
                            Text(selected.name.isEmpty ? "Untitled" : selected.name)
                                .appDisplayItalic(26)
                        }
                        Spacer()
                        if testResult == .success {
                            HStack(spacing: 6) {
                                Circle()
                                    .fill(Theme.accent)
                                    .frame(width: 7, height: 7)
                                    .overlay(Circle().stroke(Theme.accent.opacity(0.25), lineWidth: 3))
                                Text("connected")
                                    .appMono(11, color: Theme.ink3)
                            }
                        }
                    }
                    .padding(.horizontal, 22)
                    .padding(.top, 22)
                    .padding(.bottom, 4)

                    Text("postgresql://\(form.username)@\(form.host):\(form.port)/\(form.database)")
                        .appMono(11, color: Theme.ink4)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .padding(.horizontal, 22)
                        .padding(.bottom, 18)

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
                            Text("iii. — SSH tunnel")
                                .appSectionLabel()
                        }
                    }
                    .formStyle(.grouped)
                    .scrollContentBackground(.hidden)

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

                    Rectangle().fill(Theme.line).frame(height: 1)

                    HStack(spacing: 10) {
                        Button {
                            if let profile = connectionListVM.selectedProfile {
                                deleteTarget = profile
                            }
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: "trash").font(.system(size: 11))
                                Text("Delete").font(Theme.mono(size: 11.5))
                            }
                            .foregroundStyle(Theme.ink3)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 7)
                            .overlay(
                                RoundedRectangle(cornerRadius: 6)
                                    .strokeBorder(Theme.line, lineWidth: 1)
                            )
                        }
                        .buttonStyle(.plain)
                        .help("Delete Connection")

                        Spacer()

                        Button {
                            testSelected()
                        } label: {
                            Group {
                                if isTestingConnection {
                                    ProgressView()
                                        .controlSize(.small)
                                        .frame(width: 32)
                                } else {
                                    Text("Test")
                                        .font(Theme.mono(size: 12, weight: .medium))
                                        .foregroundStyle(Theme.ink)
                                }
                            }
                            .padding(.horizontal, 14)
                            .padding(.vertical, 7)
                            .overlay(
                                RoundedRectangle(cornerRadius: 6)
                                    .strokeBorder(Theme.line2, lineWidth: 1)
                            )
                        }
                        .buttonStyle(.plain)
                        .disabled(isTestingConnection)
                        .help("Test connection")

                        Button {
                            connectSelected()
                        } label: {
                            Text("Connect →")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(Theme.onAccent)
                                .padding(.horizontal, 18)
                                .padding(.vertical, 7)
                                .background(Theme.accent)
                                .clipShape(.rect(cornerRadius: 6))
                        }
                        .buttonStyle(.plain)
                        .keyboardShortcut(.return, modifiers: .command)
                        .disabled(isTestingConnection)
                    }
                    .padding(18)
                    .background(Theme.bg)
                }
                .background(Theme.bg)
            } else {
                VStack(spacing: 14) {
                    Spacer()
                    Text("ii. — connection")
                        .appSectionLabel()
                    Text("Pick a server.")
                        .appDisplayItalic(32)
                    Text("Select an existing connection from the list, or use New server to add one.")
                        .appBody()
                        .foregroundStyle(Theme.ink3)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 320)
                    Spacer()
                }
                .frame(maxWidth: .infinity)
                .background(Theme.bg)
            }
        }
        .frame(minWidth: 340, idealWidth: 400)
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

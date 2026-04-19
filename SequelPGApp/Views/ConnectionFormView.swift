import SwiftUI

/// Consolidates the 14 form fields shared by `ConnectionFormView` (modal add/edit)
/// and `StartPageView` (inline editor) so the two views agree on how profiles are
/// loaded, serialized back out, and defaulted.
///
/// Port values live as `String` because the UI exposes them through `TextField`;
/// they're coerced to `Int` via `buildProfile(id:fallbackPort:)`.
struct ConnectionFormModel {
    var name: String = ""
    var host: String = ""
    var port: String = "5432"
    var database: String = ""
    var username: String = ""
    var password: String = ""
    var sslMode: SSLMode = .prefer

    var useSSHTunnel: Bool = false
    var sshHost: String = ""
    var sshPort: String = "22"
    var sshUser: String = ""
    var sshAuthMethod: SSHAuthMethod = .keyFile
    var sshKeyPath: String = ""
    var sshPassword: String = ""

    mutating func load(
        from profile: ConnectionProfile,
        password: String,
        sshPassword: String
    ) {
        name = profile.name
        host = profile.host
        port = String(profile.port)
        database = profile.database
        username = profile.username
        sslMode = profile.sslMode
        self.password = password

        useSSHTunnel = profile.useSSHTunnel
        sshHost = profile.sshHost
        sshPort = String(profile.sshPort)
        sshUser = profile.sshUser
        sshAuthMethod = profile.sshAuthMethod
        sshKeyPath = profile.sshKeyPath
        self.sshPassword = sshPassword
    }

    /// Builds a `ConnectionProfile` from the current field values.
    /// - Parameters:
    ///   - id: Profile ID to preserve; pass a new UUID for add flows.
    ///   - fallbackPort: Value to use when `port` isn't a valid integer. Defaults
    ///     to 5432 to match the PostgreSQL default.
    func buildProfile(id: UUID, fallbackPort: Int = 5432) -> ConnectionProfile {
        let portInt = Int(port) ?? fallbackPort
        let sshPortInt = Int(sshPort) ?? 22
        return ConnectionProfile(
            id: id,
            name: name.trimmingCharacters(in: .whitespaces),
            host: host.trimmingCharacters(in: .whitespaces),
            port: portInt,
            database: database.trimmingCharacters(in: .whitespaces),
            username: username.trimmingCharacters(in: .whitespaces),
            sslMode: sslMode,
            useSSHTunnel: useSSHTunnel,
            sshHost: sshHost.trimmingCharacters(in: .whitespaces),
            sshPort: sshPortInt,
            sshUser: sshUser.trimmingCharacters(in: .whitespaces),
            sshAuthMethod: sshAuthMethod,
            sshKeyPath: sshKeyPath.trimmingCharacters(in: .whitespaces)
        )
    }

    /// `sshPassword` wrapped as optional, honoring the tunnel toggle.
    var effectiveSSHPassword: String? { useSSHTunnel ? sshPassword : nil }
}

struct ConnectionFormView: View {
    enum Mode {
        case add
        case edit(ConnectionProfile)
    }

    let mode: Mode
    @Environment(ConnectionListViewModel.self) var connectionListVM
    @Environment(\.dismiss) private var dismiss

    @State private var form = ConnectionFormModel()
    @State private var validationErrors: [String] = []

    private var isEditing: Bool {
        if case .edit = mode { return true }
        return false
    }

    var body: some View {
        VStack(spacing: 0) {
            Text(isEditing ? "Edit Connection" : "New Connection")
                .font(.headline)
                .padding()

            ScrollView {
                Form {
                    Section {
                        TextField("Name:", text: $form.name)
                        TextField("Host:", text: $form.host)
                        TextField("Port:", text: $form.port)
                        TextField("Database:", text: $form.database)
                        TextField("Username:", text: $form.username)
                        SecureField("Password:", text: $form.password)
                        Picker("SSL Mode:", selection: $form.sslMode) {
                            ForEach(SSLMode.allCases, id: \.self) { mode in
                                Text(mode.displayName).tag(mode)
                            }
                        }
                    } header: {
                        Text("Connection")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }

                    Divider()
                        .padding(.vertical, 4)

                    Section {
                        SSHTunnelFormSection(
                            useSSHTunnel: $form.useSSHTunnel,
                            sshHost: $form.sshHost,
                            sshPort: $form.sshPort,
                            sshUser: $form.sshUser,
                            sshAuthMethod: $form.sshAuthMethod,
                            sshKeyPath: $form.sshKeyPath,
                            sshPassword: $form.sshPassword
                        )
                    } header: {
                        Text("SSH Tunnel")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding()
            }

            if !validationErrors.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(validationErrors, id: \.self) { error in
                        Text(error)
                            .foregroundStyle(.red)
                            .font(.caption)
                    }
                }
                .padding(.horizontal)
            }

            HStack {
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button(isEditing ? "Save" : "Add") { save() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding()
        }
        .frame(width: 420)
        .frame(minHeight: 380, idealHeight: form.useSSHTunnel ? 580 : 420)
        .onAppear(perform: loadExisting)
    }

    private func loadExisting() {
        guard case let .edit(profile) = mode else { return }
        form.load(
            from: profile,
            password: connectionListVM.loadPasswordForProfile(profile),
            sshPassword: connectionListVM.loadSSHPasswordForProfile(profile)
        )
    }

    private func save() {
        // Use 0 as a fallback for the port so an empty value still triggers the
        // "Port must be between 1 and 65535" validation error.
        let profile = form.buildProfile(id: existingId ?? UUID(), fallbackPort: 0)

        let errors = profile.validate()
        if !errors.isEmpty {
            validationErrors = errors
            return
        }

        if isEditing {
            connectionListVM.updateProfile(profile, password: form.password, sshPassword: form.effectiveSSHPassword)
        } else {
            connectionListVM.addProfile(profile, password: form.password, sshPassword: form.effectiveSSHPassword)
        }
        dismiss()
    }

    private var existingId: UUID? {
        if case let .edit(profile) = mode { return profile.id }
        return nil
    }
}

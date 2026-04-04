import SwiftUI

struct ConnectionFormView: View {
    enum Mode {
        case add
        case edit(ConnectionProfile)
    }

    let mode: Mode
    @Environment(ConnectionListViewModel.self) var connectionListVM
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var host = ""
    @State private var port = "5432"
    @State private var database = ""
    @State private var username = ""
    @State private var password = ""
    @State private var sslMode: SSLMode = .prefer
    @State private var validationErrors: [String] = []

    // SSH tunnel fields
    @State private var useSSHTunnel = false
    @State private var sshHost = ""
    @State private var sshPort = "22"
    @State private var sshUser = ""
    @State private var sshAuthMethod: SSHAuthMethod = .keyFile
    @State private var sshKeyPath = ""
    @State private var sshPassword = ""

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
                        TextField("Name:", text: $name)
                        TextField("Host:", text: $host)
                        TextField("Port:", text: $port)
                        TextField("Database:", text: $database)
                        TextField("Username:", text: $username)
                        SecureField("Password:", text: $password)
                        Picker("SSL Mode:", selection: $sslMode) {
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
                            useSSHTunnel: $useSSHTunnel,
                            sshHost: $sshHost,
                            sshPort: $sshPort,
                            sshUser: $sshUser,
                            sshAuthMethod: $sshAuthMethod,
                            sshKeyPath: $sshKeyPath,
                            sshPassword: $sshPassword
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
        .frame(minHeight: 380, idealHeight: useSSHTunnel ? 580 : 420)
        .onAppear(perform: loadExisting)
    }

    private func loadExisting() {
        if case let .edit(profile) = mode {
            name = profile.name
            host = profile.host
            port = String(profile.port)
            database = profile.database
            username = profile.username
            sslMode = profile.sslMode
            password = connectionListVM.loadPasswordForProfile(profile)

            useSSHTunnel = profile.useSSHTunnel
            sshHost = profile.sshHost
            sshPort = String(profile.sshPort)
            sshUser = profile.sshUser
            sshAuthMethod = profile.sshAuthMethod
            sshKeyPath = profile.sshKeyPath
            sshPassword = connectionListVM.loadSSHPasswordForProfile(profile)
        }
    }

    private func save() {
        let portInt = Int(port) ?? 0
        let sshPortInt = Int(sshPort) ?? 22
        let profile = ConnectionProfile(
            id: existingId ?? UUID(),
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

        let errors = profile.validate()
        if !errors.isEmpty {
            validationErrors = errors
            return
        }

        let sshPass: String? = useSSHTunnel ? sshPassword : nil
        if isEditing {
            connectionListVM.updateProfile(profile, password: password, sshPassword: sshPass)
        } else {
            connectionListVM.addProfile(profile, password: password, sshPassword: sshPass)
        }
        dismiss()
    }

    private var existingId: UUID? {
        if case let .edit(profile) = mode { return profile.id }
        return nil
    }
}

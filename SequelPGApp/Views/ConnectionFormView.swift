import SwiftUI

/// Consolidates the 14 form fields the start page's connection editor works
/// with so loading, serialising, and defaulting a profile live in one place.
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
    var sslSkipVerification: Bool = false
    var sslRootCertPath: String = ""

    var useSSHTunnel: Bool = false
    var sshHost: String = ""
    var sshPort: String = "22"
    var sshUser: String = ""
    var sshAuthMethod: SSHAuthMethod = .keyFile
    var sshKeyPath: String = ""
    var sshPassword: String = ""

    var mcpAccess: MCPAccess = .off

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
        sslSkipVerification = profile.sslSkipVerification
        sslRootCertPath = profile.sslRootCertPath
        self.password = password

        useSSHTunnel = profile.useSSHTunnel
        sshHost = profile.sshHost
        sshPort = String(profile.sshPort)
        sshUser = profile.sshUser
        sshAuthMethod = profile.sshAuthMethod
        sshKeyPath = profile.sshKeyPath
        self.sshPassword = sshPassword
        mcpAccess = profile.mcpAccess
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
            sslSkipVerification: sslSkipVerification,
            sslRootCertPath: sslRootCertPath.trimmingCharacters(in: .whitespaces),
            useSSHTunnel: useSSHTunnel,
            sshHost: sshHost.trimmingCharacters(in: .whitespaces),
            sshPort: sshPortInt,
            sshUser: sshUser.trimmingCharacters(in: .whitespaces),
            sshAuthMethod: sshAuthMethod,
            sshKeyPath: sshKeyPath.trimmingCharacters(in: .whitespaces),
            mcpAccess: mcpAccess
        )
    }

    /// `sshPassword` wrapped as optional, honoring the tunnel toggle.
    var effectiveSSHPassword: String? { useSSHTunnel ? sshPassword : nil }
}

/// The connection settings form shared by the start page and the
/// Edit Connection sheet: server fields, SSL mode, and the SSH tunnel.
struct ConnectionSettingsForm: View {
    @Binding var form: ConnectionFormModel
    @State private var showPassword = false
    @State private var showSSHPassword = false

    private func chooseRootCertificate() {
        let panel = NSOpenPanel()
        panel.title = "Choose CA Certificate"
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.showsHiddenFiles = true
        if let url = FilePanels.chooseOpenURL(panel) {
            form.sslRootCertPath = (url.path as NSString).abbreviatingWithTildeInPath
        }
    }

    var body: some View {
        Form {
            Section {
                TextField("Name", text: $form.name)
                    .accessibilityIdentifier(A11yID.Form.name)
                TextField("Host", text: $form.host, prompt: Text("localhost"))
                    .accessibilityIdentifier(A11yID.Form.host)
                TextField("Port", text: $form.port, prompt: Text("5432"))
                    .accessibilityIdentifier(A11yID.Form.port)
                TextField("Database", text: $form.database)
                    .accessibilityIdentifier(A11yID.Form.database)
                TextField("Username", text: $form.username)
                    .accessibilityIdentifier(A11yID.Form.username)
                HStack {
                    if showPassword {
                        TextField("Password", text: $form.password)
                            .accessibilityIdentifier(A11yID.Form.password)
                    } else {
                        SecureField("Password", text: $form.password)
                            .accessibilityIdentifier(A11yID.Form.password)
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
                .accessibilityIdentifier(A11yID.Form.sslMode)
                .help("Prefer uses SSL when the server offers it; Require insists on it. "
                    + "Verify CA checks the certificate chain only; Verify Full also checks the host name.")
                if form.sslMode.verificationIsOptional {
                    Toggle("Don't verify server certificate", isOn: $form.sslSkipVerification)
                        .accessibilityIdentifier(A11yID.Form.sslSkipVerification)
                        .help("Encrypt without checking who the server is. Use for self-signed certificates "
                            + "you can't add as a CA file.")
                }
                if form.sslMode != .off, !(form.sslMode.verificationIsOptional && form.sslSkipVerification) {
                    HStack {
                        TextField("CA Certificate", text: $form.sslRootCertPath, prompt: Text("System trust store"))
                            .accessibilityIdentifier(A11yID.Form.sslRootCert)
                            .help("PEM file with the CA that signed the server certificate. "
                                + "Leave empty to trust the system's certificates.")
                        Button("Choose\u{2026}") { chooseRootCertificate() }
                            .accessibilityIdentifier(A11yID.Form.sslRootCertChoose)
                    }
                }
            } header: {
                Text("PostgreSQL Server")
            } footer: {
                VStack(alignment: .leading, spacing: 4) {
                    Text("postgresql://\(form.username)@\(form.host):\(form.port)/\(form.database)")
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                    if form.sslMode.verificationIsOptional, form.sslSkipVerification {
                        Text("Encrypted, but the server's identity isn't verified.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
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

            Section {
                Picker("MCP Access", selection: $form.mcpAccess) {
                    ForEach(MCPAccess.allCases, id: \.self) { access in
                        Text(access.displayName).tag(access)
                    }
                }
                .accessibilityIdentifier(A11yID.Form.mcpAccess)
            } header: {
                Text("AI Assistants")
            } footer: {
                Text(form.mcpAccess == .off
                    ? "AI assistants connected through MCP (Claude, Cursor…) can't see this connection."
                    : "AI assistants connected through MCP can browse the schema and run read-only queries. Query results are sent to the assistant's model provider. Turn the server on in Settings → MCP.")
            }
        }
        .formStyle(.grouped)
    }
}

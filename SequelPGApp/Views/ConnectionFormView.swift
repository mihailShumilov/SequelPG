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
    @State private var isTestingConnection = false
    @State private var testResult: TestConnectionResult?

    private enum TestConnectionResult: Equatable {
        case success
        case failure(String)
    }

    private var isEditing: Bool {
        if case .edit = mode { return true }
        return false
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(isEditing ? "ii. — edit" : "ii. — new")
                        .appSectionLabel()
                    Text(isEditing ? "Edit connection" : "New connection")
                        .appDisplay(24)
                }
                Spacer()
            }
            .padding(.horizontal, 22)
            .padding(.top, 22)
            .padding(.bottom, 12)

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
                        Text("ii. — connection")
                            .appSectionLabel()
                    }

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
                        Text("iii. — SSH tunnel")
                            .appSectionLabel()
                    }
                }
                .formStyle(.grouped)
                .scrollContentBackground(.hidden)
            }
            .background(Theme.bg)

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

            if let testResult {
                testResultBanner(testResult)
            }

            Rectangle().fill(Theme.line).frame(height: 1)

            HStack(spacing: 10) {
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .buttonStyle(.plain)
                    .foregroundStyle(Theme.ink3)
                Spacer()
                Button {
                    test()
                } label: {
                    Group {
                        if isTestingConnection {
                            ProgressView().controlSize(.small).frame(width: 32)
                        } else {
                            Text("Test").font(Theme.mono(size: 12, weight: .medium))
                        }
                    }
                    .foregroundStyle(Theme.ink)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 7)
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.line2, lineWidth: 1))
                }
                .buttonStyle(.plain)
                .disabled(isTestingConnection)

                Button {
                    save()
                } label: {
                    Text(isEditing ? "Save →" : "Add →")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Theme.onAccent)
                        .padding(.horizontal, 18)
                        .padding(.vertical, 7)
                        .background(Theme.accent)
                        .clipShape(.rect(cornerRadius: 6))
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.defaultAction)
                .disabled(isTestingConnection)
            }
            .padding(18)
            .background(Theme.bg)
        }
        .frame(width: 460)
        .frame(minHeight: 420, idealHeight: form.useSSHTunnel ? 620 : 460)
        .background(Theme.bg)
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
        }
    }

    private func test() {
        let profile = form.buildProfile(id: existingId ?? UUID(), fallbackPort: 0)
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

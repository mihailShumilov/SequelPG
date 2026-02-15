import SwiftUI

struct ConnectionFormView: View {
    enum Mode {
        case add
        case edit(ConnectionProfile)
    }

    let mode: Mode
    @EnvironmentObject var appVM: AppViewModel
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var host = ""
    @State private var port = "5432"
    @State private var database = ""
    @State private var username = ""
    @State private var password = ""
    @State private var sslMode: SSLMode = .prefer
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

            Form {
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
            }
            .padding()

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
        .frame(width: 400)
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
            password = appVM.connectionListVM.loadPasswordForProfile(profile)
        }
    }

    private func save() {
        let portInt = Int(port) ?? 0
        let profile = ConnectionProfile(
            id: existingId ?? UUID(),
            name: name.trimmingCharacters(in: .whitespaces),
            host: host.trimmingCharacters(in: .whitespaces),
            port: portInt,
            database: database.trimmingCharacters(in: .whitespaces),
            username: username.trimmingCharacters(in: .whitespaces),
            sslMode: sslMode
        )

        let errors = profile.validate()
        if !errors.isEmpty {
            validationErrors = errors
            return
        }

        if isEditing {
            appVM.connectionListVM.updateProfile(profile, password: password)
        } else {
            appVM.connectionListVM.addProfile(profile, password: password)
        }
        dismiss()
    }

    private var existingId: UUID? {
        if case let .edit(profile) = mode { return profile.id }
        return nil
    }
}

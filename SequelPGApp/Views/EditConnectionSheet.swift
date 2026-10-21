import SwiftUI

/// Edits the saved profile behind the window's live connection. Changes can be
/// saved for next time, or saved and applied by reconnecting the window.
struct EditConnectionSheet: View {
    let profileID: UUID

    @Environment(AppViewModel.self) private var appVM
    @Environment(ConnectionListViewModel.self) private var connectionListVM
    @Environment(\.dismiss) private var dismiss

    @State private var form = ConnectionFormModel()
    @State private var validationErrors: [String] = []

    private var savedProfile: ConnectionProfile? {
        connectionListVM.profiles.first { $0.id == profileID }
    }

    var body: some View {
        VStack(spacing: 0) {
            Text("Edit Connection")
                .font(.headline)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 20)
                .padding(.top, 18)

            if savedProfile != nil {
                ConnectionSettingsForm(form: $form)
            } else {
                ContentUnavailableView(
                    "Connection Deleted",
                    systemImage: "server.rack",
                    description: Text("This connection was removed from the saved connections.")
                )
            }

            if !validationErrors.isEmpty {
                InlineBanner(kind: .warning, message: validationErrors.joined(separator: "\n")) {
                    validationErrors = []
                }
            }

            Divider()

            SheetButtonBar(confirmTitle: "Save & Reconnect", confirmDisabled: savedProfile == nil) {
                dismiss()
            } onConfirm: {
                save(reconnect: true)
            } leading: {
                Button("Save") { save(reconnect: false) }
                    .disabled(savedProfile == nil)
                    .help("Save for next time without interrupting this session")
            }
        }
        .frame(width: 520, height: 520)
        .onAppear(perform: load)
    }

    private func load() {
        guard let profile = savedProfile else { return }
        form.load(
            from: profile,
            password: connectionListVM.loadPasswordForProfile(profile),
            sshPassword: connectionListVM.loadSSHPasswordForProfile(profile)
        )
    }

    private func save(reconnect: Bool) {
        let profile = form.buildProfile(id: profileID)
        let errors = profile.validate()
        guard errors.isEmpty else {
            validationErrors = errors
            return
        }
        connectionListVM.updateProfile(profile, password: form.password, sshPassword: form.effectiveSSHPassword)
        dismiss()

        if reconnect {
            let password: String? = form.password.isEmpty ? nil : form.password
            let sshPassword = form.effectiveSSHPassword
            Task { await appVM.reconnect(profile: profile, password: password, sshPassword: sshPassword) }
        } else {
            // The session keeps its settings until it reconnects; only the
            // window title follows a rename right away.
            appVM.connectedProfileName = profile.name
        }
    }
}

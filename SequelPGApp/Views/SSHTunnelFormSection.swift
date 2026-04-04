import SwiftUI

/// Reusable SSH tunnel form section used in both ConnectionFormView and StartPageView.
///
/// When `showSSHPassword` is `nil` the password field renders as a plain
/// `SecureField` (no visibility toggle). When it is a non-nil `Binding<Bool>` an
/// eye button is shown so the user can reveal the password.
struct SSHTunnelFormSection: View {
    @Binding var useSSHTunnel: Bool
    @Binding var sshHost: String
    @Binding var sshPort: String
    @Binding var sshUser: String
    @Binding var sshAuthMethod: SSHAuthMethod
    @Binding var sshKeyPath: String
    @Binding var sshPassword: String
    var showSSHPassword: Binding<Bool>?

    var body: some View {
        Toggle("Connect via SSH Tunnel", isOn: $useSSHTunnel.animation())

        if useSSHTunnel {
            TextField("SSH Host:", text: $sshHost)
            TextField("SSH Port:", text: $sshPort)
            TextField("SSH User:", text: $sshUser)
            Picker("Auth Method:", selection: $sshAuthMethod) {
                ForEach(SSHAuthMethod.allCases, id: \.self) { method in
                    Text(method.displayName).tag(method)
                }
            }

            if sshAuthMethod == .keyFile {
                TextField("Key Path:", text: $sshKeyPath)
                    .help("Path to SSH private key (e.g. ~/.ssh/id_rsa). Leave empty to use SSH agent.")
            }

            if sshAuthMethod == .password {
                if let showBinding = showSSHPassword {
                    HStack {
                        if showBinding.wrappedValue {
                            TextField("SSH Password:", text: $sshPassword)
                        } else {
                            SecureField("SSH Password:", text: $sshPassword)
                        }
                        Button {
                            showBinding.wrappedValue.toggle()
                        } label: {
                            Image(systemName: showBinding.wrappedValue ? "eye.slash" : "eye")
                        }
                        .buttonStyle(.borderless)
                    }
                } else {
                    SecureField("SSH Password:", text: $sshPassword)
                }
            }
        }
    }
}

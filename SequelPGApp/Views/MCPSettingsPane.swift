import AppKit
import SwiftUI

/// Settings → MCP: the server switch and status, the connections AI clients
/// can see, and the clients the user approved.
struct MCPSettingsPane: View {
    @Environment(MCPServerController.self) private var controller
    @Environment(ConnectionListViewModel.self) private var connectionListVM
    @State private var installMessage: (text: String, isError: Bool)?
    @State private var installing: MCPClientInstaller.Client?

    private var sharedProfiles: [ConnectionProfile] {
        connectionListVM.profiles.filter { $0.mcpAccess != .off }
    }

    var body: some View {
        @Bindable var controller = controller
        Form {
            Section {
                Toggle("Enable MCP server", isOn: $controller.isEnabled)
                    .accessibilityIdentifier(A11yID.Settings.mcpEnabled)
                LabeledContent("Status") {
                    // Client count isn't observable (it changes on socket
                    // threads), so refresh it periodically.
                    TimelineView(.periodic(from: .now, by: 2)) { _ in
                        statusLabel
                    }
                }
            } header: {
                Text("Server")
            } footer: {
                Text(
                    "Lets AI assistants that support the Model Context Protocol — Claude Code, Claude Desktop, Cursor and others — browse schemas and run read-only queries on the connections you share. Passwords never leave SequelPG. A read-only transaction doesn't stop functions with side effects, so share connections that use a role with only the privileges the assistant needs. Superuser roles are refused unless a connection allows them."
                )
            }

            Section {
                ForEach(MCPClientInstaller.Client.allCases) { client in
                    LabeledContent(client.displayName) {
                        Button(installing == client ? "Adding…" : "Add") { install(client) }
                            .disabled(installing != nil)
                            .accessibilityIdentifier(A11yID.Settings.mcpInstall(client.rawValue))
                    }
                }
                HStack {
                    Button("Copy JSON Config") { copy(MCPClientInstaller.jsonSnippet) }
                    Button("Copy Claude Code Command") { copy(MCPClientInstaller.claudeCodeCommand) }
                }
                if let installMessage {
                    Text(installMessage.text)
                        .font(.caption)
                        .foregroundStyle(installMessage.isError ? Color.red : Color.secondary)
                        .textSelection(.enabled)
                }
                if MCPClientInstaller.isTranslocated {
                    Label(
                        "Move SequelPG to the Applications folder first: macOS is running it from a temporary location.",
                        systemImage: "exclamationmark.triangle.fill"
                    )
                    .font(.caption)
                    .foregroundStyle(.orange)
                }
            } header: {
                Text("Connect a Client")
            } footer: {
                Text(
                    "Clients start \(MCPClientInstaller.bridgeExecutable) \(MCPStdioBridge.argument), which opens SequelPG in the background when it isn't running."
                )
                .textSelection(.enabled)
            }

            Section {
                if sharedProfiles.isEmpty {
                    Text("No connections are shared. Edit a connection and set MCP Access to Read-only.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(sharedProfiles) { profile in
                        LabeledContent(profile.displayName, value: profile.mcpAccess.displayName)
                    }
                }
            } header: {
                Text("Shared Connections")
            }

            Section {
                if controller.approvedClients.isEmpty {
                    Text("SequelPG asks before a client uses your connections for the first time.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(controller.approvedClients, id: \.self) { name in
                        LabeledContent(name) {
                            Button("Revoke") { controller.revoke(name) }
                        }
                    }
                }
            } header: {
                Text("Allowed Clients")
            }
        }
        .formStyle(.grouped)
        .frame(height: 560)
    }

    private func install(_ client: MCPClientInstaller.Client) {
        installing = client
        installMessage = nil
        Task {
            let result = await Task.detached { () -> Result<String, Error> in
                Result { try MCPClientInstaller.install(client) }
            }.value
            installing = nil
            switch result {
            case let .success(message): installMessage = (message, false)
            case let .failure(error): installMessage = (error.localizedDescription, true)
            }
        }
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        installMessage = ("Copied to the clipboard.", false)
    }

    @ViewBuilder
    private var statusLabel: some View {
        switch controller.status {
        case .running:
            let count = controller.connectedClientCount
            Label(
                count == 0 ? "Running" : "Running · \(count) client\(count == 1 ? "" : "s") connected",
                systemImage: "circle.fill"
            )
            .foregroundStyle(.green)
        case .stopped:
            Label("Off", systemImage: "circle")
                .foregroundStyle(.secondary)
        case let .failed(message):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
                .lineLimit(2)
        }
    }
}

import SwiftUI

/// Settings → MCP: the server switch and status, the connections AI clients
/// can see, and the clients the user approved.
struct MCPSettingsPane: View {
    @Environment(MCPServerController.self) private var controller
    @Environment(ConnectionListViewModel.self) private var connectionListVM

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
                Text("Lets AI assistants that support the Model Context Protocol — Claude Code, Claude Desktop, Cursor and others — browse schemas and run read-only queries on the connections you share. Passwords never leave SequelPG.")
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
        .frame(height: 460)
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

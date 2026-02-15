import SwiftUI

struct ConnectionListView: View {
    @EnvironmentObject var appVM: AppViewModel

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Connections")
                    .font(.headline)
                Spacer()
                Button {
                    appVM.connectionListVM.showAddForm = true
                } label: {
                    Image(systemName: "plus")
                }
                .buttonStyle(.borderless)
                .help("Add Connection")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            List(appVM.connectionListVM.profiles) { profile in
                HStack {
                    Circle()
                        .fill(statusColor(for: profile.id))
                        .frame(width: 8, height: 8)

                    Text(profile.name)
                        .lineLimit(1)

                    Spacer()
                }
                .contentShape(Rectangle())
                .onTapGesture(count: 2) {
                    Task { await appVM.connect(profile: profile) }
                }
                .contextMenu {
                    Button("Connect") {
                        Task { await appVM.connect(profile: profile) }
                    }
                    if appVM.isConnected {
                        Button("Disconnect") {
                            Task { await appVM.disconnect() }
                        }
                    }
                    Divider()
                    Button("Edit") {
                        appVM.connectionListVM.editingProfile = profile
                    }
                    Button("Delete", role: .destructive) {
                        appVM.connectionListVM.deleteTarget = profile
                    }
                }
            }
            .listStyle(.sidebar)
        }
        .sheet(isPresented: $appVM.connectionListVM.showAddForm) {
            ConnectionFormView(mode: .add)
                .environmentObject(appVM)
        }
        .sheet(item: $appVM.connectionListVM.editingProfile) { profile in
            ConnectionFormView(mode: .edit(profile))
                .environmentObject(appVM)
        }
        .alert("Delete Connection?", isPresented: .init(
            get: { appVM.connectionListVM.deleteTarget != nil },
            set: { if !$0 { appVM.connectionListVM.deleteTarget = nil } }
        )) {
            Button("Cancel", role: .cancel) {}
            Button("Delete", role: .destructive) {
                if let target = appVM.connectionListVM.deleteTarget {
                    appVM.connectionListVM.deleteProfile(target)
                }
            }
        } message: {
            Text("Are you sure you want to delete \"\(appVM.connectionListVM.deleteTarget?.name ?? "")\"?")
        }
    }

    private func statusColor(for profileId: UUID) -> Color {
        switch appVM.connectionListVM.connectionStatuses[profileId] {
        case .connected: return .green
        case .error: return .red
        default: return .gray
        }
    }
}

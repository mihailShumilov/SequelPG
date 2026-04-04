import SwiftUI

struct ConnectionListView: View {
    @Environment(AppViewModel.self) var appVM
    @Environment(ConnectionListViewModel.self) var connectionListVM

    var body: some View {
        @Bindable var connectionListVM = connectionListVM
        VStack(spacing: 0) {
            HStack {
                Text("Connections")
                    .font(.headline)
                Spacer()
                Button {
                    connectionListVM.showAddForm = true
                } label: {
                    Image(systemName: "plus")
                }
                .buttonStyle(.borderless)
                .help("Add Connection")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            List(connectionListVM.profiles) { profile in
                HStack {
                    Circle()
                        .fill(statusColor(for: profile.id))
                        .frame(width: 8, height: 8)

                    Text(profile.name)
                        .lineLimit(1)

                    Spacer()
                }
                .contentShape(Rectangle())
                .onTapGesture {
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
                        connectionListVM.editingProfile = profile
                    }
                    Button("Delete", role: .destructive) {
                        connectionListVM.deleteTarget = profile
                    }
                }
            }
            .listStyle(.sidebar)
        }
        .sheet(isPresented: $connectionListVM.showAddForm) {
            ConnectionFormView(mode: .add)
                .environment(appVM)
                .environment(connectionListVM)
        }
        .sheet(item: $connectionListVM.editingProfile) { profile in
            ConnectionFormView(mode: .edit(profile))
                .environment(appVM)
                .environment(connectionListVM)
        }
        .alert("Delete Connection?", isPresented: .init(
            get: { connectionListVM.deleteTarget != nil },
            set: { if !$0 { connectionListVM.deleteTarget = nil } }
        )) {
            Button("Cancel", role: .cancel) {}
            Button("Delete", role: .destructive) {
                if let target = connectionListVM.deleteTarget {
                    connectionListVM.deleteProfile(target)
                }
            }
        } message: {
            Text("Are you sure you want to delete \"\(connectionListVM.deleteTarget?.name ?? "")\"?")
        }
    }

    private func statusColor(for profileId: UUID) -> Color {
        connectionListVM.statusColor(for: profileId)
    }
}

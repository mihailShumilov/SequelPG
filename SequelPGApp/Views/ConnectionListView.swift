import SwiftUI

/// Connection list view used on the start page sidebar.
/// Not shown in the connected view's sidebar.
struct ConnectionListView: View {
    @Environment(ConnectionListViewModel.self) var connectionListVM

    var body: some View {
        @Bindable var connectionListVM = connectionListVM
        VStack(spacing: 0) {
            HStack {
                Text("Connections")
                    .appSectionLabel()
                Spacer()
                Button {
                    connectionListVM.showAddForm = true
                } label: {
                    Image(systemName: "plus")
                        .foregroundStyle(Theme.ink3)
                }
                .buttonStyle(.plain)
                .help("Add Connection")
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(Theme.bg2)
            .overlay(alignment: .bottom) {
                Rectangle().fill(Theme.line).frame(height: 1)
            }

            List(connectionListVM.profiles) { profile in
                HStack(spacing: 8) {
                    Image(systemName: profile.useSSHTunnel ? "lock.shield.fill" : "server.rack")
                        .foregroundStyle(Theme.ink3)
                        .font(.system(size: 11))
                    Text(profile.name)
                        .font(.system(size: 12.5))
                        .lineLimit(1)
                    Spacer()
                }
                .contentShape(Rectangle())
                .contextMenu {
                    Button("Edit") {
                        connectionListVM.editingProfile = profile
                    }
                    Button("Delete", role: .destructive) {
                        connectionListVM.deleteTarget = profile
                    }
                }
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)
            .background(Theme.bg)
        }
        .background(Theme.bg2)
        .sheet(isPresented: $connectionListVM.showAddForm) {
            ConnectionFormView(mode: .add)
                .environment(connectionListVM)
        }
        .sheet(item: $connectionListVM.editingProfile) { profile in
            ConnectionFormView(mode: .edit(profile))
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
}

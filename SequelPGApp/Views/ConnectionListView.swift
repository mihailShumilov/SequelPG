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
                    Text(profile.name)
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
        }
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

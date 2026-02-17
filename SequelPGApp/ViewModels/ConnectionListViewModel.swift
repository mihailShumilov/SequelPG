import Foundation

/// Connection status for display in the sidebar.
enum ConnectionStatus {
    case disconnected
    case connected
    case error
}

/// Manages the list of saved connections and their UI state.
@MainActor
final class ConnectionListViewModel: ObservableObject {
    private let store: ConnectionStore
    private let keychainService: KeychainServiceProtocol

    @Published var profiles: [ConnectionProfile] = []
    @Published var connectionStatuses: [UUID: ConnectionStatus] = [:]
    @Published var showAddForm = false
    @Published var editingProfile: ConnectionProfile?
    @Published var deleteTarget: ConnectionProfile?
    @Published var selectedProfileId: UUID?
    @Published var filterText: String = ""

    var filteredProfiles: [ConnectionProfile] {
        if filterText.isEmpty { return profiles }
        return profiles.filter { $0.name.localizedCaseInsensitiveContains(filterText) }
    }

    var selectedProfile: ConnectionProfile? {
        profiles.first { $0.id == selectedProfileId }
    }

    init(store: ConnectionStore, keychainService: KeychainServiceProtocol) {
        self.store = store
        self.keychainService = keychainService
        self.profiles = store.loadAll()
        self.selectedProfileId = profiles.first?.id
    }

    func reload() {
        profiles = store.loadAll()
        if selectedProfileId == nil || !profiles.contains(where: { $0.id == selectedProfileId }) {
            selectedProfileId = profiles.first?.id
        }
    }

    func addProfile(_ profile: ConnectionProfile, password: String?) {
        store.add(profile)
        if let password, !password.isEmpty {
            try? keychainService.save(password: password, forKey: profile.keychainKey)
        }
        reload()
        selectedProfileId = profile.id
    }

    func updateProfile(_ profile: ConnectionProfile, password: String?) {
        store.update(profile)
        if let password, !password.isEmpty {
            try? keychainService.save(password: password, forKey: profile.keychainKey)
        } else if password?.isEmpty == true {
            try? keychainService.delete(forKey: profile.keychainKey)
        }
        reload()
    }

    func deleteProfile(_ profile: ConnectionProfile) {
        if selectedProfileId == profile.id {
            selectedProfileId = nil
        }
        store.delete(id: profile.id)
        try? keychainService.delete(forKey: profile.keychainKey)
        connectionStatuses.removeValue(forKey: profile.id)
        reload()
    }

    func loadPasswordForProfile(_ profile: ConnectionProfile) -> String {
        (try? keychainService.load(forKey: profile.keychainKey)) ?? ""
    }

    func setConnected(profileId: UUID) {
        for key in connectionStatuses.keys {
            connectionStatuses[key] = .disconnected
        }
        connectionStatuses[profileId] = .connected
    }

    func setError(profileId: UUID) {
        connectionStatuses[profileId] = .error
    }

    func clearConnectionState() {
        connectionStatuses.removeAll()
    }

    func statusColor(for profileId: UUID) -> String {
        switch connectionStatuses[profileId] {
        case .connected: return "green"
        case .error: return "red"
        default: return "gray"
        }
    }
}

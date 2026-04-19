import Foundation
import OSLog
import SwiftUI

/// Connection status for display in the sidebar.
enum ConnectionStatus {
    case disconnected
    case connected
    case error
}

/// Manages the list of saved connections and their UI state.
@MainActor
@Observable final class ConnectionListViewModel {
    @ObservationIgnored private let store: ConnectionStore
    @ObservationIgnored private let keychainService: KeychainServiceProtocol

    /// In-memory password cache to avoid repeated Keychain reads.
    /// Populated lazily on first access per profile; written through on save.
    @ObservationIgnored private var passwordCache: [String: String] = [:]

    var profiles: [ConnectionProfile] = []
    var connectionStatuses: [UUID: ConnectionStatus] = [:]
    var showAddForm = false
    var editingProfile: ConnectionProfile?
    var deleteTarget: ConnectionProfile?
    var selectedProfileId: UUID?
    var filterText: String = ""

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

    func addProfile(_ profile: ConnectionProfile, password: String?, sshPassword: String? = nil) {
        store.add(profile)
        syncKeychain(key: profile.keychainKey, password: password, label: "password")
        syncKeychain(key: profile.sshKeychainKey, password: sshPassword, label: "SSH password")
        reload()
        selectedProfileId = profile.id
    }

    func updateProfile(_ profile: ConnectionProfile, password: String?, sshPassword: String? = nil) {
        store.update(profile)
        syncKeychain(key: profile.keychainKey, password: password, label: "password")
        syncKeychain(key: profile.sshKeychainKey, password: sshPassword, label: "SSH password")
        reload()
    }

    func deleteProfile(_ profile: ConnectionProfile) {
        if selectedProfileId == profile.id {
            selectedProfileId = nil
        }
        store.delete(id: profile.id)
        // Pass empty string to force delete path regardless of prior state.
        syncKeychain(key: profile.keychainKey, password: "", label: "password")
        syncKeychain(key: profile.sshKeychainKey, password: "", label: "SSH password")
        connectionStatuses.removeValue(forKey: profile.id)
        reload()
    }

    /// Keeps Keychain and in-memory cache consistent with the user's intent:
    /// * nil → leave alone (caller didn't touch the field)
    /// * empty → delete the entry (caller cleared the field)
    /// * non-empty → write through
    private func syncKeychain(key: String, password: String?, label: String) {
        guard let password else { return }
        if password.isEmpty {
            do {
                try keychainService.delete(forKey: key)
            } catch {
                Log.app.error("Failed to delete \(label) from Keychain: \(error.localizedDescription)")
            }
            passwordCache.removeValue(forKey: key)
        } else {
            do {
                try keychainService.save(password: password, forKey: key)
            } catch {
                Log.app.error("Failed to save \(label) to Keychain: \(error.localizedDescription)")
            }
            passwordCache[key] = password
        }
    }

    func loadPasswordForProfile(_ profile: ConnectionProfile) -> String {
        loadCachedPassword(forKey: profile.keychainKey)
    }

    func loadSSHPasswordForProfile(_ profile: ConnectionProfile) -> String {
        loadCachedPassword(forKey: profile.sshKeychainKey)
    }

    private func loadCachedPassword(forKey key: String) -> String {
        if let cached = passwordCache[key] {
            return cached
        }
        let password = (try? keychainService.load(forKey: key)) ?? ""
        passwordCache[key] = password
        return password
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
        passwordCache.removeAll()
    }

    func statusColor(for profileId: UUID) -> Color {
        switch connectionStatuses[profileId] {
        case .connected: return .green
        case .error: return .red
        default: return .gray
        }
    }
}

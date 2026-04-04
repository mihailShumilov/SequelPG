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
        if let password, !password.isEmpty {
            do {
                try keychainService.save(password: password, forKey: profile.keychainKey)
            } catch {
                Log.app.error("Failed to save password to Keychain: \(error.localizedDescription)")
            }
            passwordCache[profile.keychainKey] = password
        }
        if let sshPassword, !sshPassword.isEmpty {
            do {
                try keychainService.save(password: sshPassword, forKey: profile.sshKeychainKey)
            } catch {
                Log.app.error("Failed to save SSH password to Keychain: \(error.localizedDescription)")
            }
            passwordCache[profile.sshKeychainKey] = sshPassword
        }
        reload()
        selectedProfileId = profile.id
    }

    func updateProfile(_ profile: ConnectionProfile, password: String?, sshPassword: String? = nil) {
        store.update(profile)
        if let password, !password.isEmpty {
            do {
                try keychainService.save(password: password, forKey: profile.keychainKey)
            } catch {
                Log.app.error("Failed to save password to Keychain: \(error.localizedDescription)")
            }
            passwordCache[profile.keychainKey] = password
        } else if password?.isEmpty == true {
            do {
                try keychainService.delete(forKey: profile.keychainKey)
            } catch {
                Log.app.error("Failed to delete password from Keychain: \(error.localizedDescription)")
            }
            passwordCache.removeValue(forKey: profile.keychainKey)
        }
        if let sshPassword, !sshPassword.isEmpty {
            do {
                try keychainService.save(password: sshPassword, forKey: profile.sshKeychainKey)
            } catch {
                Log.app.error("Failed to save SSH password to Keychain: \(error.localizedDescription)")
            }
            passwordCache[profile.sshKeychainKey] = sshPassword
        } else if sshPassword?.isEmpty == true {
            do {
                try keychainService.delete(forKey: profile.sshKeychainKey)
            } catch {
                Log.app.error("Failed to delete SSH password from Keychain: \(error.localizedDescription)")
            }
            passwordCache.removeValue(forKey: profile.sshKeychainKey)
        }
        reload()
    }

    func deleteProfile(_ profile: ConnectionProfile) {
        if selectedProfileId == profile.id {
            selectedProfileId = nil
        }
        store.delete(id: profile.id)
        do {
            try keychainService.delete(forKey: profile.keychainKey)
        } catch {
            Log.app.error("Failed to delete password from Keychain: \(error.localizedDescription)")
        }
        do {
            try keychainService.delete(forKey: profile.sshKeychainKey)
        } catch {
            Log.app.error("Failed to delete SSH password from Keychain: \(error.localizedDescription)")
        }
        passwordCache.removeValue(forKey: profile.keychainKey)
        passwordCache.removeValue(forKey: profile.sshKeychainKey)
        connectionStatuses.removeValue(forKey: profile.id)
        reload()
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

import Foundation
import OSLog

/// Protocol for connection profile persistence, enabling test mocking.
protocol ConnectionStoreProtocol: Sendable {
    func loadAll() -> [ConnectionProfile]
    func save(_ profiles: [ConnectionProfile])
    func add(_ profile: ConnectionProfile)
    func update(_ profile: ConnectionProfile)
    func delete(id: UUID)
}

/// Persists connection profiles to UserDefaults (without passwords).
final class ConnectionStore: ConnectionStoreProtocol, Sendable {
    private let defaults: UserDefaults
    private let key = "com.sequelpg.connections"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func loadAll() -> [ConnectionProfile] {
        guard let data = defaults.data(forKey: key) else {
            return []
        }
        do {
            return try JSONDecoder().decode([ConnectionProfile].self, from: data)
        } catch {
            Log.app.error("Failed to decode connections: \(error.localizedDescription)")
            return []
        }
    }

    func save(_ profiles: [ConnectionProfile]) {
        do {
            let data = try JSONEncoder().encode(profiles)
            defaults.set(data, forKey: key)
        } catch {
            Log.app.error("Failed to encode connections: \(error.localizedDescription)")
        }
    }

    func add(_ profile: ConnectionProfile) {
        var profiles = loadAll()
        profiles.append(profile)
        save(profiles)
    }

    func update(_ profile: ConnectionProfile) {
        var profiles = loadAll()
        if let index = profiles.firstIndex(where: { $0.id == profile.id }) {
            profiles[index] = profile
            save(profiles)
        }
    }

    func delete(id: UUID) {
        var profiles = loadAll()
        profiles.removeAll { $0.id == id }
        save(profiles)
    }
}

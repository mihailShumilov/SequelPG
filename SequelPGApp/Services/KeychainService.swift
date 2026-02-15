import Foundation
import Security

/// Protocol for Keychain operations, enabling test mocking.
protocol KeychainServiceProtocol: Sendable {
    func save(password: String, forKey key: String) throws
    func load(forKey key: String) throws -> String?
    func delete(forKey key: String) throws
}

/// Stores and retrieves passwords from the macOS Keychain.
final class KeychainService: KeychainServiceProtocol, Sendable {
    static let shared = KeychainService()

    func save(password: String, forKey key: String) throws {
        // Delete any existing item first
        try? delete(forKey: key)

        guard let data = password.data(using: .utf8) else {
            throw AppError.keychainError("Failed to encode password.")
        }

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "com.sequelpg.app",
            kSecAttrAccount as String: key,
            kSecValueData as String: data,
        ]

        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw AppError.keychainError("Failed to save password (OSStatus: \(status)).")
        }
    }

    func load(forKey key: String) throws -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "com.sequelpg.app",
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        if status == errSecItemNotFound {
            return nil
        }

        guard status == errSecSuccess, let data = result as? Data else {
            throw AppError.keychainError("Failed to load password (OSStatus: \(status)).")
        }

        return String(data: data, encoding: .utf8)
    }

    func delete(forKey key: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "com.sequelpg.app",
            kSecAttrAccount as String: key,
        ]

        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw AppError.keychainError("Failed to delete password (OSStatus: \(status)).")
        }
    }
}

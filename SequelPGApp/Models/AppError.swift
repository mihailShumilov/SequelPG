import Foundation

/// Application-level error with user-friendly messages.
enum AppError: LocalizedError, Sendable {
    case connectionFailed(String)
    case queryFailed(String)
    case queryTimeout
    case validationFailed([String])
    case keychainError(String)
    case notConnected
    case foreignKeyViolation(String)
    case underlying(String)

    var errorDescription: String? {
        switch self {
        case let .connectionFailed(message):
            return "Connection failed: \(message)"
        case let .queryFailed(message):
            return "Query failed: \(message)"
        case .queryTimeout:
            return "Query timed out after the configured timeout period."
        case let .validationFailed(errors):
            return errors.joined(separator: "\n")
        case let .keychainError(message):
            return "Keychain error: \(message)"
        case .notConnected:
            return "Not connected to a database."
        case let .foreignKeyViolation(message):
            return "Foreign key violation: \(message)"
        case let .underlying(message):
            return message
        }
    }

    var userMessage: String {
        errorDescription ?? "An unknown error occurred."
    }
}

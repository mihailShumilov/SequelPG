import Foundation

/// Why a connection attempt failed, reduced from the PostgresNIO error so the
/// message (and the SSL Mode hint) can be chosen without the driver types.
enum ConnectionFailure: Equatable, Sendable {
    /// The server answered the SSL request with "no" (`ssl = off`).
    case sslUnsupported
    /// The TLS handshake failed because the server's certificate (or its
    /// host name) did not verify.
    case certificateRejected(String)
    /// The TLS handshake failed for another reason.
    case tlsHandshakeFailed(String)
    /// The server rejected the session (authentication, pg_hba.conf, unknown
    /// database, …) with an error message and SQLSTATE.
    case server(message: String, sqlState: String?)
    /// Nothing accepted the TCP connection.
    case unreachable(String)
    case other(String)

    /// True when retrying the same server without SSL may succeed — the
    /// fallback libpq's `sslmode=prefer` performs.
    var allowsPlaintextRetry: Bool {
        switch self {
        case .certificateRejected, .tlsHandshakeFailed:
            return true
        case let .server(message, sqlState):
            // pg_hba.conf has only `hostnossl` lines for this client.
            return sqlState == "28000" && message.contains("SSL encryption")
        case .sslUnsupported, .unreachable, .other:
            return false
        }
    }

    /// A user-facing explanation with a hint about which setting to change.
    /// `endpoint` is the host and port as the user entered them.
    func message(sslMode: SSLMode, endpoint: String) -> String {
        switch self {
        case .sslUnsupported:
            return "The server at \(endpoint) does not accept SSL connections. "
                + "Set SSL Mode to Prefer or Off."
        case let .certificateRejected(detail):
            return "The server's SSL certificate could not be verified (\(detail)). "
                + "If the server uses a self-signed certificate, set SSL Mode to Require "
                + "to encrypt the connection without verifying the certificate."
        case let .tlsHandshakeFailed(detail):
            return "The SSL handshake with \(endpoint) failed (\(detail))."
                + (sslMode == .off || sslMode == .prefer ? "" : " Try SSL Mode Prefer or Off.")
        case let .server(message, sqlState):
            return message + Self.serverHint(message: message, sqlState: sqlState, sslMode: sslMode)
        case let .unreachable(detail):
            return "Could not reach \(endpoint) (\(detail)). "
                + "Check that PostgreSQL is running and listening on this host and port."
        case let .other(detail):
            return detail
        }
    }

    private static func serverHint(message: String, sqlState: String?, sslMode: SSLMode) -> String {
        // pg_hba.conf rejections end in ", no encryption" or ", SSL encryption"
        // (or "GSS encryption"), naming how this attempt was made.
        guard sqlState == "28000", message.contains("pg_hba.conf") else { return "" }
        if message.hasSuffix("no encryption"), sslMode == .off || sslMode == .prefer {
            return "\nThe server only accepts SSL connections from this host. Set SSL Mode to Require."
        }
        if message.hasSuffix("SSL encryption"), sslMode != .off, sslMode != .prefer {
            return "\nThe server only accepts unencrypted connections from this host. Set SSL Mode to Prefer or Off."
        }
        return ""
    }
}

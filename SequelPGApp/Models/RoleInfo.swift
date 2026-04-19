import Foundation

/// A PostgreSQL role. Source: `pg_catalog.pg_roles`.
struct RoleInfo: Identifiable, Sendable, Equatable, Hashable {
    var id: String { name }
    let name: String
    let isSuperuser: Bool
    let canLogin: Bool
    let canCreateDB: Bool
    let canCreateRole: Bool
    let isReplication: Bool
    /// Roles this role is a member of (pg_auth_members).
    let memberOf: [String]
    let validUntil: String?
}

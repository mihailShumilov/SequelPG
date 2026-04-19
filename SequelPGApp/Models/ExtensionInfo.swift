import Foundation

/// A PostgreSQL extension. For installed extensions the row comes from
/// `pg_catalog.pg_extension`; for available ones, `pg_available_extensions`.
struct ExtensionInfo: Identifiable, Sendable, Equatable, Hashable {
    var id: String { name }
    let name: String
    let schema: String?
    let installedVersion: String?
    let defaultVersion: String?
    let comment: String?

    var isInstalled: Bool { installedVersion != nil }
}

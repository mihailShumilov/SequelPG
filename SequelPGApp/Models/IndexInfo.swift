import Foundation

/// Metadata for a PostgreSQL index on a single table.
/// Source: `pg_catalog.pg_index` + `pg_catalog.pg_class`.
struct IndexInfo: Identifiable, Sendable, Equatable, Hashable {
    /// Stable id: schema.table.indexName — unique within a database.
    let id: String
    let schema: String
    let table: String
    let name: String
    /// Column names (or expression fragments) in index-key order.
    let columns: [String]
    let isUnique: Bool
    let isPrimary: Bool
    /// Access method: btree, gin, gist, hash, brin, spgist, etc.
    let method: String
    /// True when this is a partial index (`WHERE …` predicate present).
    let isPartial: Bool

    init(
        schema: String,
        table: String,
        name: String,
        columns: [String],
        isUnique: Bool,
        isPrimary: Bool,
        method: String,
        isPartial: Bool
    ) {
        self.id = "\(schema).\(table).\(name)"
        self.schema = schema
        self.table = table
        self.name = name
        self.columns = columns
        self.isUnique = isUnique
        self.isPrimary = isPrimary
        self.method = method
        self.isPartial = isPartial
    }
}

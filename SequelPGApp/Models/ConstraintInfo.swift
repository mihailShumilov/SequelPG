import Foundation

/// A constraint attached to a table. Source: `pg_catalog.pg_constraint`.
struct ConstraintInfo: Identifiable, Sendable, Equatable, Hashable {
    enum Kind: String, Sendable {
        case primaryKey = "PRIMARY KEY"
        case foreignKey = "FOREIGN KEY"
        case unique = "UNIQUE"
        case check = "CHECK"
        case exclude = "EXCLUDE"
    }

    let id: String
    let schema: String
    let table: String
    let name: String
    let kind: Kind
    /// Full constraint definition as rendered by `pg_get_constraintdef`.
    /// Used for display and in DROP statements we construct.
    let definition: String
    /// Columns involved on this side of the constraint.
    let columns: [String]
    /// Referenced table+columns for foreign keys, nil otherwise.
    let referencedTable: String?
    let referencedColumns: [String]

    init(
        schema: String,
        table: String,
        name: String,
        kind: Kind,
        definition: String,
        columns: [String],
        referencedTable: String? = nil,
        referencedColumns: [String] = []
    ) {
        self.id = "\(schema).\(table).\(name)"
        self.schema = schema
        self.table = table
        self.name = name
        self.kind = kind
        self.definition = definition
        self.columns = columns
        self.referencedTable = referencedTable
        self.referencedColumns = referencedColumns
    }
}

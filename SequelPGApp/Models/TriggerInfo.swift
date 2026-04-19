import Foundation

/// A trigger bound to a table. Source: `pg_catalog.pg_trigger` + `information_schema.triggers`.
struct TriggerInfo: Identifiable, Sendable, Equatable, Hashable {
    let id: String
    let schema: String
    let table: String
    let name: String
    /// BEFORE / AFTER / INSTEAD OF
    let timing: String
    /// Event keywords: INSERT / UPDATE / DELETE / TRUNCATE (may combine with `OR`).
    let event: String
    /// The function the trigger fires, formatted as schema.name.
    let actionStatement: String
    /// True when `pg_trigger.tgenabled = 'D'`.
    let isDisabled: Bool

    init(
        schema: String,
        table: String,
        name: String,
        timing: String,
        event: String,
        actionStatement: String,
        isDisabled: Bool
    ) {
        self.id = "\(schema).\(table).\(name)"
        self.schema = schema
        self.table = table
        self.name = name
        self.timing = timing
        self.event = event
        self.actionStatement = actionStatement
        self.isDisabled = isDisabled
    }
}

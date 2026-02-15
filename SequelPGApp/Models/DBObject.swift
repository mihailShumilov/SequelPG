import Foundation

/// Type of database object in the navigator.
enum DBObjectType: String, Sendable {
    case table
    case view
}

/// A database object (table or view) in the navigator tree.
struct DBObject: Identifiable, Sendable, Equatable {
    let id: String
    let schema: String
    let name: String
    let type: DBObjectType

    init(schema: String, name: String, type: DBObjectType) {
        self.id = "\(schema).\(name)"
        self.schema = schema
        self.name = name
        self.type = type
    }
}

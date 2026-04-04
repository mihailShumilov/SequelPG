import Foundation

/// Type of database object in the navigator.
enum DBObjectType: String, Sendable {
    case table
    case view
    case materializedView
    case function
    case sequence
    case type
    case aggregate
    case collation
    case domain
    case ftsConfiguration
    case ftsDictionary
    case ftsParser
    case ftsTemplate
    case foreignTable
    case `operator`
    case procedure
    case triggerFunction
}

/// A database object in the navigator tree.
struct DBObject: Identifiable, Sendable, Equatable, Hashable {
    let id: String
    let schema: String
    let name: String
    let type: DBObjectType

    init(schema: String, name: String, type: DBObjectType) {
        self.id = "\(schema)\0\(name)\0\(type.rawValue)"
        self.schema = schema
        self.name = name
        self.type = type
    }
}

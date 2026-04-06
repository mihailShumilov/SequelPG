import Foundation

/// Object category keys used for tree expansion and grouping.
/// Order matches pgAdmin convention.
enum ObjectCategory: String, CaseIterable, Identifiable {
    var id: String { rawValue }
    case aggregates = "Aggregates"
    case collations = "Collations"
    case domains = "Domains"
    case ftsConfigurations = "FTS Configurations"
    case ftsDictionaries = "FTS Dictionaries"
    case ftsParsers = "FTS Parsers"
    case ftsTemplates = "FTS Templates"
    case foreignTables = "Foreign Tables"
    case functions = "Functions"
    case materializedViews = "Materialized Views"
    case operators = "Operators"
    case procedures = "Procedures"
    case sequences = "Sequences"
    case tables = "Tables"
    case triggerFunctions = "Trigger Functions"
    case types = "Types"
    case views = "Views"

    var icon: String {
        switch self {
        case .aggregates: return "sum"
        case .collations: return "textformat.abc"
        case .domains: return "shield"
        case .ftsConfigurations: return "doc.text.magnifyingglass"
        case .ftsDictionaries: return "character.book.closed"
        case .ftsParsers: return "text.viewfinder"
        case .ftsTemplates: return "doc.on.doc"
        case .foreignTables: return "externaldrive"
        case .functions: return "function"
        case .materializedViews: return "square.stack.3d.up"
        case .operators: return "plus.forwardslash.minus"
        case .procedures: return "gearshape"
        case .sequences: return "number"
        case .tables: return "tablecells"
        case .triggerFunctions: return "bolt"
        case .types: return "t.square"
        case .views: return "eye"
        }
    }

}

/// Holds all cached objects for a single schema.
struct SchemaObjects: Sendable {
    var aggregates: [DBObject] = []
    var collations: [DBObject] = []
    var domains: [DBObject] = []
    var ftsConfigurations: [DBObject] = []
    var ftsDictionaries: [DBObject] = []
    var ftsParsers: [DBObject] = []
    var ftsTemplates: [DBObject] = []
    var foreignTables: [DBObject] = []
    var functions: [DBObject] = []
    var materializedViews: [DBObject] = []
    var operators: [DBObject] = []
    var procedures: [DBObject] = []
    var sequences: [DBObject] = []
    var tables: [DBObject] = []
    var triggerFunctions: [DBObject] = []
    var types: [DBObject] = []
    var views: [DBObject] = []

    func objects(for category: ObjectCategory) -> [DBObject] {
        switch category {
        case .aggregates: return aggregates
        case .collations: return collations
        case .domains: return domains
        case .ftsConfigurations: return ftsConfigurations
        case .ftsDictionaries: return ftsDictionaries
        case .ftsParsers: return ftsParsers
        case .ftsTemplates: return ftsTemplates
        case .foreignTables: return foreignTables
        case .functions: return functions
        case .materializedViews: return materializedViews
        case .operators: return operators
        case .procedures: return procedures
        case .sequences: return sequences
        case .tables: return tables
        case .triggerFunctions: return triggerFunctions
        case .types: return types
        case .views: return views
        }
    }
}

/// Manages the hierarchical database navigator state.
/// Data is stored per-database so multiple databases can be expanded simultaneously.
@MainActor
@Observable final class NavigatorViewModel {
    // Database list
    var databases: [String] = []
    var connectedDatabase: String = ""

    /// Server major version (e.g. 14, 15, 16). Determines which categories are shown.
    var serverVersion: Int = 0

    /// Categories available for the current PG version.
    var availableCategories: [ObjectCategory] {
        ObjectCategory.allCases.filter { category in
            switch category {
            case .procedures:
                return serverVersion >= 11  // prokind='p' added in PG 11
            default:
                return true
            }
        }
    }

    // Per-database schemas
    var schemasPerDatabase: [String: [String]] = [:]

    // Per-database+schema objects (keyed by "db\0schema")
    var objectsPerKey: [String: SchemaObjects] = [:]

    // Track loaded keys
    var loadedKeys: Set<String> = []

    // Tree expansion state
    var expandedDatabases: Set<String> = []
    var expandedSchemas: Set<String> = []   // "db\0schema"
    var expandedCategories: Set<String> = [] // "db\0schema\0Category"

    // Selection
    var selectedObject: DBObject?

    /// Databases currently being loaded (for showing loading indicators in the navigator).
    var loadingDatabases: Set<String> = []

    // MARK: - Key Helpers

    func schemaKey(_ db: String, _ schema: String) -> String { "\(db)\0\(schema)" }
    func categoryKey(_ db: String, _ schema: String, _ category: ObjectCategory) -> String {
        "\(db)\0\(schema)\0\(category.rawValue)"
    }

    // MARK: - Data Access

    func schemas(for db: String) -> [String] { schemasPerDatabase[db] ?? [] }

    func objects(for db: String, schema: String, category: ObjectCategory) -> [DBObject] {
        objectsPerKey[schemaKey(db, schema)]?.objects(for: category) ?? []
    }

    /// All tables across all loaded schemas (for SQL completion).
    /// Cached to avoid recomputing on every access; invalidated when objectsPerKey changes.
    @ObservationIgnored private var _allLoadedTablesCache: [DBObject]?

    var allLoadedTables: [DBObject] {
        if let cached = _allLoadedTablesCache { return cached }
        let result = objectsPerKey.values.flatMap { $0.tables }
        _allLoadedTablesCache = result
        return result
    }

    func isSchemaLoaded(db: String, schema: String) -> Bool {
        loadedKeys.contains(schemaKey(db, schema))
    }

    func hasSchemasLoaded(for db: String) -> Bool {
        schemasPerDatabase[db] != nil
    }

    // MARK: - Expansion Helpers

    func isDatabaseExpanded(_ db: String) -> Bool { expandedDatabases.contains(db) }
    func isSchemaExpanded(_ db: String, _ schema: String) -> Bool { expandedSchemas.contains(schemaKey(db, schema)) }
    func isCategoryExpanded(_ db: String, _ schema: String, _ category: ObjectCategory) -> Bool {
        expandedCategories.contains(categoryKey(db, schema, category))
    }

    func setDatabaseExpanded(_ db: String, _ expanded: Bool) {
        if expanded { expandedDatabases.insert(db) } else { expandedDatabases.remove(db) }
    }
    func setSchemaExpanded(_ db: String, _ schema: String, _ expanded: Bool) {
        let key = schemaKey(db, schema)
        if expanded { expandedSchemas.insert(key) } else { expandedSchemas.remove(key) }
    }
    func setCategoryExpanded(_ db: String, _ schema: String, _ category: ObjectCategory, _ expanded: Bool) {
        let key = categoryKey(db, schema, category)
        if expanded { expandedCategories.insert(key) } else { expandedCategories.remove(key) }
    }

    // MARK: - Data Loading

    func setDatabases(_ databases: [String], current: String) {
        self.databases = databases
        self.connectedDatabase = current
        expandedDatabases.insert(current)
    }

    func setSchemas(_ schemas: [String], forDatabase db: String) {
        schemasPerDatabase[db] = schemas
        // Auto-expand "public" schema and its Tables category
        let defaultSchema = schemas.contains("public") ? "public" : schemas.first
        if let s = defaultSchema {
            expandedSchemas.insert(schemaKey(db, s))
            expandedCategories.insert(categoryKey(db, s, .tables))
        }
    }

    func setSchemaObjects(db: String, schema: String, objects: SchemaObjects) {
        let key = schemaKey(db, schema)
        objectsPerKey[key] = objects
        loadedKeys.insert(key)
        _allLoadedTablesCache = nil
    }

    func invalidateSchema(db: String, schema: String) {
        let key = schemaKey(db, schema)
        loadedKeys.remove(key)
        objectsPerKey.removeValue(forKey: key)
        _allLoadedTablesCache = nil
    }

    func clear() {
        databases = []
        connectedDatabase = ""
        schemasPerDatabase.removeAll()
        objectsPerKey.removeAll()
        _allLoadedTablesCache = nil
        loadedKeys.removeAll()
        expandedDatabases.removeAll()
        expandedSchemas.removeAll()
        expandedCategories.removeAll()
        selectedObject = nil
    }

    /// Clears data for a specific database.
    func clearDatabase(_ db: String) {
        schemasPerDatabase.removeValue(forKey: db)
        let prefix = "\(db)\0"
        objectsPerKey = objectsPerKey.filter { !$0.key.hasPrefix(prefix) }
        _allLoadedTablesCache = nil
        loadedKeys = loadedKeys.filter { !$0.hasPrefix(prefix) }
        expandedSchemas = expandedSchemas.filter { !$0.hasPrefix(prefix) }
        expandedCategories = expandedCategories.filter { !$0.hasPrefix(prefix) }
    }
}

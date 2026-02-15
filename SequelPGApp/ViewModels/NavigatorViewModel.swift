import Foundation

/// Manages the database navigator state (schemas, tables, views).
@MainActor
final class NavigatorViewModel: ObservableObject {
    @Published var databases: [String] = []
    @Published var selectedDatabase: String = ""
    @Published var schemas: [String] = []
    @Published var selectedSchema: String = ""
    @Published var tables: [DBObject] = []
    @Published var views: [DBObject] = []
    @Published var selectedObject: DBObject?

    func setDatabases(_ databases: [String], current: String) {
        self.databases = databases
        self.selectedDatabase = current
    }

    func setSchemas(_ schemas: [String]) {
        self.schemas = schemas
        // Default to "public" if available
        if schemas.contains("public") {
            selectedSchema = "public"
        } else if let first = schemas.first {
            selectedSchema = first
        }
    }

    func setObjects(tables: [DBObject], views: [DBObject]) {
        self.tables = tables
        self.views = views
    }

    func clear() {
        databases = []
        selectedDatabase = ""
        schemas = []
        selectedSchema = ""
        tables = []
        views = []
        selectedObject = nil
    }
}

import Foundation
import OSLog
import SwiftUI

/// Root application state coordinating connections and navigation.
@MainActor
final class AppViewModel: ObservableObject {
    let connectionStore: ConnectionStore
    let keychainService: KeychainServiceProtocol
    let dbClient: DatabaseClient

    @Published var connectionListVM: ConnectionListViewModel
    @Published var navigatorVM: NavigatorViewModel
    @Published var tableVM: TableViewModel
    @Published var queryVM: QueryViewModel

    @Published var selectedTab: MainTab = .query
    @Published var showInspector = true
    @Published var isConnected = false
    @Published var connectedProfileName: String?
    @Published var errorMessage: String?

    enum MainTab: String, CaseIterable {
        case structure = "Structure"
        case content = "Content"
        case query = "Query"
    }

    init(
        connectionStore: ConnectionStore = ConnectionStore(),
        keychainService: KeychainServiceProtocol = KeychainService.shared,
        dbClient: DatabaseClient = DatabaseClient()
    ) {
        self.connectionStore = connectionStore
        self.keychainService = keychainService
        self.dbClient = dbClient

        self.connectionListVM = ConnectionListViewModel(
            store: connectionStore,
            keychainService: keychainService
        )
        self.navigatorVM = NavigatorViewModel()
        self.tableVM = TableViewModel()
        self.queryVM = QueryViewModel()
    }

    func connect(profile: ConnectionProfile) async {
        let password = try? keychainService.load(forKey: profile.keychainKey)
        do {
            try await dbClient.connect(profile: profile, password: password)
            isConnected = true
            connectedProfileName = profile.name
            connectionListVM.setConnected(profileId: profile.id)
            selectedTab = .query

            // Load schemas
            let schemas = try await dbClient.listSchemas()
            navigatorVM.setSchemas(schemas)

            errorMessage = nil
            Log.ui.info("UI: connected to \(profile.name, privacy: .public)")
        } catch {
            errorMessage = error.localizedDescription
            connectionListVM.setError(profileId: profile.id)
            Log.ui.error("UI: connection failed - \(error.localizedDescription)")
        }
    }

    func disconnect() async {
        await dbClient.disconnect()
        isConnected = false
        connectedProfileName = nil
        connectionListVM.clearConnectionState()
        navigatorVM.clear()
        tableVM.clear()
        selectedTab = .query
        Log.ui.info("UI: disconnected")
    }

    func selectObject(_ object: DBObject) async {
        navigatorVM.selectedObject = object
        selectedTab = .structure
        tableVM.clear()

        do {
            let columns = try await dbClient.getColumns(
                schema: object.schema,
                table: object.name
            )
            tableVM.setColumns(columns)

            let approxRows = try await dbClient.getApproximateRowCount(
                schema: object.schema,
                table: object.name
            )
            tableVM.approximateRowCount = approxRows
            tableVM.selectedObjectName = object.name
            tableVM.selectedObjectColumnCount = columns.count
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func loadTablesAndViews(forSchema schema: String) async {
        do {
            let tables = try await dbClient.listTables(schema: schema)
            let views = try await dbClient.listViews(schema: schema)
            navigatorVM.setObjects(tables: tables, views: views)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func loadContentPage() async {
        guard let object = navigatorVM.selectedObject else { return }
        let schema = quoteIdent(object.schema)
        let table = quoteIdent(object.name)
        let limit = tableVM.pageSize
        let offset = tableVM.currentPage * tableVM.pageSize

        let sql = "SELECT * FROM \(schema).\(table) LIMIT \(limit) OFFSET \(offset)"

        do {
            tableVM.isLoadingContent = true
            let result = try await dbClient.runQuery(sql, maxRows: limit, timeout: 10.0)
            tableVM.setContentResult(result)
            tableVM.isLoadingContent = false
        } catch {
            tableVM.isLoadingContent = false
            errorMessage = error.localizedDescription
        }
    }

    func executeQuery(_ sql: String) async {
        guard !sql.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }

        queryVM.isExecuting = true
        queryVM.errorMessage = nil
        queryVM.result = nil

        do {
            let result = try await dbClient.runQuery(sql, maxRows: 2000, timeout: 10.0)
            queryVM.result = result
            queryVM.isExecuting = false
        } catch {
            queryVM.errorMessage = error.localizedDescription
            queryVM.isExecuting = false
        }
    }
}

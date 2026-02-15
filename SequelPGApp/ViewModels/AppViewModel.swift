import Combine
import Foundation
import OSLog
import SwiftUI

/// Root application state coordinating connections and navigation.
@MainActor
final class AppViewModel: ObservableObject {
    let connectionStore: ConnectionStore
    let keychainService: KeychainServiceProtocol
    let dbClient: any PostgresClientProtocol

    @Published var connectionListVM: ConnectionListViewModel
    @Published var navigatorVM: NavigatorViewModel
    @Published var tableVM: TableViewModel
    @Published var queryVM: QueryViewModel

    @Published var selectedTab: MainTab = .query
    @Published var showInspector = true
    @Published var isConnected = false
    @Published var connectedProfileName: String?
    @Published var errorMessage: String?

    private var connectedProfile: ConnectionProfile?
    private var connectedPassword: String?
    private var cancellables = Set<AnyCancellable>()

    enum MainTab: String, CaseIterable {
        case structure = "Structure"
        case content = "Content"
        case query = "Query"
    }

    init(
        connectionStore: ConnectionStore = ConnectionStore(),
        keychainService: KeychainServiceProtocol = KeychainService.shared,
        dbClient: any PostgresClientProtocol = DatabaseClient()
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

        // Forward child VM objectWillChange to parent so SwiftUI
        // views observing this AppViewModel re-render on nested changes.
        connectionListVM.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)

        navigatorVM.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)

        tableVM.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)

        queryVM.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
    }

    func connect(profile: ConnectionProfile) async {
        let password = try? keychainService.load(forKey: profile.keychainKey)
        do {
            try await dbClient.connect(profile: profile, password: password)
            isConnected = true
            connectedProfile = profile
            connectedPassword = password
            connectedProfileName = profile.name
            connectionListVM.setConnected(profileId: profile.id)
            selectedTab = .query

            // Load databases
            let databases = try await dbClient.listDatabases()
            navigatorVM.setDatabases(databases, current: profile.database)

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
        connectedProfile = nil
        connectedPassword = nil
        connectedProfileName = nil
        connectionListVM.clearConnectionState()
        navigatorVM.clear()
        tableVM.clear()
        selectedTab = .query
        Log.ui.info("UI: disconnected")
    }

    func switchDatabase(_ name: String) async {
        guard let profile = connectedProfile, name != profile.database else { return }
        do {
            try await dbClient.switchDatabase(to: name, profile: profile, password: connectedPassword)

            // Update stored profile with the new database
            var updatedProfile = profile
            updatedProfile.database = name
            connectedProfile = updatedProfile

            // Clear navigator (schemas/tables/views/selection) and table state
            navigatorVM.schemas = []
            navigatorVM.selectedSchema = ""
            navigatorVM.tables = []
            navigatorVM.views = []
            navigatorVM.selectedObject = nil
            tableVM.clear()

            // Reload schemas and tables for the new database
            let schemas = try await dbClient.listSchemas()
            navigatorVM.setSchemas(schemas)
            navigatorVM.selectedDatabase = name

            if !navigatorVM.selectedSchema.isEmpty {
                await loadTablesAndViews(forSchema: navigatorVM.selectedSchema)
            }

            errorMessage = nil
            Log.ui.info("UI: switched to database \(name, privacy: .public)")
        } catch {
            errorMessage = error.localizedDescription
            Log.ui.error("UI: database switch failed - \(error.localizedDescription)")
        }
    }

    func selectObject(_ object: DBObject) async {
        navigatorVM.selectedObject = object
        tableVM.clear()

        // If no object-specific tab is active, switch to structure.
        if selectedTab == .query {
            selectedTab = .structure
        }

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

            // If content tab is active, load content for the new object.
            if selectedTab == .content {
                await loadContentPage()
            }
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
            var result = try await dbClient.runQuery(sql, maxRows: limit, timeout: 10.0)

            // When the table has zero rows, runQuery returns empty columns
            // because column names are derived from row data. Use the
            // already-loaded structure columns as a fallback.
            if result.columns.isEmpty, !tableVM.columns.isEmpty {
                result = QueryResult(
                    columns: tableVM.columns.map(\.name),
                    rows: [],
                    executionTime: result.executionTime,
                    rowsAffected: result.rowsAffected,
                    isTruncated: false
                )
            }

            tableVM.setContentResult(result)
            tableVM.isLoadingContent = false
        } catch {
            tableVM.isLoadingContent = false
            errorMessage = error.localizedDescription
        }
    }

    func selectRow(index: Int, columns: [String], values: [CellValue]) {
        tableVM.selectedRowIndex = index
        tableVM.selectedRowData = zip(columns, values).map { (column: $0.0, value: $0.1) }
    }

    func clearSelectedRow() {
        tableVM.selectedRowIndex = nil
        tableVM.selectedRowData = nil
    }

    func executeQuery(_ sql: String) async {
        guard !sql.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }

        queryVM.isExecuting = true
        queryVM.errorMessage = nil
        queryVM.result = nil
        queryVM.editableTableContext = nil
        queryVM.editableColumns = []
        clearSelectedRow()

        do {
            let result = try await dbClient.runQuery(sql, maxRows: 2000, timeout: 10.0)
            queryVM.result = result
            queryVM.isExecuting = false

            // Detect table context for inline editing
            if let tableRef = queryVM.parseTableFromQuery() {
                do {
                    let columns = try await dbClient.getColumns(schema: tableRef.schema, table: tableRef.table)
                    let pkColumns = columns.filter { $0.isPrimaryKey }
                    let resultColumnSet = Set(result.columns)
                    let allPKsPresent = !pkColumns.isEmpty && pkColumns.allSatisfy { resultColumnSet.contains($0.name) }
                    if allPKsPresent {
                        queryVM.editableTableContext = tableRef
                        queryVM.editableColumns = columns
                    }
                } catch {
                    // Silently fail — editing just won't be available
                    queryVM.editableTableContext = nil
                    queryVM.editableColumns = []
                }
            }
        } catch {
            queryVM.errorMessage = error.localizedDescription
            queryVM.isExecuting = false
        }
    }

    // MARK: - Inline Cell Editing

    func updateContentCell(rowIndex: Int, columnIndex: Int, newText: String) async {
        guard let object = navigatorVM.selectedObject,
              let result = tableVM.contentResult
        else { return }

        let pkColumns = tableVM.columns.filter { $0.isPrimaryKey }
        guard !pkColumns.isEmpty else { return }

        let columnName = result.columns[columnIndex]
        let originalRow = result.rows[rowIndex]
        let newValue: CellValue = newText == "NULL" ? .null : .text(newText)

        let sql = buildUpdateSQL(
            schema: object.schema,
            table: object.name,
            columnName: columnName,
            newValue: newValue,
            originalRow: originalRow,
            resultColumns: result.columns,
            pkColumnNames: pkColumns.map(\.name)
        )

        do {
            _ = try await dbClient.runQuery(sql, maxRows: 0, timeout: 10.0)
            await loadContentPage()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func updateQueryCell(rowIndex: Int, columnIndex: Int, newText: String) async {
        guard let tableRef = queryVM.editableTableContext,
              let result = queryVM.result
        else { return }

        let pkColumns = queryVM.editableColumns.filter { $0.isPrimaryKey }
        guard !pkColumns.isEmpty else { return }

        let columnName = result.columns[columnIndex]
        let originalRow = result.rows[rowIndex]
        let newValue: CellValue = newText == "NULL" ? .null : .text(newText)

        let sql = buildUpdateSQL(
            schema: tableRef.schema,
            table: tableRef.table,
            columnName: columnName,
            newValue: newValue,
            originalRow: originalRow,
            resultColumns: result.columns,
            pkColumnNames: pkColumns.map(\.name)
        )

        do {
            _ = try await dbClient.runQuery(sql, maxRows: 0, timeout: 10.0)
            // Re-execute the user's query to refresh results
            await executeQuery(queryVM.queryText)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func buildUpdateSQL(
        schema: String,
        table: String,
        columnName: String,
        newValue: CellValue,
        originalRow: [CellValue],
        resultColumns: [String],
        pkColumnNames: [String]
    ) -> String {
        let setClause = "\(quoteIdent(columnName)) = \(quoteLiteral(newValue))"

        var whereParts: [String] = []
        for pkName in pkColumnNames {
            guard let idx = resultColumns.firstIndex(of: pkName) else { continue }
            let val = originalRow[idx]
            if val.isNull {
                whereParts.append("\(quoteIdent(pkName)) IS NULL")
            } else {
                whereParts.append("\(quoteIdent(pkName)) = \(quoteLiteral(val))")
            }
        }

        let whereClause = whereParts.joined(separator: " AND ")
        return "UPDATE \(quoteIdent(schema)).\(quoteIdent(table)) SET \(setClause) WHERE \(whereClause)"
    }
}

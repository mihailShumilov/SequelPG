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
    @Published var cascadeDeleteContext: CascadeDeleteContext?

    struct CascadeDeleteContext {
        let schema: String
        let table: String
        let pkValues: [(column: String, value: CellValue)]
        let errorMessage: String
        let source: MainTab
    }

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

        var sql = "SELECT * FROM \(schema).\(table)"
        if let sortCol = tableVM.sortColumn {
            let dir = tableVM.sortAscending ? "ASC" : "DESC"
            sql += " ORDER BY \(quoteIdent(sortCol)) \(dir) NULLS LAST"
        }
        sql += " LIMIT \(limit) OFFSET \(offset)"

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
        queryVM.deleteConfirmationRowIndex = nil
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

    // MARK: - Column Sorting

    func toggleContentSort(column: String) {
        if tableVM.sortColumn == column {
            tableVM.sortAscending.toggle()
        } else {
            tableVM.sortColumn = column
            tableVM.sortAscending = true
        }
        tableVM.currentPage = 0
        clearSelectedRow()
        Task { await loadContentPage() }
    }

    func toggleQuerySort(column: String) {
        if queryVM.sortColumn == column {
            queryVM.sortAscending.toggle()
        } else {
            queryVM.sortColumn = column
            queryVM.sortAscending = true
        }
        clearSelectedRow()
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
        let newValue: CellValue = newText.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() == "NULL" ? .null : .text(newText)

        guard let sql = buildUpdateSQL(
            schema: object.schema,
            table: object.name,
            columnName: columnName,
            newValue: newValue,
            originalRow: originalRow,
            resultColumns: result.columns,
            pkColumnNames: pkColumns.map(\.name)
        ) else {
            errorMessage = "Cannot update: primary key columns missing from result"
            return
        }

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

        // rowIndex comes from the sorted display; map it back to the
        // original position in queryVM.result.
        let actualRowIndex = queryVM.originalRowIndex(rowIndex)
        let columnName = result.columns[columnIndex]
        let originalRow = result.rows[actualRowIndex]
        let newValue: CellValue = newText.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() == "NULL" ? .null : .text(newText)

        guard let sql = buildUpdateSQL(
            schema: tableRef.schema,
            table: tableRef.table,
            columnName: columnName,
            newValue: newValue,
            originalRow: originalRow,
            resultColumns: result.columns,
            pkColumnNames: pkColumns.map(\.name)
        ) else {
            errorMessage = "Cannot update: primary key columns missing from result"
            return
        }

        do {
            _ = try await dbClient.runQuery(sql, maxRows: 0, timeout: 10.0)
            // Re-execute the user's query to refresh results
            await executeQuery(queryVM.queryText)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func updateInspectorCell(columnName: String, newText: String) async {
        // Determine which context we're editing in based on the active tab
        if selectedTab == .content {
            guard let result = tableVM.contentResult,
                  let rowIndex = tableVM.selectedRowIndex,
                  let colIndex = result.columns.firstIndex(of: columnName)
            else { return }
            await updateContentCell(rowIndex: rowIndex, columnIndex: colIndex, newText: newText)
            // Re-select the row to refresh inspector data
            if let updatedResult = tableVM.contentResult, rowIndex < updatedResult.rows.count {
                selectRow(index: rowIndex, columns: updatedResult.columns, values: updatedResult.rows[rowIndex])
            }
        } else if selectedTab == .query {
            guard let result = queryVM.result,
                  let rowIndex = tableVM.selectedRowIndex,
                  let colIndex = result.columns.firstIndex(of: columnName)
            else { return }
            await updateQueryCell(rowIndex: rowIndex, columnIndex: colIndex, newText: newText)
            // Re-select the row to refresh inspector data — use sortedResult
            // because rowIndex is a display index from the sorted view.
            if let updatedResult = queryVM.sortedResult, rowIndex < updatedResult.rows.count {
                selectRow(index: rowIndex, columns: updatedResult.columns, values: updatedResult.rows[rowIndex])
            }
        }
    }

    /// Whether the inspector row detail should allow editing.
    var isInspectorEditable: Bool {
        if selectedTab == .content {
            return tableVM.columns.contains { $0.isPrimaryKey }
        } else if selectedTab == .query {
            return queryVM.editableTableContext != nil
        }
        return false
    }

    // MARK: - Insert & Delete Rows

    var canDeleteContentRow: Bool {
        guard cascadeDeleteContext == nil else { return false }
        guard navigatorVM.selectedObject?.type == .table else { return false }
        return tableVM.columns.contains { $0.isPrimaryKey }
    }

    var canDeleteQueryRow: Bool {
        guard cascadeDeleteContext == nil else { return false }
        return queryVM.editableTableContext != nil
    }

    var canInsertContentRow: Bool {
        navigatorVM.selectedObject?.type == .table
    }

    func deleteContentRow(rowIndex: Int) async {
        guard let object = navigatorVM.selectedObject,
              let result = tableVM.contentResult
        else { return }

        let pkColumns = tableVM.columns.filter { $0.isPrimaryKey }
        guard !pkColumns.isEmpty, rowIndex < result.rows.count else { return }

        let originalRow = result.rows[rowIndex]
        guard let sql = buildDeleteSQL(
            schema: object.schema,
            table: object.name,
            originalRow: originalRow,
            resultColumns: result.columns,
            pkColumnNames: pkColumns.map(\.name)
        ) else {
            errorMessage = "Cannot delete: primary key columns missing from result"
            return
        }

        do {
            _ = try await dbClient.runQuery(sql, maxRows: 0, timeout: 10.0)
            clearSelectedRow()
            // Refresh row count and reload current page
            let approxRows = try await dbClient.getApproximateRowCount(
                schema: object.schema,
                table: object.name
            )
            tableVM.approximateRowCount = approxRows
            await loadContentPage()
        } catch let error as AppError {
            if case let .foreignKeyViolation(msg) = error {
                let pkValues = pkColumns.compactMap { pk -> (column: String, value: CellValue)? in
                    guard let idx = result.columns.firstIndex(of: pk.name) else { return nil }
                    return (column: pk.name, value: originalRow[idx])
                }
                cascadeDeleteContext = CascadeDeleteContext(
                    schema: object.schema,
                    table: object.name,
                    pkValues: pkValues,
                    errorMessage: msg,
                    source: .content
                )
            } else {
                errorMessage = error.localizedDescription
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func deleteQueryRow(rowIndex: Int) async {
        guard let tableRef = queryVM.editableTableContext,
              let result = queryVM.result
        else { return }

        let pkColumns = queryVM.editableColumns.filter { $0.isPrimaryKey }
        // rowIndex comes from the sorted display; map it back to the
        // original position in queryVM.result.
        let actualRowIndex = queryVM.originalRowIndex(rowIndex)
        guard !pkColumns.isEmpty, actualRowIndex < result.rows.count else { return }

        let originalRow = result.rows[actualRowIndex]
        guard let sql = buildDeleteSQL(
            schema: tableRef.schema,
            table: tableRef.table,
            originalRow: originalRow,
            resultColumns: result.columns,
            pkColumnNames: pkColumns.map(\.name)
        ) else {
            errorMessage = "Cannot delete: primary key columns missing from result"
            return
        }

        do {
            _ = try await dbClient.runQuery(sql, maxRows: 0, timeout: 10.0)
            clearSelectedRow()
            // Re-execute the user's query to refresh results
            await executeQuery(queryVM.queryText)
        } catch let error as AppError {
            if case let .foreignKeyViolation(msg) = error {
                let pkValues = pkColumns.compactMap { pk -> (column: String, value: CellValue)? in
                    guard let idx = result.columns.firstIndex(of: pk.name) else { return nil }
                    return (column: pk.name, value: originalRow[idx])
                }
                cascadeDeleteContext = CascadeDeleteContext(
                    schema: tableRef.schema,
                    table: tableRef.table,
                    pkValues: pkValues,
                    errorMessage: msg,
                    source: .query
                )
            } else {
                errorMessage = error.localizedDescription
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func startInsertRow() {
        guard let object = navigatorVM.selectedObject,
              object.type == .table
        else { return }

        clearSelectedRow()
        tableVM.isInsertingRow = true
        // Initialize values for each column; pre-fill date/time/timestamp
        // columns with the current time.
        let now = Date()
        var values: [String: String] = [:]
        for col in tableVM.columns {
            values[col.name] = defaultInsertValue(for: col.dataType, now: now)
        }
        // If contentResult has columns but tableVM.columns is empty, use result columns
        if values.isEmpty, let result = tableVM.contentResult {
            for colName in result.columns {
                values[colName] = ""
            }
        }
        tableVM.newRowValues = values
    }

    func commitInsertRow() async {
        guard let object = navigatorVM.selectedObject,
              object.type == .table
        else { return }

        let columns = tableVM.columns
        let values = tableVM.newRowValues

        // Build column/value lists, skipping empty values for columns that
        // have a default or are nullable (let the DB fill them in).
        var insertColumns: [String] = []
        var insertValues: [String] = []

        for col in columns {
            let rawValue = values[col.name]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

            if rawValue.isEmpty {
                // Skip — let DB use default or NULL
                continue
            }

            insertColumns.append(quoteIdent(col.name))

            if rawValue.uppercased() == "NULL" {
                insertValues.append("NULL")
            } else {
                insertValues.append(quoteLiteral(.text(rawValue)))
            }
        }

        let schema = quoteIdent(object.schema)
        let table = quoteIdent(object.name)
        let sql: String
        if insertColumns.isEmpty {
            sql = "INSERT INTO \(schema).\(table) DEFAULT VALUES"
        } else {
            sql = "INSERT INTO \(schema).\(table) (\(insertColumns.joined(separator: ", "))) VALUES (\(insertValues.joined(separator: ", ")))"
        }

        do {
            _ = try await dbClient.runQuery(sql, maxRows: 0, timeout: 10.0)
            // Refresh row count
            let approxRows = try await dbClient.getApproximateRowCount(
                schema: object.schema,
                table: object.name
            )
            tableVM.approximateRowCount = approxRows
            // Navigate to last page to show the new row
            tableVM.currentPage = max(0, tableVM.totalPages - 1)
            clearSelectedRow()
            tableVM.isInsertingRow = false
            tableVM.newRowValues = [:]
            await loadContentPage()
        } catch {
            // Keep insert row visible so user can fix values
            errorMessage = error.localizedDescription
        }
    }

    func cancelInsertRow() {
        tableVM.isInsertingRow = false
        tableVM.newRowValues = [:]
    }

    /// Returns a pre-filled default value for date/time/timestamp columns,
    /// or an empty string for all other types.
    private func defaultInsertValue(for dataType: String, now: Date) -> String {
        let type = dataType.lowercased()
        let hasTimeZone = type.contains("with time zone") || type.contains("tz")

        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "en_US_POSIX")

        // Check timestamp first — "timestamp" also starts with "time"
        if type.contains("timestamp") {
            fmt.dateFormat = hasTimeZone ? "yyyy-MM-dd HH:mm:ssXXXXX" : "yyyy-MM-dd HH:mm:ss"
            return fmt.string(from: now)
        }

        if type == "date" {
            fmt.dateFormat = "yyyy-MM-dd"
            return fmt.string(from: now)
        }

        if type.hasPrefix("time") {
            fmt.dateFormat = hasTimeZone ? "HH:mm:ssXXXXX" : "HH:mm:ss"
            return fmt.string(from: now)
        }

        return ""
    }

    func deleteInspectorRow() async {
        guard let rowIndex = tableVM.selectedRowIndex else { return }
        if selectedTab == .content {
            await deleteContentRow(rowIndex: rowIndex)
        } else if selectedTab == .query {
            await deleteQueryRow(rowIndex: rowIndex)
        }
    }

    func executeCascadeDelete() async {
        guard let ctx = cascadeDeleteContext else { return }
        let source = ctx.source
        cascadeDeleteContext = nil

        // Build WHERE clause for the parent row from PK values
        let parentWhereParts = ctx.pkValues.map { pk -> String in
            if pk.value.isNull {
                return "\(quoteIdent(pk.column)) IS NULL"
            } else {
                return "\(quoteIdent(pk.column)) = \(quoteLiteral(pk.value))"
            }
        }
        guard !parentWhereParts.isEmpty else {
            errorMessage = "Cannot cascade delete: no primary key values"
            return
        }
        let parentWhere = parentWhereParts.joined(separator: " AND ")

        // Query FK metadata to find all child tables referencing this parent
        let escapedSchema = ctx.schema.replacingOccurrences(of: "'", with: "''")
        let escapedTable = ctx.table.replacingOccurrences(of: "'", with: "''")
        let fkSQL = """
            SELECT child_ns.nspname AS child_schema,
                   child_rel.relname AS child_table,
                   child_att.attname AS child_column,
                   parent_att.attname AS parent_column
            FROM pg_constraint con
            JOIN pg_class child_rel ON con.conrelid = child_rel.oid
            JOIN pg_namespace child_ns ON child_rel.relnamespace = child_ns.oid
            JOIN LATERAL unnest(con.conkey) WITH ORDINALITY AS ck(num, ord) ON true
            JOIN pg_attribute child_att ON child_att.attrelid = con.conrelid AND child_att.attnum = ck.num
            JOIN LATERAL unnest(con.confkey) WITH ORDINALITY AS cfk(num, ord) ON cfk.ord = ck.ord
            JOIN pg_attribute parent_att ON parent_att.attrelid = con.confrelid AND parent_att.attnum = cfk.num
            WHERE con.contype = 'f'
              AND con.confrelid = (
                  SELECT c.oid FROM pg_class c
                  JOIN pg_namespace n ON c.relnamespace = n.oid
                  WHERE c.relname = '\(escapedTable)' AND n.nspname = '\(escapedSchema)'
              )
            """

        do {
            let fkResult = try await dbClient.runQuery(fkSQL, maxRows: 5000, timeout: 10.0)
            if fkResult.isTruncated {
                errorMessage = "Too many foreign key relationships to cascade delete safely."
                return
            }

            // Group by (child_schema, child_table) to handle composite FKs
            struct ChildFK: Hashable {
                let schema: String
                let table: String
            }
            var childMap: [ChildFK: [(childCol: String, parentCol: String)]] = [:]

            for row in fkResult.rows {
                guard row.count >= 4,
                      case let .text(childSchema) = row[0],
                      case let .text(childTable) = row[1],
                      case let .text(childCol) = row[2],
                      case let .text(parentCol) = row[3]
                else { continue }

                let key = ChildFK(schema: childSchema, table: childTable)
                childMap[key, default: []].append((childCol: childCol, parentCol: parentCol))
            }

            // Build a writable CTE that deletes children then parent
            var cteParts: [String] = []
            for (idx, entry) in childMap.enumerated() {
                let child = entry.key
                let mappings = entry.value
                var childWhereParts: [String] = []
                var allMappingsResolved = true
                for mapping in mappings {
                    // Find the parent PK value for this mapping
                    guard let pkVal = ctx.pkValues.first(where: { $0.column == mapping.parentCol }) else {
                        // Missing PK value for a composite FK column — skip this
                        // child entirely to avoid an incomplete WHERE clause that
                        // could delete unrelated rows.
                        allMappingsResolved = false
                        break
                    }
                    if pkVal.value.isNull {
                        childWhereParts.append("\(quoteIdent(mapping.childCol)) IS NULL")
                    } else {
                        childWhereParts.append("\(quoteIdent(mapping.childCol)) = \(quoteLiteral(pkVal.value))")
                    }
                }
                guard allMappingsResolved, !childWhereParts.isEmpty else { continue }
                let childWhere = childWhereParts.joined(separator: " AND ")
                cteParts.append("del_child\(idx) AS (DELETE FROM \(quoteIdent(child.schema)).\(quoteIdent(child.table)) WHERE \(childWhere))")
            }

            let cascadeSQL: String
            if cteParts.isEmpty {
                // No children found, just retry the plain delete
                cascadeSQL = "DELETE FROM \(quoteIdent(ctx.schema)).\(quoteIdent(ctx.table)) WHERE \(parentWhere)"
            } else {
                cascadeSQL = "WITH \(cteParts.joined(separator: ", ")) DELETE FROM \(quoteIdent(ctx.schema)).\(quoteIdent(ctx.table)) WHERE \(parentWhere)"
            }

            _ = try await dbClient.runQuery(cascadeSQL, maxRows: 0, timeout: 10.0)
            clearSelectedRow()

            // Refresh data based on source tab
            if source == .content {
                if let object = navigatorVM.selectedObject {
                    let approxRows = try await dbClient.getApproximateRowCount(
                        schema: object.schema,
                        table: object.name
                    )
                    tableVM.approximateRowCount = approxRows
                }
                await loadContentPage()
            } else if source == .query {
                await executeQuery(queryVM.queryText)
            }
        } catch let error as AppError {
            if case .foreignKeyViolation = error {
                errorMessage = "Cascade delete failed: new referencing rows may have been added. Please try again."
            } else {
                errorMessage = error.localizedDescription
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func buildDeleteSQL(
        schema: String,
        table: String,
        originalRow: [CellValue],
        resultColumns: [String],
        pkColumnNames: [String]
    ) -> String? {
        var whereParts: [String] = []
        for pkName in pkColumnNames {
            guard let idx = resultColumns.firstIndex(of: pkName) else {
                return nil
            }
            let val = originalRow[idx]
            if val.isNull {
                whereParts.append("\(quoteIdent(pkName)) IS NULL")
            } else {
                whereParts.append("\(quoteIdent(pkName)) = \(quoteLiteral(val))")
            }
        }

        guard !whereParts.isEmpty else { return nil }

        let whereClause = whereParts.joined(separator: " AND ")
        return "DELETE FROM \(quoteIdent(schema)).\(quoteIdent(table)) WHERE \(whereClause)"
    }

    private func buildUpdateSQL(
        schema: String,
        table: String,
        columnName: String,
        newValue: CellValue,
        originalRow: [CellValue],
        resultColumns: [String],
        pkColumnNames: [String]
    ) -> String? {
        let setClause = "\(quoteIdent(columnName)) = \(quoteLiteral(newValue))"

        var whereParts: [String] = []
        for pkName in pkColumnNames {
            guard let idx = resultColumns.firstIndex(of: pkName) else {
                // PK column missing from result — cannot build safe WHERE clause
                return nil
            }
            let val = originalRow[idx]
            if val.isNull {
                whereParts.append("\(quoteIdent(pkName)) IS NULL")
            } else {
                whereParts.append("\(quoteIdent(pkName)) = \(quoteLiteral(val))")
            }
        }

        guard !whereParts.isEmpty else { return nil }

        let whereClause = whereParts.joined(separator: " AND ")
        return "UPDATE \(quoteIdent(schema)).\(quoteIdent(table)) SET \(setClause) WHERE \(whereClause)"
    }
}

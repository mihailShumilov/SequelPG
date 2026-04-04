import Foundation
import OSLog
import SwiftUI

/// Context for a pending cascade delete operation.
struct CascadeDeleteContext {
    let schema: String
    let table: String
    let pkValues: [(column: String, value: CellValue)]
    let errorMessage: String
    let source: AppViewModel.MainTab
}

/// Per-session application state coordinating a single database connection.
/// Each connection tab/window gets its own AppViewModel instance.
@MainActor
@Observable final class AppViewModel {
    static let defaultQueryTimeout: TimeInterval = 10.0
    static let maxQueryRows = 2000

    @ObservationIgnored let dbClient: any PostgresClientProtocol

    let navigatorVM: NavigatorViewModel
    let tableVM: TableViewModel
    let queryVM: QueryViewModel

    var selectedTab: MainTab = .query
    var showInspector = true
    var isConnected = false
    var connectedProfileName: String?
    var errorMessage: String?
    var cascadeDeleteContext: CascadeDeleteContext?

    @ObservationIgnored private var connectedProfile: ConnectionProfile?
    @ObservationIgnored private var connectedPassword: String?
    @ObservationIgnored private var connectedSSHPassword: String?

    enum MainTab: String, CaseIterable {
        case structure = "Structure"
        case content = "Content"
        case query = "Query"
    }

    init(
        dbClient: any PostgresClientProtocol = DatabaseClient()
    ) {
        self.dbClient = dbClient

        self.navigatorVM = NavigatorViewModel()
        self.tableVM = TableViewModel()
        self.queryVM = QueryViewModel()
    }

    /// Connects to a database using the given profile and credentials.
    func connect(profile: ConnectionProfile, password: String?, sshPassword: String?) async {
        do {
            try await dbClient.connect(profile: profile, password: password, sshPassword: sshPassword)
            isConnected = true
            connectedProfile = profile
            connectedPassword = password
            connectedSSHPassword = sshPassword
            connectedProfileName = profile.name
            selectedTab = .query

            // Detect server version
            let versionResult = try await dbClient.runQuery("SHOW server_version_num", maxRows: 1, timeout: 5.0)
            if let versionStr = versionResult.rows.first?.first?.displayString,
               let versionNum = Int(versionStr) {
                navigatorVM.serverVersion = versionNum / 10000  // e.g. 160004 → 16
            }

            // Load databases
            let databases = try await dbClient.listDatabases()
            navigatorVM.setDatabases(databases, current: profile.database)

            // Load schemas for the connected database
            let schemas = try await dbClient.listSchemas()
            navigatorVM.setSchemas(schemas, forDatabase: profile.database)

            // Load objects for the default expanded schemas
            await loadExpandedSchemaObjects(forDatabase: profile.database)

            errorMessage = nil
            Log.ui.info("UI: connected to \(profile.name, privacy: .public)")
        } catch {
            errorMessage = error.localizedDescription
            Log.ui.error("UI: connection failed - \(error.localizedDescription)")
        }
    }

    func disconnect() async {
        await dbClient.disconnect()
        isConnected = false
        connectedProfile = nil
        connectedPassword = nil
        connectedSSHPassword = nil
        connectedProfileName = nil
        navigatorVM.clear()
        tableVM.clear()
        selectedTab = .query
        Log.ui.info("UI: disconnected")
    }

    func switchDatabase(_ name: String) async {
        guard let profile = connectedProfile, name != profile.database else { return }
        do {
            try await dbClient.switchDatabase(to: name, profile: profile, password: connectedPassword, sshPassword: connectedSSHPassword)

            var updatedProfile = profile
            updatedProfile.database = name
            connectedProfile = updatedProfile
            navigatorVM.connectedDatabase = name
            tableVM.clear()

            // Load schemas if not already cached for this database
            if !navigatorVM.hasSchemasLoaded(for: name) {
                let schemas = try await dbClient.listSchemas()
                navigatorVM.setSchemas(schemas, forDatabase: name)
                await loadExpandedSchemaObjects(forDatabase: name)
            }

            errorMessage = nil
            Log.ui.info("UI: switched to database \(name, privacy: .public)")
        } catch {
            errorMessage = error.localizedDescription
            Log.ui.error("UI: database switch failed - \(error.localizedDescription)")
        }
    }

    /// Loads schemas for a database by temporarily switching to it, then switching back.
    /// Used when expanding a non-connected database in the navigator tree.
    func loadDatabaseSchemas(_ dbName: String) async {
        guard let profile = connectedProfile else { return }
        let currentDb = profile.database

        // If this is the connected database, just load directly
        if dbName == currentDb {
            do {
                let schemas = try await dbClient.listSchemas()
                navigatorVM.setSchemas(schemas, forDatabase: dbName)
                await loadExpandedSchemaObjects(forDatabase: dbName)
            } catch {
                errorMessage = error.localizedDescription
            }
            return
        }

        // Switch to the target database, fetch schemas, then always switch back
        do {
            try await dbClient.switchDatabase(to: dbName, profile: profile, password: connectedPassword, sshPassword: connectedSSHPassword)
            let schemas = try await dbClient.listSchemas()
            navigatorVM.setSchemas(schemas, forDatabase: dbName)
            await loadExpandedSchemaObjects(forDatabase: dbName)
        } catch {
            errorMessage = error.localizedDescription
        }
        // Always switch back to the original database
        do {
            try await dbClient.switchDatabase(to: currentDb, profile: profile, password: connectedPassword, sshPassword: connectedSSHPassword)
            var restoredProfile = profile
            restoredProfile.database = currentDb
            connectedProfile = restoredProfile
        } catch {
            errorMessage = "Failed to restore connection to \(currentDb): \(error.localizedDescription)"
        }
    }

    func selectObject(_ object: DBObject) async {
        guard navigatorVM.selectedObject != object else { return }
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

    /// Loads all objects for a schema in the specified database.
    func loadSchemaObjects(db: String, schema: String) async {
        guard !navigatorVM.isSchemaLoaded(db: db, schema: schema) else { return }
        do {
            let objects = try await dbClient.listAllSchemaObjects(schema: schema)
            navigatorVM.objectsPerKey[navigatorVM.schemaKey(db, schema)] = objects
            navigatorVM.loadedKeys.insert(navigatorVM.schemaKey(db, schema))
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Loads objects for all expanded schemas in a database.
    private func loadExpandedSchemaObjects(forDatabase db: String) async {
        let schemas = navigatorVM.schemas(for: db)
        for schema in schemas {
            let key = navigatorVM.schemaKey(db, schema)
            if navigatorVM.expandedSchemas.contains(key) {
                await loadSchemaObjects(db: db, schema: schema)
            }
        }
    }

    /// Invalidates the introspection cache and reloads the navigator tree.
    func refreshNavigator() async {
        await dbClient.invalidateCache()
        guard let db = connectedProfile?.database else { return }
        let previouslyExpanded = navigatorVM.expandedSchemas
        navigatorVM.clearDatabase(db)
        do {
            let schemas = try await dbClient.listSchemas()
            navigatorVM.setSchemas(schemas, forDatabase: db)
            // Reload objects for previously expanded schemas
            for key in previouslyExpanded {
                let parts = key.split(separator: "\0", maxSplits: 1)
                guard parts.count == 2, String(parts[0]) == db else { continue }
                let schema = String(parts[1])
                guard schemas.contains(schema) else { continue }
                navigatorVM.setSchemaExpanded(db, schema, true)
                await loadSchemaObjects(db: db, schema: schema)
            }
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
            var result = try await dbClient.runQuery(sql, maxRows: limit, timeout: Self.defaultQueryTimeout)

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
        queryVM.invalidateSortCache()
        queryVM.editableTableContext = nil
        queryVM.editableColumns = []
        queryVM.deleteConfirmationRowIndex = nil
        clearSelectedRow()

        do {
            var result = try await dbClient.runQuery(sql, maxRows: Self.maxQueryRows, timeout: Self.defaultQueryTimeout)

            // Detect table context for inline editing and resolve empty columns
            if let tableRef = queryVM.parseTableFromQuery() {
                do {
                    let columns = try await dbClient.getColumns(schema: tableRef.schema, table: tableRef.table)

                    // When a SELECT returns 0 rows, PostgresNIO doesn't yield
                    // any rows so column names aren't captured. Use the table's
                    // column metadata to fill them in.
                    if result.columns.isEmpty, !columns.isEmpty {
                        result = QueryResult(
                            columns: columns.map(\.name),
                            rows: [],
                            executionTime: result.executionTime,
                            rowsAffected: result.rowsAffected,
                            isTruncated: false
                        )
                    }

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

            queryVM.result = result
            queryVM.invalidateSortCache()
            queryVM.isExecuting = false
        } catch {
            queryVM.errorMessage = error.localizedDescription
            queryVM.isExecuting = false
        }
    }

    // MARK: - Column Sorting

    func toggleContentSort(column: String) {
        applySort(column: column, currentColumn: &tableVM.sortColumn, ascending: &tableVM.sortAscending)
        tableVM.currentPage = 0
        clearSelectedRow()
        Task { await loadContentPage() }
    }

    func toggleQuerySort(column: String) {
        applySort(column: column, currentColumn: &queryVM.sortColumn, ascending: &queryVM.sortAscending)
        queryVM.invalidateSortCache()
        clearSelectedRow()
    }

    private func applySort(column: String, currentColumn: inout String?, ascending: inout Bool) {
        if currentColumn == column {
            ascending.toggle()
        } else {
            currentColumn = column
            ascending = true
        }
    }

    // MARK: - Inline Cell Editing

    func updateContentCell(rowIndex: Int, columnIndex: Int, newText: String) async {
        guard let object = navigatorVM.selectedObject,
              let result = tableVM.contentResult
        else { return }

        let pkColumns = tableVM.columns.filter { $0.isPrimaryKey }
        guard !pkColumns.isEmpty else { return }

        let newValue = Self.cellValueFromText(newText)

        guard let sql = buildUpdateSQL(
            schema: object.schema, table: object.name,
            columnName: result.columns[columnIndex], newValue: newValue,
            originalRow: result.rows[rowIndex], resultColumns: result.columns,
            pkColumnNames: pkColumns.map(\.name), columnInfo: tableVM.columns
        ) else {
            errorMessage = "Cannot update: primary key columns missing from result"
            return
        }

        do {
            _ = try await dbClient.runQuery(sql, maxRows: 0, timeout: Self.defaultQueryTimeout)
            // Update in-place to preserve row order
            tableVM.contentResult = result.replacingCell(row: rowIndex, column: columnIndex, with: newValue)
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

        // rowIndex comes from the sorted display; map it back to the original position.
        let actualRowIndex = queryVM.originalRowIndex(rowIndex)

        let newValue = Self.cellValueFromText(newText)

        guard let sql = buildUpdateSQL(
            schema: tableRef.schema, table: tableRef.table,
            columnName: result.columns[columnIndex], newValue: newValue,
            originalRow: result.rows[actualRowIndex], resultColumns: result.columns,
            pkColumnNames: pkColumns.map(\.name), columnInfo: queryVM.editableColumns
        ) else {
            errorMessage = "Cannot update: primary key columns missing from result"
            return
        }

        do {
            _ = try await dbClient.runQuery(sql, maxRows: 0, timeout: Self.defaultQueryTimeout)
            // Update in-place to preserve row order
            queryVM.result = result.replacingCell(row: actualRowIndex, column: columnIndex, with: newValue)
            queryVM.invalidateSortCache()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private static func cellValueFromText(_ text: String) -> CellValue {
        text.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() == "NULL" ? .null : .text(text)
    }

    func updateInspectorCell(columnName: String, newText: String) async {
        // Determine which context we're editing in based on the active tab
        if selectedTab == .content {
            guard let result = tableVM.contentResult,
                  let rowIndex = tableVM.selectedRowIndex,
                  let colIndex = result.columns.firstIndex(of: columnName)
            else { return }
            await updateContentCell(rowIndex: rowIndex, columnIndex: colIndex, newText: newText)
            // Refresh inspector data from the in-place updated result
            if let updated = tableVM.contentResult, rowIndex < updated.rows.count {
                selectRow(index: rowIndex, columns: updated.columns, values: updated.rows[rowIndex])
            }
        } else if selectedTab == .query {
            guard let result = queryVM.result,
                  let rowIndex = tableVM.selectedRowIndex,
                  let colIndex = result.columns.firstIndex(of: columnName)
            else { return }
            await updateQueryCell(rowIndex: rowIndex, columnIndex: colIndex, newText: newText)
            // Refresh inspector data from the in-place updated sorted result
            if let updated = queryVM.sortedResult, rowIndex < updated.rows.count {
                selectRow(index: rowIndex, columns: updated.columns, values: updated.rows[rowIndex])
            }
        }
    }

    /// Whether the inspector row detail should allow editing.
    var isInspectorEditable: Bool {
        if selectedTab == .content {
            return tableVM.hasPrimaryKey
        } else if selectedTab == .query {
            return queryVM.editableTableContext != nil
        }
        return false
    }

    // MARK: - Insert & Delete Rows

    var canDeleteContentRow: Bool {
        guard cascadeDeleteContext == nil else { return false }
        guard navigatorVM.selectedObject?.type == .table else { return false }
        return tableVM.hasPrimaryKey
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
            _ = try await dbClient.runQuery(sql, maxRows: 0, timeout: Self.defaultQueryTimeout)
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
            _ = try await dbClient.runQuery(sql, maxRows: 0, timeout: Self.defaultQueryTimeout)
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

        // Pre-flight: check for NOT NULL columns without defaults that have empty values
        let missingRequired = columns.filter { col in
            !col.isNullable && col.columnDefault == nil
                && (values[col.name]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "").isEmpty
        }
        if !missingRequired.isEmpty {
            let names = missingRequired.map(\.name).joined(separator: ", ")
            errorMessage = "Required columns cannot be empty: \(names)"
            return
        }

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
                insertValues.append(quoteLiteralTyped(.text(rawValue), dataType: col.dataType))
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
            _ = try await dbClient.runQuery(sql, maxRows: 0, timeout: Self.defaultQueryTimeout)
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

    // MARK: - Date Formatters (static, allocated once)

    private static let timestampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f
    }()

    private static let timestampTZFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm:ssXXXXX"
        return f
    }()

    private static let insertDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    private static let timeTZFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "HH:mm:ssXXXXX"
        return f
    }()

    /// Returns a pre-filled default value for date/time/timestamp columns,
    /// or an empty string for all other types.
    private func defaultInsertValue(for dataType: String, now: Date) -> String {
        let type = dataType.lowercased()
        let hasTimeZone = type.contains("with time zone") || type.contains("tz")

        if type.contains("timestamp") {
            return (hasTimeZone ? Self.timestampTZFormatter : Self.timestampFormatter).string(from: now)
        }
        if type == "date" {
            return Self.insertDateFormatter.string(from: now)
        }
        if type.hasPrefix("time") {
            return (hasTimeZone ? Self.timeTZFormatter : Self.timeFormatter).string(from: now)
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

    /// Executes a cascading DELETE that removes direct child rows referencing
    /// the parent row, then deletes the parent itself via a writable CTE.
    ///
    /// **Limitation:** Only handles direct (one-level) foreign key dependencies.
    /// If a child table itself has child tables (grandchildren), the cascade
    /// will fail with a foreign key violation. In that case, manually delete
    /// the deeper dependencies first or use `ON DELETE CASCADE` constraints.
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
                  WHERE c.relname = \(quoteLiteral(.text(ctx.table))) AND n.nspname = \(quoteLiteral(.text(ctx.schema)))
              )
            """

        do {
            let fkResult = try await dbClient.runQuery(fkSQL, maxRows: 5000, timeout: Self.defaultQueryTimeout)
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

            let deleteSQL: String
            if cteParts.isEmpty {
                // No children found, just retry the plain delete
                deleteSQL = "DELETE FROM \(quoteIdent(ctx.schema)).\(quoteIdent(ctx.table)) WHERE \(parentWhere)"
            } else {
                deleteSQL = "WITH \(cteParts.joined(separator: ", ")) DELETE FROM \(quoteIdent(ctx.schema)).\(quoteIdent(ctx.table)) WHERE \(parentWhere)"
            }
            let cascadeSQL = "BEGIN; \(deleteSQL); COMMIT;"

            _ = try await dbClient.runQuery(cascadeSQL, maxRows: 0, timeout: Self.defaultQueryTimeout)
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
                errorMessage = "Cascade delete failed: child tables may have their own foreign key dependencies (grandchildren) that must be deleted first. Alternatively, configure ON DELETE CASCADE on the database constraints."
            } else {
                errorMessage = error.localizedDescription
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - Schema Editing (ALTER TABLE)

    func addColumn(name: String, dataType: String, nullable: Bool, defaultValue: String) async {
        guard let object = navigatorVM.selectedObject else { return }
        guard isValidTypeName(dataType) else {
            errorMessage = "Invalid data type: \(dataType)"
            return
        }
        var sql = "ALTER TABLE \(quoteIdent(object.schema)).\(quoteIdent(object.name)) ADD COLUMN \(quoteIdent(name)) \(dataType)"
        if !nullable { sql += " NOT NULL" }
        if !defaultValue.isEmpty { sql += " DEFAULT \(defaultValue)" }
        await executeSchemaChange(sql, schema: object.schema, table: object.name)
    }

    func dropColumn(_ columnName: String) async {
        guard let object = navigatorVM.selectedObject else { return }
        let sql = "ALTER TABLE \(quoteIdent(object.schema)).\(quoteIdent(object.name)) DROP COLUMN \(quoteIdent(columnName))"
        await executeSchemaChange(sql, schema: object.schema, table: object.name)
    }

    func renameColumn(oldName: String, newName: String) async {
        guard let object = navigatorVM.selectedObject else { return }
        let sql = "ALTER TABLE \(quoteIdent(object.schema)).\(quoteIdent(object.name)) RENAME COLUMN \(quoteIdent(oldName)) TO \(quoteIdent(newName))"
        await executeSchemaChange(sql, schema: object.schema, table: object.name)
    }

    func changeColumnType(columnName: String, newType: String) async {
        guard let object = navigatorVM.selectedObject else { return }
        guard isValidTypeName(newType) else {
            errorMessage = "Invalid data type: \(newType)"
            return
        }
        let sql = "ALTER TABLE \(quoteIdent(object.schema)).\(quoteIdent(object.name)) ALTER COLUMN \(quoteIdent(columnName)) TYPE \(newType) USING \(quoteIdent(columnName))::\(newType)"
        await executeSchemaChange(sql, schema: object.schema, table: object.name)
    }

    func toggleColumnNullable(columnName: String, nullable: Bool) async {
        guard let object = navigatorVM.selectedObject else { return }
        let action = nullable ? "DROP NOT NULL" : "SET NOT NULL"
        let sql = "ALTER TABLE \(quoteIdent(object.schema)).\(quoteIdent(object.name)) ALTER COLUMN \(quoteIdent(columnName)) \(action)"
        await executeSchemaChange(sql, schema: object.schema, table: object.name)
    }

    func changeColumnDefault(columnName: String, newDefault: String) async {
        guard let object = navigatorVM.selectedObject else { return }
        let action = newDefault.isEmpty ? "DROP DEFAULT" : "SET DEFAULT \(newDefault)"
        let sql = "ALTER TABLE \(quoteIdent(object.schema)).\(quoteIdent(object.name)) ALTER COLUMN \(quoteIdent(columnName)) \(action)"
        await executeSchemaChange(sql, schema: object.schema, table: object.name)
    }

    private func executeSchemaChange(_ sql: String, schema: String, table: String) async {
        do {
            _ = try await dbClient.runQuery(sql, maxRows: 0, timeout: Self.defaultQueryTimeout)
            await dbClient.invalidateCache()
            let columns = try await dbClient.getColumns(schema: schema, table: table)
            tableVM.setColumns(columns)
            tableVM.selectedObjectColumnCount = columns.count
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - Create Operations

    func createDatabase(name: String) async {
        let sql = "CREATE DATABASE \(quoteIdent(name))"
        do {
            _ = try await dbClient.runQuery(sql, maxRows: 0, timeout: Self.defaultQueryTimeout)
            let databases = try await dbClient.listDatabases()
            navigatorVM.setDatabases(databases, current: navigatorVM.connectedDatabase)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func createSchema(name: String) async {
        let sql = "CREATE SCHEMA \(quoteIdent(name))"
        do {
            _ = try await dbClient.runQuery(sql, maxRows: 0, timeout: Self.defaultQueryTimeout)
            await dbClient.invalidateCache()
            await refreshNavigator()
            let db = navigatorVM.connectedDatabase
            navigatorVM.setSchemaExpanded(db, name, true)
            await loadSchemaObjects(db: db, schema: name)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func createTable(schema: String, name: String, columns: [NewColumnDef]) async {
        let db = navigatorVM.connectedDatabase
        // Validate all column types
        for col in columns {
            guard isValidTypeName(col.dataType) else {
                errorMessage = "Invalid data type '\(col.dataType)' for column '\(col.name)'"
                return
            }
        }
        let colDefs = columns.map { col -> String in
            var def = "\(quoteIdent(col.name)) \(col.dataType)"
            if col.isPrimaryKey { def += " PRIMARY KEY" }
            if !col.isNullable, !col.isPrimaryKey { def += " NOT NULL" }
            if !col.defaultValue.isEmpty { def += " DEFAULT \(col.defaultValue)" }
            return def
        }
        let sql = "CREATE TABLE \(quoteIdent(schema)).\(quoteIdent(name)) (\(colDefs.joined(separator: ", ")))"
        do {
            _ = try await dbClient.runQuery(sql, maxRows: 0, timeout: Self.defaultQueryTimeout)
            await dbClient.invalidateCache()
            navigatorVM.invalidateSchema(db: db, schema: schema)
            await loadSchemaObjects(db: db, schema: schema)
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
        pkColumnNames: [String],
        columnInfo: [ColumnInfo] = []
    ) -> String? {
        let columnInfoByName = Dictionary(columnInfo.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
        let targetType = columnInfoByName[columnName]?.dataType
        let setClause: String
        if let dataType = targetType {
            setClause = "\(quoteIdent(columnName)) = \(quoteLiteralTyped(newValue, dataType: dataType))"
        } else {
            setClause = "\(quoteIdent(columnName)) = \(quoteLiteral(newValue))"
        }

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

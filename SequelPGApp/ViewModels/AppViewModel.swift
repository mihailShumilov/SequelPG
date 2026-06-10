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

/// Constructs the SQL needed to delete a parent row and its direct children
/// via a writable CTE. Extracted from `executeCascadeDelete` so the SQL-building
/// logic can be unit-tested and reasoned about independently of DB execution,
/// error handling, and UI refresh.
///
/// **Limitation:** Only handles direct (one-level) foreign key dependencies.
/// Grandchildren must be handled via `ON DELETE CASCADE` on the database.
struct CascadeDeleteBuilder {
    let schema: String
    let table: String
    let pkValues: [(column: String, value: CellValue)]

    var hasPrimaryKeyValues: Bool { !pkValues.isEmpty }

    /// Fetches every (child_schema, child_table, child_column, parent_column)
    /// tuple for FKs whose referenced table is this parent. Used to enumerate
    /// children that must be purged before the parent delete can succeed.
    var foreignKeyMetadataSQL: String {
        """
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
              WHERE c.relname = \(quoteLiteral(.text(table))) AND n.nspname = \(quoteLiteral(.text(schema)))
          )
        """
    }

    /// Builds the DELETE (or WITH … DELETE) SQL from the FK metadata rows
    /// returned by `foreignKeyMetadataSQL`. Falls back to a plain parent DELETE
    /// when no children are found or none of them can be matched against the
    /// parent PK values.
    func makeDeleteSQL(from fkRows: [[CellValue]]) -> String {
        let parentWhere = parentWhereClause
        let cteParts = buildChildDeleteCTEs(fkRows: fkRows)
        let parentDelete = "DELETE FROM \(quoteIdent(schema)).\(quoteIdent(table)) WHERE \(parentWhere)"
        if cteParts.isEmpty {
            return parentDelete
        }
        return "WITH \(cteParts.joined(separator: ", ")) \(parentDelete)"
    }

    // MARK: - Private

    /// Joined WHERE fragment matching the parent row. Empty-guard is handled
    /// by the caller via `hasPrimaryKeyValues`.
    private var parentWhereClause: String {
        pkValues.map(Self.columnPredicate).joined(separator: " AND ")
    }

    /// One child DELETE per distinct (schema, table) group, wrapped in a CTE
    /// body. Children whose composite FK can't be fully matched against the
    /// parent PK values are skipped so we never emit an incomplete WHERE that
    /// could target unrelated rows.
    private func buildChildDeleteCTEs(fkRows: [[CellValue]]) -> [String] {
        let childMap = groupForeignKeyRows(fkRows)
        var parts: [String] = []
        for (idx, entry) in childMap.enumerated() {
            guard let whereClause = childWhereClause(for: entry.value) else { continue }
            let child = entry.key
            parts.append(
                "del_child\(idx) AS (DELETE FROM \(quoteIdent(child.schema)).\(quoteIdent(child.table)) WHERE \(whereClause))"
            )
        }
        return parts
    }

    /// Collapses FK metadata rows into [(child_schema, child_table): [(childCol, parentCol)]].
    private func groupForeignKeyRows(_ rows: [[CellValue]]) -> [ChildFK: [(childCol: String, parentCol: String)]] {
        var map: [ChildFK: [(childCol: String, parentCol: String)]] = [:]
        for row in rows {
            guard row.count >= 4,
                  case let .text(childSchema) = row[0],
                  case let .text(childTable) = row[1],
                  case let .text(childCol) = row[2],
                  case let .text(parentCol) = row[3]
            else { continue }
            let key = ChildFK(schema: childSchema, table: childTable)
            map[key, default: []].append((childCol: childCol, parentCol: parentCol))
        }
        return map
    }

    /// Returns the composite WHERE clause for a single child, or nil when any
    /// mapping can't be resolved against the parent PK values.
    private func childWhereClause(for mappings: [(childCol: String, parentCol: String)]) -> String? {
        var parts: [String] = []
        for mapping in mappings {
            guard let pk = pkValues.first(where: { $0.column == mapping.parentCol }) else { return nil }
            parts.append(Self.columnPredicate((column: mapping.childCol, value: pk.value)))
        }
        return parts.isEmpty ? nil : parts.joined(separator: " AND ")
    }

    private static func columnPredicate(_ pair: (column: String, value: CellValue)) -> String {
        if pair.value.isNull {
            return "\(quoteIdent(pair.column)) IS NULL"
        }
        return "\(quoteIdent(pair.column)) = \(quoteLiteral(pair.value))"
    }

    private struct ChildFK: Hashable {
        let schema: String
        let table: String
    }
}

/// Per-session application state coordinating a single database connection.
/// Each connection tab/window gets its own AppViewModel instance.
@MainActor
@Observable final class AppViewModel {
    static let defaultQueryTimeout: TimeInterval = 10.0
    static let maxQueryRows = 2000

    @ObservationIgnored let dbClient: any PostgresClientProtocol

    /// Source of the user-configurable query timeout (Settings ▸ SQL Editor).
    /// Injected so tests can supply an ephemeral instance.
    @ObservationIgnored private let editorPreference: EditorPreference

    /// Timeout for user-initiated reads (Run / Explain / content pages).
    /// `0` means no limit. Internal system queries (introspection, DDL) keep
    /// the fixed `defaultQueryTimeout` — they're expected to be fast, and an
    /// unlimited setting shouldn't let them hang the app's metadata loads.
    var userQueryTimeout: TimeInterval {
        TimeInterval(editorPreference.queryTimeoutSeconds)
    }

    let navigatorVM: NavigatorViewModel
    let tableVM: TableViewModel
    let queryVM: QueryViewModel
    let queryHistoryVM: QueryHistoryViewModel
    let erdVM: ERDViewModel

    var selectedTab: MainTab = .query
    var showInspector = true
    var showQueryHistory = false
    var sidebarWidth: CGFloat = SidebarWidthStore.load()
    var isConnected = false
    var connectedProfileName: String?
    var errorMessage: String?
    var cascadeDeleteContext: CascadeDeleteContext?

    /// Open object tabs in the main area's tab strip. Each tab is an
    /// independently navigable view (its own filter, page, sort, content
    /// snapshot). `activeTabId` indicates which tab's state is currently
    /// reflected in `tableVM`; switching tabs swaps `tableVM`'s state.
    var tabs: [ObjectTab] = []
    var activeTabId: UUID?

    /// Maximum number of open object tabs. Each tab's snapshot retains a full
    /// `QueryResult` (rows + columns) plus columns/indexes/constraints/triggers
    /// metadata — visiting dozens of large tables would otherwise pile up
    /// megabytes of String data in `tabs` for the whole session. We trim the
    /// oldest non-active tab when the count exceeds this cap; the most recent
    /// activity always survives.
    static let maxOpenTabs = 12

    // Database-tools sheets (Extensions / Roles / Function Library / Export / Import)
    var showExtensionsSheet = false
    var showRolesSheet = false
    var showFunctionLibrary = false
    var showExportSheet = false
    var showImportSheet = false

    /// Immutable snapshot of the live connection for handing to external tools
    /// (`pg_dump` / `psql`). The endpoint host/port is fetched separately via
    /// `dbClient.currentEndpoint()` because the SSH-tunnel loopback port lives
    /// inside the `DatabaseClient` actor. `nil` when not connected.
    struct LiveConnection: Sendable {
        var profile: ConnectionProfile
        var password: String?
        var sshPassword: String?
    }

    var liveConnection: LiveConnection? {
        guard let connectedProfile else { return nil }
        return LiveConnection(
            profile: connectedProfile,
            password: connectedPassword,
            sshPassword: connectedSSHPassword
        )
    }

    /// Schemas in the connected database, for the export sheet's schema picker.
    /// Lives here (not in the View) so Views never call `dbClient` directly.
    /// Returns an empty list on error — the picker simply shows nothing.
    func schemasForExport() async -> [String] {
        (try? await dbClient.listSchemas()) ?? []
    }

    // MARK: - ERD diagram

    /// Populates the diagram's schema picker from the connected database, and
    /// chooses a sensible default schema (the selected object's schema, else the
    /// first available). Cheap and idempotent — safe to call when the tab opens.
    func refreshDiagramSchemas() async {
        let schemas = (try? await dbClient.listSchemas()) ?? []
        erdVM.availableSchemas = schemas
        if erdVM.selectedSchema == nil || !(schemas.contains(erdVM.selectedSchema ?? "")) {
            erdVM.selectedSchema = navigatorVM.selectedObject?.schema ?? schemas.first
        }
    }

    /// Loads tables, columns, and foreign keys for `schema`, builds the diagram,
    /// applies auto-layout, and pushes it into `erdVM`. Sole `dbClient` caller for
    /// the ERD, mirroring how `selectObject` drives `tableVM`.
    func loadDiagram(schema: String) async {
        guard isConnected else { return }
        erdVM.isLoading = true
        erdVM.errorMessage = nil
        do {
            let tables = try await dbClient.listTables(schema: schema)
            let foreignKeys = try await dbClient.listForeignKeys(schema: schema)

            // Columns per table, fetched concurrently; the actor's column cache
            // keeps this cheap on revisits.
            var columnsByTable: [String: [ColumnInfo]] = [:]
            try await withThrowingTaskGroup(of: (String, [ColumnInfo]).self) { group in
                for table in tables {
                    group.addTask { [dbClient] in
                        (table.name, try await dbClient.getColumns(schema: schema, table: table.name))
                    }
                }
                for try await (name, columns) in group {
                    columnsByTable[name] = columns
                }
            }

            var diagram = ERDDiagram.build(
                schema: schema,
                tables: tables,
                columnsByTable: columnsByTable,
                foreignKeys: foreignKeys
            )
            let positions = ERDLayoutEngine.layout(nodes: diagram.nodes, edges: diagram.edges)
            diagram.nodes = diagram.nodes.map { node in
                var node = node
                node.position = positions[node.id] ?? node.position
                return node
            }

            erdVM.setDiagram(diagram)
            erdVM.selectedSchema = schema
            // Restore the user's saved node arrangement (positions/collapse/hide)
            // if present and sane — but not the viewport, which is always reframed
            // below. A legacy/corrupt layout with off-screen positions is ignored
            // so the fresh bounded auto-layout is shown instead.
            if let profileID = connectedProfile?.id,
               let saved = erdLayoutStore.load(profileID: profileID, schema: schema),
               saved.positionsAreReasonable {
                erdVM.apply(layout: saved)
            }
            // Always frame the whole diagram (no-op until the canvas reports its
            // size, after which the canvas fits it on appear).
            erdVM.fitToViewport()
            erdVM.errorMessage = nil
            Log.ui.info("UI: loaded ERD for schema \(schema, privacy: .public) (\(diagram.nodes.count) tables)")
        } catch {
            erdVM.errorMessage = error.localizedDescription
            Log.ui.error("UI: ERD load failed - \(error.localizedDescription, privacy: .public)")
        }
        erdVM.isLoading = false
    }

    /// Persists the current diagram view state for the active profile + schema.
    /// Called by the canvas after the user moves/collapses/hides a table or
    /// changes the viewport. A no-op when nothing is loaded.
    func saveDiagramLayout() {
        guard let profileID = connectedProfile?.id,
              let schema = erdVM.selectedSchema,
              erdVM.diagram != nil
        else {
            return
        }
        erdLayoutStore.save(erdVM.currentLayout(), profileID: profileID, schema: schema)
    }

    /// Resolves the live connection into the parameters a PostgreSQL client tool
    /// needs: the effective endpoint (loopback port when tunneled) plus the
    /// connection's database/user/SSL and password. `nil` when not connected.
    func toolConnection() async -> (connection: PGToolConnection, password: String?)? {
        guard let live = liveConnection else { return nil }
        let endpoint = await dbClient.currentEndpoint()
        let connection = PGToolConnection(
            host: endpoint?.host ?? live.profile.host,
            port: endpoint?.port ?? live.profile.port,
            database: live.profile.database,
            username: live.profile.username,
            sslMode: live.profile.sslMode
        )
        return (connection, live.password)
    }

    /// Drives the Run/Call sheet for a selected function or procedure. Setting
    /// this to a non-nil value presents the sheet; the sheet clears it on close.
    var functionRunTarget: DBObject?

    /// True when the given object can be invoked via the Run/Call sheet —
    /// drives the visibility of the "Run…" affordances in Navigator + Definition
    /// tab. Aggregates and trigger functions are surfaced but with a disabled
    /// state and explanation, so the menu item is always present (less surprising
    /// than "where did the action go?").
    func isRunnable(_ object: DBObject) -> Bool {
        switch object.type {
        case .function, .procedure: return true
        default: return false
        }
    }

    @ObservationIgnored private var connectedProfile: ConnectionProfile?
    @ObservationIgnored private var connectedPassword: String?
    @ObservationIgnored private var connectedSSHPassword: String?

    /// Persists per-schema ERD layouts to disk. Owned here so Views never touch
    /// storage directly, matching the rule that AppViewModel coordinates I/O.
    @ObservationIgnored private let erdLayoutStore = ERDLayoutStore()

    // While a database switch is in flight the connection pool is torn down
    // and rebuilt; concurrent callers that try to reuse `dbClient` during that
    // window will either hit `notConnected` or land on the wrong database.
    // This flag lets callers detect the state and defer their work.
    @ObservationIgnored private var isSwitchingDatabase = false

    enum MainTab: String, CaseIterable {
        case structure = "Structure"
        case content = "Content"
        case definition = "Definition"
        case query = "Query"
        case diagram = "Diagram"
    }

    init(
        dbClient: any PostgresClientProtocol = DatabaseClient(),
        editorPreference: EditorPreference? = nil
    ) {
        self.dbClient = dbClient
        // Resolved here rather than as a default argument: default arguments
        // evaluate in a nonisolated context, and `.shared` is MainActor-bound.
        self.editorPreference = editorPreference ?? .shared

        self.navigatorVM = NavigatorViewModel()
        self.tableVM = TableViewModel()
        self.queryVM = QueryViewModel()
        self.queryHistoryVM = QueryHistoryViewModel()
        self.erdVM = ERDViewModel()
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
            erdVM.clear() // drop any diagram from a previous connection

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
        erdVM.clear()
        closeAllTabs()
        selectedTab = .query
        Log.ui.info("UI: disconnected")
    }

    func switchDatabase(_ name: String) async {
        guard let profile = connectedProfile, name != profile.database else { return }
        guard !isSwitchingDatabase else {
            Log.ui.info("UI: switchDatabase ignored — another switch in progress")
            return
        }
        isSwitchingDatabase = true
        defer { isSwitchingDatabase = false }
        do {
            try await dbClient.switchDatabase(to: name, profile: profile, password: connectedPassword, sshPassword: connectedSSHPassword)

            var updatedProfile = profile
            updatedProfile.database = name
            connectedProfile = updatedProfile
            navigatorVM.connectedDatabase = name
            closeAllTabs()

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

        guard !isSwitchingDatabase else {
            Log.ui.info("UI: loadDatabaseSchemas ignored — switch in progress")
            return
        }
        isSwitchingDatabase = true
        defer { isSwitchingDatabase = false }

        // Switch to the target database, fetch schemas, then always switch back
        do {
            try await dbClient.switchDatabase(to: dbName, profile: profile, password: connectedPassword, sshPassword: connectedSSHPassword)
            let schemas = try await dbClient.listSchemas()
            navigatorVM.setSchemas(schemas, forDatabase: dbName)
            await loadExpandedSchemaObjects(forDatabase: dbName)
        } catch {
            errorMessage = error.localizedDescription
        }
        // Always switch back to the original database — keep profile, navigator,
        // and table state consistent with the actual connection.
        do {
            try await dbClient.switchDatabase(to: currentDb, profile: profile, password: connectedPassword, sshPassword: connectedSSHPassword)
            var restoredProfile = profile
            restoredProfile.database = currentDb
            connectedProfile = restoredProfile
            navigatorVM.connectedDatabase = currentDb
        } catch {
            errorMessage = "Failed to restore connection to \(currentDb): \(error.localizedDescription)"
        }
    }

    func selectObject(_ object: DBObject) async {
        // Sync-update the model so the List's selection binding returns the
        // new object on its very next read. Without this, the binding's
        // `get` returns the old selection during the brief gap between the
        // setter and the Task body running, which makes the List "roll back"
        // its visual state and collapses parent DisclosureGroups.
        if navigatorVM.selectedObject != object {
            navigatorVM.selectedObject = object
        }

        // De-duplicate: if a tab for this exact object already exists, just
        // activate it. Cached metadata + content are restored from the tab's
        // snapshot — no DB calls needed.
        if let existing = tabs.first(where: { $0.dbObject == object }) {
            activateTab(existing.id)
            adjustSubTabForObjectType(object)
            return
        }
        await openInNewTab(object: object)
    }

    // MARK: - Object Tabs

    /// Opens a fresh tab for `object`, applies the optional pre-built filter
    /// list, loads the object's metadata, and (when the Content sub-tab is
    /// active and the object is queryable) loads its first page of content.
    /// Used by both `selectObject` for first-time opens and
    /// `navigateForeignKey` for FK jumps that need to land filtered.
    func openInNewTab(object: DBObject, filters: [ContentFilter]? = nil) async {
        // An in-flight load belongs to the outgoing tab; let it die rather
        // than write the old tab's rows into the one we're about to open.
        invalidateContentLoads()
        snapshotIntoActiveTab()

        var tab = ObjectTab(dbObject: object, pageSize: tableVM.pageSize)
        if let filters, !filters.isEmpty {
            tab.filters = filters
            tab.showFilterBar = true
        }
        tabs.append(tab)
        activeTabId = tab.id
        trimOldestNonActiveTab()

        // Hydrate tableVM into the new tab's initial empty state. Restoring
        // an empty tab clears stale columns/contentResult from the previous
        // tab without snapshotting them again.
        tableVM.clear()
        tableVM.filters = tab.filters
        tableVM.showFilterBar = tab.showFilterBar
        tableVM.selectedObjectName = object.name
        if navigatorVM.selectedObject != object {
            navigatorVM.selectedObject = object
        }
        adjustSubTabForObjectType(object)

        await loadObjectMetadata(object)

        // Now that columns are loaded, materialize the WHERE clause for any
        // pre-supplied filters (FK navigation uses this path).
        if let filters, !filters.isEmpty {
            tableVM.activeFilterSQL = filters.compactMap { buildFilterCondition($0, columns: tableVM.columns) }
                .joined(separator: " AND ")
        }

        snapshotIntoActiveTab()

        if selectedTab == .content, object.type.hasQueryableContent {
            await loadContentPage()
            snapshotIntoActiveTab()
        }
    }

    /// Activates an existing tab without any DB calls — the swap is purely an
    /// in-memory state move from the outgoing tab's snapshot into `tableVM`.
    func activateTab(_ id: UUID) {
        guard activeTabId != id else { return }
        guard let tab = tabs.first(where: { $0.id == id }) else { return }
        invalidateContentLoads()
        snapshotIntoActiveTab()
        activeTabId = id
        restoreFromTab(tab)
    }

    /// Closes a tab. When closing the active tab, activates the neighbor to
    /// the right (or to the left if it's the rightmost). When the last tab
    /// closes, clears `tableVM`, drops the navigator selection, and falls
    /// back to the Query sub-tab — the only one that doesn't require an
    /// object.
    func closeTab(_ id: UUID) {
        guard let idx = tabs.firstIndex(where: { $0.id == id }) else { return }
        let wasActive = (activeTabId == id)
        tabs.remove(at: idx)
        guard wasActive else { return }
        invalidateContentLoads()
        if tabs.isEmpty {
            activeTabId = nil
            tableVM.clear()
            navigatorVM.selectedObject = nil
            selectedTab = .query
            return
        }
        let newIdx = min(idx, tabs.count - 1)
        let neighbor = tabs[newIdx]
        activeTabId = neighbor.id
        restoreFromTab(neighbor)
    }

    /// Closes every tab and resets the main area. Called on disconnect and
    /// database switch — tab state is bound to the connection.
    func closeAllTabs() {
        invalidateContentLoads()
        tabs.removeAll()
        activeTabId = nil
        tableVM.clear()
        navigatorVM.selectedObject = nil
    }

    /// Drops the oldest tab when `tabs.count` exceeds `maxOpenTabs`. The active
    /// tab is exempt — losing the *current* tab while the user is working in it
    /// would be jarring. Each tab snapshot can carry megabytes of `QueryResult`
    /// String data, so this keeps a long browsing session from accumulating
    /// retention forever.
    private func trimOldestNonActiveTab() {
        while tabs.count > Self.maxOpenTabs {
            guard let victim = tabs.firstIndex(where: { $0.id != activeTabId }) else { break }
            tabs.remove(at: victim)
        }
    }

    /// Writes the currently-displayed `tableVM` state into the active tab's
    /// snapshot. No-op when there is no active tab (e.g., before any object
    /// has been opened).
    private func snapshotIntoActiveTab() {
        guard let activeTabId else { return }
        guard let idx = tabs.firstIndex(where: { $0.id == activeTabId }) else { return }
        var tab = tabs[idx]
        tab.contentResult = tableVM.contentResult
        tab.columns = tableVM.columns
        tab.constraints = tableVM.constraints
        tab.indexes = tableVM.indexes
        tab.triggers = tableVM.triggers
        tab.partitions = tableVM.partitions
        tab.currentPage = tableVM.currentPage
        tab.pageSize = tableVM.pageSize
        tab.approximateRowCount = tableVM.approximateRowCount
        tab.sortColumn = tableVM.sortColumn
        tab.sortAscending = tableVM.sortAscending
        tab.filters = tableVM.filters
        tab.activeFilterSQL = tableVM.activeFilterSQL
        tab.selectedRowIndex = tableVM.selectedRowIndex
        tab.showFilterBar = tableVM.showFilterBar
        tabs[idx] = tab
    }

    private func restoreFromTab(_ tab: ObjectTab) {
        tableVM.setColumns(tab.columns)
        tableVM.contentResult = tab.contentResult
        tableVM.constraints = tab.constraints
        tableVM.indexes = tab.indexes
        tableVM.triggers = tab.triggers
        tableVM.partitions = tab.partitions
        tableVM.currentPage = tab.currentPage
        tableVM.pageSize = tab.pageSize
        tableVM.approximateRowCount = tab.approximateRowCount
        tableVM.sortColumn = tab.sortColumn
        tableVM.sortAscending = tab.sortAscending
        tableVM.filters = tab.filters
        tableVM.activeFilterSQL = tab.activeFilterSQL
        tableVM.selectedRowIndex = tab.selectedRowIndex
        tableVM.showFilterBar = tab.showFilterBar
        tableVM.selectedObjectName = tab.dbObject.name
        tableVM.selectedObjectColumnCount = tab.columns.count
        if navigatorVM.selectedObject != tab.dbObject {
            navigatorVM.selectedObject = tab.dbObject
        }
    }

    private func adjustSubTabForObjectType(_ object: DBObject) {
        // If no object-specific tab is active, switch to an appropriate tab.
        if selectedTab == .query {
            switch object.type {
            case .table:
                selectedTab = .structure
            default:
                selectedTab = .definition
            }
        }
        // The Content tab only works for relations. Selecting a type, function,
        // or other non-relation while Content is active would otherwise issue
        // SELECT * FROM <type> and fail with "cannot open relation".
        if selectedTab == .content, !object.type.hasQueryableContent {
            selectedTab = .definition
        }
    }

    /// Loads columns, row count, and per-table extras for the active tab's
    /// object. Errors land in `errorMessage` rather than throwing so a single
    /// missing catalog query doesn't abandon the whole open.
    private func loadObjectMetadata(_ object: DBObject) async {
        do {
            let columns = try await dbClient.getColumns(
                schema: object.schema,
                table: object.name
            )
            tableVM.setColumns(columns)
            tableVM.selectedObjectColumnCount = columns.count

            // getApproximateRowCount falls back to SELECT COUNT(*) when
            // pg_class.reltuples is -1 (no ANALYZE yet). That fallback errors
            // for non-relation objects (composite types, sequences, …) with
            // "cannot open relation". Skip the lookup entirely there — there
            // are no rows to report anyway.
            if object.type.hasQueryableContent {
                let approxRows = try await dbClient.getApproximateRowCount(
                    schema: object.schema,
                    table: object.name
                )
                tableVM.approximateRowCount = approxRows
            } else {
                tableVM.approximateRowCount = 0
            }

            // Fetch per-table extras only for tables / partitioned tables; views
            // and other object types don't have these in a meaningful way.
            if object.type == .table {
                async let idx = dbClient.listIndexes(schema: object.schema, table: object.name)
                async let cons = dbClient.listConstraints(schema: object.schema, table: object.name)
                async let trg = dbClient.listTriggers(schema: object.schema, table: object.name)
                async let parts = dbClient.listPartitions(schema: object.schema, table: object.name)
                do {
                    tableVM.indexes = try await idx
                    tableVM.constraints = try await cons
                    tableVM.triggers = try await trg
                    tableVM.partitions = try await parts
                } catch {
                    errorMessage = error.localizedDescription
                }
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
            navigatorVM.setSchemaObjects(db: db, schema: schema, objects: objects)
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
                let parts = key.split(separator: NavigatorViewModel.keySeparator, maxSplits: 1)
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

    /// The in-flight content page load started by `reloadContentPage`.
    /// Tracked so rapid filter/sort/pagination actions cancel the previous
    /// fetch instead of racing it.
    @ObservationIgnored private var contentLoadTask: Task<Void, Never>?

    /// Monotonic token identifying the latest content load. Loads compare
    /// their captured token before writing into `tableVM`, so a stale fetch
    /// (superseded by a newer one, or finishing after a tab switch) can't
    /// overwrite the state the user is now looking at.
    @ObservationIgnored private var contentLoadGeneration = 0

    /// Fire-and-forget entry point for content reloads (filters, sorting,
    /// pagination, page-size changes). Cancels any in-flight load first.
    func reloadContentPage() {
        contentLoadTask?.cancel()
        contentLoadTask = Task { await loadContentPage() }
    }

    /// Invalidates any in-flight content load. Called on tab switches and
    /// closes: the load belongs to the *previous* tab's state, and letting it
    /// complete would write that tab's rows into the newly activated one.
    private func invalidateContentLoads() {
        contentLoadTask?.cancel()
        contentLoadTask = nil
        contentLoadGeneration &+= 1
    }

    func loadContentPage() async {
        guard let object = navigatorVM.selectedObject else { return }
        // Defensive: callers (ContentTabView .task / .onChange, pagination,
        // post-edit refresh) should already gate on this, but a stray call
        // for a type / function / sequence would surface a confusing
        // "cannot open relation" from PG.
        guard object.type.hasQueryableContent else { return }

        contentLoadGeneration &+= 1
        let generation = contentLoadGeneration

        let schema = quoteIdent(object.schema)
        let table = quoteIdent(object.name)
        let limit = tableVM.pageSize
        let offset = tableVM.currentPage * tableVM.pageSize

        var sql = "SELECT * FROM \(schema).\(table)"
        if let filterSQL = tableVM.activeFilterSQL {
            sql += " WHERE \(filterSQL)"
        }
        if let sortCol = tableVM.sortColumn {
            let dir = tableVM.sortAscending ? "ASC" : "DESC"
            sql += " ORDER BY \(quoteIdent(sortCol)) \(dir) NULLS LAST"
        }
        sql += " LIMIT \(limit) OFFSET \(offset)"

        do {
            tableVM.isLoadingContent = true
            var result = try await dbClient.runQuery(sql, maxRows: limit, timeout: userQueryTimeout)
            guard generation == contentLoadGeneration else { return }

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

            queryHistoryVM.logQuery(
                sql: sql,
                source: .system,
                duration: result.executionTime,
                success: true,
                rowCount: result.rowCount
            )
        } catch is CancellationError {
            // Superseded by a newer load or a tab switch — the newer owner
            // controls the spinner unless this was the latest load.
            if generation == contentLoadGeneration {
                tableVM.isLoadingContent = false
            }
        } catch {
            guard generation == contentLoadGeneration else { return }
            tableVM.isLoadingContent = false
            errorMessage = error.localizedDescription

            queryHistoryVM.logQuery(
                sql: sql,
                source: .system,
                success: false,
                errorMessage: error.localizedDescription
            )
        }
    }

    func selectRow(index: Int, columns: [String], values: [CellValue]) {
        // Short-circuit when the user re-clicks the same row that's already
        // selected — the AppKit grid fires this on every click whether the
        // selection changed or not, and rebuilding the row-data array (plus
        // the observation churn it kicks off in InspectorView) was visible
        // when the Inspector was open on wide tables.
        if tableVM.selectedRowIndex == index,
           let existing = tableVM.selectedRowData,
           existing.count == columns.count,
           zip(existing, values).allSatisfy({ $0.value == $1 })
        {
            return
        }
        tableVM.selectedRowIndex = index
        var rowData: [(column: String, value: CellValue)] = []
        rowData.reserveCapacity(columns.count)
        for (col, val) in zip(columns, values) {
            rowData.append((column: col, value: val))
        }
        tableVM.selectedRowData = rowData
    }

    func clearSelectedRow() {
        tableVM.selectedRowIndex = nil
        tableVM.selectedRowData = nil
    }

    /// The in-flight Run/Explain task. Tracked so the Stop button (and a
    /// rapid re-run) can cancel it instead of letting it race the next one.
    @ObservationIgnored private var queryTask: Task<Void, Never>?

    /// Monotonic token identifying the latest Run/Explain. Awaited completions
    /// compare their captured token against this before touching `queryVM`, so
    /// a superseded run can't clobber the newer run's state.
    @ObservationIgnored private var queryGeneration = 0

    /// Run the editor's query as a tracked, cancellable task. UI entry point —
    /// `executeQuery` stays awaitable for tests and internal callers.
    func runQueryAction(_ sql: String) {
        queryTask?.cancel()
        queryTask = Task { await executeQuery(sql) }
    }

    /// Explain/Analyze as a tracked, cancellable task, mirroring `runQueryAction`.
    func runExplainAction(_ sql: String, analyze: Bool) {
        queryTask?.cancel()
        queryTask = Task { await explainQuery(sql, analyze: analyze) }
    }

    /// Stop button: cancels the in-flight Run/Explain. The server-side
    /// `statement_timeout` still applies as a backstop where configured.
    func cancelRunningQuery() {
        queryTask?.cancel()
    }

    func executeQuery(_ sql: String) async {
        guard !sql.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }

        queryGeneration += 1
        let generation = queryGeneration

        queryVM.isExecuting = true
        queryVM.errorMessage = nil
        queryVM.result = nil
        queryVM.invalidateSortCache()
        queryVM.editableTableContext = nil
        queryVM.editableColumns = []
        queryVM.deleteConfirmationRowIndex = nil
        clearSelectedRow()

        do {
            var result = try await dbClient.runQuery(sql, maxRows: Self.maxQueryRows, timeout: userQueryTimeout)
            guard generation == queryGeneration else { return }

            // Detect table context for inline editing and resolve empty columns
            if let tableRef = queryVM.parseTableFromQuery() {
                do {
                    let columns = try await dbClient.getColumns(schema: tableRef.schema, table: tableRef.table)
                    guard generation == queryGeneration else { return }

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

            queryHistoryVM.logQuery(
                sql: sql,
                source: .manual,
                duration: result.executionTime,
                success: true,
                rowCount: result.rowCount
            )
        } catch is CancellationError {
            // User pressed Stop (or started a newer run). Not a failure —
            // clear the spinner only if no newer run owns it.
            queryHistoryVM.logQuery(
                sql: sql,
                source: .manual,
                success: false,
                errorMessage: "Cancelled"
            )
            guard generation == queryGeneration else { return }
            queryVM.isExecuting = false
        } catch {
            guard generation == queryGeneration else { return }
            queryVM.errorMessage = error.localizedDescription
            queryVM.isExecuting = false

            queryHistoryVM.logQuery(
                sql: sql,
                source: .manual,
                success: false,
                errorMessage: error.localizedDescription
            )
        }
    }

    /// Runs `EXPLAIN [ANALYZE]` on the current query and stores the parsed
    /// plan on `queryVM`. Switches the results area to the EXPLAIN tab so the
    /// new plan is visible immediately. ANALYZE actually executes the query;
    /// the caller is responsible for any DML confirmation.
    func explainQuery(_ sql: String, analyze: Bool) async {
        let trimmed = sql.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        queryGeneration += 1
        let generation = queryGeneration

        queryVM.isExecuting = true
        queryVM.errorMessage = nil
        queryVM.plan = nil
        queryVM.activeResultsTab = .explain

        // ANALYZE actually executes the query, so give it extra headroom over
        // the plain-EXPLAIN planning round trip. 0 stays 0 (no limit).
        let timeout = userQueryTimeout
        let explainTimeout = analyze ? timeout * 3 : timeout

        do {
            let plan = try await dbClient.explainQuery(
                trimmed,
                analyze: analyze,
                buffers: analyze,
                timeout: explainTimeout
            )
            guard generation == queryGeneration else { return }
            queryVM.plan = plan
            queryVM.isExecuting = false

            queryHistoryVM.logQuery(
                sql: (analyze ? "EXPLAIN ANALYZE " : "EXPLAIN ") + trimmed,
                source: .manual,
                duration: plan.executionTime.map { $0 / 1000 } ?? 0,
                success: true,
                rowCount: 0
            )
        } catch is CancellationError {
            queryHistoryVM.logQuery(
                sql: (analyze ? "EXPLAIN ANALYZE " : "EXPLAIN ") + trimmed,
                source: .manual,
                success: false,
                errorMessage: "Cancelled"
            )
            guard generation == queryGeneration else { return }
            queryVM.isExecuting = false
        } catch {
            guard generation == queryGeneration else { return }
            queryVM.errorMessage = error.localizedDescription
            queryVM.isExecuting = false
            queryHistoryVM.logQuery(
                sql: (analyze ? "EXPLAIN ANALYZE " : "EXPLAIN ") + trimmed,
                source: .manual,
                success: false,
                errorMessage: error.localizedDescription
            )
        }
    }

    // MARK: - Content Filters

    /// Keeps only filters that contribute to the WHERE clause, then builds each
    /// into a SQL fragment. Shared by `applyContentFilters` and `previewFilterSQL`
    /// so both see the exact same validation rules.
    private func validFilterConditions() -> [String] {
        let validFilters = tableVM.filters.filter { f in
            if f.op == .isNull || f.op == .isNotNull { return true }
            return !f.value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        return validFilters.compactMap { buildFilterCondition($0, columns: tableVM.columns) }
    }

    func applyContentFilters() {
        let conditions = validFilterConditions()
        guard !conditions.isEmpty else {
            clearContentFilters()
            return
        }

        tableVM.activeFilterSQL = conditions.joined(separator: " AND ")
        tableVM.currentPage = 0
        clearSelectedRow()
        reloadContentPage()
    }

    func clearContentFilters() {
        tableVM.activeFilterSQL = nil
        tableVM.filters = [ContentFilter()]
        tableVM.currentPage = 0
        clearSelectedRow()
        reloadContentPage()
    }

    // MARK: - Foreign Key Navigation

    /// Follows a foreign key from the given row in the current Content result
    /// to the referenced table. Selects the target object in the navigator,
    /// installs an equality filter on each `(referencedColumn, value)` pair,
    /// switches to the Content tab, and reloads. Aborts silently when any
    /// source column is NULL (no row can match) or when `fk` is not a foreign
    /// key constraint.
    func navigateForeignKey(fromRow row: [CellValue], fk: ConstraintInfo) async {
        guard fk.kind == .foreignKey,
              let refTable = fk.referencedTable,
              !fk.columns.isEmpty,
              fk.columns.count == fk.referencedColumns.count,
              let result = tableVM.contentResult
        else { return }

        let (targetSchema, targetName) = Self.splitQualifiedName(refTable)

        var filters: [ContentFilter] = []
        for (sourceCol, refCol) in zip(fk.columns, fk.referencedColumns) {
            guard let idx = result.columns.firstIndex(of: sourceCol) else { return }
            let cell = row[idx]
            if cell.isNull { return }
            filters.append(ContentFilter(column: refCol, op: .equals, value: cell.displayString))
        }
        guard !filters.isEmpty else { return }

        let target = DBObject(schema: targetSchema, name: targetName, type: .table)
        // FK navigation always opens a fresh tab so the source row remains
        // available behind it — that's the whole point of "jump to and easy
        // return". `openInNewTab` handles filter installation atomically with
        // the metadata + content load.
        selectedTab = .content
        clearSelectedRow()
        await openInNewTab(object: target, filters: filters)
    }

    /// Splits "schema.table" into its parts. `referencedTable` is always a
    /// `pg_class.relname` joined to `pg_namespace.nspname` in `listConstraints`
    /// so a single dot is the only separator; identifiers with embedded dots
    /// would have been quoted upstream.
    private static func splitQualifiedName(_ qualified: String) -> (schema: String, name: String) {
        if let dot = qualified.firstIndex(of: ".") {
            return (String(qualified[..<dot]), String(qualified[qualified.index(after: dot)...]))
        }
        return ("public", qualified)
    }

    func previewFilterSQL() -> String {
        let conditions = validFilterConditions()
        guard !conditions.isEmpty else { return "-- no active filters" }
        return "WHERE " + conditions.joined(separator: "\n  AND ")
    }

    /// Escapes a value for use inside a LIKE/ILIKE pattern. Backslash and
    /// single-quote get doubled for the E'…' string literal; `%` and `_` are
    /// escaped so they aren't interpreted as wildcards.
    private static func escapeLikePattern(_ val: String) -> String {
        val.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "'", with: "''")
            .replacingOccurrences(of: "%", with: "\\%")
            .replacingOccurrences(of: "_", with: "\\_")
    }

    private func buildFilterCondition(_ filter: ContentFilter, columns: [ColumnInfo]) -> String? {
        let val = filter.value.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !filter.column.isEmpty else {
            return buildAnyColumnCondition(op: filter.op, value: val, columns: columns)
        }

        let col = quoteIdent(filter.column)
        let escaped = Self.escapeLikePattern(val)

        switch filter.op {
        case .contains: return "\(col)::text ILIKE E'%\(escaped)%'"
        case .equals: return "\(col)::text = \(quoteLiteral(.text(val)))"
        case .notEquals: return "\(col)::text != \(quoteLiteral(.text(val)))"
        case .greaterThan: return "\(col)::text > \(quoteLiteral(.text(val)))"
        case .lessThan: return "\(col)::text < \(quoteLiteral(.text(val)))"
        case .greaterOrEqual: return "\(col)::text >= \(quoteLiteral(.text(val)))"
        case .lessOrEqual: return "\(col)::text <= \(quoteLiteral(.text(val)))"
        case .startsWith: return "\(col)::text ILIKE E'\(escaped)%'"
        case .endsWith: return "\(col)::text ILIKE E'%\(escaped)'"
        case .isNull: return "\(col) IS NULL"
        case .isNotNull: return "\(col) IS NOT NULL"
        }
    }

    /// "Any Column" — search across all text-castable columns.
    /// Note: casting every column to ::text forces a sequential scan on
    /// the server; this is intentional for quick ad-hoc filtering but
    /// won't use indexes.
    private func buildAnyColumnCondition(op: FilterOperator, value: String, columns: [ColumnInfo]) -> String? {
        guard op != .isNull, op != .isNotNull else { return nil }
        let colExprs = columns.map { quoteIdent($0.name) + "::text" }
        guard !colExprs.isEmpty else { return nil }

        let parts: [String]
        switch op {
        case .equals:
            parts = colExprs.map { "\($0) = \(quoteLiteral(.text(value)))" }
        default:
            // Every non-equals op for "Any Column" falls back to ILIKE %val%.
            let likeVal = Self.escapeLikePattern(value)
            parts = colExprs.map { "\($0) ILIKE E'%\(likeVal)%'" }
        }
        return "(" + parts.joined(separator: " OR ") + ")"
    }

    func toggleContentSort(column: String) {
        applySort(column: column, currentColumn: &tableVM.sortColumn, ascending: &tableVM.sortAscending)
        tableVM.currentPage = 0
        clearSelectedRow()
        reloadContentPage()
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

    /// Outcome of a single-row mutation. Lets callers decide whether to refresh
    /// page data, raise cascade-delete UI, or surface an inline error without
    /// duplicating the run/log/catch boilerplate.
    enum RowMutationOutcome {
        case success
        case foreignKeyViolation(String)
        case error(String)
    }

    /// Runs a row-mutation SQL statement, logs to history, and classifies the
    /// outcome so callers can branch on FK-violation vs generic failure.
    /// Internal so `AppViewModel+ObjectCRUD.swift` can reuse it for DDL ops.
    func performRowMutation(sql: String) async -> RowMutationOutcome {
        do {
            _ = try await dbClient.runQuery(sql, maxRows: 0, timeout: Self.defaultQueryTimeout)
            queryHistoryVM.logQuery(sql: sql, source: .system, success: true)
            return .success
        } catch let error as AppError {
            queryHistoryVM.logQuery(sql: sql, source: .system, success: false, errorMessage: error.localizedDescription)
            if case let .foreignKeyViolation(msg) = error {
                return .foreignKeyViolation(msg)
            }
            return .error(error.localizedDescription)
        } catch {
            queryHistoryVM.logQuery(sql: sql, source: .system, success: false, errorMessage: error.localizedDescription)
            return .error(error.localizedDescription)
        }
    }

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

        switch await performRowMutation(sql: sql) {
        case .success:
            tableVM.contentResult = result.replacingCell(row: rowIndex, column: columnIndex, with: newValue)
        case .foreignKeyViolation(let msg), .error(let msg):
            errorMessage = msg
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

        switch await performRowMutation(sql: sql) {
        case .success:
            queryVM.result = result.replacingCell(row: actualRowIndex, column: columnIndex, with: newValue)
            queryVM.invalidateSortCache()
        case .foreignKeyViolation(let msg), .error(let msg):
            errorMessage = msg
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

    /// Collects PK column name → original row value pairs. `nil` if any PK is
    /// missing from the result columns (composite-PK safety guard).
    private static func collectPKValues(
        pkColumns: [ColumnInfo],
        resultColumns: [String],
        originalRow: [CellValue]
    ) -> [(column: String, value: CellValue)] {
        pkColumns.compactMap { pk in
            guard let idx = resultColumns.firstIndex(of: pk.name) else { return nil }
            return (column: pk.name, value: originalRow[idx])
        }
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

        switch await performRowMutation(sql: sql) {
        case .success:
            clearSelectedRow()
            do {
                let approxRows = try await dbClient.getApproximateRowCount(
                    schema: object.schema, table: object.name
                )
                tableVM.approximateRowCount = approxRows
            } catch {
                errorMessage = error.localizedDescription
            }
            await loadContentPage()
        case .foreignKeyViolation(let msg):
            cascadeDeleteContext = CascadeDeleteContext(
                schema: object.schema,
                table: object.name,
                pkValues: Self.collectPKValues(pkColumns: pkColumns, resultColumns: result.columns, originalRow: originalRow),
                errorMessage: msg,
                source: .content
            )
        case .error(let msg):
            errorMessage = msg
        }
    }

    func deleteQueryRow(rowIndex: Int) async {
        guard let tableRef = queryVM.editableTableContext,
              let result = queryVM.result
        else { return }

        let pkColumns = queryVM.editableColumns.filter { $0.isPrimaryKey }
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

        switch await performRowMutation(sql: sql) {
        case .success:
            clearSelectedRow()
            await executeQuery(queryVM.queryText)
        case .foreignKeyViolation(let msg):
            cascadeDeleteContext = CascadeDeleteContext(
                schema: tableRef.schema,
                table: tableRef.table,
                pkValues: Self.collectPKValues(pkColumns: pkColumns, resultColumns: result.columns, originalRow: originalRow),
                errorMessage: msg,
                source: .query
            )
        case .error(let msg):
            errorMessage = msg
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
            queryHistoryVM.logQuery(sql: sql, source: .system, success: true)
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
            queryHistoryVM.logQuery(sql: sql, source: .system, success: false, errorMessage: error.localizedDescription)
            // Keep insert row visible so user can fix values
            errorMessage = error.localizedDescription
        }
    }

    func cancelInsertRow() {
        tableVM.isInsertingRow = false
        tableVM.newRowValues = [:]
    }

    /// Returns a pre-filled default value for date/time/timestamp columns,
    /// or an empty string for all other types. Uses ISO8601 style with a
    /// space date/time separator — the format PostgreSQL accepts natively.
    /// Time zone is intentionally the user's local TZ so the pre-filled value
    /// matches what they see on-screen.
    ///
    /// `dataType` is expected to be an `information_schema.columns.data_type`
    /// value (e.g. "timestamp with time zone"), so we match on the exact
    /// canonical names rather than substring heuristics.
    private func defaultInsertValue(for dataType: String, now: Date) -> String {
        guard let kind = TemporalColumnKind(informationSchemaDataType: dataType) else { return "" }
        let tz = TimeZone.current

        switch kind {
        case .timestamp, .timestampTZ:
            let dateStyle = Date.ISO8601FormatStyle(timeZone: tz)
                .year().month().day()
                .dateSeparator(.dash)
                .dateTimeSeparator(.space)
                .time(includingFractionalSeconds: false)
            return kind == .timestampTZ
                ? now.formatted(dateStyle.timeZone(separator: .colon))
                : now.formatted(dateStyle)
        case .date:
            return now.formatted(
                Date.ISO8601FormatStyle(timeZone: tz)
                    .year().month().day()
                    .dateSeparator(.dash)
            )
        case .time, .timeTZ:
            // PG time has no date component. Derive HH:mm:ss from the ISO string
            // — simpler than importing Formatter for the clock portion alone.
            let full = now.formatted(
                Date.ISO8601FormatStyle(timeZone: tz)
                    .year().month().day()
                    .dateSeparator(.dash)
                    .dateTimeSeparator(.space)
                    .time(includingFractionalSeconds: false)
            )
            let timePart = full.split(separator: " ").dropFirst().first.map(String.init) ?? ""
            guard kind == .timeTZ else { return timePart }
            let hours = tz.secondsFromGMT() / 3600
            let minutes = abs(tz.secondsFromGMT() / 60) % 60
            let sign = hours >= 0 ? "+" : "-"
            return String(format: "\(timePart)\(sign)%02d:%02d", abs(hours), minutes)
        }
    }

    /// Canonical information_schema.columns.data_type values for temporal types.
    private enum TemporalColumnKind {
        case timestamp, timestampTZ, date, time, timeTZ

        init?(informationSchemaDataType: String) {
            switch informationSchemaDataType.lowercased() {
            case "timestamp without time zone": self = .timestamp
            case "timestamp with time zone": self = .timestampTZ
            case "date": self = .date
            case "time without time zone": self = .time
            case "time with time zone": self = .timeTZ
            default: return nil
            }
        }
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

        let builder = CascadeDeleteBuilder(schema: ctx.schema, table: ctx.table, pkValues: ctx.pkValues)
        guard builder.hasPrimaryKeyValues else {
            errorMessage = "Cannot cascade delete: no primary key values"
            return
        }

        do {
            let fkResult = try await dbClient.runQuery(
                builder.foreignKeyMetadataSQL,
                maxRows: 5000,
                timeout: Self.defaultQueryTimeout
            )
            if fkResult.isTruncated {
                errorMessage = "Too many foreign key relationships to cascade delete safely."
                return
            }

            let deleteSQL = builder.makeDeleteSQL(from: fkResult.rows)

            // PostgresNIO's extended query protocol cannot execute multiple
            // statements in one call — sending "BEGIN; DELETE …; COMMIT;" as a
            // single string silently fails. Issue each statement separately
            // and roll back if the DELETE fails.
            _ = try await dbClient.runQuery("BEGIN", maxRows: 0, timeout: Self.defaultQueryTimeout)
            do {
                _ = try await dbClient.runQuery(deleteSQL, maxRows: 0, timeout: Self.defaultQueryTimeout)
                _ = try await dbClient.runQuery("COMMIT", maxRows: 0, timeout: Self.defaultQueryTimeout)
            } catch {
                _ = try? await dbClient.runQuery("ROLLBACK", maxRows: 0, timeout: Self.defaultQueryTimeout)
                throw error
            }
            queryHistoryVM.logQuery(sql: deleteSQL, source: .system, success: true)
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
        if !defaultValue.isEmpty {
            guard isValidSQLExpression(defaultValue) else {
                errorMessage = "Invalid default value expression"
                return
            }
            sql += " DEFAULT \(defaultValue)"
        }
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
        if !newDefault.isEmpty {
            guard isValidSQLExpression(newDefault) else {
                errorMessage = "Invalid default value expression"
                return
            }
        }
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
        for col in columns where !col.defaultValue.isEmpty {
            guard isValidSQLExpression(col.defaultValue) else {
                errorMessage = "Invalid default value for column '\(col.name)'"
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

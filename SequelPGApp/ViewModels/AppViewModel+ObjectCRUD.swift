import Foundation

extension AppViewModel {
    /// Simple `DROP <keyword> schema.name CASCADE` keywords by object type.
    /// Function-like types and operators need special handling and aren't in this table.
    private static let simpleDropKeyword: [DBObjectType: String] = [
        .table: "TABLE",
        .view: "VIEW",
        .materializedView: "MATERIALIZED VIEW",
        .sequence: "SEQUENCE",
        .type: "TYPE",
        .domain: "DOMAIN",
        .collation: "COLLATION",
        .foreignTable: "FOREIGN TABLE",
        .ftsConfiguration: "TEXT SEARCH CONFIGURATION",
        .ftsDictionary: "TEXT SEARCH DICTIONARY",
        .ftsParser: "TEXT SEARCH PARSER",
        .ftsTemplate: "TEXT SEARCH TEMPLATE",
    ]

    /// Drops any database object with confirmation already handled by the caller.
    /// Functions, procedures, aggregates, and operators are resolved and dropped
    /// by `DatabaseClient.dropOverloadableObject`, which matches the navigator
    /// name against pg_catalog so overloads and hostile names can't misfire.
    func dropObject(_ object: DBObject) async {
        let db = navigatorVM.connectedDatabase
        var dropSQL: String?
        do {
            if let keyword = Self.simpleDropKeyword[object.type] {
                let sql = "DROP \(keyword) \(quoteIdent(object.schema)).\(quoteIdent(object.name)) CASCADE"
                dropSQL = sql
                _ = try await dbClient.runQuery(sql, maxRows: 0, timeout: Self.defaultQueryTimeout)
            } else {
                dropSQL = try await dbClient.dropOverloadableObject(object, timeout: Self.defaultQueryTimeout)
            }
        } catch {
            if let dropSQL {
                queryHistoryVM.logQuery(sql: dropSQL, source: .system, success: false, errorMessage: error.localizedDescription)
            }
            errorMessage = error.localizedDescription
            return
        }

        if let dropSQL {
            queryHistoryVM.logQuery(sql: dropSQL, source: .system, success: true)
        }
        await dbClient.invalidateCache()
        // The user may have moved on while the DROP ran: only clear a selection
        // that still points at the dropped object, and only reload the tree if
        // it still shows the database the object lived in.
        if navigatorVM.selectedObject == object {
            navigatorVM.selectedObject = nil
        }
        navigatorVM.invalidateSchema(db: db, schema: object.schema)
        if navigatorVM.connectedDatabase == db {
            await loadSchemaObjects(db: db, schema: object.schema)
        }
    }

    /// Executes a CREATE statement and refreshes the navigator.
    func executeCreateSQL(_ sql: String, inSchema schema: String) async {
        do {
            _ = try await dbClient.runQuery(sql, maxRows: 0, timeout: Self.defaultQueryTimeout)
            queryHistoryVM.logQuery(sql: sql, source: .system, success: true)
            await dbClient.invalidateCache()
            let db = navigatorVM.connectedDatabase
            navigatorVM.invalidateSchema(db: db, schema: schema)
            await loadSchemaObjects(db: db, schema: schema)
        } catch {
            queryHistoryVM.logQuery(sql: sql, source: .system, success: false, errorMessage: error.localizedDescription)
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - Table / Materialized View operations

    /// Maintenance operations that can be applied to a table or materialized view
    /// from the navigator context menu. Each case carries its display name so
    /// the menu stays declarative.
    enum MaintenanceOp: String, CaseIterable, Identifiable {
        case truncate = "Truncate"
        case vacuum = "Vacuum"
        case vacuumFull = "Vacuum Full"
        case analyze = "Analyze"
        case refreshMatView = "Refresh"
        case refreshMatViewConcurrently = "Refresh Concurrently"

        var id: String { rawValue }

        var confirmationMessage: String? {
            switch self {
            case .truncate:
                return "TRUNCATE removes all rows and cannot be undone. Continue?"
            case .vacuumFull:
                return "VACUUM FULL rewrites the entire table and holds an ACCESS EXCLUSIVE lock for the duration. Continue?"
            default:
                return nil
            }
        }

        // Vacuum variants cannot run inside a transaction block; in general
        // these all issue a single DDL/utility statement so they execute with
        // a generous timeout. Return nil to keep the default.
        var timeoutOverride: TimeInterval? {
            switch self {
            case .vacuum, .vacuumFull, .analyze, .refreshMatView, .refreshMatViewConcurrently:
                return 300
            default:
                return nil
            }
        }
    }

    // MARK: - Index / Constraint / Trigger ops

    /// Creates an index on the currently-selected table using the provided SQL
    /// (emitted by `IndexCreateSheet`). Refreshes the per-table metadata so
    /// the new index appears immediately.
    func createIndex(sql: String) async {
        guard let object = navigatorVM.selectedObject else { return }
        switch await performRowMutation(sql: sql) {
        case .success:
            await refreshSelectedTableMetadata(schema: object.schema, table: object.name)
        case .foreignKeyViolation(let msg), .error(let msg):
            errorMessage = msg
        }
    }

    func dropIndex(_ index: IndexInfo) async {
        let sql = "DROP INDEX \(quoteIdent(index.schema)).\(quoteIdent(index.name))"
        switch await performRowMutation(sql: sql) {
        case .success:
            await refreshSelectedTableMetadata(schema: index.schema, table: index.table)
        case .foreignKeyViolation(let msg), .error(let msg):
            errorMessage = msg
        }
    }

    func dropConstraint(_ constraint: ConstraintInfo) async {
        let sql = """
            ALTER TABLE \(quoteIdent(constraint.schema)).\(quoteIdent(constraint.table)) \
            DROP CONSTRAINT \(quoteIdent(constraint.name))
            """
        switch await performRowMutation(sql: sql) {
        case .success:
            await refreshSelectedTableMetadata(schema: constraint.schema, table: constraint.table)
        case .foreignKeyViolation(let msg), .error(let msg):
            errorMessage = msg
        }
    }

    /// Enables or disables a trigger. ENABLE and DISABLE are schema DDL on
    /// the parent table rather than the trigger itself.
    func setTriggerEnabled(_ trigger: TriggerInfo, enabled: Bool) async {
        let action = enabled ? "ENABLE" : "DISABLE"
        let sql = """
            ALTER TABLE \(quoteIdent(trigger.schema)).\(quoteIdent(trigger.table)) \
            \(action) TRIGGER \(quoteIdent(trigger.name))
            """
        switch await performRowMutation(sql: sql) {
        case .success:
            await refreshSelectedTableMetadata(schema: trigger.schema, table: trigger.table)
        case .foreignKeyViolation(let msg), .error(let msg):
            errorMessage = msg
        }
    }

    func dropTrigger(_ trigger: TriggerInfo) async {
        let sql = """
            DROP TRIGGER \(quoteIdent(trigger.name)) \
            ON \(quoteIdent(trigger.schema)).\(quoteIdent(trigger.table))
            """
        switch await performRowMutation(sql: sql) {
        case .success:
            await refreshSelectedTableMetadata(schema: trigger.schema, table: trigger.table)
        case .foreignKeyViolation(let msg), .error(let msg):
            errorMessage = msg
        }
    }

    /// Reloads the per-table metadata lists after a DDL change that might
    /// invalidate them (new index, dropped constraint, etc).
    private func refreshSelectedTableMetadata(schema: String, table: String) async {
        // Only refresh if still pointing at the same object
        guard let current = navigatorVM.selectedObject,
              current.schema == schema, current.name == table
        else { return }
        await dbClient.invalidateCache()
        do {
            async let idx = dbClient.listIndexes(schema: schema, table: table)
            async let cons = dbClient.listConstraints(schema: schema, table: table)
            async let trg = dbClient.listTriggers(schema: schema, table: table)
            tableVM.indexes = try await idx
            tableVM.constraints = try await cons
            tableVM.triggers = try await trg
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - Extensions / Roles

    /// CREATE EXTENSION IF NOT EXISTS. Lets users install a PG extension
    /// without round-tripping through the SQL editor.
    func installExtension(_ name: String, schema: String? = nil) async {
        var sql = "CREATE EXTENSION IF NOT EXISTS \(quoteIdent(name))"
        if let schema {
            sql += " WITH SCHEMA \(quoteIdent(schema))"
        }
        switch await performRowMutation(sql: sql) {
        case .success:
            await dbClient.invalidateCache()
        case .foreignKeyViolation(let msg), .error(let msg):
            errorMessage = msg
        }
    }

    func dropExtension(_ name: String) async {
        let sql = "DROP EXTENSION IF EXISTS \(quoteIdent(name)) CASCADE"
        switch await performRowMutation(sql: sql) {
        case .success:
            await dbClient.invalidateCache()
        case .foreignKeyViolation(let msg), .error(let msg):
            errorMessage = msg
        }
    }

    /// Runs a maintenance operation against a table or materialized view.
    /// Refreshes the navigator cache and reloads the current page when the
    /// operation targets the currently selected object.
    func runMaintenance(_ op: MaintenanceOp, on object: DBObject) async {
        let qualified = "\(quoteIdent(object.schema)).\(quoteIdent(object.name))"
        let sql: String
        switch op {
        case .truncate:
            sql = "TRUNCATE TABLE \(qualified)"
        case .vacuum:
            sql = "VACUUM \(qualified)"
        case .vacuumFull:
            sql = "VACUUM FULL \(qualified)"
        case .analyze:
            sql = "ANALYZE \(qualified)"
        case .refreshMatView:
            sql = "REFRESH MATERIALIZED VIEW \(qualified)"
        case .refreshMatViewConcurrently:
            sql = "REFRESH MATERIALIZED VIEW CONCURRENTLY \(qualified)"
        }
        let timeout = op.timeoutOverride ?? Self.defaultQueryTimeout
        do {
            _ = try await dbClient.runQuery(sql, maxRows: 0, timeout: timeout)
            queryHistoryVM.logQuery(sql: sql, source: .system, success: true)
            if object == navigatorVM.selectedObject {
                let approxRows = try await dbClient.getApproximateRowCount(
                    schema: object.schema,
                    table: object.name
                )
                tableVM.approximateRowCount = approxRows
                if selectedTab == .content {
                    await loadContentPage()
                }
            }
        } catch {
            queryHistoryVM.logQuery(sql: sql, source: .system, success: false, errorMessage: error.localizedDescription)
            errorMessage = error.localizedDescription
        }
    }
}

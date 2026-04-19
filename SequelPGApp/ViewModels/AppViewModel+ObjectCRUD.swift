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
    func dropObject(_ object: DBObject) async {
        guard let dropSQL = buildDropSQL(for: object) else {
            errorMessage = "Cannot drop \(object.name): object metadata is invalid."
            return
        }

        do {
            _ = try await dbClient.runQuery(dropSQL, maxRows: 0, timeout: Self.defaultQueryTimeout)
            queryHistoryVM.logQuery(sql: dropSQL, source: .system, success: true)
            await dbClient.invalidateCache()
            navigatorVM.selectedObject = nil
            let db = navigatorVM.connectedDatabase
            navigatorVM.invalidateSchema(db: db, schema: object.schema)
            await loadSchemaObjects(db: db, schema: object.schema)
        } catch {
            queryHistoryVM.logQuery(sql: dropSQL, source: .system, success: false, errorMessage: error.localizedDescription)
            errorMessage = error.localizedDescription
        }
    }

    /// Builds a safe DROP statement, validating any component that comes from
    /// pg_catalog (function argument lists, operator argument types) to defeat
    /// injection via hostile-server-supplied identifiers.
    private func buildDropSQL(for object: DBObject) -> String? {
        let qualified = "\(quoteIdent(object.schema)).\(quoteIdent(object.name))"
        if let keyword = Self.simpleDropKeyword[object.type] {
            return "DROP \(keyword) \(qualified) CASCADE"
        }
        switch object.type {
        case .function, .triggerFunction:
            return buildFunctionLikeDropSQL(object, keyword: "FUNCTION", defaultArgs: "")
        case .procedure:
            return buildFunctionLikeDropSQL(object, keyword: "PROCEDURE", defaultArgs: "")
        case .aggregate:
            return buildFunctionLikeDropSQL(object, keyword: "AGGREGATE", defaultArgs: "*")
        case .operator:
            return buildOperatorDropSQL(object)
        default:
            return nil
        }
    }

    private func buildFunctionLikeDropSQL(_ object: DBObject, keyword: String, defaultArgs: String) -> String? {
        let (baseName, argList) = Self.splitFunctionName(object.name, defaultArgs: defaultArgs)
        // Reject arg lists that came from a hostile pg_catalog row and would
        // escape the parameter list (e.g. "integer) CASCADE; DROP TABLE users").
        guard argList.isEmpty || argList == "*" || isValidFunctionParams(argList) else { return nil }
        return "DROP \(keyword) \(quoteIdent(object.schema)).\(quoteIdent(baseName))(\(argList)) CASCADE"
    }

    private func buildOperatorDropSQL(_ object: DBObject) -> String? {
        // DROP OPERATOR requires (left_type, right_type), but the navigator
        // only stores the bare symbol. We emit a best-effort statement that
        // the DB will reject with a friendly error; the identifier is still
        // quoteIdent-safe against injection.
        return "DROP OPERATOR \(quoteIdent(object.schema)).\(quoteIdent(object.name)) CASCADE"
    }

    /// Splits a function name like "my_func(integer, text)" into ("my_func", "integer, text").
    /// If the name has no parentheses, returns the name with the given default args.
    static func splitFunctionName(_ name: String, defaultArgs: String = "") -> (name: String, args: String) {
        guard let parenIdx = name.firstIndex(of: "("),
              name.hasSuffix(")")
        else {
            return (name, defaultArgs)
        }
        let funcName = String(name[name.startIndex ..< parenIdx])
        let argsStart = name.index(after: parenIdx)
        let argsEnd = name.index(before: name.endIndex)
        let args = argsStart < argsEnd ? String(name[argsStart ..< argsEnd]) : defaultArgs
        return (funcName, args)
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

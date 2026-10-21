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
        let dropSQL: String
        do {
            guard let sql = try await buildDropSQL(for: object) else {
                errorMessage = "Cannot drop \(object.name): this object type can't be dropped from the navigator."
                return
            }
            dropSQL = sql
        } catch {
            errorMessage = error.localizedDescription
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

    /// Builds the DROP statement for `object`, or `nil` for unsupported types.
    ///
    /// Overloadable objects (routines, aggregates, operators) are resolved on the
    /// server: the navigator name is matched against pg_catalog as a quoted
    /// literal, and the server renders the drop target with `%I` / `format_type`.
    /// No catalog-derived text is parsed or spliced into SQL on the client, so a
    /// hostile object or type name can't escape the statement.
    private func buildDropSQL(for object: DBObject) async throws -> String? {
        if let keyword = Self.simpleDropKeyword[object.type] {
            return "DROP \(keyword) \(quoteIdent(object.schema)).\(quoteIdent(object.name)) CASCADE"
        }
        let keyword: String
        switch object.type {
        case .function, .triggerFunction: keyword = "FUNCTION"
        case .procedure: keyword = "PROCEDURE"
        case .aggregate: keyword = "AGGREGATE"
        case .operator: keyword = "OPERATOR"
        default: return nil
        }
        let target = try await resolveDropTarget(Self.dropTargetLookupSQL(for: object), object: object)
        return "DROP \(keyword) \(target) CASCADE"
    }

    /// Catalog query returning the server-rendered drop target for an
    /// overloadable object — one row per catalog entry matching its navigator name.
    static func dropTargetLookupSQL(for object: DBObject) -> String {
        let schema = quoteLiteral(.text(object.schema))
        let name = quoteLiteral(.text(object.name))
        if object.type == .operator {
            return """
                SELECT format('%I.%s (%s, %s)', n.nspname, o.oprname,
                    COALESCE(format_type(NULLIF(o.oprleft, 0), NULL), 'NONE'),
                    COALESCE(format_type(NULLIF(o.oprright, 0), NULL), 'NONE'))
                FROM pg_operator o
                JOIN pg_namespace n ON o.oprnamespace = n.oid
                WHERE n.nspname = \(schema) AND \(CatalogSignature.operator) = \(name)
                """
        }
        // Functions are listed with their signature; procedures, aggregates,
        // and trigger functions by bare name.
        let match = object.name.hasSuffix(")") ? CatalogSignature.routine : "p.proname"
        // DROP AGGREGATE spells a zero-argument signature as (*).
        let args = object.type == .aggregate
            ? "CASE WHEN p.pronargs = 0 THEN '*' ELSE oidvectortypes(p.proargtypes) END"
            : "oidvectortypes(p.proargtypes)"
        let isAggregate = "EXISTS (SELECT 1 FROM pg_aggregate a WHERE a.aggfnoid = p.oid)"
        return """
            SELECT format('%I.%I(%s)', n.nspname, p.proname, \(args))
            FROM pg_proc p
            JOIN pg_namespace n ON p.pronamespace = n.oid
            WHERE n.nspname = \(schema) AND \(match) = \(name)
              AND \(object.type == .aggregate ? "" : "NOT ")\(isAggregate)
            """
    }

    /// Runs a drop-target lookup and requires exactly one match, so a stale or
    /// overloaded navigator entry can never drop the wrong object.
    private func resolveDropTarget(_ lookupSQL: String, object: DBObject) async throws -> String {
        let result = try await dbClient.runQuery(lookupSQL, maxRows: 2, timeout: Self.defaultQueryTimeout)
        switch result.rows.count {
        case 0:
            throw AppError.validationFailed([
                "\(object.name) no longer exists in schema \(object.schema). Refresh the navigator.",
            ])
        case 1:
            guard case let .text(target) = result.rows[0].first else {
                throw AppError.validationFailed(["Cannot drop \(object.name): object metadata is invalid."])
            }
            return target
        default:
            throw AppError.validationFailed([
                "\(object.name) has several overloads. Drop the one you mean from the Query tab with its argument types.",
            ])
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

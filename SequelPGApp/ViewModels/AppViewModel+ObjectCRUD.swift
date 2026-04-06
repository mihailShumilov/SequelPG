import Foundation

extension AppViewModel {
    /// Drops any database object with confirmation already handled by the caller.
    func dropObject(_ object: DBObject) async {
        let dropSQL: String
        switch object.type {
        case .table:
            dropSQL = "DROP TABLE \(quoteIdent(object.schema)).\(quoteIdent(object.name)) CASCADE"
        case .view:
            dropSQL = "DROP VIEW \(quoteIdent(object.schema)).\(quoteIdent(object.name)) CASCADE"
        case .materializedView:
            dropSQL = "DROP MATERIALIZED VIEW \(quoteIdent(object.schema)).\(quoteIdent(object.name)) CASCADE"
        case .function, .triggerFunction:
            let fullName = object.name.contains("(") ? object.name : "\(object.name)()"
            dropSQL = "DROP FUNCTION \(quoteIdent(object.schema)).\(fullName) CASCADE"
        case .procedure:
            let fullName = object.name.contains("(") ? object.name : "\(object.name)()"
            dropSQL = "DROP PROCEDURE \(quoteIdent(object.schema)).\(fullName) CASCADE"
        case .aggregate:
            let fullName = object.name.contains("(") ? object.name : "\(object.name)(*)"
            dropSQL = "DROP AGGREGATE \(quoteIdent(object.schema)).\(fullName) CASCADE"
        case .sequence:
            dropSQL = "DROP SEQUENCE \(quoteIdent(object.schema)).\(quoteIdent(object.name)) CASCADE"
        case .type:
            dropSQL = "DROP TYPE \(quoteIdent(object.schema)).\(quoteIdent(object.name)) CASCADE"
        case .domain:
            dropSQL = "DROP DOMAIN \(quoteIdent(object.schema)).\(quoteIdent(object.name)) CASCADE"
        case .collation:
            dropSQL = "DROP COLLATION \(quoteIdent(object.schema)).\(quoteIdent(object.name)) CASCADE"
        case .foreignTable:
            dropSQL = "DROP FOREIGN TABLE \(quoteIdent(object.schema)).\(quoteIdent(object.name)) CASCADE"
        case .ftsConfiguration:
            dropSQL = "DROP TEXT SEARCH CONFIGURATION \(quoteIdent(object.schema)).\(quoteIdent(object.name)) CASCADE"
        case .ftsDictionary:
            dropSQL = "DROP TEXT SEARCH DICTIONARY \(quoteIdent(object.schema)).\(quoteIdent(object.name)) CASCADE"
        case .ftsParser:
            dropSQL = "DROP TEXT SEARCH PARSER \(quoteIdent(object.schema)).\(quoteIdent(object.name)) CASCADE"
        case .ftsTemplate:
            dropSQL = "DROP TEXT SEARCH TEMPLATE \(quoteIdent(object.schema)).\(quoteIdent(object.name)) CASCADE"
        case .operator:
            dropSQL = "DROP OPERATOR \(quoteIdent(object.schema)).\(object.name) CASCADE"
        }

        do {
            _ = try await dbClient.runQuery(dropSQL, maxRows: 0, timeout: Self.defaultQueryTimeout)
            await dbClient.invalidateCache()
            navigatorVM.selectedObject = nil
            let db = navigatorVM.connectedDatabase
            navigatorVM.invalidateSchema(db: db, schema: object.schema)
            await loadSchemaObjects(db: db, schema: object.schema)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Executes a CREATE statement and refreshes the navigator.
    func executeCreateSQL(_ sql: String, inSchema schema: String) async {
        do {
            _ = try await dbClient.runQuery(sql, maxRows: 0, timeout: Self.defaultQueryTimeout)
            await dbClient.invalidateCache()
            let db = navigatorVM.connectedDatabase
            navigatorVM.invalidateSchema(db: db, schema: schema)
            await loadSchemaObjects(db: db, schema: schema)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

import XCTest
@testable import SequelPG

final class SQLCompletionProviderTests: XCTestCase {

    private func emptyMetadata() -> SQLCompletionProvider.Metadata {
        SQLCompletionProvider.Metadata(schemas: [], tables: [], columns: [])
    }

    // MARK: - Prefix matching

    /// 'sel' must only match candidates that start with 'sel'. SELECT must be
    /// at the top; SET, SECURITY, etc. must not appear at all even though
    /// they share a prefix with 'sel' for fewer characters.
    func testSelPrefixOnlyReturnsSelectAndNothingElse() {
        let items = SQLCompletionProvider.completions(
            for: "sel",
            metadata: emptyMetadata(),
            context: .unknown
        )
        let labels = items.map(\.label)
        XCTAssertTrue(labels.contains("SELECT"), "SELECT should be a top result for 'sel'")
        XCTAssertFalse(labels.contains("SET"), "SET must not appear for 'sel' (only 'se' prefix matches)")
        XCTAssertFalse(labels.contains("SECURITY"), "SECURITY must not appear for 'sel'")
    }

    func testSelectIsFirstResultForSel() {
        let items = SQLCompletionProvider.completions(
            for: "sel",
            metadata: emptyMetadata(),
            context: .unknown
        )
        XCTAssertEqual(items.first?.label, "SELECT")
    }

    func testSePrefixIncludesSelectSetSecurityButSelectIsFirstByShorterLength() {
        let items = SQLCompletionProvider.completions(
            for: "se",
            metadata: emptyMetadata(),
            context: .unknown
        )
        let labels = items.map(\.label)
        XCTAssertTrue(labels.contains("SELECT"))
        XCTAssertTrue(labels.contains("SET"))
        // SET (3 chars) should beat SELECT (6) at the top when both are pure
        // prefix matches — shorter wins among same-priority kind candidates.
        let setIdx = labels.firstIndex(of: "SET") ?? Int.max
        let selectIdx = labels.firstIndex(of: "SELECT") ?? Int.max
        XCTAssertLessThan(setIdx, selectIdx, "SET (shorter) should rank above SELECT for 'se' prefix")
    }

    // MARK: - Context awareness

    func testFromContextOnlySuggestsTables() {
        let metadata = SQLCompletionProvider.Metadata(
            schemas: ["public"],
            tables: [
                DBObject(schema: "public", name: "users", type: .table),
                DBObject(schema: "public", name: "user_sessions", type: .table),
            ],
            columns: [
                ColumnInfo(name: "user_id", ordinalPosition: 1, dataType: "integer", isNullable: false, columnDefault: nil, characterMaximumLength: nil),
            ]
        )
        // Context: just typed 'us' after 'SELECT * FROM '
        let context = CompletionContext(position: .fromList, qualifier: nil, fromTables: [])
        let items = SQLCompletionProvider.completions(for: "us", metadata: metadata, context: context)
        let labels = items.map(\.label)
        XCTAssertTrue(labels.contains("users"), "After FROM, 'us' should match the table 'users'")
        // user_id is a column — must not appear at the top in FROM context.
        if let usersIdx = labels.firstIndex(of: "users"), let userIdIdx = labels.firstIndex(of: "user_id") {
            XCTAssertLessThan(usersIdx, userIdIdx, "table 'users' should rank above column 'user_id' in FROM context")
        }
    }

    func testWhereContextRanksColumnsAboveTables() {
        let metadata = SQLCompletionProvider.Metadata(
            schemas: [],
            tables: [DBObject(schema: "public", name: "user_data", type: .table)],
            columns: [
                ColumnInfo(name: "user_id", ordinalPosition: 1, dataType: "integer", isNullable: false, columnDefault: nil, characterMaximumLength: nil),
            ]
        )
        let context = CompletionContext(position: .whereClause, qualifier: nil, fromTables: ["users"])
        let items = SQLCompletionProvider.completions(for: "user", metadata: metadata, context: context)
        let labels = items.map(\.label)
        XCTAssertTrue(labels.contains("user_id"))
        if let columnIdx = labels.firstIndex(of: "user_id"), let tableIdx = labels.firstIndex(of: "user_data") {
            XCTAssertLessThan(columnIdx, tableIdx, "Column should rank above table in WHERE context")
        }
    }

    // MARK: - Context detection from tokens

    func testDetectPositionAfterFrom() {
        let tokens = SQLFormatter.tokenize("SELECT * FROM us")
        // Cursor at the end of 'us'.
        let cursor = "SELECT * FROM us".utf16.count
        let context = CompletionContext.detect(tokens: tokens, cursorUTF16Offset: cursor)
        XCTAssertEqual(context.position, .fromList)
    }

    func testDetectPositionAfterWhere() {
        let tokens = SQLFormatter.tokenize("SELECT * FROM users WHERE id")
        let cursor = "SELECT * FROM users WHERE id".utf16.count
        let context = CompletionContext.detect(tokens: tokens, cursorUTF16Offset: cursor)
        XCTAssertEqual(context.position, .whereClause)
    }

    func testDetectPositionUnknownAtStart() {
        let tokens = SQLFormatter.tokenize("sel")
        let cursor = "sel".utf16.count
        let context = CompletionContext.detect(tokens: tokens, cursorUTF16Offset: cursor)
        XCTAssertEqual(context.position, .unknown)
    }

    func testDetectQualifierFromTableDotPartial() {
        let tokens = SQLFormatter.tokenize("SELECT users.na")
        let cursor = "SELECT users.na".utf16.count
        let context = CompletionContext.detect(tokens: tokens, cursorUTF16Offset: cursor)
        XCTAssertEqual(context.qualifier, "users")
    }

    // MARK: - Regression: 'li' must not fuzzy-match 'public' in FROM context

    /// User-reported regression: typing `li` (intending `LIMIT`) inside
    /// `SELECT * FROM "orders" li|` produced `public` as the top suggestion
    /// because keywords were excluded from the FROM-context pool, and the
    /// fuzzy fallback matched `l` and `i` as a subsequence in the `public`
    /// schema name. The fix is two-pronged: keywords are now always in the
    /// pool (so `LIMIT` becomes a real prefix match), and fuzzy fallback is
    /// disabled for partials shorter than 3 chars.
    func testLiInFromContextSuggestsLimitNotPublic() {
        let metadata = SQLCompletionProvider.Metadata(
            schemas: ["public", "auth"],
            tables: [DBObject(schema: "public", name: "orders", type: .table)],
            columns: []
        )
        let context = CompletionContext(position: .fromList, qualifier: nil, fromTables: ["orders"])
        let result = SQLCompletionProvider.result(for: "li", metadata: metadata, context: context)
        let labels = result.items.map(\.label)
        XCTAssertFalse(labels.contains("public"),
                       "'public' must not appear for 'li' — it's only a fuzzy match for two chars, which is too noisy")
        XCTAssertTrue(labels.contains("LIMIT"),
                      "LIMIT must be a top suggestion for 'li' (prefix match, even in FROM context)")
        XCTAssertTrue(result.preselectTop,
                      "Prefix-match results must be pre-selectable so Tab/Return commits the top")
    }

    func testShortFuzzyDoesNotMatch() {
        let metadata = SQLCompletionProvider.Metadata(
            schemas: ["public"],
            tables: [],
            columns: []
        )
        // 'pc' fuzzy-matches 'public' (p, then c at the end) — but with the
        // 3-char minimum for fuzzy fallback we should get no results.
        let result = SQLCompletionProvider.result(for: "pc", metadata: metadata, context: .unknown)
        XCTAssertFalse(result.items.contains { $0.label == "public" },
                       "Two-char fuzzy matches should be suppressed")
    }

    func testFuzzyMatchesAtThreeChars() {
        let metadata = SQLCompletionProvider.Metadata(
            schemas: ["public"],
            tables: [],
            columns: [ColumnInfo(name: "user_profile", ordinalPosition: 1, dataType: "text", isNullable: true, columnDefault: nil, characterMaximumLength: nil)]
        )
        // 'usp' matches 'user_profile' as a subsequence — that's the
        // motivating use case for keeping fuzzy at all, and it works at 3+
        // chars.
        let result = SQLCompletionProvider.result(for: "usp", metadata: metadata, context: .unknown)
        XCTAssertTrue(result.items.contains { $0.label == "user_profile" })
        XCTAssertFalse(result.preselectTop,
                       "Fuzzy-only results must not pre-select — accidental Tab would commit a marginal match")
    }

    // MARK: - DDL object targets (GH #5)

    /// Reporter scenario: `DROP SCHEMA validate_… CASCADE;`. Typing `val`
    /// surfaced the keyword `VALUES` (and `VACUUM` at two chars) above the
    /// actual schema, because `DROP SCHEMA` wasn't recognised as a clause and
    /// fell back to `.unknown` where keywords win. The schema must now rank
    /// first and be pre-selectable so Tab/Return commits it.
    func testDropSchemaPrefersSchemaNameOverKeyword() {
        let metadata = SQLCompletionProvider.Metadata(
            schemas: ["public", "validate_20260526071310"],
            tables: [],
            columns: []
        )
        let sql = "DROP SCHEMA val"
        let tokens = SQLFormatter.tokenize(sql)
        let context = CompletionContext.detect(tokens: tokens, cursorUTF16Offset: sql.utf16.count)
        XCTAssertEqual(context.position, .schemaTarget)

        let result = SQLCompletionProvider.result(for: "val", metadata: metadata, context: context)
        let labels = result.items.map(\.label)
        XCTAssertEqual(result.items.first?.label, "validate_20260526071310",
                       "The schema must be the top suggestion after DROP SCHEMA, not VALUES")
        XCTAssertTrue(result.preselectTop,
                      "Schema prefix match must pre-select so Tab/Return commits it")
        if let schemaIdx = labels.firstIndex(of: "validate_20260526071310"),
           let valuesIdx = labels.firstIndex(of: "VALUES")
        {
            XCTAssertLessThan(schemaIdx, valuesIdx, "Schema must outrank the VALUES keyword")
        }
    }

    /// Same statement at two characters (`va`), where both VACUUM and VALUES
    /// prefix-match — the schema still has to win.
    func testDropSchemaPrefersSchemaNameAtTwoChars() {
        let metadata = SQLCompletionProvider.Metadata(
            schemas: ["validate_20260526071310"],
            tables: [],
            columns: []
        )
        let sql = "DROP SCHEMA va"
        let tokens = SQLFormatter.tokenize(sql)
        let context = CompletionContext.detect(tokens: tokens, cursorUTF16Offset: sql.utf16.count)
        let result = SQLCompletionProvider.result(for: "va", metadata: metadata, context: context)
        XCTAssertEqual(result.items.first?.label, "validate_20260526071310")
        let labels = result.items.map(\.label)
        if let schemaIdx = labels.firstIndex(of: "validate_20260526071310"),
           let vacuumIdx = labels.firstIndex(of: "VACUUM")
        {
            XCTAssertLessThan(schemaIdx, vacuumIdx, "Schema must outrank the VACUUM keyword")
        }
    }

    func testDropTablePrefersTableNameOverKeyword() {
        let metadata = SQLCompletionProvider.Metadata(
            schemas: [],
            tables: [DBObject(schema: "public", name: "tasks", type: .table)],
            columns: []
        )
        let sql = "DROP TABLE ta"
        let tokens = SQLFormatter.tokenize(sql)
        let context = CompletionContext.detect(tokens: tokens, cursorUTF16Offset: sql.utf16.count)
        XCTAssertEqual(context.position, .objectTarget)

        let result = SQLCompletionProvider.result(for: "ta", metadata: metadata, context: context)
        let labels = result.items.map(\.label)
        XCTAssertEqual(result.items.first?.label, "tasks",
                       "The table must outrank the TABLE keyword after DROP TABLE")
        if let tableIdx = labels.firstIndex(of: "tasks"),
           let kwIdx = labels.firstIndex(of: "TABLE")
        {
            XCTAssertLessThan(tableIdx, kwIdx)
        }
    }

    /// Keywords are still offered — just deprioritised. After the schema name
    /// is typed, `CASCADE` must still complete (no schema matches "cas").
    func testKeywordStillSuggestedAfterSchemaName() {
        let metadata = SQLCompletionProvider.Metadata(
            schemas: ["validate_20260526071310"],
            tables: [],
            columns: []
        )
        let sql = "DROP SCHEMA validate_20260526071310 cas"
        let tokens = SQLFormatter.tokenize(sql)
        let context = CompletionContext.detect(tokens: tokens, cursorUTF16Offset: sql.utf16.count)
        XCTAssertEqual(context.position, .schemaTarget)
        let result = SQLCompletionProvider.result(for: "cas", metadata: metadata, context: context)
        XCTAssertTrue(result.items.map(\.label).contains("CASCADE"),
                      "CASCADE must still be offered after the schema name in schemaTarget position")
    }

    func testDetectPositionAfterDropSchema() {
        let sql = "DROP SCHEMA val"
        let tokens = SQLFormatter.tokenize(sql)
        let context = CompletionContext.detect(tokens: tokens, cursorUTF16Offset: sql.utf16.count)
        XCTAssertEqual(context.position, .schemaTarget)
    }

    func testDetectPositionAfterDropSchemaIfExists() {
        let sql = "DROP SCHEMA IF EXISTS val"
        let tokens = SQLFormatter.tokenize(sql)
        let context = CompletionContext.detect(tokens: tokens, cursorUTF16Offset: sql.utf16.count)
        XCTAssertEqual(context.position, .schemaTarget,
                       "IF EXISTS between SCHEMA and the name must not change the detected position")
    }

    func testDetectPositionAfterAlterTable() {
        let sql = "ALTER TABLE us"
        let tokens = SQLFormatter.tokenize(sql)
        let context = CompletionContext.detect(tokens: tokens, cursorUTF16Offset: sql.utf16.count)
        XCTAssertEqual(context.position, .objectTarget)
    }
}

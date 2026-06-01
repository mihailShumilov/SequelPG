import Foundation

/// Provides SQL autocompletion candidates from keywords and database metadata.
/// The provider is *context-aware*: it consumes a `CompletionContext` (built
/// from the tokens before the cursor) so it can bias suggestions toward what
/// PostgreSQL would actually accept at that point — tables after FROM, columns
/// after SELECT/WHERE/ON, only-this-table's-columns after `tablename.`, etc.
///
/// Ranking is JetBrains-style: case-insensitive prefix matches win
/// outright. Fuzzy subsequence matches are only used as a fallback when no
/// candidate prefix-matches the user's input. That avoids the surprising
/// "SECURITY ranks above SELECT for 'sele'" behaviour the original fuzzy-only
/// implementation produced.
enum SQLCompletionProvider {
    struct Metadata: Equatable {
        var schemas: [String]
        var tables: [DBObject]
        var columns: [ColumnInfo]
    }

    /// Returns ranked completions for the given partial word and context.
    /// Pass `.unknown` context to get the legacy "everything matches" behaviour.
    ///
    /// Algorithm:
    ///   1. Build a candidate pool — keywords are *always* present, plus
    ///      tables/columns/functions/schemas biased by the clause context.
    ///   2. Find case-insensitive prefix matches. If any exist, return only
    ///      those, sorted by context-aware priority and shortest-first.
    ///   3. Otherwise fall back to fuzzy subsequence — but only when the
    ///      partial is at least 3 characters long. Shorter partials produce
    ///      far too many noise matches under fuzzy (typing `li` matches
    ///      anything containing both an `l` and an `i`, including unrelated
    ///      schema names like `public`).
    ///   4. Fuzzy-only results return with `preselect = false` so the caller
    ///      knows not to auto-select index 0 — we don't want Tab/Return to
    ///      commit a random fuzzy match.
    static func completions(
        for partial: String,
        metadata: Metadata,
        context: CompletionContext = .unknown
    ) -> [CompletionItem] {
        result(for: partial, metadata: metadata, context: context).items
    }

    struct Result {
        let items: [CompletionItem]
        /// True when the top item is a confident match (prefix hit). The
        /// editor uses this to decide whether to pre-select index 0 in the
        /// popup; for fuzzy-only fallbacks we deliberately do not pre-select
        /// so an accidental Tab doesn't commit a marginal match.
        let preselectTop: Bool
    }

    static func result(
        for partial: String,
        metadata: Metadata,
        context: CompletionContext = .unknown
    ) -> Result {
        guard !partial.isEmpty else { return Result(items: [], preselectTop: false) }

        let items = buildCandidatePool(metadata: metadata, context: context)
        let lowered = partial.lowercased()

        // Pass 1 — case-insensitive prefix matches.
        var prefixHits: [CompletionItem] = []
        for var item in items where item.label.lowercased().hasPrefix(lowered) {
            let endIdx = item.label.index(item.label.startIndex, offsetBy: lowered.count)
            item.matchedRanges = [item.label.startIndex ..< endIdx]
            prefixHits.append(item)
        }
        if !prefixHits.isEmpty {
            let ranked = prefixHits
                .sorted { lhs, rhs in
                    if lhs.kind.priority(in: context) != rhs.kind.priority(in: context) {
                        return lhs.kind.priority(in: context) < rhs.kind.priority(in: context)
                    }
                    if lhs.label.count != rhs.label.count { return lhs.label.count < rhs.label.count }
                    return lhs.label.localizedCaseInsensitiveCompare(rhs.label) == .orderedAscending
                }
                .prefix(50)
                .map { $0 }
            return Result(items: Array(ranked), preselectTop: true)
        }

        // Pass 2 — fuzzy subsequence. Only run when partial is long enough
        // to make fuzzy matches meaningful.
        guard partial.count >= 3 else {
            return Result(items: [], preselectTop: false)
        }
        let scored: [(CompletionItem, FuzzyMatcher.Score)] = items.compactMap { item in
            guard let score = FuzzyMatcher.score(partial: partial, candidate: item.label) else {
                return nil
            }
            var matched = item
            matched.matchedRanges = score.matchedRanges
            return (matched, score)
        }
        let ranked = scored
            .sorted { lhs, rhs in
                if lhs.1.consecutiveScore != rhs.1.consecutiveScore {
                    return lhs.1.consecutiveScore > rhs.1.consecutiveScore
                }
                if lhs.0.kind.priority(in: context) != rhs.0.kind.priority(in: context) {
                    return lhs.0.kind.priority(in: context) < rhs.0.kind.priority(in: context)
                }
                return lhs.0.label.localizedCaseInsensitiveCompare(rhs.0.label) == .orderedAscending
            }
            .prefix(50)
            .map(\.0)
        return Result(items: Array(ranked), preselectTop: false)
    }

    /// Builds the pool of `CompletionItem`s that get matched against the
    /// partial. Filters/biases the pool based on context — e.g., after `FROM`
    /// we don't include column names at all because PostgreSQL won't accept
    /// them there. Keywords are always included so the user can still type
    /// e.g. "WHERE" right after a table name.
    private static func buildCandidatePool(
        metadata: Metadata,
        context: CompletionContext
    ) -> [CompletionItem] {
        var items: [CompletionItem] = []

        // Qualified completion: `tablename.partial`. Restrict to columns of
        // that table when the metadata is available.
        if let qualifier = context.qualifier {
            let matchedColumns: [ColumnInfo]
            if context.fromTables.contains(qualifier.lowercased()) || metadata.tables.contains(where: { $0.name.lowercased() == qualifier.lowercased() }) {
                // Only include columns belonging to the qualifier. We don't
                // have a column→table mapping in metadata.columns (it's the
                // currently-selected table's columns), so when the qualifier
                // isn't the current table, fall back to "all columns we know"
                // — better to over-suggest than show nothing.
                matchedColumns = metadata.columns
            } else {
                matchedColumns = metadata.columns
            }
            for column in matchedColumns {
                items.append(CompletionItem(
                    insertText: column.name,
                    label: column.name,
                    kind: .column,
                    detail: column.dataType + (column.isPrimaryKey ? "  ·  PK" : "")
                ))
            }
            return items
        }

        // Keywords are ALWAYS in the pool — at any point in any clause the
        // user can transition to a new clause (`SELECT … FROM t LIMIT 10`,
        // `WHERE … ORDER BY …`). Excluding them by context produced bad
        // suggestions like fuzzy-matching `li` against `public` because
        // `LIMIT` wasn't a candidate. Context bias happens via the per-kind
        // priority in `Kind.priority(in:)`, not by removing items from the
        // pool.
        items.append(contentsOf: keywordItems())

        switch context.position {
        case .fromList, .joinList, .updateTarget, .insertTarget, .truncateTarget, .objectTarget:
            // After FROM/JOIN/DROP TABLE/etc., tables and schemas are the
            // primary candidates. Columns are not included — they're not valid
            // here. Schemas stay in the pool for schema-qualified names like
            // `myschema.mytable`.
            items.append(contentsOf: tableItems(metadata.tables))
            items.append(contentsOf: schemaItems(metadata.schemas))
        case .schemaTarget:
            // `DROP SCHEMA` / `ALTER SCHEMA` — only schema names are valid here.
            items.append(contentsOf: schemaItems(metadata.schemas))
        case .selectList, .whereClause, .onClause, .groupByClause, .orderByClause,
             .setClause, .returningClause, .insertColumnsList:
            // Column-expecting positions. We still include tables (for
            // qualified `tbl.col`) and functions (`count(*)`, etc.).
            items.append(contentsOf: columnItems(metadata.columns))
            items.append(contentsOf: tableItems(metadata.tables))
            items.append(contentsOf: functionItems())
        case .unknown:
            items.append(contentsOf: columnItems(metadata.columns))
            items.append(contentsOf: tableItems(metadata.tables))
            items.append(contentsOf: schemaItems(metadata.schemas))
            items.append(contentsOf: functionItems())
        }
        return items
    }

    private static func columnItems(_ columns: [ColumnInfo]) -> [CompletionItem] {
        columns.map { c in
            CompletionItem(
                insertText: c.name,
                label: c.name,
                kind: .column,
                detail: c.dataType + (c.isPrimaryKey ? "  ·  PK" : "")
            )
        }
    }

    private static func tableItems(_ tables: [DBObject]) -> [CompletionItem] {
        tables.map { t in
            CompletionItem(
                insertText: t.name,
                label: t.name,
                kind: .table,
                detail: schemaQualified(t)
            )
        }
    }

    private static func schemaItems(_ schemas: [String]) -> [CompletionItem] {
        schemas.map { s in
            CompletionItem(insertText: s, label: s, kind: .schema, detail: "schema")
        }
    }

    private static func functionItems() -> [CompletionItem] {
        SQLFunctionLibrary.all.map { entry in
            CompletionItem(insertText: entry.name, label: entry.name, kind: .function, detail: entry.signature)
        }
    }

    private static func keywordItems() -> [CompletionItem] {
        SQLFormatter.keywords.map { kw in
            CompletionItem(insertText: kw.uppercased(), label: kw.uppercased(), kind: .keyword, detail: "keyword")
        }
    }

    private static func schemaQualified(_ obj: DBObject) -> String {
        let kindLabel = obj.type == .view ? "view" : "table"
        if obj.schema.isEmpty || obj.schema == "public" { return kindLabel }
        return "\(obj.schema)  ·  \(kindLabel)"
    }
}

// MARK: - CompletionContext

/// What the user appears to be completing at the current cursor position.
/// Built by `CompletionContext.detect(tokens:cursorUTF16Offset:)` from the
/// stream of tokens already produced by the syntax-highlighting pass — no
/// extra tokenization at completion time.
struct CompletionContext {
    enum Position {
        case selectList         // SELECT ... before FROM
        case fromList           // FROM ...
        case joinList           // JOIN ...
        case onClause           // ON ...
        case whereClause        // WHERE ...
        case groupByClause      // GROUP BY ...
        case orderByClause      // ORDER BY ...
        case setClause          // UPDATE ... SET ...
        case returningClause    // RETURNING ...
        case updateTarget       // UPDATE _here_
        case insertTarget       // INSERT INTO _here_
        case insertColumnsList  // INSERT INTO tbl (_here_)
        case truncateTarget     // TRUNCATE _here_
        case schemaTarget       // DROP / ALTER SCHEMA _here_ (or DATABASE)
        case objectTarget       // DROP / ALTER TABLE | VIEW | INDEX … _here_
        case unknown
    }

    let position: Position
    /// When the user typed `tablename.partial`, this is "tablename". Empty
    /// otherwise. Used to restrict column suggestions to one table.
    let qualifier: String?
    /// Table names appearing in the FROM clause of the current statement.
    /// Empty if no FROM seen yet (or position is itself FROM).
    let fromTables: [String]

    static let unknown = CompletionContext(position: .unknown, qualifier: nil, fromTables: [])

    /// Inspects the tokens preceding `cursorUTF16Offset` to figure out what
    /// kind of identifier is being completed. Walks tokens backwards from the
    /// cursor, skipping content inside balanced parentheses except for the
    /// innermost open paren (so `INSERT INTO t (col_` correctly detects
    /// `insertColumnsList`).
    ///
    /// **Token lookback cap.** When the document is many statements long,
    /// scanning every token before the cursor on each keystroke costs more
    /// than it saves. We use the most recent `;` (statement boundary) as the
    /// natural cap, and if no `;` is found within the last 400 tokens, we
    /// fall back to `.unknown` rather than walk an unbounded prefix.
    static func detect(tokens: [SQLFormatter.Token], cursorUTF16Offset: Int) -> CompletionContext {
        // Map each token to its UTF-16 start offset so we can find the
        // tokens preceding the cursor.
        var offsets: [Int] = []
        var pos = 0
        for token in tokens {
            offsets.append(pos)
            pos += token.text.utf16.count
        }
        // Index of the token directly under or just before the cursor.
        var cursorIdx = tokens.count - 1
        for (i, off) in offsets.enumerated() where off >= cursorUTF16Offset {
            cursorIdx = i - 1
            break
        }
        cursorIdx = max(-1, cursorIdx)

        // Qualifier detection: walk back over the partial identifier we are
        // completing, then check for a `.` immediately before, then an
        // identifier before that. Tokens at `cursorIdx` may BE the partial
        // identifier — that's fine, we walk past it.
        let qualifier = detectQualifier(tokens: tokens, cursorTokenIdx: cursorIdx)

        // Statement start: scan back for a `;`, treating everything since
        // that point as a single statement. Cap the lookback at 400 tokens —
        // for documents with many prior statements, no semicolon in that
        // window means we shouldn't infer a clause from ancient context.
        var stmtStart = max(0, cursorIdx - 400)
        for i in stride(from: cursorIdx, through: max(0, cursorIdx - 400), by: -1) where i < tokens.count {
            if tokens[i].kind == .punctuation, tokens[i].text == ";" {
                stmtStart = i + 1
                break
            }
        }

        // FROM-tables collection. Look forward from each FROM/JOIN/INTO/etc.
        // and grab the next identifier — that's the table name.
        let fromTables = collectFromTables(tokens: tokens, start: stmtStart, end: cursorIdx)

        // Clause detection: walk back from cursor through significant tokens,
        // skipping whitespace/comments, ignoring tokens inside balanced
        // parens *except* if our cursor is inside an unbalanced open paren.
        let position = detectPosition(tokens: tokens, stmtStart: stmtStart, cursorIdx: cursorIdx)

        return CompletionContext(position: position, qualifier: qualifier, fromTables: fromTables)
    }

    /// Walks tokens before the partial we're completing to see if it looks
    /// like `qualifier.partial`. Returns the qualifier name (lowercased for
    /// case-insensitive comparison elsewhere), or nil.
    private static func detectQualifier(tokens: [SQLFormatter.Token], cursorTokenIdx: Int) -> String? {
        guard cursorTokenIdx >= 1 else { return nil }
        // Walk back over whitespace.
        var i = cursorTokenIdx
        // The cursor token itself may be the partial identifier — skip it
        // back if so.
        while i >= 0, tokens[i].kind == .identifier || tokens[i].kind == .keyword {
            i -= 1
        }
        // Now look for a `.` punctuation immediately before.
        while i >= 0, tokens[i].kind == .whitespace { i -= 1 }
        guard i >= 0, tokens[i].kind == .punctuation, tokens[i].text == "." else { return nil }
        i -= 1
        while i >= 0, tokens[i].kind == .whitespace { i -= 1 }
        guard i >= 0,
              tokens[i].kind == .identifier || tokens[i].kind == .quotedIdentifier
        else { return nil }
        let raw = tokens[i].text
        // Strip the surrounding double-quotes from quoted identifiers.
        if raw.hasPrefix("\""), raw.hasSuffix("\""), raw.count >= 2 {
            return String(raw.dropFirst().dropLast())
        }
        return raw
    }

    /// Returns the names that appear right after FROM, JOIN, INTO, UPDATE,
    /// or TRUNCATE within the current statement (between `stmtStart` and
    /// `cursorIdx`). Used so column suggestions can prefer columns of tables
    /// the user has already named.
    private static func collectFromTables(tokens: [SQLFormatter.Token], start: Int, end: Int) -> [String] {
        guard start <= end else { return [] }
        var result: [String] = []
        var i = start
        while i <= end, i < tokens.count {
            let t = tokens[i]
            if t.kind == .keyword {
                let kw = t.text.lowercased()
                if kw == "from" || kw == "join" || kw == "into" || kw == "update" || kw == "truncate" {
                    // Skip to the next identifier; allow optional ONLY or schema-qualified.
                    var j = i + 1
                    while j <= end, j < tokens.count, tokens[j].kind == .whitespace { j += 1 }
                    if j <= end, j < tokens.count {
                        let tok = tokens[j]
                        if tok.kind == .identifier || tok.kind == .quotedIdentifier {
                            var name = tok.text
                            if name.hasPrefix("\""), name.hasSuffix("\""), name.count >= 2 {
                                name = String(name.dropFirst().dropLast())
                            }
                            // Handle schema.table — take the part after the dot.
                            if j + 2 <= end, j + 2 < tokens.count,
                               tokens[j + 1].kind == .punctuation, tokens[j + 1].text == ".",
                               tokens[j + 2].kind == .identifier || tokens[j + 2].kind == .quotedIdentifier
                            {
                                name = tokens[j + 2].text
                                if name.hasPrefix("\""), name.hasSuffix("\""), name.count >= 2 {
                                    name = String(name.dropFirst().dropLast())
                                }
                            }
                            result.append(name.lowercased())
                        }
                    }
                }
            }
            i += 1
        }
        return result
    }

    /// Identifies the most recent clause keyword in the statement preceding
    /// the cursor. The "most recent" wins so e.g. SELECT a, b FROM t WHERE _
    /// reports `whereClause`, not `selectList`.
    private static func detectPosition(tokens: [SQLFormatter.Token], stmtStart: Int, cursorIdx: Int) -> Position {
        // Build a list of significant keyword positions in order — we'll
        // pick the last one. Multi-word clauses (ORDER BY, GROUP BY,
        // INSERT INTO) are recognised by looking at the next non-whitespace
        // token when we see the prefix.
        struct Marker { let position: Position; let order: Int }
        var markers: [Marker] = []
        var i = stmtStart
        while i <= cursorIdx, i < tokens.count {
            let t = tokens[i]
            if t.kind == .keyword {
                let kw = t.text.lowercased()
                let next = nextKeyword(tokens: tokens, from: i + 1, upTo: cursorIdx)
                switch kw {
                case "select": markers.append(Marker(position: .selectList, order: i))
                case "from": markers.append(Marker(position: .fromList, order: i))
                case "join": markers.append(Marker(position: .joinList, order: i))
                case "on": markers.append(Marker(position: .onClause, order: i))
                case "where": markers.append(Marker(position: .whereClause, order: i))
                case "having": markers.append(Marker(position: .whereClause, order: i))
                case "set": markers.append(Marker(position: .setClause, order: i))
                case "returning": markers.append(Marker(position: .returningClause, order: i))
                case "update": markers.append(Marker(position: .updateTarget, order: i))
                case "truncate": markers.append(Marker(position: .truncateTarget, order: i))
                case "group" where next == "by":
                    markers.append(Marker(position: .groupByClause, order: i))
                case "order" where next == "by":
                    markers.append(Marker(position: .orderByClause, order: i))
                case "insert" where next == "into":
                    markers.append(Marker(position: .insertTarget, order: i))
                // DDL object references: `DROP SCHEMA <name>`, `ALTER TABLE
                // <name>`, etc. Without these the statement falls back to
                // `.unknown`, where keywords outrank everything — so typing the
                // name of an existing schema like `validate_…` got drowned out
                // by `VACUUM` / `VALUES` (GH #5). We look at the object-type
                // keyword right after DROP/ALTER to decide what to prioritise.
                case "drop", "alter":
                    switch next {
                    case "schema", "database":
                        markers.append(Marker(position: .schemaTarget, order: i))
                    case "table", "view", "index", "materialized":
                        markers.append(Marker(position: .objectTarget, order: i))
                    default: break
                    }
                default: break
                }
            }
            i += 1
        }
        guard let last = markers.last else { return .unknown }

        // Refine insertTarget vs insertColumnsList: if the cursor is inside
        // the parenthesised column list right after the table name, we're
        // listing column names.
        if last.position == .insertTarget {
            if cursorInsideParenAfter(tokens: tokens, marker: last.order, cursorIdx: cursorIdx) {
                return .insertColumnsList
            }
        }
        return last.position
    }

    private static func nextKeyword(tokens: [SQLFormatter.Token], from start: Int, upTo end: Int) -> String? {
        var i = start
        while i <= end, i < tokens.count {
            let t = tokens[i]
            if t.kind == .whitespace { i += 1; continue }
            if t.kind == .keyword { return t.text.lowercased() }
            return nil
        }
        return nil
    }

    /// True when, between `marker` and `cursorIdx`, we've passed an opening
    /// `(` that is not yet matched by a `)`.
    private static func cursorInsideParenAfter(tokens: [SQLFormatter.Token], marker: Int, cursorIdx: Int) -> Bool {
        var depth = 0
        for i in (marker + 1) ... cursorIdx where i < tokens.count {
            let t = tokens[i]
            if t.kind == .punctuation {
                if t.text == "(" { depth += 1 }
                if t.text == ")" { depth -= 1 }
            }
        }
        return depth > 0
    }
}

// MARK: - CompletionItem

/// One row in the autocomplete popup. Carries everything the UI needs to draw
/// a categorized JetBrains-style row: the identifier to insert, a display
/// label (may differ from insertText for quoted identifiers later), the kind
/// for the leading chip, an optional detail string (type info / sig), and the
/// indices in `label` that matched the user's partial — used to draw the
/// bold-highlight on each matched character.
struct CompletionItem: Identifiable, Hashable {
    let id = UUID()
    let insertText: String
    let label: String
    let kind: Kind
    let detail: String
    var matchedRanges: [Range<String.Index>] = []

    enum Kind: Hashable {
        case keyword
        case schema
        case table
        case column
        case function

        var chip: String {
            switch self {
            case .keyword: return "kw"
            case .schema: return "sch"
            case .table: return "tbl"
            case .column: return "col"
            case .function: return "fn"
            }
        }

        /// Sort order between kinds at the same fuzzy/prefix score. The
        /// priority changes with context: after FROM, tables outrank columns;
        /// after WHERE, columns outrank tables. Keywords sit last unless the
        /// position is "unknown" (start of statement), where they bubble up.
        func priority(in context: CompletionContext) -> Int {
            switch context.position {
            case .fromList, .joinList, .updateTarget, .insertTarget, .truncateTarget, .objectTarget:
                switch self {
                case .table: return 0
                case .schema: return 1
                case .column: return 2
                case .function: return 3
                case .keyword: return 4
                }
            case .schemaTarget:
                // Naming an existing schema — schema names win outright. This
                // is what keeps `DROP SCHEMA val…` from preferring `VALUES`
                // over the `validate_…` schema (GH #5).
                switch self {
                case .schema: return 0
                case .table: return 1
                case .column: return 2
                case .function: return 3
                case .keyword: return 4
                }
            case .selectList, .whereClause, .onClause, .groupByClause, .orderByClause,
                 .setClause, .returningClause, .insertColumnsList:
                switch self {
                case .column: return 0
                case .table: return 1
                case .function: return 2
                case .schema: return 3
                case .keyword: return 4
                }
            case .unknown:
                switch self {
                case .keyword: return 0
                case .table: return 1
                case .column: return 2
                case .schema: return 3
                case .function: return 4
                }
            }
        }
    }

    static func == (lhs: CompletionItem, rhs: CompletionItem) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

// MARK: - Fuzzy matcher

/// Subsequence fuzzy matcher: returns a score if every character of `partial`
/// appears in `candidate` in order (case-insensitive). Only used as a
/// fallback in `SQLCompletionProvider.completions` — prefix matches are
/// preferred outright.
enum FuzzyMatcher {
    struct Score {
        let consecutiveScore: Int
        let matchedRanges: [Range<String.Index>]
    }

    static func score(partial: String, candidate: String) -> Score? {
        guard !partial.isEmpty else { return nil }
        let lowerPartial = partial.lowercased()
        let lowerCandidate = candidate.lowercased()

        var pIdx = lowerPartial.startIndex
        var cIdx = lowerCandidate.startIndex
        var matched: [Range<String.Index>] = []
        var consecutiveScore = 0
        var streak = 0
        var candidateOriginalIdx = candidate.startIndex

        while pIdx < lowerPartial.endIndex, cIdx < lowerCandidate.endIndex {
            if lowerPartial[pIdx] == lowerCandidate[cIdx] {
                let nextOriginal = candidate.index(after: candidateOriginalIdx)
                matched.append(candidateOriginalIdx ..< nextOriginal)
                pIdx = lowerPartial.index(after: pIdx)
                streak += 1
                consecutiveScore += streak
            } else {
                streak = 0
            }
            cIdx = lowerCandidate.index(after: cIdx)
            candidateOriginalIdx = candidate.index(after: candidateOriginalIdx)
        }
        guard pIdx == lowerPartial.endIndex else { return nil }
        return Score(consecutiveScore: consecutiveScore, matchedRanges: matched)
    }
}

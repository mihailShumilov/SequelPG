---
name: SequelPG codebase structure and audit findings
description: Architecture, key file locations, SQL patterns, and correctness issues found during the 2026-04-04 audit of the SequelPG macOS PostgreSQL client
type: project
---

# SequelPG Codebase — Audit Findings (2026-04-04)

## Architecture
Strict MVVM: Views → ViewModels (@MainActor) → Services → PostgresNIO

Key files:
- Services/PostgresClient.swift — DatabaseClient actor, all DB access, introspection, cell decoding
- Services/SSHTunnelService.swift — SSH tunnel via system ssh binary, SSH_ASKPASS for passwords
- Services/ConnectionStore.swift — UserDefaults-backed profile persistence
- Services/KeychainService.swift — macOS Keychain for passwords
- Utilities/QuoteIdent.swift — quoteIdent() doubles double-quotes, wraps in double-quotes
- Utilities/QuoteLiteral.swift — quoteLiteral() escapes single-quotes, handles NULL
- ViewModels/AppViewModel.swift — root coordinator, all SQL-building logic for INSERT/UPDATE/DELETE/cascade
- ViewModels/TableViewModel.swift — pagination state, content result, column metadata
- ViewModels/QueryViewModel.swift — query editor state, client-side sort, parseTableFromQuery

## Known Issues Found in Audit

### Critical
1. PSQLError.sqlState parsed via String(reflecting:) — fragile, will break on PostgresNIO version changes (PostgresClient.swift ~line 194)
2. listSchemas() silently excludes pg_toast and pg_temp_* schemas; query should use NOT LIKE 'pg_%' or pg_catalog-level filter
3. getApproximateRowCount returns -1 as 0 (via max(count,0)) but pg_class.reltuples = -1 means stats not collected yet — callers treat 0 as "empty table"
4. quoteLiteral handles only text strings — binary, numeric, array, JSON values all go through text path with no type casting; UPDATE/INSERT of numeric columns without explicit cast may fail depending on column type
5. Cell decoding: float4/float8 decoded to Swift Float/Double then String — loses precision (6-7 decimal digits for Float); should use Decimal or higher-precision path
6. Date cell decoding for .date type allocates a new DateFormatter on every row — should be a static/cached formatter like dateFormatter

### High Priority
7. listTables/listViews/getColumns/getPrimaryKeys use manual single-quote escaping (.replacingOccurrences) instead of parameterized queries — correct but fragile pattern; inline-escape is fine for introspection but inconsistent with the rest of the codebase
8. executeCascadeDelete builds CTE with per-child WHERE using only direct PK values — does not handle grandchildren (child-of-child FKs), will leave grandchild rows causing the cascade DELETE to fail with another FK error
9. loadContentPage passes maxRows: limit to runQuery — if limit=50, isTruncated is never set because the query itself only returns ≤50 rows; the LIMIT in SQL and maxRows in Swift are identical, so the truncation flag will never fire for content paging
10. Timeout implementation: withThrowingTaskGroup races query task vs. sleep task — on timeout, the query task is cancelled but the underlying PostgresNIO connection is not explicitly cancelled; PSQLError from the ongoing query may arrive after the timeout error is reported
11. parseTableFromQuery regex uses \w+ which only matches ASCII word chars — Unicode table names (e.g., "заказы") won't be detected for inline editing

### Medium Priority
12. switchDatabase reconnects by calling connect() with a new profile — tears down and re-establishes SSH tunnel if one is configured; could reuse existing tunnel
13. DBObject.id = "\(schema).\(name)" — not unique if schema="a.b" and name="c" vs schema="a" and name="b.c"; unlikely but possible
14. commitInsertRow skips empty fields entirely (lets DB use DEFAULT/NULL) but does not skip columns with no default that are NOT NULL — the INSERT will fail at DB level; could improve by pre-validating against ColumnInfo.isNullable + columnDefault
15. getColumns decodes ordinal_position as Int (Swift Int = Int64 on 64-bit) but pg returns int4 — should decode as Int32 to be explicit
16. listSchemas filter: WHERE schema_name NOT IN ('pg_catalog', 'information_schema') — does not exclude pg_toast, pg_temp_NNN schemas that appear on some servers
17. SSL mode only supports off/prefer/require — missing verify-ca and verify-full (most secure options for production)

## PostgreSQL Version Support
Not explicitly declared. No version detection. Uses information_schema queries (all versions), pg_class/pg_index (all versions), pg_constraint with LATERAL unnest (PG9.4+, safe).

## SQL Building Patterns
- Identifiers: always via quoteIdent() — correct
- Literals in DML: always via quoteLiteral() — correct, but text-only
- Introspection queries: manual single-quote escaping — correct but inconsistent
- User-executed SQL: passed through unsafeSQL — intentional (user is the author)
- Cascade CTE: built dynamically with quoteIdent + quoteLiteral — correct for supported cases

# SequelPG

A lightweight, native macOS PostgreSQL client inspired by Sequel Pro.

## Requirements

- macOS 14.4 (Sonoma) or later
- Xcode 15.0 or later
- Swift 5.9+

## Build & Run

```bash
# Clone the repository
git clone <repo-url> && cd SequelPG

# Open in Xcode
open SequelPG.xcodeproj

# Or build from command line
xcodebuild -project SequelPG.xcodeproj -scheme SequelPG -configuration Debug build
```

Select the **SequelPG** scheme and press **Cmd+R** to run.

## Running Tests

```bash
xcodebuild test -project SequelPG.xcodeproj -scheme SequelPG -destination 'platform=macOS'
```

Or use **Cmd+U** in Xcode.

## Feature Checklist

- [x] Connection management (add, edit, delete, connect, disconnect)
- [x] Keychain-backed password storage with in-memory caching
- [x] SSL mode toggle (Off / Prefer / Require / Verify-CA / Verify-Full)
- [x] SSH tunnel support (key file or password auth)
- [x] Hierarchical tree navigator (databases, schemas, 17 object categories)
- [x] PG version-adaptive object categories (e.g., Procedures for PG 11+)
- [x] Multi-database browsing (expand any database to see its schemas)
- [x] iTerm2-style tabs (Cmd+T) for multiple connections in one window
- [x] Structure tab (column details)
- [x] Content tab with pagination (50 / 100 / 200 rows)
- [x] Single-click inline cell editing with auto-save
- [x] Insert and delete records
- [x] Schema editing (add/drop/rename columns, change types, toggle nullable)
- [x] SQL editor with syntax highlighting, autocompletion, and query formatter
- [x] Query timeout (10s default, server-side `statement_timeout`)
- [x] Query result row cap (2000 rows)
- [x] Execution time display
- [x] Native Table grid with column sorting
- [x] Right inspector panel (object name, row count, column count)
- [x] Create database, schema, table, view, function, sequence, type, and domain from navigator
- [x] Drop any database object from navigator context menu
- [x] Object Definition tab (DDL/source viewer for views, functions, sequences, types, etc.)
- [x] Content filter bar (Cmd+F) with column/operator/value filtering and SQL preview
- [x] Type-aware field editor (JSON, array, boolean, long text) in Inspector
- [x] Connection status indicators
- [x] Disconnect menu item (Cmd+Shift+W)

## Architecture Overview

SequelPG follows **MVVM** with strict layer boundaries:

```
Views (SwiftUI)
  |
ViewModels (@MainActor, @Observable)
  |
Services (PostgresClient, ConnectionStore, KeychainService)
  |
PostgresNIO (database driver)
```

### Key Modules

| Module             | Responsibility                                    |
| ------------------ | ------------------------------------------------- |
| `Models/`          | Data types: ConnectionProfile, QueryResult, etc.  |
| `Services/`        | Database access, persistence, Keychain            |
| `ViewModels/`      | UI state management, business logic               |
| `Views/`           | SwiftUI views only; no direct DB or storage calls |
| `Utilities/`       | Pure helpers: identifier quoting, logging          |

### Performance Choices

- **Single PostgresNIO client** with connection pooling (max 4 connections).
- **Schema/table/column caching** to avoid redundant introspection queries.
- **Pagination** with LIMIT/OFFSET for content browsing (50/100/200 rows).
- **Approximate row counts** via `pg_class.reltuples` instead of COUNT(*), with fallback to COUNT(*) when `reltuples = -1`.
- **Hard cap of 2000 rows** on query results to prevent memory issues.
- **10-second query timeout** with server-side `statement_timeout` and client-side Task cancellation.
- **Lazy string truncation** for large text fields (10K char limit in UI).
- **Native Table** with `TableColumnForEach` for dynamic columns, built-in cell reuse, and sort indicators.
- **Per-property @Observable tracking** eliminates unnecessary view re-renders (no Combine dependency).
- **Memoized sort results** with lazy cache and O(1) row index lookups.

## Code Style

SwiftFormat is used for consistent formatting. See [CONTRIBUTING.md](CONTRIBUTING.md) for details.

```bash
./Scripts/format.sh
```

## Known Limitations

- No custom SSL certificate management (verify-ca and verify-full modes available).
- No CSV import/export.
- No ER diagrams.
- No user/role management.
- No triggers/procedures editing UI (view-only via Definition tab).
- No schema diff.
- No multi-window support.
- Stop button in query editor is disabled if driver-level cancellation is not supported.

## Troubleshooting

### Connection Refused
- Verify PostgreSQL is running on the specified host and port.
- Check `pg_hba.conf` allows connections from your machine.

### Authentication Failed
- Double-check username and password.
- Ensure the user has access to the specified database.

### SSL Errors
- If using SSL Require, ensure the server supports SSL.
- Try SSL Prefer or Off to diagnose.

### Timeout Errors
- The default query timeout is 10 seconds.
- Long-running queries will be cancelled automatically.

## License

MIT. See [LICENSE](LICENSE).

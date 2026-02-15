# SequelPG

A lightweight, native macOS PostgreSQL client inspired by Sequel Pro.

## Requirements

- macOS 13.0 (Ventura) or later
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
xcodebuild -project SequelPG.xcodeproj -scheme SequelPGTests -configuration Debug test
```

Or use **Cmd+U** in Xcode.

## Feature Checklist

- [x] Connection management (add, edit, delete, connect, disconnect)
- [x] Keychain-backed password storage
- [x] SSL mode toggle (Off / Prefer / Require)
- [x] Database navigator (schemas, tables, views)
- [x] Structure tab (column details)
- [x] Content tab with pagination (50 / 100 / 200 rows)
- [x] Query editor with Cmd+Enter execution
- [x] Query timeout (10s default)
- [x] Query result row cap (2000 rows)
- [x] Execution time display
- [x] Right inspector panel (object name, row count, column count)
- [x] Connection status indicators

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
- **Approximate row counts** via `pg_class.reltuples` instead of COUNT(*).
- **Hard cap of 2000 rows** on query results to prevent memory issues.
- **10-second query timeout** with client-side Task cancellation.
- **Lazy string truncation** for large text fields (10K char limit in UI).
- **Stable identifiers** in SwiftUI Table to minimize re-rendering.

## Code Style

SwiftFormat is used for consistent formatting. See [CONTRIBUTING.md](CONTRIBUTING.md) for details.

```bash
./Scripts/format.sh
```

## Known Limitations

- No SSH tunnel support.
- No SSL certificate management (only mode toggle).
- No CSV import/export.
- No ER diagrams.
- No user/role management.
- No triggers/procedures UI.
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

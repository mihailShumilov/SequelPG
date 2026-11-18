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
- [x] Test connection without disturbing the active session
- [x] Keychain-backed password storage with in-memory caching
- [x] SSL mode toggle (Off / Prefer / Require / Verify-CA / Verify-Full)
- [x] SSH tunnel support (key file or password auth)
- [x] Hierarchical tree navigator (databases, schemas, 17 object categories) with a filter field
- [x] PG version-adaptive object categories (e.g., Procedures for PG 11+)
- [x] Multi-database browsing (expand any database to see its schemas)
- [x] Native window tabs (⌘T) and windows (⌘N) for multiple connections
- [x] Connections toolbar menu and File menu to open saved connections in new tabs and edit the live connection
- [x] Structure tab with column, index, constraint, trigger, and partition sections
- [x] Content tab with pagination (50 / 100 / 200 rows)
- [x] Double-click cell editing through a type-aware editor sheet, saved immediately
- [x] Insert (form with per-column type/default hints) and delete records (with cascade-delete prompt for FK violations)
- [x] Schema editing (add/drop/rename columns, change types, toggle nullable — double-click to edit)
- [x] Index creation sheet
- [x] SQL editor with syntax highlighting, autocompletion, native find bar, query formatter, and a configurable font
- [x] Query history log of every system- and user-issued query
- [x] Query timeout (10s default, server-side `statement_timeout`)
- [x] Query result row cap (2000 rows)
- [x] Execution time display
- [x] AppKit `DataGridView` results grid: type-aware cell rendering, vertical dividers, column sorting, multi-select
- [x] Native inspector panel (⌥⌘I): object facts and the selected row with type-aware editing
- [x] Create database, schema, table, view, function, sequence, type, and domain from navigator
- [x] Drop any database object from navigator context menu
- [x] Object Definition tab (DDL/source viewer for views, functions, sequences, types, etc.)
- [x] Database-tools sheets: Extensions, Roles, SQL Function Library reference
- [x] Content filter bar (Cmd+F) with column/operator/value filtering and SQL preview
- [x] Type-aware field editor (JSON, array, boolean, long text) in Inspector
- [x] Connection status indicators
- [x] Database and Query menus with shortcuts (Refresh ⌘R, Disconnect ⇧⌘W, Run ⌘↩, Stop ⌘., Explain ⌥⌘E, Beautify ⇧⌘F)
- [x] Structure / Content / Definition / Query / Diagram mode switcher in the toolbar (⌘1–⌘5)
- [x] Light and Dark appearance with system colors and the user's accent color
- [x] MCP server for AI assistants (Claude Code, Claude Desktop, Cursor): schema browsing and read-only queries on the connections you share

## AI Assistants (MCP)

SequelPG can serve the connections you choose to AI assistants that support the [Model Context Protocol](https://modelcontextprotocol.io).

1. Open **Settings → MCP** and turn on **Enable MCP server**.
2. Edit each connection the assistant may use and set **MCP Access** to **Read-only**. Other connections stay invisible.
3. In **Settings → MCP → Connect a Client**, click **Add** next to Claude Code, Claude Desktop or Cursor. For other clients, use **Copy JSON Config**; the entry runs `SequelPG.app/Contents/MacOS/SequelPG --mcp-stdio`.
4. The first time a client calls a tool, SequelPG asks whether to allow it. Allowed clients are listed in Settings, where you can revoke them.

Tools: `list_connections`, `list_databases`, `list_schemas`, `list_objects`, `describe_table`, `get_ddl`, `run_query`, `explain_query`.

How it works:
- The client starts the SequelPG executable with `--mcp-stdio`. That process only forwards messages to the running app over a private Unix socket (`~/Library/Application Support/SequelPG/mcp.sock`), and opens SequelPG in the background when it isn't running. Passwords, SSH tunnels and connections stay inside the app.
- MCP queries use their own sessions, so they never change the database or interrupt a query in your windows.
- `run_query` runs exactly one `SELECT`, `WITH`, `VALUES`, `TABLE`, `SHOW` or `EXPLAIN` statement in a `READ ONLY` transaction that is always rolled back, with a 30-second `statement_timeout` and up to 1000 rows. Everything else (`DO`, `CALL`, `COPY`, `SET`, maintenance commands, several statements at once) is rejected, and advisory locks a query takes are released afterwards.
- Up to 4 tool calls run at once, and at most 6 database sessions stay open; idle ones close after 5 minutes.
- The server switch, allowed clients and which connections are shared are stored in the Keychain, so another program can't turn them on by editing SequelPG's preferences.

Security notes:
- Query results are sent to the assistant's model provider. Share only connections whose data you're allowed to send there.
- A read-only transaction is not a sandbox: functions with side effects (`pg_terminate_backend`, `dblink_exec`…) still run. Share connections that use a role with only the privileges the assistant needs, such as `SELECT` on your schemas. SequelPG refuses superusers and members of `pg_execute_server_program`, `pg_write_server_files` and `pg_read_server_files`.
- The approval prompt uses the name the client reports about itself; it guards against surprises, not against software already running under your user account.

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
| `Services/`        | Database access, persistence, Keychain, MCP server |
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
- **AppKit `DataGridView`** results grid: type-aware cell rendering, vertical cell dividers, native single-click selection and multi-select, and binary-wire decoding of numeric / money / inet / cidr / macaddr / jsonb / composite types.
- **Per-property @Observable tracking** eliminates unnecessary view re-renders (no Combine dependency).
- **Memoized sort results** with lazy cache and O(1) row index lookups.

## Code Style

SwiftFormat is used for consistent formatting. See [CONTRIBUTING.md](CONTRIBUTING.md) for details.

```bash
./Scripts/format.sh
```

## Known Limitations

- No custom SSL certificate management (verify-ca and verify-full modes available).
- No CSV import (CSV/JSON export of result rows is available from the results footer).
- No user/role management.
- No triggers/procedures editing UI (view-only via Definition tab).
- No schema diff.

## Troubleshooting

### Connection Refused
- Verify PostgreSQL is running on the specified host and port.
- Check `pg_hba.conf` allows connections from your machine.

### Authentication Failed
- Double-check username and password.
- Ensure the user has access to the specified database.

### SSL Errors
SSL modes follow `psql`'s `sslmode`:
- **Prefer** (the default) uses SSL when the server offers it and connects without SSL otherwise.
- **Require** always encrypts but does not verify the server certificate, so self-signed certificates work.
- **Verify CA** and **Verify Full** also check the certificate against the system's trusted roots (Verify Full checks the host name too).

When a connection fails, the error names the cause and which SSL Mode to try.

### Timeout Errors
- The default query timeout is 10 seconds.
- Long-running queries will be cancelled automatically.

## License

MIT. See [LICENSE](LICENSE).

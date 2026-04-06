# Changelog

All notable changes to SequelPG will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

## [0.1.9] - 2026-04-06

### Added
- Object Definition tab: view DDL/source for views, functions, sequences, types, domains, materialized views, operators, and more.
- Object CRUD: drop any database object (table, view, function, sequence, type, domain, collation, foreign table, FTS objects, operator, etc.) with confirmation dialog.
- Create object sheets: create views, materialized views, functions, sequences, types, and domains from the navigator context menu.
- Generic create sheet for remaining object categories with a raw SQL editor.
- Content filter bar (`Cmd+F`): filter rows by column, operator (contains, equals, not equals, greater/less than, starts/ends with, is null/not null), and value. Supports multi-filter with AND logic and SQL preview popover.
- Type-aware field editor: rich popover editor in the Inspector for JSON (pretty-printed), arrays (indexed list), booleans (toggle), and long text (multi-line). Falls back to inline editing for plain values.
- Inspector type badges: each column value in the Inspector now shows a colored data-type badge (JSON, array, boolean, text).
- Navigator context menus: right-click any object to drop it; right-click a schema to create new objects.
- `getObjectDDL(schema:name:type:)` protocol method for retrieving object definitions from `pg_catalog`.

### Changed
- Non-table objects now default to the Definition tab instead of Structure when selected.
- Content pagination bar includes a filter toggle button with active-filter indicator.
- Inspector value rendering: JSON values show a pretty-printed preview (4-line max), arrays show indexed items (5-item max), booleans show checkmark/cross icons.

## [0.1.8] - 2026-04-06

### Added
- iTerm2-style tabs: Cmd+T opens a new tab within the same window, each with its own independent database connection.
- Hierarchical tree navigator with DisclosureGroups: databases > schemas > object categories > objects.
- 17 pgAdmin-style object categories: Aggregates, Collations, Domains, FTS Configurations, FTS Dictionaries, FTS Parsers, FTS Templates, Foreign Tables, Functions, Materialized Views, Operators, Procedures, Sequences, Tables, Trigger Functions, Types, Views.
- PG version-adaptive categories: Procedures category only shown for PostgreSQL 11+; aggregate/trigger queries adapt to pre-11 catalog schema.
- Server version detection on connect via `SHOW server_version_num`.
- Multi-database browsing: expanding any database in the tree fetches its schemas (switches connection temporarily if needed).
- Create database, schema, and table from the navigator "+" menu.
- Schema editing in Structure tab: add/drop columns, rename, change type, toggle nullable, change default via ALTER TABLE.
- Single-click cell editing with auto-save on focus loss (replaces double-click + Enter).
- In-place cell updates after edit (preserves row order instead of re-fetching).
- `listAllSchemaObjects(schema:)` bulk protocol method for parallel fetching of all object types.

### Changed
- Navigator is now a tree view replacing the flat database/schema pickers.
- AppViewModel is per-tab (no longer owns ConnectionListViewModel); shared ConnectionListViewModel injected via environment.
- Connected sidebar only shows the Navigator tree (connection list removed).
- Cell editing: clicking a cell selects the row and updates the Inspector panel.
- `QueryResult.rows` changed from `let` to `var` to support in-place cell updates.

### Removed
- Flat database and schema picker dropdowns (replaced by tree navigator).
- ConnectionListView from the connected sidebar.

## [0.1.7] - 2026-04-04

### Changed
- Bump minimum deployment target from macOS 13 to macOS 14.4.
- Migrate all ViewModels from `ObservableObject`/`@Published` to `@Observable` with per-property tracking, eliminating unnecessary view re-renders.
- Replace `@EnvironmentObject` with `@Environment(Type.self)` across all views.
- Replace custom `ScrollView`+`LazyVStack` grid with native `Table` using `TableColumnForEach` for dynamic columns and built-in cell reuse.
- Add `ColumnSortComparator` for native Table header sort indicators.
- Update all `onChange(of:)` calls to non-deprecated two-parameter form.

### Removed
- Combine dependency (`objectWillChange` forwarding, `AnyCancellable`).
- Obsolete `objectWillChange` publisher tests.

## [0.1.6] - 2026-03-28

### Fixed
- **Security:** Replace `PSQLError` `String(reflecting:)` hack with structured `serverInfo` API.
- **Security:** SSH password delivery via FIFO instead of temp file on disk.
- **Security:** SSH host key verification changed from `accept-new` to strict.
- **Security:** Keychain items use `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`.
- **Security:** `quoteLiteral` uses `E'...'` escape syntax with backslash safety.
- **Security:** SSH stderr filtered before display; key path validated before launch.
- **Security:** Password cache cleared on disconnect.
- **Security:** Connection-loss SQL states (08xxx) detected and surfaced.
- **PostgreSQL:** `float4` decoded as `Double` to prevent precision loss on round-trip.
- **PostgreSQL:** `reltuples = -1` (never analyzed) falls back to `COUNT(*)`.
- **PostgreSQL:** DML uses typed casts (`quoteLiteralTyped`) for non-text columns.
- **PostgreSQL:** Server-side `statement_timeout` set per query.
- **PostgreSQL:** Schema listing excludes `pg_toast`/`pg_temp` via `NOT LIKE 'pg_%'`.
- **PostgreSQL:** SSH tunnel preserved on database switch (no teardown/rebuild).
- **PostgreSQL:** `ordinal_position` decoded as `Int32` then widened.
- **PostgreSQL:** `DBObject.id` uses null separator to prevent collisions.
- **PostgreSQL:** NOT NULL pre-flight validation in `commitInsertRow`.
- **PostgreSQL:** `parseTableFromQuery` supports Unicode identifiers.
- **PostgreSQL:** Cascade FK query uses `quoteLiteral` instead of manual escaping.
- **PostgreSQL:** Navigator refresh button invalidates introspection cache.

### Added
- SSL `verify-ca` and `verify-full` modes.

### Changed
- **Performance:** Remove `objectWillChange` forwarding; inject child VMs as `@EnvironmentObject`.
- **Performance:** Memoize `sortedResult` with lazy cache and O(1) `originalRowIndex` via index map.
- **Performance:** Guard `selectObject` against re-selection (avoids 12 mutations + 2 DB queries).
- **Performance:** `NavigatorView` `onAppear` only loads if tables are empty.
- **Performance:** Cache `hasPrimaryKey` in `TableViewModel.setColumns`.
- **Performance:** Pre-build `colInfoByName` dictionary in insert row view (O(n) vs O(n²)).
- **Performance:** `SQLEditorView` skips `updateNSView` when metadata is unchanged.
- **Performance:** `ResultsGridView` uses enumerated `ForEach` for proper identity diffing.
- **Performance:** `CellValue` truncation moved to decode time with static `DateFormatter`.
- **Performance:** Focus set directly instead of `DispatchQueue.main.asyncAfter` hack.
- **Code quality:** Extract shared helpers and views to reduce duplication across 36 files.

## [0.1.5] - 2026-03-10

### Added
- SQL editor with token-based syntax highlighting (keywords, strings, comments, numbers, operators).
- Autocompletion from SQL keywords and database metadata (schemas, tables, columns).
- Beautify button that formats queries with proper indentation and auto-quotes mixed-case identifiers.
- New files: `SQLFormatter`, `SQLSyntaxColors`, `SQLTextStorage`, `SQLCompletionProvider`, `SQLEditorView`.

### Fixed
- Empty query results showing "Query executed successfully" instead of column headers when a SELECT returns 0 rows.

## [0.1.4] - 2026-03-01

### Added
- SSH tunnel support via local port forwarding using the system `ssh` binary.
- Key file and password authentication for SSH connections.
- SSH settings on both the start page and the connection form sheet.
- `SSHTunnelService` actor managing SSH process lifecycle.
- SSH passwords stored in Keychain under a separate key per profile.
- Custom app icon (PostgreSQL elephant + `<SQL>`) at all macOS sizes.
- File > Disconnect menu item (`Cmd+Shift+W`) to return to start page.
- `CLAUDE.md` for Claude Code onboarding.

### Fixed
- Start page now uses the actual app icon instead of a generic SF Symbol.
- In-memory password cache eliminates repeated Keychain reads when switching connections.

## [0.1.3] - 2026-02-28

### Changed
- GitHub releases are now published as non-draft.

## [0.1.2] - 2026-02-25

### Added
- GitHub Action to build DMG and publish releases.

## [0.1.1] - 2026-02-20

### Added
- GitHub Action to build DMG and publish releases (initial setup).
- Rebuilt start screen.
- Delete and insert records functionality.
- Edit data in right sidebar.
- Inline data editing.
- Keyboard navigation between data rows.
- Detailed row view.
- Database switcher.

### Fixed
- Type-aware cell decoding and grid layout.
- Preserve active tab on table switch and show empty table columns.
- Single-click connection from connections list.
- HStack layout and unchecked Sendable for stability.
- Propagate nested ObservableObject changes to parent.

## [0.1.0] - 2026-02-15

### Added
- Initial release of SequelPG.
- Connection management with Keychain-backed password storage.
- Database navigator with schema, table, and view browsing.
- Structure tab showing column details.
- Content tab with paginated row browsing.
- Query editor with execution, timeout, and result row limits.
- SSL mode support (Off / Prefer / Require).
- Right inspector panel with object metadata.

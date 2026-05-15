# Changelog

All notable changes to SequelPG will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

### Added
- **Editorial app theme.** New `Theme` design system — warm-charcoal canvas (`#14130f`), phosphor-lime accent (`#b9f25a`), Instrument Serif italic headlines for object names and section titles, JetBrains Mono for identifiers / types / counts / SQL. Bundled font files ship in `Resources/Fonts/` and register at app launch.
- **Lime selection across the board.** Sidebar selection, results-grid row selection, primary buttons, tab indicators, the SQL editor caret and active-line gutter all use the lime accent instead of macOS blue. `AccentColor` asset now drives the system control tint.
- **Editorial chrome on every tab.** Italic-serif object titles (`orders`, `users`) above each tab, roman-numeral kicker labels (`i. — definition`, `ii. — connection`), dotted-rule dividers, monospaced row-count meta — translated faithfully from the SequelPG site mockups.
- **Type-pill column headers and inspector rows.** Each column carries a tiny uppercase pill in violet / mauve / amber / cyan depending on whether the type is built-in PG, user-defined, JSON, or temporal.
- **Refined Slonik mark.** New app icon (Option C from the icons design): figurative elephant head with curled trunk, ear, tusk, and eye. Bundled at every macOS AppIcon size from 16px to 1024px.

### Changed
- SQL syntax highlighting palette retuned to match the editorial tokens — keywords in cool blue, functions in violet, strings in rose, numbers in amber, comments in muted ink. The Definition and Query tabs share the same colors.
- Object tabs in the main area now render with a 2px lime top accent on the active tab and a monospaced label, replacing the rounded-pill background.
- Inspector lays out as an editorial card — italic section titles, dotted rules between rows, type-pill keys, monospaced values.
- Connection picker and the in-tab connection form now use roman-numeral sections (`ii. — connection`, `iii. — SSH tunnel`) and a solid lime Connect / Save button.
- Empty states across the app are now italic-serif headlines (`A fresh query.`, `Pick a table.`) with editorial roman-numeral kickers and keyboard-cap chips for the next action.
- Window forces dark color scheme app-wide. Light mode would tear the type colors and is no longer a supported appearance.

## [0.1.13] - 2026-05-12

### Added
- **Run / Call sheet** for functions and procedures. Right-click a routine in the navigator (or use the toolbar button on its Definition tab) to open a focused builder: one row per input parameter with a Value / Expression / NULL / DEFAULT mode picker, live SQL preview, and an inline result pane that shapes itself to the return kind (scalar value box, multi-row grid for `SETOF` / `RETURNS TABLE`, "completed" status for procedures). Trigger functions and aggregates explain themselves instead of producing an invalid call.
- **Full CREATE TABLE in the Definition tab**. Tables now reconstruct their DDL from `pg_catalog`: columns with type / default / identity / generated / NOT NULL, table-level constraints in canonical order, `PARTITION BY` for partitioned parents, secondary `CREATE INDEX` statements (skipping the ones backing constraints), and table / column comments.
- **Syntax-highlighted Definition tab** for every entity type — uses the same tokenizer and colors as the SQL editor instead of plain monospaced text.
- Working **Test Connection** button on the start page detail form and the modal add/edit form. Runs validation, opens a throwaway connection so the active session isn't disturbed, and reports a green success banner or selectable red error message inline.

### Changed
- Navigator selection is applied synchronously so the List binding never sees a stale value, which previously caused parent DisclosureGroups to collapse the moment you clicked a leaf row.
- Disclosure-group **labels** in the navigator (database, schema, category) are now clickable to expand or collapse, not just the chevron.

### Fixed
- PG17+ named NOT-NULL constraints (`contype = 'n'`) are filtered out of the reconstructed CREATE TABLE so the per-column `NOT NULL` isn't duplicated as a `CONSTRAINT … NOT NULL col` line.
- Function-metadata query was returning an empty parameter list. `proargtypes` is an `oidvector` with 0-based indexing; the array was re-aggregated through `unnest WITH ORDINALITY` so PostgresNIO's 1-based-only array decoder accepts it.

## [0.1.11] - 2026-04-19

### Added
- Database-tools sheets: Extensions (list / enable / disable), Roles (`pg_roles` metadata browser), SQL Function Library reference.
- Structure tab now lists Indexes, Constraints, and Triggers with drop confirmations; new Index creation sheet.
- Partitions section for partitioned tables.
- Query History view with `QueryHistoryViewModel` logging every system- and user-issued query (status, duration, row count).
- Result grid rebuilt on AppKit (`DataGridView`): native single-click selection, multi-select, vertical cell dividers, type-aware cell rendering (numeric, money, inet/cidr/macaddr, jsonb, composite types decoded from binary wire format), and richer column headers.
- Dockerized PostgreSQL 18 demo database under `dev-db/` for local testing.

### Changed
- All internal catalog queries use `PostgresQuery` parameter bindings instead of manual quote-doubling.
- `CascadeDeleteBuilder` extracts the SQL-construction path from `executeCascadeDelete` for testability.
- `ConnectionFormModel` consolidates 14 parallel `@State` fields shared by `ConnectionFormView` and `StartPageView`.
- `RowDeleteConfirming` protocol formalizes the delete-row prompt concern shared by table views.
- `decodeCellValue` is table-driven via a `PostgresDataType → decoder` dictionary.
- `ConnectionProfile` drops manual `init(from:)` in favor of `@DecodableDefault` property wrappers.

### Fixed
- First-click row selection, multi-select, and the freeze that could occur when editing `jsonb` cells.
- Composite-type values now render correctly in the results grid.
- Function navigator entries round-trip through `regprocedure` so overload-qualified names survive.
- Type select no longer raises an error toast; aggregate DDL output is no longer truncated; PSQL errors surface with their underlying message instead of an opaque wrapper.
- Skipped `SELECT *` against non-relation objects (composite types, sequences, functions) that produced "cannot open relation" errors.
- Content grid stays mounted during reload to stop the visible blink.
- `float4` decoded as `Double` and `numeric` / `money` decoded from binary to prevent precision loss.

## [0.1.10] - 2026-04-06

### Changed
- Documentation refresh covering the v0.1.9 feature set (Object Definition tab, object CRUD, content filters, type-aware editor).

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

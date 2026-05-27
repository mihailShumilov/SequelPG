---
name: Code Smells Found
description: Recurring smells, duplication hotspots, and anti-patterns found in the first full codebase review (2026-04-04)
type: project
---

## Critical / High Priority

1. **SQL injection in introspection queries (DatabaseClient.swift)** — listTables, listViews, listMaterializedViews, listFunctions, listSequences, listTypes, getColumns, getPrimaryKeys, getApproximateRowCount, listAllSchemaObjects all use manual `.replacingOccurrences(of: "'", with: "''")` for schema/table escaping instead of parameterised queries. Lines ~357, ~377, ~398, ~419, ~441, ~464, ~697-705, ~738-742, ~766-775. This is inconsistent — some functions escape (listMaterializedViews, listFunctions, listSequences, listTypes) and some do not escape at all (listTables line 357, listViews line 377).

2. **NavigatorView directly calls appVM.dbClient** — NavigatorView.createDatabase(), createSchema(), createTable() bypass AppViewModel and call appVM.dbClient.runQuery() directly (lines ~218, ~229, ~252). This violates the MVVM layer boundary documented in CLAUDE.md; these operations should go through AppViewModel methods.

3. **Duplication: makePKColumn/makeColumn/setupContentState/setupQueryState in tests** — These four helpers are duplicated verbatim between CascadeDeleteTests and InsertDeleteTests. Should be moved to AppViewModelTestCase base class.

## Medium Priority

4. **Duplicate TLS configuration switch in DatabaseClient** — The switch over `profile.sslMode` to build `PostgresClient.Configuration.TLS` is copy-pasted identically in connect() (~lines 70-82) and switchDatabase() (~lines 848-860). Should be extracted to a private helper `makeTLSConfig(for:)`.

5. **Duplicate SSH tunnel startup logic in switchDatabase()** — The SSH tunnel setup block (lines ~829-846) in switchDatabase() partially mirrors the connect() tunnel setup (lines ~55-67). The reconnection path should call a shared helper.

6. **AppViewModel.executeCascadeDelete() is very long (~126 lines)** — Contains inline struct definition (ChildFK), FK metadata query, CTE building loop, SQL execution, and refresh logic. Should be split into smaller private methods.

7. **objectIcon computed property on ObjectCategory is an identity alias** — `var objectIcon: String { icon }` (NavigatorViewModel.swift line 46) is dead weight — the property is identical to `icon`. Callers can just use `icon` directly.

8. **InspectorView has duplicate display code for editable/non-editable cell** — Lines ~89-103 render the same `Text(value.displayString)` with the same styling in two branches; the only difference is `.textSelection(.enabled)` in the non-editable branch. Extract a shared view component.

9. **Magic number 2000 for query max rows** — Hardcoded in AppViewModel.executeQuery() line ~304 and referenced by user-visible string "(capped at 2000)" in QueryTabView. Should be a named constant.

10. **Magic number 10.0 for query timeout** — Used in ~8 places throughout AppViewModel (loadContentPage, updateContentCell, updateQueryCell, deleteContentRow, deleteQueryRow, commitInsertRow, executeCascadeDelete) and StructureTabView.executeSchemaChange(). Should be a named constant.

## Lower Priority

11. **NSRegularExpression compiled on every call in QueryViewModel.parseTableFromQuery()** — `try? NSRegularExpression(pattern: pattern)` is called every time the method runs. Should be a static/lazy stored property.

12. **SchemaObjects.objects(for:) switch is a large switch that mirrors ObjectCategory enum** — Every time a new ObjectCategory case is added, this switch must also be updated. The pattern is mechanical and error-prone. Consider a KeyPath-based approach or a computed subscript.

13. **QueryViewModel.showErrorDetail is never read** — The property is declared and set to `false` as initial state but never toggled in the codebase. It appears to be dead/speculative code.

14. **ColumnInfo.id computed from ordinalPosition + name** — If ordinal position changes (ALTER TABLE), the ID changes, which could break SwiftUI List diffing. Consider using name alone or a UUID.

15. **ConnectionListViewModel.setConnected() iterates all keys to reset** — The loop `for key in connectionStatuses.keys { connectionStatuses[key] = .disconnected }` at line 116-118 could be replaced with `connectionStatuses.removeAll()` or `connectionStatuses = [profileId: .connected]` for clarity.

## Documentation Gaps

- `buildDeleteSQL` and `buildUpdateSQL` in AppViewModel have no doc comments explaining the WHERE clause construction or the "PK column missing" nil-return contract.
- `waitForPort` in SSHTunnelService has no doc comment.
- `QuoteLiteral.quoteLiteralTyped()` explains why no cast for NULL but doesn't explain the `textLikeTypes` rationale (why those and not others).
- `SQLFormatter.reconstruct()` is the most complex function in the codebase with no inline comments explaining the `isMultiWordSecond` detection logic.

## New Findings (2026-05-26 review — export/import feature)

### New Warnings
- **ExportViewModel / ImportViewModel: duplicated appendProgress + maxProgressLines** — Exact same 5-line method and constant in both VMs. Extract to a shared `TransferProgressBuffer` helper or a protocol mixin once a third consumer appears; acceptable for two callers.
- **ExportViewModel / ImportViewModel: duplicated locateTool() pattern** — Both follow the identical 6-line locate-then-detach-version pattern. Differs only in which `PGTool` enum case is passed. Could be a shared `func locateTool(_ tool: PGTool)` but divergence is minimal; borderline.
- **ExportViewModel / ImportViewModel: duplicated cancel() pattern** — Both cancel() methods are identical 4-line blocks. Same verdict as above.
- **ExportSheet / ImportSheet: transferLog computed property is copy-pasted verbatim** — Both sheets have the same `transferLog` var (a `ScrollViewReader` wrapping a `LazyVStack` of mono-font lines that auto-scrolls). Should be extracted to a `TransferLogView` (or private file-scope View) in a future pass.
- **ExportSheet / ImportSheet: connectionSummary is copy-pasted verbatim** — Same 10-line `@ViewBuilder` block in both sheets. Extract to a fileprivate `ConnectionSummaryView`.
- **ExportSheet / ImportSheet: toolMissingView has near-identical structure** — Both are 10-line VStack with same icon/layout, differing only in the tool name string. Could be a shared `ToolMissingView(toolName:)`.
- **ExportSheet / ImportSheet: progressView status header is structural duplicate** — The if/else-if chain that shows spinner/error-icon/checkmark differs only in label strings. Borderline given the file-path-display row that only ExportSheet has.
- **PGConnectionEndpoint is unused** — `PGConnectionEndpoint` is declared in `DatabaseTransfer.swift` but nothing in the reviewed surface area (ViewModels, Service, Tests) ever constructs or references it. Possibly dead code or a placeholder for future SSH-tunnel endpoint abstraction that was superseded by `PGToolConnection`.
- **ExportOptions.arguments uses `--name=value` injection without sanitization** — Schema/table names from user-selected DB values are interpolated into arg strings (e.g. `--schema=\(schema)`) using `=` form which guards against getopt re-parsing, but a schema name containing whitespace would still silently corrupt the argument. The test covers the `-` prefix case; a whitespace case is untested.
- **PGToolchain.configuredDirectory directly touches UserDefaults.standard** — This is inconsistent with the project convention where only `ConnectionStore` is supposed to access `UserDefaults`. Low severity given it's settings, not connection data.

### New Suggestions
- **DatabaseTransfer.swift: `ExportOptions` has 15 stored properties** — It is a wide struct but deliberately models all pg_dump knobs. Not a smell at this scale; the value comes from centralized testable argument construction.
- **OutputCollector.maxTailLines is a magic number** — 40 lines retained for error summary is reasonable but undocumented. Trivial to name as a constant.
- **`PGTool.displayName` is always identical to `rawValue`** — The enum has `.pgDump = "pg_dump"` and `.psql` with `displayName` returning the same strings. The computed property adds no value; callers could use `.rawValue` directly.
- **DatabaseTransferTests: `testLocateReturnsNilForMissingToolInEmptyDirectory` has a weak assertion** — The test body is `_ = PGToolchain.locate(.pgDump)` with no assertion about the return value. It only tests that the call doesn't crash. Rename to reflect this (e.g. `testLocateDoesNotCrashWithInvalidDirectory`), or add `XCTAssertNil` for the specific path override.

## New Findings (2026-04-11 review of recently modified files)

### New Critical
- **Duplicate alert in ContentView** — `tabContent()` attaches a "Connection Error" alert AND `connectedView()` attaches an "Error" alert both bound to the same `tab.appVM.errorMessage`. Only one can fire at a time, but the second is unreachable in the connected state because `connectedView` handles it. Both alerts share the same binding, creating ambiguous dismissal semantics. The `tabContent` alert is dead once connected.

### New Warnings
- **`visibleEntries` computed property in QueryHistoryView duplicates `filteredEntries` in QueryHistoryViewModel** — Lines 8-13 of QueryHistoryView reimplement the exact same filtering logic (`if let filter = historyVM.filterSource { ... }`) already expressed in `QueryHistoryViewModel.filteredEntries`. The view should call `historyVM.filteredEntries` directly.
- **`loadSchemaObjects` in AppViewModel bypasses `setSchemaObjects()` helper** — Lines ~217-218 directly write to `navigatorVM.objectsPerKey` and `navigatorVM.loadedKeys` instead of calling `navigatorVM.setSchemaObjects(db:schema:objects:)`. This bypasses the cache invalidation of `_allLoadedTablesCache`.
- **`@Bindable var historyVM` declared twice in QueryHistoryView** — Once in `body` (line 16) and once inside `toolbar` computed property (line 33). The second is redundant because `toolbar` is called from `body` in the same struct scope; the outer declaration is sufficient.
- **`deleteQueryRow` does not log to queryHistoryVM on success** — `deleteContentRow` logs the DELETE SQL on success (line ~659), but `deleteQueryRow` does not log on the success path (it re-runs `executeQuery` which logs, but the DELETE itself is silent).
- **Magic number `50` for longText threshold in FieldEditorKind** — `value.count > 50` at line 24 of FieldEditorView is an undocumented threshold for switching to the multi-line editor. Should be a named constant with a comment.
- **`isTabEnabled` collapse in MainAreaView** — The `.structure` and `.definition` cases in the `isTabEnabled` switch (lines 80-83) share identical bodies (`navigatorVM.selectedObject != nil`). They can be collapsed to `case .structure, .content, .definition:` but currently `.content` is a separate case — actually `.content` is grouped under `.structure` in the first case arm, so `.definition` is listed separately but identically. Minor cleanup opportunity.
- **`CreateDatabaseSheet` and `CreateSchemaSheet` are structurally identical** — Both are 38-line structs with identical layout (title, text field, Cancel/Create buttons, `.frame(width: 340)`). The only difference is the title string and label text. Should be collapsed into a single parameterized `NameInputSheet(title:fieldLabel:onCreate:)`.

### New Suggestions
- **`SidebarWidthStore.load()` is called in AppViewModel's stored property initializer** — `var sidebarWidth: CGFloat = SidebarWidthStore.load()` at AppViewModel line 31 runs at struct init time. If `SidebarWidthStore` is ever changed to be async, this will be a problem. Also, `SidebarWidthStore.load()` calls `UserDefaults.standard` at the call site, which is fine for now but worth noting.
- **`QueryHistoryViewModel.maxEntries` is a magic number without documentation** — 500 is reasonable but there's no comment explaining the rationale (memory budget, UX, etc.).
- **`parsePostgresArray` and `serializePostgresArray` are file-scope free functions** — They are tightly coupled to `FieldEditorView` but declared as global free functions. They should be `fileprivate` or moved to a namespace/extension to avoid polluting the module namespace.
- **`badgeInfo(for:)` is a global free function** — Same issue as above; it's only used by `FieldEditorView` and `CellTypeBadge`. Should be `fileprivate` or a static method on `FieldEditorKind`.

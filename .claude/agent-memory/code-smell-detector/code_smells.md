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

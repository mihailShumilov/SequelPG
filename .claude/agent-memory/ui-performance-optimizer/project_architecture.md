---
name: SequelPG Architecture and UI Conventions
description: Core architecture, styling approach, component patterns, and performance characteristics of the SequelPG macOS SwiftUI app
type: project
---

## Stack
- macOS 14.0+ SwiftUI app, Swift 5.9+, Xcode 15+
- Database: PostgresNIO via DatabaseClient actor
- No external UI libraries — pure SwiftUI + AppKit bridging for NSTextView (SQLEditorView)
- No CSS/design tokens — uses SwiftUI semantic colors and system fonts throughout

## Architecture
Strict MVVM: Views → @Observable ViewModels (@MainActor) → Services (actors) → PostgresNIO

Root coordinator: AppViewModel owns NavigatorViewModel, TableViewModel, QueryViewModel, QueryHistoryViewModel.
All VMs injected via SwiftUI .environment() — no @StateObject, no @ObservableObject (uses new @Observable macro).

## Key Views
- TabRootView (ContentView.swift) — tab management, single vs multi-tab layout
- NavigatorView.swift — DisclosureGroup tree (databases → schemas → 17 categories → objects)
- MainAreaView.swift — tab bar (Structure / Content / Query / Definition) + tab content switch
- QueryTabView.swift — SQL editor + ResultsGridView (native Table)
- ContentTabView.swift — ResultsGridView with pagination
- StructureTabView.swift — column editor with inline edits
- InspectorView.swift — row detail panel, right sidebar
- StartPageView.swift — 3-column connection manager

## Performance Characteristics (verified in code)

### ContentView.swift
- GeometryReader wraps connectedView solely for the .onAppear default-sidebar-width calculation. After .onAppear fires once, GeometryReader keeps measuring on every resize — unnecessary overhead since the value is only needed once.
- SidebarResizeHandle: DragGesture updates sidebarWidth on every onChanged event which writes to @Observable AppViewModel on main actor — triggers navigator re-render on every drag frame. No throttling.
- TabRootView multi-tab mode: all tabs rendered in ZStack with opacity 0/1 — correct approach for keeping tab state alive; no issues.

### NavigatorView.swift
- .transaction { $0.animation = nil } is correct and intentional — prevents DisclosureGroup animation jank when tree nodes appear.
- dbExpansionBinding / schemaExpansionBinding / categoryExpansionBinding: each creates a new Binding closure on every render. On @Observable this is low overhead (no Combine subscription), but it is unnecessary closure allocation per node.
- coreCategories and advancedCategories computed properties on NavigatorViewModel: both call availableCategories which iterates ObjectCategory.allCases (17 items) and filters. Called once per schema node during render. Negligible for small trees but non-zero allocation.
- navigatorVM.objects(for:schema:category:) — a dictionary lookup (O(1)) into objectsPerKey, then a struct property access. Fast.
- allLoadedTables: properly invalidated-and-cached via _allLoadedTablesCache. Good pattern.

### QueryHistoryView.swift
- DUPLICATE FILTERING: QueryHistoryViewModel already has a `filteredEntries` computed property that does exactly the same filter. QueryHistoryView declares a SECOND `visibleEntries` computed property doing the identical filter. Every render evaluates this filter twice (once for the empty check, once for the List). With 500 entries this is O(n) per render frame — wasted work.
- visibleEntries is called twice per body render: once in `if visibleEntries.isEmpty` and once in `entryList` (as `ForEach(visibleEntries)`). Swift does NOT cache computed properties — this runs the filter twice per render.
- List uses ForEach(visibleEntries) with no row height estimate — SwiftUI will virtualize but row measurement may be expensive given each row has variable height (optional error text, optional rowCount, etc.).

### QueryTabView.swift / ResultsGridView
- identifiedRows and identifiedColumns are computed properties on ResultsGridView struct. Every time the Table body re-renders (e.g. on selection change, sortOrder change, editingCell change), both arrays are rebuilt from scratch: O(n) allocation for rows (up to 2000), O(m) for columns.
- Table selection change triggers body re-render → identifiedRows rebuild → same 2000 IdentifiedRow allocations just to update a highlight. This is the most significant hot path.
- cellView has per-cell popover Binding construction: `Binding(get: { fieldEditorCell?.row == rowIdx && fieldEditorCell?.col == colIdx }, set: ...)` — created for every visible cell on every render. With Table virtualization this is bounded to ~20-40 visible rows, so manageable.
- editorKind(for:cell:) calls columns.first(where:) — linear scan of ColumnInfo array — per cell per render. For wide tables (50+ columns) this compounds.
- insertRowView: constructs Dictionary from columns array on every render: `Dictionary(columns.map { ($0.name, $0) }, ...)` — O(m) allocation every body call.

### MainAreaView.swift
- Tab content switch uses `switch appVM.selectedTab` inside a Group — SwiftUI destroys and recreates StructureTabView / ContentTabView / QueryTabView / ObjectDefinitionView on every tab switch. No .id() preservation or hidden-stack pattern.
- showQueryHistory toggle wraps tabContent in VSplitView vs bare view — this causes tabContent to be destroyed/recreated when the toggle changes, losing any sub-view scroll position.

### ContentTabView.swift
- tableVM.columns.contains { $0.isPrimaryKey } called inline in ResultsGridView isEditable parameter — linear scan per render. Should be a stored/cached property on TableViewModel.
- filterBar: `tableVM.filters.allSatisfy { $0.value.isEmpty && $0.op != .isNull && $0.op != .isNotNull }` computed inline in a disabled modifier — called every render of the filter bar.

## Design Conventions
- Spacing: .padding(.horizontal, 12) / .padding(.vertical, 8) in headers, .padding(.horizontal, 12) / .padding(.vertical, 6) in toolbars — consistent 4px/8px base
- Colors: semantic only (Color.accentColor, Color(nsColor: .windowBackgroundColor), .secondary, .tertiary)
- Typography: .headline for panel titles, .caption for metadata, .system(.body, design: .monospaced) for data cells
- Icons: SF Symbols throughout, mix of outline and filled (not fully consistent)
- Tab indicators: accentColor.opacity(0.15) background for selected tab — subtle, correct
- No shadow system defined
- Accessibility: .help() used on most buttons; no explicit accessibilityLabel on icon-only buttons in some places

## Known Issues (verified)
1. PERF (HIGH): identifiedRows/identifiedColumns recomputed on every ResultsGridView render — should be memoized or moved upstream to ViewModel. Up to 2000 IdentifiedRow allocations per selection change.
2. PERF (HIGH): visibleEntries filter in QueryHistoryView duplicates filteredEntries in ViewModel AND runs twice per render pass (isEmpty check + ForEach). Use historyVM.filteredEntries directly.
3. PERF (MEDIUM): GeometryReader in connectedView used only for onAppear default-width calculation — keep measuring on every resize unnecessarily. Can be replaced with a one-shot .onGeometryChange or removed after first use.
4. PERF (MEDIUM): sidebarWidth write on every DragGesture.onChanged frame triggers main actor publish → potential navigator re-render. Consider debouncing or using a local @State and only committing on drag end (with live preview via preference key).
5. PERF (MEDIUM): Tab content destroyed/recreated on every tab switch (MainAreaView switch statement). ContentTabView re-runs .task and reloads data on every reactivation.
6. PERF (MEDIUM): showQueryHistory toggle destroys/recreates tabContent (VSplitView vs bare) — scroll position lost.
7. PERF (LOW): editorKind(for:cell:) uses columns.first(where:) linear scan per visible cell per render. Pre-build a dictionary once.
8. PERF (LOW): insertRowView builds Dictionary(columns.map...) on every render. Extract to a stored variable.
9. PERF (LOW): tableVM.columns.contains { $0.isPrimaryKey } computed inline per ResultsGridView render in ContentTabView — should be a cached ViewModel property.
10. UX: Tab content (StructureTabView, ContentTabView) destroyed/recreated on tab switch — ContentTabView re-triggers data load.
11. UX: "Stop" button in QueryTabView permanently disabled with no visual distinction from enabled state beyond tooltip — confusing.
12. UX: No loading state in NavigatorView when schemas/objects are being fetched (tree just stays empty). loadingDatabases Set exists on NavigatorViewModel but is never read in NavigatorView.
13. UX: Single-tap and double-tap gestures stacked on same element in cellView — SwiftUI evaluates both gesture recognizers; single-tap will fire before double-tap recognition window completes, selecting the row before edit begins.
14. ACCESSIBILITY: Icon-only buttons in NavigatorView header (plus Menu, arrow.clockwise) — plus has no accessibilityLabel, arrow.clockwise does (good).
15. ACCESSIBILITY: Tab buttons in MainAreaView have no accessibilityLabel — disabled tabs show no reason why they are disabled.
16. DESIGN: CreateDatabaseSheet and CreateSchemaSheet are structurally identical — prime candidate for a parameterized shared component.
17. DESIGN: QueryHistoryView entryRow uses `.cornerRadius(3)` — deprecated in favor of `.clipShape(.rect(cornerRadius: 3))` on macOS 14+.

**Why:** This is load-bearing context for all future UI/perf work on this project.
**How to apply:** Reference these findings before suggesting changes; verify file paths before citing them.

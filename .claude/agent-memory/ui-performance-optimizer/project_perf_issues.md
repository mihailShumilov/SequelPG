---
name: Performance issues identified in initial audit
description: All UI performance issues found in April 2026 audit of SequelPG views and view models
type: project
---

Performance audit completed 2026-04-19. Issues ranked by impact.

**Why:** Recorded so future sessions don't need to re-read all files to know what was found.

**How to apply:** Reference these when implementing fixes so nothing is missed and priorities are clear.

## HIGH impact

1. **MainAreaView: all 4 tabs always mounted (MainAreaView.swift:62-76)**
   - StructureTabView, ContentTabView, ObjectDefinitionView, QueryTabView are ALL in a ZStack always
   - Only visible tab has opacity:1 but all four are rendered, all four observe AppViewModel
   - Fix: Use if/switch to show only the active tab, or conditionally mount with `.id(appVM.selectedTab)`

2. **SQLEditorView completionMetadata rebuilt every body eval (QueryTabView.swift:105-113)**
   - SQLCompletionProvider.Metadata is constructed inline in editorArea computed property
   - New struct instance every SwiftUI render → forces NSViewRepresentable updateNSView on every AppViewModel change
   - Fix: Cache in @State or make Metadata Equatable and guard updateNSView on equality

3. **InspectorView: prettyJSONPreview JSONSerialization called every render (InspectorView.swift:319-334)**
   - JSON parse + pretty-print runs inside a computed property called from body
   - No memoization — re-runs on every AppViewModel observation cycle even when cell value unchanged
   - Fix: Memoize result keyed on the raw string value; compute once, cache in @State

4. **QueryViewModel.sortedResult sort cache: invalidateSortCache() not called on sortColumn/sortAscending change**
   - QueryViewModel.sortAscending and sortColumn are @Observable properties
   - toggleQuerySort calls invalidateSortCache(), but any direct write to sortColumn/sortAscending bypasses the cache guard
   - Already fixed for most paths, but verify no code sets these directly without calling invalidateSortCache()

## MEDIUM impact

5. **TableViewModel.clear() fires 14 separate @Observable property assignments (TableViewModel.swift:77-95)**
   - Each assignment independently schedules a SwiftUI update — 14 UI updates instead of 1
   - Fix: Batch into a nested plain struct, or use @ObservationIgnored + a single `didClear` property to coalesce

6. **ContentTabView.paginationBar: appVM.canInsertContentRow / canDeleteContentRow evaluated every render**
   - Both are plain computed vars on AppViewModel that call navigatorVM.selectedObject?.type and tableVM.hasPrimaryKey
   - Called during body evaluation with no caching; fires on every AppViewModel change
   - Fix: Expose as stored @Observable properties on AppViewModel, updated reactively

7. **NavigatorView: categoryNode objects computed inline (NavigatorView.swift:278)**
   - `navigatorVM.objects(for: db, schema: schema, category: category)` called in body
   - This likely returns an array lookup — verify it doesn't rebuild arrays on every render
   - Fix: If NavigatorViewModel rebuilds these arrays on every call, add memoization

8. **QueryHistoryView.visibleEntries: computed property filters on every render (QueryHistoryView.swift:8-13)**
   - Full filter pass over all history entries on every view update
   - Fix: Cache in QueryHistoryViewModel as a stored @Observable property updated on filterSource change

9. **InspectorView.parsePostgresArray called on every render (InspectorView.swift:258)**
   - Array parsing runs inside arrayPreview which is called from body
   - Fix: Same strategy as JSON — memoize keyed on displayString value

## LOW impact

10. **ContentTabView.insertRowView: uses `ForEach(0 ..< result.columns.count, id: \.self)` (QueryTabView.swift:472)**
    - Index-based ForEach — SwiftUI cannot diff efficiently; all cells re-render on any change
    - Fix: ForEach over IdentifiedColumn array (already constructed in init) for stable identity

11. **MainAreaView: tab bar renders all 4 tabs even when 3 are disabled**
    - Button.disabled(true) still participates in layout and body evaluation
    - Minor but can be replaced with conditional styling without disabled() overhead

12. **ContentView (TabRootView): all inactive tab AppViewModels still observe via .environment**
    - ZStack of tabContent views: inactive tabs are mounted with opacity:0 but remain in the view tree
    - Each inactive tab's AppViewModel/child VMs can trigger observation updates from background operations
    - Fix: Only mount the active tab's content (conditional on selectedTabId == tab.id)

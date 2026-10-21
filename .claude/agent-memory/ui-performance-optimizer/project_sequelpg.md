---
name: SequelPG codebase overview
description: Architecture, styling, component library, and design token conventions for SequelPG macOS app
type: project
---

Native macOS PostgreSQL client built with SwiftUI, targeting macOS 14.0+, Swift 5.9+, Xcode 15+. No external UI framework — pure SwiftUI + AppKit (NSViewRepresentable for SQL editor).

**Why:** Understanding this shapes all optimization suggestions — no Combine, no external state libraries.

**How to apply:** Always recommend SwiftUI-native solutions; never suggest React/web patterns or third-party state libraries.

## Architecture
- Strict MVVM: Views → ViewModels (@MainActor @Observable) → Services → PostgresNIO
- AppViewModel is the root coordinator, owns NavigatorViewModel, TableViewModel, QueryViewModel, QueryHistoryViewModel
- All child VMs are injected via `.environment()` — views access them via `@Environment(ChildVM.self)`
- NO Combine forwarding (was previously ObservableObject; now uses @Observable macro)
- All views observe only the VMs they declare via @Environment — correct scoping

## Key files
- ViewModels: AppViewModel.swift, AppViewModel+ObjectCRUD.swift, QueryViewModel.swift, TableViewModel.swift, NavigatorViewModel.swift, ConnectionListViewModel.swift, QueryHistoryViewModel.swift
- Views: ContentView.swift (TabRootView), MainAreaView.swift, NavigatorView.swift, ContentTabView.swift, QueryTabView.swift (also contains ResultsGridView), StructureTabView.swift, InspectorView.swift, SQLEditorView.swift, StartPageView.swift, ConnectionFormView.swift, QueryHistoryView.swift

## Styling conventions
- No design tokens / CSS custom properties — inline SwiftUI modifiers
- No component library beyond SwiftUI builtins
- Spacing: ad-hoc (.padding(.horizontal, 12), .padding(.vertical, 8), etc.)
- Colors: system colors (Color.accentColor, Color(nsColor: .controlBackgroundColor), .secondary, .tertiary)
- No custom font scale — system defaults with occasional .font(.headline/.caption/.subheadline)

## Data model notes
- QueryResult: struct, NOT Equatable — all assignments trigger observation update
- CellValue: enum, IS Equatable
- ColumnInfo: struct, IS Equatable
- DBObject: struct, IS Equatable and Hashable
- TableViewModel has 14 separate @Observable properties — any single change triggers a view update for all observers

## Tab architecture
- TabRootView holds an array of TabItem (each with its own AppViewModel)
- Single tab: renders tabContent directly (no tab bar)
- Multiple tabs: ZStack of all tabContent views, inactive tabs set to opacity:0 — ALL tabs remain mounted
- MainAreaView uses ZStack for its 4 sub-tabs (Structure/Content/Definition/Query) — all 4 always mounted

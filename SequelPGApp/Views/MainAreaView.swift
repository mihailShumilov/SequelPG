import SwiftUI

struct MainAreaView: View {
    @Environment(AppViewModel.self) var appVM
    @Environment(NavigatorViewModel.self) var navigatorVM

    fileprivate static let chromeBackground = Theme.bg

    var body: some View {
        VStack(spacing: 0) {
            // Object tabs (one per open table/view/function/etc.). Hidden
            // entirely when there is nothing open — the strip is dead weight
            // before the first navigator selection.
            if !appVM.tabs.isEmpty {
                ObjectTabsBar()
                Rectangle().fill(Theme.line).frame(height: 1)
            }

            // Tab bar
            HStack(spacing: 0) {
                ForEach(Array(AppViewModel.MainTab.allCases.enumerated()), id: \.element) { index, tab in
                    let isActive = appVM.selectedTab == tab
                    let enabled = isTabEnabled(tab)
                    Button {
                        if enabled {
                            appVM.selectedTab = tab
                        }
                    } label: {
                        Text(tab.rawValue)
                            .font(.system(size: 13, weight: isActive ? .semibold : .medium))
                            .padding(.horizontal, 18)
                            .padding(.vertical, 12)
                            .background(Color.clear)
                            .foregroundColor(enabled ? (isActive ? Theme.ink : Theme.ink3) : Theme.ink4)
                    }
                    .buttonStyle(.plain)
                    .overlay(alignment: .bottom) {
                        if isActive {
                            RoundedRectangle(cornerRadius: 1, style: .continuous)
                                .fill(Theme.accent)
                                .frame(height: 2)
                                .padding(.horizontal, 14)
                        }
                    }
                    .disabled(!enabled)
                    .accessibilityLabel(tab.rawValue)
                    .accessibilityHint(enabled ? "Switch to the \(tab.rawValue) tab" : "Select an object in the Navigator to enable")
                    .keyboardShortcut(tabShortcut(for: index), modifiers: .command)
                }
                Spacer()
            }
            .background(Theme.bg)

            Rectangle().fill(Theme.line).frame(height: 1)

            // Tab content + optional bottom history panel
            if appVM.showQueryHistory {
                VSplitView {
                    tabContent
                        .frame(minHeight: 100)

                    QueryHistoryView()
                        .frame(minHeight: 120, idealHeight: 220)
                }
            } else {
                tabContent
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .toggleQueryHistory)) { _ in
            appVM.showQueryHistory.toggle()
        }
    }

    // Only mount the active tab. Inactive tabs were previously kept in a ZStack
    // with opacity 0, which forced SwiftUI to keep their observation wiring and
    // redraw them whenever any shared view model changed.
    @ViewBuilder
    private var tabContent: some View {
        switch appVM.selectedTab {
        case .structure:
            StructureTabView()
        case .content:
            ContentTabView()
        case .definition:
            ObjectDefinitionView()
        case .query:
            QueryTabView()
        }
    }

    private func isTabEnabled(_ tab: AppViewModel.MainTab) -> Bool {
        switch tab {
        case .structure, .content, .definition:
            return navigatorVM.selectedObject != nil
        case .query:
            return appVM.isConnected
        }
    }

    /// Cmd+1…4 for the four main tabs. Returns `.defaultAction` for anything
    /// beyond that so the modifier is a no-op and doesn't clash with defaults.
    private func tabShortcut(for index: Int) -> KeyEquivalent {
        switch index {
        case 0: return "1"
        case 1: return "2"
        case 2: return "3"
        case 3: return "4"
        default: return .return
        }
    }
}

/// Horizontal strip of object tabs above the main Structure/Content/Definition
/// /Query bar. Each tab represents one open `DBObject` with its own per-tab
/// snapshot of filters, pagination, sort, and content. FK navigation always
/// opens a new tab; navigator selection of an already-open object reactivates
/// the existing tab.
private struct ObjectTabsBar: View {
    @Environment(AppViewModel.self) private var appVM

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 0) {
                ForEach(appVM.tabs) { tab in
                    ObjectTabChip(tab: tab)
                }
                Spacer(minLength: 0)
            }
        }
        .frame(height: 34)
        .background(Theme.bg2)
    }
}

private struct ObjectTabChip: View {
    let tab: ObjectTab
    @Environment(AppViewModel.self) private var appVM
    @State private var isHovered = false

    private var isActive: Bool { appVM.activeTabId == tab.id }

    private var title: String {
        // Drop the schema prefix for the `public` schema — that's the noisy
        // default in most Postgres setups. Keep the qualified name otherwise
        // so cross-schema tabs read unambiguously in the strip.
        tab.dbObject.schema == "public"
            ? tab.dbObject.name
            : "\(tab.dbObject.schema).\(tab.dbObject.name)"
    }

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: icon)
                .font(.system(size: 10))
                .foregroundStyle(isActive ? Theme.ink : Theme.ink4)
            Text(title)
                .font(Theme.mono(size: 11.5, weight: isActive ? .medium : .regular))
                .foregroundStyle(isActive ? Theme.ink : Theme.ink3)
                .lineLimit(1)
                .truncationMode(.middle)

            Button {
                appVM.closeTab(tab.id)
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(isHovered || isActive ? Theme.ink2 : Color.clear)
                    .frame(width: 14, height: 14)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Close tab")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
        .frame(minWidth: 100, maxWidth: 240)
        .background(
            // Top-2px lime accent bar on the active tab — mirrors the
            // `.app-tab.active::after` rule in the web design.
            VStack(spacing: 0) {
                Rectangle()
                    .fill(isActive ? Theme.accent : Color.clear)
                    .frame(height: 2)
                Rectangle()
                    .fill(isActive ? Theme.bg : Theme.bg2)
            }
        )
        .overlay(alignment: .trailing) {
            Rectangle()
                .fill(Theme.line)
                .frame(width: 1)
        }
        .contentShape(Rectangle())
        .onTapGesture { appVM.activateTab(tab.id) }
        .onHover { isHovered = $0 }
        .accessibilityLabel("Tab: \(title)")
        .accessibilityHint(isActive ? "Active tab. Click \u{00D7} to close." : "Click to activate. Click \u{00D7} to close.")
    }

    /// Small visual cue for the object kind in the tab chip. Keeps tables
    /// distinguishable from views/functions/types at a glance.
    private var icon: String {
        switch tab.dbObject.type {
        case .table, .foreignTable: return "tablecells"
        case .view, .materializedView: return "doc.text.magnifyingglass"
        case .function, .procedure, .triggerFunction, .aggregate: return "function"
        case .sequence: return "number"
        case .type, .domain: return "shippingbox"
        default: return "circle.dotted"
        }
    }
}

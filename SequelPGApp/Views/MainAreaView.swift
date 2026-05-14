import SwiftUI

struct MainAreaView: View {
    @Environment(AppViewModel.self) var appVM
    @Environment(NavigatorViewModel.self) var navigatorVM

    fileprivate static let chromeBackground = Color(nsColor: .controlBackgroundColor)

    var body: some View {
        VStack(spacing: 0) {
            // Object tabs (one per open table/view/function/etc.). Hidden
            // entirely when there is nothing open — the strip is dead weight
            // before the first navigator selection.
            if !appVM.tabs.isEmpty {
                ObjectTabsBar()
                Divider()
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
                            .font(.body)
                            .fontWeight(isActive ? .semibold : .regular)
                            .padding(.horizontal, 20)
                            .padding(.vertical, 12)
                            .background(isActive ? Color.accentColor.opacity(0.1) : Color.clear)
                            .foregroundColor(enabled ? (isActive ? Color.accentColor : .primary) : Color.secondary.opacity(0.5))
                    }
                    .buttonStyle(.plain)
                    .overlay(alignment: .bottom) {
                        if isActive {
                            Rectangle()
                                .fill(Color.accentColor)
                                .frame(height: 2)
                        }
                    }
                    .disabled(!enabled)
                    .accessibilityLabel(tab.rawValue)
                    .accessibilityHint(enabled ? "Switch to the \(tab.rawValue) tab" : "Select an object in the Navigator to enable")
                    .keyboardShortcut(tabShortcut(for: index), modifiers: .command)
                }
                Spacer()
            }
            .background(MainAreaView.chromeBackground)

            Divider()

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
            HStack(spacing: 1) {
                ForEach(appVM.tabs) { tab in
                    ObjectTabChip(tab: tab)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
        }
        .background(MainAreaView.chromeBackground)
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
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(title)
                .font(.system(.callout))
                .fontWeight(isActive ? .semibold : .regular)
                .foregroundStyle(isActive ? Color.primary : Color.secondary)
                .lineLimit(1)
                .truncationMode(.middle)

            Button {
                appVM.closeTab(tab.id)
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(isHovered || isActive ? Color.primary.opacity(0.7) : Color.clear)
                    .frame(width: 14, height: 14)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Close tab")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .frame(minWidth: 80, maxWidth: 220)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(isActive ? Color.accentColor.opacity(0.15) : Color.clear)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .stroke(isActive ? Color.accentColor.opacity(0.4) : Color.secondary.opacity(0.15), lineWidth: 1)
        )
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

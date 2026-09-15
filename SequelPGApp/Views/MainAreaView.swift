import SwiftUI

/// Detail column of the connected workspace: the strip of open object tabs
/// (when any are open), the pane for the current mode, and the optional
/// query-history drawer at the bottom. The mode itself (Structure / Content /
/// Definition / Query / Diagram) is chosen with the segmented control in the
/// window toolbar or ⌘1–⌘5.
struct MainAreaView: View {
    @Environment(AppViewModel.self) var appVM

    var body: some View {
        VStack(spacing: 0) {
            // Object tabs (one per open table/view/function/etc.). Hidden
            // entirely when there is nothing open.
            if !appVM.tabs.isEmpty {
                ObjectTabsBar()
                Divider()
            }

            if appVM.showQueryHistory {
                // See QueryTabView: keep the panes' intrinsic width small so the
                // split view doesn't force the detail column wider than needed.
                VSplitView {
                    modeContent
                        .frame(minWidth: 0, idealWidth: 480, maxWidth: .infinity, minHeight: 120)

                    QueryHistoryView()
                        .frame(minWidth: 0, idealWidth: 480, maxWidth: .infinity, minHeight: 120, idealHeight: 220)
                }
            } else {
                modeContent
            }
        }
        .background(Theme.bg)
    }

    // Only the active mode is mounted; the others keep no live observation
    // wiring while hidden.
    @ViewBuilder
    private var modeContent: some View {
        switch appVM.selectedTab {
        case .structure:
            StructureTabView()
        case .content:
            ContentTabView()
        case .definition:
            ObjectDefinitionView()
        case .query:
            QueryTabView()
        case .diagram:
            DiagramTabView()
        }
    }
}

/// Horizontal strip of object tabs. Each tab represents one open `DBObject`
/// with its own snapshot of filters, pagination, sort, and content. FK
/// navigation always opens a new tab; selecting an already-open object in the
/// navigator reactivates its tab.
private struct ObjectTabsBar: View {
    @Environment(AppViewModel.self) private var appVM

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 2) {
                ForEach(appVM.tabs) { tab in
                    ObjectTabChip(tab: tab)
                }
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
        }
        .frame(height: 32)
        .background(.bar)
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
        // so cross-schema tabs read unambiguously.
        tab.dbObject.schema == "public"
            ? tab.dbObject.name
            : "\(tab.dbObject.schema).\(tab.dbObject.name)"
    }

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: tab.dbObject.type.symbolName)
                .font(.system(size: 11))
                .foregroundStyle(isActive ? Color.accentColor : Color.secondary)
            Text(title)
                .font(.system(size: 12, weight: isActive ? .medium : .regular))
                .foregroundStyle(isActive ? .primary : .secondary)
                .lineLimit(1)
                .truncationMode(.middle)

            Button {
                appVM.closeTab(tab.id)
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.secondary)
                    .frame(width: 14, height: 14)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .opacity(isHovered || isActive ? 1 : 0)
            .help("Close tab")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .frame(minWidth: 90, maxWidth: 240)
        .background(
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(Color.primary.opacity(isActive ? 0.1 : (isHovered ? 0.05 : 0)))
        )
        .contentShape(Rectangle())
        .onTapGesture { appVM.activateTab(tab.id) }
        .onHover { isHovered = $0 }
        .contextMenu {
            Button("Close Tab") { appVM.closeTab(tab.id) }
            Button("Close Other Tabs") { appVM.closeOtherTabs(except: tab.id) }
                .disabled(appVM.tabs.count <= 1)
            Button("Close All Tabs") { appVM.closeAllTabs() }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Tab: \(title)")
        .accessibilityHint(isActive ? "Active tab." : "Click to activate.")
    }
}

extension DBObjectType {
    /// SF Symbol used for this object kind in tabs, headers, and the sidebar.
    var symbolName: String {
        switch self {
        case .table: return "tablecells"
        case .foreignTable: return "externaldrive"
        case .view: return "eye"
        case .materializedView: return "square.stack.3d.up"
        case .function: return "function"
        case .procedure: return "gearshape"
        case .triggerFunction: return "bolt"
        case .aggregate: return "sum"
        case .sequence: return "number"
        case .type: return "t.square"
        case .domain: return "shield"
        case .collation: return "textformat.abc"
        case .ftsConfiguration: return "doc.text.magnifyingglass"
        case .ftsDictionary: return "character.book.closed"
        case .ftsParser: return "text.viewfinder"
        case .ftsTemplate: return "doc.on.doc"
        case .operator: return "plus.forwardslash.minus"
        }
    }

    /// Human-readable kind label ("Materialized View", "Trigger Function").
    var displayName: String {
        switch self {
        case .table: return "Table"
        case .foreignTable: return "Foreign Table"
        case .view: return "View"
        case .materializedView: return "Materialized View"
        case .function: return "Function"
        case .procedure: return "Procedure"
        case .triggerFunction: return "Trigger Function"
        case .aggregate: return "Aggregate"
        case .sequence: return "Sequence"
        case .type: return "Type"
        case .domain: return "Domain"
        case .collation: return "Collation"
        case .ftsConfiguration: return "FTS Configuration"
        case .ftsDictionary: return "FTS Dictionary"
        case .ftsParser: return "FTS Parser"
        case .ftsTemplate: return "FTS Template"
        case .operator: return "Operator"
        }
    }
}

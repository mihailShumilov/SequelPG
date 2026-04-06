import SwiftUI

struct ObjectDefinitionView: View {
    @Environment(AppViewModel.self) var appVM
    @Environment(NavigatorViewModel.self) var navigatorVM
    @Environment(TableViewModel.self) var tableVM

    @State private var ddlText: String = ""
    @State private var isLoading = false
    @State private var loadedObjectId: String?

    var body: some View {
        VStack(spacing: 0) {
            // Toolbar
            HStack {
                if let obj = navigatorVM.selectedObject {
                    Label(obj.name, systemImage: objectIcon(for: obj.type))
                        .font(.headline)
                    Text("(\(obj.type.rawValue))")
                        .foregroundStyle(.secondary)
                }
                Spacer()

                Button {
                    Task { await loadDDL() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Refresh definition")
                .disabled(isLoading)

                Button("Edit in Query") {
                    editInQuery()
                }
                .disabled(ddlText.isEmpty || isLoading)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            Divider()

            // DDL content
            if isLoading {
                ProgressView("Loading definition...")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if ddlText.isEmpty {
                Text("Select an object to view its definition.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    Text(ddlText)
                        .font(.system(.body, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding()
                }
            }
        }
        .task(id: navigatorVM.selectedObject?.id) {
            await loadDDL()
        }
    }

    private func loadDDL() async {
        guard let obj = navigatorVM.selectedObject else {
            ddlText = ""
            return
        }
        // Skip for tables (they use Structure tab)
        guard obj.type != .table else {
            ddlText = "-- Use the Structure tab to view table details."
            return
        }
        isLoading = true
        do {
            ddlText = try await appVM.dbClient.getObjectDDL(schema: obj.schema, name: obj.name, type: obj.type)
        } catch {
            ddlText = "-- Error loading definition: \(error.localizedDescription)"
        }
        isLoading = false
    }

    private func editInQuery() {
        appVM.queryVM.queryText = ddlText
        appVM.selectedTab = .query
    }

    private func objectIcon(for type: DBObjectType) -> String {
        switch type {
        case .function: return "function"
        case .procedure: return "gearshape"
        case .view: return "eye"
        case .materializedView: return "square.stack.3d.up"
        case .sequence: return "number"
        case .type: return "t.square"
        case .domain: return "shield"
        case .aggregate: return "sum"
        case .triggerFunction: return "bolt"
        case .collation: return "textformat.abc"
        case .foreignTable: return "externaldrive"
        case .ftsConfiguration: return "doc.text.magnifyingglass"
        case .ftsDictionary: return "character.book.closed"
        case .ftsParser: return "text.viewfinder"
        case .ftsTemplate: return "doc.on.doc"
        case .operator: return "plus.forwardslash.minus"
        case .table: return "tablecells"
        }
    }
}

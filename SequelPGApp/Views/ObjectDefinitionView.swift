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
            // Toolbar — editorial header on the left, action chips on the right.
            HStack(alignment: .top) {
                if let obj = navigatorVM.selectedObject {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("i. — definition")
                            .appSectionLabel()
                        Text("\(obj.schema) · \(obj.type.rawValue)")
                            .appMono(10.5, color: Theme.ink4)
                            .tracking(1.5)
                            .textCase(.uppercase)
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            Image(systemName: objectIcon(for: obj.type))
                                .foregroundStyle(Theme.ink3)
                                .font(.system(size: 14))
                            Text(obj.name)
                                .appDisplayItalic(30)
                        }
                    }
                } else {
                    Text("Definition")
                        .appSectionLabel()
                }
                Spacer()

                HStack(spacing: 8) {
                    Button {
                        Task { await loadDDL() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.ink3)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .overlay(
                                RoundedRectangle(cornerRadius: 5)
                                    .strokeBorder(Theme.line2, lineWidth: 1)
                            )
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Refresh definition")
                    .disabled(isLoading)

                    if let obj = navigatorVM.selectedObject, appVM.isRunnable(obj) {
                        Button {
                            appVM.functionRunTarget = obj
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: "play.fill")
                                    .font(.system(size: 10))
                                Text(obj.type == .procedure ? "Call…" : "Run…")
                                    .font(Theme.mono(size: 11, weight: .medium))
                            }
                            .foregroundStyle(Theme.ink2)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .overlay(
                                RoundedRectangle(cornerRadius: 5)
                                    .strokeBorder(Theme.line2, lineWidth: 1)
                            )
                        }
                        .buttonStyle(.plain)
                        .help(obj.type == .procedure ? "Call this procedure" : "Run this function")
                    }

                    Button {
                        editInQuery()
                    } label: {
                        Text("Edit in Query →")
                            .font(Theme.mono(size: 11, weight: .semibold))
                            .foregroundStyle(Theme.onAccent)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(Theme.accent)
                            .clipShape(.rect(cornerRadius: 5))
                    }
                    .buttonStyle(.plain)
                    .disabled(ddlText.isEmpty || isLoading)
                }
            }
            .padding(.horizontal, 22)
            .padding(.vertical, 16)
            .background(Theme.bg)

            Rectangle().fill(Theme.line).frame(height: 1)

            // DDL content
            if isLoading {
                VStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Loading definition…")
                        .appMono(11, color: Theme.ink3)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Theme.bg)
            } else if ddlText.isEmpty {
                Text("Select an object to view its definition.")
                    .appDisplayItalic(20, color: Theme.ink3)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Theme.bg)
            } else {
                SQLSyntaxView(text: ddlText)
            }
        }
        .background(Theme.bg)
        .task(id: navigatorVM.selectedObject?.id) {
            await loadDDL()
        }
    }

    private func loadDDL() async {
        guard let obj = navigatorVM.selectedObject else {
            ddlText = ""
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

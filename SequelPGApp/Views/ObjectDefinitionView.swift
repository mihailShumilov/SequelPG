import SwiftUI

/// Source/DDL of the selected object with syntax highlighting. Tables
/// reconstruct their CREATE TABLE; views, functions, types, and the rest show
/// their catalog definition.
struct ObjectDefinitionView: View {
    @Environment(AppViewModel.self) var appVM
    @Environment(NavigatorViewModel.self) var navigatorVM
    @Environment(EditorPreference.self) var editorPreference

    @State private var ddlText: String = ""
    @State private var isLoading = false

    var body: some View {
        VStack(spacing: 0) {
            if let obj = navigatorVM.selectedObject {
                header(for: obj)
                Divider()

                if isLoading {
                    ProgressView("Loading definition…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if ddlText.isEmpty {
                    ContentUnavailableView {
                        Label("No Definition", systemImage: "doc.text")
                    } description: {
                        Text("PostgreSQL did not return a definition for this object.")
                    }
                } else {
                    SQLSyntaxView(text: ddlText, font: editorPreference.editorFont)
                }
            } else {
                ContentUnavailableView {
                    Label("No Object Selected", systemImage: "doc.text")
                } description: {
                    Text("Choose a table, view, function, or any other object in the sidebar to see its definition.")
                }
            }
        }
        .background(Theme.bg)
        .task(id: navigatorVM.selectedObject?.id) {
            await loadDDL()
        }
    }

    private func header(for obj: DBObject) -> some View {
        HStack(spacing: 10) {
            Image(systemName: obj.type.symbolName)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(obj.name)
                    .font(.headline)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text("\(obj.type.displayName) in \(obj.schema)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            HStack(spacing: 8) {
                Button {
                    Task { await loadDDL() }
                } label: {
                    Label("Reload", systemImage: "arrow.clockwise")
                }
                .labelStyle(.iconOnly)
                .disabled(isLoading)
                .help("Reload the definition")

                if appVM.isRunnable(obj) {
                    Button {
                        appVM.functionRunTarget = obj
                    } label: {
                        Label(obj.type == .procedure ? "Call…" : "Run…", systemImage: "play.fill")
                    }
                    .help(obj.type == .procedure ? "Call this procedure" : "Run this function")
                }

                Button("Open in Query Editor") {
                    editInQuery()
                }
                .disabled(ddlText.isEmpty || isLoading)
                .help("Copy the definition into the SQL editor")
            }
            .controlSize(.small)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.bar)
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
}

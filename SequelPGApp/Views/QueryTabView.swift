import SwiftUI

struct QueryTabView: View {
    @EnvironmentObject var appVM: AppViewModel

    var body: some View {
        VSplitView {
            editorArea
                .frame(minHeight: 100)

            resultsArea
                .frame(minHeight: 100)
        }
    }

    private var editorArea: some View {
        VStack(spacing: 0) {
            HStack {
                Button {
                    Task { await appVM.executeQuery(appVM.queryVM.queryText) }
                } label: {
                    Label("Run", systemImage: "play.fill")
                }
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(appVM.queryVM.isExecuting || !appVM.isConnected)

                Button(role: .destructive) {
                    // Stop is disabled; client-side cancellation is not
                    // reliably supported by the driver.
                } label: {
                    Label("Stop", systemImage: "stop.fill")
                }
                .disabled(true)
                .help("Stop is not supported by the current driver configuration.")

                Button {
                    appVM.queryVM.queryText = ""
                    appVM.queryVM.result = nil
                    appVM.queryVM.errorMessage = nil
                } label: {
                    Label("Clear", systemImage: "trash")
                }

                Spacer()

                if appVM.queryVM.isExecuting {
                    ProgressView()
                        .controlSize(.small)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)

            Divider()

            TextEditor(text: $appVM.queryVM.queryText)
                .font(.system(.body, design: .monospaced))
                .scrollContentBackground(.visible)
        }
    }

    private var resultsArea: some View {
        VStack(spacing: 0) {
            if let error = appVM.queryVM.errorMessage {
                errorBanner(error)
            }

            if let result = appVM.queryVM.result {
                if result.columns.isEmpty {
                    VStack {
                        Text("Query executed successfully.")
                            .font(.headline)
                        Text("Execution time: \(String(format: "%.3f", result.executionTime))s")
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    VStack(spacing: 0) {
                        ResultsGridView(
                            result: result,
                            onRowSelected: { rowIdx in
                                appVM.selectRow(index: rowIdx, columns: result.columns, values: result.rows[rowIdx])
                            },
                            selectedRowIndex: $appVM.tableVM.selectedRowIndex
                        )

                        Divider()

                        HStack {
                            Text("\(result.rowCount) row\(result.rowCount == 1 ? "" : "s")")
                            if result.isTruncated {
                                Text("(capped at 2000)")
                                    .foregroundStyle(.orange)
                            }
                            Spacer()
                            Text("\(String(format: "%.3f", result.executionTime))s")
                                .foregroundStyle(.secondary)
                        }
                        .font(.caption)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 4)
                    }
                }
            } else if !appVM.queryVM.isExecuting {
                Text("Enter a query and press Cmd+Enter to execute.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private func errorBanner(_ message: String) -> some View {
        HStack {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
            Text(message)
                .lineLimit(2)
            Spacer()
            Button("Dismiss") {
                appVM.queryVM.errorMessage = nil
            }
            .buttonStyle(.borderless)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color.red.opacity(0.1))
    }
}

/// Custom grid for displaying query results with dynamic columns.
/// Uses ScrollView instead of Table to support arbitrary column counts on macOS 13.
struct ResultsGridView: View {
    let result: QueryResult
    var onRowSelected: ((Int) -> Void)?
    @Binding var selectedRowIndex: Int?
    private let columnMinWidth: CGFloat = 100

    init(result: QueryResult, onRowSelected: ((Int) -> Void)? = nil, selectedRowIndex: Binding<Int?> = .constant(nil)) {
        self.result = result
        self.onRowSelected = onRowSelected
        self._selectedRowIndex = selectedRowIndex
    }

    var body: some View {
        GeometryReader { geometry in
            ScrollView([.horizontal, .vertical]) {
                LazyVStack(spacing: 0, pinnedViews: [.sectionHeaders]) {
                    Section {
                        if result.rows.isEmpty {
                            HStack(spacing: 0) {
                                ForEach(0 ..< result.columns.count, id: \.self) { colIdx in
                                    Text("")
                                        .frame(minWidth: columnMinWidth, maxWidth: .infinity, alignment: .leading)
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 3)

                                    if colIdx < result.columns.count - 1 {
                                        Divider()
                                    }
                                }
                            }
                            Divider()
                        }
                        ForEach(0 ..< result.rows.count, id: \.self) { rowIdx in
                            HStack(spacing: 0) {
                                ForEach(0 ..< result.columns.count, id: \.self) { colIdx in
                                    let cell = result.rows[rowIdx][colIdx]
                                    Text(cell.displayString)
                                        .lineLimit(1)
                                        .font(.system(.body, design: .monospaced))
                                        .foregroundStyle(cell.isNull ? .secondary : .primary)
                                        .frame(minWidth: columnMinWidth, maxWidth: .infinity, alignment: .leading)
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 3)

                                    if colIdx < result.columns.count - 1 {
                                        Divider()
                                    }
                                }
                            }
                            .background(selectedRowIndex == rowIdx ? Color.accentColor.opacity(0.15) : (rowIdx % 2 == 0 ? Color.clear : Color.gray.opacity(0.05)))
                            .contentShape(Rectangle())
                            .onTapGesture { onRowSelected?(rowIdx) }

                            Divider()
                        }
                    } header: {
                        HStack(spacing: 0) {
                            ForEach(0 ..< result.columns.count, id: \.self) { colIdx in
                                Text(result.columns[colIdx])
                                    .fontWeight(.semibold)
                                    .lineLimit(1)
                                    .frame(minWidth: columnMinWidth, maxWidth: .infinity, alignment: .leading)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 4)

                                if colIdx < result.columns.count - 1 {
                                    Divider()
                                }
                            }
                        }
                        .background(Color(nsColor: .controlBackgroundColor))
                    }
                }
                .frame(minWidth: geometry.size.width, minHeight: geometry.size.height, alignment: .topLeading)
            }
        }
    }
}

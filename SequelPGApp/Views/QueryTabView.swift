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

            if let result = appVM.queryVM.sortedResult {
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
                            columns: appVM.queryVM.editableColumns,
                            isEditable: appVM.queryVM.editableTableContext != nil,
                            onRowSelected: { rowIdx in
                                appVM.selectRow(index: rowIdx, columns: result.columns, values: result.rows[rowIdx])
                            },
                            onCellEdited: { row, col, text in
                                Task { await appVM.updateQueryCell(rowIndex: row, columnIndex: col, newText: text) }
                            },
                            sortColumn: appVM.queryVM.sortColumn,
                            sortAscending: appVM.queryVM.sortAscending,
                            onColumnHeaderTapped: { column in
                                appVM.toggleQuerySort(column: column)
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
    var columns: [ColumnInfo]
    var isEditable: Bool
    var onRowSelected: ((Int) -> Void)?
    var onCellEdited: ((Int, Int, String) -> Void)?
    var sortColumn: String?
    var sortAscending: Bool
    var onColumnHeaderTapped: ((String) -> Void)?
    @Binding var selectedRowIndex: Int?
    @FocusState private var isFocused: Bool
    @FocusState private var editFieldFocused: Bool
    @State private var editingCell: (row: Int, col: Int)?
    @State private var editingText: String = ""
    private let columnMinWidth: CGFloat = 100

    init(
        result: QueryResult,
        columns: [ColumnInfo] = [],
        isEditable: Bool = false,
        onRowSelected: ((Int) -> Void)? = nil,
        onCellEdited: ((Int, Int, String) -> Void)? = nil,
        sortColumn: String? = nil,
        sortAscending: Bool = true,
        onColumnHeaderTapped: ((String) -> Void)? = nil,
        selectedRowIndex: Binding<Int?> = .constant(nil)
    ) {
        self.result = result
        self.columns = columns
        self.isEditable = isEditable
        self.onRowSelected = onRowSelected
        self.onCellEdited = onCellEdited
        self.sortColumn = sortColumn
        self.sortAscending = sortAscending
        self.onColumnHeaderTapped = onColumnHeaderTapped
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
                                    cellView(rowIdx: rowIdx, colIdx: colIdx)

                                    if colIdx < result.columns.count - 1 {
                                        Divider()
                                    }
                                }
                            }
                            .background(selectedRowIndex == rowIdx ? Color.accentColor.opacity(0.15) : (rowIdx % 2 == 0 ? Color.clear : Color.gray.opacity(0.05)))
                            .contentShape(Rectangle())
                            .onTapGesture {
                                isFocused = true
                                onRowSelected?(rowIdx)
                            }

                            Divider()
                        }
                    } header: {
                        HStack(spacing: 0) {
                            ForEach(0 ..< result.columns.count, id: \.self) { colIdx in
                                let colName = result.columns[colIdx]
                                HStack(spacing: 3) {
                                    Text(colName)
                                        .fontWeight(.semibold)
                                        .lineLimit(1)
                                    if sortColumn == colName {
                                        Image(systemName: sortAscending ? "chevron.up" : "chevron.down")
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                }
                                .frame(minWidth: columnMinWidth, maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 4)
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    onColumnHeaderTapped?(colName)
                                }

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
        .focusable()
        .focused($isFocused)
        .onMoveCommand { direction in
            guard !result.rows.isEmpty else { return }
            let current = selectedRowIndex ?? -1
            let newIndex: Int
            switch direction {
            case .up:
                newIndex = current <= 0 ? 0 : current - 1
            case .down:
                newIndex = min(result.rows.count - 1, current + 1)
            default:
                return
            }
            guard newIndex >= 0, newIndex < result.rows.count else { return }
            onRowSelected?(newIndex)
        }
    }

    @ViewBuilder
    private func cellView(rowIdx: Int, colIdx: Int) -> some View {
        let cell = result.rows[rowIdx][colIdx]

        if let editing = editingCell, editing.row == rowIdx, editing.col == colIdx {
            TextField("", text: $editingText)
                .textFieldStyle(.plain)
                .font(.system(.body, design: .monospaced))
                .frame(minWidth: columnMinWidth, maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .focused($editFieldFocused)
                .onSubmit {
                    commitEdit()
                }
                .onExitCommand {
                    cancelEdit()
                }
        } else {
            Text(cell.displayString)
                .lineLimit(1)
                .font(.system(.body, design: .monospaced))
                .foregroundStyle(cell.isNull ? .secondary : .primary)
                .frame(minWidth: columnMinWidth, maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .contentShape(Rectangle())
                .onTapGesture(count: 2) {
                    guard isEditable else { return }
                    editingText = cell.isNull ? "NULL" : cell.displayString
                    editingCell = (row: rowIdx, col: colIdx)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                        editFieldFocused = true
                    }
                }
        }
    }

    private func commitEdit() {
        guard let editing = editingCell else { return }
        onCellEdited?(editing.row, editing.col, editingText)
        editingCell = nil
        editingText = ""
    }

    private func cancelEdit() {
        editingCell = nil
        editingText = ""
    }
}

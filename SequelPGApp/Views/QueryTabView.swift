import SwiftUI

struct QueryTabView: View {
    @Environment(AppViewModel.self) var appVM
    @Environment(QueryViewModel.self) var queryVM
    @Environment(NavigatorViewModel.self) var navigatorVM
    @Environment(TableViewModel.self) var tableVM

    var body: some View {
        @Bindable var queryVM = queryVM
        @Bindable var tableVM = tableVM
        VSplitView {
            editorArea
                .frame(minHeight: 100)

            resultsArea
                .frame(minHeight: 100)
        }
        .alert(
            "Delete Row?",
            isPresented: Binding<Bool>(
                get: { queryVM.deleteConfirmationRowIndex != nil },
                set: { if !$0 { queryVM.deleteConfirmationRowIndex = nil } }
            )
        ) {
            Button("Cancel", role: .cancel) {
                queryVM.deleteConfirmationRowIndex = nil
            }
            Button("Delete", role: .destructive) {
                if let idx = queryVM.deleteConfirmationRowIndex {
                    queryVM.deleteConfirmationRowIndex = nil
                    Task { await appVM.deleteQueryRow(rowIndex: idx) }
                }
            }
        } message: {
            Text("This row will be permanently deleted from the database.")
        }
        .alert(
            "Foreign Key Conflict",
            isPresented: Binding<Bool>(
                get: { appVM.cascadeDeleteContext?.source == .query },
                set: { if !$0 { appVM.cascadeDeleteContext = nil } }
            )
        ) {
            Button("Cancel", role: .cancel) {
                appVM.cascadeDeleteContext = nil
            }
            Button("Delete All", role: .destructive) {
                Task { await appVM.executeCascadeDelete() }
            }
        } message: {
            Text(appVM.cascadeDeleteContext?.errorMessage ?? "This row is referenced by other tables. Delete all referencing rows too?")
        }
    }

    private var editorArea: some View {
        @Bindable var queryVM = queryVM
        return VStack(spacing: 0) {
            HStack {
                Button {
                    Task { await appVM.executeQuery(queryVM.queryText) }
                } label: {
                    Label("Run", systemImage: "play.fill")
                }
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(queryVM.isExecuting || !appVM.isConnected)

                Button(role: .destructive) {
                    // Stop is disabled; client-side cancellation is not
                    // reliably supported by the driver.
                } label: {
                    Label("Stop", systemImage: "stop.fill")
                }
                .disabled(true)
                .help("Stop is not supported by the current driver configuration.")

                Button {
                    queryVM.queryText = ""
                    queryVM.result = nil
                    queryVM.errorMessage = nil
                } label: {
                    Label("Clear", systemImage: "trash")
                }

                Button {
                    queryVM.beautify()
                } label: {
                    Label("Beautify", systemImage: "wand.and.stars")
                }
                .disabled(queryVM.queryText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .help("Format SQL query")

                Spacer()

                if queryVM.isExecuting {
                    ProgressView()
                        .controlSize(.small)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)

            Divider()

            SQLEditorView(
                text: $queryVM.queryText,
                completionMetadata: SQLCompletionProvider.Metadata(
                    schemas: navigatorVM.schemas,
                    tables: navigatorVM.tables,
                    columns: tableVM.columns
                )
            )
        }
    }

    private var resultsArea: some View {
        @Bindable var tableVM = tableVM
        return VStack(spacing: 0) {
            if let error = queryVM.errorMessage {
                errorBanner(error)
            }

            if let result = queryVM.sortedResult {
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
                            columns: queryVM.editableColumns,
                            isEditable: queryVM.editableTableContext != nil,
                            onRowSelected: { rowIdx in
                                appVM.selectRow(index: rowIdx, columns: result.columns, values: result.rows[rowIdx])
                            },
                            onCellEdited: { row, col, text in
                                Task { await appVM.updateQueryCell(rowIndex: row, columnIndex: col, newText: text) }
                            },
                            sortColumn: queryVM.sortColumn,
                            sortAscending: queryVM.sortAscending,
                            onColumnHeaderTapped: { column in
                                appVM.toggleQuerySort(column: column)
                            },
                            onDeleteRow: appVM.canDeleteQueryRow ? { rowIdx in
                                queryVM.deleteConfirmationRowIndex = rowIdx
                            } : nil,
                            selectedRowIndex: $tableVM.selectedRowIndex
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
            } else if !queryVM.isExecuting {
                Text("Enter a query and press Cmd+Enter to execute.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private func errorBanner(_ message: String) -> some View {
        @Bindable var queryVM = queryVM
        return HStack {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
            Text(message)
                .lineLimit(2)
            Spacer()
            Button("Dismiss") {
                queryVM.errorMessage = nil
            }
            .buttonStyle(.borderless)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color.red.opacity(0.1))
    }
}

/// Wrapper that gives each row a stable identity for use with Table.
struct IdentifiedRow: Identifiable {
    let id: Int // row index
    let cells: [CellValue]
}

/// Wrapper that gives each column a stable identity for TableColumnForEach.
struct IdentifiedColumn: Identifiable {
    let id: Int // column index
    let name: String
}

/// Comparator that sorts IdentifiedRow values by a specific column index.
struct ColumnSortComparator: SortComparator {
    var columnIndex: Int
    var columnName: String
    var order: SortOrder

    func compare(_ lhs: IdentifiedRow, _ rhs: IdentifiedRow) -> ComparisonResult {
        let lVal = lhs.cells[columnIndex].displayString
        let rVal = rhs.cells[columnIndex].displayString
        let result = lVal.localizedStandardCompare(rVal)
        return order == .forward ? result : result.reversed
    }
}

private extension ComparisonResult {
    var reversed: ComparisonResult {
        switch self {
        case .orderedAscending: return .orderedDescending
        case .orderedDescending: return .orderedAscending
        case .orderedSame: return .orderedSame
        }
    }
}

/// Native macOS Table-based grid for displaying query results with dynamic columns.
struct ResultsGridView: View {
    let result: QueryResult
    var columns: [ColumnInfo]
    var isEditable: Bool
    var onRowSelected: ((Int) -> Void)?
    var onCellEdited: ((Int, Int, String) -> Void)?
    var sortColumn: String?
    var sortAscending: Bool
    var onColumnHeaderTapped: ((String) -> Void)?
    var onDeleteRow: ((Int) -> Void)?
    var isInsertingRow: Bool
    var insertRowValues: Binding<[String: String]>?
    var onInsertCommit: (() -> Void)?
    var onInsertCancel: (() -> Void)?
    @Binding var selectedRowIndex: Int?
    @FocusState private var isFocused: Bool
    @FocusState private var editFieldFocused: Bool
    @FocusState private var insertFieldFocused: Bool
    @State private var editingCell: (row: Int, col: Int)?
    @State private var editingText: String = ""
    @State private var sortOrder: [ColumnSortComparator] = []
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
        onDeleteRow: ((Int) -> Void)? = nil,
        selectedRowIndex: Binding<Int?> = .constant(nil),
        isInsertingRow: Bool = false,
        insertRowValues: Binding<[String: String]>? = nil,
        onInsertCommit: (() -> Void)? = nil,
        onInsertCancel: (() -> Void)? = nil
    ) {
        self.result = result
        self.columns = columns
        self.isEditable = isEditable
        self.onRowSelected = onRowSelected
        self.onCellEdited = onCellEdited
        self.sortColumn = sortColumn
        self.sortAscending = sortAscending
        self.onColumnHeaderTapped = onColumnHeaderTapped
        self.onDeleteRow = onDeleteRow
        self._selectedRowIndex = selectedRowIndex
        self.isInsertingRow = isInsertingRow
        self.insertRowValues = insertRowValues
        self.onInsertCommit = onInsertCommit
        self.onInsertCancel = onInsertCancel
    }

    private var identifiedRows: [IdentifiedRow] {
        result.rows.enumerated().map { idx, cells in
            IdentifiedRow(id: idx, cells: cells)
        }
    }

    private var identifiedColumns: [IdentifiedColumn] {
        result.columns.enumerated().map { idx, name in
            IdentifiedColumn(id: idx, name: name)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            Table(identifiedRows, selection: $selectedRowIndex, sortOrder: $sortOrder) {
                TableColumnForEach(identifiedColumns) { column in
                    TableColumn(column.name, sortUsing: ColumnSortComparator(
                        columnIndex: column.id,
                        columnName: column.name,
                        order: .forward
                    )) { row in
                        cellView(rowIdx: row.id, colIdx: column.id)
                    }
                    .width(min: columnMinWidth)
                }
            }
            .tableStyle(.bordered(alternatesRowBackgrounds: true))
            .contextMenu(forSelectionType: IdentifiedRow.ID.self) { selectedIds in
                if let onDeleteRow, let rowIdx = selectedIds.first {
                    Button(role: .destructive) {
                        onDeleteRow(rowIdx)
                    } label: {
                        Label("Delete Row", systemImage: "trash")
                    }
                }
            }
            .onChange(of: selectedRowIndex) { _, newValue in
                if let newValue {
                    onRowSelected?(newValue)
                }
            }
            .onChange(of: sortOrder) { _, newOrder in
                if let first = newOrder.first {
                    onColumnHeaderTapped?(first.columnName)
                }
            }
            .focusable()
            .focused($isFocused)
            .onDeleteCommand {
                guard let onDeleteRow, let idx = selectedRowIndex else { return }
                onDeleteRow(idx)
            }

            if isInsertingRow, let binding = insertRowValues {
                Divider()
                insertRowView(binding: binding)
            }
        }
    }

    @ViewBuilder
    private func cellView(rowIdx: Int, colIdx: Int) -> some View {
        let cell = result.rows[rowIdx][colIdx]

        if let editing = editingCell, editing.row == rowIdx, editing.col == colIdx {
            TextField("", text: $editingText)
                .textFieldStyle(.plain)
                .font(.system(.body, design: .monospaced))
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
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .onTapGesture(count: 2) {
                    guard isEditable else { return }
                    editingText = cell.isNull ? "NULL" : cell.displayString
                    editingCell = (row: rowIdx, col: colIdx)
                    editFieldFocused = true
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

    @ViewBuilder
    private func insertRowView(binding: Binding<[String: String]>) -> some View {
        let colInfoByName = Dictionary(columns.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
        HStack(spacing: 0) {
            ForEach(0 ..< result.columns.count, id: \.self) { colIdx in
                let colName = result.columns[colIdx]
                let colInfo = colInfoByName[colName]
                let placeholder = colInfo.map { info -> String in
                    var parts: [String] = [info.dataType]
                    if info.isNullable { parts.append("nullable") }
                    if info.columnDefault != nil { parts.append("has default") }
                    return parts.joined(separator: ", ")
                } ?? colName

                TextField(placeholder, text: Binding(
                    get: { binding.wrappedValue[colName] ?? "" },
                    set: { binding.wrappedValue[colName] = $0 }
                ))
                .textFieldStyle(.plain)
                .font(.system(.body, design: .monospaced))
                .frame(minWidth: columnMinWidth, maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .focused($insertFieldFocused)

                if colIdx < result.columns.count - 1 {
                    Divider()
                }
            }
        }
        .background(Color.blue.opacity(0.08))
        .onExitCommand {
            onInsertCancel?()
        }
    }
}

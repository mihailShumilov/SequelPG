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
                    schemas: navigatorVM.schemas(for: navigatorVM.connectedDatabase),
                    tables: navigatorVM.allLoadedTables,
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
    @State private var originalEditText: String = ""
    @State private var sortOrder: [ColumnSortComparator] = []
    @State private var fieldEditorCell: (row: Int, col: Int)?
    private let columnMinWidth: CGFloat = 100
    private let columnsByName: [String: ColumnInfo]
    private let identifiedRows: [IdentifiedRow]
    private let identifiedColumns: [IdentifiedColumn]

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
        self.columnsByName = Dictionary(columns.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
        self.identifiedRows = result.rows.enumerated().map { IdentifiedRow(id: $0.offset, cells: $0.element) }
        self.identifiedColumns = result.columns.enumerated().map { IdentifiedColumn(id: $0.offset, name: $0.element) }
    }

    var body: some View {
        VStack(spacing: 0) {
            Table(identifiedRows, selection: $selectedRowIndex, sortOrder: $sortOrder) {
                TableColumnForEach(identifiedColumns) { column in
                    TableColumn(headerTitle(for: column.name), sortUsing: ColumnSortComparator(
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

    /// Returns the FieldEditorKind for a column index, or .plain if no column info.
    private func editorKind(for colIdx: Int, cell: CellValue) -> FieldEditorKind {
        let colName = colIdx < result.columns.count ? result.columns[colIdx] : ""
        guard let info = columnsByName[colName] else { return .plain }
        let value = cell.isNull ? "" : cell.displayString
        return FieldEditorKind(udtName: info.udtName, dataType: info.dataType, value: value)
    }

    /// Whether this column should use the rich popover editor instead of inline TextField.
    private func needsRichEditor(kind: FieldEditorKind) -> Bool {
        switch kind {
        case .json, .array, .boolean, .longText: return true
        case .plain: return false
        }
    }

    @ViewBuilder
    private func cellView(rowIdx: Int, colIdx: Int) -> some View {
        // Guard against stale row/column IDs that the Table may request
        // after the result changes (e.g., when switching tabs).
        if rowIdx < result.rows.count, colIdx < result.rows[rowIdx].count {
            let cell = result.rows[rowIdx][colIdx]
            let kind = editorKind(for: colIdx, cell: cell)
            let renderKind = CellRenderKind.from(column: columnInfo(for: colIdx), cell: cell)
            if let editing = editingCell, editing.row == rowIdx, editing.col == colIdx {
                TextField("NULL", text: $editingText)
                    .textFieldStyle(.plain)
                    .font(.system(.body, design: .monospaced))
                    .focused($editFieldFocused)
                    .onSubmit {
                        commitEdit()
                    }
                    .onExitCommand {
                        cancelEdit()
                    }
                    .onChange(of: editFieldFocused) { _, focused in
                        if !focused {
                            commitEdit()
                        }
                    }
            } else {
                HStack(spacing: 4) {
                    if renderKind.alignment == .trailing { Spacer(minLength: 0) }
                    CellTypeBadge(kind: kind)
                    cellContentView(cell: cell, renderKind: renderKind)
                    if renderKind.alignment == .leading { Spacer(minLength: 0) }
                }
                .padding(.vertical, 3)
                .frame(maxWidth: .infinity)
                .contentShape(Rectangle())
                .help(cell.isNull ? "NULL" : cell.displayString)
                .onTapGesture(count: 2) {
                    guard isEditable else { return }
                    if editingCell != nil {
                        commitEdit()
                    }
                    if needsRichEditor(kind: kind) {
                        fieldEditorCell = (row: rowIdx, col: colIdx)
                    } else {
                        startEditing(row: rowIdx, col: colIdx, cell: cell)
                    }
                }
                .popover(
                    isPresented: Binding(
                        get: { fieldEditorCell?.row == rowIdx && fieldEditorCell?.col == colIdx },
                        set: { if !$0 { fieldEditorCell = nil } }
                    ),
                    arrowEdge: .bottom
                ) {
                    fieldEditorPopover(rowIdx: rowIdx, colIdx: colIdx, cell: cell)
                }
            }
        } else {
            Text("")
        }
    }

    /// Returns the ColumnInfo for a column index by name, if available.
    private func columnInfo(for colIdx: Int) -> ColumnInfo? {
        guard colIdx < result.columns.count else { return nil }
        return columnsByName[result.columns[colIdx]]
    }

    /// Renders the cell's text using a typography appropriate to its category:
    /// muted italic for NULL, monospaced for IDs / numbers / dates / network /
    /// JSON, sans-serif for plain text, and a small dot indicator for booleans.
    @ViewBuilder
    private func cellContentView(cell: CellValue, renderKind: CellRenderKind) -> some View {
        switch renderKind {
        case .null:
            Text("NULL")
                .font(.system(.body, design: .monospaced))
                .italic()
                .foregroundStyle(.tertiary)
        case .boolean:
            let isTrue = cell.displayString == "true"
            HStack(spacing: 5) {
                Circle()
                    .fill(isTrue ? Color.green : Color.gray.opacity(0.45))
                    .frame(width: 7, height: 7)
                Text(isTrue ? "true" : "false")
                    .font(.system(.body))
            }
        case .number:
            Text(cell.displayString)
                .font(.system(.body, design: .monospaced))
                .lineLimit(1)
        case .uuid:
            Text(cell.displayString)
                .font(.system(.body, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        case .network:
            Text(cell.displayString)
                .font(.system(.body, design: .monospaced))
                .lineLimit(1)
        case .date, .timestamp:
            Text(cell.displayString)
                .font(.system(.body, design: .monospaced))
                .lineLimit(1)
        case .json:
            Text(cell.displayString)
                .font(.system(.body, design: .monospaced))
                .foregroundStyle(.primary)
                .lineLimit(1)
        case .binary:
            Text(cell.displayString)
                .font(.system(.body, design: .monospaced))
                .italic()
                .foregroundStyle(.tertiary)
        case .text:
            Text(cell.displayString)
                .font(.system(.body, design: .monospaced))
                .lineLimit(1)
        }
    }

    /// Builds the column header label, appending a short type tag after the
    /// column name (e.g. "user_id · text", "amount · int4"). When the column's
    /// type isn't known (free-form queries with no editable table context),
    /// falls back to just the column name.
    private func headerTitle(for columnName: String) -> String {
        guard let info = columnsByName[columnName] else { return columnName }
        let short = ColumnInfo.shortTypeName(dataType: info.dataType, udtName: info.udtName)
        if short.isEmpty { return columnName }
        return "\(columnName)  ·  \(short)"
    }

    @ViewBuilder
    private func fieldEditorPopover(rowIdx: Int, colIdx: Int, cell: CellValue) -> some View {
        let colName = colIdx < result.columns.count ? result.columns[colIdx] : "Column"
        let info = columns.first(where: { $0.name == colName })
        FieldEditorView(
            columnName: colName,
            dataType: info?.dataType ?? "text",
            isNullable: info?.isNullable ?? true,
            initialValue: cell,
            onSave: { newText in
                fieldEditorCell = nil
                onCellEdited?(rowIdx, colIdx, newText)
            },
            onCancel: {
                fieldEditorCell = nil
            }
        )
    }

    private func startEditing(row: Int, col: Int, cell: CellValue) {
        let text = cell.isNull ? "" : cell.displayString
        editingText = text
        originalEditText = text
        editingCell = (row: row, col: col)
        editFieldFocused = true
    }

    private func commitEdit() {
        guard let editing = editingCell else { return }
        let changed = editingText != originalEditText
        let row = editing.row
        let col = editing.col
        editingCell = nil
        let text = editingText
        editingText = ""
        originalEditText = ""
        if changed {
            onCellEdited?(row, col, text)
        }
    }

    private func cancelEdit() {
        editingCell = nil
        editingText = ""
        originalEditText = ""
    }

    @ViewBuilder
    private func insertRowView(binding: Binding<[String: String]>) -> some View {
        HStack(spacing: 0) {
            ForEach(0 ..< result.columns.count, id: \.self) { colIdx in
                let colName = result.columns[colIdx]
                let colInfo = columnsByName[colName]
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

// MARK: - Cell Render Classification

/// Classifies a cell for *display* (alignment, typography, color), as opposed
/// to `FieldEditorKind`, which classifies it for choosing an *editor* widget.
/// Display kinds carry more granularity (numbers, dates, UUIDs, etc.) because
/// they each warrant distinct visual treatment even though they all share the
/// same plain inline editor.
enum CellRenderKind {
    case null, boolean, number, uuid, date, timestamp, json, binary, network, text

    /// Numeric values right-align so digit columns line up by magnitude. All
    /// other categories left-align for natural reading order.
    var alignment: HorizontalAlignment {
        self == .number ? .trailing : .leading
    }

    static func from(column: ColumnInfo?, cell: CellValue) -> CellRenderKind {
        if cell.isNull { return .null }
        guard let info = column else { return .text }
        let dt = info.dataType.lowercased().trimmingCharacters(in: .whitespaces)
        let udt = info.udtName?.lowercased() ?? ""
        switch dt {
        case "boolean", "bool": return .boolean
        case "uuid": return .uuid
        case "date": return .date
        case "json", "jsonb": return .json
        case "bytea": return .binary
        case "inet", "cidr", "macaddr", "macaddr8": return .network
        default: break
        }
        if dt.contains("timestamp") || dt.hasPrefix("time ") || dt == "time" { return .timestamp }
        let numerics: Set<String> = [
            "smallint", "integer", "bigint", "decimal", "numeric",
            "real", "double precision", "smallserial", "serial", "bigserial", "money",
        ]
        let udtNumerics: Set<String> = ["int2", "int4", "int8", "float4", "float8", "numeric"]
        if numerics.contains(dt) || udtNumerics.contains(udt) { return .number }
        return .text
    }
}

extension ColumnInfo {
    /// Returns the compact form of a PostgreSQL type name used in column
    /// headers (e.g. "integer" → "int4", "character varying" → "varchar",
    /// "timestamp without time zone" → "timestamp"). Prefers the catalog-level
    /// `udtName` when it's already short, otherwise falls back to a curated
    /// map of long names; returns the original on no match.
    static func shortTypeName(dataType: String, udtName: String?) -> String {
        let dt = dataType.lowercased().trimmingCharacters(in: .whitespaces)
        let udt = udtName?.lowercased() ?? ""
        if !udt.isEmpty, udt != dt {
            let aliases: [String: String] = [
                "int2": "int2", "int4": "int4", "int8": "int8",
                "float4": "float4", "float8": "float8",
                "bpchar": "char", "varchar": "varchar",
                "timestamptz": "timestamptz", "timetz": "timetz",
            ]
            if let mapped = aliases[udt] { return mapped }
        }
        let longMap: [String: String] = [
            "smallint": "int2",
            "integer": "int4",
            "bigint": "int8",
            "real": "float4",
            "double precision": "float8",
            "character varying": "varchar",
            "character": "char",
            "timestamp without time zone": "timestamp",
            "timestamp with time zone": "timestamptz",
            "time without time zone": "time",
            "time with time zone": "timetz",
            "boolean": "bool",
        ]
        return longMap[dt] ?? dt
    }
}

import AppKit
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
            DataGridView(
                rowCount: identifiedRows.count,
                columns: identifiedColumns.map { col in
                    DataGridView.Column(
                        id: col.id,
                        title: headerTitle(for: col.name),
                        rawName: col.name,
                        minWidth: columnMinWidth
                    )
                },
                selectedRowIndex: $selectedRowIndex,
                sortColumnName: sortColumn,
                sortAscending: sortAscending,
                onSelectionChanged: { idx in
                    if let idx { onRowSelected?(idx) }
                },
                onColumnHeaderClicked: { colName in
                    onColumnHeaderTapped?(colName)
                },
                onDoubleClick: { rowIdx, colIdx in
                    handleCellDoubleClick(row: rowIdx, col: colIdx)
                },
                onDeleteSelected: {
                    if let onDeleteRow, let idx = selectedRowIndex {
                        onDeleteRow(idx)
                    }
                },
                contextMenuItems: { rowIdx in
                    guard let onDeleteRow else { return [] }
                    return [
                        DataGridView.MenuItem(title: "Delete Row", isDestructive: true) {
                            onDeleteRow(rowIdx)
                        },
                    ]
                },
                renderCell: { rowIdx, colIdx in
                    AnyView(cellView(rowIdx: rowIdx, colIdx: colIdx))
                }
            )

            if isInsertingRow, let binding = insertRowValues {
                Divider()
                insertRowView(binding: binding)
            }
        }
        // Single sheet hosting the rich field editor. Lifted out of the cell
        // view so we don't pay the per-cell popover allocation that froze
        // SwiftUI when there were dozens of columns visible.
        .sheet(isPresented: Binding(
            get: { fieldEditorCell != nil },
            set: { if !$0 { fieldEditorCell = nil } }
        )) {
            if let editing = fieldEditorCell,
               editing.row < result.rows.count,
               editing.col < result.rows[editing.row].count
            {
                fieldEditorPopover(rowIdx: editing.row, colIdx: editing.col, cell: result.rows[editing.row][editing.col])
            }
        }
    }

    private func handleCellDoubleClick(row: Int, col: Int) {
        guard isEditable, row < result.rows.count, col < result.rows[row].count else { return }
        if editingCell != nil { commitEdit() }
        // All edits route through the field-editor sheet now that cells don't
        // capture mouse input (so they couldn't host an inline TextField that
        // takes focus on click anyway).
        fieldEditorCell = (row: row, col: col)
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
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .frame(maxWidth: .infinity, alignment: renderKind.alignment == .trailing ? .trailing : .leading)
                // Field editor presentation lives on the parent body (sheet),
                // not per cell. Putting a .popover on every cell — each living
                // inside its own NSHostingView under our AppKit table — caused
                // SwiftUI to create a fresh NSPopover per cell on every reload,
                // overflowing NSWindow's live-window count and freezing the UI.
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

// MARK: - DataGridView (AppKit-backed)

/// Native AppKit data grid wrapping NSScrollView + NSTableView. Replaces
/// SwiftUI's `Table` so we get reliable first-click row selection, hardware-
/// accelerated scrolling on large result sets, and native vertical column
/// dividers via `gridStyleMask` that always line up with the header.
///
/// Cells are still SwiftUI views — each NSTableCellView hosts an
/// `NSHostingView` whose root view is the SwiftUI cell content. That keeps
/// the type-aware rendering, badges, NULL styling, etc., while delegating
/// the heavy lifting (scrolling, selection, sort, drag-resize) to AppKit.
struct DataGridView: NSViewRepresentable {
    struct Column {
        let id: Int
        let title: String
        let rawName: String
        let minWidth: CGFloat
    }

    struct MenuItem {
        let title: String
        let isDestructive: Bool
        let action: () -> Void
    }

    let rowCount: Int
    let columns: [Column]
    @Binding var selectedRowIndex: Int?
    var sortColumnName: String?
    var sortAscending: Bool
    var onSelectionChanged: (Int?) -> Void
    var onColumnHeaderClicked: (String) -> Void
    var onDoubleClick: (Int, Int) -> Void
    var onDeleteSelected: () -> Void
    var contextMenuItems: (Int) -> [MenuItem]
    var renderCell: (Int, Int) -> AnyView

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = true

        let tableView = FocusableTableView()
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.gridStyleMask = [.solidVerticalGridLineMask]
        tableView.gridColor = NSColor.separatorColor
        tableView.style = .inset
        tableView.allowsEmptySelection = true
        // Multi-selection enabled — Shift-click extends to a contiguous range,
        // Cmd-click toggles individual rows in/out of the selection.
        tableView.allowsMultipleSelection = true
        tableView.allowsColumnSelection = false
        tableView.allowsColumnReordering = false
        tableView.allowsColumnResizing = true
        tableView.usesAutomaticRowHeights = false
        tableView.rowHeight = 22
        tableView.intercellSpacing = NSSize(width: 0, height: 0)
        tableView.dataSource = context.coordinator
        tableView.delegate = context.coordinator
        tableView.target = context.coordinator
        tableView.doubleAction = #selector(Coordinator.handleDoubleClick(_:))
        tableView.menu = NSMenu()
        tableView.menu?.delegate = context.coordinator
        tableView.headerView?.menu = nil

        // Initial column install. We rebuild on column-shape changes in update().
        for col in columns {
            tableView.addTableColumn(makeColumn(for: col))
        }

        scrollView.documentView = tableView
        context.coordinator.tableView = tableView
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let tableView = scrollView.documentView as? FocusableTableView else { return }
        let coordinator = context.coordinator
        coordinator.parent = self

        // Rebuild columns only if the column set actually changed — column
        // identity is the IdentifiedColumn id (its index in the result).
        let currentIDs = tableView.tableColumns.compactMap { Int($0.identifier.rawValue) }
        let desiredIDs = columns.map(\.id)
        let columnsChanged = currentIDs != desiredIDs ||
            zip(tableView.tableColumns, columns).contains { $0.0.title != $0.1.title }

        if columnsChanged {
            for c in tableView.tableColumns { tableView.removeTableColumn(c) }
            for col in columns { tableView.addTableColumn(makeColumn(for: col)) }
        }

        // Reload data. NSTableView reuses cell views, but our cell content is
        // generated by a SwiftUI closure that captures fresh state, so we need
        // to redraw to pick up edits/inserts/sort changes.
        tableView.reloadData()

        // Sync selection from the binding into the table. The flag suppresses
        // the resulting tableViewSelectionDidChange callback so we don't write
        // back into the SwiftUI binding during a view update (which is what
        // produced the "Modifying state during view update" warnings).
        let desiredSelection = selectedRowIndex.flatMap { ($0 >= 0 && $0 < rowCount) ? IndexSet(integer: $0) : nil } ?? IndexSet()
        if tableView.selectedRowIndexes != desiredSelection {
            coordinator.isSyncingFromSwiftUI = true
            tableView.selectRowIndexes(desiredSelection, byExtendingSelection: false)
            coordinator.isSyncingFromSwiftUI = false
        }

        // Sort indicator on the header.
        for col in tableView.tableColumns {
            tableView.setIndicatorImage(nil, in: col)
        }
        if let name = sortColumnName,
           let col = tableView.tableColumns.first(where: { ($0.headerCell as? NSTableHeaderCell)?.stringValue.hasPrefix(name) == true || coordinator.rawName(forColumnId: Int($0.identifier.rawValue) ?? -1) == name })
        {
            let indicator = NSImage(named: sortAscending ? "NSAscendingSortIndicator" : "NSDescendingSortIndicator")
            tableView.setIndicatorImage(indicator, in: col)
            tableView.highlightedTableColumn = col
        }
    }

    private func makeColumn(for col: Column) -> NSTableColumn {
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(rawValue: String(col.id)))
        column.title = col.title
        column.minWidth = col.minWidth
        column.width = max(col.minWidth, 140)
        column.resizingMask = .userResizingMask
        // Sort descriptor key uses the raw column name so we can map it back
        // to the caller's sort callback (which expects the SQL column name).
        column.sortDescriptorPrototype = NSSortDescriptor(key: col.rawName, ascending: true)
        return column
    }

    // MARK: - Coordinator

    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSMenuDelegate {
        var parent: DataGridView
        weak var tableView: NSTableView?
        private let cellIdentifier = NSUserInterfaceItemIdentifier(rawValue: "DataGridCell")
        // Set true while updateNSView is syncing SwiftUI → NSTableView so the
        // resulting tableViewSelectionDidChange notification doesn't bounce
        // back through the binding mid-view-update.
        var isSyncingFromSwiftUI = false

        init(_ parent: DataGridView) {
            self.parent = parent
        }

        func rawName(forColumnId id: Int) -> String? {
            parent.columns.first(where: { $0.id == id })?.rawName
        }

        // MARK: NSTableViewDataSource

        func numberOfRows(in tableView: NSTableView) -> Int {
            parent.rowCount
        }

        func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
            guard let key = tableView.sortDescriptors.first?.key else { return }
            parent.onColumnHeaderClicked(key)
        }

        // MARK: NSTableViewDelegate

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            guard let tableColumn,
                  let colId = Int(tableColumn.identifier.rawValue),
                  row >= 0, row < parent.rowCount
            else { return nil }

            // We always recreate the hosting view's root view — SwiftUI cell
            // content is cheap and this is the simplest path to "always
            // reflects the latest model state".
            let view = parent.renderCell(row, colId)

            if let cellView = tableView.makeView(withIdentifier: cellIdentifier, owner: self) as? HostingCellView {
                cellView.update(rootView: view)
                return cellView
            }
            let cellView = HostingCellView(rootView: view)
            cellView.identifier = cellIdentifier
            return cellView
        }

        func tableViewSelectionDidChange(_ notification: Notification) {
            // Skip the bounce when the change came from updateNSView pushing
            // the SwiftUI binding into the table.
            if isSyncingFromSwiftUI { return }
            guard let tv = notification.object as? NSTableView else { return }
            // For multi-selection, expose the most recently clicked row to
            // the single-Int? binding. Multi-row context-menu / delete picks
            // up the full set via NSTableView.selectedRowIndexes directly.
            let newIdx: Int? = tv.selectedRow >= 0 ? tv.selectedRow : nil
            if parent.selectedRowIndex != newIdx {
                parent.selectedRowIndex = newIdx
                parent.onSelectionChanged(newIdx)
            }
        }

        @objc func handleDoubleClick(_ sender: Any?) {
            guard let tv = tableView else { return }
            let row = tv.clickedRow
            let col = tv.clickedColumn
            guard row >= 0, col >= 0,
                  let colId = Int(tv.tableColumns[col].identifier.rawValue) else { return }
            parent.onDoubleClick(row, colId)
        }

        // MARK: Context menu

        func menuNeedsUpdate(_ menu: NSMenu) {
            menu.removeAllItems()
            guard let tv = tableView else { return }
            // Right-click semantics: the row under the cursor is the operand
            // even if it isn't selected. Mirror Finder-style behavior.
            let targetRow = tv.clickedRow >= 0 ? tv.clickedRow : tv.selectedRow
            guard targetRow >= 0 else { return }

            for item in parent.contextMenuItems(targetRow) {
                let menuItem = NSMenuItem(title: item.title, action: #selector(menuItemClicked(_:)), keyEquivalent: "")
                menuItem.target = self
                menuItem.representedObject = item.action
                if item.isDestructive { menuItem.attributedTitle = NSAttributedString(string: item.title, attributes: [.foregroundColor: NSColor.systemRed]) }
                menu.addItem(menuItem)
            }
        }

        @objc private func menuItemClicked(_ sender: NSMenuItem) {
            (sender.representedObject as? () -> Void)?()
        }
    }

    // MARK: - HostingCellView

    /// NSTableCellView that hosts a SwiftUI view edge-to-edge. Reused across
    /// scrolling via NSTableView's normal recycling.
    ///
    /// Hit-testing returns nil so mouse events bypass the SwiftUI subtree and
    /// reach the underlying NSTableView — that's what makes single-click row
    /// selection work on the *first* click. SwiftUI cells are display-only;
    /// in-place editing happens via the field-editor sheet, not by interacting
    /// with widgets inside the cell.
    private final class HostingCellView: NSTableCellView {
        private var hosting: NSHostingView<AnyView>

        init(rootView: AnyView) {
            self.hosting = NSHostingView(rootView: rootView)
            super.init(frame: .zero)
            hosting.translatesAutoresizingMaskIntoConstraints = false
            addSubview(hosting)
            NSLayoutConstraint.activate([
                hosting.leadingAnchor.constraint(equalTo: leadingAnchor),
                hosting.trailingAnchor.constraint(equalTo: trailingAnchor),
                hosting.topAnchor.constraint(equalTo: topAnchor),
                hosting.bottomAnchor.constraint(equalTo: bottomAnchor),
            ])
        }

        required init?(coder: NSCoder) { fatalError("not used") }

        func update(rootView: AnyView) {
            hosting.rootView = rootView
        }

        override func hitTest(_ point: NSPoint) -> NSView? {
            // Pass mouse events through to the NSTableView so click → select
            // works on the first click. The cell's SwiftUI content stays
            // visible and reactive to data updates; it just doesn't capture
            // mouse input.
            return nil
        }
    }

    // MARK: - FocusableTableView

    /// NSTableView subclass that accepts the first mouse click as a real
    /// click — both becomes-first-responder AND selects the row in one
    /// gesture. The default behavior swallows the first click when the view
    /// isn't already first responder, which is the "have to click twice"
    /// problem.
    final class FocusableTableView: NSTableView {
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        override var acceptsFirstResponder: Bool { true }

        // Forward delete / backspace to the bound delete callback when a
        // row is selected, matching SwiftUI Table's onDeleteCommand behavior.
        override func keyDown(with event: NSEvent) {
            let chars = event.charactersIgnoringModifiers ?? ""
            if (chars == "\u{7F}" || chars == "\u{8}") && selectedRow >= 0 {
                if let coord = delegate as? Coordinator {
                    coord.parent.onDeleteSelected()
                    return
                }
            }
            super.keyDown(with: event)
        }
    }
}

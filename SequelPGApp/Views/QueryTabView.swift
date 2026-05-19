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
            HStack(spacing: 8) {
                QueryActionButton(
                    title: "Run", systemImage: "play.fill", isPrimary: true,
                    disabled: queryVM.isExecuting || !appVM.isConnected
                ) {
                    Task { await appVM.executeQuery(queryVM.queryText) }
                }
                .keyboardShortcut(.return, modifiers: .command)

                // Explain (no execute) — safe to press on any query, including
                // DML. Renders the planner's predicted shape.
                QueryActionButton(
                    title: "Explain", systemImage: "list.bullet.indent",
                    disabled: queryVM.isExecuting || !appVM.isConnected ||
                        queryVM.queryText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ) {
                    Task { await appVM.explainQuery(queryVM.queryText, analyze: false) }
                }

                // Analyze — actually runs the query. Hold ⌥ for a finer "yes
                // I know this writes" affordance later; for v1 the user is
                // trusted to know what their query does.
                QueryActionButton(
                    title: "Analyze", systemImage: "stopwatch",
                    disabled: queryVM.isExecuting || !appVM.isConnected ||
                        queryVM.queryText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ) {
                    Task { await appVM.explainQuery(queryVM.queryText, analyze: true) }
                }

                QueryActionButton(title: "Clear", systemImage: "trash", disabled: false) {
                    queryVM.queryText = ""
                    queryVM.result = nil
                    queryVM.plan = nil
                    queryVM.activeResultsTab = .results
                    queryVM.errorMessage = nil
                }

                QueryActionButton(
                    title: "Beautify", systemImage: "wand.and.stars",
                    disabled: queryVM.queryText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ) {
                    queryVM.beautify()
                }

                Spacer(minLength: 8)

                // Meta affordances: keyboard hint + connection status dot.
                // Pinned with `.fixedSize` and `.lineLimit(1)` so the toolbar
                // can't enter a layout-feedback loop where a wrapping label
                // forces the buttons next to it to compress to a 1-char column.
                HStack(spacing: 8) {
                    HStack(spacing: 4) {
                        AppKbd(key: "⌘")
                        AppKbd(key: "↵")
                        Text("to run")
                            .appMono(11, color: Theme.ink3)
                            .padding(.leading, 2)
                    }
                    Text("·")
                        .appMono(11, color: Theme.ink4)
                    HStack(spacing: 6) {
                        Circle()
                            .fill(appVM.isConnected ? Theme.accent : Theme.ink4)
                            .frame(width: 7, height: 7)
                            .overlay(
                                Circle()
                                    .stroke(Theme.accent.opacity(appVM.isConnected ? 0.25 : 0), lineWidth: 3)
                            )
                        Text(appVM.connectedProfileName ?? "disconnected")
                            .appMono(11, color: Theme.ink3)
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .frame(maxWidth: 200, alignment: .leading)
                    }
                }
                .fixedSize(horizontal: true, vertical: false)

                if queryVM.isExecuting {
                    ProgressView()
                        .controlSize(.small)
                }
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 10)
            .background(Theme.bg)

            Rectangle().fill(Theme.line).frame(height: 1)

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
            // Results-panel header — tabs for Results / Messages / EXPLAIN, plus
            // a meta row on the right with status, row count, and exec time.
            // The header shows whenever there's *anything* to show (a result,
            // a plan, or an error), not just after a row-returning query.
            let hasAnyContent = queryVM.sortedResult != nil || queryVM.plan != nil || queryVM.errorMessage != nil
            if hasAnyContent {
                HStack(spacing: 14) {
                    HStack(spacing: 14) {
                        ResultsTab(label: "Results", isActive: queryVM.activeResultsTab == .results) {
                            queryVM.activeResultsTab = .results
                        }
                        ResultsTab(label: "Messages", isActive: queryVM.activeResultsTab == .messages) {
                            queryVM.activeResultsTab = .messages
                        }
                        ResultsTab(label: "EXPLAIN", isActive: queryVM.activeResultsTab == .explain) {
                            queryVM.activeResultsTab = .explain
                        }
                    }
                    Spacer()
                    resultsMetaRow
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 8)
                .frame(height: 36)
                .background(Theme.bg2)
                .overlay(alignment: .bottom) {
                    Rectangle().fill(Theme.line).frame(height: 1)
                }
            }

            if let error = queryVM.errorMessage {
                errorBanner(error)
            }

            if queryVM.activeResultsTab == .explain {
                if let plan = queryVM.plan {
                    QueryPlanView(plan: plan)
                } else if queryVM.errorMessage == nil {
                    QueryPlanEmptyView(isConnected: appVM.isConnected)
                }
            } else if let result = queryVM.sortedResult {
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

                        Rectangle().fill(Theme.line).frame(height: 1)

                        HStack(spacing: 12) {
                            Text("\(result.rowCount) row\(result.rowCount == 1 ? "" : "s")")
                                .appMono(11, color: Theme.ink3)
                            if result.isTruncated {
                                Text("capped at 2000")
                                    .appMono(11, color: Theme.amber)
                            }
                            Spacer()
                            Text("\(Int(result.executionTime * 1000)) ms")
                                .appMono(11, color: Theme.ink3)
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 6)
                        .frame(height: 30)
                        .background(Theme.bg2)
                    }
                }
            } else if !queryVM.isExecuting {
                VStack(spacing: 14) {
                    Text("v. — empty")
                        .appSectionLabel()
                    Text("A fresh query.")
                        .appDisplay(32)
                    Text("Type SQL above, or pick a table from the navigator.\nCmd+Enter runs the statement under the caret.")
                        .appBody()
                        .foregroundStyle(Theme.ink3)
                        .multilineTextAlignment(.center)
                    HStack(spacing: 10) {
                        AppKbd(key: "⌘")
                        AppKbd(key: "↵")
                        Text("execute")
                            .appMono(11, color: Theme.ink3)
                            .padding(.leading, 2)
                        Text("·").appMono(11, color: Theme.ink4)
                        AppKbd(key: "⌘")
                        AppKbd(key: "⇧")
                        AppKbd(key: "F")
                        Text("beautify")
                            .appMono(11, color: Theme.ink3)
                            .padding(.leading, 2)
                    }
                    .padding(.top, 6)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Theme.bg)
            }
        }
        .background(Theme.bg)
    }

    /// Right-side meta strip for the results header — context shifts with the
    /// active tab: row/exec stats for the data grid, plan totals for EXPLAIN,
    /// or a quiet "no plan yet" hint when nothing has been computed.
    @ViewBuilder
    private var resultsMetaRow: some View {
        HStack(spacing: 12) {
            if queryVM.activeResultsTab == .explain {
                if let plan = queryVM.plan {
                    let label = plan.didAnalyze ? "analyzed" : "explained"
                    HStack(spacing: 5) {
                        Text("●").foregroundStyle(Theme.accent).font(.system(size: 8))
                        Text(label).appMono(11, color: Theme.ink3)
                    }
                    if let exec = plan.executionTime {
                        Text("\(Int(exec)) ms execution").appMono(11, color: Theme.ink3)
                    } else {
                        Text("plan only").appMono(11, color: Theme.ink3)
                    }
                }
            } else if let result = queryVM.sortedResult, !result.columns.isEmpty {
                HStack(spacing: 5) {
                    Text("●").foregroundStyle(Theme.accent).font(.system(size: 8))
                    Text("success").appMono(11, color: Theme.ink3)
                }
                Text("\(result.rowCount) row\(result.rowCount == 1 ? "" : "s")")
                    .appMono(11, color: Theme.ink3)
                Text("\(Int(result.executionTime * 1000)) ms")
                    .appMono(11, color: Theme.ink3)
            }
        }
    }

    private func errorBanner(_ message: String) -> some View {
        @Bindable var queryVM = queryVM
        return HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(Theme.rose)
            Text(message)
                .font(Theme.mono(size: 11.5))
                .foregroundStyle(Theme.rose)
                .lineLimit(2)
            Spacer()
            Button("Dismiss") {
                queryVM.errorMessage = nil
            }
            .buttonStyle(.plain)
            .foregroundStyle(Theme.ink3)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(Theme.rose.opacity(0.08))
        .overlay(alignment: .bottom) {
            Rectangle().fill(Theme.line).frame(height: 1)
        }
    }
}

/// Underlined tab strip used at the top of the Query results panel. Mirrors
/// the `.results-head .tabs .t` pattern from the web design — active tab gets
/// a 2px lime underline. Tapping a tab fires the supplied closure.
private struct ResultsTab: View {
    let label: String
    let isActive: Bool
    var onTap: () -> Void = {}

    var body: some View {
        Button(action: onTap) {
            Text(label)
                .font(Theme.mono(size: 11.5, weight: isActive ? .medium : .regular))
                .foregroundStyle(isActive ? Theme.ink : Theme.ink3)
                .padding(.vertical, 4)
                .overlay(alignment: .bottom) {
                    if isActive {
                        Rectangle()
                            .fill(Theme.accent)
                            .frame(height: 2)
                            .offset(y: 10)
                    }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// Editorial toolbar button used in the Query tab's action row. Renders as
/// either a pill-outline secondary button or — with `isPrimary` — a solid lime
/// chip for the dominant "Run" affordance.
private struct QueryActionButton: View {
    let title: String
    let systemImage: String
    var isPrimary: Bool = false
    var disabled: Bool = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: systemImage)
                    .font(.system(size: 10, weight: isPrimary ? .bold : .regular))
                Text(title)
                    .font(Theme.mono(size: 11.5, weight: isPrimary ? .semibold : .regular))
                    .lineLimit(1)
            }
            .fixedSize(horizontal: true, vertical: false)
            .foregroundStyle(isPrimary ? Theme.onAccent : Theme.ink2)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(
                Group {
                    if isPrimary {
                        Theme.accent
                    } else {
                        Color.clear
                    }
                }
            )
            .overlay(
                RoundedRectangle(cornerRadius: 5)
                    .strokeBorder(isPrimary ? Theme.accent : Theme.line2, lineWidth: 1)
            )
            .clipShape(.rect(cornerRadius: 5))
            .opacity(disabled ? 0.45 : 1)
        }
        .buttonStyle(.plain)
        .disabled(disabled)
    }
}

/// Per-column metadata derived once when a `ResultsGridView` is constructed.
/// Caching here means `cellView` doesn't redo the `String.lowercased()` /
/// type-class lookups for every visible row × column on every reload.
private struct GridColumnMeta {
    let id: Int
    let name: String
    let info: ColumnInfo?
    let headerTitle: String
    let editorKind: FieldEditorKindResolved
    let foreignKey: ConstraintInfo?
}

/// `FieldEditorKind` derives from a cell's value (specifically the long-text
/// branch which inspects character count). For pre-computed column metadata
/// we resolve everything *except* the value-dependent fallback; cells then
/// pick the final kind by checking their own length on the long-text edge.
private enum FieldEditorKindResolved {
    case json
    case array
    case boolean
    /// Plain text: may degrade to `.longText` per cell on the cell's own
    /// length / multi-line content. Carried here so cells don't need to
    /// re-call `dataType.lowercased()` to figure it out.
    case plainOrLong

    func resolved(forValue value: String) -> FieldEditorKind {
        switch self {
        case .json: return .json
        case .array: return .array
        case .boolean: return .boolean
        case .plainOrLong:
            return value.utf16.count > FieldEditorKind.longTextThreshold || value.contains("\n")
                ? .longText
                : .plain
        }
    }

    init(udtName: String?, dataType: String) {
        if let udt = udtName?.lowercased(), udt.hasPrefix("_") {
            self = .array
            return
        }
        let normalized = dataType.lowercased().trimmingCharacters(in: .whitespaces)
        if normalized == "json" || normalized == "jsonb" {
            self = .json
        } else if normalized == "boolean" || normalized == "bool" {
            self = .boolean
        } else if normalized.hasSuffix("[]") || normalized == "array" || normalized.hasPrefix("_") {
            self = .array
        } else {
            self = .plainOrLong
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
    /// Resolves a column name to the FK constraint it participates in, if any.
    /// Drives the inline arrow affordance, the "Jump to <table>" context-menu
    /// item, and Cmd-click navigation. Pass nil to disable FK navigation
    /// entirely (e.g., from the Query tab where FK metadata isn't loaded).
    var foreignKeyForColumn: ((String) -> ConstraintInfo?)?
    /// Invoked when the user activates FK navigation on a cell (via Cmd-click
    /// or the context-menu item). Receives the displayed row and column index.
    var onFKJump: ((Int, Int) -> Void)?
    @Binding var selectedRowIndex: Int?
    @FocusState private var isFocused: Bool
    @FocusState private var editFieldFocused: Bool
    @FocusState private var insertFieldFocused: Bool
    @State private var editingCell: (row: Int, col: Int)?
    @State private var editingText: String = ""
    @State private var originalEditText: String = ""
    @State private var fieldEditorCell: (row: Int, col: Int)?
    private let columnMinWidth: CGFloat = 100
    private let columnsByName: [String: ColumnInfo]
    /// Per-column derived metadata. Indexed by display column position (i.e.
    /// the same index passed to `cellView(rowIdx:colIdx:)`). Computed once at
    /// init so each cell render is a single subscript instead of repeated
    /// `dataType.lowercased()` / set lookups / FK-by-name dictionary walks.
    private let columnMeta: [GridColumnMeta]

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
        onInsertCancel: (() -> Void)? = nil,
        foreignKeyForColumn: ((String) -> ConstraintInfo?)? = nil,
        onFKJump: ((Int, Int) -> Void)? = nil
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
        self.foreignKeyForColumn = foreignKeyForColumn
        self.onFKJump = onFKJump
        let byName = Dictionary(columns.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
        self.columnsByName = byName
        self.columnMeta = result.columns.enumerated().map { (idx, name) in
            let info = byName[name]
            let headerTitle: String
            if let info {
                let short = ColumnInfo.shortTypeName(dataType: info.dataType, udtName: info.udtName)
                headerTitle = short.isEmpty ? name : "\(name)  ·  \(short)"
            } else {
                headerTitle = name
            }
            return GridColumnMeta(
                id: idx,
                name: name,
                info: info,
                headerTitle: headerTitle,
                editorKind: info.map { FieldEditorKindResolved(udtName: $0.udtName, dataType: $0.dataType) } ?? .plainOrLong,
                foreignKey: foreignKeyForColumn?(name)
            )
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            DataGridView(
                rowCount: result.rows.count,
                resultRevision: result.revision,
                columns: columnMeta.map { meta in
                    DataGridView.Column(
                        id: meta.id,
                        title: meta.headerTitle,
                        rawName: meta.name,
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
                    buildContextMenuItems(rowIdx: rowIdx)
                },
                renderCell: { rowIdx, colIdx in
                    AnyView(cellView(rowIdx: rowIdx, colIdx: colIdx))
                },
                onCmdClick: { rowIdx, colIdx in
                    handleCmdClick(row: rowIdx, col: colIdx)
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

    /// Cmd-click handler. Returns true only when the click landed on a non-null
    /// FK cell — for any other cell we let NSTableView's default Cmd-click
    /// multi-select behavior run.
    private func handleCmdClick(row: Int, col: Int) -> Bool {
        guard let onFKJump, foreignKeyForColumn != nil,
              row < result.rows.count, col < result.columns.count
        else { return false }
        let colName = result.columns[col]
        guard let _ = foreignKeyForColumn?(colName) else { return false }
        let cell = result.rows[row][col]
        guard !cell.isNull else { return false }
        onFKJump(row, col)
        return true
    }

    /// Builds the row's context menu, prepending a "Jump to <ref_table>" item
    /// when the right-clicked column is a non-null FK source.
    private func buildContextMenuItems(rowIdx: Int) -> [DataGridView.MenuItem] {
        var items: [DataGridView.MenuItem] = []
        if let onFKJump,
           rowIdx < result.rows.count
        {
            // The DataGridView coordinator passes a row index but not a column
            // — its menuNeedsUpdate uses tv.clickedRow only. So we walk the
            // row's cells and offer a Jump item for each FK column that has a
            // non-null value. That keeps the right-click surface comprehensive
            // even though NSTableView doesn't expose the clicked column to the
            // menu builder.
            for colIdx in 0 ..< min(result.columns.count, result.rows[rowIdx].count) {
                let colName = result.columns[colIdx]
                guard let fk = foreignKeyForColumn?(colName) else { continue }
                let cell = result.rows[rowIdx][colIdx]
                guard !cell.isNull, let refTable = fk.referencedTable else { continue }
                let captured = colIdx
                items.append(DataGridView.MenuItem(
                    title: "Jump to \(refTable) via \(colName)",
                    isDestructive: false
                ) { onFKJump(rowIdx, captured) })
            }
        }
        if let onDeleteRow {
            items.append(DataGridView.MenuItem(title: "Delete Row", isDestructive: true) {
                onDeleteRow(rowIdx)
            })
        }
        return items
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
        guard colIdx < columnMeta.count else { return .plain }
        let value = cell.isNull ? "" : cell.displayString
        return columnMeta[colIdx].editorKind.resolved(forValue: value)
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
        if rowIdx < result.rows.count, colIdx < result.rows[rowIdx].count, colIdx < columnMeta.count {
            let cell = result.rows[rowIdx][colIdx]
            let meta = columnMeta[colIdx]
            let kind = meta.editorKind.resolved(forValue: cell.isNull ? "" : cell.displayString)
            let renderKind = CellRenderKind.from(column: meta.info, cell: cell)
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
                let fkInfo = meta.foreignKey
                HStack(spacing: 4) {
                    if renderKind.alignment == .trailing { Spacer(minLength: 0) }
                    CellTypeBadge(kind: kind)
                    cellContentView(cell: cell, renderKind: renderKind)
                    if renderKind.alignment == .leading { Spacer(minLength: 0) }
                    // FK affordance. HostingCellView returns nil from hitTest
                    // (so first-click selection works) which means SwiftUI
                    // gestures can't fire here — the icon is a visual
                    // affordance only. Activation routes through Cmd-click on
                    // the cell or the right-click "Jump to <table>" menu item.
                    if let fkInfo, !cell.isNull, fkInfo.referencedTable != nil {
                        Image(systemName: "arrow.up.right.square")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .help("Foreign key → \(fkInfo.referencedTable ?? ""). Cmd-click or right-click to follow.")
                    }
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
    /// Kept for callers that look up by index; cell rendering reads `columnMeta`
    /// directly so it doesn't pay the dictionary-lookup cost per cell.
    private func columnInfo(for colIdx: Int) -> ColumnInfo? {
        guard colIdx < columnMeta.count else { return nil }
        return columnMeta[colIdx].info
    }

    /// Renders the cell's text using a typography appropriate to its category:
    /// muted italic for NULL, monospaced for IDs / numbers / dates / network /
    /// JSON, sans-serif for plain text, and a small dot indicator for booleans.
    @ViewBuilder
    private func cellContentView(cell: CellValue, renderKind: CellRenderKind) -> some View {
        switch renderKind {
        case .null:
            // ‹NULL› with angle brackets distinguishes the meta-value from a
            // literal text cell whose contents happen to be "NULL". No italic
            // — the dim color carries the affordance.
            Text("‹NULL›")
                .font(.system(.body, design: .monospaced))
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
                .foregroundStyle(.tertiary)
        case .text:
            Text(cell.displayString)
                .font(.system(.body, design: .monospaced))
                .lineLimit(1)
        }
    }

    @ViewBuilder
    private func fieldEditorPopover(rowIdx: Int, colIdx: Int, cell: CellValue) -> some View {
        let meta = colIdx < columnMeta.count ? columnMeta[colIdx] : nil
        let colName = meta?.name ?? "Column"
        let info = meta?.info
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
    /// Stable identity of the underlying result. Bumped whenever rows change
    /// (new query, inline cell edit, etc.). The Coordinator uses this to skip
    /// the expensive `reloadData()` pass when only selection or unrelated
    /// SwiftUI inputs changed.
    let resultRevision: UUID
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
    /// Cmd-click handler. Returns true to consume the event (suppressing the
    /// default multi-select toggle), false to fall through to normal handling.
    /// Callers use this for context-sensitive actions like "jump to FK target":
    /// they return true only when the clicked cell actually has an action.
    var onCmdClick: ((Int, Int) -> Bool)? = nil

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

        let coordinator = context.coordinator
        tableView.onCmdClick = { [weak coordinator] row, col in
            coordinator?.parent.onCmdClick?(row, col) ?? false
        }
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let tableView = scrollView.documentView as? FocusableTableView else { return }
        let coordinator = context.coordinator
        coordinator.parent = self

        // Rebuild columns only if the column set actually changed — column
        // identity is the column index in the result.
        let currentIDs = tableView.tableColumns.compactMap { Int($0.identifier.rawValue) }
        let desiredIDs = columns.map(\.id)
        let columnsChanged = currentIDs != desiredIDs ||
            zip(tableView.tableColumns, columns).contains { $0.0.title != $0.1.title }

        if columnsChanged {
            for c in tableView.tableColumns { tableView.removeTableColumn(c) }
            for col in columns { tableView.addTableColumn(makeColumn(for: col)) }
        }

        // SwiftUI calls updateNSView whenever any observed property the parent
        // reads changes — selection, loading flags, filter SQL, etc. Reloading
        // every cell on every one of those was the dominant cost of the grid.
        // Skip reloadData when neither the columns nor the underlying result
        // revision changed; selection/sort sync below still runs.
        let dataChanged = columnsChanged
            || coordinator.lastReloadRowCount != rowCount
            || coordinator.lastReloadResultRevision != resultRevision
            || coordinator.lastReloadSortKey != (sortColumnName ?? "")
            || coordinator.lastReloadSortAscending != sortAscending
        if dataChanged {
            tableView.reloadData()
            coordinator.lastReloadRowCount = rowCount
            coordinator.lastReloadResultRevision = resultRevision
            coordinator.lastReloadSortKey = sortColumnName ?? ""
            coordinator.lastReloadSortAscending = sortAscending
        }

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

        // Sort indicator on the header. Cheap to refresh unconditionally — it
        // touches a handful of NSTableColumn objects, not the row body.
        if columnsChanged || dataChanged {
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

        // Last-reload signature. updateNSView compares against the new values
        // and only invokes `reloadData()` when the *data* actually changed —
        // selection/binding-only edits skip the expensive cell rebuild.
        var lastReloadRowCount: Int = -1
        var lastReloadResultRevision: UUID = UUID(uuidString: "00000000-0000-0000-0000-000000000000")!
        var lastReloadSortKey: String = ""
        var lastReloadSortAscending: Bool = true

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

        // Catch the click at the cell level — if we let it fall through to
        // the inner NSHostingView, SwiftUI's gesture machinery absorbs the
        // mouseDown without doing anything useful (we have no gestures on
        // the cell content), and the table never gets a chance to select.
        override func hitTest(_ point: NSPoint) -> NSView? {
            frame.contains(point) ? self : nil
        }

        // Required so the first click on the table — even when the table
        // isn't yet first responder — registers as a real selection click
        // rather than getting consumed by window activation.
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        // Forward the mouseDown up to the host NSTableView so its built-in
        // selection logic runs. Walking via superview chain (rather than
        // nextResponder) is more reliable here because NSTableRowView's
        // default mouseDown silently consumes the event.
        override func mouseDown(with event: NSEvent) {
            var view: NSView? = superview
            while let v = view {
                if let table = v as? NSTableView {
                    table.mouseDown(with: event)
                    return
                }
                view = v.superview
            }
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

        /// Optional Cmd-click sink. Returns true to consume the click; false
        /// (or nil) lets NSTableView run its default Cmd-click multi-select.
        var onCmdClick: ((Int, Int) -> Bool)?

        override func mouseDown(with event: NSEvent) {
            if event.modifierFlags.contains(.command), let onCmdClick {
                let point = convert(event.locationInWindow, from: nil)
                let r = row(at: point)
                let c = column(at: point)
                if r >= 0, c >= 0, c < tableColumns.count,
                   let colId = Int(tableColumns[c].identifier.rawValue),
                   onCmdClick(r, colId)
                {
                    return
                }
            }
            super.mouseDown(with: event)
        }

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

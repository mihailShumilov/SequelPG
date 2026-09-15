import SwiftUI

/// Rows of the selected table or view: optional filter bar, the data grid,
/// and a bottom bar with insert/delete, filter toggle, page size, paging,
/// export, and the approximate row count.
struct ContentTabView: View {
    @Environment(AppViewModel.self) var appVM
    @Environment(TableViewModel.self) var tableVM
    @Environment(NavigatorViewModel.self) var navigatorVM

    @State private var showSQLPreview = false

    var body: some View {
        @Bindable var tableVM = tableVM
        VStack(spacing: 0) {
            // Filter bar (toggle with ⌘F)
            if tableVM.showFilterBar, navigatorVM.selectedObject?.type.hasQueryableContent == true {
                filterBar
                Divider()
            }

            ZStack {
                if let result = tableVM.contentResult {
                    ResultsGridView(
                        result: result,
                        columns: tableVM.columns,
                        isEditable: tableVM.hasPrimaryKey,
                        onRowSelected: { rowIdx in
                            appVM.selectRow(index: rowIdx, columns: result.columns, values: result.rows[rowIdx])
                        },
                        onCellEdited: { row, col, text in
                            Task { await appVM.updateContentCell(rowIndex: row, columnIndex: col, newText: text) }
                        },
                        sortColumn: tableVM.sortColumn,
                        sortAscending: tableVM.sortAscending,
                        onColumnHeaderTapped: { column in
                            appVM.toggleContentSort(column: column)
                        },
                        onDeleteRow: appVM.canDeleteContentRow ? { rowIdx in
                            tableVM.deleteConfirmationRowIndex = rowIdx
                        } : nil,
                        selectedRowIndex: $tableVM.selectedRowIndex,
                        foreignKeyForColumn: { columnName in
                            tableVM.foreignKey(forColumn: columnName)
                        },
                        onFKJump: { rowIdx, colIdx in
                            guard rowIdx < result.rows.count, colIdx < result.columns.count else { return }
                            let colName = result.columns[colIdx]
                            guard let fk = tableVM.foreignKey(forColumn: colName) else { return }
                            Task { await appVM.navigateForeignKey(fromRow: result.rows[rowIdx], fk: fk) }
                        }
                    )
                } else if let obj = navigatorVM.selectedObject, !obj.type.hasQueryableContent {
                    ContentUnavailableView {
                        Label(obj.name, systemImage: obj.type.symbolName)
                    } description: {
                        Text("A \(obj.type.displayName.lowercased()) has no rows to browse. Open the Definition tab to see its source.")
                    } actions: {
                        Button("Show Definition") { appVM.selectedTab = .definition }
                    }
                } else if navigatorVM.selectedObject == nil {
                    ContentUnavailableView {
                        Label("No Table Selected", systemImage: "tablecells")
                    } description: {
                        Text("Choose a table or view in the sidebar to browse its rows.")
                    }
                }

                // Full-screen spinner only appears on the initial load. Once a
                // result has been rendered, subsequent reloads keep the grid
                // mounted so it doesn't blink in/out — feedback comes from the
                // small inline spinner in the bottom bar instead.
                if tableVM.isLoadingContent, tableVM.contentResult == nil {
                    ProgressView("Loading rows…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(Theme.bg)
                }
            }

            if navigatorVM.selectedObject?.type.hasQueryableContent == true {
                bottomBar
            }
        }
        .background(Theme.bg)
        .task {
            if let obj = navigatorVM.selectedObject,
               obj.type.hasQueryableContent,
               tableVM.contentResult == nil
            {
                await appVM.loadContentPage()
            }
        }
        .onChange(of: navigatorVM.selectedObject) { _, _ in
            // Only auto-load when there's no cached content for the (now) active
            // tab. Switching between tabs restores their cached contentResult via
            // AppViewModel.activateTab, so re-fetching here would silently reload
            // every tab swap and discard pagination/sort state.
            if let obj = navigatorVM.selectedObject,
               obj.type.hasQueryableContent,
               appVM.selectedTab == .content,
               tableVM.contentResult == nil
            {
                appVM.reloadContentPage()
            }
        }
        .sheet(isPresented: Binding(
            get: { tableVM.isInsertingRow },
            set: { if !$0 { appVM.cancelInsertRow() } }
        )) {
            InsertRowSheet()
                .environment(appVM)
                .environment(tableVM)
        }
        .alert(
            "Delete Row?",
            isPresented: Binding<Bool>(
                get: { tableVM.deleteConfirmationRowIndex != nil },
                set: { if !$0 { tableVM.deleteConfirmationRowIndex = nil } }
            )
        ) {
            Button("Cancel", role: .cancel) {
                tableVM.deleteConfirmationRowIndex = nil
            }
            Button("Delete", role: .destructive) {
                if let idx = tableVM.deleteConfirmationRowIndex {
                    tableVM.deleteConfirmationRowIndex = nil
                    Task { await appVM.deleteContentRow(rowIndex: idx) }
                }
            }
        } message: {
            Text("This row will be permanently deleted from the database.")
        }
        .alert(
            "Foreign Key Conflict",
            isPresented: Binding<Bool>(
                get: { appVM.cascadeDeleteContext?.source == .content },
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
            Text(appVM.cascadeDeleteContext?.errorMessage
                ?? "This row is referenced by other tables. Delete all referencing rows too?")
        }
        .popover(isPresented: $showSQLPreview) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Filter SQL")
                    .font(.headline)
                Text(appVM.previewFilterSQL())
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
            }
            .padding()
            .frame(minWidth: 320)
        }
    }

    // MARK: - Filter Bar

    private var filterBar: some View {
        @Bindable var tableVM = tableVM
        // Materialize the column-name list once per filter-bar render rather
        // than rebuilding it inside every filter row's Picker.
        let columnNames = tableVM.columns.map(\.name)
        let hasUsableFilter = tableVM.filters.contains {
            $0.op == .isNull || $0.op == .isNotNull || !$0.value.trimmingCharacters(in: .whitespaces).isEmpty
        }
        return VStack(spacing: 6) {
            ForEach($tableVM.filters) { $filter in
                filterRow(filter: $filter, columnNames: columnNames)
            }

            HStack(spacing: 8) {
                Button("Clear") {
                    appVM.clearContentFilters()
                }
                .disabled(tableVM.activeFilterSQL == nil && !hasUsableFilter)

                Button("Show SQL") {
                    showSQLPreview.toggle()
                }
                .disabled(!hasUsableFilter)

                Spacer()

                if tableVM.activeFilterSQL != nil {
                    Label("Filter applied", systemImage: "line.3.horizontal.decrease.circle.fill")
                        .foregroundStyle(Color.accentColor)
                        .font(.caption)
                }

                Button("Apply") {
                    appVM.applyContentFilters()
                }
                .keyboardShortcut(.return, modifiers: .command)
                .buttonStyle(.borderedProminent)
                .disabled(!hasUsableFilter && tableVM.activeFilterSQL == nil)
            }
        }
        .controlSize(.small)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(.bar)
    }

    private func filterRow(filter: Binding<ContentFilter>, columnNames: [String]) -> some View {
        HStack(spacing: 6) {
            Picker("Column", selection: filter.column) {
                Text("Any Column").tag("")
                ForEach(columnNames, id: \.self) { name in
                    Text(name).tag(name)
                }
            }
            .labelsHidden()
            .frame(width: 150)

            Picker("Operator", selection: filter.op) {
                ForEach(FilterOperator.allCases, id: \.self) { op in
                    Text(op.rawValue).tag(op)
                }
            }
            .labelsHidden()
            .frame(width: 130)

            // Value field (hidden for is null / is not null)
            if filter.wrappedValue.op.needsValue {
                TextField("Value", text: filter.value)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit {
                        appVM.applyContentFilters()
                    }
            } else {
                Spacer()
            }

            Button {
                tableVM.filters.append(ContentFilter())
            } label: {
                Image(systemName: "plus")
            }
            .buttonStyle(.borderless)
            .help("Add a condition")
            .accessibilityLabel("Add filter")

            Button {
                tableVM.filters.removeAll { $0.id == filter.id }
            } label: {
                Image(systemName: "minus")
            }
            .buttonStyle(.borderless)
            .disabled(tableVM.filters.count <= 1)
            .help("Remove this condition")
            .accessibilityLabel("Remove filter")
        }
    }

    // MARK: - Bottom Bar

    private var bottomBar: some View {
        @Bindable var tableVM = tableVM
        let filterActive = tableVM.activeFilterSQL != nil
        return BottomBar {
            Button {
                appVM.startInsertRow()
            } label: {
                Image(systemName: "plus")
            }
            .disabled(!appVM.canInsertContentRow || tableVM.isInsertingRow)
            .help(appVM.canInsertContentRow ? "Insert a new row" : "Rows can only be inserted into tables")
            .accessibilityLabel("Insert row")

            Button {
                if let idx = tableVM.selectedRowIndex {
                    tableVM.deleteConfirmationRowIndex = idx
                }
            } label: {
                Image(systemName: "minus")
            }
            .disabled(tableVM.selectedRowIndex == nil || !appVM.canDeleteContentRow || tableVM.isInsertingRow)
            .help(appVM.canDeleteContentRow
                ? "Delete the selected row"
                : "Rows can only be deleted from tables with a primary key")
            .accessibilityLabel("Delete row")

            Divider().frame(height: 14)

            Button {
                tableVM.showFilterBar.toggle()
            } label: {
                Image(systemName: filterActive
                    ? "line.3.horizontal.decrease.circle.fill"
                    : "line.3.horizontal.decrease.circle")
                    .foregroundStyle(filterActive ? Color.accentColor : Color.primary)
            }
            .help("Filter rows (⌘F)")
            .accessibilityLabel("Toggle filter bar")

            Picker("Rows per page", selection: $tableVM.pageSize) {
                ForEach(tableVM.pageSizeOptions, id: \.self) { size in
                    Text("\(size) rows").tag(size)
                }
            }
            .labelsHidden()
            .fixedSize()
            .disabled(tableVM.isInsertingRow)
            .onChange(of: tableVM.pageSize) { _, _ in
                tableVM.currentPage = 0
                appVM.clearSelectedRow()
                appVM.reloadContentPage()
            }

            Spacer()

            Button {
                tableVM.currentPage = max(0, tableVM.currentPage - 1)
                appVM.clearSelectedRow()
                appVM.reloadContentPage()
            } label: {
                Image(systemName: "chevron.left")
            }
            .disabled(tableVM.currentPage <= 0 || tableVM.isInsertingRow)
            .help("Previous page")
            .accessibilityLabel("Previous page")

            PageJumpField(
                page: tableVM.currentPage + 1,
                total: tableVM.totalPages,
                onCommit: { newPage in
                    let clamped = max(1, min(tableVM.totalPages, newPage))
                    tableVM.currentPage = clamped - 1
                    appVM.clearSelectedRow()
                    appVM.reloadContentPage()
                }
            )
            .disabled(tableVM.totalPages <= 1 || tableVM.isInsertingRow)

            Button {
                tableVM.currentPage = min(tableVM.totalPages - 1, tableVM.currentPage + 1)
                appVM.clearSelectedRow()
                appVM.reloadContentPage()
            } label: {
                Image(systemName: "chevron.right")
            }
            .disabled(tableVM.currentPage >= tableVM.totalPages - 1 || tableVM.isInsertingRow)
            .help("Next page")
            .accessibilityLabel("Next page")

            Spacer()

            // Inline reload indicator — shown when a reload is in flight while
            // an existing result is still on screen.
            if tableVM.isLoadingContent, tableVM.contentResult != nil {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel("Reloading rows")
            }

            ResultExportButton(
                result: tableVM.contentResult,
                defaultFileName: tableVM.selectedObjectName ?? "table"
            )

            Text("≈ \(tableVM.approximateRowCount.formatted()) rows")
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .accessibilityLabel("Approximately \(tableVM.approximateRowCount) rows")
        }
        .buttonStyle(.borderless)
    }
}

/// Editable page number that commits on Enter or blur.
private struct PageJumpField: View {
    let page: Int
    let total: Int
    let onCommit: (Int) -> Void

    @State private var text: String = ""
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 4) {
            TextField("", text: $text)
                .textFieldStyle(.roundedBorder)
                .multilineTextAlignment(.center)
                .monospacedDigit()
                .frame(width: 48)
                .focused($focused)
                .accessibilityLabel("Page number. Currently \(page) of \(total). Enter a number and press return to jump.")
                .onChange(of: page, initial: true) { _, newValue in
                    if !focused { text = String(newValue) }
                }
                .onChange(of: focused) { _, isFocused in
                    if !isFocused { text = String(page) }
                }
                .onSubmit {
                    if let n = Int(text.trimmingCharacters(in: .whitespaces)) {
                        onCommit(n)
                    } else {
                        text = String(page)
                    }
                }
            Text("of \(total)")
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
    }
}

/// Form for inserting a new row: one field per column with the type, NULL-
/// ability, and default shown as hints. Empty fields are omitted from the
/// INSERT so the database applies its default (or NULL); typing `NULL`
/// sends an explicit null.
struct InsertRowSheet: View {
    @Environment(AppViewModel.self) private var appVM
    @Environment(TableViewModel.self) private var tableVM

    private var requiredMissing: [String] {
        tableVM.columns
            .filter { !$0.isNullable && $0.columnDefault == nil && !$0.isIdentity }
            .filter { (tableVM.newRowValues[$0.name] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .map(\.name)
    }

    var body: some View {
        @Bindable var tableVM = tableVM
        VStack(spacing: 0) {
            HStack {
                Text("Insert Row into \u{201C}\(tableVM.selectedObjectName ?? "table")\u{201D}")
                    .font(.headline)
                Spacer()
            }
            .padding(.horizontal, 20)
            .padding(.top, 18)
            .padding(.bottom, 6)

            Form {
                Section {
                    ForEach(tableVM.columns) { column in
                        LabeledContent {
                            TextField(
                                column.name,
                                text: Binding(
                                    get: { tableVM.newRowValues[column.name] ?? "" },
                                    set: { tableVM.newRowValues[column.name] = $0 }
                                ),
                                prompt: Text(placeholder(for: column))
                            )
                            .labelsHidden()
                            .font(.system(.body, design: .monospaced))
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                HStack(spacing: 4) {
                                    Text(column.name)
                                        .font(.system(.body, design: .monospaced))
                                    if column.isPrimaryKey {
                                        Image(systemName: "key.fill")
                                            .font(.caption2)
                                            .foregroundStyle(Theme.amber)
                                    }
                                }
                                Text(hint(for: column))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                } footer: {
                    Text("Leave a field empty to use the column default (or NULL). Type NULL for an explicit null.")
                }
            }
            .formStyle(.grouped)

            Divider()

            SheetButtonBar(
                confirmTitle: "Insert",
                confirmDisabled: !requiredMissing.isEmpty,
                onCancel: { appVM.cancelInsertRow() },
                onConfirm: { Task { await appVM.commitInsertRow() } }
            ) {
                if !requiredMissing.isEmpty {
                    Label("Required: \(requiredMissing.joined(separator: ", "))", systemImage: "exclamationmark.circle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
        }
        .frame(width: 560)
        .frame(minHeight: 320, idealHeight: min(200 + CGFloat(tableVM.columns.count) * 52, 720), maxHeight: 760)
    }

    private func placeholder(for column: ColumnInfo) -> String {
        if column.isIdentity { return "generated" }
        if let def = column.columnDefault, !def.isEmpty { return "default: \(def)" }
        return column.isNullable ? "NULL" : "required"
    }

    private func hint(for column: ColumnInfo) -> String {
        var parts = [ColumnInfo.shortTypeName(dataType: column.dataType, udtName: column.udtName)]
        if !column.isNullable { parts.append("not null") }
        return parts.joined(separator: " · ")
    }
}

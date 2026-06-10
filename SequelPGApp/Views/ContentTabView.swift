import SwiftUI

struct ContentTabView: View {
    @Environment(AppViewModel.self) var appVM
    @Environment(TableViewModel.self) var tableVM
    @Environment(NavigatorViewModel.self) var navigatorVM

    @State private var showSQLPreview = false

    /// Cached background — keeps the spinner backdrop / filter bar on the
    /// theme's secondary panel tone instead of the system control color.
    private static let chromeBackground = Theme.bg2

    var body: some View {
        @Bindable var tableVM = tableVM
        VStack(spacing: 0) {
            // Filter bar (toggle with Cmd+F)
            if tableVM.showFilterBar {
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
                        isInsertingRow: tableVM.isInsertingRow,
                        insertRowValues: Binding(
                            get: { tableVM.newRowValues },
                            set: { tableVM.newRowValues = $0 }
                        ),
                        onInsertCommit: {
                            Task { await appVM.commitInsertRow() }
                        },
                        onInsertCancel: {
                            appVM.cancelInsertRow()
                        },
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
                    VStack(spacing: 12) {
                        Text(obj.name)
                            .appDisplay(32)
                        Text("Has no rows to browse — open the Definition tab for this \(obj.type.rawValue).")
                            .appBody()
                            .foregroundStyle(Theme.ink3)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Theme.bg)
                } else if navigatorVM.selectedObject == nil {
                    VStack(spacing: 14) {
                        Text("v. — content")
                            .appSectionLabel()
                        Text("Pick a table.")
                            .appDisplay(32)
                        Text("Choose any table from the navigator to start browsing rows.")
                            .appBody()
                            .foregroundStyle(Theme.ink3)
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: 320)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Theme.bg)
                }

                // Full-screen spinner only appears on the initial load. Once a
                // result has been rendered, subsequent reloads keep the grid
                // mounted so it doesn't blink in/out — feedback comes from the
                // small inline spinner in the pagination bar instead.
                if tableVM.isLoadingContent, tableVM.contentResult == nil {
                    ProgressView("Loading...")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(Self.chromeBackground)
                }
            }

            Divider()
            paginationBar
        }
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
        .onReceive(NotificationCenter.default.publisher(for: .toggleFilterBar)) { _ in
            tableVM.showFilterBar.toggle()
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
            Text(appVM.cascadeDeleteContext?.errorMessage ?? "This row is referenced by other tables. Delete all referencing rows too?")
        }
        .popover(isPresented: $showSQLPreview) {
            VStack(alignment: .leading) {
                Text("Filter SQL")
                    .font(.headline)
                Text(appVM.previewFilterSQL())
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(.top, 4)
            }
            .padding()
            .frame(minWidth: 300)
        }
    }

    // MARK: - Filter Bar

    private var filterBar: some View {
        @Bindable var tableVM = tableVM
        // Materialize the column-name list once per filter-bar render rather
        // than rebuilding it inside every filter row's Picker. For a 100-col
        // table with 3 filters that was 300 Picker items rebuilt per redraw.
        let columnNames = tableVM.columns.map(\.name)
        return VStack(spacing: 6) {
            ForEach($tableVM.filters) { $filter in
                filterRow(filter: $filter, columnNames: columnNames)
            }

            HStack(spacing: 8) {
                Button("Clear Filter") {
                    appVM.clearContentFilters()
                }
                .disabled(tableVM.activeFilterSQL == nil && tableVM.filters.allSatisfy { $0.value.isEmpty && $0.op != .isNull && $0.op != .isNotNull })

                Button("SQL Preview") {
                    showSQLPreview.toggle()
                }

                Spacer()

                if tableVM.activeFilterSQL != nil {
                    Text("Filter active")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }

                Button("Apply Filter") {
                    appVM.applyContentFilters()
                }
                .keyboardShortcut(.return, modifiers: .command)
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Self.chromeBackground)
    }

    private func filterRow(filter: Binding<ContentFilter>, columnNames: [String]) -> some View {
        HStack(spacing: 6) {
            // Column picker — column names are passed in from `filterBar` so
            // they're materialized once per redraw rather than per filter row.
            Picker("", selection: filter.column) {
                Text("Any Column").tag("")
                ForEach(columnNames, id: \.self) { name in
                    Text(name).tag(name)
                }
            }
            .frame(width: 140)

            // Operator picker
            Picker("", selection: filter.op) {
                ForEach(FilterOperator.allCases, id: \.self) { op in
                    Text(op.rawValue).tag(op)
                }
            }
            .frame(width: 130)

            // Value field (hidden for is null / is not null)
            if filter.wrappedValue.op.needsValue {
                TextField("Value...", text: filter.value)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit {
                        appVM.applyContentFilters()
                    }
            }

            // Add/remove buttons
            Button {
                tableVM.filters.append(ContentFilter())
            } label: {
                Image(systemName: "plus")
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Add filter")

            if tableVM.filters.count > 1 {
                Button {
                    tableVM.filters.removeAll { $0.id == filter.id }
                } label: {
                    Image(systemName: "minus")
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Remove filter")
            }
        }
    }

    // MARK: - Pagination Bar

    private var paginationBar: some View {
        @Bindable var tableVM = tableVM
        return HStack {
            Button {
                appVM.startInsertRow()
            } label: {
                Image(systemName: "plus")
                    .frame(width: 16, height: 16)
            }
            .accessibilityLabel("Insert row")
            .disabled(!appVM.canInsertContentRow || tableVM.isInsertingRow)
            .help("Insert a new row")

            Button {
                if let idx = tableVM.selectedRowIndex {
                    tableVM.deleteConfirmationRowIndex = idx
                }
            } label: {
                Image(systemName: "minus")
                    .frame(width: 16, height: 16)
            }
            .accessibilityLabel("Delete row")
            .disabled(tableVM.selectedRowIndex == nil || !appVM.canDeleteContentRow || appVM.cascadeDeleteContext != nil || tableVM.isInsertingRow)
            .help("Delete the selected row")

            if tableVM.isInsertingRow {
                Divider()
                    .frame(height: 16)

                Button("Save") {
                    Task { await appVM.commitInsertRow() }
                }
                .keyboardShortcut(.return, modifiers: .command)

                Button("Cancel", role: .cancel) {
                    appVM.cancelInsertRow()
                }
                .keyboardShortcut(.escape, modifiers: [])
            }

            Divider()
                .frame(height: 16)

            // Filter toggle
            Button {
                tableVM.showFilterBar.toggle()
            } label: {
                Image(systemName: tableVM.activeFilterSQL != nil ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
                    .foregroundStyle(tableVM.activeFilterSQL != nil ? .orange : .primary)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Toggle filter bar")
            .help("Filter rows (Cmd+F)")

            Divider()
                .frame(height: 16)

            Picker("Rows:", selection: $tableVM.pageSize) {
                ForEach(tableVM.pageSizeOptions, id: \.self) { size in
                    Text("\(size)").tag(size)
                }
            }
            .frame(width: 130)
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
            .accessibilityLabel("Previous page")
            .disabled(tableVM.currentPage <= 0 || tableVM.isInsertingRow)

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
            .accessibilityLabel("Next page")
            .disabled(tableVM.currentPage >= tableVM.totalPages - 1 || tableVM.isInsertingRow)

            Spacer()

            // Inline reload indicator — shown when a reload is in flight while
            // an existing result is still on screen. Replaces the old behavior
            // of swapping the entire grid for a centered spinner.
            if tableVM.isLoadingContent, tableVM.contentResult != nil {
                ProgressView()
                    .controlSize(.small)
                    .padding(.trailing, 4)
                    .accessibilityLabel("Reloading rows")
            }

            Text("≈ \(tableVM.approximateRowCount) rows")
                .font(Theme.mono(size: 11))
                .foregroundStyle(Theme.ink3)
                .accessibilityLabel("Approximately \(tableVM.approximateRowCount) rows")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .frame(height: 32)
        .background(Theme.bg2)
        .overlay(alignment: .top) {
            Rectangle().fill(Theme.line).frame(height: 1)
        }
    }
}

/// Editable page number that commits on Enter or blur. The surrounding HStack
/// previously showed a read-only "Page N of M" label, forcing users to click
/// pagination arrows hundreds of times in large result sets.
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
                .frame(width: 52)
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

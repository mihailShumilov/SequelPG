import SwiftUI

struct ContentTabView: View {
    @Environment(AppViewModel.self) var appVM
    @Environment(TableViewModel.self) var tableVM
    @Environment(NavigatorViewModel.self) var navigatorVM

    var body: some View {
        @Bindable var tableVM = tableVM
        VStack(spacing: 0) {
            if tableVM.isLoadingContent {
                ProgressView("Loading...")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let result = tableVM.contentResult {
                ResultsGridView(
                    result: result,
                    columns: tableVM.columns,
                    isEditable: tableVM.columns.contains { $0.isPrimaryKey },
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
                    }
                )
            } else if navigatorVM.selectedObject != nil {
                ProgressView("Loading...")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Text("Select a table and switch to Content to browse rows.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            Divider()
            paginationBar
        }
        .onAppear {
            if navigatorVM.selectedObject != nil, tableVM.contentResult == nil {
                Task { await appVM.loadContentPage() }
            }
        }
        .onChange(of: navigatorVM.selectedObject) { _, _ in
            if navigatorVM.selectedObject != nil, appVM.selectedTab == .content {
                Task { await appVM.loadContentPage() }
            }
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
    }

    private var paginationBar: some View {
        @Bindable var tableVM = tableVM
        return HStack {
            Button {
                appVM.startInsertRow()
            } label: {
                Image(systemName: "plus")
                    .frame(width: 16, height: 16)
            }
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
                Task { await appVM.loadContentPage() }
            }

            Spacer()

            Button {
                tableVM.currentPage = max(0, tableVM.currentPage - 1)
                appVM.clearSelectedRow()
                Task { await appVM.loadContentPage() }
            } label: {
                Image(systemName: "chevron.left")
            }
            .disabled(tableVM.currentPage <= 0 || tableVM.isInsertingRow)

            Text("Page \(tableVM.currentPage + 1) of \(tableVM.totalPages)")
                .monospacedDigit()

            Button {
                tableVM.currentPage = min(tableVM.totalPages - 1, tableVM.currentPage + 1)
                appVM.clearSelectedRow()
                Task { await appVM.loadContentPage() }
            } label: {
                Image(systemName: "chevron.right")
            }
            .disabled(tableVM.currentPage >= tableVM.totalPages - 1 || tableVM.isInsertingRow)

            Spacer()

            Text("\u{2248} \(tableVM.approximateRowCount) rows")
                .foregroundStyle(.secondary)
                .font(.caption)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }
}

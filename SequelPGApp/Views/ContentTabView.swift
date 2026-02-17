import SwiftUI

struct ContentTabView: View {
    @EnvironmentObject var appVM: AppViewModel

    var body: some View {
        VStack(spacing: 0) {
            if appVM.tableVM.isLoadingContent {
                ProgressView("Loading...")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let result = appVM.tableVM.contentResult {
                ResultsGridView(
                    result: result,
                    columns: appVM.tableVM.columns,
                    isEditable: appVM.tableVM.columns.contains { $0.isPrimaryKey },
                    onRowSelected: { rowIdx in
                        appVM.selectRow(index: rowIdx, columns: result.columns, values: result.rows[rowIdx])
                    },
                    onCellEdited: { row, col, text in
                        Task { await appVM.updateContentCell(rowIndex: row, columnIndex: col, newText: text) }
                    },
                    sortColumn: appVM.tableVM.sortColumn,
                    sortAscending: appVM.tableVM.sortAscending,
                    onColumnHeaderTapped: { column in
                        appVM.toggleContentSort(column: column)
                    },
                    onDeleteRow: appVM.canDeleteContentRow ? { rowIdx in
                        appVM.tableVM.deleteConfirmationRowIndex = rowIdx
                    } : nil,
                    selectedRowIndex: $appVM.tableVM.selectedRowIndex,
                    isInsertingRow: appVM.tableVM.isInsertingRow,
                    insertRowValues: Binding(
                        get: { appVM.tableVM.newRowValues },
                        set: { appVM.tableVM.newRowValues = $0 }
                    ),
                    onInsertCommit: {
                        Task { await appVM.commitInsertRow() }
                    },
                    onInsertCancel: {
                        appVM.cancelInsertRow()
                    }
                )
            } else if appVM.navigatorVM.selectedObject != nil {
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
            if appVM.navigatorVM.selectedObject != nil, appVM.tableVM.contentResult == nil {
                Task { await appVM.loadContentPage() }
            }
        }
        .onChange(of: appVM.navigatorVM.selectedObject) { _ in
            if appVM.navigatorVM.selectedObject != nil, appVM.selectedTab == .content {
                Task { await appVM.loadContentPage() }
            }
        }
        .alert(
            "Delete Row?",
            isPresented: Binding<Bool>(
                get: { appVM.tableVM.deleteConfirmationRowIndex != nil },
                set: { if !$0 { appVM.tableVM.deleteConfirmationRowIndex = nil } }
            )
        ) {
            Button("Cancel", role: .cancel) {
                appVM.tableVM.deleteConfirmationRowIndex = nil
            }
            Button("Delete", role: .destructive) {
                if let idx = appVM.tableVM.deleteConfirmationRowIndex {
                    appVM.tableVM.deleteConfirmationRowIndex = nil
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
        HStack {
            Button {
                appVM.startInsertRow()
            } label: {
                Image(systemName: "plus")
                    .frame(width: 16, height: 16)
            }
            .disabled(!appVM.canInsertContentRow || appVM.tableVM.isInsertingRow)
            .help("Insert a new row")

            Button {
                if let idx = appVM.tableVM.selectedRowIndex {
                    appVM.tableVM.deleteConfirmationRowIndex = idx
                }
            } label: {
                Image(systemName: "minus")
                    .frame(width: 16, height: 16)
            }
            .disabled(appVM.tableVM.selectedRowIndex == nil || !appVM.canDeleteContentRow || appVM.cascadeDeleteContext != nil || appVM.tableVM.isInsertingRow)
            .help("Delete the selected row")

            if appVM.tableVM.isInsertingRow {
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

            Picker("Rows:", selection: $appVM.tableVM.pageSize) {
                ForEach(appVM.tableVM.pageSizeOptions, id: \.self) { size in
                    Text("\(size)").tag(size)
                }
            }
            .frame(width: 130)
            .disabled(appVM.tableVM.isInsertingRow)
            .onChange(of: appVM.tableVM.pageSize) { _ in
                appVM.tableVM.currentPage = 0
                appVM.clearSelectedRow()
                Task { await appVM.loadContentPage() }
            }

            Spacer()

            Button {
                appVM.tableVM.currentPage = max(0, appVM.tableVM.currentPage - 1)
                appVM.clearSelectedRow()
                Task { await appVM.loadContentPage() }
            } label: {
                Image(systemName: "chevron.left")
            }
            .disabled(appVM.tableVM.currentPage <= 0 || appVM.tableVM.isInsertingRow)

            Text("Page \(appVM.tableVM.currentPage + 1) of \(appVM.tableVM.totalPages)")
                .monospacedDigit()

            Button {
                appVM.tableVM.currentPage = min(appVM.tableVM.totalPages - 1, appVM.tableVM.currentPage + 1)
                appVM.clearSelectedRow()
                Task { await appVM.loadContentPage() }
            } label: {
                Image(systemName: "chevron.right")
            }
            .disabled(appVM.tableVM.currentPage >= appVM.tableVM.totalPages - 1 || appVM.tableVM.isInsertingRow)

            Spacer()

            Text("\u{2248} \(appVM.tableVM.approximateRowCount) rows")
                .foregroundStyle(.secondary)
                .font(.caption)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }
}

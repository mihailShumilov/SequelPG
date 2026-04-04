import SwiftUI

struct InspectorView: View {
    @Environment(AppViewModel.self) var appVM
    @Environment(TableViewModel.self) var tableVM
    @State private var editingColumn: String?
    @State private var editingText: String = ""
    @State private var showDeleteConfirmation = false
    @FocusState private var editFieldFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Inspector")
                .font(.headline)

            if let name = tableVM.selectedObjectName {
                LabeledContent("Object") {
                    Text(name)
                        .fontWeight(.medium)
                }

                LabeledContent("Approx. Rows") {
                    Text("\(tableVM.approximateRowCount)")
                        .monospacedDigit()
                }

                LabeledContent("Columns") {
                    Text("\(tableVM.selectedObjectColumnCount)")
                        .monospacedDigit()
                }
            } else {
                Text("No object selected")
                    .foregroundStyle(.secondary)
                    .font(.caption)
            }

            if let rowData = tableVM.selectedRowData,
               let rowIndex = tableVM.selectedRowIndex {
                Divider()

                HStack {
                    Text("Row Detail")
                        .font(.headline)
                    Text("#\(rowIndex + 1)")
                        .foregroundStyle(.secondary)
                        .font(.subheadline)
                    Spacer()
                    if inspectorCanDelete {
                        Button {
                            showDeleteConfirmation = true
                        } label: {
                            Image(systemName: "trash")
                                .foregroundStyle(.red)
                        }
                        .buttonStyle(.borderless)
                        .accessibilityLabel("Delete row")
                        .help("Delete this row")
                    }
                    Button {
                        appVM.clearSelectedRow()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("Dismiss row detail")
                }

                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(Array(rowData.enumerated()), id: \.element.column) { _, item in
                            let column = item.column
                            let value = item.value
                            VStack(alignment: .leading, spacing: 2) {
                                Text(column)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)

                                if editingColumn == column {
                                    TextField("", text: $editingText)
                                        .textFieldStyle(.roundedBorder)
                                        .font(.system(.body, design: .monospaced))
                                        .focused($editFieldFocused)
                                        .onSubmit {
                                            commitInspectorEdit(column: column)
                                        }
                                        .onExitCommand {
                                            cancelInspectorEdit()
                                        }
                                } else if appVM.isInspectorEditable {
                                    Text(value.displayString)
                                        .font(.system(.body, design: .monospaced))
                                        .foregroundStyle(value.isNull ? .secondary : .primary)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .contentShape(Rectangle())
                                        .onTapGesture(count: 2) {
                                            editingText = value.isNull ? "NULL" : value.displayString
                                            editingColumn = column
                                            editFieldFocused = true
                                        }
                                } else {
                                    Text(value.displayString)
                                        .font(.system(.body, design: .monospaced))
                                        .foregroundStyle(value.isNull ? .secondary : .primary)
                                        .textSelection(.enabled)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                }
                            }
                            if column != rowData.last?.column {
                                Divider()
                            }
                        }
                    }
                }
            }

            Spacer()
        }
        .padding()
        .alert("Delete Row?", isPresented: $showDeleteConfirmation) {
            Button("Cancel", role: .cancel) {}
            Button("Delete", role: .destructive) {
                Task { await appVM.deleteInspectorRow() }
            }
        } message: {
            Text("This row will be permanently deleted from the database.")
        }
    }

    private var inspectorCanDelete: Bool {
        if appVM.selectedTab == .content {
            return appVM.canDeleteContentRow
        } else if appVM.selectedTab == .query {
            return appVM.canDeleteQueryRow
        }
        return false
    }

    private func commitInspectorEdit(column: String) {
        let text = editingText
        editingColumn = nil
        editingText = ""
        Task { await appVM.updateInspectorCell(columnName: column, newText: text) }
    }

    private func cancelInspectorEdit() {
        editingColumn = nil
        editingText = ""
    }
}

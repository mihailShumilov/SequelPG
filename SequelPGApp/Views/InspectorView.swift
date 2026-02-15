import SwiftUI

struct InspectorView: View {
    @EnvironmentObject var appVM: AppViewModel
    @State private var editingColumn: String?
    @State private var editingText: String = ""
    @FocusState private var editFieldFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Inspector")
                .font(.headline)

            if let name = appVM.tableVM.selectedObjectName {
                LabeledContent("Object") {
                    Text(name)
                        .fontWeight(.medium)
                }

                LabeledContent("Approx. Rows") {
                    Text("\(appVM.tableVM.approximateRowCount)")
                        .monospacedDigit()
                }

                LabeledContent("Columns") {
                    Text("\(appVM.tableVM.selectedObjectColumnCount)")
                        .monospacedDigit()
                }
            } else {
                Text("No object selected")
                    .foregroundStyle(.secondary)
                    .font(.caption)
            }

            if let rowData = appVM.tableVM.selectedRowData,
               let rowIndex = appVM.tableVM.selectedRowIndex {
                Divider()

                HStack {
                    Text("Row Detail")
                        .font(.headline)
                    Text("#\(rowIndex + 1)")
                        .foregroundStyle(.secondary)
                        .font(.subheadline)
                    Spacer()
                    Button {
                        appVM.clearSelectedRow()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.borderless)
                }

                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(0 ..< rowData.count, id: \.self) { idx in
                            let column = rowData[idx].column
                            let value = rowData[idx].value
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
                                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                                                editFieldFocused = true
                                            }
                                        }
                                } else {
                                    Text(value.displayString)
                                        .font(.system(.body, design: .monospaced))
                                        .foregroundStyle(value.isNull ? .secondary : .primary)
                                        .textSelection(.enabled)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                }
                            }
                            if idx < rowData.count - 1 {
                                Divider()
                            }
                        }
                    }
                }
            }

            Spacer()
        }
        .padding()
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

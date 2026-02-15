import SwiftUI

struct InspectorView: View {
    @EnvironmentObject var appVM: AppViewModel

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
                            VStack(alignment: .leading, spacing: 2) {
                                Text(rowData[idx].column)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Text(rowData[idx].value.displayString)
                                    .font(.system(.body, design: .monospaced))
                                    .foregroundStyle(rowData[idx].value.isNull ? .secondary : .primary)
                                    .textSelection(.enabled)
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
}

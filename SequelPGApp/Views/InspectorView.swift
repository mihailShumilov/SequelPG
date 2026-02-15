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

            Spacer()
        }
        .padding()
    }
}

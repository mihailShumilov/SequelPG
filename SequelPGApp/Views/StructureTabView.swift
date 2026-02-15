import SwiftUI

struct StructureTabView: View {
    @EnvironmentObject var appVM: AppViewModel

    var body: some View {
        if appVM.tableVM.columns.isEmpty {
            Text("Select a table or view to see its structure.")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            Table(appVM.tableVM.columns) {
                TableColumn("#") { col in
                    Text("\(col.ordinalPosition)")
                        .monospacedDigit()
                }
                .width(min: 30, ideal: 40, max: 50)

                TableColumn("Column") { col in
                    Text(col.name)
                }
                .width(min: 100, ideal: 180)

                TableColumn("Type") { col in
                    Text(col.dataType)
                }
                .width(min: 80, ideal: 120)

                TableColumn("Nullable") { col in
                    Text(col.isNullable ? "YES" : "NO")
                }
                .width(min: 50, ideal: 70, max: 80)

                TableColumn("Default") { col in
                    Text(col.columnDefault ?? "")
                        .foregroundStyle(.secondary)
                }
                .width(min: 80, ideal: 150)

                TableColumn("Max Length") { col in
                    if let len = col.characterMaximumLength {
                        Text("\(len)")
                            .monospacedDigit()
                    } else {
                        Text("")
                    }
                }
                .width(min: 60, ideal: 80, max: 100)
            }
        }
    }
}

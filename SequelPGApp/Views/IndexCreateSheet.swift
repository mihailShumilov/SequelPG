import SwiftUI

/// Minimal CREATE INDEX sheet. Supports non-partial, single-column-list indexes
/// with a user-chosen access method. Users who need `WHERE` predicates or
/// expression indexes can drop into the SQL editor.
struct IndexCreateSheet: View {
    let schema: String
    let table: String
    let availableColumns: [String]
    let onCreate: (String) -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var name: String = ""
    @State private var unique: Bool = false
    @State private var method: String = "btree"
    @State private var selectedColumns: Set<String> = []

    private let methods = ["btree", "hash", "gin", "gist", "brin", "spgist"]

    var body: some View {
        VStack(spacing: 0) {
            Text("Create Index on \"\(schema).\(table)\"")
                .font(.headline)
                .padding()
            Form {
                TextField("Index name (optional):", text: $name)
                Toggle("UNIQUE", isOn: $unique)
                Picker("Method:", selection: $method) {
                    ForEach(methods, id: \.self) { Text($0).tag($0) }
                }
                Section("Columns (in order):") {
                    ForEach(availableColumns, id: \.self) { col in
                        Toggle(col, isOn: Binding(
                            get: { selectedColumns.contains(col) },
                            set: { isOn in
                                if isOn { selectedColumns.insert(col) }
                                else { selectedColumns.remove(col) }
                            }
                        ))
                    }
                }
            }
            .formStyle(.grouped)
            .padding(.horizontal)

            HStack {
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Create") {
                    commitCreate()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(selectedColumns.isEmpty)
            }
            .padding()
        }
        .frame(width: 460, height: 460)
    }

    private func commitCreate() {
        let cols = availableColumns.filter { selectedColumns.contains($0) }
        guard !cols.isEmpty else { return }
        let colList = cols.map { quoteIdent($0) }.joined(separator: ", ")
        let uniquePart = unique ? "UNIQUE " : ""
        let namePart = name.trimmingCharacters(in: .whitespaces).isEmpty
            ? ""
            : " \(quoteIdent(name))"
        let sql = """
            CREATE \(uniquePart)INDEX\(namePart) ON \(quoteIdent(schema)).\(quoteIdent(table)) \
            USING \(method) (\(colList))
            """
        onCreate(sql)
        dismiss()
    }
}

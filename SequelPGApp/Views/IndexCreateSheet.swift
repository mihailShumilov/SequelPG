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
            Text("New Index on \u{201C}\(schema).\(table)\u{201D}")
                .font(.headline)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 20)
                .padding(.top, 18)

            Form {
                Section {
                    TextField("Name", text: $name, prompt: Text("Optional — PostgreSQL picks one"))
                        .font(.system(.body, design: .monospaced))
                    Picker("Method", selection: $method) {
                        ForEach(methods, id: \.self) { Text($0).tag($0) }
                    }
                    Toggle("Unique", isOn: $unique)
                }
                Section {
                    ForEach(availableColumns, id: \.self) { col in
                        Toggle(isOn: Binding(
                            get: { selectedColumns.contains(col) },
                            set: { isOn in
                                if isOn { selectedColumns.insert(col) } else { selectedColumns.remove(col) }
                            }
                        )) {
                            Text(col).font(.system(.body, design: .monospaced))
                        }
                    }
                } header: {
                    Text("Columns")
                } footer: {
                    Text("Columns are indexed in table order. Use the query editor for expression or partial indexes.")
                }
            }
            .formStyle(.grouped)

            Divider()

            SheetButtonBar(confirmTitle: "Create", confirmDisabled: selectedColumns.isEmpty) {
                dismiss()
            } onConfirm: {
                commitCreate()
            }
        }
        .frame(width: 460)
        .frame(minHeight: 380, idealHeight: min(300 + CGFloat(availableColumns.count) * 28, 640))
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

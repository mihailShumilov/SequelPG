import SwiftUI

/// Browsable catalog of common built-in PostgreSQL functions. Users can
/// search, filter by category, and insert a signature into the current query.
struct FunctionLibrarySheet: View {
    @Environment(QueryViewModel.self) var queryVM
    @Environment(\.dismiss) private var dismiss

    @State private var searchText: String = ""
    @State private var selectedCategory: SQLFunctionLibrary.Category? = nil

    private var filtered: [SQLFunctionLibrary.Entry] {
        var entries = SQLFunctionLibrary.all
        if let cat = selectedCategory {
            entries = entries.filter { $0.category == cat }
        }
        if !searchText.isEmpty {
            let q = searchText.lowercased()
            entries = entries.filter {
                $0.name.lowercased().contains(q)
                    || $0.signature.lowercased().contains(q)
                    || $0.summary.lowercased().contains(q)
            }
        }
        return entries
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("SQL Function Library").font(.headline)
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            .padding()

            HStack {
                TextField("Search…", text: $searchText)
                    .textFieldStyle(.roundedBorder)

                Picker("Category:", selection: $selectedCategory) {
                    Text("All").tag(SQLFunctionLibrary.Category?.none)
                    ForEach(SQLFunctionLibrary.Category.allCases) { cat in
                        Text(cat.rawValue).tag(SQLFunctionLibrary.Category?.some(cat))
                    }
                }
                .frame(width: 200)
            }
            .padding(.horizontal)
            .padding(.bottom, 8)

            Divider()

            List(filtered) { entry in
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(entry.signature)
                            .font(.system(.callout, design: .monospaced))
                        Text(entry.summary)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text(entry.category.rawValue)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Button {
                        insertIntoEditor(entry.signature)
                    } label: {
                        Image(systemName: "arrow.right.circle.fill")
                    }
                    .buttonStyle(.borderless)
                    .help("Insert into editor")
                }
                .padding(.vertical, 3)
            }
            .listStyle(.plain)
        }
        .frame(width: 600, height: 500)
    }

    private func insertIntoEditor(_ signature: String) {
        // Append with a leading space so we don't mash into prior text.
        if queryVM.queryText.isEmpty {
            queryVM.queryText = signature
        } else if queryVM.queryText.hasSuffix(" ") || queryVM.queryText.hasSuffix("\n") {
            queryVM.queryText += signature
        } else {
            queryVM.queryText += " \(signature)"
        }
    }
}

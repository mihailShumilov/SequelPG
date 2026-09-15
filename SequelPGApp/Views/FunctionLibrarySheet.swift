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
            HStack(spacing: 10) {
                Text("SQL Function Library")
                    .font(.headline)
                Spacer()
                Picker("Category", selection: $selectedCategory) {
                    Text("All Categories").tag(SQLFunctionLibrary.Category?.none)
                    ForEach(SQLFunctionLibrary.Category.allCases) { cat in
                        Text(cat.rawValue).tag(SQLFunctionLibrary.Category?.some(cat))
                    }
                }
                .labelsHidden()
                .frame(width: 170)
                SearchField(text: $searchText, prompt: "Search functions", controlSize: .regular)
                    .frame(width: 200)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)

            Divider()

            if filtered.isEmpty {
                ContentUnavailableView.search(text: searchText)
            } else {
                List(filtered) { entry in
                    HStack(alignment: .top, spacing: 10) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(entry.signature)
                                .font(.system(.callout, design: .monospaced))
                                .textSelection(.enabled)
                            Text(entry.summary)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(entry.category.rawValue)
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                        Button("Insert") {
                            insertIntoEditor(entry.signature)
                        }
                        .controlSize(.small)
                        .help("Insert this signature into the query editor")
                    }
                    .padding(.vertical, 3)
                }
                .listStyle(.inset)
            }

            Divider()

            HStack {
                Text("\(filtered.count) function\(filtered.count == 1 ? "" : "s")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
        }
        .frame(width: 640, height: 520)
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

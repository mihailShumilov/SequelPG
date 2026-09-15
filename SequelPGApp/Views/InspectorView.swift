import SwiftUI

/// Trailing inspector: facts about the selected object and, when a row is
/// selected in the Content or Query grid, every column of that row with a
/// type-aware value preview and in-place editing.
struct InspectorView: View {
    @Environment(AppViewModel.self) var appVM
    @Environment(TableViewModel.self) var tableVM
    @State private var editingColumn: String?
    @State private var editingText: String = ""
    @State private var showDeleteConfirmation = false
    @State private var fieldEditorColumn: String?
    @State private var columnInfoIndex: [String: ColumnInfo] = [:]
    @FocusState private var editFieldFocused: Bool

    var body: some View {
        Group {
            if tableVM.selectedObjectName == nil, tableVM.selectedRowData == nil {
                ContentUnavailableView {
                    Label("No Selection", systemImage: "info.circle")
                } description: {
                    Text("Select an object in the sidebar, or a row in a results grid, to inspect it.")
                }
            } else {
                Form {
                    if let name = tableVM.selectedObjectName {
                        Section("Object") {
                            LabeledContent("Name") {
                                Text(name)
                                    .font(.system(.body, design: .monospaced))
                                    .textSelection(.enabled)
                            }
                            LabeledContent("Rows", value: "≈ \(tableVM.approximateRowCount.formatted())")
                            LabeledContent("Columns", value: "\(tableVM.selectedObjectColumnCount)")
                        }
                    }

                    if let rowData = tableVM.selectedRowData, let rowIndex = tableVM.selectedRowIndex {
                        Section {
                            ForEach(Array(rowData.enumerated()), id: \.element.column) { _, item in
                                rowField(column: item.column, value: item.value)
                            }
                        } header: {
                            HStack {
                                Text("Row \(rowIndex + 1)")
                                Spacer()
                                if inspectorCanDelete {
                                    Button {
                                        showDeleteConfirmation = true
                                    } label: {
                                        Image(systemName: "trash")
                                    }
                                    .buttonStyle(.borderless)
                                    .accessibilityLabel("Delete row")
                                    .help("Delete this row")
                                }
                                Button {
                                    appVM.clearSelectedRow()
                                } label: {
                                    Image(systemName: "xmark.circle.fill")
                                }
                                .buttonStyle(.borderless)
                                .accessibilityLabel("Dismiss row detail")
                                .help("Deselect the row")
                            }
                        } footer: {
                            if appVM.isInspectorEditable {
                                Text("Double-click a value to edit it.")
                            }
                        }
                    }
                }
                .formStyle(.grouped)
            }
        }
        // Rebuild the O(1) column lookup only when the columns array actually
        // changes; the Inspector body fires for many unrelated `tableVM`
        // mutations (selection, page, sort).
        .onAppear { rebuildColumnIndexIfNeeded() }
        .onChange(of: tableVM.columns.count) { _, _ in rebuildColumnIndexIfNeeded() }
        .onChange(of: tableVM.selectedObjectName) { _, _ in rebuildColumnIndexIfNeeded() }
        .alert("Delete Row?", isPresented: $showDeleteConfirmation) {
            Button("Cancel", role: .cancel) {}
            Button("Delete", role: .destructive) {
                Task { await appVM.deleteInspectorRow() }
            }
        } message: {
            Text("This row will be permanently deleted from the database.")
        }
    }

    // MARK: - Row field

    @ViewBuilder
    private func rowField(column: String, value: CellValue) -> some View {
        let colInfo = columnInfoIndex[column]
        let kind = inspectorEditorKind(colInfo: colInfo, value: value)
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(column)
                    .font(.system(.callout, design: .monospaced).weight(.medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let dt = colInfo?.dataType {
                    Tag(ColumnInfo.shortTypeName(dataType: dt, udtName: colInfo?.udtName), color: kind.badgeColor)
                }
                Spacer()
            }

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
                inspectorValueView(value: value, kind: kind)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2) {
                        if needsRichInspectorEditor(kind: kind) {
                            fieldEditorColumn = column
                        } else {
                            editingText = value.isNull ? "NULL" : value.displayString
                            editingColumn = column
                            editFieldFocused = true
                        }
                    }
                    .popover(
                        isPresented: Binding(
                            get: { fieldEditorColumn == column },
                            set: { if !$0 { fieldEditorColumn = nil } }
                        ),
                        arrowEdge: .leading
                    ) {
                        FieldEditorView(
                            columnName: column,
                            dataType: colInfo?.dataType ?? "text",
                            isNullable: colInfo?.isNullable ?? true,
                            initialValue: value,
                            onSave: { newText in
                                fieldEditorColumn = nil
                                Task {
                                    await appVM.updateInspectorCell(columnName: column, newText: newText)
                                }
                            },
                            onCancel: {
                                fieldEditorColumn = nil
                            }
                        )
                    }
            } else {
                inspectorValueView(value: value, kind: kind)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.vertical, 2)
    }

    private func rebuildColumnIndexIfNeeded() {
        let cols = tableVM.columns
        if columnInfoIndex.count == cols.count,
           cols.allSatisfy({ columnInfoIndex[$0.name]?.dataType == $0.dataType })
        {
            return
        }
        columnInfoIndex = Dictionary(cols.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
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

    // MARK: - Rich Editor Helpers

    private func inspectorEditorKind(colInfo: ColumnInfo?, value: CellValue) -> FieldEditorKind {
        guard let info = colInfo else { return .plain }
        let raw = value.isNull ? "" : value.displayString
        return FieldEditorKind(udtName: info.udtName, dataType: info.dataType, value: raw)
    }

    private func needsRichInspectorEditor(kind: FieldEditorKind) -> Bool {
        switch kind {
        case .json, .array, .boolean, .longText: return true
        case .plain: return false
        }
    }

    @ViewBuilder
    private func inspectorValueView(value: CellValue, kind: FieldEditorKind) -> some View {
        switch kind {
        case .json:
            jsonPreview(value: value)
        case .array:
            arrayPreview(value: value)
        case .boolean:
            boolPreview(value: value)
        default:
            Text(value.isNull ? "NULL" : value.displayString)
                .font(.system(.body, design: .monospaced))
                .foregroundStyle(value.isNull ? .tertiary : .primary)
                .lineLimit(6)
        }
    }

    @ViewBuilder
    private func jsonPreview(value: CellValue) -> some View {
        nullOr(value) {
            let preview = prettyJSONPreview(value.displayString, maxLines: 6)
            Text(preview)
                .font(.system(.caption, design: .monospaced))
                .lineLimit(6)
                .padding(6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.panel2, in: RoundedRectangle(cornerRadius: 5))
        }
    }

    @ViewBuilder
    private func arrayPreview(value: CellValue) -> some View {
        nullOr(value) {
            let items = parsePostgresArray(value.displayString)
            if items.isEmpty {
                Text("{}")
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(items.prefix(5).enumerated()), id: \.offset) { idx, item in
                        HStack(spacing: 6) {
                            Text("\(idx)")
                                .font(.system(.caption2, design: .monospaced))
                                .foregroundStyle(.tertiary)
                                .frame(width: 16, alignment: .trailing)
                            if item.isNull {
                                Text("NULL")
                                    .font(.system(.caption, design: .monospaced))
                                    .foregroundStyle(.tertiary)
                            } else {
                                Text(item.value)
                                    .font(.system(.caption, design: .monospaced))
                                    .lineLimit(1)
                            }
                        }
                    }
                    if items.count > 5 {
                        Text("… \(items.count - 5) more")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.panel2, in: RoundedRectangle(cornerRadius: 5))
            }
        }
    }

    @ViewBuilder
    private func boolPreview(value: CellValue) -> some View {
        nullOr(value) {
            let isTrue = value.displayString.lowercased() == "true"
                || value.displayString == "t"
                || value.displayString == "1"
            Label(isTrue ? "true" : "false", systemImage: isTrue ? "checkmark.circle.fill" : "xmark.circle")
                .font(.system(.body, design: .monospaced))
                .foregroundStyle(isTrue ? Color.green : Color.secondary)
        }
    }

    /// Renders the shared "NULL" placeholder for null cells, otherwise the caller's view.
    @ViewBuilder
    private func nullOr<Content: View>(_ value: CellValue, @ViewBuilder _ content: () -> Content) -> some View {
        if value.isNull {
            Text("NULL")
                .font(.system(.body, design: .monospaced))
                .foregroundStyle(.tertiary)
        } else {
            content()
        }
    }

    private func prettyJSONPreview(_ raw: String, maxLines: Int) -> String {
        let key = JSONPreviewCache.Key(raw: raw, maxLines: maxLines)
        if let cached = JSONPreviewCache.shared.get(key) {
            return cached
        }
        let value: String
        if let data = raw.data(using: .utf8),
           let obj = try? JSONSerialization.jsonObject(with: data),
           let pretty = try? JSONSerialization.data(
               withJSONObject: obj, options: [.prettyPrinted, .sortedKeys]
           ),
           let str = String(data: pretty, encoding: .utf8)
        {
            let lines = str.components(separatedBy: "\n")
            value = lines.count > maxLines
                ? lines.prefix(maxLines).joined(separator: "\n") + "\n…"
                : str
        } else {
            value = raw
        }
        JSONPreviewCache.shared.set(key, value: value)
        return value
    }
}

/// Pretty-printed JSON previews are expensive enough (parse + reserialize with
/// sorted keys) that we memoize them by raw string + line limit. Bounded LRU
/// keeps memory from growing unbounded during long sessions.
@MainActor
private final class JSONPreviewCache {
    struct Key: Hashable {
        let raw: String
        let maxLines: Int
    }

    static let shared = JSONPreviewCache()
    private var storage: [Key: String] = [:]
    private var order: [Key] = []
    private let capacity = 128

    func get(_ key: Key) -> String? { storage[key] }

    func set(_ key: Key, value: String) {
        if storage[key] == nil {
            order.append(key)
            if order.count > capacity {
                let evict = order.removeFirst()
                storage.removeValue(forKey: evict)
            }
        }
        storage[key] = value
    }
}

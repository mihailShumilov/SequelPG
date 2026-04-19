import SwiftUI

struct InspectorView: View {
    @Environment(AppViewModel.self) var appVM
    @Environment(TableViewModel.self) var tableVM
    @State private var editingColumn: String?
    @State private var editingText: String = ""
    @State private var showDeleteConfirmation = false
    @State private var fieldEditorColumn: String?
    @FocusState private var editFieldFocused: Bool

    /// O(1) column metadata lookup — the previous `first(where:)` call inside
    /// the per-row ForEach was O(columns × rows) on every render.
    private var columnInfoByName: [String: ColumnInfo] {
        Dictionary(uniqueKeysWithValues: tableVM.columns.map { ($0.name, $0) })
    }

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

                let columnInfoIndex = columnInfoByName
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(Array(rowData.enumerated()), id: \.element.column) { _, item in
                            let column = item.column
                            let value = item.value
                            let colInfo = columnInfoIndex[column]
                            let kind = inspectorEditorKind(colInfo: colInfo, value: value)
                            VStack(alignment: .leading, spacing: 2) {
                                HStack(spacing: 4) {
                                    Text(column)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                    if let dt = colInfo?.dataType {
                                        Text(dt)
                                            .font(.system(size: 9))
                                            .padding(.horizontal, 4)
                                            .padding(.vertical, 1)
                                            .background(inspectorBadgeColor(kind).opacity(0.12))
                                            .foregroundStyle(inspectorBadgeColor(kind))
                                            .cornerRadius(3)
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
                                                        await appVM.updateInspectorCell(
                                                            columnName: column, newText: newText
                                                        )
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

    private func inspectorBadgeColor(_ kind: FieldEditorKind) -> Color {
        kind.badgeColor
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
            Text(value.displayString)
                .font(.system(.body, design: .monospaced))
                .foregroundStyle(value.isNull ? .secondary : .primary)
        }
    }

    @ViewBuilder
    private func jsonPreview(value: CellValue) -> some View {
        nullOr(value) {
            let preview = prettyJSONPreview(value.displayString, maxLines: 4)
            Text(preview)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.primary)
                .lineLimit(4)
                .padding(6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.purple.opacity(0.05))
                .cornerRadius(4)
                .overlay(
                    RoundedRectangle(cornerRadius: 4)
                        .strokeBorder(Color.purple.opacity(0.15), lineWidth: 1)
                )
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
                        HStack(spacing: 4) {
                            Text("\(idx)")
                                .font(.system(size: 9, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .frame(width: 16, alignment: .trailing)
                            if item.isNull {
                                Text("NULL")
                                    .font(.system(.caption, design: .monospaced))
                                    .foregroundStyle(.orange)
                            } else {
                                Text(item.value)
                                    .font(.system(.caption, design: .monospaced))
                                    .lineLimit(1)
                            }
                        }
                    }
                    if items.count > 5 {
                        Text("... +\(items.count - 5) more")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.blue.opacity(0.05))
                .cornerRadius(4)
                .overlay(
                    RoundedRectangle(cornerRadius: 4)
                        .strokeBorder(Color.blue.opacity(0.15), lineWidth: 1)
                )
            }
        }
    }

    @ViewBuilder
    private func boolPreview(value: CellValue) -> some View {
        nullOr(value) {
            let isTrue = value.displayString.lowercased() == "true"
                || value.displayString == "t"
                || value.displayString == "1"
            HStack(spacing: 6) {
                Image(systemName: isTrue ? "checkmark.circle.fill" : "xmark.circle.fill")
                    .foregroundStyle(isTrue ? .green : .red)
                Text(isTrue ? "true" : "false")
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(isTrue ? .green : .red)
            }
        }
    }

    /// Renders the shared "NULL" placeholder for null cells, otherwise the caller's view.
    @ViewBuilder
    private func nullOr<Content: View>(_ value: CellValue, @ViewBuilder _ content: () -> Content) -> some View {
        if value.isNull {
            Text("NULL")
                .font(.system(.body, design: .monospaced))
                .foregroundStyle(.secondary)
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
                ? lines.prefix(maxLines).joined(separator: "\n") + "\n..."
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

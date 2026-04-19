import Foundation
import SwiftUI

// MARK: - Column Type Classification

/// Classifies a PostgreSQL data type string into an editor category.
enum FieldEditorKind {
    case json
    case array
    case boolean
    case longText
    case plain

    /// Character count threshold above which plain text opens a popover editor.
    static let longTextThreshold = 50

    init(dataType: String, value: String) {
        let normalized = dataType.lowercased().trimmingCharacters(in: .whitespaces)
        if normalized == "json" || normalized == "jsonb" {
            self = .json
        } else if normalized == "boolean" || normalized == "bool" {
            self = .boolean
        } else if normalized.hasSuffix("[]") || normalized == "array"
            || normalized.hasPrefix("_")
        {
            self = .array
        } else if value.count > Self.longTextThreshold || value.contains("\n") {
            self = .longText
        } else {
            self = .plain
        }
    }

    /// Determines editor kind from udtName (e.g. _int4 for integer[]).
    init(udtName: String?, dataType: String, value: String) {
        if let udt = udtName?.lowercased(), udt.hasPrefix("_") {
            self = .array
        } else {
            self.init(dataType: dataType, value: value)
        }
    }
}

// MARK: - Field Editor Popover View

/// A rich editor for complex PostgreSQL field types, presented as a popover/sheet.
struct FieldEditorView: View {
    let columnName: String
    let dataType: String
    let isNullable: Bool
    let initialValue: CellValue
    let onSave: (String) -> Void
    let onCancel: () -> Void

    @State private var text: String = ""
    @State private var isNull: Bool = false
    @State private var validationError: String?
    @State private var editorKind: FieldEditorKind = .plain
    @State private var boolValue: Bool = true
    @State private var arrayItems: [ArrayItem] = []
    @State private var jsonFormatted: Bool = true
    @FocusState private var textEditorFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            editorBody
            if let error = validationError {
                validationBanner(error)
            }
            Divider()
            footer
        }
        .frame(
            minWidth: editorKind == .plain ? 360 : 480,
            minHeight: editorKind == .plain ? 160 : 340
        )
        .onAppear {
            setupInitialState()
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 8) {
            typeBadge(dataType)
            VStack(alignment: .leading, spacing: 1) {
                Text(columnName)
                    .font(.headline)
                Text(dataType)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if isNullable {
                Toggle("NULL", isOn: $isNull)
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .onChange(of: isNull) { _, newVal in
                        if newVal {
                            validationError = nil
                        }
                    }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Color(nsColor: .controlBackgroundColor))
    }

    // MARK: - Editor Body

    @ViewBuilder
    private var editorBody: some View {
        if isNull {
            nullPlaceholder
        } else {
            switch editorKind {
            case .json:
                jsonEditor
            case .array:
                arrayEditor
            case .boolean:
                booleanEditor
            case .longText:
                longTextEditor
            case .plain:
                plainTextEditor
            }
        }
    }

    // MARK: - Null Placeholder

    private var nullPlaceholder: some View {
        VStack {
            Spacer()
            Image(systemName: "nosign")
                .font(.system(size: 32))
                .foregroundStyle(.tertiary)
            Text("NULL")
                .font(.title3)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - JSON Editor

    private var jsonEditor: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Button {
                    formatJSON()
                } label: {
                    Label("Format", systemImage: "text.alignleft")
                }
                .buttonStyle(.borderless)
                .controlSize(.small)

                Button {
                    compactJSON()
                } label: {
                    Label("Compact", systemImage: "arrow.right.arrow.left")
                }
                .buttonStyle(.borderless)
                .controlSize(.small)

                Spacer()

                if validationError == nil, !text.isEmpty {
                    Label("Valid JSON", systemImage: "checkmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.green)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)

            Divider()

            TextEditor(text: $text)
                .font(.system(.body, design: .monospaced))
                .scrollContentBackground(.hidden)
                .focused($textEditorFocused)
                .onChange(of: text) { _, _ in
                    validateJSON()
                }
                .padding(4)
        }
    }

    // MARK: - Array Editor

    private var arrayEditor: some View {
        VStack(spacing: 0) {
            HStack {
                Text("\(arrayItems.count) item\(arrayItems.count == 1 ? "" : "s")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    arrayItems.append(ArrayItem(value: ""))
                } label: {
                    Label("Add Item", systemImage: "plus.circle.fill")
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)

            Divider()

            if arrayItems.isEmpty {
                VStack {
                    Spacer()
                    Text("Empty array")
                        .foregroundStyle(.secondary)
                    Text("Click \"Add Item\" to begin")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                    Spacer()
                }
                .frame(maxWidth: .infinity)
            } else {
                List {
                    ForEach($arrayItems) { $item in
                        HStack(spacing: 8) {
                            Image(systemName: "line.3.horizontal")
                                .foregroundStyle(.tertiary)
                                .font(.caption)

                            TextField("Value", text: $item.value)
                                .textFieldStyle(.plain)
                                .font(.system(.body, design: .monospaced))

                            if item.isNull {
                                Text("NULL")
                                    .font(.caption2)
                                    .padding(.horizontal, 4)
                                    .padding(.vertical, 1)
                                    .background(Color.orange.opacity(0.2))
                                    .cornerRadius(3)
                            }

                            Button {
                                item.isNull.toggle()
                                if item.isNull {
                                    item.value = ""
                                }
                            } label: {
                                Image(systemName: item.isNull ? "circle.slash" : "circle")
                                    .foregroundStyle(item.isNull ? Color.orange : Color.secondary)
                            }
                            .buttonStyle(.borderless)
                            .help(item.isNull ? "Set to value" : "Set to NULL")

                            Button {
                                arrayItems.removeAll { $0.id == item.id }
                            } label: {
                                Image(systemName: "minus.circle.fill")
                                    .foregroundStyle(.red.opacity(0.7))
                            }
                            .buttonStyle(.borderless)
                        }
                        .padding(.vertical, 2)
                    }
                    .onMove { from, to in
                        arrayItems.move(fromOffsets: from, toOffset: to)
                    }
                }
                .listStyle(.plain)
                .alternatingRowBackgrounds(.enabled)
            }
        }
    }

    // MARK: - Boolean Editor

    private var booleanEditor: some View {
        VStack(spacing: 16) {
            Spacer()

            HStack(spacing: 0) {
                boolOption(label: "true", value: true, color: .green)
                boolOption(label: "false", value: false, color: .red)
            }
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(Color.primary.opacity(0.15), lineWidth: 1)
            )
            .frame(maxWidth: 280)

            Text(boolValue ? "TRUE" : "FALSE")
                .font(.system(.title2, design: .monospaced, weight: .bold))
                .foregroundStyle(boolValue ? .green : .red)

            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    private func boolOption(label: String, value: Bool, color: Color) -> some View {
        Button {
            boolValue = value
        } label: {
            Text(label)
                .font(.system(.body, design: .monospaced, weight: boolValue == value ? .bold : .regular))
                .foregroundStyle(boolValue == value ? .white : .primary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .background(boolValue == value ? color.opacity(0.85) : Color.clear)
        }
        .buttonStyle(.plain)
    }

    // MARK: - Long Text Editor

    private var longTextEditor: some View {
        VStack(spacing: 0) {
            HStack {
                Text("\(text.count) characters")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)

            Divider()

            TextEditor(text: $text)
                .font(.system(.body, design: .monospaced))
                .scrollContentBackground(.hidden)
                .focused($textEditorFocused)
                .padding(4)
        }
    }

    // MARK: - Plain Text Editor

    private var plainTextEditor: some View {
        VStack(spacing: 12) {
            Spacer()
            TextField("Enter value...", text: $text)
                .textFieldStyle(.roundedBorder)
                .font(.system(.body, design: .monospaced))
                .focused($textEditorFocused)
                .padding(.horizontal, 16)
                .onSubmit {
                    save()
                }
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Validation Banner

    private func validationBanner(_ message: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text(message)
                .font(.caption)
                .lineLimit(2)
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color.orange.opacity(0.1))
    }

    // MARK: - Footer

    private var footer: some View {
        HStack {
            if editorKind == .json || editorKind == .longText {
                Text("Use Cmd+Enter to save")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            Spacer()
            Button("Cancel") {
                onCancel()
            }
            .keyboardShortcut(.escape, modifiers: [])

            Button("Save") {
                save()
            }
            .keyboardShortcut(.return, modifiers: .command)
            .buttonStyle(.borderedProminent)
            .disabled(validationError != nil && !isNull)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    // MARK: - Type Badge

    private func typeBadge(_ type: String) -> some View {
        return Image(systemName: editorKind.badgeIcon)
            .font(.title3)
            .foregroundStyle(editorKind.badgeColor)
            .frame(width: 28, height: 28)
    }

    // MARK: - Logic

    private func setupInitialState() {
        let rawValue: String
        if case .text(let v) = initialValue {
            rawValue = v
        } else {
            rawValue = ""
            isNull = true
        }

        editorKind = FieldEditorKind(dataType: dataType, value: rawValue)
        text = rawValue

        switch editorKind {
        case .json:
            if !rawValue.isEmpty {
                // Try to pretty-print on open
                if let data = rawValue.data(using: .utf8),
                   let obj = try? JSONSerialization.jsonObject(with: data),
                   let pretty = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys]),
                   let str = String(data: pretty, encoding: .utf8)
                {
                    text = str
                }
            }
        case .boolean:
            boolValue = rawValue.lowercased() == "true" || rawValue == "t" || rawValue == "1"
        case .array:
            arrayItems = parsePostgresArray(rawValue)
        default:
            break
        }

        textEditorFocused = true
    }

    private func save() {
        if isNull {
            onSave("")
            return
        }

        switch editorKind {
        case .boolean:
            onSave(boolValue ? "true" : "false")
        case .array:
            onSave(serializePostgresArray(arrayItems))
        case .json:
            // Validate before saving
            if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                guard let data = text.data(using: .utf8),
                      (try? JSONSerialization.jsonObject(with: data)) != nil
                else {
                    validationError = "Invalid JSON. Fix errors before saving."
                    return
                }
            }
            onSave(text)
        default:
            onSave(text)
        }
    }

    private func formatJSON() {
        guard let data = text.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data),
              let pretty = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys]),
              let str = String(data: pretty, encoding: .utf8)
        else { return }
        text = str
    }

    private func compactJSON() {
        guard let data = text.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data),
              let compact = try? JSONSerialization.data(withJSONObject: obj),
              let str = String(data: compact, encoding: .utf8)
        else { return }
        text = str
    }

    private func validateJSON() {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            validationError = nil
            return
        }
        if let data = trimmed.data(using: .utf8),
           (try? JSONSerialization.jsonObject(with: data)) != nil
        {
            validationError = nil
        } else {
            validationError = "Invalid JSON syntax"
        }
    }
}

// MARK: - Array Item Model

struct ArrayItem: Identifiable {
    let id = UUID()
    var value: String
    var isNull: Bool = false
}

// MARK: - Postgres Array Parsing

/// Parses a PostgreSQL text-format array like `{1,2,"hello world",NULL}` into items.
func parsePostgresArray(_ raw: String) -> [ArrayItem] {
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard trimmed.hasPrefix("{"), trimmed.hasSuffix("}") else {
        // If it doesn't look like a PG array, treat the whole string as one item
        if trimmed.isEmpty { return [] }
        return [ArrayItem(value: trimmed)]
    }

    let inner = String(trimmed.dropFirst().dropLast())
    if inner.isEmpty { return [] }

    var items: [ArrayItem] = []
    var current = ""
    var inQuotes = false
    var escaped = false
    var i = inner.startIndex

    while i < inner.endIndex {
        let ch = inner[i]
        if escaped {
            current.append(ch)
            escaped = false
        } else if ch == "\\" {
            escaped = true
        } else if ch == "\"" {
            inQuotes.toggle()
        } else if ch == "," && !inQuotes {
            items.append(makeArrayItem(current))
            current = ""
        } else {
            current.append(ch)
        }
        i = inner.index(after: i)
    }
    items.append(makeArrayItem(current))
    return items
}

private func makeArrayItem(_ raw: String) -> ArrayItem {
    let trimmed = raw.trimmingCharacters(in: .whitespaces)
    if trimmed == "NULL" {
        return ArrayItem(value: "", isNull: true)
    }
    return ArrayItem(value: trimmed)
}

/// Serializes array items back to PostgreSQL text format.
func serializePostgresArray(_ items: [ArrayItem]) -> String {
    let elements = items.map { item -> String in
        if item.isNull { return "NULL" }
        let val = item.value
        // Quote if contains special characters — include control characters
        // so newlines / tabs inside an element can't ambiguate the array text.
        let needsQuoting = val.isEmpty || val.contains(",") || val.contains("\"")
            || val.contains("\\") || val.contains("{") || val.contains("}")
            || val.contains(" ") || val.contains("\n") || val.contains("\r")
            || val.contains("\t") || val.uppercased() == "NULL"
        if needsQuoting {
            let escaped = val
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")
                .replacingOccurrences(of: "\n", with: "\\n")
                .replacingOccurrences(of: "\r", with: "\\r")
                .replacingOccurrences(of: "\t", with: "\\t")
            return "\"\(escaped)\""
        }
        return val
    }
    return "{\(elements.joined(separator: ","))}"
}

// MARK: - Badge Info on FieldEditorKind

extension FieldEditorKind {
    var badgeIcon: String {
        switch self {
        case .json: return "curlybraces"
        case .array: return "list.bullet.rectangle"
        case .boolean: return "switch.2"
        case .longText: return "text.alignleft"
        case .plain: return "character.cursor.ibeam"
        }
    }

    var badgeColor: Color {
        switch self {
        case .json: return .purple
        case .array: return .blue
        case .boolean: return .green
        case .longText: return .orange
        case .plain: return .secondary
        }
    }
}

// MARK: - Cell Type Badge (for use in table grid)

/// A small inline badge shown in table cells for complex types.
struct CellTypeBadge: View {
    let kind: FieldEditorKind

    var body: some View {
        if kind != .plain {
            Image(systemName: kind.badgeIcon)
                .font(.system(size: 9))
                .foregroundStyle(kind.badgeColor.opacity(0.7))
        }
    }
}

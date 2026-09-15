import SwiftUI

/// Shared frame for the create-object sheets: headline, grouped form, and the
/// standard Cancel / Create button row.
private struct CreateSheetFrame<Content: View>: View {
    let title: String
    let width: CGFloat
    let height: CGFloat
    let canCreate: Bool
    let onCancel: () -> Void
    let onCreate: () -> Void
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(spacing: 0) {
            Text(title)
                .font(.headline)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 20)
                .padding(.top, 18)

            Form {
                content()
            }
            .formStyle(.grouped)

            Divider()

            SheetButtonBar(confirmTitle: "Create", confirmDisabled: !canCreate, onCancel: onCancel, onConfirm: onCreate)
        }
        .frame(width: width, height: height)
    }
}

/// Multi-line SQL body field used by the view / function / generic sheets.
private struct SQLBodyField: View {
    let label: String
    @Binding var text: String
    var minHeight: CGFloat = 140

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
            TextEditor(text: $text)
                .font(.system(.body, design: .monospaced))
                .frame(minHeight: minHeight)
                .scrollContentBackground(.hidden)
                .padding(4)
                .background(Theme.bg, in: RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.line, lineWidth: 1))
        }
    }
}

// MARK: - Create View Sheet

struct CreateViewSheet: View {
    let schema: String
    let onCreate: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var sqlDefinition = "SELECT "

    private var canCreate: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty
            && !sqlDefinition.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !schema.isEmpty
    }

    var body: some View {
        CreateSheetFrame(
            title: "New View in \u{201C}\(schema)\u{201D}",
            width: 520, height: 400, canCreate: canCreate,
            onCancel: { dismiss() },
            onCreate: {
                let trimmedName = name.trimmingCharacters(in: .whitespaces)
                let sql = "CREATE OR REPLACE VIEW \(quoteIdent(schema)).\(quoteIdent(trimmedName)) AS \(sqlDefinition)"
                onCreate(sql)
                dismiss()
            }
        ) {
            TextField("Name", text: $name)
                .font(.system(.body, design: .monospaced))
            SQLBodyField(label: "Definition", text: $sqlDefinition)
        }
    }
}

// MARK: - Create Materialized View Sheet

struct CreateMaterializedViewSheet: View {
    let schema: String
    let onCreate: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var sqlDefinition = "SELECT "

    private var canCreate: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty
            && !sqlDefinition.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !schema.isEmpty
    }

    var body: some View {
        CreateSheetFrame(
            title: "New Materialized View in \u{201C}\(schema)\u{201D}",
            width: 520, height: 400, canCreate: canCreate,
            onCancel: { dismiss() },
            onCreate: {
                let trimmedName = name.trimmingCharacters(in: .whitespaces)
                let sql = "CREATE MATERIALIZED VIEW \(quoteIdent(schema)).\(quoteIdent(trimmedName)) AS \(sqlDefinition)"
                onCreate(sql)
                dismiss()
            }
        ) {
            TextField("Name", text: $name)
                .font(.system(.body, design: .monospaced))
            SQLBodyField(label: "Definition", text: $sqlDefinition)
        }
    }
}

// MARK: - Create Function Sheet

struct CreateFunctionSheet: View {
    let schema: String
    let onCreate: (String) -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var parameters = ""
    @State private var returnType = "void"
    @State private var language = "plpgsql"
    @State private var functionBody = "BEGIN\n  \nEND;"
    @State private var volatility = "VOLATILE"
    @State private var showUntrustedWarning = false
    @State private var pendingUntrustedCreate: (() -> Void)?

    private let returnTypes = ["void", "text", "integer", "bigint", "boolean", "trigger", "record", "setof record", "table"]
    private let languages = ["sql", "plpgsql", "plpython3u"]
    private let volatilities = ["VOLATILE", "STABLE", "IMMUTABLE"]

    private var languageIsUntrusted: Bool {
        // Untrusted PLs (suffix "u") run as the DB superuser with full OS
        // access. We surface an explicit warning so users don't enable one
        // accidentally via the Picker.
        language.hasSuffix("u")
    }

    private var canCreate: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty && !schema.isEmpty
    }

    var body: some View {
        CreateSheetFrame(
            title: "New Function in \u{201C}\(schema)\u{201D}",
            width: 560, height: 560, canCreate: canCreate,
            onCancel: { dismiss() },
            onCreate: { create() }
        ) {
            Section {
                TextField("Name", text: $name)
                    .font(.system(.body, design: .monospaced))
                TextField("Parameters", text: $parameters, prompt: Text("p1 integer, p2 text"))
                    .font(.system(.body, design: .monospaced))
                LabeledContent("Returns") {
                    SuggestingTextField(label: "type", text: $returnType, suggestions: returnTypes)
                }
                Picker("Language", selection: $language) {
                    ForEach(languages, id: \.self) { Text($0).tag($0) }
                }
                Picker("Volatility", selection: $volatility) {
                    ForEach(volatilities, id: \.self) { Text($0).tag($0) }
                }
            } footer: {
                if languageIsUntrusted {
                    Label(
                        "\(language) is an untrusted language — functions run with superuser OS-level access.",
                        systemImage: "exclamationmark.triangle.fill"
                    )
                    .foregroundStyle(.orange)
                }
            }
            Section {
                SQLBodyField(label: "Body", text: $functionBody, minHeight: 150)
            }
        }
        .alert("Create untrusted function?", isPresented: $showUntrustedWarning, presenting: pendingUntrustedCreate) { confirm in
            Button("Cancel", role: .cancel) { pendingUntrustedCreate = nil }
            Button("Create", role: .destructive) {
                confirm()
                pendingUntrustedCreate = nil
            }
        } message: { _ in
            Text("\(language) functions execute with full operating-system access as the PostgreSQL superuser. Only proceed if you trust the code and authored it yourself.")
        }
    }

    private func create() {
        let trimmedName = name.trimmingCharacters(in: .whitespaces)
        guard !trimmedName.isEmpty, !schema.isEmpty else { return }
        let params = parameters.trimmingCharacters(in: .whitespaces)
        guard isValidFunctionParams(params) else { return }
        let returns = returnType.trimmingCharacters(in: .whitespaces)
        let sql = "CREATE OR REPLACE FUNCTION \(quoteIdent(schema)).\(quoteIdent(trimmedName))(\(params)) RETURNS \(returns) LANGUAGE \(language) \(volatility) AS $$\n\(functionBody)\n$$"
        let commit = {
            onCreate(sql)
            dismiss()
        }
        if languageIsUntrusted {
            pendingUntrustedCreate = commit
            showUntrustedWarning = true
        } else {
            commit()
        }
    }
}

// MARK: - Create Sequence Sheet

struct CreateSequenceSheet: View {
    let schema: String
    let onCreate: (String) -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var increment = "1"
    @State private var minValue = ""
    @State private var maxValue = ""
    @State private var startValue = ""
    @State private var cache = "1"
    @State private var cycle = false

    private var canCreate: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty && !schema.isEmpty
    }

    var body: some View {
        CreateSheetFrame(
            title: "New Sequence in \u{201C}\(schema)\u{201D}",
            width: 440, height: 400, canCreate: canCreate,
            onCancel: { dismiss() },
            onCreate: {
                let trimmedName = name.trimmingCharacters(in: .whitespaces)
                var sql = "CREATE SEQUENCE \(quoteIdent(schema)).\(quoteIdent(trimmedName))"
                if let inc = Int(increment.trimmingCharacters(in: .whitespaces)) { sql += " INCREMENT \(inc)" }
                if let min = Int(minValue.trimmingCharacters(in: .whitespaces)) { sql += " MINVALUE \(min)" }
                if let max = Int(maxValue.trimmingCharacters(in: .whitespaces)) { sql += " MAXVALUE \(max)" }
                if let start = Int(startValue.trimmingCharacters(in: .whitespaces)) { sql += " START \(start)" }
                if let c = Int(cache.trimmingCharacters(in: .whitespaces)) { sql += " CACHE \(c)" }
                if cycle { sql += " CYCLE" }
                onCreate(sql)
                dismiss()
            }
        ) {
            TextField("Name", text: $name)
                .font(.system(.body, design: .monospaced))
            TextField("Increment", text: $increment)
            TextField("Minimum", text: $minValue, prompt: Text("default"))
            TextField("Maximum", text: $maxValue, prompt: Text("default"))
            TextField("Start", text: $startValue, prompt: Text("default"))
            TextField("Cache", text: $cache)
            Toggle("Cycle when exhausted", isOn: $cycle)
        }
    }
}

// MARK: - Create Type Sheet

struct CreateTypeSheet: View {
    let schema: String
    let onCreate: (String) -> Void
    @Environment(\.dismiss) private var dismiss

    enum TypeMode: String, CaseIterable {
        case `enum` = "Enum"
        case composite = "Composite"
    }

    private struct CompositeField: Identifiable {
        let id = UUID()
        var name: String
        var type: String
    }

    private struct EnumLabel: Identifiable {
        let id = UUID()
        var value: String
    }

    @State private var name = ""
    @State private var mode: TypeMode = .enum
    @State private var enumLabels: [EnumLabel] = [EnumLabel(value: "")]
    @State private var compositeFields: [CompositeField] = [CompositeField(name: "", type: "text")]

    private var canCreate: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty && !schema.isEmpty
    }

    var body: some View {
        CreateSheetFrame(
            title: "New Type in \u{201C}\(schema)\u{201D}",
            width: 500, height: 460, canCreate: canCreate,
            onCancel: { dismiss() },
            onCreate: { create() }
        ) {
            Section {
                TextField("Name", text: $name)
                    .font(.system(.body, design: .monospaced))
                Picker("Kind", selection: $mode) {
                    ForEach(TypeMode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
            }

            if mode == .enum {
                Section {
                    ForEach($enumLabels) { $label in
                        HStack {
                            TextField("label", text: $label.value)
                                .font(.system(.body, design: .monospaced))
                            Button {
                                enumLabels.removeAll { $0.id == label.id }
                            } label: {
                                Image(systemName: "minus.circle")
                            }
                            .buttonStyle(.borderless)
                            .disabled(enumLabels.count <= 1)
                        }
                    }
                    Button {
                        enumLabels.append(EnumLabel(value: ""))
                    } label: {
                        Label("Add Label", systemImage: "plus")
                    }
                    .buttonStyle(.borderless)
                } header: {
                    Text("Labels (in order)")
                }
            } else {
                Section {
                    ForEach($compositeFields) { $field in
                        HStack {
                            TextField("name", text: $field.name)
                                .font(.system(.body, design: .monospaced))
                            SuggestingTextField(label: "type", text: $field.type, suggestions: PGTypeSuggestions.column)
                                .frame(width: 170)
                            Button {
                                compositeFields.removeAll { $0.id == field.id }
                            } label: {
                                Image(systemName: "minus.circle")
                            }
                            .buttonStyle(.borderless)
                            .disabled(compositeFields.count <= 1)
                        }
                    }
                    Button {
                        compositeFields.append(CompositeField(name: "", type: "text"))
                    } label: {
                        Label("Add Field", systemImage: "plus")
                    }
                    .buttonStyle(.borderless)
                } header: {
                    Text("Fields")
                }
            }
        }
    }

    private func create() {
        let trimmedName = name.trimmingCharacters(in: .whitespaces)
        guard !trimmedName.isEmpty, !schema.isEmpty else { return }
        let sql: String
        if mode == .enum {
            let labels = enumLabels
                .map { $0.value.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
                .map { "'\($0.replacingOccurrences(of: "'", with: "''"))'" }
                .joined(separator: ", ")
            sql = "CREATE TYPE \(quoteIdent(schema)).\(quoteIdent(trimmedName)) AS ENUM (\(labels))"
        } else {
            let validFields = compositeFields
                .filter { !$0.name.trimmingCharacters(in: .whitespaces).isEmpty }
            for field in validFields {
                guard isValidTypeName(field.type.trimmingCharacters(in: .whitespaces)) else { return }
            }
            let fields = validFields
                .map { "\(quoteIdent($0.name.trimmingCharacters(in: .whitespaces))) \($0.type.trimmingCharacters(in: .whitespaces))" }
                .joined(separator: ", ")
            sql = "CREATE TYPE \(quoteIdent(schema)).\(quoteIdent(trimmedName)) AS (\(fields))"
        }
        onCreate(sql)
        dismiss()
    }
}

// MARK: - Create Domain Sheet

struct CreateDomainSheet: View {
    let schema: String
    let onCreate: (String) -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var baseType = "text"
    @State private var nullable = true
    @State private var defaultValue = ""
    @State private var checkExpression = ""

    private var canCreate: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty
            && !baseType.trimmingCharacters(in: .whitespaces).isEmpty
            && !schema.isEmpty
    }

    var body: some View {
        CreateSheetFrame(
            title: "New Domain in \u{201C}\(schema)\u{201D}",
            width: 480, height: 360, canCreate: canCreate,
            onCancel: { dismiss() },
            onCreate: {
                let trimmedName = name.trimmingCharacters(in: .whitespaces)
                guard !trimmedName.isEmpty, !schema.isEmpty else { return }
                var sql = "CREATE DOMAIN \(quoteIdent(schema)).\(quoteIdent(trimmedName)) AS \(baseType.trimmingCharacters(in: .whitespaces))"
                let trimmedDefault = defaultValue.trimmingCharacters(in: .whitespaces)
                if !trimmedDefault.isEmpty {
                    guard isValidSQLExpression(trimmedDefault) else { return }
                    sql += " DEFAULT \(trimmedDefault)"
                }
                if !nullable { sql += " NOT NULL" }
                let trimmedCheck = checkExpression.trimmingCharacters(in: .whitespaces)
                if !trimmedCheck.isEmpty {
                    guard isValidSQLExpression(trimmedCheck) else { return }
                    sql += " CHECK (\(trimmedCheck))"
                }
                onCreate(sql)
                dismiss()
            }
        ) {
            TextField("Name", text: $name)
                .font(.system(.body, design: .monospaced))
            LabeledContent("Base type") {
                SuggestingTextField(label: "type", text: $baseType, suggestions: PGTypeSuggestions.column)
            }
            Toggle("Allows NULL", isOn: $nullable)
            TextField("Default", text: $defaultValue, prompt: Text("expression"))
                .font(.system(.body, design: .monospaced))
            TextField("Check", text: $checkExpression, prompt: Text("VALUE > 0"))
                .font(.system(.body, design: .monospaced))
        }
    }
}

// MARK: - Generic Create Sheet

struct GenericCreateSheet: View {
    let title: String
    let schema: String
    let onCreate: (String) -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var sqlBody = ""

    var body: some View {
        CreateSheetFrame(
            title: "New \(singular(title)) in \u{201C}\(schema)\u{201D}",
            width: 520, height: 380,
            canCreate: !sqlBody.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            onCancel: { dismiss() },
            onCreate: {
                onCreate(sqlBody)
                dismiss()
            }
        ) {
            Section {
                SQLBodyField(label: "CREATE statement", text: $sqlBody, minHeight: 180)
            } footer: {
                Text("The statement runs as written; the schema is not added automatically.")
            }
        }
    }

    private func singular(_ category: String) -> String {
        category.hasSuffix("s") ? String(category.dropLast()) : category
    }
}

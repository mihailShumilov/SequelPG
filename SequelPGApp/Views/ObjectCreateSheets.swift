import SwiftUI

// MARK: - Create View Sheet

struct CreateViewSheet: View {
    let schema: String
    let onCreate: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var sqlDefinition = "SELECT "

    var body: some View {
        VStack(spacing: 0) {
            Text("Create View in \"\(schema)\"")
                .font(.headline)
                .padding()
            Form {
                TextField("View name:", text: $name)
                VStack(alignment: .leading) {
                    Text("SQL Definition:")
                    TextEditor(text: $sqlDefinition)
                        .font(.system(.body, design: .monospaced))
                        .frame(minHeight: 120)
                }
            }
            .formStyle(.grouped)
            .padding(.horizontal)
            HStack {
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Create") {
                    let trimmedName = name.trimmingCharacters(in: .whitespaces)
                    guard !trimmedName.isEmpty, !schema.isEmpty else { return }
                    let sql = "CREATE OR REPLACE VIEW \(quoteIdent(schema)).\(quoteIdent(trimmedName)) AS \(sqlDefinition)"
                    onCreate(sql)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || sqlDefinition.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || schema.isEmpty)
            }
            .padding()
        }
        .frame(width: 480)
    }
}

// MARK: - Create Materialized View Sheet

struct CreateMaterializedViewSheet: View {
    let schema: String
    let onCreate: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var sqlDefinition = "SELECT "

    var body: some View {
        VStack(spacing: 0) {
            Text("Create Materialized View in \"\(schema)\"")
                .font(.headline)
                .padding()
            Form {
                TextField("Name:", text: $name)
                VStack(alignment: .leading) {
                    Text("SQL Definition:")
                    TextEditor(text: $sqlDefinition)
                        .font(.system(.body, design: .monospaced))
                        .frame(minHeight: 120)
                }
            }
            .formStyle(.grouped)
            .padding(.horizontal)
            HStack {
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Create") {
                    let trimmedName = name.trimmingCharacters(in: .whitespaces)
                    guard !trimmedName.isEmpty, !schema.isEmpty else { return }
                    let sql = "CREATE MATERIALIZED VIEW \(quoteIdent(schema)).\(quoteIdent(trimmedName)) AS \(sqlDefinition)"
                    onCreate(sql)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || sqlDefinition.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || schema.isEmpty)
            }
            .padding()
        }
        .frame(width: 480)
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

    private let returnTypes = ["void", "text", "integer", "boolean", "trigger", "record", "setof record", "table"]
    private let languages = ["sql", "plpgsql", "plpython3u"]
    private let volatilities = ["VOLATILE", "STABLE", "IMMUTABLE"]

    private var languageIsUntrusted: Bool {
        // Untrusted PLs (suffix "u") run as the DB superuser with full OS
        // access. We surface an explicit warning so users don't enable one
        // accidentally via the Picker.
        language.hasSuffix("u")
    }

    var body: some View {
        VStack(spacing: 0) {
            Text("Create Function in \"\(schema)\"")
                .font(.headline)
                .padding()
            Form {
                TextField("Function name:", text: $name)
                TextField("Parameters (e.g. p1 integer, p2 text):", text: $parameters)
                    .font(.system(.body, design: .monospaced))
                Picker("Returns:", selection: $returnType) {
                    ForEach(returnTypes, id: \.self) { Text($0).tag($0) }
                }
                Picker("Language:", selection: $language) {
                    ForEach(languages, id: \.self) { Text($0).tag($0) }
                }
                if languageIsUntrusted {
                    Label("\(language) is an untrusted language — functions run with superuser OS-level access. Only use for trusted code.",
                          systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                Picker("Volatility:", selection: $volatility) {
                    ForEach(volatilities, id: \.self) { Text($0).tag($0) }
                }
                VStack(alignment: .leading) {
                    Text("Body:")
                    TextEditor(text: $functionBody)
                        .font(.system(.body, design: .monospaced))
                        .frame(minHeight: 140)
                }
            }
            .formStyle(.grouped)
            .padding(.horizontal)
            HStack {
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Create") {
                    let trimmedName = name.trimmingCharacters(in: .whitespaces)
                    guard !trimmedName.isEmpty, !schema.isEmpty else { return }
                    let params = parameters.trimmingCharacters(in: .whitespaces)
                    guard isValidFunctionParams(params) else { return }
                    let sql = "CREATE OR REPLACE FUNCTION \(quoteIdent(schema)).\(quoteIdent(trimmedName))(\(params)) RETURNS \(returnType) LANGUAGE \(language) \(volatility) AS $$\n\(functionBody)\n$$"
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
                .keyboardShortcut(.defaultAction)
                .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || schema.isEmpty)
            }
            .padding()
        }
        .frame(width: 520)
        .frame(minHeight: 500)
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

    var body: some View {
        VStack(spacing: 0) {
            Text("Create Sequence in \"\(schema)\"")
                .font(.headline)
                .padding()
            Form {
                TextField("Sequence name:", text: $name)
                TextField("Increment:", text: $increment)
                TextField("Min value:", text: $minValue)
                TextField("Max value:", text: $maxValue)
                TextField("Start value:", text: $startValue)
                TextField("Cache:", text: $cache)
                Toggle("Cycle", isOn: $cycle)
            }
            .formStyle(.grouped)
            .padding(.horizontal)
            HStack {
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Create") {
                    let trimmedName = name.trimmingCharacters(in: .whitespaces)
                    guard !trimmedName.isEmpty, !schema.isEmpty else { return }
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
                .keyboardShortcut(.defaultAction)
                .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || schema.isEmpty)
            }
            .padding()
        }
        .frame(width: 420)
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

    @State private var name = ""
    @State private var mode: TypeMode = .enum
    @State private var enumLabels: [String] = [""]
    @State private var compositeFields: [(name: String, type: String)] = [("", "text")]

    var body: some View {
        VStack(spacing: 0) {
            Text("Create Type in \"\(schema)\"")
                .font(.headline)
                .padding()
            Form {
                TextField("Type name:", text: $name)
                Picker("Mode:", selection: $mode) {
                    ForEach(TypeMode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
            }
            .formStyle(.grouped)
            .padding(.horizontal)

            if mode == .enum {
                enumEditor
            } else {
                compositeEditor
            }

            HStack {
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Create") {
                    let trimmedName = name.trimmingCharacters(in: .whitespaces)
                    guard !trimmedName.isEmpty, !schema.isEmpty else { return }
                    let sql: String
                    if mode == .enum {
                        let labels = enumLabels
                            .map { $0.trimmingCharacters(in: .whitespaces) }
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
                .keyboardShortcut(.defaultAction)
                .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || schema.isEmpty)
            }
            .padding()
        }
        .frame(width: 480)
    }

    private var enumEditor: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Enum Labels")
                    .font(.subheadline.weight(.medium))
                Spacer()
                Button {
                    enumLabels.append("")
                } label: {
                    Image(systemName: "plus")
                }
                .buttonStyle(.borderless)
            }
            .padding(.horizontal)
            ScrollView {
                VStack(spacing: 6) {
                    ForEach(enumLabels.indices, id: \.self) { idx in
                        HStack {
                            TextField("label", text: Binding(
                                get: { enumLabels[idx] },
                                set: { enumLabels[idx] = $0 }
                            ))
                            Button {
                                enumLabels.remove(at: idx)
                            } label: {
                                Image(systemName: "trash")
                                    .foregroundStyle(.red)
                            }
                            .buttonStyle(.borderless)
                            .disabled(enumLabels.count <= 1)
                        }
                    }
                }
                .padding(.horizontal)
            }
            .frame(minHeight: 80, maxHeight: 200)
        }
        .padding(.vertical, 4)
    }

    private var compositeEditor: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Fields")
                    .font(.subheadline.weight(.medium))
                Spacer()
                Button {
                    compositeFields.append(("", "text"))
                } label: {
                    Image(systemName: "plus")
                }
                .buttonStyle(.borderless)
            }
            .padding(.horizontal)
            ScrollView {
                VStack(spacing: 6) {
                    ForEach(compositeFields.indices, id: \.self) { idx in
                        HStack {
                            TextField("name", text: Binding(
                                get: { compositeFields[idx].name },
                                set: { compositeFields[idx].name = $0 }
                            ))
                            TextField("type", text: Binding(
                                get: { compositeFields[idx].type },
                                set: { compositeFields[idx].type = $0 }
                            ))
                            .font(.system(.body, design: .monospaced))
                            Button {
                                compositeFields.remove(at: idx)
                            } label: {
                                Image(systemName: "trash")
                                    .foregroundStyle(.red)
                            }
                            .buttonStyle(.borderless)
                            .disabled(compositeFields.count <= 1)
                        }
                    }
                }
                .padding(.horizontal)
            }
            .frame(minHeight: 80, maxHeight: 200)
        }
        .padding(.vertical, 4)
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

    private let commonBaseTypes = [
        "text", "varchar(255)", "integer", "bigint", "smallint",
        "boolean", "numeric", "numeric(10,2)", "real", "double precision",
        "date", "timestamp", "timestamptz", "uuid", "jsonb",
    ]

    var body: some View {
        VStack(spacing: 0) {
            Text("Create Domain in \"\(schema)\"")
                .font(.headline)
                .padding()
            Form {
                TextField("Domain name:", text: $name)
                Picker("Base type:", selection: $baseType) {
                    ForEach(commonBaseTypes, id: \.self) { Text($0).tag($0) }
                }
                Toggle("Nullable", isOn: $nullable)
                TextField("Default value:", text: $defaultValue)
                    .font(.system(.body, design: .monospaced))
                TextField("CHECK expression:", text: $checkExpression)
                    .font(.system(.body, design: .monospaced))
            }
            .formStyle(.grouped)
            .padding(.horizontal)
            HStack {
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Create") {
                    let trimmedName = name.trimmingCharacters(in: .whitespaces)
                    guard !trimmedName.isEmpty, !schema.isEmpty else { return }
                    var sql = "CREATE DOMAIN \(quoteIdent(schema)).\(quoteIdent(trimmedName)) AS \(baseType)"
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
                .keyboardShortcut(.defaultAction)
                .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || schema.isEmpty)
            }
            .padding()
        }
        .frame(width: 460)
    }
}

// MARK: - Generic Create Sheet

struct GenericCreateSheet: View {
    let title: String
    let schema: String
    let onCreate: (String) -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var sqlBody = ""

    var body: some View {
        VStack(spacing: 0) {
            Text("Create \(title) in \"\(schema)\"")
                .font(.headline)
                .padding()
            Form {
                TextField("Name (for reference):", text: $name)
                VStack(alignment: .leading) {
                    Text("Full CREATE statement:")
                    TextEditor(text: $sqlBody)
                        .font(.system(.body, design: .monospaced))
                        .frame(minHeight: 140)
                }
            }
            .formStyle(.grouped)
            .padding(.horizontal)
            HStack {
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Create") {
                    onCreate(sqlBody)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(sqlBody.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding()
        }
        .frame(width: 480)
        .frame(minHeight: 350)
    }
}

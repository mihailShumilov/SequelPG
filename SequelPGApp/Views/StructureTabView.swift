import SwiftUI

struct StructureTabView: View {
    @Environment(AppViewModel.self) var appVM
    @Environment(TableViewModel.self) var tableVM
    @Environment(NavigatorViewModel.self) var navigatorVM

    @State private var selectedColumnId: String?
    @State private var showAddColumn = false
    @State private var dropConfirmColumn: ColumnInfo?

    // Inline editing state
    @State private var editingField: (columnName: String, field: EditableField)?
    @State private var editingText: String = ""
    @FocusState private var editFieldFocused: Bool

    enum EditableField {
        case name, type, defaultValue
    }

    private var isTable: Bool {
        navigatorVM.selectedObject?.type == .table
    }

    var body: some View {
        VStack(spacing: 0) {
            if tableVM.columns.isEmpty {
                Text("Select a table or view to see its structure.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Table(tableVM.columns, selection: $selectedColumnId) {
                    TableColumn("#") { col in
                        Text("\(col.ordinalPosition)")
                            .monospacedDigit()
                    }
                    .width(min: 30, ideal: 40, max: 50)

                    TableColumn("Column") { col in
                        editableCell(column: col, field: .name, value: col.name)
                    }
                    .width(min: 100, ideal: 180)

                    TableColumn("Type") { col in
                        editableCell(column: col, field: .type, value: col.dataType)
                    }
                    .width(min: 80, ideal: 120)

                    TableColumn("Nullable") { col in
                        if isTable {
                            Toggle("", isOn: Binding(
                                get: { col.isNullable },
                                set: { newValue in
                                    Task { await toggleNullable(column: col, nullable: newValue) }
                                }
                            ))
                            .toggleStyle(.checkbox)
                            .labelsHidden()
                        } else {
                            Text(col.isNullable ? "YES" : "NO")
                        }
                    }
                    .width(min: 50, ideal: 70, max: 80)

                    TableColumn("Default") { col in
                        editableCell(column: col, field: .defaultValue, value: col.columnDefault ?? "")
                    }
                    .width(min: 80, ideal: 150)

                    TableColumn("PK") { col in
                        if col.isPrimaryKey {
                            Image(systemName: "key.fill")
                                .foregroundStyle(.yellow)
                                .font(.caption)
                        }
                    }
                    .width(min: 30, ideal: 35, max: 40)

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
                .tableStyle(.bordered(alternatesRowBackgrounds: true))
            }

            if isTable {
                Divider()
                toolbar
            }
        }
        .sheet(isPresented: $showAddColumn) {
            AddColumnSheet { name, dataType, nullable, defaultValue in
                Task { await addColumn(name: name, dataType: dataType, nullable: nullable, defaultValue: defaultValue) }
            }
        }
        .alert("Drop Column?", isPresented: .init(
            get: { dropConfirmColumn != nil },
            set: { if !$0 { dropConfirmColumn = nil } }
        )) {
            Button("Cancel", role: .cancel) { dropConfirmColumn = nil }
            Button("Drop", role: .destructive) {
                if let col = dropConfirmColumn {
                    dropConfirmColumn = nil
                    Task { await dropColumn(col) }
                }
            }
        } message: {
            Text("Column \"\(dropConfirmColumn?.name ?? "")\" and all its data will be permanently removed.")
        }
    }

    // MARK: - Toolbar

    private var toolbar: some View {
        HStack {
            Button {
                showAddColumn = true
            } label: {
                Image(systemName: "plus")
                    .frame(width: 16, height: 16)
            }
            .help("Add Column")

            Button {
                if let id = selectedColumnId,
                   let col = tableVM.columns.first(where: { $0.id == id }) {
                    dropConfirmColumn = col
                }
            } label: {
                Image(systemName: "minus")
                    .frame(width: 16, height: 16)
            }
            .disabled(selectedColumnId == nil)
            .help("Drop Selected Column")

            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    // MARK: - Inline Editing

    @ViewBuilder
    private func editableCell(column: ColumnInfo, field: EditableField, value: String) -> some View {
        if isTable,
           let editing = editingField,
           editing.columnName == column.name,
           editing.field == field
        {
            TextField("", text: $editingText)
                .textFieldStyle(.plain)
                .font(.system(.body, design: .monospaced))
                .focused($editFieldFocused)
                .onSubmit { commitFieldEdit(column: column, field: field) }
                .onExitCommand { cancelFieldEdit() }
                .onChange(of: editFieldFocused) { _, focused in
                    if !focused { commitFieldEdit(column: column, field: field) }
                }
        } else {
            Text(value)
                .foregroundStyle(field == .defaultValue && value.isEmpty ? .tertiary : .primary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .onTapGesture {
                    guard isTable else { return }
                    if editingField != nil {
                        // Commit previous edit before starting new one
                        if let prev = editingField,
                           let prevCol = tableVM.columns.first(where: { $0.name == prev.columnName }) {
                            commitFieldEdit(column: prevCol, field: prev.field)
                        }
                    }
                    editingText = value
                    editingField = (columnName: column.name, field: field)
                    editFieldFocused = true
                }
        }
    }

    private func commitFieldEdit(column: ColumnInfo, field: EditableField) {
        let newValue = editingText.trimmingCharacters(in: .whitespacesAndNewlines)
        editingField = nil
        editingText = ""

        switch field {
        case .name:
            if !newValue.isEmpty, newValue != column.name {
                Task { await renameColumn(column: column, newName: newValue) }
            }
        case .type:
            if !newValue.isEmpty, newValue != column.dataType {
                Task { await changeType(column: column, newType: newValue) }
            }
        case .defaultValue:
            let oldDefault = column.columnDefault ?? ""
            if newValue != oldDefault {
                Task { await changeDefault(column: column, newDefault: newValue) }
            }
        }
    }

    private func cancelFieldEdit() {
        editingField = nil
        editingText = ""
    }

    // MARK: - ALTER TABLE Operations

    private func addColumn(name: String, dataType: String, nullable: Bool, defaultValue: String) async {
        guard let object = navigatorVM.selectedObject else { return }

        var sql = "ALTER TABLE \(quoteIdent(object.schema)).\(quoteIdent(object.name)) ADD COLUMN \(quoteIdent(name)) \(dataType)"
        if !nullable {
            sql += " NOT NULL"
        }
        if !defaultValue.isEmpty {
            sql += " DEFAULT \(defaultValue)"
        }

        await executeSchemaChange(sql)
    }

    private func dropColumn(_ column: ColumnInfo) async {
        guard let object = navigatorVM.selectedObject else { return }

        let sql = "ALTER TABLE \(quoteIdent(object.schema)).\(quoteIdent(object.name)) DROP COLUMN \(quoteIdent(column.name))"
        await executeSchemaChange(sql)
    }

    private func renameColumn(column: ColumnInfo, newName: String) async {
        guard let object = navigatorVM.selectedObject else { return }

        let sql = "ALTER TABLE \(quoteIdent(object.schema)).\(quoteIdent(object.name)) RENAME COLUMN \(quoteIdent(column.name)) TO \(quoteIdent(newName))"
        await executeSchemaChange(sql)
    }

    private func changeType(column: ColumnInfo, newType: String) async {
        guard let object = navigatorVM.selectedObject else { return }

        let sql = "ALTER TABLE \(quoteIdent(object.schema)).\(quoteIdent(object.name)) ALTER COLUMN \(quoteIdent(column.name)) TYPE \(newType) USING \(quoteIdent(column.name))::\(newType)"
        await executeSchemaChange(sql)
    }

    private func toggleNullable(column: ColumnInfo, nullable: Bool) async {
        guard let object = navigatorVM.selectedObject else { return }

        let action = nullable ? "DROP NOT NULL" : "SET NOT NULL"
        let sql = "ALTER TABLE \(quoteIdent(object.schema)).\(quoteIdent(object.name)) ALTER COLUMN \(quoteIdent(column.name)) \(action)"
        await executeSchemaChange(sql)
    }

    private func changeDefault(column: ColumnInfo, newDefault: String) async {
        guard let object = navigatorVM.selectedObject else { return }

        let action: String
        if newDefault.isEmpty {
            action = "DROP DEFAULT"
        } else {
            action = "SET DEFAULT \(newDefault)"
        }
        let sql = "ALTER TABLE \(quoteIdent(object.schema)).\(quoteIdent(object.name)) ALTER COLUMN \(quoteIdent(column.name)) \(action)"
        await executeSchemaChange(sql)
    }

    private func executeSchemaChange(_ sql: String) async {
        do {
            _ = try await appVM.dbClient.runQuery(sql, maxRows: 0, timeout: 10.0)
            // Invalidate column cache and reload
            await appVM.dbClient.invalidateCache()
            if let object = navigatorVM.selectedObject {
                let columns = try await appVM.dbClient.getColumns(
                    schema: object.schema,
                    table: object.name
                )
                tableVM.setColumns(columns)
                tableVM.selectedObjectColumnCount = columns.count
            }
        } catch {
            appVM.errorMessage = error.localizedDescription
        }
    }
}

// MARK: - Add Column Sheet

struct AddColumnSheet: View {
    let onAdd: (String, String, Bool, String) -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var dataType = "text"
    @State private var nullable = true
    @State private var defaultValue = ""

    private static let commonTypes = [
        "text", "varchar(255)", "integer", "bigint", "smallint",
        "boolean", "numeric", "numeric(10,2)", "real", "double precision",
        "date", "timestamp", "timestamptz", "time", "timetz",
        "uuid", "jsonb", "json", "bytea", "serial", "bigserial",
    ]

    var body: some View {
        VStack(spacing: 0) {
            Text("Add Column")
                .font(.headline)
                .padding()

            Form {
                TextField("Name:", text: $name)

                Picker("Type:", selection: $dataType) {
                    ForEach(Self.commonTypes, id: \.self) { type in
                        Text(type).tag(type)
                    }
                }
                .pickerStyle(.menu)

                TextField("Or custom type:", text: $dataType)
                    .font(.system(.body, design: .monospaced))

                Toggle("Nullable", isOn: $nullable)

                TextField("Default:", text: $defaultValue)
                    .font(.system(.body, design: .monospaced))
                    .help("SQL expression, e.g. 0, '', now(), gen_random_uuid()")
            }
            .padding()

            HStack {
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Add") {
                    onAdd(name.trimmingCharacters(in: .whitespaces), dataType, nullable, defaultValue.trimmingCharacters(in: .whitespaces))
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || dataType.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding()
        }
        .frame(width: 380)
    }
}

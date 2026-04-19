import SwiftUI

struct StructureTabView: View {
    @Environment(AppViewModel.self) var appVM
    @Environment(TableViewModel.self) var tableVM
    @Environment(NavigatorViewModel.self) var navigatorVM

    @State private var selectedColumnId: String?
    @State private var showAddColumn = false
    @State private var showCreateIndex = false
    @State private var dropConfirmColumn: ColumnInfo?
    @State private var dropConfirmIndex: IndexInfo?
    @State private var dropConfirmConstraint: ConstraintInfo?
    @State private var dropConfirmTrigger: TriggerInfo?

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
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        columnsSection
                        if isTable {
                            indexesSection
                            constraintsSection
                            triggersSection
                            if !tableVM.partitions.isEmpty {
                                partitionsSection
                            }
                        }
                    }
                    .padding(12)
                }
            }

            if isTable {
                Divider()
                toolbar
            }
        }
        .sheet(isPresented: $showAddColumn) {
            AddColumnSheet { name, dataType, nullable, defaultValue in
                Task { await appVM.addColumn(name: name, dataType: dataType, nullable: nullable, defaultValue: defaultValue) }
            }
        }
        .sheet(isPresented: $showCreateIndex) {
            if let object = navigatorVM.selectedObject {
                IndexCreateSheet(
                    schema: object.schema,
                    table: object.name,
                    availableColumns: tableVM.columns.map(\.name),
                    onCreate: { sql in
                        Task { await appVM.createIndex(sql: sql) }
                    }
                )
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
                    Task { await appVM.dropColumn(col.name) }
                }
            }
        } message: {
            Text("Column \"\(dropConfirmColumn?.name ?? "")\" and all its data will be permanently removed.")
        }
        .alert("Drop Index?", isPresented: .init(
            get: { dropConfirmIndex != nil },
            set: { if !$0 { dropConfirmIndex = nil } }
        )) {
            Button("Cancel", role: .cancel) { dropConfirmIndex = nil }
            Button("Drop", role: .destructive) {
                if let idx = dropConfirmIndex {
                    dropConfirmIndex = nil
                    Task { await appVM.dropIndex(idx) }
                }
            }
        } message: {
            Text("Index \"\(dropConfirmIndex?.name ?? "")\" will be permanently removed.")
        }
        .alert("Drop Constraint?", isPresented: .init(
            get: { dropConfirmConstraint != nil },
            set: { if !$0 { dropConfirmConstraint = nil } }
        )) {
            Button("Cancel", role: .cancel) { dropConfirmConstraint = nil }
            Button("Drop", role: .destructive) {
                if let c = dropConfirmConstraint {
                    dropConfirmConstraint = nil
                    Task { await appVM.dropConstraint(c) }
                }
            }
        } message: {
            Text("Constraint \"\(dropConfirmConstraint?.name ?? "")\" will be dropped.")
        }
        .alert("Drop Trigger?", isPresented: .init(
            get: { dropConfirmTrigger != nil },
            set: { if !$0 { dropConfirmTrigger = nil } }
        )) {
            Button("Cancel", role: .cancel) { dropConfirmTrigger = nil }
            Button("Drop", role: .destructive) {
                if let t = dropConfirmTrigger {
                    dropConfirmTrigger = nil
                    Task { await appVM.dropTrigger(t) }
                }
            }
        } message: {
            Text("Trigger \"\(dropConfirmTrigger?.name ?? "")\" will be dropped.")
        }
    }

    // MARK: - Columns Section

    private var columnsSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionHeader("Columns", count: tableVM.columns.count)
            Table(tableVM.columns, selection: $selectedColumnId) {
                TableColumn("#") { col in
                    Text("\(col.ordinalPosition)").monospacedDigit()
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
                                Task { await appVM.toggleColumnNullable(columnName: col.name, nullable: newValue) }
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
                        Text("\(len)").monospacedDigit()
                    } else {
                        Text("")
                    }
                }
                .width(min: 60, ideal: 80, max: 100)
            }
            .tableStyle(.bordered(alternatesRowBackgrounds: true))
            .frame(minHeight: 160, idealHeight: CGFloat(120 + tableVM.columns.count * 22))
        }
    }

    // MARK: - Indexes

    private var indexesSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                sectionHeader("Indexes", count: tableVM.indexes.count)
                Spacer()
                Button {
                    showCreateIndex = true
                } label: {
                    Label("Add Index", systemImage: "plus")
                        .labelStyle(.iconOnly)
                }
                .buttonStyle(.borderless)
                .help("Create a new index on this table")
            }
            if tableVM.indexes.isEmpty {
                Text("No indexes.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(tableVM.indexes) { idx in
                    indexRow(idx)
                }
            }
        }
    }

    @ViewBuilder
    private func indexRow(_ idx: IndexInfo) -> some View {
        HStack(alignment: .top) {
            Image(systemName: idx.isPrimary ? "key.fill" : (idx.isUnique ? "lock.fill" : "list.number"))
                .foregroundStyle(idx.isPrimary ? .yellow : (idx.isUnique ? .orange : .secondary))
                .font(.caption)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(idx.name).font(.callout.weight(.medium))
                    badgeText(idx.method.uppercased(), color: .blue)
                    if idx.isPrimary { badgeText("PRIMARY", color: .yellow) }
                    else if idx.isUnique { badgeText("UNIQUE", color: .orange) }
                    if idx.isPartial { badgeText("PARTIAL", color: .purple) }
                }
                Text(idx.columns.joined(separator: ", "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospaced()
            }
            Spacer()
            if !idx.isPrimary {
                Button {
                    dropConfirmIndex = idx
                } label: {
                    Image(systemName: "trash")
                        .foregroundStyle(.red)
                        .font(.caption)
                }
                .buttonStyle(.borderless)
                .help("Drop index")
            }
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 8)
        .background(Color(nsColor: .controlBackgroundColor))
        .cornerRadius(4)
    }

    // MARK: - Constraints

    private var constraintsSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionHeader("Constraints", count: tableVM.constraints.count)
            if tableVM.constraints.isEmpty {
                Text("No constraints.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(tableVM.constraints) { c in
                    HStack(alignment: .top) {
                        Image(systemName: constraintIcon(c.kind))
                            .foregroundStyle(constraintColor(c.kind))
                            .font(.caption)
                            .frame(width: 16)
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 6) {
                                Text(c.name).font(.callout.weight(.medium))
                                badgeText(c.kind.rawValue, color: constraintColor(c.kind))
                            }
                            Text(c.definition)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .monospaced()
                                .textSelection(.enabled)
                        }
                        Spacer()
                        if c.kind != .primaryKey {
                            Button {
                                dropConfirmConstraint = c
                            } label: {
                                Image(systemName: "trash")
                                    .foregroundStyle(.red)
                                    .font(.caption)
                            }
                            .buttonStyle(.borderless)
                            .help("Drop constraint")
                        }
                    }
                    .padding(.vertical, 4)
                    .padding(.horizontal, 8)
                    .background(Color(nsColor: .controlBackgroundColor))
                    .cornerRadius(4)
                }
            }
        }
    }

    // MARK: - Triggers

    private var triggersSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionHeader("Triggers", count: tableVM.triggers.count)
            if tableVM.triggers.isEmpty {
                Text("No triggers.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(tableVM.triggers) { t in
                    HStack(alignment: .top) {
                        Image(systemName: t.isDisabled ? "bolt.slash" : "bolt.fill")
                            .foregroundStyle(t.isDisabled ? Color.secondary : Color.orange)
                            .font(.caption)
                            .frame(width: 16)
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 6) {
                                Text(t.name).font(.callout.weight(.medium))
                                badgeText(t.timing, color: .purple)
                                badgeText(t.event, color: .blue)
                                if t.isDisabled { badgeText("DISABLED", color: .gray) }
                            }
                            Text(t.actionStatement)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .monospaced()
                                .lineLimit(2)
                                .textSelection(.enabled)
                        }
                        Spacer()
                        Button {
                            Task { await appVM.setTriggerEnabled(t, enabled: t.isDisabled) }
                        } label: {
                            Image(systemName: t.isDisabled ? "play.fill" : "pause.fill")
                                .font(.caption)
                        }
                        .buttonStyle(.borderless)
                        .help(t.isDisabled ? "Enable trigger" : "Disable trigger")
                        Button {
                            dropConfirmTrigger = t
                        } label: {
                            Image(systemName: "trash")
                                .foregroundStyle(.red)
                                .font(.caption)
                        }
                        .buttonStyle(.borderless)
                        .help("Drop trigger")
                    }
                    .padding(.vertical, 4)
                    .padding(.horizontal, 8)
                    .background(Color(nsColor: .controlBackgroundColor))
                    .cornerRadius(4)
                }
            }
        }
    }

    // MARK: - Partitions

    private var partitionsSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionHeader("Partitions", count: tableVM.partitions.count)
            ForEach(tableVM.partitions) { p in
                HStack(alignment: .top) {
                    Image(systemName: "rectangle.split.3x1")
                        .foregroundStyle(.secondary)
                        .font(.caption)
                        .frame(width: 16)
                    Text(p.name).font(.callout)
                    Spacer()
                }
                .padding(.vertical, 3)
                .padding(.horizontal, 8)
                .background(Color(nsColor: .controlBackgroundColor))
                .cornerRadius(4)
            }
        }
    }

    // MARK: - Helpers

    private func sectionHeader(_ title: String, count: Int) -> some View {
        HStack(spacing: 6) {
            Text(title).font(.headline)
            Text("(\(count))").font(.subheadline).foregroundStyle(.secondary)
        }
    }

    private func badgeText(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.system(size: 9, weight: .medium))
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(color.opacity(0.15))
            .foregroundStyle(color)
            .clipShape(.rect(cornerRadius: 3))
    }

    private func constraintIcon(_ kind: ConstraintInfo.Kind) -> String {
        switch kind {
        case .primaryKey: return "key.fill"
        case .foreignKey: return "link"
        case .unique: return "lock.fill"
        case .check: return "checkmark.shield"
        case .exclude: return "nosign"
        }
    }

    private func constraintColor(_ kind: ConstraintInfo.Kind) -> Color {
        switch kind {
        case .primaryKey: return .yellow
        case .foreignKey: return .blue
        case .unique: return .orange
        case .check: return .green
        case .exclude: return .red
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
                Task { await appVM.renameColumn(oldName: column.name, newName: newValue) }
            }
        case .type:
            if !newValue.isEmpty, newValue != column.dataType {
                Task { await appVM.changeColumnType(columnName: column.name, newType: newValue) }
            }
        case .defaultValue:
            let oldDefault = column.columnDefault ?? ""
            if newValue != oldDefault {
                Task { await appVM.changeColumnDefault(columnName: column.name, newDefault: newValue) }
            }
        }
    }

    private func cancelFieldEdit() {
        editingField = nil
        editingText = ""
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

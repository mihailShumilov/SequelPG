import SwiftUI

/// Columns, indexes, constraints, triggers, and partitions of the selected
/// relation. Tables are editable: double-click a column's name, type, or
/// default to change it; the checkbox toggles NOT NULL; the bottom bar adds
/// and drops columns.
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
            if let obj = navigatorVM.selectedObject, !tableVM.columns.isEmpty {
                header(for: obj)
                Divider()
                ScrollView {
                    VStack(alignment: .leading, spacing: 24) {
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
                    .padding(20)
                }
                if isTable {
                    bottomBar
                }
            } else if let obj = navigatorVM.selectedObject {
                ContentUnavailableView {
                    Label(obj.name, systemImage: obj.type.symbolName)
                } description: {
                    Text("A \(obj.type.displayName.lowercased()) has no columns to show. Open the Definition tab to see its source.")
                } actions: {
                    Button("Show Definition") { appVM.selectedTab = .definition }
                }
            } else {
                ContentUnavailableView {
                    Label("No Table Selected", systemImage: "tablecells")
                } description: {
                    Text("Choose a table or view in the sidebar to see its columns, indexes, constraints, and triggers.")
                }
            }
        }
        .background(Theme.bg)
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
            Text("Column \u{201C}\(dropConfirmColumn?.name ?? "")\u{201D} and all its data will be permanently removed.")
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
            Text("Index \u{201C}\(dropConfirmIndex?.name ?? "")\u{201D} will be permanently removed.")
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
            Text("Constraint \u{201C}\(dropConfirmConstraint?.name ?? "")\u{201D} will be dropped.")
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
            Text("Trigger \u{201C}\(dropConfirmTrigger?.name ?? "")\u{201D} will be dropped.")
        }
    }

    // MARK: - Header

    private func header(for obj: DBObject) -> some View {
        HStack(spacing: 10) {
            Image(systemName: obj.type.symbolName)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(obj.name)
                    .font(.headline)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text("\(obj.type.displayName) in \(obj.schema)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            HStack(spacing: 12) {
                if obj.type.hasQueryableContent {
                    Text("≈ \(tableVM.approximateRowCount.formatted()) rows")
                }
                Text("\(tableVM.columns.count) columns")
                if !tableVM.partitions.isEmpty {
                    Text("partitioned")
                }
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.bar)
    }

    // MARK: - Columns Section

    private var columnsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionHeader("Columns", count: tableVM.columns.count) {
                if isTable {
                    Text("Double-click a name, type, or default to edit")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Table(tableVM.columns, selection: $selectedColumnId) {
                TableColumn("#") { col in
                    Text("\(col.ordinalPosition)")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                .width(min: 28, ideal: 36, max: 44)

                TableColumn("Name") { col in
                    HStack(spacing: 4) {
                        if col.isPrimaryKey {
                            Image(systemName: "key.fill")
                                .font(.caption2)
                                .foregroundStyle(Theme.amber)
                                .help("Primary key")
                        }
                        editableCell(column: col, field: .name, value: col.name)
                    }
                }
                .width(min: 120, ideal: 200)

                TableColumn("Type") { col in
                    editableCell(column: col, field: .type, value: col.dataType)
                }
                .width(min: 100, ideal: 150)

                TableColumn("Nullable") { col in
                    if isTable {
                        Toggle("Nullable", isOn: Binding(
                            get: { col.isNullable },
                            set: { newValue in
                                Task { await appVM.toggleColumnNullable(columnName: col.name, nullable: newValue) }
                            }
                        ))
                        .toggleStyle(.checkbox)
                        .labelsHidden()
                        .help(col.isNullable ? "Allows NULL — click to add NOT NULL" : "NOT NULL — click to allow NULL")
                    } else {
                        Text(col.isNullable ? "Yes" : "No")
                            .foregroundStyle(.secondary)
                    }
                }
                .width(min: 56, ideal: 64, max: 80)

                TableColumn("Default") { col in
                    editableCell(column: col, field: .defaultValue, value: col.columnDefault ?? "")
                }
                .width(min: 100, ideal: 180)

                TableColumn("Length") { col in
                    if let len = col.characterMaximumLength {
                        Text("\(len)")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    } else {
                        Text("")
                    }
                }
                .width(min: 50, ideal: 60, max: 80)
            }
            .tableStyle(.bordered(alternatesRowBackgrounds: true))
            // Cap ideal height so wide tables (hundreds of columns) don't ask
            // SwiftUI Table to render every row up-front.
            .frame(minHeight: 160, idealHeight: CGFloat(min(120 + tableVM.columns.count * 24, 600)))
            .contextMenu(forSelectionType: String.self) { ids in
                if isTable, let id = ids.first, let col = tableVM.columns.first(where: { $0.id == id }) {
                    Button("Drop Column \u{201C}\(col.name)\u{201D}…", role: .destructive) {
                        dropConfirmColumn = col
                    }
                }
            }
        }
    }

    // MARK: - Indexes

    private var indexesSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            SectionHeader("Indexes", count: tableVM.indexes.count) {
                Button {
                    showCreateIndex = true
                } label: {
                    Label("New Index", systemImage: "plus")
                }
                .controlSize(.small)
                .help("Create a new index on this table")
            }
            if tableVM.indexes.isEmpty {
                emptyNote("No indexes.")
            } else {
                VStack(spacing: 0) {
                    ForEach(tableVM.indexes) { idx in
                        indexRow(idx)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func indexRow(_ idx: IndexInfo) -> some View {
        detailRow(
            icon: idx.isPrimary ? "key.fill" : (idx.isUnique ? "lock.fill" : "list.number"),
            iconColor: idx.isPrimary || idx.isUnique ? Theme.amber : .secondary,
            title: idx.name,
            subtitle: idx.columns.joined(separator: ", "),
            tags: {
                Tag(idx.method, color: Theme.blue)
                if idx.isPrimary { Tag("primary", color: Theme.amber) } else if idx.isUnique { Tag("unique", color: Theme.amber) }
                if idx.isPartial { Tag("partial", color: Theme.mauve) }
            },
            trailing: {
                if !idx.isPrimary {
                    dropButton("Drop index") { dropConfirmIndex = idx }
                }
            }
        )
    }

    // MARK: - Constraints

    private var constraintsSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            SectionHeader("Constraints", count: tableVM.constraints.count)
            if tableVM.constraints.isEmpty {
                emptyNote("No constraints.")
            } else {
                VStack(spacing: 0) {
                    ForEach(tableVM.constraints) { c in
                        detailRow(
                            icon: constraintIcon(c.kind),
                            iconColor: constraintColor(c.kind),
                            title: c.name,
                            subtitle: c.definition,
                            tags: { Tag(c.kind.rawValue, color: constraintColor(c.kind)) },
                            trailing: {
                                if c.kind != .primaryKey {
                                    dropButton("Drop constraint") { dropConfirmConstraint = c }
                                }
                            }
                        )
                    }
                }
            }
        }
    }

    // MARK: - Triggers

    private var triggersSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            SectionHeader("Triggers", count: tableVM.triggers.count)
            if tableVM.triggers.isEmpty {
                emptyNote("No triggers.")
            } else {
                VStack(spacing: 0) {
                    ForEach(tableVM.triggers) { t in
                        detailRow(
                            icon: t.isDisabled ? "bolt.slash" : "bolt.fill",
                            iconColor: t.isDisabled ? .secondary : Theme.amber,
                            title: t.name,
                            subtitle: t.actionStatement,
                            tags: {
                                Tag(t.timing, color: .secondary)
                                Tag(t.event, color: Theme.rose)
                                if t.isDisabled { Tag("disabled", color: .secondary) }
                            },
                            trailing: {
                                Button {
                                    Task { await appVM.setTriggerEnabled(t, enabled: t.isDisabled) }
                                } label: {
                                    Image(systemName: t.isDisabled ? "play.fill" : "pause.fill")
                                }
                                .buttonStyle(.borderless)
                                .help(t.isDisabled ? "Enable trigger" : "Disable trigger")
                                dropButton("Drop trigger") { dropConfirmTrigger = t }
                            }
                        )
                    }
                }
            }
        }
    }

    // MARK: - Partitions

    private var partitionsSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            SectionHeader("Partitions", count: tableVM.partitions.count)
            VStack(spacing: 0) {
                ForEach(tableVM.partitions) { p in
                    detailRow(
                        icon: "rectangle.split.3x1",
                        iconColor: .secondary,
                        title: p.name,
                        subtitle: nil,
                        tags: { EmptyView() },
                        trailing: { EmptyView() }
                    )
                }
            }
        }
    }

    // MARK: - Row helpers

    private func emptyNote(_ text: String) -> some View {
        Text(text)
            .font(.callout)
            .foregroundStyle(.secondary)
            .padding(.vertical, 6)
    }

    private func detailRow<Tags: View, Trailing: View>(
        icon: String,
        iconColor: Color,
        title: String,
        subtitle: String?,
        @ViewBuilder tags: () -> Tags,
        @ViewBuilder trailing: () -> Trailing
    ) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .foregroundStyle(iconColor)
                .font(.system(size: 12))
                .frame(width: 18)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(title)
                        .font(.system(.body, design: .monospaced).weight(.medium))
                        .textSelection(.enabled)
                    tags()
                }
                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.system(.callout, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                        .textSelection(.enabled)
                }
            }
            Spacer(minLength: 0)
            HStack(spacing: 8) {
                trailing()
            }
            .controlSize(.small)
        }
        .padding(.vertical, 8)
        .overlay(alignment: .bottom) { Divider() }
    }

    private func dropButton(_ help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: "trash")
        }
        .buttonStyle(.borderless)
        .help(help)
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
        case .primaryKey: return Theme.amber
        case .foreignKey: return Theme.cyan
        case .unique: return Theme.amber
        case .check: return .green
        case .exclude: return Theme.rose
        }
    }

    // MARK: - Bottom bar

    private var bottomBar: some View {
        BottomBar {
            Button {
                showAddColumn = true
            } label: {
                Image(systemName: "plus")
            }
            .help("Add a column")
            .accessibilityLabel("Add column")

            Button {
                if let id = selectedColumnId,
                   let col = tableVM.columns.first(where: { $0.id == id })
                {
                    dropConfirmColumn = col
                }
            } label: {
                Image(systemName: "minus")
            }
            .disabled(selectedColumnId == nil)
            .help("Drop the selected column")
            .accessibilityLabel("Drop column")

            Spacer()
        }
        .buttonStyle(.borderless)
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
                .font(.system(.body, design: .monospaced))
                .foregroundStyle(field == .defaultValue && value.isEmpty ? .tertiary : .primary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                // Double-click to edit: a single click selects the row, as in
                // every other macOS table, so a stray click can't start an
                // ALTER TABLE.
                .onTapGesture(count: 2) {
                    guard isTable else { return }
                    if let prev = editingField,
                       let prevCol = tableVM.columns.first(where: { $0.name == prev.columnName })
                    {
                        commitFieldEdit(column: prevCol, field: prev.field)
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

    private var canAdd: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty && !dataType.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var body: some View {
        VStack(spacing: 0) {
            Text("Add Column")
                .font(.headline)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 20)
                .padding(.top, 18)

            Form {
                TextField("Name", text: $name)
                    .font(.system(.body, design: .monospaced))
                LabeledContent("Type") {
                    SuggestingTextField(label: "type", text: $dataType, suggestions: PGTypeSuggestions.column)
                }
                Toggle("Allows NULL", isOn: $nullable)
                TextField("Default", text: $defaultValue, prompt: Text("expression, e.g. now()"))
                    .font(.system(.body, design: .monospaced))
            }
            .formStyle(.grouped)
            .frame(height: 210)

            SheetButtonBar(confirmTitle: "Add", confirmDisabled: !canAdd) {
                dismiss()
            } onConfirm: {
                onAdd(
                    name.trimmingCharacters(in: .whitespaces),
                    dataType.trimmingCharacters(in: .whitespaces),
                    nullable,
                    defaultValue.trimmingCharacters(in: .whitespaces)
                )
                dismiss()
            }
        }
        .frame(width: 440)
    }
}

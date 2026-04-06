import SwiftUI

struct NavigatorView: View {
    @Environment(AppViewModel.self) var appVM
    @Environment(NavigatorViewModel.self) var navigatorVM

    @State private var showCreateDatabase = false
    @State private var showCreateSchema = false
    @State private var showCreateTable = false
    @State private var createTableSchema = ""

    @State private var showCreateView = false
    @State private var showCreateFunction = false
    @State private var showCreateSequence = false
    @State private var showCreateType = false
    @State private var showCreateDomain = false
    @State private var showCreateMatView = false
    @State private var showCreateGeneric: ObjectCategory?
    @State private var dropTarget: DBObject?
    @State private var showDropConfirmation = false
    @State private var createSchema = ""

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            treeList
        }
        .sheet(isPresented: $showCreateDatabase) {
            CreateDatabaseSheet { name in
                Task { await appVM.createDatabase(name: name) }
            }
        }
        .sheet(isPresented: $showCreateSchema) {
            CreateSchemaSheet { name in
                Task { await appVM.createSchema(name: name) }
            }
        }
        .sheet(isPresented: $showCreateTable) {
            CreateTableSheet(schema: createTableSchema) { name, columns in
                Task { await appVM.createTable(schema: createTableSchema, name: name, columns: columns) }
            }
        }
        .sheet(isPresented: $showCreateView) {
            CreateViewSheet(schema: createSchema) { sql in
                Task { await appVM.executeCreateSQL(sql, inSchema: createSchema) }
            }
        }
        .sheet(isPresented: $showCreateMatView) {
            CreateMaterializedViewSheet(schema: createSchema) { sql in
                Task { await appVM.executeCreateSQL(sql, inSchema: createSchema) }
            }
        }
        .sheet(isPresented: $showCreateFunction) {
            CreateFunctionSheet(schema: createSchema) { sql in
                Task { await appVM.executeCreateSQL(sql, inSchema: createSchema) }
            }
        }
        .sheet(isPresented: $showCreateSequence) {
            CreateSequenceSheet(schema: createSchema) { sql in
                Task { await appVM.executeCreateSQL(sql, inSchema: createSchema) }
            }
        }
        .sheet(isPresented: $showCreateType) {
            CreateTypeSheet(schema: createSchema) { sql in
                Task { await appVM.executeCreateSQL(sql, inSchema: createSchema) }
            }
        }
        .sheet(isPresented: $showCreateDomain) {
            CreateDomainSheet(schema: createSchema) { sql in
                Task { await appVM.executeCreateSQL(sql, inSchema: createSchema) }
            }
        }
        .sheet(item: $showCreateGeneric) { category in
            GenericCreateSheet(title: category.rawValue, schema: createSchema) { sql in
                Task { await appVM.executeCreateSQL(sql, inSchema: createSchema) }
            }
        }
        .alert("Drop Object?", isPresented: $showDropConfirmation, presenting: dropTarget) { obj in
            Button("Cancel", role: .cancel) { dropTarget = nil }
            Button("Drop", role: .destructive) {
                let target = obj
                dropTarget = nil
                Task { await appVM.dropObject(target) }
            }
        } message: { obj in
            Text("\"\(obj.name)\" will be permanently dropped.")
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            Text("Navigator")
                .font(.headline)
            Spacer()

            Menu {
                Button("New Database...") { showCreateDatabase = true }
                Button("New Schema...") { showCreateSchema = true }
            } label: {
                Image(systemName: "plus")
            }
            .menuStyle(.borderlessButton)
            .frame(width: 20)
            .help("Create database or schema")

            Button {
                Task { await appVM.refreshNavigator() }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Refresh navigator")
            .help("Refresh")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    // MARK: - Tree List

    private var treeList: some View {
        @Bindable var navigatorVM = navigatorVM
        return List(selection: Binding<DBObject?>(
            get: { navigatorVM.selectedObject },
            set: { obj in
                if let obj { Task { await appVM.selectObject(obj) } }
            }
        )) {
            ForEach(navigatorVM.databases, id: \.self) { db in
                databaseNode(db)
            }
        }
        .listStyle(.sidebar)
    }

    // MARK: - Database Node

    @ViewBuilder
    private func databaseNode(_ db: String) -> some View {
        let isConnected = db == navigatorVM.connectedDatabase
        let schemas = navigatorVM.schemas(for: db)
        DisclosureGroup(
            isExpanded: dbExpansionBinding(db)
        ) {
            if schemas.isEmpty, navigatorVM.hasSchemasLoaded(for: db) {
                Text("No schemas")
                    .foregroundStyle(.tertiary)
                    .font(.caption)
            } else {
                ForEach(schemas, id: \.self) { schema in
                    schemaNode(db: db, schema: schema)
                }
            }
        } label: {
            Label {
                Text(db)
                    .fontWeight(isConnected ? .medium : .regular)
            } icon: {
                Image(systemName: "cylinder.split.1x2")
                    .foregroundStyle(isConnected ? .green : .secondary)
            }
            .contentShape(Rectangle())
            .onTapGesture {
                if !isConnected {
                    Task { await appVM.switchDatabase(db) }
                }
            }
            .contextMenu {
                if !isConnected {
                    Button("Switch to \(db)") {
                        Task { await appVM.switchDatabase(db) }
                    }
                }
            }
        }
    }

    private func dbExpansionBinding(_ db: String) -> Binding<Bool> {
        Binding(
            get: { appVM.navigatorVM.isDatabaseExpanded(db) },
            set: { expanded in
                appVM.navigatorVM.setDatabaseExpanded(db, expanded)
                if expanded, !appVM.navigatorVM.hasSchemasLoaded(for: db) {
                    Task { await appVM.loadDatabaseSchemas(db) }
                }
            }
        )
    }

    // MARK: - Schema Node

    @ViewBuilder
    private func schemaNode(db: String, schema: String) -> some View {
        DisclosureGroup(
            isExpanded: schemaExpansionBinding(db, schema)
        ) {
            ForEach(navigatorVM.availableCategories, id: \.self) { category in
                categoryNode(db: db, schema: schema, category: category)
            }
        } label: {
            Label(schema, systemImage: "folder")
                .contextMenu {
                    Button("New Table...") {
                        createTableSchema = schema
                        showCreateTable = true
                    }
                    Button("New View...") {
                        createSchema = schema
                        showCreateView = true
                    }
                    Button("New Function...") {
                        createSchema = schema
                        showCreateFunction = true
                    }
                    Button("New Sequence...") {
                        createSchema = schema
                        showCreateSequence = true
                    }
                    Button("New Type...") {
                        createSchema = schema
                        showCreateType = true
                    }
                }
        }
    }

    private func schemaExpansionBinding(_ db: String, _ schema: String) -> Binding<Bool> {
        Binding(
            get: { appVM.navigatorVM.isSchemaExpanded(db, schema) },
            set: { expanded in
                appVM.navigatorVM.setSchemaExpanded(db, schema, expanded)
                if expanded {
                    Task { await appVM.loadSchemaObjects(db: db, schema: schema) }
                }
            }
        )
    }

    // MARK: - Category Node — always shown

    @ViewBuilder
    private func categoryNode(db: String, schema: String, category: ObjectCategory) -> some View {
        let objects = navigatorVM.objects(for: db, schema: schema, category: category)

        DisclosureGroup(
            isExpanded: categoryExpansionBinding(db, schema, category)
        ) {
            ForEach(objects) { obj in
                Label(obj.name, systemImage: category.icon)
                    .tag(obj)
                    .contextMenu {
                        Button("Drop \(obj.name)...", role: .destructive) {
                            dropTarget = obj
                            showDropConfirmation = true
                        }
                    }
            }
            if let action = createAction(for: category, schema: schema) {
                Button {
                    action()
                } label: {
                    Label("New \(createLabel(for: category))...", systemImage: "plus")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        } label: {
            Label {
                HStack {
                    Text(category.rawValue)
                    Text("(\(objects.count))")
                        .foregroundStyle(.secondary)
                        .font(.caption)
                }
            } icon: {
                Image(systemName: category.icon)
            }
        }
    }

    private func categoryExpansionBinding(_ db: String, _ schema: String, _ category: ObjectCategory) -> Binding<Bool> {
        Binding(
            get: { appVM.navigatorVM.isCategoryExpanded(db, schema, category) },
            set: { appVM.navigatorVM.setCategoryExpanded(db, schema, category, $0) }
        )
    }

    // MARK: - Create Action Helpers

    private func createLabel(for category: ObjectCategory) -> String {
        switch category {
        case .tables: return "Table"
        case .views: return "View"
        case .materializedViews: return "Materialized View"
        case .functions: return "Function"
        case .sequences: return "Sequence"
        case .types: return "Type"
        case .domains: return "Domain"
        default: return category.rawValue
        }
    }

    private func createAction(for category: ObjectCategory, schema: String) -> (() -> Void)? {
        switch category {
        case .tables:
            return {
                createTableSchema = schema
                showCreateTable = true
            }
        case .views:
            return {
                createSchema = schema
                showCreateView = true
            }
        case .materializedViews:
            return {
                createSchema = schema
                showCreateMatView = true
            }
        case .functions, .triggerFunctions:
            return {
                createSchema = schema
                showCreateFunction = true
            }
        case .sequences:
            return {
                createSchema = schema
                showCreateSequence = true
            }
        case .types:
            return {
                createSchema = schema
                showCreateType = true
            }
        case .domains:
            return {
                createSchema = schema
                showCreateDomain = true
            }
        case .collations, .ftsConfigurations, .ftsDictionaries, .ftsParsers, .ftsTemplates,
             .foreignTables, .operators, .aggregates, .procedures:
            return {
                createSchema = schema
                showCreateGeneric = category
            }
        }
    }

}

// MARK: - Column definition for new table

struct NewColumnDef: Identifiable {
    let id = UUID()
    var name: String
    var dataType: String
    var isNullable: Bool
    var isPrimaryKey: Bool
    var defaultValue: String
}

// MARK: - Create Database Sheet

struct CreateDatabaseSheet: View {
    let onCreate: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""

    var body: some View {
        VStack(spacing: 0) {
            Text("Create Database")
                .font(.headline)
                .padding()
            Form {
                TextField("Database name:", text: $name)
            }
            .padding()
            HStack {
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Create") {
                    onCreate(name.trimmingCharacters(in: .whitespaces))
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding()
        }
        .frame(width: 340)
    }
}

// MARK: - Create Schema Sheet

struct CreateSchemaSheet: View {
    let onCreate: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""

    var body: some View {
        VStack(spacing: 0) {
            Text("Create Schema")
                .font(.headline)
                .padding()
            Form {
                TextField("Schema name:", text: $name)
            }
            .padding()
            HStack {
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Create") {
                    onCreate(name.trimmingCharacters(in: .whitespaces))
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding()
        }
        .frame(width: 340)
    }
}

// MARK: - Create Table Sheet

struct CreateTableSheet: View {
    let schema: String
    let onCreate: (String, [NewColumnDef]) -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var tableName = ""
    @State private var columns: [NewColumnDef] = [
        NewColumnDef(name: "id", dataType: "bigserial", isNullable: false, isPrimaryKey: true, defaultValue: ""),
    ]

    private static let commonTypes = [
        "text", "varchar(255)", "integer", "bigint", "smallint",
        "boolean", "numeric", "numeric(10,2)", "real", "double precision",
        "date", "timestamp", "timestamptz", "uuid", "jsonb", "json",
        "bytea", "serial", "bigserial",
    ]

    var body: some View {
        VStack(spacing: 0) {
            Text("Create Table in \"\(schema)\"")
                .font(.headline)
                .padding()

            Form {
                TextField("Table name:", text: $tableName)
            }
            .padding(.horizontal)

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Columns")
                        .font(.subheadline.weight(.medium))
                    Spacer()
                    Button {
                        columns.append(NewColumnDef(name: "", dataType: "text", isNullable: true, isPrimaryKey: false, defaultValue: ""))
                    } label: {
                        Image(systemName: "plus")
                    }
                    .buttonStyle(.borderless)
                }
                .padding(.horizontal)

                ScrollView {
                    VStack(spacing: 8) {
                        ForEach($columns) { $col in
                            columnRow(col: $col)
                        }
                    }
                    .padding(.horizontal)
                }
                .frame(minHeight: 120, maxHeight: 300)
            }
            .padding(.vertical, 8)

            HStack {
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Create") {
                    let validColumns = columns.filter { !$0.name.trimmingCharacters(in: .whitespaces).isEmpty }
                    onCreate(tableName.trimmingCharacters(in: .whitespaces), validColumns)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(tableName.trimmingCharacters(in: .whitespaces).isEmpty || columns.allSatisfy { $0.name.trimmingCharacters(in: .whitespaces).isEmpty })
            }
            .padding()
        }
        .frame(width: 520)
        .frame(minHeight: 400)
    }

    private func columnRow(col: Binding<NewColumnDef>) -> some View {
        HStack(spacing: 6) {
            TextField("name", text: col.name)
                .frame(minWidth: 80)

            Picker("", selection: col.dataType) {
                ForEach(Self.commonTypes, id: \.self) { type in
                    Text(type).tag(type)
                }
            }
            .frame(width: 140)

            Toggle("PK", isOn: col.isPrimaryKey)
                .toggleStyle(.checkbox)

            Toggle("Null", isOn: col.isNullable)
                .toggleStyle(.checkbox)
                .disabled(col.isPrimaryKey.wrappedValue)

            TextField("default", text: col.defaultValue)
                .frame(minWidth: 60, maxWidth: 100)
                .font(.system(.body, design: .monospaced))

            Button {
                columns.removeAll { $0.id == col.id }
            } label: {
                Image(systemName: "trash")
                    .foregroundStyle(.red)
            }
            .buttonStyle(.borderless)
            .disabled(columns.count <= 1)
        }
    }
}

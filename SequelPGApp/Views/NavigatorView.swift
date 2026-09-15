import SwiftUI

/// Sidebar: the database → schema → category → object tree, with a filter
/// field and creation menu in a bottom bar (Xcode-style). Selection drives
/// the main area; context menus expose create / run / maintenance / drop.
struct NavigatorView: View {
    @Environment(AppViewModel.self) var appVM
    @Environment(NavigatorViewModel.self) var navigatorVM

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
    @State private var maintenanceTarget: (op: AppViewModel.MaintenanceOp, object: DBObject)?
    @State private var showMaintenanceConfirmation = false

    var body: some View {
        @Bindable var appVM = appVM
        VStack(spacing: 0) {
            treeList
            Divider()
            bottomBar
        }
        .sheet(isPresented: $appVM.showCreateDatabaseSheet) {
            NameInputSheet(title: "New Database", fieldLabel: "Name") { name in
                Task { await appVM.createDatabase(name: name) }
            }
        }
        .sheet(isPresented: $appVM.showCreateSchemaSheet) {
            NameInputSheet(title: "New Schema", fieldLabel: "Name") { name in
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
        .sheet(item: $appVM.functionRunTarget) { target in
            FunctionRunSheet(object: target)
                .environment(appVM)
        }
        .alert("Drop Object?", isPresented: $showDropConfirmation, presenting: dropTarget) { obj in
            Button("Cancel", role: .cancel) { dropTarget = nil }
            Button("Drop", role: .destructive) {
                let target = obj
                dropTarget = nil
                Task { await appVM.dropObject(target) }
            }
        } message: { obj in
            Text("\u{201C}\(obj.name)\u{201D} will be permanently dropped.")
        }
        .alert(
            "Run \(maintenanceTarget?.op.rawValue ?? "Operation")?",
            isPresented: $showMaintenanceConfirmation,
            presenting: maintenanceTarget
        ) { target in
            Button("Cancel", role: .cancel) { maintenanceTarget = nil }
            Button(target.op.rawValue, role: .destructive) {
                let captured = target
                maintenanceTarget = nil
                Task { await appVM.runMaintenance(captured.op, on: captured.object) }
            }
        } message: { target in
            Text(target.op.confirmationMessage ?? "Continue?")
        }
    }

    /// Verb shown on the navigator context menu when the user can invoke the
    /// selected routine. Mirrors PG terminology — functions are SELECTed, but
    /// procedures are CALLed.
    private func runMenuLabel(for object: DBObject) -> String {
        switch object.type {
        case .procedure: return "Call \(object.name)…"
        default: return "Run \(object.name)…"
        }
    }

    /// Whether this object type supports maintenance commands (VACUUM/ANALYZE/TRUNCATE/REFRESH).
    private func maintenanceOps(for object: DBObject) -> [AppViewModel.MaintenanceOp] {
        switch object.type {
        case .table:
            return [.truncate, .vacuum, .vacuumFull, .analyze]
        case .materializedView:
            return [.refreshMatView, .refreshMatViewConcurrently, .vacuum, .analyze]
        default:
            return []
        }
    }

    private func triggerMaintenance(_ op: AppViewModel.MaintenanceOp, on object: DBObject) {
        if op.confirmationMessage != nil {
            maintenanceTarget = (op, object)
            showMaintenanceConfirmation = true
        } else {
            Task { await appVM.runMaintenance(op, on: object) }
        }
    }

    // MARK: - Bottom bar

    private var bottomBar: some View {
        @Bindable var navigatorVM = navigatorVM
        return HStack(spacing: 6) {
            SearchField(text: $navigatorVM.filterText, prompt: "Filter")
                .frame(maxWidth: .infinity)

            Menu {
                Button("New Database…") { appVM.showCreateDatabaseSheet = true }
                Button("New Schema…") { appVM.showCreateSchemaSheet = true }
                if let schema = navigatorVM.selectedObject?.schema {
                    Divider()
                    Button("New Table in \(schema)…") {
                        createTableSchema = schema
                        showCreateTable = true
                    }
                }
            } label: {
                Image(systemName: "plus")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Create a database, schema, or table")
            .accessibilityLabel("Create")

            Menu {
                Toggle("Show Advanced Objects", isOn: Binding(
                    get: { navigatorVM.complexity == .advanced },
                    set: { navigatorVM.complexity = $0 ? .advanced : .simple }
                ))
                Divider()
                Button("Refresh") { Task { await appVM.refreshNavigator() } }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Sidebar options")
            .accessibilityLabel("Sidebar options")
        }
        .controlSize(.small)
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(.bar)
    }

    // MARK: - Tree List

    private var treeList: some View {
        List(selection: Binding<DBObject?>(
            get: { navigatorVM.selectedObject },
            set: { obj in
                guard let obj, obj != navigatorVM.selectedObject else { return }
                // Apply the selection synchronously so the List's `get` reads
                // the new value on its next pass. Without this, the brief gap
                // before the async Task runs makes SwiftUI think the selection
                // bounced back to the old value and collapse the surrounding
                // DisclosureGroups. Catalog queries still happen async.
                navigatorVM.selectedObject = obj
                Task { await appVM.selectObject(obj) }
            }
        )) {
            ForEach(navigatorVM.databases, id: \.self) { db in
                databaseNode(db)
            }
        }
        .listStyle(.sidebar)
        .transaction { $0.animation = nil }
    }

    // MARK: - Database Node

    @ViewBuilder
    private func databaseNode(_ db: String) -> some View {
        let isConnected = db == navigatorVM.connectedDatabase
        let schemas = navigatorVM.schemas(for: db)
        let binding = dbExpansionBinding(db)
        DisclosureGroup(isExpanded: binding) {
            if schemas.isEmpty, !navigatorVM.hasSchemasLoaded(for: db) {
                HStack(spacing: 6) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Loading…")
                        .foregroundStyle(.secondary)
                }
            } else if schemas.isEmpty {
                Text("No schemas")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(schemas, id: \.self) { schema in
                    schemaNode(db: db, schema: schema)
                }
            }
        } label: {
            Label {
                Text(db)
                    .fontWeight(isConnected ? .semibold : .regular)
            } icon: {
                Image(systemName: "cylinder.split.1x2")
                    .foregroundStyle(isConnected ? Color.accentColor : Color.secondary)
            }
            .contentShape(Rectangle())
            .onTapGesture(count: 2) {
                if !isConnected { Task { await appVM.switchDatabase(db) } }
            }
            .onTapGesture { binding.wrappedValue.toggle() }
            .help(isConnected ? "Connected database" : "Double-click to switch to this database")
            .contextMenu {
                if !isConnected {
                    Button("Switch to \(db)") {
                        Task { await appVM.switchDatabase(db) }
                    }
                }
                Button("New Schema…") { appVM.showCreateSchemaSheet = true }
                    .disabled(!isConnected)
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
        let binding = schemaExpansionBinding(db, schema)
        DisclosureGroup(isExpanded: binding) {
            // Core categories always visible
            ForEach(navigatorVM.coreCategories, id: \.self) { category in
                categoryNode(db: db, schema: schema, category: category)
            }

            // Advanced categories: shown inline in advanced mode, grouped in simple mode
            if navigatorVM.complexity == .advanced {
                ForEach(navigatorVM.advancedCategories, id: \.self) { category in
                    categoryNode(db: db, schema: schema, category: category)
                }
            } else if !navigatorVM.advancedCategories.isEmpty, !navigatorVM.isFiltering {
                DisclosureGroup("More") {
                    ForEach(navigatorVM.advancedCategories, id: \.self) { category in
                        categoryNode(db: db, schema: schema, category: category)
                    }
                }
            } else if navigatorVM.isFiltering {
                ForEach(navigatorVM.advancedCategories, id: \.self) { category in
                    categoryNode(db: db, schema: schema, category: category)
                }
            }
        } label: {
            Label(schema, systemImage: "folder")
                .contentShape(Rectangle())
                .onTapGesture { binding.wrappedValue.toggle() }
                .contextMenu {
                    Button("New Table…") {
                        createTableSchema = schema
                        showCreateTable = true
                    }
                    Button("New View…") {
                        createSchema = schema
                        showCreateView = true
                    }
                    Button("New Materialized View…") {
                        createSchema = schema
                        showCreateMatView = true
                    }
                    Button("New Function…") {
                        createSchema = schema
                        showCreateFunction = true
                    }
                    Button("New Sequence…") {
                        createSchema = schema
                        showCreateSequence = true
                    }
                    Button("New Type…") {
                        createSchema = schema
                        showCreateType = true
                    }
                    Button("New Domain…") {
                        createSchema = schema
                        showCreateDomain = true
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

    // MARK: - Category Node

    @ViewBuilder
    private func categoryNode(db: String, schema: String, category: ObjectCategory) -> some View {
        let isFiltering = navigatorVM.isFiltering
        let objects = navigatorVM.filteredObjects(for: db, schema: schema, category: category)
        // While filtering, categories without a match disappear and the rest
        // are forced open so matches are visible without clicking around.
        if isFiltering, objects.isEmpty {
            EmptyView()
        } else {
            let binding = isFiltering
                ? Binding<Bool>(get: { true }, set: { _ in })
                : categoryExpansionBinding(db, schema, category)

            DisclosureGroup(isExpanded: binding) {
                ForEach(objects) { obj in
                    Label(obj.name, systemImage: category.icon)
                        .tag(obj)
                        .contextMenu {
                            if appVM.isRunnable(obj) {
                                Button(runMenuLabel(for: obj)) {
                                    appVM.functionRunTarget = obj
                                }
                                Divider()
                            }
                            let ops = maintenanceOps(for: obj)
                            if !ops.isEmpty {
                                ForEach(ops) { op in
                                    Button(op.rawValue) {
                                        triggerMaintenance(op, on: obj)
                                    }
                                }
                                Divider()
                            }
                            Button("Drop \(obj.name)…", role: .destructive) {
                                dropTarget = obj
                                showDropConfirmation = true
                            }
                        }
                }
                if !isFiltering, let action = createAction(for: category, schema: schema) {
                    Button {
                        action()
                    } label: {
                        Label("New \(createLabel(for: category))…", systemImage: "plus")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            } label: {
                Label {
                    HStack {
                        Text(category.rawValue)
                        Spacer(minLength: 4)
                        Text("\(objects.count)")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(
                        "\(category.rawValue), \(objects.count) \(objects.count == 1 ? "object" : "objects")"
                    )
                } icon: {
                    Image(systemName: category.icon)
                }
                .contentShape(Rectangle())
                .onTapGesture { binding.wrappedValue.toggle() }
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

// MARK: - Reusable Name Input Sheet (Create Database / Create Schema)

struct NameInputSheet: View {
    let title: String
    let fieldLabel: String
    let onCreate: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""

    private var trimmed: String { name.trimmingCharacters(in: .whitespaces) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title)
                .font(.headline)
            TextField(fieldLabel, text: $name, prompt: Text("identifier"))
                .textFieldStyle(.roundedBorder)
                .font(.system(.body, design: .monospaced))
                .onSubmit {
                    guard !trimmed.isEmpty else { return }
                    onCreate(trimmed)
                    dismiss()
                }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Create") {
                    onCreate(trimmed)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(trimmed.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 380)
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

    private var canCreate: Bool {
        !tableName.trimmingCharacters(in: .whitespaces).isEmpty
            && columns.contains { !$0.name.trimmingCharacters(in: .whitespaces).isEmpty }
    }

    var body: some View {
        VStack(spacing: 0) {
            Text("New Table in \u{201C}\(schema)\u{201D}")
                .font(.headline)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 20)
                .padding(.top, 18)
                .padding(.bottom, 8)

            HStack(spacing: 8) {
                Text("Name")
                TextField("table_name", text: $tableName)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 14)

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Columns")
                        .font(.headline)
                    Spacer()
                    Button {
                        columns.append(NewColumnDef(
                            name: "", dataType: "text", isNullable: true, isPrimaryKey: false, defaultValue: ""
                        ))
                    } label: {
                        Label("Add Column", systemImage: "plus")
                    }
                    .controlSize(.small)
                }
                .padding(.horizontal, 20)

                HStack(spacing: 8) {
                    Text("Name").frame(minWidth: 110, alignment: .leading)
                    Text("Type").frame(width: 150, alignment: .leading)
                    Text("PK").frame(width: 32)
                    Text("Null").frame(width: 40)
                    Text("Default").frame(minWidth: 90, maxWidth: .infinity, alignment: .leading)
                    Color.clear.frame(width: 22)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 20)

                ScrollView {
                    VStack(spacing: 6) {
                        ForEach($columns) { $col in
                            columnRow(col: $col)
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 4)
                }
                .frame(minHeight: 140, maxHeight: 320)
            }
            .padding(.bottom, 8)

            Divider()

            SheetButtonBar(confirmTitle: "Create", confirmDisabled: !canCreate) {
                dismiss()
            } onConfirm: {
                let validColumns = columns.filter { !$0.name.trimmingCharacters(in: .whitespaces).isEmpty }
                onCreate(tableName.trimmingCharacters(in: .whitespaces), validColumns)
                dismiss()
            }
        }
        .frame(width: 620)
    }

    private func columnRow(col: Binding<NewColumnDef>) -> some View {
        HStack(spacing: 8) {
            TextField("name", text: col.name)
                .font(.system(.body, design: .monospaced))
                .frame(minWidth: 110)

            SuggestingTextField(label: "type", text: col.dataType, suggestions: PGTypeSuggestions.column)
                .frame(width: 150)

            Toggle("", isOn: col.isPrimaryKey)
                .toggleStyle(.checkbox)
                .labelsHidden()
                .frame(width: 32)
                .help("Primary key")

            Toggle("", isOn: col.isNullable)
                .toggleStyle(.checkbox)
                .labelsHidden()
                .frame(width: 40)
                .disabled(col.isPrimaryKey.wrappedValue)
                .help("Allows NULL")

            TextField("expression", text: col.defaultValue)
                .frame(minWidth: 90, maxWidth: .infinity)
                .font(.system(.body, design: .monospaced))

            Button {
                columns.removeAll { $0.id == col.id }
            } label: {
                Image(systemName: "minus.circle")
            }
            .buttonStyle(.borderless)
            .disabled(columns.count <= 1)
            .frame(width: 22)
            .help("Remove column")
        }
        .textFieldStyle(.roundedBorder)
    }
}

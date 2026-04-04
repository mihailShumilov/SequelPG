import SwiftUI

struct NavigatorView: View {
    @EnvironmentObject var appVM: AppViewModel
    @EnvironmentObject var navigatorVM: NavigatorViewModel

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Navigator")
                    .font(.headline)
                Spacer()
                Button {
                    Task { await appVM.refreshNavigator() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .help("Refresh schemas, tables, and views")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            if !navigatorVM.databases.isEmpty {
                Picker("Database", selection: $navigatorVM.selectedDatabase) {
                    ForEach(navigatorVM.databases, id: \.self) { db in
                        Text(db).tag(db)
                    }
                }
                .pickerStyle(.menu)
                .padding(.horizontal, 12)
                .padding(.bottom, 4)
                .onChange(of: navigatorVM.selectedDatabase) { newValue in
                    if !newValue.isEmpty {
                        Task { await appVM.switchDatabase(newValue) }
                    }
                }
            }

            if !navigatorVM.schemas.isEmpty {
                Picker("Schema", selection: $navigatorVM.selectedSchema) {
                    ForEach(navigatorVM.schemas, id: \.self) { schema in
                        Text(schema).tag(schema)
                    }
                }
                .pickerStyle(.menu)
                .padding(.horizontal, 12)
                .padding(.bottom, 4)
                .onChange(of: navigatorVM.selectedSchema) { newValue in
                    if !newValue.isEmpty {
                        Task { await appVM.loadTablesAndViews(forSchema: newValue) }
                    }
                }
                .onAppear {
                    // Only load if we have a schema but no tables yet —
                    // avoids double-loading when onChange also fires.
                    let schema = navigatorVM.selectedSchema
                    if !schema.isEmpty, navigatorVM.tables.isEmpty, navigatorVM.views.isEmpty {
                        Task { await appVM.loadTablesAndViews(forSchema: schema) }
                    }
                }
            }

            List(selection: Binding<DBObject?>(
                get: { navigatorVM.selectedObject },
                set: { obj in
                    if let obj {
                        Task { await appVM.selectObject(obj) }
                    }
                }
            )) {
                if !navigatorVM.tables.isEmpty {
                    Section("Tables") {
                        ForEach(navigatorVM.tables) { table in
                            Label(table.name, systemImage: "tablecells")
                                .tag(table)
                        }
                    }
                }

                if !navigatorVM.views.isEmpty {
                    Section("Views") {
                        ForEach(navigatorVM.views) { view in
                            Label(view.name, systemImage: "eye")
                                .tag(view)
                        }
                    }
                }
            }
            .listStyle(.sidebar)
        }
    }
}

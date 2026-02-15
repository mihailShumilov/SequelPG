import SwiftUI

struct NavigatorView: View {
    @EnvironmentObject var appVM: AppViewModel

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Navigator")
                    .font(.headline)
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            if !appVM.navigatorVM.schemas.isEmpty {
                Picker("Schema", selection: $appVM.navigatorVM.selectedSchema) {
                    ForEach(appVM.navigatorVM.schemas, id: \.self) { schema in
                        Text(schema).tag(schema)
                    }
                }
                .pickerStyle(.menu)
                .padding(.horizontal, 12)
                .padding(.bottom, 4)
                .onChange(of: appVM.navigatorVM.selectedSchema) { newValue in
                    if !newValue.isEmpty {
                        Task { await appVM.loadTablesAndViews(forSchema: newValue) }
                    }
                }
                .onAppear {
                    let schema = appVM.navigatorVM.selectedSchema
                    if !schema.isEmpty {
                        Task { await appVM.loadTablesAndViews(forSchema: schema) }
                    }
                }
            }

            List(selection: Binding<DBObject?>(
                get: { appVM.navigatorVM.selectedObject },
                set: { obj in
                    if let obj {
                        Task { await appVM.selectObject(obj) }
                    }
                }
            )) {
                if !appVM.navigatorVM.tables.isEmpty {
                    Section("Tables") {
                        ForEach(appVM.navigatorVM.tables) { table in
                            Label(table.name, systemImage: "tablecells")
                                .tag(table)
                        }
                    }
                }

                if !appVM.navigatorVM.views.isEmpty {
                    Section("Views") {
                        ForEach(appVM.navigatorVM.views) { view in
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

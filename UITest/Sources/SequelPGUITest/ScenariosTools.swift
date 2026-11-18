import Foundation

/// The Database toolbar menu: catalog sheets, export with pg_dump, import with psql.
extension Scenarios {
    static var tools: [Scenario] {
        [
            Scenario(name: "database-sheets", summary: "Extensions, Roles and Function Library open and close") { ui in
                try ui.step("connect") { try ui.connect("PG18 scram") }
                for (item, title, expected) in [
                    ("Extensions…", "Extensions", "plpgsql"),
                    ("Roles & Privileges…", "Roles & Privileges", Cluster.role("readonly").user),
                    ("Function Library…", "SQL Function Library", "substring"),
                ] {
                    try ui.step(title) {
                        try ui.choose(.id(A11yID.Workspace.databaseMenu), item: item)
                        try ui.expect(Query(role: "AXStaticText", value: title), timeout: 10)
                        // Lists are lazy: search so the expected entry is on screen.
                        let sheet = try ui.expect(Query(role: "AXSheet"))
                        if let search = sheet.descendants().map(\.node).first(where: { $0.subrole == "AXSearchField" }) {
                            search.setValue(expected)
                        }
                        try ui.expect(Query(value: expected, partial: true), timeout: 10)
                        try ui.dismissSheet()
                    }
                }
            },

            Scenario(name: "export-database", summary: "Export Database writes a pg_dump script") { ui in
                try ui.step("connect") { try ui.connect("PG18 scram") }
                try ui.step("export") {
                    try ui.choose(.id(A11yID.Workspace.databaseMenu), item: "Export Database…")
                    try ui.press(.button("Export…"))
                    try ui.press(.button("Done"), timeout: 120)
                    let dump = try ui.exportedFile(extension: "sql")
                    try ui.expect(dump.contains("PostgreSQL database dump"), "not a pg_dump script")
                    try ui.expect(dump.contains("qa.people"), "dump lacks qa.people")
                }
            },

            Scenario(
                name: "import-sql",
                summary: "Import SQL File runs a script against the database",
                setupSQL: ["DROP TABLE IF EXISTS qa.ui_import"],
                openFileContents: """
                CREATE TABLE qa.ui_import (id int PRIMARY KEY, note text);
                INSERT INTO qa.ui_import VALUES (1, 'one'), (2, 'two'), (3, 'three');
                """
            ) { ui in
                try ui.step("connect") { try ui.connect("PG18 scram") }
                try ui.step("import") {
                    try ui.choose(.id(A11yID.Workspace.databaseMenu), item: "Import SQL File…")
                    try ui.press(.button("Choose…"))
                    try ui.expect(Query(value: "import-sql-open.sql", partial: true))
                    try ui.press(.button("Import"))
                    try ui.press(.button("Done"), timeout: 60)
                    try ui.expectEqual(try Cluster.sql("SELECT count(*) FROM qa.ui_import"), "3", "imported rows")
                }
                try ui.step("cleanup") { try Cluster.sql("DROP TABLE qa.ui_import") }
            },
        ]
    }
}

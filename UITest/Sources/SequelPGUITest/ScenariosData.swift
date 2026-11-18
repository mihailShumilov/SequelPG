import Foundation

/// Browsing objects: navigator, Structure, Content, Definition, Diagram;
/// editing rows; exporting results.
extension Scenarios {
    static let rowsTableSQL = [
        "DROP TABLE IF EXISTS qa.ui_rows",
        "CREATE TABLE qa.ui_rows (id serial PRIMARY KEY, label text NOT NULL)",
        "INSERT INTO qa.ui_rows (label) VALUES ('alpha'), ('beta')",
    ]

    static var data: [Scenario] {
        [
            Scenario(name: "browse-table", summary: "navigator → Structure, Content, Definition, Diagram") { ui in
                try ui.step("connect") { try ui.connect("PG18 scram") }
                try ui.step("open qa.people") { try ui.openObject(schema: "qa", name: "people") }
                try ui.step("structure lists columns") {
                    try ui.mode("Structure")
                    for column in ["email", "created_at"] {
                        try ui.expect(Query(value: column), timeout: 10)
                    }
                }
                try ui.step("content shows rows") {
                    try ui.mode("Content")
                    try ui.session.waitUntil("50 content rows", timeout: 15) {
                        (try? ui.grid(A11yID.Content.grid).count) == 50
                    }
                    try ui.expectContains(id: A11yID.Content.approximateRowCount, "50")
                }
                try ui.step("definition shows DDL") {
                    try ui.mode("Definition")
                    try ui.expect(Query(value: "CREATE TABLE", partial: true), timeout: 10)
                }
                try ui.step("diagram opens") {
                    try ui.mode("Diagram")
                    try ui.expect(Query(value: "people", partial: true), timeout: 15)
                }
            },

            Scenario(name: "edit-rows", summary: "insert and delete rows from the Content tab",
                     setupSQL: rowsTableSQL)
            { ui in
                try ui.step("connect") { try ui.connect("PG18 scram") }
                try ui.step("open qa.ui_rows") {
                    try ui.openObject(schema: "qa", name: "ui_rows")
                    try ui.mode("Content")
                    try ui.session.waitUntil("2 rows", timeout: 15) { (try? ui.grid(A11yID.Content.grid).count) == 2 }
                }
                try ui.step("insert a row") {
                    try ui.press(id: A11yID.Content.insertRow)
                    try ui.fill(id: A11yID.Content.insertField("label"), "gamma")
                    try ui.press(.button("Insert"))
                    try ui.session.waitUntil("3 rows", timeout: 15) { (try? ui.grid(A11yID.Content.grid).count) == 3 }
                    try ui.expectEqual(try Cluster.sql("SELECT string_agg(label, ',' ORDER BY id) FROM qa.ui_rows"),
                                       "alpha,beta,gamma", "rows in database")
                }
                try ui.step("delete the first row") {
                    let table = try ui.expect(id: A11yID.Content.grid)
                    table.selectRows([table.rows[0]])
                    try ui.press(id: A11yID.Content.deleteRow)
                    try ui.press(.button("Delete"))
                    try ui.session.waitUntil("2 rows", timeout: 15) { (try? ui.grid(A11yID.Content.grid).count) == 2 }
                    try ui.expectEqual(try Cluster.sql("SELECT string_agg(label, ',' ORDER BY id) FROM qa.ui_rows"),
                                       "beta,gamma", "rows in database")
                }
            },

            Scenario(name: "export-results", summary: "query results export to CSV and JSON files") { ui in
                try ui.step("connect") { try ui.connect("PG18 scram") }
                try ui.step("query") { try ui.query("SELECT id, name FROM qa.people ORDER BY id LIMIT 3", rows: 3) }
                try ui.step("export CSV") {
                    try ui.choose(.id(A11yID.Results.export), item: "Export as CSV…")
                    let csv = try ui.exportedFile(extension: "csv")
                    try ui.expect(csv.hasPrefix("id,name"), "CSV header: \(csv.prefix(80))")
                    try ui.expect(csv.contains("Person 03"), "CSV rows: \(csv)")
                }
                try ui.step("export JSON") {
                    try ui.choose(.id(A11yID.Results.export), item: "Export as JSON…")
                    let json = try ui.exportedFile(extension: "json")
                    let rows = try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [[String: Any]]
                    try ui.expectEqual(rows?.count, 3, "JSON rows")
                }
            },
        ]
    }
}

extension ScenarioContext {
    /// Waits for the save-panel stand-in to write a file with `extension`.
    func exportedFile(extension ext: String, timeout: TimeInterval = 10) throws -> String {
        var found: URL?
        try session.waitUntil("an exported .\(ext) file", timeout: timeout) {
            found = (try? FileManager.default.contentsOfDirectory(at: session.saveDirectory,
                                                                  includingPropertiesForKeys: nil))?
                .first { $0.pathExtension == ext }
            return found.flatMap { try? Data(contentsOf: $0) }.map { !$0.isEmpty } ?? false
        }
        return try String(contentsOf: found!, encoding: .utf8)
    }
}

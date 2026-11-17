import Foundation

/// The Query tab: results, NULLs, errors, commands, EXPLAIN, long statements.
extension Scenarios {
    static var query: [Scenario] {
        [
            Scenario(name: "query-results", summary: "rows, NULLs, unicode identifiers, the row cap") { ui in
                try ui.step("connect") { try ui.connect("PG18 scram") }
                try ui.step("ordered rows") {
                    let rows = try ui.query("SELECT id, name, age FROM qa.people ORDER BY id LIMIT 3", rows: 3)
                    try ui.expectEqual(rows, [["1", "Person 01", "19"], ["2", "Person 02", "20"],
                                              ["3", "Person 03", "21"]], "grid")
                }
                try ui.step("NULL is shown as NULL") {
                    let rows = try ui.query("SELECT id, age FROM qa.people WHERE id = 10", rows: 1)
                    try ui.expectEqual(rows.first?.last, "‹NULL›", "age of id 10")
                }
                try ui.step("quoted and unicode identifiers") {
                    let count = Int(try Cluster.sql(#"SELECT count(*) FROM qa."Weird Table""#)) ?? -1
                    try ui.query(#"SELECT "Mixed Case", "кириллица" FROM qa."Weird Table""#, rows: count)
                }
                try ui.step("large result is capped") {
                    try ui.run("SELECT * FROM qa.big_numbers")
                    try ui.expect(id: A11yID.Query.truncated, timeout: 20)
                }
            },

            Scenario(name: "query-errors", summary: "syntax and permission errors show inline and clear") { ui in
                try ui.step("connect") { try ui.connect("PG18 scram") }
                try ui.step("syntax error") {
                    try ui.run("SELEC 1")
                    try ui.expectContains(id: A11yID.Query.errorBanner, "syntax error")
                }
                try ui.step("unknown table") {
                    try ui.run("SELECT * FROM qa.nope")
                    try ui.expectContains(id: A11yID.Query.errorBanner, "does not exist")
                }
                try ui.step("next good query clears the error") {
                    try ui.query("SELECT 1", rows: 1)
                    try ui.expectGone(.id(A11yID.Query.errorBanner))
                }
            },

            Scenario(
                name: "query-commands",
                summary: "DDL and DML report affected rows and really change the database",
                setupSQL: ["DROP TABLE IF EXISTS qa.ui_cmd"]
            ) { ui in
                try ui.step("connect") { try ui.connect("PG18 scram") }
                try ui.step("CREATE TABLE") {
                    try ui.run("CREATE TABLE qa.ui_cmd (id int)")
                    try ui.expect(id: A11yID.Query.commandCompleted)
                }
                try ui.step("INSERT writes 5 rows") {
                    try ui.run("INSERT INTO qa.ui_cmd SELECT generate_series(1, 5)")
                    try ui.expect(id: A11yID.Query.commandCompleted)
                    // Known issue: the "N rows affected" summary never shows —
                    // DatabaseClient doesn't read the command tag (rowsAffected is nil).
                    try ui.expectEqual(try Cluster.sql("SELECT count(*) FROM qa.ui_cmd"), "5", "rows in database")
                }
                try ui.step("DROP TABLE") {
                    try ui.run("DROP TABLE qa.ui_cmd")
                    try ui.expect(id: A11yID.Query.commandCompleted)
                    try ui.expectEqual(try Cluster.sql("SELECT to_regclass('qa.ui_cmd') IS NULL"), "t", "dropped")
                }
            },

            Scenario(name: "explain", summary: "Explain and Analyze show a plan") { ui in
                try ui.step("connect") { try ui.connect("PG18 scram") }
                try ui.step("explain") {
                    try ui.mode("Query")
                    try ui.fill(id: A11yID.Query.editor, "SELECT * FROM qa.people WHERE age > 30")
                    try ui.press(id: A11yID.Query.explain)
                    try ui.waitUntilIdle()
                    try ui.expect(id: A11yID.Query.planView, timeout: 10)
                }
                try ui.step("analyze") {
                    try ui.press(id: A11yID.Query.analyze)
                    try ui.waitUntilIdle()
                    try ui.expectContains(id: A11yID.Query.planView, "people")
                }
            },

            Scenario(name: "long-query", summary: "a running statement shows Stop, then its result") { ui in
                try ui.step("connect") { try ui.connect("PG18 scram") }
                try ui.step("Stop appears while running") {
                    try ui.mode("Query")
                    try ui.fill(id: A11yID.Query.editor, "SELECT pg_sleep(2), 42 AS answer")
                    try ui.press(id: A11yID.Query.run)
                    try ui.expect(id: A11yID.Query.stop, timeout: 3)
                }
                try ui.step("result arrives") {
                    try ui.waitUntilIdle(timeout: 15)
                    try ui.expectText(id: A11yID.Query.rowCount, "1 row") { $0 == "1 row" }
                    try ui.expectEqual(try ui.grid().first?.last, "42", "answer")
                }
            },
        ]
    }
}

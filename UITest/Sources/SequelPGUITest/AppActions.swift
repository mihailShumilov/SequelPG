import AppKit
import Foundation

/// SequelPG-specific steps built on the generic actions.
extension ScenarioContext {
    // MARK: Start page

    /// Selects a saved connection in the start page sidebar.
    func selectProfile(_ name: String) throws {
        let list = try expect(id: A11yID.StartPage.connectionList)
        var row: AXNode?
        try session.waitUntil("profile row “\(name)”") {
            row = list.rows.first { $0.allText.contains(name) }
            return row != nil
        }
        list.selectRows([row!])
        try expectText(id: A11yID.Form.name, "name “\(name)”") { $0 == name }
    }

    /// Selects `profile` (if given), presses Connect and waits for the workspace.
    func connect(_ profile: String? = nil, timeout: TimeInterval = 30) throws {
        if let profile { try selectProfile(profile) }
        try press(id: A11yID.StartPage.connect)
        do {
            try expect(Query(role: "AXRadioButton", label: "Query"), timeout: timeout)
        } catch {
            let alert = alertText
            throw Failure("workspace did not open" + (alert.isEmpty ? "" : "; alert: \(alert)"))
        }
    }

    /// Presses Connect and returns the text of the error alert that must appear.
    @discardableResult
    func connectExpectingError(_ profile: String, timeout: TimeInterval = 30) throws -> String {
        try selectProfile(profile)
        try press(id: A11yID.StartPage.connect)
        var text = ""
        try session.waitUntil("a connection error alert", timeout: timeout) {
            text = alertText
            return !text.isEmpty
        }
        try press(.button("OK"))
        try expectGone(Query(role: "AXSheet"))
        return text
    }

    func disconnect() throws {
        try choose(.id(A11yID.Workspace.databaseMenu), item: "Disconnect")
        try expect(id: A11yID.StartPage.connect, timeout: 10)
    }

    /// Closes the open sheet with Escape (the first press may only clear a search field).
    func dismissSheet() throws {
        for _ in 0 ..< 3 where !session.find(Query(role: "AXSheet")).isEmpty {
            try key("escape")
            RunLoop.current.run(until: Date().addingTimeInterval(0.4))
        }
        try expectGone(Query(role: "AXSheet"))
    }

    // MARK: Workspace

    /// Switches the main mode: Structure, Content, Definition, Query or Diagram.
    func mode(_ name: String) throws {
        try press(Query(role: "AXRadioButton", label: name))
        try session.waitUntil("mode \(name)") {
            session.find(Query(role: "AXRadioButton", label: name)).first?.value == "1"
        }
    }

    /// Puts `sql` in the editor, presses Run and waits for execution to finish.
    func run(_ sql: String, timeout: TimeInterval = 20) throws {
        try mode("Query")
        if let clear = session.find(.id(A11yID.Query.clear)).first, clear.isEnabled { clear.press() }
        try fill(id: A11yID.Query.editor, sql)
        try press(id: A11yID.Query.run)
        try waitUntilIdle(timeout: timeout)
    }

    /// Waits until no statement is executing (the Stop button is gone).
    func waitUntilIdle(timeout: TimeInterval = 20) throws {
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        try expectGone(.id(A11yID.Query.stop), timeout: timeout)
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))
    }

    /// Cell texts of a results grid, row by row.
    func grid(_ id: String = A11yID.Query.grid) throws -> [[String]] {
        let table = try expect(id: id)
        return table.rows.map { row in
            row.children.filter { $0.role == "AXCell" }.map { cell in
                cell.descendants(maxDepth: 6).map(\.node).filter { $0.role == "AXStaticText" }
                    .map(\.value).filter { !$0.isEmpty }.joined(separator: " ")
            }
        }
    }

    /// Runs `sql` and returns the result grid, checking the "N rows" footer.
    @discardableResult
    func query(_ sql: String, rows expected: Int) throws -> [[String]] {
        try run(sql)
        if let error = session.find(.id(A11yID.Query.errorBanner)).first {
            throw Failure("query failed: \(error.allText)")
        }
        try expectText(id: A11yID.Query.rowCount, "\(expected) row(s)") {
            $0 == "\(expected) row\(expected == 1 ? "" : "s")"
        }
        return try grid()
    }

    /// First cell of a one-row result.
    func scalar(_ sql: String) throws -> String {
        let rows = try query(sql, rows: 1)
        guard let value = rows.first?.first else { throw Failure("no value for \(sql)") }
        return value
    }

    // MARK: Navigator

    private func outlineRow(containing node: AXNode) throws -> AXNode {
        var current: AXNode? = node
        while let candidate = current, candidate.role != "AXRow" { current = candidate.parent }
        guard let row = current else { throw Failure("\(node) is not in a list row") }
        return row
    }

    func expandNavigator(_ id: String) throws {
        let row = try outlineRow(containing: try expect(id: id, timeout: 15))
        if (row.attribute("AXDisclosing") as? Bool) != true {
            AXUIElementSetAttributeValue(row.element, "AXDisclosing" as CFString, kCFBooleanTrue)
        }
        RunLoop.current.run(until: Date().addingTimeInterval(0.5))
    }

    /// Expands schema ▸ category and selects the object, as clicking it would.
    func openObject(schema: String, name: String, category: String = "Tables") throws {
        try expandNavigator(A11yID.Navigator.schema(schema))
        try expandNavigator(A11yID.Navigator.category(schema: schema, category))
        // The sidebar is lazy: rows scrolled out of view have no cells. The
        // filter (over loaded objects) brings the wanted one into view.
        try fill(id: A11yID.Navigator.filter, name)
        let item = try expect(id: A11yID.Navigator.object(schema: schema, name: name), timeout: 15)
        let row = try outlineRow(containing: item)
        guard let outline = row.parent else { throw Failure("navigator outline not found") }
        outline.selectRows([row])
        RunLoop.current.run(until: Date().addingTimeInterval(0.5))
    }
}

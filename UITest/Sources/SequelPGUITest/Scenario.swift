import AppKit
import Foundation

/// A UI scenario: what a person does, step by step, through the real interface.
struct Scenario {
    let name: String
    let summary: String
    /// Profiles saved before launch.
    var profiles: [SeedProfile] = Scenarios.standardProfiles
    /// SQL run (as admin, on pg18) before launch to prepare fixtures.
    var setupSQL: [String] = []
    /// Contents of the file the app's open panel "chooses" in this run.
    var openFileContents: String?
    let body: @MainActor (ScenarioContext) throws -> Void
}

/// What a scenario can do. Each `step` ends with a screenshot; a failed step
/// is screenshotted too and stops the scenario.
@MainActor
final class ScenarioContext {
    struct Step: Codable {
        let name: String
        let passed: Bool
        let detail: String
        let screenshot: String?
        let seconds: Double
    }

    let session: Session
    let scenario: String
    private(set) var steps: [Step] = []

    init(session: Session, scenario: String) {
        self.session = session
        self.scenario = scenario
    }

    func step(_ name: String, _ body: () throws -> Void) throws {
        let started = Date()
        do {
            try body()
            RunLoop.current.run(until: Date().addingTimeInterval(0.25))
            let shot = session.screenshot("\(scenario)-\(name)")
            steps.append(Step(name: name, passed: true, detail: "", screenshot: shot?.lastPathComponent,
                              seconds: Date().timeIntervalSince(started)))
        } catch {
            let shot = session.screenshot("\(scenario)-\(name)-FAILED")
            steps.append(Step(name: name, passed: false, detail: "\(error)", screenshot: shot?.lastPathComponent,
                              seconds: Date().timeIntervalSince(started)))
            throw error
        }
    }

    // MARK: - Generic actions

    /// Presses the control with this accessibility identifier.
    @discardableResult
    func press(id: String, timeout: TimeInterval = 5) throws -> AXNode {
        try press(.id(id), timeout: timeout)
    }

    @discardableResult
    func press(_ query: Query, timeout: TimeInterval = 5) throws -> AXNode {
        var node: AXNode?
        try session.waitUntil("\(query) to be enabled", timeout: timeout) {
            node = session.find(query).first { $0.isEnabled }
            return node != nil
        }
        node!.press()
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        return node!
    }

    /// Picks `item` from the pop-up/menu button matching `menuButton`.
    /// Opens a pop-up menu and picks `item`. A menu snapshots its items'
    /// enabled state when it opens, so a still-disabled item (the app is
    /// catching up) is retried by closing and reopening the menu.
    func choose(_ menuButton: Query, item: String, timeout: TimeInterval = 10) throws {
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            try press(menuButton, timeout: max(1, deadline.timeIntervalSinceNow))
            do {
                try press(Query(role: "AXMenuItem", label: item), timeout: 2)
                return
            } catch {
                guard Date() < deadline else { throw error }
                try key("escape")
                RunLoop.current.run(until: Date().addingTimeInterval(0.5))
            }
        }
    }

    /// Replaces the text of the field with this identifier.
    func fill(id: String, _ text: String) throws {
        let field = try session.element(.id(id))
        guard field.setValue(text) else { throw Failure("couldn't set text of \(field)") }
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))
    }

    func key(_ shortcut: String) throws {
        try Keys.press(shortcut, to: session.pid)
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))
    }

    // MARK: - Checks

    @discardableResult
    func expect(_ query: Query, timeout: TimeInterval = 5) throws -> AXNode {
        try session.element(query, timeout: timeout)
    }

    @discardableResult
    func expect(id: String, timeout: TimeInterval = 5) throws -> AXNode {
        try session.element(.id(id), timeout: timeout)
    }

    func expectGone(_ query: Query, timeout: TimeInterval = 5) throws {
        try session.waitUntil("\(query) to go away", timeout: timeout) { session.find(query).isEmpty }
    }

    /// Waits until the element's text (value or label) satisfies `predicate`.
    @discardableResult
    func expectText(
        id: String,
        timeout: TimeInterval = 10,
        _ what: String,
        _ predicate: (String) -> Bool
    ) throws -> String {
        var last = "<missing>"
        do {
            try session.waitUntil("#\(id) \(what)", timeout: timeout) {
                guard let node = session.find(.id(id)).first else { return false }
                last = node.value.isEmpty ? node.label : node.value
                return predicate(last)
            }
        } catch {
            throw Failure("#\(id): expected \(what), got “\(last)”")
        }
        return last
    }

    /// Waits until the subtree with this identifier contains `text` anywhere.
    @discardableResult
    func expectContains(id: String, _ text: String, timeout: TimeInterval = 10) throws -> String {
        var last = "<missing>"
        do {
            try session.waitUntil("#\(id) to contain “\(text)”", timeout: timeout) {
                guard let node = session.find(.id(id)).first else { return false }
                last = node.allText
                return last.localizedCaseInsensitiveContains(text)
            }
        } catch {
            throw Failure("#\(id): expected to contain “\(text)”, got “\(last.prefix(400))”")
        }
        return last
    }

    func expect(_ condition: Bool, _ message: @autoclosure () -> String) throws {
        if !condition { throw Failure(message()) }
    }

    func expectEqual<T: Equatable>(_ actual: T, _ expected: T, _ what: String) throws {
        if actual != expected { throw Failure("\(what): expected \(expected), got \(actual)") }
    }

    /// Fails the step with the text of any alert/sheet currently shown.
    var alertText: String {
        var texts: [String] = []
        for window in session.windows {
            for (node, _) in window.descendants() where node.role == "AXSheet" || node.subrole == "AXDialog" {
                texts.append(node.allText)
            }
        }
        return texts.joined(separator: " | ")
    }
}

/// Runs scenarios, each on a freshly launched app, and writes the report.
@MainActor
struct ScenarioRunner {
    let folder: URL

    func run(_ names: [String]) throws -> Int32 {
        let chosen = names.isEmpty ? Scenarios.all : Scenarios.all.filter { names.contains($0.name) }
        guard !chosen.isEmpty else { throw Failure("no scenario named \(names); see `list`") }
        guard Cluster.isUp else { throw Failure("test cluster is not running; run `make -C test-db up`") }
        let reportFolder = folder.appending(path: "report")
        try? FileManager.default.removeItem(at: reportFolder)
        try FileManager.default.createDirectory(at: reportFolder, withIntermediateDirectories: true)
        var report = Report()
        for scenario in chosen {
            let started = Date()
            var failure: String?
            var context: ScenarioContext?
            var session: Session?
            do {
                for sql in scenario.setupSQL { try Cluster.sql(sql) }
                var openFile: URL?
                if let contents = scenario.openFileContents {
                    openFile = folder.appending(path: "\(scenario.name)-open.sql")
                    try contents.write(to: openFile!, atomically: true, encoding: .utf8)
                }
                session = try Session.launch(folder: folder.appending(path: "run-\(scenario.name)"),
                                             profiles: scenario.profiles, openFile: openFile)
                context = ScenarioContext(session: session!, scenario: scenario.name)
                try scenario.body(context!)
            } catch {
                failure = "\(error)"
            }
            session?.quit()
            let steps = context?.steps ?? []
            for shot in steps.compactMap(\.screenshot) {
                try? FileManager.default.copyItem(at: session!.shots.appending(path: shot),
                                                  to: reportFolder.appending(path: shot))
            }
            report.add(scenario: scenario, steps: steps, failure: failure, seconds: Date().timeIntervalSince(started))
            let status = failure == nil ? "PASS" : "FAIL"
            let seconds = String(format: "%.1f", Date().timeIntervalSince(started))
            var line = "\(status)  \(scenario.name)  (\(steps.count) steps, \(seconds)s)"
            if let failure { line += "\n      \(failure)" }
            print(line)
        }
        try report.write(to: reportFolder)
        print(report.summary)
        print("Report: \(reportFolder.appending(path: "report.html").path)")
        return report.failed == 0 ? 0 : 1
    }
}

struct Report {
    struct Entry: Codable {
        let name: String
        let summary: String
        let passed: Bool
        let failure: String?
        let seconds: Double
        let steps: [ScenarioContext.Step]
    }

    private(set) var entries: [Entry] = []
    var failed: Int { entries.filter { !$0.passed }.count }
    var summary: String { "\(entries.count - failed) passed, \(failed) failed, \(entries.count) scenarios" }

    mutating func add(scenario: Scenario, steps: [ScenarioContext.Step], failure: String?, seconds: Double) {
        entries.append(Entry(name: scenario.name, summary: scenario.summary, passed: failure == nil,
                             failure: failure, seconds: seconds, steps: steps))
    }

    func write(to folder: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(entries).write(to: folder.appending(path: "report.json"))
        func esc(_ s: String) -> String {
            s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
                .replacingOccurrences(of: ">", with: "&gt;")
        }
        var html = """
        <!doctype html><meta charset="utf-8"><title>SequelPG UI scenarios</title>
        <style>body{font:14px -apple-system,sans-serif;margin:24px;background:#fafafa;color:#222}
        h2{margin-top:32px}.pass{color:#1a7f37}.fail{color:#cf222e}.step{display:inline-block;margin:8px;
        vertical-align:top;width:360px}.step img{width:360px;border:1px solid #ccc;border-radius:6px}
        pre{white-space:pre-wrap;background:#fff0f0;padding:8px;border-radius:6px}</style>
        <h1>SequelPG UI scenarios</h1><p>\(esc(summary))</p>
        """
        for entry in entries {
            html += "<h2 class=\"\(entry.passed ? "pass" : "fail")\">\(entry.passed ? "✓" : "✗") \(esc(entry.name))</h2>"
            html += "<p>\(esc(entry.summary)) — \(String(format: "%.1f", entry.seconds)) s</p>"
            if let failure = entry.failure { html += "<pre>\(esc(failure))</pre>" }
            for step in entry.steps {
                html += "<div class=\"step\"><b class=\"\(step.passed ? "pass" : "fail")\">\(esc(step.name))</b>"
                if let shot = step.screenshot { html += "<br><a href=\"\(shot)\"><img src=\"\(shot)\"></a>" }
                if !step.detail.isEmpty { html += "<pre>\(esc(step.detail))</pre>" }
                html += "</div>"
            }
        }
        try html.write(to: folder.appending(path: "report.html"), atomically: true, encoding: .utf8)
    }
}

import AppKit
import Foundation

/// `sequelpg-uitest`: end-to-end UI scenarios against the Docker test
/// cluster, plus step-by-step commands for exploring the interface.
///
///   run [scenario…]          run scenarios (all by default); writes report/
///   list                     list scenarios
///   launch [--seed]          start the app (with the standard test profiles)
///   quit                     quit it
///   dump [--all]             outline of the windows
///   press <id|label>         press a control by identifier or label
///   set <id|label> <text>    put text into a field
///   key <shortcut>           send a shortcut, e.g. cmd+return
///   menu "File>Export Database…"
///   shot <name>              screenshot the focused window
///   focus                    print the focused element
///
/// Session folder: $SEQUELPG_UITEST_DIR or <repo>/build/uitest.
@MainActor
enum CLI {
    static func main() -> Int32 {
        setvbuf(stdout, nil, _IOLBF, 0)
        var arguments = Array(CommandLine.arguments.dropFirst())
        guard !arguments.isEmpty else {
            print(usage)
            return 64
        }
        let command = arguments.removeFirst()
        let folder = Session.defaultFolder()
        do {
            switch command {
            case "run": return try ScenarioRunner(folder: folder).run(arguments)
            case "list":
                for scenario in Scenarios.all { print("\(scenario.name)\t\(scenario.summary)") }
            case "launch":
                let profiles = arguments.contains("--seed") ? Scenarios.standardProfiles : []
                let session = try Session.launch(folder: folder.appending(path: "interactive"), profiles: profiles)
                print("launched pid \(session.pid)")
            default:
                try interactive(command, arguments, Session.attach(folder: folder.appending(path: "interactive")))
            }
            return 0
        } catch {
            FileHandle.standardError.write(Data("error: \(error)\n".utf8))
            return 1
        }
    }

    private static func interactive(_ command: String, _ arguments: [String], _ session: Session) throws {
        func arg(_ index: Int) throws -> String {
            guard arguments.count > index else { throw Failure("missing argument \(index + 1)\n\(usage)") }
            return arguments[index]
        }
        func lookup(_ text: String) throws -> AXNode {
            if let byID = session.find(.id(text)).first { return byID }
            return try session.element(Query(label: text))
        }
        switch command {
        case "quit": session.quit()
        case "dump": print(session.outline(all: arguments.contains("--all")))
        case "press":
            let node = try lookup(try arg(0))
            print(node.press() ? "pressed \(node)" : "press failed on \(node) (actions: \(node.actions))")
        case "set":
            let node = try lookup(try arg(0))
            print(node.setValue(try arg(1)) ? "set \(node)" : "could not set \(node)")
        case "key": try Keys.press(try arg(0), to: session.pid)
        case "menu": try session.menu(try arg(0).components(separatedBy: ">"))
        case "shot": print(session.screenshot(try arg(0))?.path ?? "screenshot failed")
        case "focus": print(session.focused.map { "\($0)" } ?? "nothing focused")
        default: throw Failure("unknown command “\(command)”\n\(usage)")
        }
    }

    static let usage = "usage: sequelpg-uitest run|list|launch|quit|dump|press|set|key|menu|shot|focus …"
}

exit(MainActor.assumeIsolated { CLI.main() })

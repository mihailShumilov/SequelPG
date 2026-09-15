import AppKit
import SwiftUI

/// SwiftUI Settings scene (`⌘,`): General (appearance), Editor (completion,
/// timeout, font), and Tools (PostgreSQL client binaries).
struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettingsPane()
                .tabItem { Label("General", systemImage: "gearshape") }
            EditorSettingsPane()
                .tabItem { Label("Editor", systemImage: "text.cursor") }
            ToolsSettingsPane()
                .tabItem { Label("Tools", systemImage: "wrench.and.screwdriver") }
        }
        .frame(width: 520)
    }
}

private struct GeneralSettingsPane: View {
    @Environment(ThemePreference.self) private var themePreference

    var body: some View {
        @Bindable var pref = themePreference
        Form {
            Picker("Appearance", selection: $pref.mode) {
                ForEach(ThemeMode.allCases) { mode in
                    Text(mode.label).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            Text("Auto follows the system appearance and switches live between Light and Dark.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
        .frame(height: 140)
    }
}

private struct EditorSettingsPane: View {
    @Environment(EditorPreference.self) private var editorPreference

    var body: some View {
        @Bindable var pref = editorPreference
        Form {
            Section("Font") {
                Picker("Family", selection: $pref.fontFamily) {
                    ForEach(EditorFontFamily.allCases) { family in
                        Text(family.label).tag(family)
                    }
                }
                Stepper(value: $pref.fontSize, in: EditorPreference.fontSizeRange) {
                    LabeledContent("Size", value: "\(pref.fontSize) pt")
                }
                Text("SELECT id, created_at FROM orders WHERE total > 100;")
                    .font(Font(pref.editorFont))
                    .lineLimit(1)
                    .foregroundStyle(.secondary)
            }

            Section("Completion") {
                Toggle("Suggest completions while typing", isOn: $pref.autocompleteWhileTyping)
                Text("Turn this off to type without interruption — completions are still available on demand with Escape or ⌃Space.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Execution") {
                Picker("Query timeout", selection: $pref.queryTimeoutSeconds) {
                    Text("5 seconds").tag(5)
                    Text("10 seconds").tag(10)
                    Text("30 seconds").tag(30)
                    Text("1 minute").tag(60)
                    Text("5 minutes").tag(300)
                    Text("No limit").tag(0)
                }
                Text("Queries running longer than this are stopped automatically. With “No limit”, a query runs until it finishes or you press Stop (⌘.).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(height: 420)
    }
}

private struct ToolsSettingsPane: View {
    /// Mirrors `PGToolchain.configuredDirectory` (UserDefaults-backed). Local
    /// state because the toolchain isn't an `@Observable` model.
    @State private var toolsDirectory: String = PGToolchain.configuredDirectory ?? ""
    @State private var detectedDump: String?
    @State private var detectedPsql: String?

    var body: some View {
        Form {
            Section {
                HStack {
                    TextField("Directory", text: $toolsDirectory, prompt: Text("Auto-detect"))
                        .onChange(of: toolsDirectory) { _, newValue in
                            PGToolchain.configuredDirectory = newValue
                            refreshDetection()
                        }
                    Button("Choose…") { chooseDirectory() }
                }
                detectionRow(tool: "pg_dump", path: detectedDump)
                detectionRow(tool: "psql", path: detectedPsql)
            } header: {
                Text("PostgreSQL Client Tools")
            } footer: {
                Text("Used for Export Database and Import SQL File. Leave the directory empty to auto-detect Postgres.app, Homebrew, and the EDB installer.")
            }
        }
        .formStyle(.grouped)
        .frame(height: 240)
        .task { refreshDetection() }
    }

    @ViewBuilder
    private func detectionRow(tool: String, path: String?) -> some View {
        LabeledContent {
            Text(path ?? "Not found")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
        } label: {
            Label {
                Text(tool).font(.system(.body, design: .monospaced))
            } icon: {
                Image(systemName: path == nil ? "xmark.circle.fill" : "checkmark.circle.fill")
                    .foregroundStyle(path == nil ? Color.red : Color.green)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(tool): \(path ?? "not found")")
    }

    private func refreshDetection() {
        // FileManager probing can touch slow/network mounts; keep it off the
        // main actor.
        Task {
            let dump = await Task.detached { PGToolchain.locate(.pgDump) }.value
            let psql = await Task.detached { PGToolchain.locate(.psql) }.value
            detectedDump = dump
            detectedPsql = psql
        }
    }

    private func chooseDirectory() {
        let panel = NSOpenPanel()
        panel.title = "Choose PostgreSQL bin Directory"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        toolsDirectory = url.path
    }
}

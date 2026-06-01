import AppKit
import SwiftUI

/// SwiftUI Settings scene (`⌘,`). Houses the Appearance picker and the
/// PostgreSQL client-tools location — extend with new tabs as more land.
struct SettingsView: View {
    @Environment(ThemePreference.self) private var themePreference

    var body: some View {
        TabView {
            GeneralSettingsPane()
                .tabItem { Label("General", systemImage: "gearshape") }
        }
        .frame(width: 480, height: 360)
    }
}

private struct GeneralSettingsPane: View {
    @Environment(ThemePreference.self) private var themePreference
    @Environment(EditorPreference.self) private var editorPreference

    /// Mirrors `PGToolchain.configuredDirectory` (UserDefaults-backed). Local
    /// state because the toolchain isn't an `@Observable` model.
    @State private var toolsDirectory: String = PGToolchain.configuredDirectory ?? ""
    @State private var detectedDump: String?
    @State private var detectedPsql: String?

    var body: some View {
        @Bindable var pref = themePreference
        @Bindable var editorPref = editorPreference
        Form {
            Section {
                Picker("Appearance", selection: $pref.mode) {
                    ForEach(ThemeMode.allCases) { mode in
                        Text(mode.label).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                Text("Auto follows your macOS appearance setting and switches when the system toggles between Light and Dark.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } header: {
                Text("Theme").font(.headline)
            }

            Section {
                Toggle("Suggest completions while typing", isOn: $editorPref.autocompleteWhileTyping)
                Text("Pops the autocomplete list automatically as you type in the SQL editor. Turn this off to type without interruption — you can still request completions on demand by pressing Escape.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } header: {
                Text("SQL Editor").font(.headline)
            }

            Section {
                HStack {
                    TextField("Directory", text: $toolsDirectory, prompt: Text("Auto-detect"))
                        .textFieldStyle(.roundedBorder)
                        .onChange(of: toolsDirectory) { _, newValue in
                            PGToolchain.configuredDirectory = newValue
                            refreshDetection()
                        }
                    Button("Choose…") { chooseDirectory() }
                }
                detectionRow(tool: "pg_dump", path: detectedDump)
                detectionRow(tool: "psql", path: detectedPsql)
                Text("Used for database export and SQL import. Leave blank to auto-detect Postgres.app, Homebrew, and standard installs.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } header: {
                Text("PostgreSQL Client Tools").font(.headline)
            }
        }
        .formStyle(.grouped)
        .padding(.vertical, 4)
        .task { refreshDetection() }
    }

    @ViewBuilder
    private func detectionRow(tool: String, path: String?) -> some View {
        HStack(spacing: 6) {
            Image(systemName: path == nil ? "xmark.circle.fill" : "checkmark.circle.fill")
                .foregroundStyle(path == nil ? Theme.rose : Color.green)
                .accessibilityHidden(true)
            Text(tool).font(Theme.mono(size: 11))
            Spacer()
            Text(path ?? "not found")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
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

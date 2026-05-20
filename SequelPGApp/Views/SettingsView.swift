import SwiftUI

/// SwiftUI Settings scene (`⌘,`). Currently houses the Appearance picker —
/// extend with new tabs as more preferences land.
struct SettingsView: View {
    @Environment(ThemePreference.self) private var themePreference

    var body: some View {
        TabView {
            GeneralSettingsPane()
                .tabItem { Label("General", systemImage: "gearshape") }
        }
        .frame(width: 460, height: 220)
    }
}

private struct GeneralSettingsPane: View {
    @Environment(ThemePreference.self) private var themePreference

    var body: some View {
        @Bindable var pref = themePreference
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
        }
        .formStyle(.grouped)
        .padding(.vertical, 4)
    }
}

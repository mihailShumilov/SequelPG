import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Imports a `.sql` file into the connected database with `psql`. The safety
/// behaviour (single transaction / stop on error) is chosen per import — the
/// view model is recreated each time the sheet opens, so nothing is remembered
/// between imports.
struct ImportSheet: View {
    @Environment(AppViewModel.self) private var appVM
    @Environment(\.dismiss) private var dismiss

    @State private var vm = ImportViewModel()

    private var showsProgress: Bool {
        vm.isImporting || vm.didFinish || vm.didCancel || vm.errorMessage != nil
    }

    var body: some View {
        VStack(spacing: 0) {
            header

            Divider()

            if vm.toolMissing {
                ToolMissingView(toolName: "psql")
            } else if showsProgress {
                progressView
            } else {
                optionsForm
            }

            Divider()

            footer
        }
        .frame(width: 600, height: 560)
        .task { await vm.locateTool() }
        // Dismissing the sheet (Done / Escape) mid-import would otherwise leave
        // psql running with no way to stop it.
        .onDisappear { vm.cancel() }
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            Text("Import SQL File").font(.headline)
            Spacer()
            Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
        }
        .padding()
    }

    // MARK: - Options

    @ViewBuilder
    private var optionsForm: some View {
        @Bindable var vm = vm
        Form {
            Section("File") {
                HStack {
                    if let url = vm.inputURL {
                        Text(url.lastPathComponent)
                            .font(Theme.mono(size: 12))
                            .lineLimit(1)
                            .truncationMode(.middle)
                    } else {
                        Text("No file selected")
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Choose…") { presentOpenPanel() }
                }
                if let url = vm.inputURL {
                    Text(url.deletingLastPathComponent().path)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }

            Section {
                Toggle("Run in a single transaction", isOn: $vm.options.singleTransaction)
                Text("Wraps the whole file in one transaction — any error rolls everything back, so the database is never left half-imported. Turn off for files that manage their own transactions or can't run inside one (e.g. large dumps).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Toggle("Stop on first error", isOn: $vm.options.stopOnError)
                Text("Aborts as soon as a statement fails (ON_ERROR_STOP). Turn off to continue past errors and import everything that succeeds.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } header: {
                Text("Safety")
            } footer: {
                Label(
                    "Statements run against the active database \u{201C}\(appVM.liveConnection?.profile.database ?? "")\u{201D} and can modify or drop data.",
                    systemImage: "exclamationmark.triangle.fill"
                )
                .font(.caption)
                .foregroundStyle(Theme.amber)
                .padding(.top, 4)
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - Progress

    private var progressView: some View {
        VStack(alignment: .leading, spacing: 10) {
            TransferStatusHeader(
                isRunning: vm.isImporting,
                didFinish: vm.didFinish,
                didCancel: vm.didCancel,
                hasError: vm.errorMessage != nil,
                noun: "Import",
                activeLabel: "Importing…"
            )

            TransferLogView(lines: vm.progressLines)

            if let error = vm.errorMessage {
                Text(error)
                    .font(Theme.mono(size: 11))
                    .foregroundStyle(Theme.rose)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    // MARK: - Footer

    private var footer: some View {
        HStack {
            if let profile = appVM.liveConnection?.profile {
                ConnectionSummaryView(profile: profile, toolVersion: vm.toolVersion)
            }
            Spacer()
            if vm.isImporting {
                Button("Cancel", role: .cancel) { vm.cancel() }
            } else if showsProgress {
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            } else {
                Button("Import") { startImport() }
                    .buttonStyle(.borderedProminent)
                    .disabled(vm.toolMissing || vm.inputURL == nil || appVM.liveConnection == nil)
            }
        }
        .padding()
    }

    // MARK: - Actions

    private func presentOpenPanel() {
        let panel = NSOpenPanel()
        panel.title = "Choose SQL File"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        var types: [UTType] = [.plainText, .data]
        if let sql = UTType(filenameExtension: "sql") { types.insert(sql, at: 0) }
        panel.allowedContentTypes = types
        guard panel.runModal() == .OK, let url = panel.url else { return }
        vm.inputURL = url
    }

    private func startImport() {
        Task {
            guard let (connection, password) = await appVM.toolConnection() else {
                vm.errorMessage = "Not connected."
                return
            }
            vm.start(connection: connection, password: password)
        }
    }
}

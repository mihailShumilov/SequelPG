import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Exports the connected database with `pg_dump`, exposing the full range of
/// dump options. Presented from the Database-tools toolbar menu and the File
/// menu. The connection endpoint (including the SSH-tunnel loopback port) is
/// resolved from the live `DatabaseClient`.
struct ExportSheet: View {
    @Environment(AppViewModel.self) private var appVM
    @Environment(\.dismiss) private var dismiss

    @State private var vm = ExportViewModel()

    private var showsProgress: Bool {
        vm.isExporting || vm.didFinish || vm.didCancel || vm.errorMessage != nil
    }

    var body: some View {
        VStack(spacing: 0) {
            header

            Divider()

            if vm.toolMissing {
                ToolMissingView(toolName: "pg_dump")
            } else if showsProgress {
                progressView
            } else {
                optionsForm
            }

            Divider()

            footer
        }
        .frame(width: 600, height: 640)
        .task {
            await vm.locateTool()
            await loadSchemas()
        }
        // Dismissing the sheet (Done / Escape) mid-export would otherwise leave
        // pg_dump running with no way to stop it.
        .onDisappear { vm.cancel() }
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            Text("Export Database").font(.headline)
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
            Section("Format") {
                Picker("Format", selection: $vm.options.format) {
                    ForEach(ExportFormat.allCases) { format in
                        Text(format.displayName).tag(format)
                    }
                }
                Text(vm.options.format.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if vm.options.format.supportsCompression {
                    Picker("Compression", selection: $vm.options.compressionLevel) {
                        Text("Default").tag(0)
                        ForEach(1 ... 9, id: \.self) { level in
                            Text("Level \(level)").tag(level)
                        }
                    }
                }
            }

            Section("Contents") {
                Picker("Include", selection: $vm.options.content) {
                    ForEach(ExportContent.allCases) { content in
                        Text(content.displayName).tag(content)
                    }
                }
                .pickerStyle(.radioGroup)
            }

            Section("Schemas") {
                Picker("Scope", selection: $vm.schemaScope) {
                    ForEach(ExportViewModel.SchemaScope.allCases) { scope in
                        Text(scope.label).tag(scope)
                    }
                }
                .pickerStyle(.segmented)

                if vm.schemaScope == .selected {
                    if vm.availableSchemas.isEmpty {
                        Text("Loading schemas…")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        schemaChecklist
                        if vm.selectedSchemas.isEmpty {
                            Text("Select at least one schema to export.")
                                .font(.caption)
                                .foregroundStyle(Theme.amber)
                        }
                    }
                }
            }

            Section("Ownership & Privileges") {
                Toggle("Exclude ownership (--no-owner)", isOn: $vm.options.noOwner)
                Toggle("Exclude grant/revoke privileges (--no-privileges)", isOn: $vm.options.noPrivileges)
            }

            Section {
                Toggle("Add DROP statements (--clean)", isOn: $vm.options.clean)
                Toggle("Use IF EXISTS with DROP (--if-exists)", isOn: $vm.options.ifExists)
                    .disabled(!vm.options.clean)
                    .help(vm.options.clean ? "" : "Requires “Add DROP statements (--clean)”.")
                Toggle("Recreate the database (--create)", isOn: $vm.options.createDatabase)
            } header: {
                Text("Restore preamble")
            } footer: {
                Text("Statements added ahead of the dump to prepare the target before restoring.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            // --if-exists has no meaning without --clean; keep them coherent.
            .onChange(of: vm.options.clean) { _, isOn in
                if !isOn { vm.options.ifExists = false }
            }

            Section("Data representation") {
                Toggle("Use INSERT statements (--inserts)", isOn: $vm.options.useInserts)
                Toggle("INSERTs with column names (--column-inserts)", isOn: $vm.options.useColumnInserts)
            }

            Section("Other") {
                Toggle("Exclude comments (--no-comments)", isOn: $vm.options.noComments)
                Toggle("Include large objects", isOn: $vm.options.includeLargeObjects)
                Toggle("Quote all identifiers", isOn: $vm.options.quoteAllIdentifiers)
                Toggle("Exclude tablespace assignments", isOn: $vm.options.noTablespaces)
                Toggle("Verbose progress", isOn: $vm.options.verbose)
            }
        }
        .formStyle(.grouped)
    }

    private var schemaChecklist: some View {
        @Bindable var vm = vm
        return VStack(alignment: .leading, spacing: 2) {
            ForEach(vm.availableSchemas, id: \.self) { schema in
                Toggle(isOn: Binding(
                    get: { vm.selectedSchemas.contains(schema) },
                    set: { isOn in
                        if isOn { vm.selectedSchemas.insert(schema) }
                        else { vm.selectedSchemas.remove(schema) }
                    }
                )) {
                    Text(schema).font(Theme.mono(size: 12))
                }
                .accessibilityLabel("Include schema \(schema)")
            }
        }
    }

    // MARK: - Progress

    private var progressView: some View {
        VStack(alignment: .leading, spacing: 10) {
            TransferStatusHeader(
                isRunning: vm.isExporting,
                didFinish: vm.didFinish,
                didCancel: vm.didCancel,
                hasError: vm.errorMessage != nil,
                noun: "Export",
                activeLabel: "Exporting…"
            )

            if let path = vm.exportedPath, vm.didFinish {
                Text(path)
                    .font(Theme.mono(size: 11))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .lineLimit(2)
                    .truncationMode(.middle)
            }

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
            if vm.isExporting {
                Button("Cancel", role: .cancel) { vm.cancel() }
            } else if showsProgress {
                if vm.didFinish, let path = vm.exportedPath {
                    Button("Show in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
                    }
                    .help("Reveal the exported file in Finder")
                }
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            } else {
                Button("Export…") { presentSavePanel() }
                    .buttonStyle(.borderedProminent)
                    .disabled(vm.toolMissing || !canExport)
            }
        }
        .padding()
    }

    // MARK: - Actions

    private var canExport: Bool {
        appVM.liveConnection != nil
            && !(vm.schemaScope == .selected && vm.selectedSchemas.isEmpty)
    }

    private func loadSchemas() async {
        vm.prepare(availableSchemas: await appVM.schemasForExport())
    }

    private func presentSavePanel() {
        guard let profile = appVM.liveConnection?.profile else { return }
        let panel = NSSavePanel()
        panel.title = "Export Database"
        panel.prompt = "Export"
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = vm.suggestedFileName(database: profile.database)
        if let ext = vm.options.format.fileExtension,
           let type = UTType(filenameExtension: ext) {
            panel.allowedContentTypes = [type]
        }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task {
            guard let (connection, password) = await appVM.toolConnection() else {
                vm.errorMessage = "Not connected."
                return
            }
            vm.start(connection: connection, password: password, outputPath: url.path)
        }
    }
}

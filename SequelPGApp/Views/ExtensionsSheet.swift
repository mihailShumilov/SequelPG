import SwiftUI

/// Database-wide extensions management. Lists installed and available PG
/// extensions; lets users install/drop with a click.
struct ExtensionsSheet: View {
    @Environment(AppViewModel.self) var appVM
    @Environment(\.dismiss) private var dismiss

    @State private var installed: [ExtensionInfo] = []
    @State private var available: [ExtensionInfo] = []
    @State private var searchText: String = ""
    @State private var isLoading: Bool = true
    @State private var dropTarget: ExtensionInfo?

    /// Rows visible in the combined list — installed ones first, then the
    /// installable subset of `available` that isn't already installed.
    private var rows: [ExtensionInfo] {
        let installedNames = Set(installed.map(\.name))
        let installable = available.filter { !installedNames.contains($0.name) }
        let combined = installed + installable
        guard !searchText.isEmpty else { return combined }
        return combined.filter { ext in
            ext.name.localizedCaseInsensitiveContains(searchText)
                || (ext.comment?.localizedCaseInsensitiveContains(searchText) ?? false)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Text("Extensions")
                    .font(.headline)
                Spacer()
                SearchField(text: $searchText, prompt: "Search extensions", controlSize: .regular)
                    .frame(width: 220)
                Button {
                    Task { await reload() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .help("Refresh list")
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)

            Divider()

            if isLoading {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if rows.isEmpty {
                ContentUnavailableView.search(text: searchText)
            } else {
                List(rows) { ext in
                    row(ext)
                }
                .listStyle(.inset)
            }

            Divider()

            HStack {
                Text("\(installed.count) installed · \(available.count) available")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
        }
        .frame(width: 600, height: 500)
        .task { await reload() }
        .alert("Drop Extension?", isPresented: .init(
            get: { dropTarget != nil },
            set: { if !$0 { dropTarget = nil } }
        )) {
            Button("Cancel", role: .cancel) { dropTarget = nil }
            Button("Drop", role: .destructive) {
                if let ext = dropTarget {
                    dropTarget = nil
                    Task {
                        await appVM.dropExtension(ext.name)
                        await reload()
                    }
                }
            }
        } message: {
            Text("Extension \u{201C}\(dropTarget?.name ?? "")\u{201D} will be dropped. Dependent objects will be removed via CASCADE.")
        }
    }

    @ViewBuilder
    private func row(_ ext: ExtensionInfo) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: ext.isInstalled ? "checkmark.circle.fill" : "circle.dashed")
                .foregroundStyle(ext.isInstalled ? Color.green : Color.secondary)
                .frame(width: 20)
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(ext.name)
                        .font(.system(.body, design: .monospaced).weight(.medium))
                    if let installed = ext.installedVersion {
                        Text("v\(installed)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else if let available = ext.defaultVersion {
                        Text("v\(available) available")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if let schema = ext.schema, ext.isInstalled {
                        Tag(schema, color: .secondary)
                    }
                }
                if let comment = ext.comment, !comment.isEmpty {
                    Text(comment)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }

            Spacer()

            if ext.isInstalled {
                Button("Drop…") { dropTarget = ext }
                    .controlSize(.small)
            } else {
                Button("Install") {
                    Task {
                        await appVM.installExtension(ext.name)
                        await reload()
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }
        }
        .padding(.vertical, 4)
    }

    @MainActor
    private func reload() async {
        isLoading = true
        defer { isLoading = false }
        do {
            async let inst = appVM.dbClient.listExtensions()
            async let avail = appVM.dbClient.listAvailableExtensions()
            installed = try await inst
            available = try await avail
        } catch {
            appVM.errorMessage = error.localizedDescription
        }
    }
}

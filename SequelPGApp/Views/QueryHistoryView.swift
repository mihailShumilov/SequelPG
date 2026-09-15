import SwiftUI

/// Bottom drawer listing every statement the app has run this session —
/// the user's own queries and the catalog/DML statements issued on their
/// behalf. Entries can be copied, reopened in the editor, or re-run.
struct QueryHistoryView: View {
    @Environment(AppViewModel.self) var appVM
    @Environment(QueryHistoryViewModel.self) var historyVM
    @Environment(QueryViewModel.self) var queryVM

    var body: some View {
        let entries = historyVM.filteredEntries
        VStack(spacing: 0) {
            toolbar
            Divider()

            if entries.isEmpty {
                ContentUnavailableView {
                    Label("No Queries Yet", systemImage: "clock.arrow.circlepath")
                } description: {
                    Text("Statements you run — and the ones SequelPG runs for you — appear here.")
                }
            } else {
                List {
                    ForEach(entries) { entry in
                        entryRow(entry)
                    }
                }
                .listStyle(.inset)
            }
        }
        .background(Theme.bg2)
    }

    // MARK: - Toolbar

    private var toolbar: some View {
        HStack(spacing: 10) {
            Text("Query History")
                .font(.headline)

            Spacer()

            Picker("Source", selection: Binding(
                get: { historyVM.filterSource },
                set: { historyVM.filterSource = $0 }
            )) {
                Text("All").tag(QueryHistoryEntry.QuerySource?.none)
                Text("Mine").tag(QueryHistoryEntry.QuerySource?.some(.manual))
                Text("System").tag(QueryHistoryEntry.QuerySource?.some(.system))
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()

            Button {
                historyVM.redactSystemDMLValues.toggle()
            } label: {
                Image(systemName: historyVM.redactSystemDMLValues ? "eye.slash" : "eye")
            }
            .help(historyVM.redactSystemDMLValues
                ? "Literal values in system-issued DML are hidden. Click to show them."
                : "Literal values in system-issued DML are shown. Click to hide them.")
            .accessibilityLabel("Toggle literal redaction")

            Button {
                historyVM.clear()
            } label: {
                Image(systemName: "trash")
            }
            .disabled(historyVM.entries.isEmpty)
            .help("Clear history")
            .accessibilityLabel("Clear history")

            Button {
                appVM.showQueryHistory = false
            } label: {
                Image(systemName: "xmark")
            }
            .help("Close (⇧⌘Y)")
            .accessibilityLabel("Close query history")
        }
        .buttonStyle(.borderless)
        .controlSize(.small)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.bar)
    }

    // MARK: - Entry Row

    private func entryRow(_ entry: QueryHistoryEntry) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Image(systemName: entry.success ? "checkmark.circle.fill" : "xmark.circle.fill")
                    .foregroundStyle(entry.success ? Color.green : Color.red)
                    .font(.caption)

                Text(entry.timestamp, format: .dateTime.hour().minute().second())
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)

                Tag(entry.source == .manual ? "mine" : "system", color: entry.source == .manual ? Theme.blue : .secondary)

                if let duration = entry.duration {
                    Text("\(Int(duration * 1000)) ms")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(duration > 0.2 ? .orange : .secondary)
                }

                if let rows = entry.rowCount {
                    Text("\(rows) row\(rows == 1 ? "" : "s")")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }

                if entry.isRedacted {
                    Image(systemName: "eye.slash")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .help("Literal values redacted from this entry")
                }

                Spacer()

                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(entry.sql, forType: .string)
                } label: {
                    Image(systemName: "doc.on.doc")
                }
                .help("Copy SQL")
                .accessibilityLabel("Copy SQL")

                Button {
                    queryVM.queryText = entry.sql
                    appVM.selectedTab = .query
                } label: {
                    Image(systemName: "square.and.pencil")
                }
                .help("Open in the query editor")
                .accessibilityLabel("Open in editor")

                if entry.source == .manual {
                    Button {
                        queryVM.queryText = entry.sql
                        appVM.selectedTab = .query
                        appVM.runQueryAction(entry.sql)
                    } label: {
                        Image(systemName: "play.fill")
                    }
                    .help("Run again")
                    .accessibilityLabel("Run again")
                }
            }
            .buttonStyle(.borderless)
            .controlSize(.small)

            Text(entry.sql)
                .font(.system(.callout, design: .monospaced))
                .lineLimit(3)
                .textSelection(.enabled)

            if let error = entry.errorMessage {
                Text(error)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.red)
                    .lineLimit(2)
                    .textSelection(.enabled)
            }
        }
        .padding(.vertical, 4)
    }
}

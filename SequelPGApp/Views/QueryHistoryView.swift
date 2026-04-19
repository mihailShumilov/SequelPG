import SwiftUI

struct QueryHistoryView: View {
    @Environment(AppViewModel.self) var appVM
    @Environment(QueryHistoryViewModel.self) var historyVM
    @Environment(QueryViewModel.self) var queryVM

    var body: some View {
        // `filteredEntries` lives on the view model so the filter runs only
        // when `entries` or `filterSource` changes, not on every redraw.
        let entries = historyVM.filteredEntries
        VStack(spacing: 0) {
            Divider()
            toolbar
            Divider()

            if entries.isEmpty {
                emptyState
            } else {
                List {
                    ForEach(entries) { entry in
                        entryRow(entry)
                    }
                }
                .listStyle(.plain)
            }
        }
    }

    // MARK: - Toolbar

    private var toolbar: some View {
        HStack(spacing: 8) {
            Text("Query History")
                .font(.subheadline)
                .fontWeight(.medium)

            Spacer()

            Picker("", selection: Binding(
                get: { historyVM.filterSource },
                set: { historyVM.filterSource = $0 }
            )) {
                Text("All").tag(QueryHistoryEntry.QuerySource?.none)
                Text("Manual").tag(QueryHistoryEntry.QuerySource?.some(.manual))
                Text("System").tag(QueryHistoryEntry.QuerySource?.some(.system))
            }
            .pickerStyle(.segmented)
            .frame(width: 200)

            Button {
                historyVM.redactSystemDMLValues.toggle()
            } label: {
                Image(systemName: historyVM.redactSystemDMLValues ? "eye.slash" : "eye")
            }
            .buttonStyle(.borderless)
            .help(historyVM.redactSystemDMLValues
                  ? "System DML values are redacted (click to show literals in history)"
                  : "System DML values are shown in plaintext (click to redact)")

            Button {
                historyVM.clear()
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .disabled(historyVM.entries.isEmpty)
            .help("Clear history")

            Button {
                appVM.showQueryHistory = false
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
            .help("Close panel (Cmd+Shift+Y)")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color(nsColor: .controlBackgroundColor))
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: 8) {
            Spacer()
            Image(systemName: "clock.arrow.circlepath")
                .font(.system(size: 32))
                .foregroundStyle(.tertiary)
            Text("No queries yet")
                .font(.headline)
                .foregroundStyle(.secondary)
            Text("Execute queries to see them here.")
                .font(.caption)
                .foregroundStyle(.tertiary)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Entry Row

    private func entryRow(_ entry: QueryHistoryEntry) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                // Source badge
                Text(entry.source.rawValue)
                    .font(.system(size: 9, weight: .medium))
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(entry.source == .manual ? Color.blue.opacity(0.15) : Color.gray.opacity(0.15))
                    .foregroundStyle(entry.source == .manual ? .blue : .secondary)
                    .clipShape(.rect(cornerRadius: 3))

                // Status indicator
                Image(systemName: entry.success ? "checkmark.circle.fill" : "xmark.circle.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(entry.success ? .green : .red)

                // Timestamp
                Text(entry.timestamp, format: .dateTime.hour().minute().second())
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if let duration = entry.duration {
                    Text("\(String(format: "%.3f", duration))s")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.secondary)
                }

                if let rows = entry.rowCount {
                    Text("\(rows) row\(rows == 1 ? "" : "s")")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }

                if entry.isRedacted {
                    Image(systemName: "eye.slash.fill")
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                        .help("Literal values redacted from this entry")
                }

                Spacer()

                // Actions
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(entry.sql, forType: .string)
                } label: {
                    Image(systemName: "doc.on.doc")
                        .font(.system(size: 11))
                }
                .buttonStyle(.borderless)
                .help("Copy query")

                Button {
                    queryVM.queryText = entry.sql
                    appVM.selectedTab = .query
                } label: {
                    Image(systemName: "pencil.and.outline")
                        .font(.system(size: 11))
                }
                .buttonStyle(.borderless)
                .help("Open in editor")

                if entry.source == .manual {
                    Button {
                        queryVM.queryText = entry.sql
                        appVM.selectedTab = .query
                        Task { await appVM.executeQuery(entry.sql) }
                    } label: {
                        Image(systemName: "play.fill")
                            .font(.system(size: 10))
                    }
                    .buttonStyle(.borderless)
                    .help("Re-run query")
                }
            }

            // SQL text
            Text(entry.sql)
                .font(.system(.caption, design: .monospaced))
                .lineLimit(3)
                .foregroundStyle(.primary)
                .textSelection(.enabled)

            if let error = entry.errorMessage {
                Text(error)
                    .font(.caption2)
                    .foregroundStyle(.red)
                    .lineLimit(2)
            }
        }
        .padding(.vertical, 4)
    }
}

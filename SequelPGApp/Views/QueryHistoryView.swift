import SwiftUI

struct QueryHistoryView: View {
    @Environment(AppViewModel.self) var appVM
    @Environment(QueryHistoryViewModel.self) var historyVM
    @Environment(QueryViewModel.self) var queryVM

    private static let toolbarBackground = Theme.bg2

    var body: some View {
        let entries = historyVM.filteredEntries
        VStack(spacing: 0) {
            Rectangle().fill(Theme.line).frame(height: 1)
            toolbar
            Rectangle().fill(Theme.line).frame(height: 1)

            if entries.isEmpty {
                emptyState
            } else {
                List {
                    ForEach(entries) { entry in
                        entryRow(entry)
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .background(Theme.bg2)
            }
        }
        .background(Theme.bg2)
    }

    // MARK: - Toolbar

    private var toolbar: some View {
        HStack(spacing: 12) {
            Text("— Query history")
                .appDisplay(18)
            Text("literals redacted")
                .appMono(11, color: Theme.ink4)

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
                    .foregroundStyle(Theme.ink3)
                    .font(.system(size: 11))
            }
            .buttonStyle(.plain)
            .help(historyVM.redactSystemDMLValues
                  ? "System DML values are redacted (click to show literals in history)"
                  : "System DML values are shown in plaintext (click to redact)")

            Button {
                historyVM.clear()
            } label: {
                Image(systemName: "trash")
                    .foregroundStyle(Theme.rose)
                    .font(.system(size: 11))
            }
            .buttonStyle(.plain)
            .disabled(historyVM.entries.isEmpty)
            .help("Clear history")

            HStack(spacing: 3) {
                AppKbd(key: "⌘")
                AppKbd(key: "⇧")
                AppKbd(key: "Y")
            }
            .opacity(0.85)

            Button {
                appVM.showQueryHistory = false
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Theme.ink3)
            }
            .buttonStyle(.plain)
            .help("Close panel (Cmd+Shift+Y)")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 9)
        .background(Theme.bg2)
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "clock.arrow.circlepath")
                .font(.system(size: 30))
                .foregroundStyle(Theme.ink4)
            Text("No queries yet.")
                .appDisplay(22)
            Text("Execute queries to see them here.")
                .appBody()
                .foregroundStyle(Theme.ink3)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.bg2)
    }

    // MARK: - Entry Row

    private func entryRow(_ entry: QueryHistoryEntry) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 8) {
                Tag(entry.source.rawValue, color: entry.source == .manual ? Theme.blue : Theme.ink3)

                Image(systemName: entry.success ? "checkmark.circle.fill" : "xmark.circle.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(entry.success ? Theme.accent : Theme.rose)

                Text(entry.timestamp, format: .dateTime.hour().minute().second())
                    .appMono(11, color: Theme.ink4)

                if let duration = entry.duration {
                    Text("\(Int(duration * 1000)) ms")
                        .appMono(11, color: duration > 0.2 ? Theme.amber : Theme.ink3)
                }

                if let rows = entry.rowCount {
                    Text("\(rows)")
                        .appMono(11, color: Theme.ink3)
                }

                if entry.isRedacted {
                    Image(systemName: "eye.slash.fill")
                        .font(.system(size: 9))
                        .foregroundStyle(Theme.ink4)
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
                .font(Theme.mono(size: 11.5))
                .lineLimit(3)
                .foregroundStyle(Theme.ink2)
                .textSelection(.enabled)

            if let error = entry.errorMessage {
                Text(error)
                    .font(Theme.mono(size: 11))
                    .foregroundStyle(Theme.rose)
                    .lineLimit(2)
            }
        }
        .padding(.vertical, 6)
        .listRowBackground(Theme.bg2)
    }
}

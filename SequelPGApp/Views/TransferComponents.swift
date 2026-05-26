import SwiftUI

/// Shared building blocks for the Export and Import sheets. Both sheets present
/// the same live-output log, connection summary, tool-missing state, and status
/// header, so they live here in one place rather than being duplicated.

/// Scrolling, auto-following view of streamed tool output. Uses each line's
/// stable `id` (not its array offset) so trimming the front of the buffer
/// doesn't force a full re-diff, and follows the tail via a fixed bottom anchor.
struct TransferLogView: View {
    let lines: [ProgressLine]

    private let bottomAnchor = "transfer-log-bottom"

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    ForEach(lines) { line in
                        Text(line.text)
                            .font(Theme.mono(size: 10))
                            .foregroundStyle(Theme.ink2)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                    }
                    Color.clear.frame(height: 1).id(bottomAnchor)
                }
                .padding(8)
            }
            .background(Theme.panel)
            .clipShape(.rect(cornerRadius: 6))
            .overlay(
                RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.line, lineWidth: 1)
            )
            .onChange(of: lines.count) { _, _ in
                proxy.scrollTo(bottomAnchor, anchor: .bottom)
            }
        }
    }
}

/// One-line connection identity (`user@host:port/db`) plus the resolved tool
/// version, shown in each sheet's footer.
struct ConnectionSummaryView: View {
    let profile: ConnectionProfile
    let toolVersion: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("\(profile.username)@\(profile.host):\(profile.port)/\(profile.database)")
                .font(Theme.mono(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            if let toolVersion {
                Text(toolVersion).font(.caption2).foregroundStyle(.tertiary)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Connected to \(profile.username) at \(profile.host) port \(profile.port), database \(profile.database)")
    }
}

/// Empty state shown when the required client binary can't be located.
struct ToolMissingView: View {
    let toolName: String

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "wrench.and.screwdriver")
                .font(.largeTitle)
                .foregroundStyle(Theme.ink3)
                .accessibilityHidden(true)
            Text("\(toolName) not found")
                .font(.headline)
            Text("Install the PostgreSQL client tools (e.g. `brew install libpq` or Postgres.app) and, if needed, set their location in Settings → General.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }
}

/// Status line at the top of the progress view. `noun` is "Export"/"Import";
/// `activeLabel` is "Exporting…"/"Importing…".
struct TransferStatusHeader: View {
    let isRunning: Bool
    let didFinish: Bool
    let didCancel: Bool
    let hasError: Bool
    let noun: String
    let activeLabel: String

    var body: some View {
        HStack(spacing: 8) {
            if isRunning {
                ProgressView().controlSize(.small)
                Text(activeLabel).font(.callout.weight(.medium))
            } else if hasError {
                icon("xmark.octagon.fill", Theme.rose)
                Text("\(noun) failed").font(.callout.weight(.medium))
            } else if didCancel {
                icon("stop.circle.fill", Theme.amber)
                Text("\(noun) cancelled").font(.callout.weight(.medium))
            } else if didFinish {
                icon("checkmark.circle.fill", .green)
                Text("\(noun) complete").font(.callout.weight(.medium))
            }
            Spacer()
        }
    }

    private func icon(_ name: String, _ color: Color) -> some View {
        Image(systemName: name)
            .foregroundStyle(color)
            .accessibilityHidden(true)
    }
}

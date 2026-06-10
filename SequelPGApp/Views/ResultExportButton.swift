import AppKit
import SwiftUI

/// "Export ▾" menu shared by the query results footer and the content tab's
/// pagination bar. Presents the save panel itself (a UI concern, like the
/// directory picker in Settings); the actual serialization + file write goes
/// through `AppViewModel.exportResult` per the no-I/O-in-Views rule.
struct ResultExportButton: View {
    @Environment(AppViewModel.self) private var appVM

    /// The grid currently on screen — pass the *sorted* result so the file
    /// matches what the user is looking at.
    let result: QueryResult?

    /// Base name pre-filled in the save panel (without extension).
    var defaultFileName: String = "result"

    private var isDisabled: Bool {
        guard let result else { return true }
        return result.columns.isEmpty
    }

    var body: some View {
        Menu {
            ForEach(ResultExportFormat.allCases) { format in
                Button("Export as \(format.label)…") { export(format) }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "square.and.arrow.up")
                    .font(.system(size: 10))
                Text("Export")
                    .font(Theme.mono(size: 11))
            }
            .foregroundStyle(Theme.ink3)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .disabled(isDisabled)
        .help("Export the rows currently shown to a CSV or JSON file")
        .accessibilityLabel("Export results")
    }

    private func export(_ format: ResultExportFormat) {
        guard let result else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [format.contentType]
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        panel.nameFieldStringValue = "\(defaultFileName).\(format.fileExtension)"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        appVM.exportResult(result, format: format, to: url)
    }
}

import Foundation
import OSLog

/// Drives the database export sheet: tracks the `pg_dump` options, locates the
/// binary, runs the export, and surfaces live progress / errors. The actual
/// command construction lives in `ExportOptions` (testable in isolation); this
/// type orchestrates the run and owns the UI state.
@MainActor
@Observable
final class ExportViewModel {
    enum SchemaScope: String, CaseIterable, Identifiable {
        case all
        case selected
        var id: String { rawValue }
        var label: String { self == .all ? "All schemas" : "Selected schemas" }
    }

    var options = ExportOptions()
    var schemaScope: SchemaScope = .all
    var selectedSchemas: Set<String> = []
    var availableSchemas: [String] = []

    /// Resolved `pg_dump` path, `nil` until located / when missing.
    var toolPath: String?
    var toolVersion: String?
    var toolMissing = false

    var isExporting = false
    var progressLines: [ProgressLine] = []
    var errorMessage: String?
    var didFinish = false
    var didCancel = false
    var exportedPath: String?

    /// Keep the progress feed bounded — a verbose dump of a large schema can
    /// emit thousands of lines, which would bloat the view's diffing.
    private let maxProgressLines = 500
    private var nextLineID = 0

    @ObservationIgnored private var service: DatabaseTransferService?
    @ObservationIgnored private var task: Task<Void, Never>?

    /// Locates `pg_dump` and probes its version off the main actor. Driven by
    /// the sheet's `.task`, so it's cancelled automatically when the sheet closes.
    func locateTool() async {
        let path = await Task.detached { PGToolchain.locate(.pgDump) }.value
        toolPath = path
        toolMissing = path == nil
        guard path != nil else { return }
        toolVersion = await Task.detached { PGToolchain.version(of: .pgDump) }.value
    }

    func prepare(availableSchemas: [String]) {
        self.availableSchemas = availableSchemas
    }

    /// Default file name (without directory) for the save panel, based on the
    /// database name, current date, and chosen format.
    func suggestedFileName(database: String) -> String {
        let stamp = Self.fileNameDateFormatter.string(from: Date())
        let base = "\(database)_\(stamp)"
        if let ext = options.format.fileExtension {
            return "\(base).\(ext)"
        }
        return base
    }

    /// Starts the export to `outputPath`. `connection` must already carry the
    /// effective endpoint (resolved via `AppViewModel.toolConnection()`).
    func start(connection: PGToolConnection, password: String?, outputPath: String) {
        guard let toolPath else {
            errorMessage = "pg_dump was not found. Set its location in Settings."
            return
        }
        // Fold the schema scope into the options just before running.
        options.selectedSchemas = schemaScope == .selected
            ? availableSchemas.filter { selectedSchemas.contains($0) }
            : []

        isExporting = true
        didFinish = false
        didCancel = false
        errorMessage = nil
        progressLines = []
        nextLineID = 0
        exportedPath = nil

        let service = DatabaseTransferService()
        self.service = service
        let options = self.options

        task?.cancel()
        task = Task { @MainActor in
            do {
                let stream = await service.export(
                    options: options,
                    connection: connection,
                    password: password,
                    toolPath: toolPath,
                    outputPath: outputPath
                )
                for try await line in stream {
                    appendProgress(line)
                }
                isExporting = false
                didFinish = true
                exportedPath = outputPath
                Log.app.info("Export completed to \(outputPath, privacy: .public)")
            } catch {
                isExporting = false
                // A user-initiated cancel terminates pg_dump, which surfaces as
                // a non-zero exit; don't show that as a failure.
                if !didCancel, !(error is CancellationError) {
                    errorMessage = error.localizedDescription
                }
            }
        }
    }

    func cancel() {
        guard isExporting else { return }
        didCancel = true
        task?.cancel()
        let service = self.service
        Task { await service?.cancel() }
    }

    private func appendProgress(_ text: String) {
        progressLines.append(ProgressLine(id: nextLineID, text: text))
        nextLineID += 1
        if progressLines.count > maxProgressLines {
            progressLines.removeFirst(progressLines.count - maxProgressLines)
        }
    }

    private static let fileNameDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd_HHmm"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter
    }()
}

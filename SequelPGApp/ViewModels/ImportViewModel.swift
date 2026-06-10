import Foundation
import OSLog

/// Drives the SQL import sheet: tracks the chosen file and per-import safety
/// options, locates `psql`, runs the import, and surfaces live progress /
/// errors. Command construction lives in `ImportOptions` (testable in isolation).
@MainActor
@Observable
final class ImportViewModel {
    var options = ImportOptions()
    var inputURL: URL?

    /// Resolved `psql` path, `nil` until located / when missing.
    var toolPath: String?
    var toolVersion: String?
    var toolMissing = false

    var isImporting = false
    var progressLines: [ProgressLine] = []
    var errorMessage: String?
    var didFinish = false
    var didCancel = false

    private let maxProgressLines = 500
    private var nextLineID = 0

    @ObservationIgnored private var service: DatabaseTransferService?
    @ObservationIgnored private var task: Task<Void, Never>?

    /// Locates `psql` and probes its version off the main actor. Driven by the
    /// sheet's `.task`, so it's cancelled automatically when the sheet closes.
    func locateTool() async {
        let path = await Task.detached { PGToolchain.locate(.psql) }.value
        toolPath = path
        toolMissing = path == nil
        guard path != nil else { return }
        toolVersion = await Task.detached { PGToolchain.version(of: .psql) }.value
    }

    /// Starts importing the selected file into the connected database.
    func start(connection: PGToolConnection, password: String?) {
        guard let toolPath else {
            errorMessage = "psql was not found. Set its location in Settings."
            return
        }
        guard let inputURL else {
            errorMessage = "Choose a .sql file to import."
            return
        }

        isImporting = true
        didFinish = false
        didCancel = false
        errorMessage = nil
        progressLines = []
        nextLineID = 0

        let service = DatabaseTransferService()
        self.service = service
        let options = self.options
        let path = inputURL.path

        task?.cancel()
        task = Task { @MainActor in
            // defer (not per-branch resets) so the spinner can't survive an
            // early exit — e.g. the task being cancelled mid-stream.
            defer { isImporting = false }
            do {
                let stream = await service.runImport(
                    options: options,
                    connection: connection,
                    password: password,
                    toolPath: toolPath,
                    inputPath: path
                )
                for try await line in stream {
                    appendProgress(line)
                }
                didFinish = true
                Log.app.info("Import completed from \(path, privacy: .public)")
            } catch {
                // A user-initiated cancel terminates psql, surfacing as a
                // non-zero exit; don't show that as a failure.
                if !didCancel, !(error is CancellationError) {
                    errorMessage = error.localizedDescription
                }
            }
        }
    }

    func cancel() {
        guard isImporting else { return }
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
}

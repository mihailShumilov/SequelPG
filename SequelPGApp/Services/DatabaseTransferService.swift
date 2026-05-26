import Foundation
import OSLog

/// Spawns `pg_dump` / `psql` child processes to export and import databases.
///
/// Peer to `SSHTunnelService`: the sole component that launches the PostgreSQL
/// client binaries. Output is streamed line-by-line so the UI can show live
/// progress, and the running process can be cancelled. One instance drives a
/// single operation at a time; the view models create a fresh instance per run.
actor DatabaseTransferService {
    private var process: Process?

    /// Terminates the running child process, if any. Safe to call repeatedly.
    func cancel() {
        guard let process, process.isRunning else { return }
        process.terminate()
        Log.app.info("Database transfer cancelled (PID \(process.processIdentifier))")
    }

    /// Exports the connected database with `pg_dump`. The returned stream emits
    /// each line of tool output, finishes on success, and throws
    /// `AppError.exportFailed` on a non-zero exit.
    func export(
        options: ExportOptions,
        connection: PGToolConnection,
        password: String?,
        toolPath: String,
        outputPath: String
    ) -> AsyncThrowingStream<String, Error> {
        let arguments = options.arguments(connection: connection, outputPath: outputPath)
        return run(
            toolPath: toolPath,
            arguments: arguments,
            password: password,
            sslMode: connection.pgSSLMode,
            label: "pg_dump",
            makeError: AppError.exportFailed
        )
    }

    /// Imports a `.sql` file into the connected database with `psql`. Streams
    /// output, finishes on success, and throws `AppError.importFailed` on a
    /// non-zero exit.
    func runImport(
        options: ImportOptions,
        connection: PGToolConnection,
        password: String?,
        toolPath: String,
        inputPath: String
    ) -> AsyncThrowingStream<String, Error> {
        let arguments = options.arguments(connection: connection, inputPath: inputPath)
        return run(
            toolPath: toolPath,
            arguments: arguments,
            password: password,
            sslMode: connection.pgSSLMode,
            label: "psql",
            makeError: AppError.importFailed
        )
    }

    // MARK: - Private

    private func run(
        toolPath: String,
        arguments: [String],
        password: String?,
        sslMode: String,
        label: String,
        makeError: @escaping @Sendable (String) -> AppError
    ) -> AsyncThrowingStream<String, Error> {
        let (stream, continuation) = AsyncThrowingStream<String, Error>.makeStream()

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: toolPath)
        proc.arguments = arguments
        proc.qualityOfService = .userInitiated

        // Credentials and connection settings go through the environment, never
        // the argument vector (which is visible in `ps`).
        var environment = ProcessInfo.processInfo.environment
        // Drop any inherited PGPASSWORD so a value from the app's own parent
        // environment can't leak into the tool when this connection has none.
        environment.removeValue(forKey: "PGPASSWORD")
        if let password, !password.isEmpty {
            environment["PGPASSWORD"] = password
        }
        environment["PGSSLMODE"] = sslMode
        environment["PGCONNECT_TIMEOUT"] = "10"
        proc.environment = environment

        // pg_dump's progress (`--verbose`) and psql's diagnostics arrive on
        // stderr; psql command tags arrive on stdout. Merge both into one feed.
        let collector = OutputCollector(continuation: continuation)
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        proc.standardOutput = stdoutPipe
        proc.standardError = stderrPipe
        stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
            collector.ingest(handle.availableData)
        }
        stderrPipe.fileHandleForReading.readabilityHandler = { handle in
            collector.ingest(handle.availableData)
        }

        proc.terminationHandler = { process in
            // Detach the handlers so the pipes can be closed and drained.
            stdoutPipe.fileHandleForReading.readabilityHandler = nil
            stderrPipe.fileHandleForReading.readabilityHandler = nil
            collector.ingest(stdoutPipe.fileHandleForReading.readDataToEndOfFile())
            collector.ingest(stderrPipe.fileHandleForReading.readDataToEndOfFile())
            collector.flush()

            if process.terminationStatus == 0 {
                continuation.finish()
            } else {
                let detail = collector.errorSummary().isEmpty
                    ? "\(label) exited with status \(process.terminationStatus)."
                    : collector.errorSummary()
                continuation.finish(throwing: makeError(detail))
            }
        }

        do {
            try proc.run()
            process = proc
            Log.app.info("\(label, privacy: .public) started (PID \(proc.processIdentifier))")
        } catch {
            continuation.finish(throwing: makeError("Failed to launch \(label): \(error.localizedDescription)"))
        }

        return stream
    }
}

/// Buffers raw pipe data, splits it into lines, forwards each line to the
/// stream, and retains a bounded tail for the failure message. `readabilityHandler`
/// fires on arbitrary threads and both pipes share one instance, so access is
/// serialized with a lock.
private final class OutputCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer = Data()
    private var tail: [String] = []
    private let continuation: AsyncThrowingStream<String, Error>.Continuation

    /// Cap on retained trailing lines used to build the error summary.
    private let maxTailLines = 40
    private let newline = UInt8(ascii: "\n")

    init(continuation: AsyncThrowingStream<String, Error>.Continuation) {
        self.continuation = continuation
    }

    func ingest(_ data: Data) {
        guard !data.isEmpty else { return }
        lock.lock()
        buffer.append(data)
        let lines = drainCompleteLinesLocked()
        lock.unlock()
        // Yield outside the lock: continuation.yield() can apply back-pressure,
        // and blocking here while holding the lock would stall the other pipe's
        // readabilityHandler and could fill the kernel pipe buffer.
        yield(lines)
    }

    /// Emits any trailing bytes that weren't newline-terminated.
    func flush() {
        lock.lock()
        let remaining = buffer
        buffer.removeAll()
        lock.unlock()
        if let line = Self.normalize(remaining) { yield([line]) }
    }

    func errorSummary() -> String {
        lock.lock()
        defer { lock.unlock() }
        return tail.joined(separator: "\n")
    }

    /// Splits complete (newline-terminated) lines out of `buffer`. Caller holds `lock`.
    private func drainCompleteLinesLocked() -> [String] {
        var lines: [String] = []
        while let index = buffer.firstIndex(of: newline) {
            let lineData = buffer[buffer.startIndex ..< index]
            buffer.removeSubrange(buffer.startIndex ... index)
            if let line = Self.normalize(lineData) { lines.append(line) }
        }
        return lines
    }

    private func yield(_ lines: [String]) {
        guard !lines.isEmpty else { return }
        lock.lock()
        tail.append(contentsOf: lines)
        if tail.count > maxTailLines { tail.removeFirst(tail.count - maxTailLines) }
        lock.unlock()
        for line in lines { continuation.yield(line) }
    }

    private static func normalize(_ data: Data) -> String? {
        guard let raw = String(data: data, encoding: .utf8) else { return nil }
        let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return line.isEmpty ? nil : line
    }
}

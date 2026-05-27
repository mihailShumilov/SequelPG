import Foundation

/// Persists ERD view layouts (node positions, collapse/hide state, viewport) as
/// JSON under Application Support, keyed by connection profile + schema.
///
/// Deliberately file-based rather than UserDefaults: `ConnectionStore` is the
/// only component that owns UserDefaults in this app, and per-schema layouts can
/// grow large enough that a defaults plist is the wrong home for them.
struct ERDLayoutStore {
    private let directory: URL
    private let fileManager: FileManager

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
        let base = (try? fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )) ?? fileManager.temporaryDirectory
        self.directory = base
            .appendingPathComponent("SequelPG", isDirectory: true)
            .appendingPathComponent("erd-layouts", isDirectory: true)
    }

    /// Returns the saved layout for a profile+schema, or `nil` when none exists
    /// or the file was written by a newer, unreadable format version.
    func load(profileID: UUID, schema: String) -> ERDLayout? {
        let url = fileURL(profileID: profileID, schema: schema)
        guard
            let data = try? Data(contentsOf: url),
            let layout = try? JSONDecoder().decode(ERDLayout.self, from: data),
            layout.isReadable
        else {
            return nil
        }
        return layout
    }

    /// Writes the layout atomically. Failures are logged, not thrown — a missing
    /// saved layout simply means the diagram falls back to auto-layout next time.
    func save(_ layout: ERDLayout, profileID: UUID, schema: String) {
        let url = fileURL(profileID: profileID, schema: schema)
        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(layout)
            try data.write(to: url, options: .atomic)
        } catch {
            Log.app.error("ERD: failed to save layout - \(error.localizedDescription, privacy: .public)")
        }
    }

    private func fileURL(profileID: UUID, schema: String) -> URL {
        // A schema name may contain characters that are unsafe in a filename, so
        // percent-encode it; the profile UUID keeps keys unique across profiles.
        let safeSchema = schema.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "schema"
        return directory.appendingPathComponent("\(profileID.uuidString)__\(safeSchema).json")
    }
}

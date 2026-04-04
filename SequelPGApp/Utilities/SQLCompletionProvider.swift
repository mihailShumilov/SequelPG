import Foundation

/// Provides SQL autocompletion candidates from keywords and database metadata.
enum SQLCompletionProvider {
    struct Metadata: Equatable {
        var schemas: [String]
        var tables: [DBObject]
        var columns: [ColumnInfo]
    }

    /// Returns completions for the given partial word, ordered by relevance.
    static func completions(for partial: String, metadata: Metadata) -> [String] {
        guard !partial.isEmpty else { return [] }

        var results: [String] = []
        let lowered = partial.lowercased()

        // SQL keywords (uppercased to match formatter convention)
        for kw in SQLFormatter.keywords where kw.hasPrefix(lowered) {
            results.append(kw.uppercased())
        }
        results.sort()

        // Schema names
        let matchingSchemas = metadata.schemas
            .filter { $0.lowercased().hasPrefix(lowered) }
            .sorted()
        results.append(contentsOf: matchingSchemas)

        // Table/view names
        let matchingTables = metadata.tables
            .map(\.name)
            .filter { $0.lowercased().hasPrefix(lowered) }
            .sorted()
        results.append(contentsOf: matchingTables)

        // Column names
        let matchingColumns = metadata.columns
            .map(\.name)
            .filter { $0.lowercased().hasPrefix(lowered) }
            .sorted()
        results.append(contentsOf: matchingColumns)

        // Deduplicate while preserving order
        var seen = Set<String>()
        return results.filter { seen.insert($0).inserted }
    }
}

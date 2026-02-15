import Foundation

/// Manages the query editor state and results.
@MainActor
final class QueryViewModel: ObservableObject {
    @Published var queryText = ""
    @Published var result: QueryResult?
    @Published var isExecuting = false
    @Published var errorMessage: String?
    @Published var showErrorDetail = false
}

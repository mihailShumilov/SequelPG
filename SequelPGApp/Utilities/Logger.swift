import OSLog

/// Centralized OSLog loggers for the application.
enum Log {
    static let app = Logger(subsystem: "com.sequelpg.app", category: "app")
    static let db = Logger(subsystem: "com.sequelpg.app", category: "db")
    static let ui = Logger(subsystem: "com.sequelpg.app", category: "ui")
    static let perf = Logger(subsystem: "com.sequelpg.app", category: "perf")
}

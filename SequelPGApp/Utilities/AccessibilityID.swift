import Foundation

/// Stable accessibility identifiers for UI automation.
///
/// The UI scenario driver (`UITest/`) compiles this same file through a
/// symlink, so scenarios reference the constants the views use. Renaming a
/// value is safe; deleting one breaks the matching scenario at compile time.
enum A11yID {
    enum StartPage {
        static let connectionList = "startPage.connectionList"
        static let addConnection = "startPage.addConnection"
        static let deleteConnection = "startPage.deleteConnection"
        static let testConnection = "startPage.testConnection"
        static let connect = "startPage.connect"
        static let testSucceeded = "startPage.testSucceeded"
        static let testFailed = "startPage.testFailed"
        static let validationErrors = "startPage.validationErrors"
        static let emptyState = "startPage.emptyState"
    }

    enum Form {
        static let name = "form.name"
        static let host = "form.host"
        static let port = "form.port"
        static let database = "form.database"
        static let username = "form.username"
        static let password = "form.password"
        static let sslMode = "form.sslMode"
        static let sslSkipVerification = "form.sslSkipVerification"
        static let sslRootCert = "form.sslRootCert"
        static let sslRootCertChoose = "form.sslRootCertChoose"
        static let useSSH = "form.useSSH"
        static let sshHost = "form.sshHost"
        static let sshPort = "form.sshPort"
        static let sshUser = "form.sshUser"
        static let sshAuth = "form.sshAuth"
        static let sshKeyPath = "form.sshKeyPath"
        static let sshPassword = "form.sshPassword"
        static let mcpAccess = "form.mcpAccess"
    }

    enum Settings {
        static let mcpEnabled = "settings.mcpEnabled"
        static func mcpInstall(_ client: String) -> String { "settings.mcpInstall.\(client)" }
    }

    enum Workspace {
        static let modePicker = "workspace.modePicker"
        static let refresh = "workspace.refresh"
        static let databaseMenu = "workspace.databaseMenu"
    }

    enum Navigator {
        static let list = "navigator.list"
        static let filter = "navigator.filter"

        static func object(schema: String, name: String) -> String {
            "navigator.object.\(schema).\(name)"
        }

        static func schema(_ name: String) -> String {
            "navigator.schema.\(name)"
        }

        static func category(schema: String, _ category: String) -> String {
            "navigator.category.\(schema).\(category)"
        }
    }

    enum Query {
        static let editor = "query.editor"
        static let run = "query.run"
        static let stop = "query.stop"
        static let explain = "query.explain"
        static let analyze = "query.analyze"
        static let clear = "query.clear"
        static let resultsTabs = "query.resultsTabs"
        static let grid = "query.grid"
        static let rowCount = "query.rowCount"
        static let truncated = "query.truncated"
        static let errorBanner = "query.errorBanner"
        static let commandCompleted = "query.commandCompleted"
        static let planView = "query.planView"
    }

    enum Content {
        static let grid = "content.grid"
        static let insertRow = "content.insertRow"
        static let deleteRow = "content.deleteRow"
        static let toggleFilter = "content.toggleFilter"
        static let previousPage = "content.previousPage"
        static let nextPage = "content.nextPage"
        static let approximateRowCount = "content.approximateRowCount"

        /// Value field for `column` in the Insert Row sheet.
        static func insertField(_ column: String) -> String {
            "content.insert.\(column)"
        }
    }

    enum Results {
        static let export = "results.export"
    }

    enum FieldEditor {
        static let value = "fieldEditor.value"
        static let save = "fieldEditor.save"
        static let cancel = "fieldEditor.cancel"
    }
}

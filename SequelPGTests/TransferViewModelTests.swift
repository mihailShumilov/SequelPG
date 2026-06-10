import XCTest
@testable import SequelPG

/// Error-path and state tests for the export/import sheet ViewModels. The
/// happy path shells out to real `pg_dump`/`psql` processes, so it's covered
/// by manual verification; these tests pin down the cheap deterministic
/// guards that previously had no coverage.
@MainActor
final class TransferViewModelTests: XCTestCase {
    private var connection: PGToolConnection {
        PGToolConnection(host: "127.0.0.1", port: 5432, database: "db", username: "u", sslMode: .prefer)
    }

    // MARK: - ExportViewModel

    func testExportStartWithoutToolSetsErrorAndDoesNotRun() {
        let vm = ExportViewModel()
        vm.toolPath = nil
        vm.start(connection: connection, password: nil, outputPath: "/tmp/out.sql")
        XCTAssertFalse(vm.isExporting)
        XCTAssertNotNil(vm.errorMessage)
        XCTAssertFalse(vm.didFinish)
    }

    func testExportCancelIsNoOpWhenIdle() {
        let vm = ExportViewModel()
        vm.cancel()
        XCTAssertFalse(vm.didCancel)
    }

    func testSuggestedFileNameUsesDatabaseAndExtension() {
        let vm = ExportViewModel()
        vm.options.format = .plain
        let name = vm.suggestedFileName(database: "shop")
        XCTAssertTrue(name.hasPrefix("shop_"), name)
        XCTAssertTrue(name.hasSuffix(".sql"), name)
    }

    func testPrepareStoresAvailableSchemas() {
        let vm = ExportViewModel()
        vm.prepare(availableSchemas: ["public", "sales"])
        XCTAssertEqual(vm.availableSchemas, ["public", "sales"])
    }

    // MARK: - ImportViewModel

    func testImportStartWithoutToolSetsError() {
        let vm = ImportViewModel()
        vm.toolPath = nil
        vm.inputURL = URL(fileURLWithPath: "/tmp/in.sql")
        vm.start(connection: connection, password: nil)
        XCTAssertFalse(vm.isImporting)
        XCTAssertNotNil(vm.errorMessage)
    }

    func testImportStartWithoutFileSetsError() {
        let vm = ImportViewModel()
        vm.toolPath = "/usr/bin/true"
        vm.inputURL = nil
        vm.start(connection: connection, password: nil)
        XCTAssertFalse(vm.isImporting)
        XCTAssertEqual(vm.errorMessage, "Choose a .sql file to import.")
    }

    func testImportCancelIsNoOpWhenIdle() {
        let vm = ImportViewModel()
        vm.cancel()
        XCTAssertFalse(vm.didCancel)
    }
}

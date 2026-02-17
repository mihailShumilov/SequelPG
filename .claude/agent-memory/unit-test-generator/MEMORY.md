# SequelPG Testing Conventions

## Project Structure
- Xcode project: `SequelPG.xcodeproj` with schemes `SequelPG` (app) and `SequelPGTests`
- Source: `SequelPGApp/` (ViewModels, Models, etc.)
- Tests: `SequelPGTests/`
- Import: `@testable import SequelPG`

## Testing Framework & Style
- XCTest framework, no third-party test libraries
- `final class FooTests: XCTestCase` naming
- Test methods: `testDescriptiveCamelCase` (e.g., `testLoadAllReturnsEmptyByDefault`)
- Use `setUp()` / `tearDown()` with `sut` pattern (subject under test)
- Assertions: `XCTAssertEqual`, `XCTAssertTrue`, `XCTAssertNil`, `XCTAssertNotEqual`
- `// MARK: - Helpers` section for factory methods
- Helper factories: `private func makeFoo(...) -> Foo`

## Key Models
- `DBObject(schema:name:type:)` where type is `.table` or `.view`
- `ConnectionProfile(name:host:port:database:username:)` with `id: UUID`
- `CellValue` enum: `.null`, `.text(String)`
- `AppError` enum with `.connectionFailed`, `.queryTimeout`, `.validationFailed`, `.notConnected`, `.foreignKeyViolation`, `.underlying`
- `AppViewModel.CascadeDeleteContext` struct: `schema`, `table`, `pkValues`, `errorMessage`, `source` (MainTab)

## MainActor Testing
- ViewModels are `@MainActor` -- test classes must be `@MainActor` too
- Works with synchronous test methods directly (no need for `await`)

## Combine / Publisher Testing
- Import `Combine` when testing `objectWillChange` on ObservableObject VMs
- Use `XCTestExpectation` + `vm.objectWillChange.sink` to verify publisher fires
- Cancel the cancellable after assertion; timeout 1.0s is sufficient

## QueryResult Construction (for test helpers)
- `QueryResult(columns:rows:executionTime:rowsAffected:isTruncated:)`
- Minimal: `QueryResult(columns: ["a"], rows: [[.text("1")]], executionTime: 0.1, rowsAffected: nil, isTruncated: false)`

## Mocking Patterns
- `KeychainServiceProtocol` (Sendable) -- mock with in-memory dict + call tracking arrays
- `ConnectionStore` uses DI via `UserDefaults(suiteName:)` -- use ephemeral suite per test
- `ConnectionListViewModel` takes concrete `ConnectionStore` + `KeychainServiceProtocol`
- `PostgresClientProtocol` -- **actor-based protocol**; mock with `actor MockDatabaseClient`
  - Actor property mutation from `@MainActor` tests requires `await` setter methods
  - Define setter helpers in an extension: `func setShouldThrowOnConnect(_ value: Bool)`
- Mocks are defined at file scope (not private) in test files; no shared mock files yet
- Use `@unchecked Sendable` on mock classes that track calls with mutable arrays
- `AppViewModel` DI: `init(connectionStore:keychainService:dbClient:)` -- all three injectable
- MockDatabaseClient has `allRunQuerySQLs: [String]` array + `getAllRunQuerySQLs()` -- use when methods chain multiple queries (e.g., delete then reload)
- Mocks in `AppViewModelTests.swift` are `internal` (file-scope, no access modifier) and reusable from other test files in the same target
- MockDatabaseClient has `runQueryHandler: (@Sendable (String) throws -> QueryResult)?` for per-SQL-call behavior control
  - Set via `setRunQueryHandler(...)` -- overrides `shouldThrowOnRunQuery`/`stubbedQueryResult` when non-nil
  - Useful for testing methods that call `runQuery` multiple times with different SQL (e.g., `executeCascadeDelete`)

## Xcode Project Registration (pbxproj)
- New test files MUST be added to `project.pbxproj` in 4 places:
  1. PBXBuildFile section (AA-prefixed ID, e.g. `AA10000000000000000023`)
  2. PBXFileReference section (AB-prefixed ID, e.g. `AB10000000000000000023`)
  3. SequelPGTests PBXGroup children list (`AC20000000000000000009`)
  4. Test target PBXSourcesBuildPhase files list (`AF10000000000000000013`)
- IDs follow pattern: `AA1000000000000000XXXX` (build) / `AB1000000000000000XXXX` (ref)
- Next available suffix: `0026` (after CascadeDeleteTests used `0025A`)

## Build & Run Tests
```bash
xcodebuild test -project SequelPG.xcodeproj -scheme SequelPG \
  -destination 'platform=macOS' \
  -only-testing:SequelPGTests/TestClassName 2>&1 | tail -60
```

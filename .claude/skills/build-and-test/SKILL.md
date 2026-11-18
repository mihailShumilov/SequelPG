---
name: build-and-test
description: Build SequelPG, run the unit, integration and UI test suites (all, one class, or one method), and format Swift with SwiftFormat. Use after any Swift change, before committing, or when the user asks to build, test, or check that the project compiles.
---

# Build and test SequelPG

Run from the repository root (`SequelPG/`). Filter `xcodebuild` output — the raw log is thousands of lines.

## Build

```bash
xcodebuild -project SequelPG.xcodeproj -scheme SequelPG -configuration Debug build 2>&1 \
  | grep -E '(error:|warning: .*SequelPGApp|BUILD SUCCEEDED|BUILD FAILED)' | head -40
```

## Test

```bash
# Everything
xcodebuild test -project SequelPG.xcodeproj -scheme SequelPG -destination 'platform=macOS' 2>&1 \
  | grep -E '(error:|failed|Executed .* tests|TEST SUCCEEDED|TEST FAILED)' | tail -40

# One class / one method
xcodebuild test -project SequelPG.xcodeproj -scheme SequelPG -destination 'platform=macOS' \
  -only-testing:SequelPGTests/TableViewModelTests 2>&1 | grep -E '(error:|failed|passed|TEST )' | tail -40
xcodebuild test -project SequelPG.xcodeproj -scheme SequelPG -destination 'platform=macOS' \
  -only-testing:SequelPGTests/TableViewModelTests/testSomething 2>&1 | tail -20
```

Unit tests (`SequelPGTests`) never need a live database — they use `MockDatabaseClient`.

## Live-database suites (local only)

| Suite | Command | Needs |
| --- | --- | --- |
| Unit | `make -C test-db test-unit` | nothing |
| Integration (`SequelPGIntegrationTests`, ~45 s) | `make -C test-db test-integration [ONLY=Class[/method]]` | `make -C test-db up` |
| UI scenarios (`UITest/`, ~4 min) | `make -C test-db test-ui [ONLY="smoke edit-rows"]` | cluster + Accessibility permission for the terminal |
| Everything on a fresh cluster | `make -C test-db test-all` | Docker |

See the `test-db`, `integration-test` and `ui-test` skills. Results: `build/test-results/*.xcresult`, `build/uitest/report/report.html`.

No test run touches the real Keychain or the developer's saved connections: the app detects the XCTest host or `-SequelPGUITestMode` (`TestingHooks`) and switches to an in-memory Keychain and an isolated defaults suite.

## Format

```bash
./Scripts/format.sh          # requires: brew install swiftformat
```

`Scripts/pre-commit` formats staged Swift files; install with
`cp Scripts/pre-commit .git/hooks/pre-commit && chmod +x .git/hooks/pre-commit`.

## Reading failures

- `Cannot find 'Foo' in scope` right after adding a file → the file isn't registered in `project.pbxproj`; use the `add-swift-file` skill.
- Main-actor isolation errors in tests → the test class needs `@MainActor`.
- After running the app or tests, delete a stray `default.profraw` at the repo root if one appears; it is not part of the project.

Report the outcome faithfully: the exact number of tests executed and failed, with the failing test names and assertion messages.

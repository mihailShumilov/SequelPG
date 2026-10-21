---
name: build-and-test
description: Build SequelPG, run the XCTest suite (all, one class, or one method), and format Swift with SwiftFormat. Use after any Swift change, before committing, or when the user asks to build, test, or check that the project compiles.
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

Tests never need a live database — they use `MockDatabaseClient`.

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

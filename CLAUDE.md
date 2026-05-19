# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

SequelPG is a native macOS PostgreSQL client built with SwiftUI, targeting macOS 14.0+ with Swift 5.9+ and Xcode 15+. It uses PostgresNIO as the database driver.

## Build & Run

```bash
# Build from command line
xcodebuild -project SequelPG.xcodeproj -scheme SequelPG -configuration Debug build

# Run all tests
xcodebuild test -project SequelPG.xcodeproj -scheme SequelPG -destination 'platform=macOS'

# Run a single test class
xcodebuild test -project SequelPG.xcodeproj -scheme SequelPG \
  -destination 'platform=macOS' \
  -only-testing:SequelPGTests/TableViewModelTests

# Run a single test method
xcodebuild test -project SequelPG.xcodeproj -scheme SequelPG \
  -destination 'platform=macOS' \
  -only-testing:SequelPGTests/TableViewModelTests/testSomething

# Format code (requires: brew install swiftformat)
./Scripts/format.sh
```

## Architecture

Strict **MVVM** with enforced layer boundaries:

```
Views (SwiftUI) → ViewModels (@MainActor, @Observable) → Services → PostgresNIO
```

**Key rules:**
- Views must never make direct DB or storage calls
- Only `DatabaseClient` (an actor implementing `PostgresClientProtocol`) touches PostgresNIO
- Only `ConnectionStore` touches UserDefaults
- Only `KeychainService` touches the Keychain
- `AppViewModel` is the root coordinator — it owns `ConnectionListViewModel`, `NavigatorViewModel`, `TableViewModel`, and `QueryViewModel`, injected into the SwiftUI environment via `.environment()`

**Services layer:**
- `DatabaseClient` — actor wrapping PostgresNIO with introspection caching (schemas, tables, views, columns, PKs). All DB access goes through `PostgresClientProtocol` for testability.
- `SSHTunnelService` — actor managing SSH tunnel via system `ssh` binary. Handles local port forwarding, port allocation, and process lifecycle. Supports key file and password auth (via `SSH_ASKPASS`).
- `ConnectionStore` — UserDefaults-backed profile persistence
- `KeychainService` — password storage via Keychain (DB password under `SequelPG:<uuid>`, SSH password under `SequelPGSSH:<uuid>`)

**Utilities:** `quoteIdent()` and `quoteLiteral()` for safe SQL identifier/literal quoting — always use these when building SQL.

## Code Style

- SwiftFormat is enforced (config in `.swiftformat`): 4-space indent, 120 char max width, balanced closing parens
- Conventional Commits: `feat:`, `fix:`, `refactor:`, `test:`, `docs:`, `chore:`
- Branch prefixes: `feat/`, `fix/`, `refactor/`, `test/`, `docs/`, `chore/`

## Testing

Tests are in `SequelPGTests/` and use mock implementations of `PostgresClientProtocol`. No live database is needed for tests. Import with `@testable import SequelPG`.

**Key patterns:**
- ViewModels are `@MainActor`, so test classes must also be `@MainActor`
- `DatabaseClient` mock is an `actor MockDatabaseClient: PostgresClientProtocol` — use `await` setter methods to mutate properties from `@MainActor` tests
- `ConnectionStore` uses DI via `UserDefaults(suiteName:)` — use an ephemeral suite per test
- `KeychainService` mock uses in-memory dict conforming to `KeychainServiceProtocol`

**Adding new test files:** New `.swift` test files must be registered in `project.pbxproj` in 4 places (PBXBuildFile, PBXFileReference, SequelPGTests PBXGroup children, test target PBXSourcesBuildPhase). See existing entries for the ID naming pattern.

## Recommended Agents

Reach for these proactively when the task fits:

- **postgresql-function-auditor** — audit which PostgreSQL functions are surfaced in the UI vs. missing, prioritized by real-world usage. Use when planning the feature roadmap or evaluating query-builder coverage.
- **paranoid-security-auditor** — run after touching anything sensitive: `DatabaseClient`, `KeychainService`, `ConnectionStore`, `SSHTunnelService`, SQL builders, credential handling, export paths. Treat as mandatory before commits in those areas.
- **ui-performance-optimizer** — for SwiftUI polish, large-result-set scroll/render performance, and modernizing visual consistency.
- **feature-dev:code-explorer / code-architect / code-reviewer** — three-phase loop for non-trivial features (new panes, new connection types, schema tools). Explorer first → architect → reviewer.
- **code-smell-detector** — run proactively after any significant Swift change to catch duplication and anti-patterns.
- **Explore** — fast read-only search across the Swift codebase when locating symbols or call sites across `SequelPGApp/`.
- **Plan** — design step before larger refactors or cross-cutting changes.

## Recommended Skills

- `/review` and `/code-review:code-review` — review changes on the current branch / a PR.
- `/security-review` — security pass on pending changes. Required when touching connection/auth/SQL paths above.
- `/simplify` — review recently changed Swift for reuse and clarity.
- `/feature-dev:feature-dev` — guided feature development with codebase understanding.
- `/frontend-design:frontend-design` — for the sequelpg.com Next.js marketing site at `/Users/mihailshumilov/sites/my/sequelpg.com`.
- `/fewer-permission-prompts` — scan transcripts and auto-allowlist routine Bash/MCP calls (e.g. xcodebuild, swift).

**Skip for this project:** PostHog skills, `claude-api`, telegram/calendar/gmail/drive auth skills — not relevant unless the app is instrumented with those integrations.

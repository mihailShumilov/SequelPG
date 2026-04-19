---
name: Project Architecture
description: macOS SwiftUI MVVM PostgreSQL client — layer rules, conventions, and key architectural decisions
type: project
---

SequelPG is a native macOS PostgreSQL client (SwiftUI, macOS 14+, Swift 5.9+, PostgresNIO driver).

**Architecture:** Strict MVVM — Views -> ViewModels (@MainActor @Observable) -> Services (actors) -> PostgresNIO.

**Key actors/classes:**
- `AppViewModel` (~950 lines) — root coordinator, owns NavigatorVM/TableVM/QueryVM. All DB coordination goes through here.
- `DatabaseClient` (actor) — sole PostgresNIO wrapper, implements `PostgresClientProtocol` for testability.
- `SSHTunnelService` (actor) — manages ssh process lifecycle.
- `ConnectionStore` — UserDefaults-backed profile persistence.
- `KeychainService` — Keychain password storage.

**ViewModels injected into SwiftUI environment via .environment().**

**Conventions:**
- quoteIdent() / quoteLiteral() used consistently for SQL safety.
- @ObservationIgnored on stored credentials and dbClient in AppViewModel.
- Tests use MockDatabaseClient actor; no live DB needed.
- AppViewModelTestCase base class shared by AppViewModelTests, CascadeDeleteTests, InsertDeleteTests.
- CLAUDE.md documents build, test, and style rules.
- SwiftFormat enforced (4-space indent, 120 char max).

**Why:** per-CLAUDE.md, these layers are enforced to keep testability and separation of concerns.
**How to apply:** When suggesting changes, respect these boundaries — never push DB logic into views or ViewModels directly.

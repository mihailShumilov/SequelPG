---
name: SequelPG Codebase Patterns
description: Key architectural patterns, recurring smells, and conventions observed in the SequelPG macOS PostgreSQL client codebase
type: project
---

Strict MVVM: Views → ViewModels (@MainActor @Observable) → Services → PostgresNIO. AppViewModel is the root coordinator owning child VMs injected via SwiftUI environment.

**Why:** Architecture enforces testability (all DB access behind PostgresClientProtocol) and clear layer boundaries.

**How to apply:** Flag any pattern that crosses layer boundaries; favor protocol injection over concrete types in ViewModels.

Key smells observed (first review, 2026-04-19):

- `DatabaseClient` has ~11 nearly identical introspection methods (listTables, listViews, listSequences, etc.) — each pattern: check cache, guard client, build escaped SQL, loop rows, append DBObject, cache result, log. Prime extraction candidate.
- `connect()` and `switchDatabase()` in `DatabaseClient` share ~30 lines of PostgresClient construction + run task + verification — duplicated exactly.
- `AppViewModel` is large (~1240 lines) but reasonably well-divided by MARK sections and a separate `+ObjectCRUD` extension. Not a god object concern yet.
- `buildFilterCondition` in AppViewModel has a duplicated LIKE-escape block (lines 453-457 and 472-475) — same 4 replacingOccurrences calls.
- `isValidSQLExpression` and `isValidFunctionParams` in QuoteLiteral.swift share the same dangerous-keyword loop pattern — could share a helper.
- `listAllSchemaObjects` uses inline closures for aggregate/collation/domain/FTS queries instead of calling the dedicated list* methods — creates divergence risk.
- SQL string interpolation still uses manual `.replacingOccurrences(of: "'", with: "''")` escaping in introspection methods instead of parameterized queries (PostgresNIO does support bindings).
- `deleteConfirmationRowIndex` exists in both `TableViewModel` and `QueryViewModel` — parallel state that could drift.
- Tests: `AppViewModelTestCase` base class correctly shared. Test smell: no tests for `buildFilterCondition` edge cases (any-column mode, escape characters).

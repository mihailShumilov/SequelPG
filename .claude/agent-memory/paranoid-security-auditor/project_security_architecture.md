---
name: SequelPG Security Architecture Overview
description: Security architecture, data flows, credential handling, and risk areas for the SequelPG macOS PostgreSQL client
type: project
---

SequelPG is a native macOS PostgreSQL client (SwiftUI, PostgresNIO, macOS 14+). Single-user desktop app — no server component, no web surface.

**Credential storage:**
- DB passwords stored in macOS Keychain under key `SequelPG:<uuid>` with `kSecAttrAccessibleWhenUnlockedThisDeviceOnly` (good)
- SSH passwords stored under `SequelPGSSH:<uuid>`
- ConnectionProfile (non-sensitive fields) persisted to UserDefaults as JSON
- In-memory password cache in ConnectionListViewModel (passwords live in heap for session duration)
- connectedPassword and connectedSSHPassword stored as plain String? on @MainActor AppViewModel instance — cleared on disconnect

**Sandbox status:** DISABLED. App explicitly disables App Sandbox in entitlements to allow spawning /usr/bin/ssh via Process(). Any process-injection or dylib injection attack gets full filesystem access.

**SQL construction approach:**
- `quoteIdent()` used for identifiers (doubles internal double-quotes, wraps in double-quotes) — correct
- `quoteLiteral()` / `quoteLiteralTyped()` used for values — correct
- `isValidTypeName()` regex + keyword blocklist guards DDL type injection — present but incomplete
- Introspection queries use `replacingOccurrences(of: "'", with: "''")` NOT the utility functions — adequate for single-quote injection but not unicode normalization attacks
- All queries sent via `PostgresQuery(unsafeSQL:)` — no parameterized query support in PostgresNIO for introspection queries

**ACTIVE SQL injection vectors (unresolved as of 2026-04-11):**

1. `addColumn()` / `AppViewModel.swift:1048`: `defaultValue` injected raw into `DEFAULT <defaultValue>` — no validation, no quoting. SQL expression input accepted intentionally but without any sanitization boundary.

2. `changeColumnDefault()` / `AppViewModel.swift:1083`: `newDefault` injected raw into `SET DEFAULT <newDefault>` — same issue.

3. `createTable()` / `AppViewModel.swift:1140`: `col.defaultValue` injected raw into column definition `DEFAULT <defaultValue>`. `col.dataType` is validated via `isValidTypeName()` but defaultValue is not.

4. `CreateDomainSheet` / `ObjectCreateSheets.swift:418-422`: `defaultValue` (raw user text) and `checkExpression` (raw user text) both injected unquoted into CREATE DOMAIN SQL. No validation at all.

5. `CreateFunctionSheet` / `ObjectCreateSheets.swift:146`: `parameters` string (free-form text field) injected raw into CREATE FUNCTION argument list. Can inject arbitrary SQL after the closing `$$`.

6. `dropObject()` for .operator / `AppViewModel+ObjectCRUD.swift:42`: `object.name` is NOT wrapped in quoteIdent — raw operator name injected into DROP OPERATOR. Operator names come from pg_catalog and could be crafted by a hostile DB server.

7. `dropObject()` for .function / .procedure / .aggregate: `fullName` uses `object.name` which includes a parenthesized argument list (e.g. "myfunc(integer, text)") — not quoted via quoteIdent, so injection within parentheses is possible if the argument type names are attacker-controlled (hostile DB scenario).

8. `quoteLiteralTyped()` / `QuoteLiteral.swift:35`: `dataType` string appended raw as `::dataType` cast suffix. `isValidTypeName()` is called at call sites in `addColumn`/`createTable` but NOT consistently enforced before `quoteLiteralTyped()` is called in `commitInsertRow()` and `buildUpdateSQL()`. The dataType value comes from `getColumns()` pg_catalog metadata — malicious DB can set column type names.

**SSH tunnel security:**
- Uses FIFO (named pipe) + askpass script for password delivery — password never written to regular file
- StrictHostKeyChecking=yes enforced — good
- TOCTOU window exists between port allocation (bind to :0) and SSH binding — minor race
- SSH_ASKPASS script writes password to temp FIFO; the DispatchQueue write is not cancelled if the ssh process dies before reading — benign but leaves FD open briefly

**Logging:**
- OSLog used throughout with `privacy: .public` for hostnames/schemas — appropriate for desktop app
- DB passwords never appear in logs
- SSH stderr logged on tunnel failure with `privacy: .private` — credentials not exposed but stderr may contain server banners with sensitive info

**QueryHistoryViewModel:**
- All executed SQL (including UPDATE/DELETE/INSERT with actual PK values) stored in entries: [QueryHistoryEntry] — in-memory only, not persisted to disk. Max 500 entries.
- PK values from quoteLiteral() appear as E'...' literals in logged SQL. For sensitive tables this means PII values appear in query history UI.

**Entitlements:**
- com.apple.security.network.client: true — needed, minimal
- App Sandbox DISABLED — highest-risk configuration. Comment in entitlements file explicitly acknowledges this.

**Why this matters:**
- This is a desktop DB admin tool. The primary threat is a malicious database (or schema/table names crafted by a DBA on a shared server) injecting SQL via schema/table/column names returned from pg_catalog and used unescaped in DDL.
- The secondary threat is a user connecting to an untrusted database and having the DB return crafted column type names / operator names that escape into DDL statements.

---

## ERD Feature — Security Audit (2026-05-27)

### SQL Injection (listForeignKeys)
- Uses `let query: PostgresQuery = """...\(schema)..."""` string interpolation on a `PostgresQuery` typed literal — this IS PostgresNIO's parameterized query mechanism (bound parameter, not string concatenation). Identical pattern to `listConstraints`. No SQL injection risk.

### File Path (ERDLayoutStore)
- Schema encoded with `.addingPercentEncoding(withAllowedCharacters: .alphanumerics)` — encodes `.` `..` `/` `\` `:` `?` `*` `<` `>` `|` space and all non-alphanumeric chars. Path traversal not possible.
- Profile key is `UUID.uuidString` — only hexadecimal + hyphens, never contains path separators.
- Fallback to "schema" literal if encoding returns nil — correctly bounded.
- ERDLayout fields: schemaVersion (Int), positions ([String:CGPoint]), collapsed (Set<String>), hidden (Set<String>), scale (CGFloat), offset (CGPoint). No credentials or sensitive data.

### OSLog Privacy Gap (unresolved)
- `AppViewModel.swift:267`: `Log.ui.error("UI: ERD load failed - \(error.localizedDescription)")` — missing `privacy: .public` annotation. OSLog default for non-annotated String interpolations is `.private` (redacted in Console on device), so this is NOT a disclosure risk in practice, but is inconsistent with `ERDLayoutStore.swift:49` which explicitly annotates.

### SVG XML Injection
- `escape()` covers all 5 required XML entities: `&` `<` `>` `"` `'`. Applied to all DB-sourced strings (node.name, column.name, column.type) via the `text()` helper. All SVG attribute values (colors, weight, anchor, dimensions) are hardcoded constants or CGFloat integers — no user-controlled data in attributes. No injection path.

### Export Path Safety
- NSSavePanel provides the URL; user chooses location interactively — correct pattern.
- `allowedContentTypes` set conditionally (only when `UTType(filenameExtension:)` succeeds). UTType lookup for "png", "svg", "pdf" will succeed on any macOS 14+ system; this is a defense-in-depth note, not a real gap.
- App is NOT sandboxed; write is unrestricted at OS level once user selects path. This is pre-existing architecture, not introduced by ERD feature.
- Export error `localizedDescription` shown in UI — `NSCocoaError` from `data.write(to:)` may include the user-chosen path in the message. This is expected behavior for a desktop tool (the user chose the path); not a security concern.

### No Credentials in SVG/PNG/PDF
- SVG contains only: table names, column names, column types, cardinality glyphs — all schema metadata. No connection strings, passwords, hostnames, or usernames present in any export format.

---

## Export/Import Feature — Security Audit (2026-05-26)

### Credential Handling
- `PGPASSWORD` env var injection: correct approach; password never on argv (visible in `ps`)
- Password stored as cleartext `String?` in `AppViewModel.connectedPassword` for session duration — by design for desktop app
- `LiveConnection` Sendable struct holds password transiently while constructing `PGToolConnection`
- No credential leakage into OSLog confirmed (Log lines use `privacy: .public` only for label, PID, and paths)

### Argument Injection
- All pg_dump/psql args passed via `Process.arguments` array — no shell, no string concatenation, no globbing
- Schema/table names passed as argv elements (e.g. `-n schema_name`): correctly separated, no shell interpretation possible
- Encoding field exists in `ExportOptions.encoding` but is NOT surfaced in the ExportSheet UI — dead code path currently; if later exposed as a text field, validation needed
- Compression level 0-9 bounded by picker in ExportSheet — correctly constrained

### Binary Discovery / PATH Trust
- Search priority: UserDefaults-configured dir > Homebrew > Postgres.app > EDB > inherited $PATH
- UserDefaults key `com.sequelpg.pgToolsDirectory` — any process with same bundle ID can write this (user-space, non-sandboxed); but this is within the threat model for a desktop tool
- TOCTOU: `isExecutableFile` check at `locateTool()` (sheet open), path cached in `toolPath`, executed at export/import button press — attacker with filesystem access could swap the binary in the window

### Process Lifecycle Issues
- `cancel()` calls `process.terminate()` (SIGTERM) but does NOT call `waitUntilExit()` — unlike SSHTunnelService which does
- "Done" (header) button always enabled even during active transfer — can dismiss sheet without cancelling process (ORPHAN RISK)
- No `onDisappear` cleanup in ExportSheet or ImportSheet
- No cleanup of partial output files on failure or cancel

### Concurrency / OutputCollector
- `continuation.yield()` called while holding `NSLock` — if consumer is slow (back-pressure), yield could block, causing one pipe's `readabilityHandler` to hold the lock and stall the other
- Double-delivery risk: `terminationHandler` sets `readabilityHandler=nil`, then calls `readDataToEndOfFile()` — Apple's `readabilityHandler` nil-assignment may not prevent an already-queued callback from firing on that same data before the `readDataToEndOfFile()` call
- `AsyncThrowingStream.Continuation.yield()` is documented as thread-safe; `@unchecked Sendable` is appropriately scoped and the NSLock usage is correct for this pattern

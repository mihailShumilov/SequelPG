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

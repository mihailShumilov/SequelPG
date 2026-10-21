---
name: SequelPG Security Architecture
description: Core security architecture, credential flow, SQL injection mitigations, and trust boundaries in the SequelPG macOS app — updated 2026-04-19
type: project
---

## Authentication and Credential Flow

- DB passwords and SSH passwords stored in macOS Keychain via `KeychainService` using `kSecClassGenericPassword` under service `com.sequelpg.app`
- Keychain items now use `kSecAttrAccessibleWhenUnlockedThisDeviceOnly` (fixed from prior audit — explicit and non-synced)
- `kSecAttrSynchronizable: false` prevents iCloud sync
- `ConnectionListViewModel` maintains in-memory `passwordCache: [String: String]` — passwords live in process heap after first load
- `AppViewModel` holds `@ObservationIgnored private var connectedPassword/connectedSSHPassword` — cleared on disconnect()
- Profile metadata (host, port, username, SSL mode, SSH settings — NO passwords) stored in UserDefaults as JSON via `ConnectionStore`
- Entitlement: only `com.apple.security.network.client` — App Sandbox is NOT enabled

## SSH Tunnel (SSHTunnelService)

- Uses system `/usr/bin/ssh` binary via `Process` — no shell involvement, args passed as array (safe from shell injection)
- SSH password auth uses FIFO (named pipe) not a regular file — password never written to disk
- `StrictHostKeyChecking=yes` (FIXED from prior audit — was `accept-new`)
- Askpass script still written to temp dir as executable shell script; script contains FIFO path but not password
- SSH key path: `expandingTildeInPath` applied, `isReadableFile` check added — still no symlink or path traversal check
- TOCTOU gap between `findAvailablePort()` socket close and SSH tunnel bind — low-impact race

## SQL Injection Mitigations

- `quoteIdent()`: doubles internal `"` chars, wraps in `"` — correct PostgreSQL identifier quoting
- `quoteLiteral()`: uses `E'...'` escape-string syntax with backslash and single-quote doubling — correct
- `quoteLiteralTyped()`: appends `::dataType` cast — `isValidTypeName()` guard in function body
- `isValidTypeName()`: regex `/^[a-zA-Z_][a-zA-Z0-9_ ,.()\[\]]*$/` + keyword blocklist — adequate for most cases
- `isValidSQLExpression()`: rejects semicolons + dangerous keyword blocklist — adequate for DEFAULT/CHECK inputs
- `isValidFunctionParams()`: rejects semicolons, closing parens, dangerous keywords

## Active SQL Injection Vectors (unresolved as of 2026-04-19)

1. `CreateViewSheet`/`CreateMaterializedViewSheet` — `sqlDefinition` (free-text user SQL body) injected raw after `AS` — intentional by design for a SQL client, but no sanitization or injection boundary
2. `CreateFunctionSheet:147` — `parameters` free-text field passes `isValidFunctionParams()` but `returnType` and `language` fields are Picker-constrained (safe); `volatility` is Picker-constrained (safe); `functionBody` is raw text inside `$$` delimiter — safe only if `$$` cannot be escaped by user
3. `CreateDomainSheet` — `defaultValue` and `checkExpression` are validated by `isValidSQLExpression()` — this IS now validated (fixed from prior secondary audit notes)
4. `addColumn()`/`changeColumnDefault()`/`createTable()` — default value expressions validated via `isValidSQLExpression()` before injection
5. `dropObject()` for `.operator` (`AppViewModel+ObjectCRUD.swift:42`) — `object.name` injected raw into `DROP OPERATOR ... CASCADE`; operator names from pg_catalog are not quoteIdent-wrapped
6. `dropObject()` for `.function/.procedure/.aggregate` — `argList` from `splitFunctionName()` is the raw arg list from pg_catalog, not sanitized; injected into DROP statement arg list
7. `getObjectDDL()` for `.view`/`.materializedView` — `esc`/`escName` values concatenated into SQL string literals already inside `''` delimited by single-quote doubling — adequate
8. All introspection queries in `listTables`, `listViews`, etc. use `replacingOccurrences(of: "'", with: "''")` rather than `quoteLiteral()` — functionally equivalent but inconsistent style

## QueryHistoryViewModel (NEW as of 2026-04-19)

- In-memory query log, max 500 entries — not persisted to disk
- Stores full SQL text including UPDATE/DELETE with PK literal values — PII can appear in UI
- `errorMessage` from DB errors stored and displayed in history panel — may contain server-side info (table names, constraint names, values)

## Key Risk Areas

1. App Sandbox NOT enabled — full filesystem and process execution access
2. `dropObject()` for operator type — operator name not quoteIdent-wrapped (hostile DB injection)
3. `dropObject()` for function/procedure/aggregate — arg list from pg_catalog not sanitized
4. SSH key path input has no symlink/traversal validation
5. TOCTOU gap between `findAvailablePort()` and SSH bind
6. `quoteLiteralTyped()` appends raw dataType from pg_catalog — `isValidTypeName()` guards inside the function are present but hostile DB could craft type names passing the regex
7. PII in query history panel (in-memory only)

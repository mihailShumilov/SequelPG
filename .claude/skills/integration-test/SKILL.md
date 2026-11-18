---
name: integration-test
description: Write and run SequelPG integration tests (SequelPGIntegrationTests) — real DatabaseClient, SSHTunnelService and AppViewModel against the Docker test cluster on PostgreSQL 18/16/13. Use when changing connection, auth, SSL, SSH, query execution, type decoding, introspection, drop/DDL or export/import code, or when a unit test with mocks can't prove the behavior.
---

# SequelPG integration tests

Target `SequelPGIntegrationTests` (scheme of the same name) is a hosted test bundle: `@testable import SequelPG` gives the real services. It needs the test cluster (`test-db` skill).

```bash
make -C test-db up
make -C test-db test-integration                          # ~45 s
make -C test-db test-integration ONLY=SSLModeTests
make -C test-db test-integration ONLY=SSLModeTests/testRequireUsesTLS
```

With `SEQUELPG_REQUIRE_CLUSTER=1` (set by make) a missing cluster fails the run; run directly from Xcode without it, tests skip instead.

## Files

| File | Covers |
| --- | --- |
| `TestCluster.swift` | reads `test-db/test-env.json`; `TestCluster.Server` (`.pg18/.pg16/.pg13`), `Role`, `profile(...)`, `sshProfile(...)`, `connect(...)`, `DatabaseClient.exec/scalar` |
| `IntegrationTestCase.swift` | base class: tracks and disconnects clients, `makeScratchSchema(on:)` (dropped in teardown), `assertThrowsAsync`, `message(of:)` |
| `ConnectionAuthTests` / `SSLModeTests` / `SSHTunnelTests` | every auth method, SSL mode and tunnel variant, plus the failure messages |
| `QueryExecutionTests` / `TypeDecodingTests` | execution, limits, cancellation, how each type renders |
| `IntrospectionTests` | catalog queries on every server version |
| `DropObjectIntegrationTests` / `AppViewModelIntegrationTests` / `TransferIntegrationTests` | DDL, ViewModel flows end to end, pg_dump/psql round trips |

## Writing a test

```swift
final class FooIntegrationTests: IntegrationTestCase {
    func testSomethingOnEveryServer() async throws {
        for server in TestCluster.Server.allCases {
            let client = try await connect(server)
            let schema = try await makeScratchSchema(on: client)
            try await client.exec("CREATE TABLE \(quoteIdent(schema)).t (id int)")
            XCTAssertEqual(try await client.scalar("SELECT count(*) FROM \(quoteIdent(schema)).t"), "0", "\(server)")
        }
    }
}
```

Rules:
- Put the server in every assertion message (`"\(server)"`) — the same query often behaves differently on 13 vs 18.
- Never mutate the shared `qa` fixtures; use `makeScratchSchema(on:)`. Read-only checks against `qa` are fine.
- `XCTUnwrap(await …)` doesn't compile — await into a local first.
- Pin what the app actually shows (e.g. ISO-8601 timestamps, upper-case UUIDs, `udtName` of a domain is its base type), not what psql prints.
- A known product bug gets `XCTExpectFailure("why")` with the real assertion, so the test flips to failing when the bug is fixed. Don't delete or weaken the assertion.
- Tests run in the hosted app: `TestingHooks.isTestHost` gives them an in-memory Keychain and isolated defaults, so nothing prompts or touches the developer's data.
- Register new files: `Scripts/pbxproj.py add-file SequelPGIntegrationTests/FooIntegrationTests.swift --targets SequelPGIntegrationTests`.

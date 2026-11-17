# Automated test environment

Everything here runs locally. Three suites share one Docker cluster:

| Suite | Where | What it proves | Time |
| --- | --- | --- | --- |
| Unit | `SequelPGTests/` | ViewModels, SQL builders, parsers — with mocks, no database | ~5 s |
| Integration | `SequelPGIntegrationTests/` | real `DatabaseClient`, SSH tunnels, `AppViewModel`, pg_dump/psql against PostgreSQL 18, 16 and 13 | ~45 s |
| UI scenarios | `UITest/` | the real app operated through its interface, a screenshot per step | ~4 min |

## Quick start

```bash
open -a Docker                 # Docker Desktop must be running
make -C test-db up             # start the cluster (fresh every time)
make -C test-db test-unit
make -C test-db test-integration
make -C test-db test-ui        # report: build/uitest/report/report.html
make -C test-db test-all       # reset + all three
make -C test-db down
```

Narrow a run: `ONLY=SSLModeTests` / `ONLY=SSLModeTests/testRequireUsesTLS` for integration, `ONLY="smoke edit-rows"` for UI scenarios (`make -C test-db ui-list` lists them).

## The cluster

| Service | Port | Purpose |
| --- | --- | --- |
| `pg18` | 127.0.0.1:55418 | TLS with a private CA; dev-db fixtures plus the `qa` schema |
| `pg16` | 127.0.0.1:55416 | `qa` schema |
| `pg13` | 127.0.0.1:55413 | `qa` schema |
| `sshd` | 127.0.0.1:55022 | SSH bastion (`tunnel`, key or password) forwarding to `pg18` |

- Data is on tmpfs: every start is a fresh `initdb`.
- `test-env.json` is the single source of truth for ports, roles and passwords. Tests read it, and `make check` verifies `docker-compose.yml` against it.
- Roles cover scram-sha-256, md5, trust, a read-only role and an SSL-only role rejected by `pg_hba` without TLS.
- `scripts/gen-assets.sh` generates the CA, server certificate, SSH keys and `known_hosts` into `.generated/` (gitignored).
- `init/00_sequelpg_test.sh` sets up roles, `pg_hba` and TLS. `fixtures/01_qa.sql` holds the shared test objects (portable to PG 13).

All passwords here are throwaway test values. The ports are bound to 127.0.0.1 only.

## UI scenarios without taking over the screen

`UITest/` builds `sequelpg-uitest`. It launches the Debug app with `open -g`, so the app stays behind your windows. It then drives the app through the macOS accessibility API:

- presses controls with `AXPress`;
- sets text through `AXValue`;
- selects rows and expands outline items through accessibility attributes;
- posts keys to the app's process only;
- screenshots just that window with `screencapture -l`.

The pointer, focus and keyboard stay yours, so you can keep working while it runs.

The terminal needs Accessibility permission: System Settings ▸ Privacy & Security ▸ Accessibility.

Interactive exploration uses the same driver:

```bash
B=UITest/.build/release/sequelpg-uitest
$B launch --seed; $B dump; $B press startPage.connect; $B set query.editor "SELECT 1"; $B press query.run; $B shot q; $B quit
```

Controls are found by accessibility identifiers from `SequelPGApp/Utilities/AccessibilityID.swift`. The driver uses the same file through a symlink.

## How the app is isolated during tests

Debug builds honor these hooks (`SequelPGApp/Utilities/TestingHooks.swift`). Release builds compile them out.

| Trigger | Effect |
| --- | --- |
| hosted XCTest run, or `-SequelPGUITestMode` | in-memory Keychain (never the real one, so no system prompts), defaults suite `com.sequelpg.app.uitests` wiped at launch, temporary Application Support |
| `SEQUELPG_UITEST_PROFILES` (JSON) | saved connections and their passwords for the run |
| `SEQUELPG_UITEST_SAVE_DIR` / `SEQUELPG_UITEST_OPEN_FILE` | replace the Save / Open panels |
| `SEQUELPG_SSH_KNOWN_HOSTS_FILE` | tunnels use the cluster's `known_hosts`, not `~/.ssh/known_hosts` |

## Known product issues found by the suites

These are pinned by tests (`XCTExpectFailure`, or a comment in the scenario). They will flag when fixed.

- **Stop doesn't cancel the statement on the server.** The UI waits for the query to finish.
- **Timestamps lose microseconds.** They are shown with millisecond precision.
- **Export from PG 18 can't be imported into PG < 17.** pg_dump 18 emits `SET transaction_timeout`.
- **Multi-statement queries are rejected.** Execution uses the extended protocol.
- **verify-ca / verify-full trust only the system store.** A private CA can't be configured.
- **No affected-row count.** INSERT/UPDATE/DELETE show "Command Completed" without "N rows affected", because the command tag isn't read.

## Troubleshooting

- **`make up` reports an exited container.** Run `make logs S=pg13`; it's usually fixture SQL that is too new for that server.
- **Integration tests skip.** The cluster isn't reachable. `make` sets `SEQUELPG_REQUIRE_CLUSTER=1`, which turns that into a failure.
- **The UI driver says "no Accessibility permission".** Grant it to your terminal app and rerun.
- **A UI scenario fails.** Open its `…-FAILED.png` in `build/uitest/report/`, then explore with `launch` / `dump`.

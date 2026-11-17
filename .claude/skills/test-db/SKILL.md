---
name: test-db
description: Start, reset, inspect or extend the Docker test cluster in test-db/ (PostgreSQL 18/16/13, every auth method, TLS, an SSH bastion) that the integration tests and UI scenarios run against. Use before running those suites, when a connection/auth/SSL/SSH case needs a server, or when a test needs a new fixture object or role.
---

# SequelPG test cluster

`test-db/` is a throwaway cluster for automated tests. It is separate from `dev-db/` (the hand-testing demo database) — never point tests at dev-db.

| Service | Port (127.0.0.1) | Notes |
| --- | --- | --- |
| `pg18` | 55418 | TLS on (private CA), dev fixtures + `qa` fixtures |
| `pg16` | 55416 | `qa` fixtures |
| `pg13` | 55413 | `qa` fixtures |
| `sshd` | 55022 | bastion, user `tunnel`; forwards to `pg18:5432` |

Data lives on tmpfs: every start is a fresh `initdb`, so tests may create and drop freely.

**Single source of truth:** `test-db/test-env.json` (ports, database, roles, passwords, SSH). Tests read it; `make check` verifies `docker-compose.yml` agrees with it. Change both together.

## Commands (from the repo root)

```bash
make -C test-db up        # check config, generate certs/keys, build sshd, start, wait until healthy
make -C test-db status
make -C test-db reset     # fresh initdb on every server
make -C test-db down
make -C test-db psql S=pg16
make -C test-db logs S=sshd
```

`make up` needs Docker Desktop running (`open -a Docker`). If `wait` reports an exited container, read `make logs S=<service>` — usually an init-script SQL error on an older server.

## Roles (database `sequelpg_test`)

| Key in test-env.json | Role | Auth |
| --- | --- | --- |
| `admin` | `sp_admin` | scram, superuser — setup/verification only |
| `scram` | `sp_scram` | scram-sha-256 |
| `md5` | `sp_md5` | md5 (password stored as md5) |
| `trust` | `sp_trust` | trust, empty password |
| `readonly` | `sp_readonly` | SELECT on `qa.people` only |
| `sslonly` | `sp_sslonly` | `hostnossl … reject`: must use SSL |

A second database `sequelpg_test_other` holds `other.marker`.

## Fixtures

- `test-db/init/00_sequelpg_test.sh` — roles, pg_hba rules, TLS, then fixtures. Dev fixtures (`../dev-db/init`) load only on PG ≥ 18 (they use PG18 syntax).
- `test-db/fixtures/01_qa.sql` — schema `qa`, portable to PG 13+: `people` (50 rows, `age` NULL when `id % 10 = 0`), `big_numbers` (100k), `"Weird Table"` (quoted/unicode columns), `type_samples`, `parent`/`child` (FK RESTRICT), `editable`, `no_pk`, view `adults`, matview `mood_counts`, `ticket_seq`, overloaded `add()`, `slow(seconds)`, procedure, aggregate `sum_sq`, operator `===`, partitioned `measurements`.

Adding a fixture: append portable SQL to `01_qa.sql` (test it on pg13 too), then `make reset`. Tests that only need a scratch object should create it themselves (integration: `makeScratchSchema(on:)`; UI scenarios: `setupSQL`) instead of growing the shared fixtures.

## Generated assets

`scripts/gen-assets.sh` writes `test-db/.generated/` (gitignored): CA + server cert (SAN localhost/127.0.0.1), SSH host key, `client_ed25519`, `wrong_ed25519`, and `known_hosts` for `[127.0.0.1]:55022`. The app gets `known_hosts` through `SEQUELPG_SSH_KNOWN_HOSTS_FILE` (Debug builds only), so tunnels never touch `~/.ssh/known_hosts`.

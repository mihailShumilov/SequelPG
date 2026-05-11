# SequelPG demo database

A PostgreSQL 18 cluster in Docker, pre-loaded with a comprehensive test
fixture: every built-in field type, every table flavor, custom types,
functions, procedures, triggers, RLS, and PG-18-specific features (virtual
generated columns, `uuidv7()`, temporal `WITHOUT OVERLAPS`, `RETURNING old/new`,
`NOT ENFORCED`).

The cluster binds to `127.0.0.1` only and uses a non-default port so it
won't collide with system Postgres or other projects.

## Quick start

```bash
cd dev-db
make up        # starts the container, waits for ready, prints the URL
```

When `make up` finishes you'll see something like:

```
  SequelPG demo database is up.
  ─────────────────────────────
  Host:     127.0.0.1
  Port:     54318
  Database: demo
  User:     demo
  Password: demo

  psql:     psql -h 127.0.0.1 -p 54318 -U demo -d demo
  URI:      postgres://demo:demo@127.0.0.1:54318/demo
```

Plug those values into a new connection in SequelPG (SSL mode: `prefer` or
`disable` — the container has no certificate set up).

## Common tasks

| Command         | What it does                                         |
| --------------- | ---------------------------------------------------- |
| `make up`       | Start the container and wait for `pg_isready`        |
| `make down`     | Stop and remove the container (volume preserved)     |
| `make stop`     | Stop without removing                                |
| `make restart`  | Restart the container                                |
| `make reset`    | Wipe the data volume and re-run every init script    |
| `make psql`     | Open `psql` inside the container                     |
| `make logs`     | Tail the postgres log                                |
| `make port`     | Print the host port                                  |
| `make info`     | Print connection details                             |
| `make status`   | `docker compose ps`                                  |

`make reset` is the one you want after editing anything under `init/` —
docker-entrypoint only runs init scripts on a *fresh* data directory, so
you have to drop the volume to re-run them.

## Picking a different port

Default is `54318`. To change it (e.g. you already have something there):

```bash
cp .env.example .env
# edit POSTGRES_PORT, then:
make reset
```

`.env` overrides every Make target and `docker compose` invocation.

## What's inside

The init scripts run in lexical order; each builds on the previous.

| File | Purpose |
| ---- | ------- |
| `01_extensions_and_schemas.sql` | Enables 17 contrib extensions; creates `app`, `audit`, `archive`, `reports`, `staging` schemas; sets `search_path`. |
| `02_types_and_domains.sql`      | Five enums, four composite types, six domains, one custom range type (`pricerange`). |
| `03_tables.sql`                 | A `kitchen_sink` table with one column per built-in type; orders/users/products/tenants/documents; range/list/hash partitioning; legacy table inheritance; table-of-type; unlogged staging table; foreign table via `postgres_fdw` self-loopback. |
| `04_views.sql`                  | Plain view, joined view (made writeable later), aggregated reporting view, recursive view over an `ltree` hierarchy, `WITH NO DATA` materialized view. |
| `05_routines.sql`               | SQL + plpgsql functions, overloads, `VARIADIC`, `SETOF`/`TABLE` returns, `EXCEPTION` handling, a `PROCEDURE`, a custom `AGGREGATE` and `OPERATOR`, plus the trigger functions wired up in 06. |
| `06_triggers.sql`               | `BEFORE`/`AFTER`, `ROW`/`STATEMENT`, `WHEN` predicates, multi-event (`INSERT OR UPDATE OR DELETE`), `INSTEAD OF` on a view. |
| `07_indexes.sql`                | One index per access method (`btree`, `hash`, `gin`, `gist`, `brin`, `spgist`), plus partial / expression / multicolumn / `INCLUDE` covering / trigram / ltree-gist. |
| `08_security_and_rls.sql`       | Three roles (`app_admin`, `app_user`, `app_readonly`), object grants, default privileges, RLS policy on `app.documents` keyed on a session GUC. |
| `09_demo_data.sql`              | Tenants, users, products, orders (across 6 monthly partitions), 200 events (across 4 hash partitions), shipments, animals, ltree categories, a fully-populated kitchen-sink row, a mostly-NULL kitchen-sink row, plus a `REFRESH MATERIALIZED VIEW` and `ANALYZE`. |
| `10_pg18_features.sql`          | `STORED` vs `VIRTUAL` generated columns, `uuidv7()`, temporal `PRIMARY KEY (..., valid WITHOUT OVERLAPS)`, `NOT ENFORCED` constraint, function using `RETURNING old.*, new.*`. |

## Trying the RLS policy

`app.documents` is RLS-locked to a tenant set on the session:

```sql
SET ROLE app_user;
SELECT set_config('app.current_tenant', '11111111-1111-1111-1111-111111111111', false);
SELECT * FROM app.documents;     -- only Acme rows
RESET ROLE;
SELECT * FROM app.documents;     -- everything (bypassed by table owner)
```

## Trying PG18 RETURNING old/new

```sql
SELECT * FROM app.bump_regional_prices(1.10);
```

Returns `(product_id, region, old_price, new_price, delta)` for every row
touched, using PG18's `RETURNING old.col, new.col` syntax under the hood.

## Caveats

- The container exposes port only on `127.0.0.1`. Don't change that and
  expose it to the LAN — the password is literally `demo`.
- The foreign table `app.products_remote` uses a self-loopback through
  `postgres_fdw` for demo purposes. It writes the demo password into the
  user mapping; rotate it before reusing this cluster for anything real.
- `make reset` drops the data volume. Anything you've added by hand is
  gone after a reset — that's the point.

---
name: dev-db
description: Start, reset, inspect, or extend the SequelPG demo PostgreSQL 18 database in dev-db/ (Docker). Use when a change needs a real server to verify — introspection queries, Structure/Content/Definition views, ERD, EXPLAIN, export/import — or when adding fixture objects for a new feature.
---

# SequelPG demo database

`dev-db/` runs PostgreSQL 18 in Docker, bound to `127.0.0.1` only, preloaded with every built-in type, partitioning, inheritance, a foreign table, RLS, all index access methods, routines/procedures/aggregates/operators, triggers, and PG18 features.

## Commands (from the repo root)

```bash
make -C dev-db up       # start and wait for pg_isready, then print connection info
make -C dev-db info     # host / port / credentials
make -C dev-db psql     # psql inside the container
make -C dev-db reset    # drop the volume and re-run every init script
make -C dev-db down     # stop and remove (volume kept)
```

Defaults: host `127.0.0.1`, port `54318`, database `demo`, user `demo`, password `demo`, SSL mode `prefer` or `disable`. Override the port via `dev-db/.env` (copy `.env.example`).

Schemas: `app`, `audit`, `archive`, `reports`, `staging`. RLS demo: `app.documents` keyed on the `app.current_tenant` GUC.

## Running ad-hoc SQL

```bash
PGPASSWORD=demo psql -h 127.0.0.1 -p 54318 -U demo -d demo -c "SELECT …"
```

If `psql` isn't on PATH, use `docker compose -f dev-db/docker-compose.yml exec -T postgres psql -U demo -d demo -c "…"`.

## Extending the fixture

- Init scripts in `dev-db/init/NN_name.sql` run in lexical order on a **fresh** volume only; after editing one, run `make -C dev-db reset`.
- Add objects to the script that owns that category (types → 02, tables → 03, routines → 05, …); put features tied to a specific server version in a dedicated numbered script, like `10_pg18_features.sql`.
- Update the "What's inside" table in `dev-db/README.md` when you add a script or a notable object.

## Cautions

- Requires Docker Desktop running; if `make up` times out, check `make -C dev-db logs`.
- Never expose the port beyond `127.0.0.1`; the password is `demo`.
- `reset` wipes anything added by hand — confirm with the user first if they may have local data in the cluster.
- The cluster is PG18 only. Behaviour on older servers (10–17) has to be reasoned about or tested against another server; say so instead of assuming.

#!/usr/bin/env bash
# Runs once per fresh cluster (docker-entrypoint-initdb.d). Sets up:
#   * auth-variant login roles (scram / md5 / trust / readonly / ssl-only)
#   * pg_hba rules for those roles
#   * TLS (pg18 only, when SEQUELPG_SSL=on)
#   * fixtures: dev-db/init (shared with the demo DB) + test-db/fixtures (qa schema)
set -euo pipefail

MAJOR=$(postgres -V | sed -E 's/.* ([0-9]+)(\.[0-9]+)?.*/\1/')
PSQL=(psql -v ON_ERROR_STOP=1 --no-psqlrc -q -U "$POSTGRES_USER" -d "$POSTGRES_DB")
echo "== SequelPG test init (PostgreSQL $MAJOR) =="

# ── Roles ──────────────────────────────────────────────────────────────
"${PSQL[@]}" <<'SQL'
SET password_encryption = 'scram-sha-256';
CREATE ROLE sp_scram    LOGIN PASSWORD 'scram_pw' SUPERUSER;
CREATE ROLE sp_trust    LOGIN SUPERUSER;
CREATE ROLE sp_readonly LOGIN PASSWORD 'readonly_pw';
CREATE ROLE sp_sslonly  LOGIN PASSWORD 'sslonly_pw';
SET password_encryption = 'md5';
CREATE ROLE sp_md5      LOGIN PASSWORD 'md5_pw' SUPERUSER;
RESET password_encryption;
SQL

# ── pg_hba: first match wins, so prepend the role-specific rules ───────
HBA="$PGDATA/pg_hba.conf"
{
    echo "# --- SequelPG test rules ---"
    echo "host    all  sp_trust    all  trust"
    echo "host    all  sp_md5      all  md5"
    echo "hostnossl all sp_sslonly all  reject"
    echo "# ---------------------------"
    cat "$HBA"
} > "$HBA.new"
mv "$HBA.new" "$HBA"

# ── TLS ────────────────────────────────────────────────────────────────
if [[ "${SEQUELPG_SSL:-off}" == "on" ]]; then
    install -m 600 /certs-src/server.crt "$PGDATA/server.crt"
    install -m 600 /certs-src/server.key "$PGDATA/server.key"
    install -m 644 /certs-src/ca.crt     "$PGDATA/ca.crt"
    "${PSQL[@]}" -c "ALTER SYSTEM SET ssl = on" \
                 -c "ALTER SYSTEM SET ssl_cert_file = 'server.crt'" \
                 -c "ALTER SYSTEM SET ssl_key_file = 'server.key'"
    echo "TLS enabled"
fi

# ── Fixtures ───────────────────────────────────────────────────────────
# dev-db/init targets PG18 syntax throughout (SQL-standard function bodies,
# VIRTUAL generated columns, …), so older servers get only the portable qa
# fixtures below.
if [[ "$MAJOR" -ge 18 ]]; then
    for f in /fixtures/dev/*.sql; do
        echo "apply dev/$(basename "$f")"
        "${PSQL[@]}" -f "$f" >/dev/null
    done
else
    echo "skip dev-db fixtures (PG$MAJOR < 18)"
fi

for f in /fixtures/qa/*.sql; do
    echo "apply qa/$(basename "$f")"
    "${PSQL[@]}" -f "$f" >/dev/null
done

# Read-only role: CONNECT + SELECT on one table, nothing else.
"${PSQL[@]}" <<'SQL'
GRANT USAGE ON SCHEMA qa TO sp_readonly;
GRANT SELECT ON qa.people TO sp_readonly;
SQL

# Marker table in the secondary database (database-switch tests).
psql -v ON_ERROR_STOP=1 --no-psqlrc -q -U "$POSTGRES_USER" -d sequelpg_test_other <<'SQL'
CREATE SCHEMA other;
CREATE TABLE other.marker (id integer PRIMARY KEY, label text);
INSERT INTO other.marker VALUES (1, 'other-db');
SQL

echo "== SequelPG test init done =="

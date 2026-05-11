-- 07_indexes.sql
-- One index per access method PostgreSQL ships, plus partial / expression /
-- multicolumn / covering examples. Lets the index inspector show off the
-- USING clause and the predicate / INCLUDE columns.

\echo '== Indexes =='

SET search_path = app, public;

-- ── B-tree (default) ────────────────────────────────────────────────────
CREATE INDEX users_email_btree     ON app.users (email);
CREATE INDEX orders_status_idx     ON app.orders (status);
CREATE INDEX orders_user_placed_idx ON app.orders (user_id, placed_at DESC);

-- Multi-column B-tree designed to benefit from PG18 skip scans.
CREATE INDEX events_type_session_idx
    ON app.events (type, session_id);

-- ── Covering / INCLUDE ──────────────────────────────────────────────────
CREATE INDEX products_sku_covering
    ON app.products (sku) INCLUDE (name, price);

-- ── Partial ─────────────────────────────────────────────────────────────
CREATE INDEX orders_open_only
    ON app.orders (placed_at)
    WHERE status IN ('pending', 'paid', 'shipped');

-- ── Expression ──────────────────────────────────────────────────────────
CREATE INDEX users_lower_email
    ON app.users (lower(email::text));

-- ── Hash ────────────────────────────────────────────────────────────────
CREATE INDEX users_id_hash ON app.users USING hash (id);

-- ── GIN on jsonb + on tsvector ──────────────────────────────────────────
CREATE INDEX users_metadata_gin
    ON app.users USING gin (metadata jsonb_path_ops);

CREATE INDEX products_search_gin
    ON app.products USING gin (search_vec);

-- ── GiST on a range column (also enables exclusion constraints elsewhere)
CREATE INDEX orders_placed_gist
    ON app.orders USING gist (tstzrange(placed_at, placed_at, '[]'));

-- ── BRIN — great for the timestamp column on a big append-only table ────
CREATE INDEX events_occurred_brin
    ON app.events USING brin (occurred_at);

-- ── SP-GiST on point ────────────────────────────────────────────────────
CREATE INDEX kitchen_geo_point_spgist
    ON app.kitchen_sink USING spgist (geo_point);

-- ── Trigram (pg_trgm) for ILIKE acceleration ────────────────────────────
CREATE INDEX products_name_trgm
    ON app.products USING gin (name gin_trgm_ops);

-- ── ltree GiST for hierarchy lookups ────────────────────────────────────
CREATE INDEX categories_path_gist
    ON app.categories USING gist (path);

COMMENT ON INDEX events_type_session_idx
    IS 'Multi-column B-tree — exercises PG18 skip-scan paths when querying by session_id alone.';

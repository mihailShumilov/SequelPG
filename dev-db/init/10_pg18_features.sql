-- 10_pg18_features.sql
-- PostgreSQL-18-specific surface area, kept in its own file so it's easy to
-- comment out if anyone runs the harness against an earlier server.

\echo '== PostgreSQL 18 features =='

SET search_path = app, public;

-- ── Virtual generated columns are the PG18 default — exercised in 03 on
-- app.users (is_admin) and app.documents (word_count). Add an example with
-- both VIRTUAL and STORED side by side so the difference is browsable.
CREATE TABLE app.measurements (
    id          bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    sample_at   timestamptz NOT NULL DEFAULT now(),
    height_cm   numeric NOT NULL,
    -- VIRTUAL: computed at SELECT, no storage cost.
    height_in   numeric GENERATED ALWAYS AS (height_cm / 2.54) VIRTUAL,
    -- STORED: materialized at write, indexable.
    height_class text GENERATED ALWAYS AS (
        CASE WHEN height_cm < 150 THEN 'short'
             WHEN height_cm < 180 THEN 'medium'
             ELSE 'tall' END
    ) STORED
);
CREATE INDEX measurements_class_idx ON app.measurements (height_class);

INSERT INTO app.measurements (height_cm) VALUES
    (148.0), (165.5), (172.3), (181.0), (193.7);

-- ── UUIDv7 — timestamp-ordered identifiers, native in PG18 ──────────────
CREATE TABLE app.audit_events_v7 (
    id          uuid PRIMARY KEY DEFAULT uuidv7(),
    happened_at timestamptz NOT NULL DEFAULT now(),
    payload     jsonb NOT NULL
);

INSERT INTO app.audit_events_v7 (payload) VALUES
    ('{"action":"signup","tenant":"acme"}'),
    ('{"action":"login","tenant":"acme"}'),
    ('{"action":"login","tenant":"globex"}'),
    ('{"action":"purchase","tenant":"acme","sku":"SKU-001"}');

-- ── Temporal constraints (PRIMARY KEY ... WITHOUT OVERLAPS) ─────────────
-- Used to model "exactly one active membership per user at any time".
CREATE TABLE app.memberships (
    user_id    uuid NOT NULL REFERENCES app.users(id) ON DELETE CASCADE,
    plan       text NOT NULL,
    valid      tstzrange NOT NULL,
    -- PG18 temporal PK: scalar columns must be unique together with
    -- the range column non-overlapping.
    PRIMARY KEY (user_id, valid WITHOUT OVERLAPS)
);

INSERT INTO app.memberships (user_id, plan, valid) VALUES
    ('aaaa1111-0000-0000-0000-000000000001', 'pro',
        tstzrange('2026-01-01 00:00+00','2026-04-01 00:00+00','[)')),
    ('aaaa1111-0000-0000-0000-000000000001', 'enterprise',
        tstzrange('2026-04-01 00:00+00', NULL,'[)'));

-- ── NOT ENFORCED constraint — declared but not validated, useful for
-- documenting a known invariant or staging a migration step.
CREATE TABLE app.shipping_rates (
    region   iso_country NOT NULL,
    weight_g integer NOT NULL,
    cost     numeric(10, 2) NOT NULL,
    CONSTRAINT shipping_rates_weight_positive CHECK (weight_g > 0) NOT ENFORCED
);

INSERT INTO app.shipping_rates VALUES
    ('US', 500,  9.95),
    ('US', 2000, 19.95),
    ('DE', 500,  7.50);

-- ── RETURNING old.* / new.* — PG18 lets the same statement expose both
-- snapshots without a trigger. We use app.product_prices.price (a plain
-- numeric) for the demo; composite columns work too but need parens.
CREATE FUNCTION app.bump_regional_prices(p_factor numeric)
RETURNS TABLE (
    product_id bigint,
    region     iso_country,
    old_price  numeric,
    new_price  numeric,
    delta      numeric
)
LANGUAGE sql
AS $$
    UPDATE app.product_prices
    SET price = price * p_factor
    RETURNING product_id,
              region,
              old.price AS old_price,
              new.price AS new_price,
              new.price - old.price AS delta;
$$;
COMMENT ON FUNCTION app.bump_regional_prices(numeric)
    IS 'Multiplies every product_prices.price by the given factor; returns old/new/delta per row using PG18 RETURNING old/new.';

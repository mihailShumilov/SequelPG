-- 01_qa.sql — deterministic fixtures for automated tests.
--
-- Everything lives in schema `qa` so tests can assert exact values without
-- depending on the demo data in dev-db/init. Must stay portable to the
-- oldest server in test-env.json (PostgreSQL 13): no multiranges, no
-- PG14+ syntax.
--
-- Tests that mutate data create their own throwaway schema (see
-- TestDB.makeScratchSchema) — the objects below are read-only by convention,
-- except qa.editable, which UI tests reset before use.

CREATE SCHEMA qa;
SET search_path = qa, public;

-- ── Types ──────────────────────────────────────────────────────────────
CREATE TYPE qa.mood AS ENUM ('sad', 'ok', 'happy');
CREATE DOMAIN qa.positive_int AS integer CHECK (VALUE > 0);
CREATE TYPE qa.point2 AS (x integer, y integer);

-- ── people: small table with PK, unique, defaults ──────────────────────
CREATE TABLE qa.people (
    id         serial PRIMARY KEY,
    name       text NOT NULL,
    email      text UNIQUE,
    age        integer,
    mood       qa.mood DEFAULT 'ok',
    created_at timestamptz NOT NULL DEFAULT '2026-01-01 00:00:00+00'
);
COMMENT ON TABLE qa.people IS 'Fifty deterministic rows for assertions.';

INSERT INTO qa.people (name, email, age, mood)
SELECT 'Person ' || lpad(g::text, 2, '0'),
       'person' || g || '@qa.test',
       CASE WHEN g % 10 = 0 THEN NULL ELSE 18 + g END,
       (ARRAY['sad', 'ok', 'happy'])[1 + g % 3]::qa.mood
FROM generate_series(1, 50) AS g;

CREATE INDEX people_age_idx ON qa.people (age);

-- ── big_numbers: large table for paging, row caps, Stop/timeout ────────
CREATE TABLE qa.big_numbers (
    id  bigint PRIMARY KEY,
    val text NOT NULL
);
INSERT INTO qa.big_numbers
SELECT g, 'row-' || g FROM generate_series(1, 100000) AS g;
ANALYZE qa.big_numbers;

-- ── Identifiers that need quoting ──────────────────────────────────────
CREATE TABLE qa."Weird Table" (
    "Mixed Case" integer PRIMARY KEY,
    "with space" text,
    "quote""d"   text,
    "кириллица"  text
);
INSERT INTO qa."Weird Table" VALUES
    (1, 'a b', 'it''s', 'привет'),
    (2, NULL, '"dq"', 'мир'),
    (3, 'emoji 🐘', NULL, NULL);

-- ── type_samples: one row per known value + one all-NULL row ───────────
CREATE TABLE qa.type_samples (
    id          integer PRIMARY KEY,
    c_bool      boolean,
    c_int2      smallint,
    c_int4      integer,
    c_int8      bigint,
    c_numeric   numeric(12, 4),
    c_float4    real,
    c_float8    double precision,
    c_text      text,
    c_varchar   varchar(20),
    c_char      char(3),
    c_bytea     bytea,
    c_date      date,
    c_time      time,
    c_timetz    timetz,
    c_ts        timestamp,
    c_tstz      timestamptz,
    c_interval  interval,
    c_uuid      uuid,
    c_json      json,
    c_jsonb     jsonb,
    c_inet      inet,
    c_cidr      cidr,
    c_macaddr   macaddr,
    c_int_arr   integer[],
    c_text_arr  text[],
    c_int_range int4range,
    c_ts_range  tsrange,
    c_mood      qa.mood,
    c_domain    qa.positive_int,
    c_composite qa.point2,
    c_money     money,
    c_bit       bit(4),
    c_xml       xml,
    c_point     point
);

INSERT INTO qa.type_samples VALUES (
    1,
    true,
    -12,
    123456,
    9007199254740993,
    1234.5678,
    1.5,
    2.25,
    'hello, world',
    'varchar',
    'abc',
    '\xdeadbeef',
    '2026-03-15',
    '13:45:30',
    '13:45:30+02',
    '2026-03-15 13:45:30.123456',
    '2026-03-15 13:45:30+00',
    '1 year 2 mons 3 days 04:05:06',
    'a0eebc99-9c0b-4ef8-bb6d-6bb9bd380a11',
    '{"a": 1}',
    '{"b": [1, 2, 3]}',
    '192.168.0.1/24',
    '10.0.0.0/8',
    '08:00:2b:01:02:03',
    '{1,2,3}',
    '{"x","y z",NULL}',
    '[1,10)',
    '[2026-01-01 00:00,2026-02-01 00:00)',
    'happy',
    42,
    ROW(3, 4),
    12.34,
    B'1010',
    '<a>1</a>',
    '(1.5,2.5)'
);
INSERT INTO qa.type_samples (id) VALUES (2);

-- ── FK parent/child (RESTRICT) for cascade-delete flows ────────────────
CREATE TABLE qa.parent (
    id   integer PRIMARY KEY,
    name text NOT NULL
);
CREATE TABLE qa.child (
    id        integer PRIMARY KEY,
    parent_id integer NOT NULL REFERENCES qa.parent (id) ON DELETE RESTRICT,
    note      text
);
INSERT INTO qa.parent VALUES (1, 'p1'), (2, 'p2');
INSERT INTO qa.child VALUES (10, 1, 'c10'), (11, 1, 'c11'), (20, 2, 'c20');

-- ── editable: the table UI tests edit (they reset it first) ────────────
CREATE TABLE qa.editable (
    id   integer PRIMARY KEY,
    note text
);
INSERT INTO qa.editable VALUES (1, 'one'), (2, 'two'), (3, 'three');

-- ── Table without a primary key (editing must be refused) ──────────────
CREATE TABLE qa.no_pk (
    a integer,
    b text
);
INSERT INTO qa.no_pk VALUES (1, 'x'), (2, 'y');

-- ── Views, sequence, routines, trigger ─────────────────────────────────
CREATE VIEW qa.adults AS
    SELECT id, name, age FROM qa.people WHERE age >= 40;

CREATE MATERIALIZED VIEW qa.mood_counts AS
    SELECT mood, count(*) AS n FROM qa.people GROUP BY mood;

CREATE SEQUENCE qa.ticket_seq START 100 INCREMENT 5;

CREATE FUNCTION qa.add(a integer, b integer) RETURNS integer
    LANGUAGE sql IMMUTABLE AS 'SELECT a + b';

CREATE FUNCTION qa.add(a numeric, b numeric) RETURNS numeric
    LANGUAGE sql IMMUTABLE AS 'SELECT a + b';

CREATE FUNCTION qa.slow(seconds double precision) RETURNS integer
    LANGUAGE plpgsql AS $$
BEGIN
    PERFORM pg_sleep(seconds);
    RETURN 1;
END $$;

CREATE FUNCTION qa.noisy() RETURNS integer
    LANGUAGE plpgsql AS $$
BEGIN
    RAISE NOTICE 'qa notice';
    RETURN 7;
END $$;

CREATE PROCEDURE qa.touch_people()
    LANGUAGE sql AS 'UPDATE qa.people SET age = age WHERE false';

CREATE FUNCTION qa.audit_trigger() RETURNS trigger
    LANGUAGE plpgsql AS $$
BEGIN
    RETURN NEW;
END $$;

CREATE TRIGGER people_audit
    BEFORE UPDATE ON qa.people
    FOR EACH ROW EXECUTE FUNCTION qa.audit_trigger();

CREATE AGGREGATE qa.sum_sq(integer) (
    SFUNC = int4pl,
    STYPE = integer,
    INITCOND = '0'
);

CREATE FUNCTION qa.text_ieq(text, text) RETURNS boolean
    LANGUAGE sql IMMUTABLE AS 'SELECT lower($1) = lower($2)';

CREATE OPERATOR qa.=== (
    LEFTARG = text,
    RIGHTARG = text,
    FUNCTION = qa.text_ieq
);

-- ── Partitioned table ──────────────────────────────────────────────────
CREATE TABLE qa.measurements (
    id      integer NOT NULL,
    taken   date NOT NULL,
    reading numeric
) PARTITION BY RANGE (taken);
CREATE TABLE qa.measurements_2026_h1 PARTITION OF qa.measurements
    FOR VALUES FROM ('2026-01-01') TO ('2026-07-01');
CREATE TABLE qa.measurements_2026_h2 PARTITION OF qa.measurements
    FOR VALUES FROM ('2026-07-01') TO ('2027-01-01');

-- ── A second database for database switching ───────────────────────────
-- (CREATE DATABASE can't run in a transaction block; psql -f runs each
-- statement on its own, so this is fine.)
CREATE DATABASE sequelpg_test_other;

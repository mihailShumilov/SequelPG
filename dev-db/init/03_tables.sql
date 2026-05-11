-- 03_tables.sql
-- Tables that exercise every PostgreSQL field type, every constraint flavor,
-- and every storage variant (regular, unlogged, partitioned, inherited,
-- table-of-type). Foreign tables live at the end because they reach across
-- the cluster.

\echo '== Tables =='

SET search_path = app, public;

-- ────────────────────────────────────────────────────────────────────────
-- KITCHEN SINK: every built-in scalar / container type, side by side. The
-- demo data in 09 leaves NULLs in some columns so the UI can render both
-- "real value" and "NULL" treatments per type.
-- ────────────────────────────────────────────────────────────────────────
CREATE TABLE app.kitchen_sink (
    -- Identity / generated PK exercising PG18 SQL standard "GENERATED ALWAYS AS IDENTITY".
    id              bigint  GENERATED ALWAYS AS IDENTITY PRIMARY KEY,

    -- Numeric family
    n_smallint      smallint,
    n_integer       integer,
    n_bigint        bigint,
    n_numeric       numeric(20, 5),
    n_decimal       decimal(12, 2),
    n_real          real,
    n_double        double precision,
    n_money         money,
    n_serial        serial,
    n_bigserial     bigserial,

    -- Character family
    c_char          char(8),
    c_varchar       varchar(64),
    c_text          text,
    c_citext        citext,
    c_name          name,

    -- Binary
    b_bytea         bytea,

    -- Boolean
    bool_flag       boolean,

    -- Date / time / interval
    d_date          date,
    t_time          time,
    t_timetz        time with time zone,
    ts_timestamp    timestamp,
    ts_timestamptz  timestamp with time zone,
    iv_interval     interval,

    -- Network
    net_inet        inet,
    net_cidr        cidr,
    net_macaddr     macaddr,
    net_macaddr8    macaddr8,

    -- Bit string
    bit_fixed       bit(8),
    bit_varying     bit varying(32),

    -- Geometric
    geo_point       point,
    geo_line        line,
    geo_lseg        lseg,
    geo_box         box,
    geo_path        path,
    geo_polygon     polygon,
    geo_circle      circle,

    -- Identifiers
    uid_v4          uuid,
    uid_v7          uuid,                -- populated via uuidv7() in 09 (PG18+)

    -- Markup / structured
    xml_doc         xml,
    json_doc        json,
    jsonb_doc       jsonb,

    -- Text search
    ts_vector       tsvector,
    ts_query        tsquery,

    -- Range / multirange
    r_int4range     int4range,
    r_int8range     int8range,
    r_numrange      numrange,
    r_daterange     daterange,
    r_tsrange       tsrange,
    r_tstzrange     tstzrange,
    mr_int4         int4multirange,
    mr_date         datemultirange,
    r_price         pricerange,

    -- Arrays
    a_int           integer[],
    a_text          text[],
    a_int_2d        integer[][],
    a_jsonb         jsonb[],

    -- User-defined
    addr            address_t,
    money_total     money_amount,
    coords          geo_coords,
    name_parts      full_name,
    role            user_role,
    status          order_status,
    prio            priority_level,

    -- Domains
    email           email_address,
    homepage        url,
    pos_qty         positive_int,
    pct             percent_unit,
    country_code    iso_country,

    -- ltree / hstore
    tag_path        ltree,
    attrs           hstore,

    -- Catalog references
    obj_oid         oid,
    obj_regclass    regclass,
    obj_regproc     regproc,
    obj_regtype     regtype,

    -- Replication / system
    lsn_pos         pg_lsn,

    -- Audit
    created_at      timestamptz NOT NULL DEFAULT now(),
    updated_at      timestamptz
);
COMMENT ON TABLE app.kitchen_sink IS 'One column per built-in type — the canonical UI render-test fixture.';

-- ────────────────────────────────────────────────────────────────────────
-- TENANTS / USERS / ORDERS — the relational backbone for joins, FKs, RLS,
-- and the partitioned children below.
-- ────────────────────────────────────────────────────────────────────────
CREATE TABLE app.tenants (
    id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    slug         citext UNIQUE NOT NULL,
    display_name text NOT NULL,
    plan         text NOT NULL DEFAULT 'free' CHECK (plan IN ('free', 'pro', 'enterprise')),
    created_at   timestamptz NOT NULL DEFAULT now()
);
COMMENT ON TABLE app.tenants IS 'Top-level tenant; powers the RLS policy on app.documents.';

CREATE TABLE app.users (
    id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id    uuid NOT NULL REFERENCES app.tenants(id) ON DELETE CASCADE,
    email        email_address UNIQUE NOT NULL,
    role         user_role NOT NULL DEFAULT 'customer',
    name         full_name,
    age          smallint CHECK (age IS NULL OR age BETWEEN 0 AND 130),
    address      address_t,
    metadata     jsonb NOT NULL DEFAULT '{}'::jsonb,
    -- Generated-column demos for built-in types live on app.documents
    -- (word_count, VIRTUAL) and app.measurements (10_pg18_features.sql,
    -- STORED + VIRTUAL). PG18 forbids generation expressions that reference
    -- user-defined types, so we can't use `name` (composite) or `role` (enum)
    -- here — they'd need a trigger instead.
    created_at   timestamptz NOT NULL DEFAULT now(),
    updated_at   timestamptz
);
COMMENT ON TABLE app.users IS 'Tenant-scoped user. Generated-column demos live on app.documents and app.measurements (PG18 restricts generation expressions from referencing user-defined types).';

CREATE TABLE app.products (
    id           bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    sku          text NOT NULL UNIQUE,
    name         text NOT NULL,
    description  text,
    price        money_amount NOT NULL,
    tags         text[] NOT NULL DEFAULT '{}',
    attributes   jsonb NOT NULL DEFAULT '{}'::jsonb,
    search_vec   tsvector GENERATED ALWAYS AS (
        to_tsvector('english', coalesce(name, '') || ' ' || coalesce(description, ''))
    ) STORED,
    created_at   timestamptz NOT NULL DEFAULT now()
);
COMMENT ON COLUMN app.products.search_vec IS 'Auto-maintained FTS index source.';

-- Composite PK + multi-column UNIQUE so the inspector has variety.
CREATE TABLE app.product_prices (
    product_id   bigint NOT NULL REFERENCES app.products(id) ON DELETE CASCADE,
    region       iso_country NOT NULL,
    valid_range  daterange NOT NULL,
    price        numeric(12, 4) NOT NULL CHECK (price >= 0),
    PRIMARY KEY (product_id, region, valid_range),
    -- Exclude overlapping ranges per (product, region). Requires btree_gist
    -- to mix equality + range exclusion in one constraint.
    EXCLUDE USING gist (
        product_id WITH =,
        region     WITH =,
        valid_range WITH &&
    )
);

-- ────────────────────────────────────────────────────────────────────────
-- ORDERS — partitioned by month. Demonstrates RANGE partitioning, default
-- partition, and a multi-column primary key carrying the partition key.
-- ────────────────────────────────────────────────────────────────────────
CREATE TABLE app.orders (
    id           uuid NOT NULL DEFAULT gen_random_uuid(),
    tenant_id    uuid NOT NULL,
    user_id      uuid NOT NULL REFERENCES app.users(id) ON DELETE RESTRICT,
    placed_at    timestamptz NOT NULL,
    status       order_status NOT NULL DEFAULT 'pending',
    payment      payment_method,
    total        money_amount NOT NULL,
    notes        text,
    PRIMARY KEY (id, placed_at)
) PARTITION BY RANGE (placed_at);

CREATE TABLE app.orders_2026_01 PARTITION OF app.orders
    FOR VALUES FROM ('2026-01-01') TO ('2026-02-01');
CREATE TABLE app.orders_2026_02 PARTITION OF app.orders
    FOR VALUES FROM ('2026-02-01') TO ('2026-03-01');
CREATE TABLE app.orders_2026_03 PARTITION OF app.orders
    FOR VALUES FROM ('2026-03-01') TO ('2026-04-01');
CREATE TABLE app.orders_2026_04 PARTITION OF app.orders
    FOR VALUES FROM ('2026-04-01') TO ('2026-05-01');
CREATE TABLE app.orders_2026_05 PARTITION OF app.orders
    FOR VALUES FROM ('2026-05-01') TO ('2026-06-01');
CREATE TABLE app.orders_default PARTITION OF app.orders DEFAULT;

-- Cold partition lives in a separate schema to model an archive policy.
CREATE TABLE archive.orders_2025 PARTITION OF app.orders
    FOR VALUES FROM ('2025-01-01') TO ('2026-01-01');

-- ────────────────────────────────────────────────────────────────────────
-- SHIPMENTS — LIST partitioning over region.
-- ────────────────────────────────────────────────────────────────────────
CREATE TABLE app.shipments (
    id          bigserial NOT NULL,
    region      iso_country NOT NULL,
    order_id    uuid NOT NULL,
    placed_at   timestamptz NOT NULL,
    carrier     text NOT NULL,
    shipped_at  timestamptz,
    delivered_at timestamptz,
    PRIMARY KEY (id, region),
    FOREIGN KEY (order_id, placed_at) REFERENCES app.orders(id, placed_at) ON DELETE CASCADE
) PARTITION BY LIST (region);

CREATE TABLE app.shipments_us PARTITION OF app.shipments FOR VALUES IN ('US');
CREATE TABLE app.shipments_eu PARTITION OF app.shipments FOR VALUES IN ('DE', 'FR', 'GB', 'NL', 'ES', 'IT');
CREATE TABLE app.shipments_other PARTITION OF app.shipments DEFAULT;

-- ────────────────────────────────────────────────────────────────────────
-- EVENTS — HASH partitioning. Useful for testing the partition inspector
-- against many sibling tables.
-- ────────────────────────────────────────────────────────────────────────
CREATE TABLE app.events (
    id           uuid NOT NULL DEFAULT gen_random_uuid(),
    occurred_at  timestamptz NOT NULL DEFAULT now(),
    type         text NOT NULL,
    session_id   text,
    client_ip    inet,
    metadata     jsonb NOT NULL DEFAULT '{}'::jsonb,
    PRIMARY KEY (id)
) PARTITION BY HASH (id);

CREATE TABLE app.events_h0 PARTITION OF app.events FOR VALUES WITH (modulus 4, remainder 0);
CREATE TABLE app.events_h1 PARTITION OF app.events FOR VALUES WITH (modulus 4, remainder 1);
CREATE TABLE app.events_h2 PARTITION OF app.events FOR VALUES WITH (modulus 4, remainder 2);
CREATE TABLE app.events_h3 PARTITION OF app.events FOR VALUES WITH (modulus 4, remainder 3);

-- ────────────────────────────────────────────────────────────────────────
-- INHERITANCE (legacy) — animals/dogs/cats. The classic example, kept so
-- the navigator's inheritance-aware behavior has something to render.
-- ────────────────────────────────────────────────────────────────────────
CREATE TABLE app.animals (
    id      bigserial PRIMARY KEY,
    name    text NOT NULL,
    born_on date
);

CREATE TABLE app.dogs (
    breed       text,
    is_good_boy boolean NOT NULL DEFAULT true
) INHERITS (app.animals);

CREATE TABLE app.cats (
    color       text,
    indoor_only boolean NOT NULL DEFAULT false
) INHERITS (app.animals);

-- ────────────────────────────────────────────────────────────────────────
-- TABLE-OF-TYPE — uses the address_t composite as its row shape.
-- ────────────────────────────────────────────────────────────────────────
CREATE TABLE app.warehouse_addresses OF address_t (
    PRIMARY KEY (line1, postal_code)
);

-- ────────────────────────────────────────────────────────────────────────
-- UNLOGGED — fast scratch table; no WAL, lost on crash.
-- ────────────────────────────────────────────────────────────────────────
CREATE UNLOGGED TABLE staging.imports_buffer (
    batch_id    uuid NOT NULL DEFAULT gen_random_uuid(),
    line_no     bigint NOT NULL,
    raw         jsonb NOT NULL,
    PRIMARY KEY (batch_id, line_no)
);

-- ────────────────────────────────────────────────────────────────────────
-- AUDIT — the trigger in 06 writes here. No FK to the source so we can
-- delete source rows without breaking history.
-- ────────────────────────────────────────────────────────────────────────
CREATE TABLE audit.row_history (
    id          bigserial PRIMARY KEY,
    happened_at timestamptz NOT NULL DEFAULT now(),
    actor       text NOT NULL DEFAULT current_user,
    action      text NOT NULL CHECK (action IN ('INSERT', 'UPDATE', 'DELETE')),
    schema_name text NOT NULL,
    table_name  text NOT NULL,
    row_pk      jsonb,
    old_row     jsonb,
    new_row     jsonb
);
CREATE INDEX ON audit.row_history (table_name, happened_at);

-- ────────────────────────────────────────────────────────────────────────
-- DOCUMENTS — RLS demo target. Tenant-scoped, with a deferrable FK to the
-- author so multi-row upserts can shuffle order without violating the
-- constraint mid-transaction.
-- ────────────────────────────────────────────────────────────────────────
CREATE TABLE app.documents (
    id          bigserial PRIMARY KEY,
    tenant_id   uuid NOT NULL REFERENCES app.tenants(id) ON DELETE CASCADE,
    author_id   uuid NOT NULL,
    title       text NOT NULL,
    body        text,
    tags        text[] NOT NULL DEFAULT '{}',
    metadata    jsonb NOT NULL DEFAULT '{}'::jsonb,
    word_count  integer GENERATED ALWAYS AS (
        coalesce(array_length(regexp_split_to_array(coalesce(body, ''), '\s+'), 1), 0)
    ) VIRTUAL,
    created_at  timestamptz NOT NULL DEFAULT now(),
    updated_at  timestamptz,
    CONSTRAINT documents_author_fk FOREIGN KEY (author_id)
        REFERENCES app.users(id) DEFERRABLE INITIALLY IMMEDIATE
);

-- ────────────────────────────────────────────────────────────────────────
-- FOREIGN TABLE — self-loopback via postgres_fdw, so no second cluster is
-- needed. The mapping uses the same demo credentials; not for production.
-- ────────────────────────────────────────────────────────────────────────
DO $$
DECLARE
    db text := current_database();
BEGIN
    EXECUTE format(
        $sql$CREATE SERVER IF NOT EXISTS local_loopback
             FOREIGN DATA WRAPPER postgres_fdw
             OPTIONS (host 'localhost', port '5432', dbname %L)$sql$,
        db
    );
END$$;

DO $$
DECLARE
    usr text := current_user;
    pwd text := current_setting('demo.password', true);
BEGIN
    -- Password is plumbed via custom GUC in 09; if absent (e.g. user reset
    -- the cluster mid-script) we still create the mapping so the foreign
    -- table itself shows up in the navigator.
    EXECUTE format(
        $sql$CREATE USER MAPPING IF NOT EXISTS FOR %I SERVER local_loopback
             OPTIONS (user %L, password %L)$sql$,
        usr, usr, coalesce(pwd, 'demo')
    );
END$$;

CREATE FOREIGN TABLE app.products_remote (
    id    bigint,
    sku   text,
    name  text
) SERVER local_loopback
  OPTIONS (schema_name 'app', table_name 'products');
COMMENT ON FOREIGN TABLE app.products_remote IS 'Loopback FDW pointing at app.products — for testing the foreign-table inspector.';

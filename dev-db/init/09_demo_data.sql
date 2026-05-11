-- 09_demo_data.sql
-- Realistic-looking sample data so every table the inspector touches has
-- something to render. Quantities are small (tens to a few hundred rows)
-- so cold starts stay fast.

\echo '== Demo data =='

SET search_path = app, public;

-- Stash the demo password as a session GUC so the FDW user-mapping in 03
-- can pick it up; harmless if the value is missing.
SELECT set_config('demo.password', 'demo', false);

-- ── Tenants ─────────────────────────────────────────────────────────────
INSERT INTO app.tenants (id, slug, display_name, plan) VALUES
    ('11111111-1111-1111-1111-111111111111', 'acme',     'Acme Inc.',          'pro'),
    ('22222222-2222-2222-2222-222222222222', 'globex',   'Globex Corp.',       'enterprise'),
    ('33333333-3333-3333-3333-333333333333', 'initech',  'Initech',            'free'),
    ('44444444-4444-4444-4444-444444444444', 'umbrella', 'Umbrella Corp.',     'enterprise');

-- ── Users ───────────────────────────────────────────────────────────────
INSERT INTO app.users (id, tenant_id, email, role, name, age, address, metadata) VALUES
    ('aaaa1111-0000-0000-0000-000000000001', '11111111-1111-1111-1111-111111111111',
        'alice@acme.test', 'admin',
        ROW('Alice', NULL, 'Anderson', NULL)::full_name, 34,
        ROW('1 Innovation Way', NULL, 'San Francisco', 'CA', '94110', 'US')::address_t,
        '{"newsletter": true, "tags": ["founder","early-adopter"]}'),
    ('aaaa1111-0000-0000-0000-000000000002', '11111111-1111-1111-1111-111111111111',
        'bob@acme.test', 'staff',
        ROW('Bob', 'M.', 'Brown', NULL)::full_name, 41,
        ROW('22 Market St', 'Suite 5', 'Brooklyn', 'NY', '11201', 'US')::address_t,
        '{"newsletter": false}'),
    ('aaaa1111-0000-0000-0000-000000000003', '11111111-1111-1111-1111-111111111111',
        'carol@acme.test', 'customer',
        ROW('Carol', NULL, 'Chen', NULL)::full_name, 28,
        NULL, '{"prefs": {"locale": "en-US"}}'),
    ('bbbb2222-0000-0000-0000-000000000001', '22222222-2222-2222-2222-222222222222',
        'dave@globex.test', 'admin',
        ROW('Dave', NULL, 'Drummond', 'PhD')::full_name, 52,
        ROW('Avenida Reforma 9', NULL, 'Mexico City', 'CDMX', '06600', 'MX')::address_t,
        '{"vip": true}'),
    ('bbbb2222-0000-0000-0000-000000000002', '22222222-2222-2222-2222-222222222222',
        'eve@globex.test', 'vendor',
        ROW('Eve', 'L.', 'Esposito', NULL)::full_name, NULL,
        ROW('Via Roma 12', NULL, 'Rome', NULL, '00184', 'IT')::address_t,
        '{}'),
    ('cccc3333-0000-0000-0000-000000000001', '33333333-3333-3333-3333-333333333333',
        'frank@initech.test', 'customer',
        ROW('Frank', NULL, 'Furter', NULL)::full_name, 67,
        ROW('Hauptstr. 7', NULL, 'Berlin', NULL, '10115', 'DE')::address_t,
        '{}'),
    ('dddd4444-0000-0000-0000-000000000001', '44444444-4444-4444-4444-444444444444',
        'grace@umbrella.test', 'admin',
        ROW('Grace', NULL, 'Glover', NULL)::full_name, 39,
        NULL, '{"clearance": "level-5"}');

-- ── Products ────────────────────────────────────────────────────────────
INSERT INTO app.products (sku, name, description, price, tags, attributes) VALUES
    ('SKU-001', 'Widget Classic', 'The original spinning widget. Made in the USA.',
        ROW(19.99, 'USD')::money_amount, ARRAY['hardware','best-seller'],
        '{"weight_g": 220, "color": "silver", "warranty_yr": 2}'),
    ('SKU-002', 'Sprocket Pro',    'Heavy-duty sprocket for industrial uses.',
        ROW(149.50, 'USD')::money_amount, ARRAY['hardware','b2b'],
        '{"weight_g": 1800, "color": "black", "warranty_yr": 5}'),
    ('SKU-003', 'Gizmo Mini',      'Pocket gizmo, USB-C rechargeable.',
        ROW(34.00, 'EUR')::money_amount, ARRAY['gadget','consumer'],
        '{"battery_mah": 1500, "color": "blue"}'),
    ('SKU-004', 'Mega Module',     NULL,
        ROW(2499.00, 'USD')::money_amount, ARRAY['enterprise'],
        '{"dimensions": {"w_mm": 480, "d_mm": 220, "h_mm": 90}}'),
    ('SKU-005', 'Eco Refill',      'Compostable refill cartridge.',
        ROW(4.95, 'GBP')::money_amount, ARRAY['consumer','eco'],
        '{"refill_count": 3}'),
    ('SKU-006', 'Quantum Dongle',  'Plug it in. Don''t ask.',
        ROW(99.99, 'USD')::money_amount, ARRAY['gadget','experimental'],
        '{"observed": true, "schroedinger_state": "superposed"}');

-- ── Product prices (range PK + exclusion constraint) ────────────────────
INSERT INTO app.product_prices (product_id, region, valid_range, price) VALUES
    (1, 'US', daterange('2026-01-01','2026-07-01'),  19.99),
    (1, 'US', daterange('2026-07-01', NULL),         21.99),
    (1, 'DE', daterange('2026-01-01', NULL),         18.50),
    (2, 'US', daterange('2026-01-01', NULL),        149.50),
    (3, 'IT', daterange('2026-01-01', NULL),         34.00),
    (5, 'GB', daterange('2026-01-01', NULL),          4.95);

-- ── Orders + their hash/list/range partitions ───────────────────────────
INSERT INTO app.orders (tenant_id, user_id, placed_at, status, payment, total, notes) VALUES
    ('11111111-1111-1111-1111-111111111111', 'aaaa1111-0000-0000-0000-000000000001',
        '2026-01-15 14:22:01+00', 'delivered', 'card',     ROW(39.98, 'USD')::money_amount, 'gift wrap'),
    ('11111111-1111-1111-1111-111111111111', 'aaaa1111-0000-0000-0000-000000000003',
        '2026-02-03 09:00:00+00', 'paid',      'paypal',   ROW(149.50, 'USD')::money_amount, NULL),
    ('11111111-1111-1111-1111-111111111111', 'aaaa1111-0000-0000-0000-000000000002',
        '2026-03-10 17:45:33+00', 'shipped',   'card',     ROW(2499.00, 'USD')::money_amount, 'expedite'),
    ('22222222-2222-2222-2222-222222222222', 'bbbb2222-0000-0000-0000-000000000002',
        '2026-04-22 11:11:11+00', 'pending',   'bank_transfer', ROW(4.95, 'GBP')::money_amount, NULL),
    ('33333333-3333-3333-3333-333333333333', 'cccc3333-0000-0000-0000-000000000001',
        '2026-05-04 06:30:00+00', 'cancelled', 'crypto',   ROW(99.99, 'USD')::money_amount, 'fraud check'),
    ('11111111-1111-1111-1111-111111111111', 'aaaa1111-0000-0000-0000-000000000003',
        '2025-12-22 19:00:00+00', 'refunded',  'card',     ROW(34.00, 'EUR')::money_amount, 'returned');

-- ── Shipments (LIST partitions) ─────────────────────────────────────────
INSERT INTO app.shipments (region, order_id, placed_at, carrier, shipped_at, delivered_at)
SELECT 'US', id, placed_at, 'ups', placed_at + interval '1 day', placed_at + interval '4 days'
FROM app.orders WHERE status IN ('delivered','shipped','paid') AND tenant_id = '11111111-1111-1111-1111-111111111111';

INSERT INTO app.shipments (region, order_id, placed_at, carrier, shipped_at, delivered_at)
SELECT 'GB', id, placed_at, 'royal-mail', placed_at + interval '2 days', NULL
FROM app.orders WHERE status = 'pending' AND tenant_id = '22222222-2222-2222-2222-222222222222';

-- ── Events (HASH partitions) — one per row per type ─────────────────────
INSERT INTO app.events (occurred_at, type, session_id, client_ip, metadata)
SELECT
    now() - (random() * interval '30 days'),
    (ARRAY['page_view','click','signup','purchase','error'])[1 + (i % 5)],
    'sess-' || (i % 25),
    ('10.0.' || (i % 256) || '.' || ((i * 7) % 256))::inet,
    jsonb_build_object('seq', i, 'utm', (ARRAY['email','google','direct','social'])[1 + (i % 4)])
FROM generate_series(1, 200) AS s(i);

-- ── Inheritance children ────────────────────────────────────────────────
INSERT INTO app.dogs (name, born_on, breed, is_good_boy) VALUES
    ('Rex',    '2020-04-12', 'Border Collie', true),
    ('Biscuit','2022-07-30', 'Labrador',      true);

INSERT INTO app.cats (name, born_on, color, indoor_only) VALUES
    ('Mochi',  '2021-01-09', 'tortie', true),
    ('Sasha',  '2019-11-20', 'black',  false);

-- ── Warehouse addresses (table-of-type) ─────────────────────────────────
INSERT INTO app.warehouse_addresses VALUES
    ('100 Loading Dock', NULL,        'Memphis',   'TN', '38101', 'US'),
    ('Industriestr. 4',  'Halle 3',   'Hamburg',   NULL, '20097', 'DE'),
    ('Rua das Flores 9', NULL,        'Lisbon',    NULL, '1100',  'PT');

-- ── Categories (ltree) ──────────────────────────────────────────────────
INSERT INTO app.categories (path, label) VALUES
    ('hardware',                 'Hardware'),
    ('hardware.fasteners',       'Fasteners'),
    ('hardware.fasteners.bolts', 'Bolts'),
    ('hardware.fasteners.nuts',  'Nuts'),
    ('hardware.power_tools',     'Power Tools'),
    ('software',                 'Software'),
    ('software.dev_tools',       'Dev Tools'),
    ('software.databases',       'Databases');

-- ── Documents (RLS-enabled) ─────────────────────────────────────────────
INSERT INTO app.documents (tenant_id, author_id, title, body, tags, metadata) VALUES
    ('11111111-1111-1111-1111-111111111111', 'aaaa1111-0000-0000-0000-000000000001',
        'Welcome to Acme', 'Hi everyone, welcome aboard. Read the handbook.',
        ARRAY['onboarding'], '{"published": true}'),
    ('11111111-1111-1111-1111-111111111111', 'aaaa1111-0000-0000-0000-000000000002',
        'Q1 Roadmap',      'Plan for the first quarter. Confidential.',
        ARRAY['planning','internal'], '{"published": false}'),
    ('22222222-2222-2222-2222-222222222222', 'bbbb2222-0000-0000-0000-000000000001',
        'Globex Strategy', 'Globalize. Localize. Synergize.',
        ARRAY['strategy'], '{"published": true, "level": "vip"}'),
    ('44444444-4444-4444-4444-444444444444', 'dddd4444-0000-0000-0000-000000000001',
        'Project T-Virus', 'Top secret. Do not commit to git.',
        ARRAY['classified'], '{"published": false}');

-- ── Kitchen sink rows ───────────────────────────────────────────────────
INSERT INTO app.kitchen_sink (
    n_smallint, n_integer, n_bigint, n_numeric, n_decimal, n_real, n_double, n_money,
    c_char, c_varchar, c_text, c_citext, c_name,
    b_bytea, bool_flag,
    d_date, t_time, t_timetz, ts_timestamp, ts_timestamptz, iv_interval,
    net_inet, net_cidr, net_macaddr, net_macaddr8,
    bit_fixed, bit_varying,
    geo_point, geo_line, geo_lseg, geo_box, geo_path, geo_polygon, geo_circle,
    uid_v4, uid_v7,
    xml_doc, json_doc, jsonb_doc,
    ts_vector, ts_query,
    r_int4range, r_int8range, r_numrange, r_daterange, r_tsrange, r_tstzrange,
    mr_int4, mr_date, r_price,
    a_int, a_text, a_int_2d, a_jsonb,
    addr, money_total, coords, name_parts, role, status, prio,
    email, homepage, pos_qty, pct, country_code,
    tag_path, attrs,
    obj_oid, obj_regclass, obj_regproc, obj_regtype, lsn_pos
) VALUES (
    32767, 2147483647, 9223372036854775807, 12345.67890, 999.99, 3.14, 2.718281828, '$1,234.56',
    'CODE-A  ', 'short text', 'A longer text payload that should be truncated in the grid for visual variety.',
    'CaSeLeSs', 'role_name',
    decode('48656c6c6f', 'hex'), true,
    DATE '2026-05-11', TIME '13:45:30', TIME WITH TIME ZONE '13:45:30+02',
    TIMESTAMP '2026-05-11 13:45:30', TIMESTAMP WITH TIME ZONE '2026-05-11 13:45:30+00',
    INTERVAL '1 year 2 months 3 days 04:05:06',
    '192.168.1.42'::inet, '10.0.0.0/24'::cidr,
    '08:00:2b:01:02:03'::macaddr, '08:00:2b:ff:fe:01:02:03'::macaddr8,
    B'10101010', B'1100110011',
    POINT(1, 2), '{1,-1,0}'::line, LSEG '[(0,0),(3,4)]', BOX '((0,0),(2,2))',
    PATH '[(0,0),(1,1),(2,0)]', POLYGON '((0,0),(2,0),(2,2),(0,2))', CIRCLE '<(0,0),5>',
    gen_random_uuid(),
    -- uuidv7() is PG18; falls back to gen_random_uuid() on older servers via COALESCE.
    COALESCE((SELECT uuidv7() WHERE current_setting('server_version_num')::int >= 180000),
             gen_random_uuid()),
    XMLPARSE(DOCUMENT '<?xml version="1.0"?><greeting tone="warm">hello</greeting>'),
    '{"a": 1, "b": [true, null, "x"]}'::json,
    '{"a": 1, "b": [true, null, "x"], "nested": {"k": "v"}}'::jsonb,
    to_tsvector('english', 'PostgreSQL is a powerful database'),
    to_tsquery('english', 'powerful & database'),
    int4range(1, 10), int8range(1000, 1000000), numrange(0.0, 1.0, '[]'),
    daterange('2026-01-01', '2026-12-31'),
    tsrange('2026-05-11 09:00', '2026-05-11 17:00'),
    tstzrange('2026-05-11 09:00+00', '2026-05-11 17:00+00'),
    '{[1,5),[10,20)}'::int4multirange,
    '{[2026-01-01,2026-02-01),[2026-06-01,2026-07-01)}'::datemultirange,
    pricerange(9.99, 19.99),
    ARRAY[1,2,3,5,8,13], ARRAY['alpha','beta','gamma'],
    ARRAY[[1,2,3],[4,5,6]], ARRAY['{"k":1}'::jsonb,'{"k":2}'::jsonb],
    ROW('221B Baker Street', NULL, 'London', NULL, 'NW1 6XE', 'GB')::address_t,
    ROW(1234.5678, 'USD')::money_amount,
    ROW(37.7749, -122.4194)::geo_coords,
    ROW('Ada','Augusta','Lovelace',NULL)::full_name,
    'admin', 'paid', 'high',
    'demo+kitchen@example.org', 'https://www.postgresql.org/',
    7, 99.50, 'GB',
    'top.middle.leaf'::ltree, 'k1=>v1, k2=>v2'::hstore,
    'pg_class'::regclass::oid, 'pg_class'::regclass, 'now'::regproc, 'integer'::regtype,
    pg_current_wal_lsn()
);

-- A second row that's almost entirely NULL — for testing the NULL renderer.
INSERT INTO app.kitchen_sink (n_integer, c_text, bool_flag) VALUES
    (NULL, NULL, NULL);

-- And one boolean=false row, plus an extreme edge case for numerics.
INSERT INTO app.kitchen_sink (n_integer, n_numeric, bool_flag, c_text) VALUES
    (-2147483648, 'NaN'::numeric, false, '');

-- ── Refresh the materialized view now that orders exist ────────────────
REFRESH MATERIALIZED VIEW reports.daily_orders;

-- ── Vacuum/analyze so reltuples is sensible for the row-count display ──
ANALYZE app.kitchen_sink, app.tenants, app.users, app.products, app.orders,
        app.events, app.shipments, app.documents;

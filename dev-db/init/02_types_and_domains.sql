-- 02_types_and_domains.sql
-- User-defined enums, composites, ranges, and domains. These are exercised
-- both by the kitchen_sink table in 03 and by demo data in 09.

\echo '== User-defined types =='

SET search_path = app, public;

-- ── ENUMs ───────────────────────────────────────────────────────────────
CREATE TYPE order_status   AS ENUM ('draft', 'pending', 'paid', 'shipped', 'delivered', 'cancelled', 'refunded');
CREATE TYPE user_role      AS ENUM ('admin', 'staff', 'customer', 'vendor', 'guest');
CREATE TYPE priority_level AS ENUM ('low', 'medium', 'high', 'urgent');
CREATE TYPE payment_method AS ENUM ('card', 'paypal', 'bank_transfer', 'crypto', 'cash');
CREATE TYPE weekday        AS ENUM ('mon', 'tue', 'wed', 'thu', 'fri', 'sat', 'sun');

-- ── COMPOSITE TYPES ─────────────────────────────────────────────────────
CREATE TYPE address_t AS (
    line1       text,
    line2       text,
    city        text,
    region      text,
    postal_code text,
    country     char(2)
);

CREATE TYPE money_amount AS (
    amount   numeric(20, 4),
    currency char(3)
);

CREATE TYPE geo_coords AS (
    lat numeric(9, 6),
    lon numeric(9, 6)
);

CREATE TYPE full_name AS (
    first  text,
    middle text,
    last   text,
    suffix text
);

-- ── DOMAINS (constrained scalars) ───────────────────────────────────────
CREATE DOMAIN positive_int   AS integer        CHECK (VALUE > 0);
CREATE DOMAIN nonnegative    AS numeric(20, 2) CHECK (VALUE >= 0);
CREATE DOMAIN percent_unit   AS numeric(5, 2)  CHECK (VALUE BETWEEN 0 AND 100);
CREATE DOMAIN email_address  AS citext         CHECK (VALUE ~* '^[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}$');
CREATE DOMAIN url            AS text           CHECK (VALUE ~* '^https?://');
CREATE DOMAIN iso_country    AS char(2)        CHECK (VALUE ~ '^[A-Z]{2}$');

-- ── CUSTOM RANGE TYPE ───────────────────────────────────────────────────
-- Built-in ranges (int4range, daterange, etc.) are exercised in 03; this
-- proves user-defined ranges + their auto-generated multirange work too.
-- numeric has no built-in subtype_diff returning float8, so we provide one.
CREATE FUNCTION app.numeric_diff_f8(a numeric, b numeric)
RETURNS float8
LANGUAGE sql IMMUTABLE STRICT PARALLEL SAFE
RETURN (a - b)::float8;

CREATE TYPE pricerange AS RANGE (
    subtype = numeric,
    subtype_diff = app.numeric_diff_f8
);

COMMENT ON TYPE order_status IS 'Lifecycle states of a customer order.';
COMMENT ON TYPE address_t    IS 'Reusable mailing-address composite.';
COMMENT ON DOMAIN email_address IS 'Case-insensitive RFC-loose email address.';

-- 01_extensions_and_schemas.sql
-- Bootstraps every contrib extension we'll exercise plus the schemas that
-- group the demo objects. Kept first so later scripts can reference the
-- extensions and schemas without ordering surprises.

\echo '== Extensions and schemas =='

-- Cryptography & identifiers
CREATE EXTENSION IF NOT EXISTS pgcrypto;     -- gen_random_uuid, digest, crypt
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";  -- legacy uuid_generate_*

-- Text/data types
CREATE EXTENSION IF NOT EXISTS citext;       -- case-insensitive text
CREATE EXTENSION IF NOT EXISTS hstore;       -- key/value store
CREATE EXTENSION IF NOT EXISTS ltree;        -- hierarchical labels
CREATE EXTENSION IF NOT EXISTS pg_trgm;      -- trigram similarity
CREATE EXTENSION IF NOT EXISTS unaccent;     -- diacritic stripping
CREATE EXTENSION IF NOT EXISTS fuzzystrmatch;-- soundex / levenshtein
CREATE EXTENSION IF NOT EXISTS isn;          -- ISBN/ISSN/EAN13 types
CREATE EXTENSION IF NOT EXISTS intarray;     -- int[] operators

-- Index helpers
CREATE EXTENSION IF NOT EXISTS btree_gin;    -- btree opclasses inside GIN
CREATE EXTENSION IF NOT EXISTS btree_gist;   -- btree opclasses inside GiST

-- Geometry / earth
CREATE EXTENSION IF NOT EXISTS cube;
CREATE EXTENSION IF NOT EXISTS earthdistance;
CREATE EXTENSION IF NOT EXISTS seg;

-- Foreign data
CREATE EXTENSION IF NOT EXISTS postgres_fdw;
CREATE EXTENSION IF NOT EXISTS file_fdw;

-- Crosstab / pivots
CREATE EXTENSION IF NOT EXISTS tablefunc;

-- Diagnostics (built-in but lives in shared_preload_libraries; image enables it)
CREATE EXTENSION IF NOT EXISTS pg_stat_statements;

-- Schemas. `app` is the primary tenant; the rest exist so the navigator has
-- something interesting to show besides public.
CREATE SCHEMA IF NOT EXISTS app;
CREATE SCHEMA IF NOT EXISTS audit;
CREATE SCHEMA IF NOT EXISTS archive;
CREATE SCHEMA IF NOT EXISTS reports;
CREATE SCHEMA IF NOT EXISTS staging;

COMMENT ON SCHEMA app      IS 'Primary application objects (tables, views, routines).';
COMMENT ON SCHEMA audit    IS 'Append-only audit log driven by AFTER triggers.';
COMMENT ON SCHEMA archive  IS 'Long-term storage of cold partitions.';
COMMENT ON SCHEMA reports  IS 'Materialized views and reporting helpers.';
COMMENT ON SCHEMA staging  IS 'Scratch area for ETL / temporary loads.';

-- Make `app` the default lookup schema for sessions used by demo callers; the
-- demo user keeps `public` available for ad-hoc work. Using format()+\gexec
-- so the script doesn't hard-code the database name (which can be overridden
-- via the POSTGRES_DB env var on the container).
SELECT format('ALTER DATABASE %I SET search_path TO app, public', current_database())
\gexec

-- 05_routines.sql
-- Functions (SQL + plpgsql), procedures, custom aggregates and operators.
-- Trigger functions live here too; the triggers themselves are wired up in
-- 06 so the BEFORE/AFTER metadata sits next to its host table.

\echo '== Functions, procedures, aggregates =='

SET search_path = app, public;

-- ── Scalar SQL function ─────────────────────────────────────────────────
CREATE FUNCTION app.add_two(a integer, b integer)
RETURNS integer
LANGUAGE sql IMMUTABLE PARALLEL SAFE
RETURN a + b;
COMMENT ON FUNCTION app.add_two(integer, integer) IS 'Trivial scalar fn — exercises overload display in the navigator.';

-- Overload (different arg types) so the inspector renders multiple entries
-- for the same name.
CREATE FUNCTION app.add_two(a numeric, b numeric)
RETURNS numeric
LANGUAGE sql IMMUTABLE
RETURN a + b;

-- ── Variadic + DEFAULT args ─────────────────────────────────────────────
-- VARIADIC must be the last parameter, so its preceding params can't take
-- defaults unless every later param has one too. Variadic itself gets a
-- default empty array so callers can omit the names list entirely.
CREATE FUNCTION app.greet(greeting text, VARIADIC names text[] DEFAULT ARRAY[]::text[])
RETURNS text
LANGUAGE plpgsql IMMUTABLE
AS $$
BEGIN
    IF cardinality(names) = 0 THEN
        RETURN greeting || '!';
    END IF;
    RETURN greeting || ', ' || array_to_string(names, ', ') || '!';
END
$$;

-- ── SETOF function returning composite rows ─────────────────────────────
CREATE FUNCTION app.recent_orders(p_limit integer DEFAULT 10)
RETURNS SETOF app.orders
LANGUAGE sql STABLE
AS $$
    SELECT * FROM app.orders ORDER BY placed_at DESC LIMIT p_limit;
$$;

-- ── Function returning a TABLE shape ────────────────────────────────────
CREATE FUNCTION app.order_summary(p_user uuid)
RETURNS TABLE (
    status         order_status,
    order_count    bigint,
    total_amount   numeric
)
LANGUAGE sql STABLE
AS $$
    SELECT status, count(*)::bigint, coalesce(sum((total).amount), 0)::numeric
    FROM app.orders
    WHERE user_id = p_user
    GROUP BY status;
$$;

-- ── plpgsql with control flow + EXCEPTION block ─────────────────────────
CREATE FUNCTION app.safe_divide(num numeric, den numeric)
RETURNS numeric
LANGUAGE plpgsql IMMUTABLE
AS $$
BEGIN
    RETURN num / den;
EXCEPTION
    WHEN division_by_zero THEN
        RAISE WARNING 'safe_divide called with zero denominator';
        RETURN NULL;
END
$$;

-- ── Procedure (CALL-only, may COMMIT) ───────────────────────────────────
CREATE PROCEDURE app.archive_old_orders(p_before timestamptz)
LANGUAGE plpgsql
AS $$
DECLARE
    moved bigint;
BEGIN
    WITH d AS (
        DELETE FROM app.orders WHERE placed_at < p_before RETURNING *
    )
    INSERT INTO archive.orders_2025 SELECT * FROM d;

    GET DIAGNOSTICS moved = ROW_COUNT;
    RAISE NOTICE 'Archived % orders', moved;
END
$$;

-- ── Custom aggregate: concatenation with separator ──────────────────────
CREATE FUNCTION app.concat_with_sep_sfunc(state text, value text, sep text)
RETURNS text
LANGUAGE sql IMMUTABLE
AS $$
    SELECT CASE
        WHEN state IS NULL OR state = '' THEN value
        ELSE state || sep || value
    END
$$;

CREATE AGGREGATE app.concat_with_sep(text, text) (
    sfunc     = app.concat_with_sep_sfunc,
    stype     = text,
    initcond  = ''
);
COMMENT ON AGGREGATE app.concat_with_sep(text, text)
    IS 'agg(value, separator) — like string_agg but with the separator passed per row.';

-- ── Custom operator: case-insensitive equality on text ──────────────────
CREATE FUNCTION app.text_ieq(text, text)
RETURNS boolean
LANGUAGE sql IMMUTABLE PARALLEL SAFE
RETURN lower($1) = lower($2);

CREATE OPERATOR app.=== (
    LEFTARG  = text,
    RIGHTARG = text,
    FUNCTION = app.text_ieq,
    COMMUTATOR = ===
);

-- ── Trigger functions (the triggers themselves are in 06) ───────────────

-- Generic AFTER row trigger: writes (old, new) into audit.row_history.
CREATE FUNCTION audit.log_change()
RETURNS trigger
LANGUAGE plpgsql
AS $$
DECLARE
    pk_cols text[] := TG_ARGV;
    pk_json jsonb;
BEGIN
    IF cardinality(pk_cols) > 0 THEN
        SELECT jsonb_object_agg(c, COALESCE(to_jsonb(NEW)->c, to_jsonb(OLD)->c))
        INTO pk_json
        FROM unnest(pk_cols) AS c;
    END IF;

    INSERT INTO audit.row_history (action, schema_name, table_name, row_pk, old_row, new_row)
    VALUES (
        TG_OP,
        TG_TABLE_SCHEMA,
        TG_TABLE_NAME,
        pk_json,
        CASE WHEN TG_OP IN ('UPDATE', 'DELETE') THEN to_jsonb(OLD) END,
        CASE WHEN TG_OP IN ('INSERT', 'UPDATE') THEN to_jsonb(NEW) END
    );

    RETURN COALESCE(NEW, OLD);
END
$$;

-- BEFORE UPDATE row trigger: stamp updated_at.
CREATE FUNCTION app.set_updated_at()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
    NEW.updated_at := now();
    RETURN NEW;
END
$$;

-- BEFORE DELETE row trigger with WHEN clause: refuse to delete admins.
CREATE FUNCTION app.prevent_admin_delete()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
    RAISE EXCEPTION 'cannot delete admin user %', OLD.email
        USING ERRCODE = 'check_violation';
END
$$;

-- AFTER STATEMENT trigger: refresh materialized view.
CREATE FUNCTION reports.refresh_daily_orders()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
    REFRESH MATERIALIZED VIEW CONCURRENTLY reports.daily_orders;
    RETURN NULL;
END
$$;

-- INSTEAD OF trigger on the user_orders view: lets callers UPDATE status
-- without learning the underlying join shape.
CREATE FUNCTION app.user_orders_update()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
    UPDATE app.orders
    SET status = NEW.status
    WHERE id = OLD.order_id AND placed_at = OLD.placed_at;
    RETURN NEW;
END
$$;

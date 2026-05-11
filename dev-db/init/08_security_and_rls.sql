-- 08_security_and_rls.sql
-- Roles, GRANTs, and a row-level-security policy on app.documents. RLS uses
-- a per-session GUC (`app.current_tenant`) so demo callers can scope reads
-- without joining auth metadata.

\echo '== Roles, grants, RLS =='

SET search_path = app, public;

-- ── Roles ───────────────────────────────────────────────────────────────
DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'app_admin') THEN
        CREATE ROLE app_admin    NOLOGIN;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'app_user') THEN
        CREATE ROLE app_user     NOLOGIN;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'app_readonly') THEN
        CREATE ROLE app_readonly NOLOGIN;
    END IF;
END$$;

COMMENT ON ROLE app_admin    IS 'Full app-schema read/write; can change schema.';
COMMENT ON ROLE app_user     IS 'CRUD on tenant-scoped tables; no DDL.';
COMMENT ON ROLE app_readonly IS 'SELECT only across app + reports.';

-- ── Grants ──────────────────────────────────────────────────────────────
GRANT USAGE ON SCHEMA app, audit, archive, reports, staging TO app_admin;
GRANT USAGE ON SCHEMA app, reports TO app_user, app_readonly;

GRANT ALL                                 ON ALL TABLES IN SCHEMA app, audit, archive, reports, staging TO app_admin;
GRANT SELECT, INSERT, UPDATE, DELETE      ON ALL TABLES IN SCHEMA app                                   TO app_user;
GRANT SELECT                              ON ALL TABLES IN SCHEMA app, reports                          TO app_readonly;

GRANT USAGE, SELECT, UPDATE ON ALL SEQUENCES IN SCHEMA app, staging TO app_admin, app_user;

-- Future tables / sequences inherit the same grants.
ALTER DEFAULT PRIVILEGES IN SCHEMA app
    GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO app_user;
ALTER DEFAULT PRIVILEGES IN SCHEMA app, reports
    GRANT SELECT ON TABLES TO app_readonly;

-- ── Row-Level Security on documents ─────────────────────────────────────
ALTER TABLE app.documents ENABLE ROW LEVEL SECURITY;
ALTER TABLE app.documents FORCE ROW LEVEL SECURITY;  -- applies to owners too

CREATE POLICY documents_tenant_isolation
    ON app.documents
    USING (tenant_id::text = current_setting('app.current_tenant', true))
    WITH CHECK (tenant_id::text = current_setting('app.current_tenant', true));

CREATE POLICY documents_admin_bypass
    ON app.documents
    AS PERMISSIVE
    FOR ALL
    TO app_admin
    USING (true) WITH CHECK (true);

COMMENT ON POLICY documents_tenant_isolation ON app.documents
    IS $$Set app.current_tenant to a tenant UUID for the session, e.g.
       SELECT set_config('app.current_tenant', 'aaaaaaaa-...', false);$$;

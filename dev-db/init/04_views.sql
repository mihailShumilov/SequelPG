-- 04_views.sql
-- Plain views, an updatable view, a recursive CTE view, and a materialized
-- view with its own index. Run before routines so triggers can target them.

\echo '== Views =='

SET search_path = app, public;

-- Simple lookup view; auto-updatable since it's a 1-table SELECT *.
CREATE VIEW app.active_users AS
SELECT *
FROM app.users
WHERE role <> 'guest';
COMMENT ON VIEW app.active_users IS 'All users except guests; updatable.';

-- Joined view, NOT auto-updatable (the INSTEAD OF trigger in 06 makes it
-- writeable for one column).
CREATE VIEW app.user_orders AS
SELECT u.id            AS user_id,
       u.email,
       o.id            AS order_id,
       o.placed_at,
       o.status,
       (o.total).amount  AS total_amount,
       (o.total).currency AS total_currency
FROM app.users u
JOIN app.orders o ON o.user_id = u.id;
COMMENT ON VIEW app.user_orders IS 'User × order roll-up. INSTEAD-OF trigger in 06 lets you UPDATE status.';

-- Aggregated view.
CREATE VIEW reports.tenant_revenue AS
SELECT t.slug,
       t.display_name,
       count(o.*)                       AS order_count,
       coalesce(sum((o.total).amount), 0) AS total_revenue,
       max(o.placed_at)                 AS last_order_at
FROM app.tenants t
LEFT JOIN app.orders o ON o.tenant_id = t.id
GROUP BY t.slug, t.display_name;

-- Recursive view: example category tree using ltree paths.
CREATE TABLE app.categories (
    id       bigserial PRIMARY KEY,
    path     ltree NOT NULL UNIQUE,
    label    text NOT NULL
);

CREATE VIEW app.category_tree AS
WITH RECURSIVE walk(id, depth, label, path, parent_path) AS (
    SELECT id, 1 AS depth, label, path,
           CASE WHEN nlevel(path) > 1
                THEN subpath(path, 0, nlevel(path) - 1)
                ELSE NULL::ltree END
    FROM app.categories
    WHERE nlevel(path) = 1
  UNION ALL
    SELECT c.id, w.depth + 1, c.label, c.path,
           subpath(c.path, 0, nlevel(c.path) - 1)
    FROM app.categories c
    JOIN walk w ON c.path <@ w.path AND nlevel(c.path) = w.depth + 1
)
SELECT * FROM walk;
COMMENT ON VIEW app.category_tree IS 'Recursive walk over the ltree-backed category hierarchy.';

-- Materialized view + supporting index. REFRESH MATERIALIZED VIEW happens
-- in 09 after the demo data lands.
CREATE MATERIALIZED VIEW reports.daily_orders AS
SELECT date_trunc('day', placed_at)::date AS order_day,
       status,
       count(*)                            AS n,
       sum((total).amount)                 AS revenue
FROM app.orders
GROUP BY 1, 2
WITH NO DATA;

CREATE UNIQUE INDEX daily_orders_pk
    ON reports.daily_orders (order_day, status);
COMMENT ON MATERIALIZED VIEW reports.daily_orders IS 'Per-day order rollup; refreshed concurrently from the audit trigger.';

-- First REFRESH must be non-concurrent — CONCURRENTLY needs an existing
-- populated snapshot. After this seed (which produces zero rows), the
-- AFTER-STATEMENT trigger on app.orders can safely refresh CONCURRENTLY.
REFRESH MATERIALIZED VIEW reports.daily_orders;

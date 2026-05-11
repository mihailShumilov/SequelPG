-- 06_triggers.sql
-- Hooks the trigger functions from 05 onto their target tables/views. Each
-- trigger uses a distinct combination of timing / level / event so the
-- inspector renders the full matrix.

\echo '== Triggers =='

SET search_path = app, public;

-- BEFORE UPDATE row trigger — touch updated_at.
CREATE TRIGGER tg_users_set_updated_at
    BEFORE UPDATE ON app.users
    FOR EACH ROW
    WHEN (OLD.* IS DISTINCT FROM NEW.*)
    EXECUTE FUNCTION app.set_updated_at();

CREATE TRIGGER tg_documents_set_updated_at
    BEFORE UPDATE ON app.documents
    FOR EACH ROW
    EXECUTE FUNCTION app.set_updated_at();

-- BEFORE DELETE row trigger with predicate — admin protection.
CREATE TRIGGER tg_users_no_admin_delete
    BEFORE DELETE ON app.users
    FOR EACH ROW
    WHEN (OLD.role = 'admin')
    EXECUTE FUNCTION app.prevent_admin_delete();

-- AFTER row triggers feeding the audit log. Argument list is the PK columns,
-- consumed by audit.log_change() via TG_ARGV.
CREATE TRIGGER tg_users_audit
    AFTER INSERT OR UPDATE OR DELETE ON app.users
    FOR EACH ROW EXECUTE FUNCTION audit.log_change('id');

CREATE TRIGGER tg_orders_audit
    AFTER INSERT OR UPDATE OR DELETE ON app.orders
    FOR EACH ROW EXECUTE FUNCTION audit.log_change('id', 'placed_at');

CREATE TRIGGER tg_products_audit
    AFTER INSERT OR UPDATE OR DELETE ON app.products
    FOR EACH ROW EXECUTE FUNCTION audit.log_change('id');

-- AFTER STATEMENT trigger — refresh the daily-orders MV.
CREATE TRIGGER tg_orders_refresh_mv
    AFTER INSERT OR UPDATE OR DELETE ON app.orders
    FOR EACH STATEMENT EXECUTE FUNCTION reports.refresh_daily_orders();

-- INSTEAD OF trigger on a non-updatable view.
CREATE TRIGGER tg_user_orders_update
    INSTEAD OF UPDATE ON app.user_orders
    FOR EACH ROW EXECUTE FUNCTION app.user_orders_update();

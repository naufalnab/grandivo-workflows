-- Grandivo product dashboard database roles.
--
-- Run with psql as the existing PostgreSQL admin user, for example:
--   psql -U grandivo_sync -d grandivo \
--     -v dashboard_password='CHANGE_THIS_TO_A_STRONG_PASSWORD' \
--     -f dashboard-readonly.sql
--
-- The password is passed at execution time and is not stored in this repository.

\if :{?dashboard_password}
\else
\echo 'ERROR: dashboard_password belum diisi. Jalankan psql dengan -v dashboard_password=...'
\quit
\endif

DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'grandivo_viewer') THEN
        CREATE ROLE grandivo_viewer NOLOGIN;
    END IF;

    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'grandivo_dashboard') THEN
        CREATE ROLE grandivo_dashboard LOGIN;
    END IF;
END
$$;

ALTER ROLE grandivo_dashboard PASSWORD :'dashboard_password';

GRANT USAGE ON SCHEMA public TO grandivo_viewer;
GRANT SELECT ON TABLE public.products TO grandivo_viewer;
GRANT grandivo_viewer TO grandivo_dashboard;

-- Keep API requests bounded and read-only at the database role level.
ALTER ROLE grandivo_dashboard SET statement_timeout = '10s';
ALTER ROLE grandivo_dashboard SET default_transaction_read_only = on;

COMMENT ON ROLE grandivo_viewer IS 'Read-only role exposed by the Grandivo product dashboard API.';
COMMENT ON ROLE grandivo_dashboard IS 'PostgREST authenticator used by the Grandivo product dashboard.';

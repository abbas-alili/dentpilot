-- =============================================================================
-- Test setup for `supabase test db` (Supabase CLI, Postgres 16+).
-- Runs first and is NOT rolled back, so the grants stay for the files after it.
-- Local test database only: migrations and production are untouched.
--
-- 1. On Supabase, postgres is not a superuser. Since Postgres 16 creating a
--    role grants its creator ADMIN but not SET, so the tests'
--    `set local role dentpilot_agent` fails without this.
-- 2. The CLI installs pgTAP in schema extensions; while acting as
--    dentpilot_agent the tests need to reach is(), ok(), results_eq() there.
-- Harmless under scripts/test_local.sh (superuser).
-- =============================================================================
create extension if not exists pgtap;

select plan(1);

grant dentpilot_agent to postgres with inherit false, set true;
grant usage on schema extensions to dentpilot_agent;

select pass('test roles ready');

select * from finish();

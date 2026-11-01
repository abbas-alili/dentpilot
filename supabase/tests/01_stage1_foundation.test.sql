-- =============================================================================
-- Stage 1 tests — run with `supabase test db` (or scripts/test_local.sh).
-- Everything runs inside one transaction and is rolled back.
-- =============================================================================
begin;
create extension if not exists pgtap;

select plan(33);

-- -----------------------------------------------------------------------------
-- Fixtures: two clinics, one staff user each
-- -----------------------------------------------------------------------------
insert into core.clinics (id, name) values
  ('11111111-0000-0000-0000-00000000000a', 'Clinic A'),
  ('22222222-0000-0000-0000-00000000000b', 'Clinic B');

insert into core.professionals (id, clinic_id, display_name) values
  ('11111111-0000-0000-0000-0000000000d1', '11111111-0000-0000-0000-00000000000a', 'Dr A'),
  ('22222222-0000-0000-0000-0000000000d9', '22222222-0000-0000-0000-00000000000b', 'Dr B');

insert into core.patients (id, clinic_id, wa_id) values
  ('11111111-0000-0000-0000-0000000000f1', '11111111-0000-0000-0000-00000000000a', '994500000001'),
  ('11111111-0000-0000-0000-0000000000f2', '11111111-0000-0000-0000-00000000000a', '994500000002'),
  ('22222222-0000-0000-0000-0000000000f9', '22222222-0000-0000-0000-00000000000b', '994500000009');

insert into auth.users (id) values
  ('aaaaaaaa-0000-0000-0000-000000000001'),   -- receptionist at A
  ('bbbbbbbb-0000-0000-0000-000000000002');   -- receptionist at B

insert into ops.staff (user_id, clinic_id, role) values
  ('aaaaaaaa-0000-0000-0000-000000000001', '11111111-0000-0000-0000-00000000000a', 'receptionist'),
  ('bbbbbbbb-0000-0000-0000-000000000002', '22222222-0000-0000-0000-00000000000b', 'receptionist');

-- -----------------------------------------------------------------------------
-- Structure
-- -----------------------------------------------------------------------------
select has_schema('core');
select has_schema('clinical');
select has_schema('ops');

select ok(
  (select not rolsuper and not rolbypassrls from pg_roles where rolname = 'dentpilot_agent'),
  'dentpilot_agent is neither superuser nor BYPASSRLS');

select ok(
  (select bool_and(c.relrowsecurity and c.relforcerowsecurity)
     from pg_class c join pg_namespace n on n.oid = c.relnamespace
    where n.nspname = 'core' and c.relkind = 'r'),
  'every core table has RLS enabled and forced');

select ok(
  (select bool_and(c.relrowsecurity)
     from pg_class c join pg_namespace n on n.oid = c.relnamespace
    where n.nspname = 'ops' and c.relkind = 'r'),
  'every ops table has RLS enabled');

-- -----------------------------------------------------------------------------
-- The clinical wall
-- -----------------------------------------------------------------------------
select ok(not has_schema_privilege('dentpilot_agent', 'clinical', 'usage'),
  'agent has no USAGE on schema clinical');
select ok(not has_schema_privilege('service_role', 'clinical', 'usage'),
  'service_role has no USAGE on schema clinical');
select ok(has_table_privilege('service_role', 'core.clinics', 'insert'),
  'service_role can create clinics (onboarding)');
select ok(not has_schema_privilege('anon', 'core', 'usage'),
  'anon has no USAGE on schema core');
select ok(not has_function_privilege('anon', 'ops.my_clinic_ids()', 'execute'),
  'anon cannot execute ops.my_clinic_ids()');
select is(
  (select count(*)::int
     from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname in ('core', 'clinical', 'ops')
      and has_function_privilege('public', p.oid, 'execute')),
  0, 'no function in core/clinical/ops is executable by PUBLIC');

-- -----------------------------------------------------------------------------
-- Constraints
-- -----------------------------------------------------------------------------
select throws_ok(
  $$ insert into core.clinics (name, timezone) values ('Bad', 'Mars/Olympus') $$,
  '23514', null, 'unknown time zone is rejected');

select throws_ok(
  $$ insert into core.services (clinic_id, code, name_az, name_ru, duration_minutes)
     values ('11111111-0000-0000-0000-00000000000a', 'svc_x', 'x', 'x', 0) $$,
  '23514', null, 'zero-minute service is rejected');

select throws_ok(
  $$ insert into core.services (clinic_id, code, name_az, name_ru, duration_minutes)
     values ('11111111-0000-0000-0000-00000000000a', 'Bad Code!', 'x', 'x', 30) $$,
  '23514', null, 'malformed service code is rejected');

select throws_ok(
  $$ insert into core.patients (clinic_id, wa_id) values ('11111111-0000-0000-0000-00000000000a', '+994 50 000') $$,
  '23514', null, 'non-digit wa_id is rejected');

select throws_ok(
  $$ insert into core.patients (clinic_id, wa_id) values ('11111111-0000-0000-0000-00000000000a', '994500000001') $$,
  '23505', null, 'same WhatsApp user twice in one clinic is rejected');

select lives_ok(
  $$ insert into core.patients (clinic_id, wa_id) values ('22222222-0000-0000-0000-00000000000b', '994500000001') $$,
  'same WhatsApp user may be a patient of two clinics');

select throws_ok(
  $$ insert into ops.staff (user_id, clinic_id, role, professional_id)
     values ('aaaaaaaa-0000-0000-0000-000000000001', '22222222-0000-0000-0000-00000000000b', 'dentist',
             '11111111-0000-0000-0000-0000000000d1') $$,
  '23503', null, 'staff row cannot link to another clinic''s dentist (composite FK)');

select throws_ok(
  $$ insert into ops.staff (user_id, clinic_id, role)
     values ('bbbbbbbb-0000-0000-0000-000000000002', '11111111-0000-0000-0000-00000000000a', 'dentist') $$,
  '23514', null, 'a dentist staff row must name its professional');

-- -----------------------------------------------------------------------------
-- updated_at and audit
-- -----------------------------------------------------------------------------
update core.patients set updated_at = '2000-01-01' where id = '11111111-0000-0000-0000-0000000000f1';
update core.patients set display_name = 'Leyla' where id = '11111111-0000-0000-0000-0000000000f1';

select ok(
  (select updated_at > '2001-01-01' from core.patients where id = '11111111-0000-0000-0000-0000000000f1'),
  'updated_at is refreshed on update');

select is(
  (select after ->> 'display_name' from ops.audit_events
    where entity = 'core.patients' and entity_id = '11111111-0000-0000-0000-0000000000f1' and action = 'UPDATE'
    order by id desc limit 1),
  'Leyla', 'audit records the after-image');

select is(
  (select count(*)::int from ops.audit_events
    where entity = 'core.clinics' and entity_id = '11111111-0000-0000-0000-00000000000a'
      and clinic_id = '11111111-0000-0000-0000-00000000000a'),
  1, 'audit rows for core.clinics carry the clinic''s own id');

-- -----------------------------------------------------------------------------
-- Assistant (dentpilot_agent) isolation
-- -----------------------------------------------------------------------------
set local role dentpilot_agent;

select is((select count(*)::int from core.patients), 0,
  'agent with no clinic set sees no patients');

select set_config('app.clinic_id', '11111111-0000-0000-0000-00000000000a', true);
select set_config('app.actor', 'assistant', true);

select is((select count(*)::int from core.patients), 2,
  'agent sees only its clinic''s patients');
select is((select count(*)::int from core.clinics), 1,
  'agent sees only its own clinic row');

select throws_ok(
  $$ insert into core.patients (clinic_id, wa_id) values ('22222222-0000-0000-0000-00000000000b', '994509999999') $$,
  '42501', null, 'agent cannot create a patient in another clinic');

select lives_ok(
  $$ insert into core.patients (clinic_id, wa_id) values ('11111111-0000-0000-0000-00000000000a', '994507777777') $$,
  'agent can create a patient in its own clinic');

select throws_ok(
  $$ delete from core.patients where wa_id = '994507777777' $$,
  '42501', null, 'agent cannot delete patients');

select throws_ok(
  $$ update core.services set duration_minutes = 10 $$,
  '42501', null, 'agent cannot change services');

reset role;

select is(
  (select actor from ops.audit_events
    where entity = 'core.patients' and after ->> 'wa_id' = '994507777777'),
  'assistant', 'audit attributes the agent''s insert to app.actor');

-- -----------------------------------------------------------------------------
-- Staff (authenticated) isolation
-- -----------------------------------------------------------------------------
select set_config('request.jwt.claim.sub', 'aaaaaaaa-0000-0000-0000-000000000001', true);
select set_config('app.actor', '', true);
set local role authenticated;

select is((select count(*)::int from core.patients), 3,
  'staff of clinic A sees clinic A patients only (2 fixtures + 1 created by agent)');

-- RLS hides other clinics' rows, so an update aimed at them matches nothing.
update core.patients set display_name = 'hacked'
 where clinic_id = '22222222-0000-0000-0000-00000000000b';

reset role;

select is(
  (select count(*)::int from core.patients
    where clinic_id = '22222222-0000-0000-0000-00000000000b' and display_name = 'hacked'),
  0, 'staff of clinic A cannot update clinic B patients');

select * from finish();
rollback;

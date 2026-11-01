-- =============================================================================
-- Stage 5 tests — price list, treatment log, visibility per role, price
-- snapshots, totals and overrides, the clinical wall.
-- Runs in one transaction and is rolled back.
-- =============================================================================
begin;
create extension if not exists pgtap;

select plan(30);

-- -----------------------------------------------------------------------------
-- Helpers and fixtures
--   Clinic A: Dr One (user d1), Dr Two (user d2), receptionist (r), admin (a)
--   Clinic B: receptionist (b)
-- -----------------------------------------------------------------------------
create schema t;
create function t.id(p_key text) returns uuid language sql stable as
  $$ select nullif(current_setting('t.' || p_key, true), '')::uuid $$;
grant usage on schema t to authenticated;
grant execute on all functions in schema t to authenticated;

-- Act as a staff member (by auth.users id) for the following statements.
create function t.as_staff(p_user uuid) returns void language sql as $$
  select set_config('request.jwt.claim.sub', p_user::text, true);
$$;

insert into core.clinics (id, name) values
  ('11111111-0000-0000-0000-00000000000a', 'Clinic A'),
  ('22222222-0000-0000-0000-00000000000b', 'Clinic B');
insert into core.professionals (id, clinic_id, display_name) values
  ('11111111-0000-0000-0000-0000000000d1', '11111111-0000-0000-0000-00000000000a', 'Dr One'),
  ('11111111-0000-0000-0000-0000000000d2', '11111111-0000-0000-0000-00000000000a', 'Dr Two');
insert into core.services (id, clinic_id, code, name_az, name_ru, duration_minutes) values
  ('11111111-0000-0000-0000-0000000000e1', '11111111-0000-0000-0000-00000000000a', 'svc_exam', 'Müayinə', 'Осмотр', 30);
insert into core.patients (id, clinic_id, wa_id) values
  ('11111111-0000-0000-0000-0000000000f1', '11111111-0000-0000-0000-00000000000a', '994500000001'),
  ('11111111-0000-0000-0000-0000000000f2', '11111111-0000-0000-0000-00000000000a', '994500000002');
insert into core.appointments (id, clinic_id, patient_id, professional_id, service_id, start_at, end_at, blocked_until) values
  ('11111111-0000-0000-0000-0000000000a1', '11111111-0000-0000-0000-00000000000a', '11111111-0000-0000-0000-0000000000f1',
   '11111111-0000-0000-0000-0000000000d1', '11111111-0000-0000-0000-0000000000e1',
   now() + interval '1 day', now() + interval '1 day 30 minutes', now() + interval '1 day 30 minutes');

insert into auth.users (id) values
  ('dddddddd-0000-0000-0000-000000000001'), ('dddddddd-0000-0000-0000-000000000002'),
  ('cccccccc-0000-0000-0000-000000000001'), ('aaaaaaaa-0000-0000-0000-000000000001'),
  ('bbbbbbbb-0000-0000-0000-000000000001');
insert into ops.staff (user_id, clinic_id, role, professional_id) values
  ('dddddddd-0000-0000-0000-000000000001', '11111111-0000-0000-0000-00000000000a', 'dentist',      '11111111-0000-0000-0000-0000000000d1'),
  ('dddddddd-0000-0000-0000-000000000002', '11111111-0000-0000-0000-00000000000a', 'dentist',      '11111111-0000-0000-0000-0000000000d2'),
  ('cccccccc-0000-0000-0000-000000000001', '11111111-0000-0000-0000-00000000000a', 'receptionist', null),
  ('aaaaaaaa-0000-0000-0000-000000000001', '11111111-0000-0000-0000-00000000000a', 'admin',        null),
  ('bbbbbbbb-0000-0000-0000-000000000001', '22222222-0000-0000-0000-00000000000b', 'receptionist', null);

-- =============================================================================
-- The wall
-- =============================================================================
select ok(not has_schema_privilege('dentpilot_agent', 'clinical', 'usage'), 'assistant has no access to clinical');
select ok(not has_schema_privilege('service_role',    'clinical', 'usage'), 'service_role has no access to clinical');
select ok(not has_column_privilege('authenticated', 'clinical.treatment_line_items', 'unit_price', 'update'),
  'nobody may edit a line''s price snapshot');
select ok(not has_table_privilege('authenticated', 'clinical.treatment_records', 'delete'),
  'treatment records cannot be deleted');
select ok(not has_table_privilege('authenticated', 'clinical.price_list', 'delete'),
  'price-list entries cannot be deleted (deactivate instead)');

-- =============================================================================
-- Price list (Q10: all staff)
-- =============================================================================
select t.as_staff('cccccccc-0000-0000-0000-000000000001');
set local role authenticated;
select lives_ok($$ insert into clinical.price_list (clinic_id, code, name, price_azn)
                   values ('11111111-0000-0000-0000-00000000000a', 'filling', 'Plomb', 80) $$,
  'receptionist adds a price');
select throws_ok($$ insert into clinical.price_list (clinic_id, code, name, price_azn)
                    values ('11111111-0000-0000-0000-00000000000a', 'bad', 'Bad', -5) $$,
  '23514', null, 'negative price is rejected');
select throws_ok($$ insert into clinical.price_list (clinic_id, code, name, price_azn)
                    values ('11111111-0000-0000-0000-00000000000a', 'filling', 'Dup', 1) $$,
  '23505', null, 'duplicate price code is rejected');
reset role;

select t.as_staff('dddddddd-0000-0000-0000-000000000001');
set local role authenticated;
select lives_ok($$ insert into clinical.price_list (clinic_id, code, name, price_azn)
                   values ('11111111-0000-0000-0000-00000000000a', 'xray', 'Rentgen', 10) $$,
  'dentist adds a price');
select set_config('t.fill', (select id::text from clinical.price_list where code = 'filling'), true);
select set_config('t.xray', (select id::text from clinical.price_list where code = 'xray'), true);
reset role;

select t.as_staff('bbbbbbbb-0000-0000-0000-000000000001');
set local role authenticated;
select is((select count(*)::int from clinical.price_list), 0, 'clinic B staff cannot see clinic A prices');
reset role;

-- =============================================================================
-- Treatment records (Q11: dentists see only their own)
-- =============================================================================
select t.as_staff('dddddddd-0000-0000-0000-000000000001');
set local role authenticated;
select set_config('t.r1', '11111111-0000-0000-0000-0000000000c1', true);
select lives_ok($$ insert into clinical.treatment_records (id, clinic_id, patient_id, professional_id, appointment_id, treated_on)
                   values (t.id('r1'), '11111111-0000-0000-0000-00000000000a', '11111111-0000-0000-0000-0000000000f1',
                           '11111111-0000-0000-0000-0000000000d1', '11111111-0000-0000-0000-0000000000a1', current_date) $$,
  'Dr One records his own treatment');
select is((select created_by from clinical.treatment_records where id = t.id('r1')),
  'dddddddd-0000-0000-0000-000000000001'::uuid, 'created_by is set from the signed-in user');

select throws_ok($$ insert into clinical.treatment_records (clinic_id, patient_id, professional_id, treated_on)
                    values ('11111111-0000-0000-0000-00000000000a', '11111111-0000-0000-0000-0000000000f2',
                            '11111111-0000-0000-0000-0000000000d2', current_date) $$,
  '42501', null, 'Dr One cannot write a record for Dr Two');

select throws_ok($$ insert into clinical.treatment_records (clinic_id, patient_id, professional_id, appointment_id, treated_on)
                    values ('11111111-0000-0000-0000-00000000000a', '11111111-0000-0000-0000-0000000000f2',
                            '11111111-0000-0000-0000-0000000000d1', '11111111-0000-0000-0000-0000000000a1', current_date) $$,
  '23503', null, 'a linked appointment must belong to the same patient and dentist');

-- Line items: price is copied from the list, whatever the client sends.
insert into clinical.treatment_line_items (clinic_id, treatment_id, price_list_id, quantity, tooth, unit_price)
values ('11111111-0000-0000-0000-00000000000a', t.id('r1'), t.id('fill'), 2, '36', 1.00),
       ('11111111-0000-0000-0000-00000000000a', t.id('r1'), t.id('xray'), 1, null, 0.00);
select results_eq($$ select unit_price from clinical.treatment_line_items where treatment_id = t.id('r1') order by unit_price $$,
  $$ values (10.00::numeric(10,2)), (80.00) $$, 'unit prices are snapshotted from the price list');
select is((select total from clinical.treatment_totals where treatment_id = t.id('r1')), 170.00::numeric(10,2),
  'total = 2 × 80 + 10');
select throws_ok($$ insert into clinical.treatment_line_items (clinic_id, treatment_id, price_list_id, tooth)
                    values ('11111111-0000-0000-0000-00000000000a', t.id('r1'), t.id('xray'), '99') $$,
  '23514', null, 'tooth must be FDI notation');
reset role;

update clinical.price_list set price_azn = 95 where code = 'filling';
select is((select total from clinical.treatment_totals where treatment_id = t.id('r1')), 170.00::numeric(10,2),
  'a later price change does not alter past treatments');
update clinical.price_list set active = false where code = 'xray';

select t.as_staff('dddddddd-0000-0000-0000-000000000001');
set local role authenticated;
select throws_ok($$ insert into clinical.treatment_line_items (clinic_id, treatment_id, price_list_id)
                    values ('11111111-0000-0000-0000-00000000000a', t.id('r1'), t.id('xray')) $$,
  '23503', null, 'an inactive price cannot be used');

-- Q12: overrides need a reason.
select throws_ok($$ update clinical.treatment_records set total_override = 150 where id = t.id('r1') $$,
  '23514', null, 'a manual total without a reason is rejected');
select lives_ok($$ update clinical.treatment_records set total_override = 150, override_reason = 'Ailə endirimi'
                    where id = t.id('r1') $$, 'a manual total with a reason is accepted');
select results_eq($$ select computed_total, total from clinical.treatment_totals where treatment_id = t.id('r1') $$,
  $$ values (170.00::numeric(10,2), 150.00::numeric(10,2)) $$, 'total uses the override; computed total is kept');
reset role;

select is((select actor from ops.audit_events
            where entity = 'clinical.treatment_records' and entity_id = t.id('r1')
              and after ->> 'total_override' = '150.00'),
  'dddddddd-0000-0000-0000-000000000001', 'the override is in the audit trail with who did it');

-- Visibility per role
select t.as_staff('dddddddd-0000-0000-0000-000000000002');
set local role authenticated;
select is((select count(*)::int from clinical.treatment_records), 0, 'Dr Two cannot see Dr One''s records');
select is((select count(*)::int from clinical.treatment_line_items), 0, '…nor their line items');
select is((select count(*)::int from clinical.treatment_totals), 0, '…nor their totals');
reset role;

select t.as_staff('cccccccc-0000-0000-0000-000000000001');
set local role authenticated;
select is((select count(*)::int from clinical.treatment_records), 1, 'receptionist sees the whole clinic''s log');
select lives_ok($$ insert into clinical.treatment_records (clinic_id, patient_id, professional_id, treated_on)
                   values ('11111111-0000-0000-0000-00000000000a', '11111111-0000-0000-0000-0000000000f2',
                           '11111111-0000-0000-0000-0000000000d2', current_date) $$,
  'receptionist records a treatment for any dentist (paper diary)');
reset role;

select t.as_staff('aaaaaaaa-0000-0000-0000-000000000001');
set local role authenticated;
select is((select count(*)::int from clinical.treatment_records), 2, 'admin sees the whole clinic''s log');
reset role;

select t.as_staff('bbbbbbbb-0000-0000-0000-000000000001');
set local role authenticated;
select is((select count(*)::int from clinical.treatment_records), 0, 'clinic B staff see none of clinic A''s log');
reset role;

select * from finish();
rollback;

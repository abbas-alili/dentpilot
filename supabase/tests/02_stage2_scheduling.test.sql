-- =============================================================================
-- Stage 2 tests — scheduling, holds, booking, approval, reschedule.
-- Fixture day: a Monday 10–16 days ahead. Each dentist works 10:00–13:00.
-- Clinic grid 45 min ⇒ exam (30 min) starts 10:00, 10:45, 11:30, 12:15.
-- Runs in one transaction (now() is frozen) and is rolled back.
-- =============================================================================
begin;
create extension if not exists pgtap;

select plan(42);

-- -----------------------------------------------------------------------------
-- Test helpers (rolled back with everything else)
-- -----------------------------------------------------------------------------
create schema t;
create function t.day() returns date language sql stable as
  $$ select current_setting('t.day')::date $$;
create function t.at(p_time time) returns timestamptz language sql stable as
  $$ select (t.day() + p_time) at time zone 'Asia/Baku' $$;
create function t.id(p_key text) returns uuid language sql stable as
  $$ select nullif(current_setting('t.' || p_key, true), '')::uuid $$;
grant usage on schema t to dentpilot_agent, authenticated;
grant execute on all functions in schema t to dentpilot_agent, authenticated;

select set_config('t.day',
  (select d::date::text from generate_series(current_date + 10, current_date + 16, interval '1 day') d
    where extract(isodow from d) = 1 limit 1), true);

-- -----------------------------------------------------------------------------
-- Fixtures
-- -----------------------------------------------------------------------------
insert into core.clinics (id, name) values
  ('11111111-0000-0000-0000-00000000000a', 'Clinic A'),
  ('22222222-0000-0000-0000-00000000000b', 'Clinic B');

insert into core.professionals (id, clinic_id, display_name) values
  ('11111111-0000-0000-0000-0000000000d1', '11111111-0000-0000-0000-00000000000a', 'Dr One'),
  ('11111111-0000-0000-0000-0000000000d2', '11111111-0000-0000-0000-00000000000a', 'Dr Two'),
  ('22222222-0000-0000-0000-0000000000d9', '22222222-0000-0000-0000-00000000000b', 'Dr B');

insert into core.services (id, clinic_id, code, name_az, name_ru, duration_minutes, buffer_minutes, requires_approval, bookable_by_patient) values
  ('11111111-0000-0000-0000-0000000000e1', '11111111-0000-0000-0000-00000000000a', 'svc_exam',  'Müayinə',   'Осмотр', 30, 0,  false, true),
  ('11111111-0000-0000-0000-0000000000e2', '11111111-0000-0000-0000-00000000000a', 'svc_clean', 'Təmizləmə', 'Чистка', 45, 15, false, true),
  ('11111111-0000-0000-0000-0000000000e3', '11111111-0000-0000-0000-00000000000a', 'svc_fill',  'Plomb',     'Пломба', 60, 15, true,  true),
  ('11111111-0000-0000-0000-0000000000e4', '11111111-0000-0000-0000-00000000000a', 'svc_surg',  'Cərrahiyyə','Хирургия', 90, 30, false, false);

insert into core.schedules (clinic_id, professional_id, weekday, start_time, end_time, valid_from) values
  ('11111111-0000-0000-0000-00000000000a', '11111111-0000-0000-0000-0000000000d1', 1, '10:00', '13:00', current_date),
  ('11111111-0000-0000-0000-00000000000a', '11111111-0000-0000-0000-0000000000d2', 1, '10:00', '13:00', current_date);

insert into core.patients (id, clinic_id, wa_id) values
  ('11111111-0000-0000-0000-0000000000f1', '11111111-0000-0000-0000-00000000000a', '994500000001'),
  ('11111111-0000-0000-0000-0000000000f2', '11111111-0000-0000-0000-00000000000a', '994500000002'),
  ('22222222-0000-0000-0000-0000000000f9', '22222222-0000-0000-0000-00000000000b', '994500000009');

-- Clinic B gets one appointment, to prove the assistant for clinic A can't see it.
insert into core.services (id, clinic_id, code, name_az, name_ru, duration_minutes) values
  ('22222222-0000-0000-0000-0000000000e9', '22222222-0000-0000-0000-00000000000b', 'svc_exam', 'x', 'x', 30);
insert into core.appointments (clinic_id, patient_id, professional_id, service_id, start_at, end_at, blocked_until) values
  ('22222222-0000-0000-0000-00000000000b', '22222222-0000-0000-0000-0000000000f9', '22222222-0000-0000-0000-0000000000d9',
   '22222222-0000-0000-0000-0000000000e9', t.at('10:00'), t.at('10:30'), t.at('10:30'));

insert into auth.users (id) values
  ('aaaaaaaa-0000-0000-0000-000000000001'),   -- receptionist at A
  ('aaaaaaaa-0000-0000-0000-000000000002');   -- admin at A
insert into ops.staff (user_id, clinic_id, role) values
  ('aaaaaaaa-0000-0000-0000-000000000001', '11111111-0000-0000-0000-00000000000a', 'receptionist'),
  ('aaaaaaaa-0000-0000-0000-000000000002', '11111111-0000-0000-0000-00000000000a', 'admin');

-- =============================================================================
-- Availability (as the assistant)
-- =============================================================================
set local role dentpilot_agent;
select set_config('app.clinic_id', '11111111-0000-0000-0000-00000000000a', true);
select set_config('app.actor', 'assistant', true);

select is((select count(*)::int from core.available_slots(null, t.day())), 0,
  'unknown service ⇒ no slots');

select is((select count(*)::int from core.available_slots('11111111-0000-0000-0000-0000000000e1', t.day())), 8,
  '45-min grid: exam has 4 starts per dentist (8 total)');

select results_eq(
  $$ select distinct (start_at at time zone 'Asia/Baku')::time
       from core.available_slots('11111111-0000-0000-0000-0000000000e1', t.day()) order by 1 $$,
  $$ values ('10:00'::time), ('10:45'), ('11:30'), ('12:15') $$,
  'start times follow the 45-min grid from the window start');

select is((select count(*)::int from core.available_slots('11111111-0000-0000-0000-0000000000e2', t.day())), 6,
  'cleaning (45 + 15 buffer) must fit the window: 3 starts per dentist');

select is((select count(*)::int from core.available_slots('11111111-0000-0000-0000-0000000000e1', t.day(),
                                                          '11111111-0000-0000-0000-0000000000d1')), 4,
  'filter by dentist');

select is((select count(*)::int from core.available_slots('11111111-0000-0000-0000-0000000000e1', t.day() + 1)), 0,
  'no schedule on Tuesday ⇒ no slots');

reset role;
update core.clinics set slot_step_minutes = 30 where id = '11111111-0000-0000-0000-00000000000a';
set local role dentpilot_agent;
select is((select count(*)::int from core.available_slots('11111111-0000-0000-0000-0000000000e1', t.day())), 12,
  'grid is a setting: 30-min grid gives 6 starts per dentist');
reset role;
update core.clinics set slot_step_minutes = 45 where id = '11111111-0000-0000-0000-00000000000a';

insert into core.blocks (clinic_id, professional_id, start_at, end_at)
values ('11111111-0000-0000-0000-00000000000a', '11111111-0000-0000-0000-0000000000d1', t.at('10:30'), t.at('11:00'));
set local role dentpilot_agent;
select is((select count(*)::int from core.available_slots('11111111-0000-0000-0000-0000000000e1', t.day(),
                                                          '11111111-0000-0000-0000-0000000000d1')), 3,
  'a dentist block removes only overlapping starts');
reset role;
delete from core.blocks;

insert into core.blocks (clinic_id, professional_id, start_at, end_at)
values ('11111111-0000-0000-0000-00000000000a', null, t.at('00:00'), t.at('23:59'));
set local role dentpilot_agent;
select is((select count(*)::int from core.available_slots('11111111-0000-0000-0000-0000000000e1', t.day())), 0,
  'a clinic-wide block closes the day for everyone');
reset role;
delete from core.blocks;

update core.schedules set valid_to = t.day() - 1 where professional_id = '11111111-0000-0000-0000-0000000000d2';
set local role dentpilot_agent;
select is((select count(*)::int from core.available_slots('11111111-0000-0000-0000-0000000000e1', t.day())), 4,
  'a schedule that ended before the day is ignored');
reset role;
update core.schedules set valid_to = null;

update core.clinics set booking_horizon_days = 1 where id = '11111111-0000-0000-0000-00000000000a';
set local role dentpilot_agent;
select is((select count(*)::int from core.available_slots('11111111-0000-0000-0000-0000000000e1', t.day())), 0,
  'days beyond the booking horizon have no slots');
reset role;
update core.clinics set booking_horizon_days = 60 where id = '11111111-0000-0000-0000-00000000000a';

select throws_ok(
  $$ insert into core.schedules (clinic_id, professional_id, weekday, start_time, end_time)
     values ('11111111-0000-0000-0000-00000000000a', '11111111-0000-0000-0000-0000000000d1', 1, '12:00', '14:00') $$,
  '23P01', null, 'overlapping working hours for one dentist are rejected');

set local role dentpilot_agent;
select is(
  (select local_date from core.available_dates('11111111-0000-0000-0000-0000000000e1', null, t.day()) limit 1),
  t.day(), 'available_dates lists the first day that has free slots');

-- =============================================================================
-- Holds
-- =============================================================================
select set_config('t.h1', core.hold_slot('11111111-0000-0000-0000-0000000000f1', '11111111-0000-0000-0000-0000000000e1',
                                         t.at('10:00'), '11111111-0000-0000-0000-0000000000d1')::text, true);
select isnt(t.id('h1'), null, 'patient 1 holds Dr One at 10:00');

select is(core.hold_slot('11111111-0000-0000-0000-0000000000f2', '11111111-0000-0000-0000-0000000000e1',
                         t.at('10:00'), '11111111-0000-0000-0000-0000000000d1'), null,
  'patient 2 cannot hold the same dentist and time');

select set_config('t.h2', core.hold_slot('11111111-0000-0000-0000-0000000000f2', '11111111-0000-0000-0000-0000000000e1',
                                         t.at('10:00'))::text, true);
select is((select professional_id from core.slot_holds where id = t.id('h2')),
  '11111111-0000-0000-0000-0000000000d2'::uuid, '"any dentist" falls through to the free dentist');

select is((select count(*)::int from core.available_slots('11111111-0000-0000-0000-0000000000e1', t.day())), 6,
  'held slots are hidden from other patients');

select is(core.hold_slot('11111111-0000-0000-0000-0000000000f1', '11111111-0000-0000-0000-0000000000e1',
                         t.at('11:13'), '11111111-0000-0000-0000-0000000000d1'), null,
  'a time off the grid cannot be held');

select throws_ok(
  $$ select core.hold_slot('11111111-0000-0000-0000-0000000000f1', '11111111-0000-0000-0000-0000000000e4', t.at('10:00')) $$,
  '42501', null, 'staff-only services cannot be held by the assistant');

select set_config('t.h3', core.hold_slot('11111111-0000-0000-0000-0000000000f1', '11111111-0000-0000-0000-0000000000e1',
                                         t.at('12:15'), '11111111-0000-0000-0000-0000000000d1')::text, true);
select is((select count(*)::int from core.slot_holds where patient_id = '11111111-0000-0000-0000-0000000000f1'), 1,
  'a new hold replaces the patient''s previous hold');

reset role;
update core.slot_holds set expires_at = now() - interval '1 second' where id = t.id('h2');
set local role dentpilot_agent;
select ok(exists (select 1 from core.available_slots('11111111-0000-0000-0000-0000000000e1', t.day(),
                                                     '11111111-0000-0000-0000-0000000000d2')
                   where start_at = t.at('10:00')),
  'an expired hold no longer blocks the slot');

-- =============================================================================
-- Confirm
-- =============================================================================
select is((select count(*)::int from core.confirm_hold(t.id('h3'), '11111111-0000-0000-0000-0000000000f2')), 0,
  'another patient cannot confirm this hold');

select set_config('t.a1', (select appointment_id from core.confirm_hold(t.id('h3'), '11111111-0000-0000-0000-0000000000f1', ' Leyla '))::text, true);
select is((select status from core.appointments where id = t.id('a1')), 'booked',
  'service without approval ⇒ booked immediately');
select is((select booked_by from core.appointments where id = t.id('a1')), 'assistant',
  'booked_by records the assistant');
select is((select appointment_id from core.confirm_hold(t.id('h3'), '11111111-0000-0000-0000-0000000000f1')), t.id('a1'),
  'confirming the same hold again returns the same appointment');
select is((select display_name from core.patients where id = '11111111-0000-0000-0000-0000000000f1'), 'Leyla',
  'patient name is saved, trimmed');

select set_config('t.h4', core.hold_slot('11111111-0000-0000-0000-0000000000f2', '11111111-0000-0000-0000-0000000000e3',
                                         t.at('11:30'), '11111111-0000-0000-0000-0000000000d2')::text, true);
select set_config('t.a2', (select appointment_id from core.confirm_hold(t.id('h4'), '11111111-0000-0000-0000-0000000000f2'))::text, true);
select is((select status from core.appointments where id = t.id('a2')), 'pending_approval',
  'service that requires approval ⇒ pending_approval');
select ok(not exists (select 1 from core.available_slots('11111111-0000-0000-0000-0000000000e1', t.day(),
                                                         '11111111-0000-0000-0000-0000000000d2')
                       where start_at = t.at('11:30')),
  'a pending appointment still blocks its slot');

select throws_ok(
  $$ select core.approve_appointment(t.id('a2'), 1) $$,
  '42501', null, 'the assistant cannot approve appointments');

select is((select count(*)::int from core.appointments), 2,
  'the assistant sees only its own clinic''s appointments');

reset role;
select throws_ok(
  $$ insert into core.appointments (clinic_id, patient_id, professional_id, service_id, start_at, end_at, blocked_until)
     values ('11111111-0000-0000-0000-00000000000a', '11111111-0000-0000-0000-0000000000f2',
             '11111111-0000-0000-0000-0000000000d1', '11111111-0000-0000-0000-0000000000e1',
             t.at('12:30'), t.at('13:00'), t.at('13:00')) $$,
  '23P01', null, 'database rejects an overlapping appointment even when written directly');

-- =============================================================================
-- Cancel, reschedule, status rules
-- =============================================================================
set local role dentpilot_agent;
select is(core.cancel_appointment(t.id('a1'), '11111111-0000-0000-0000-0000000000f2', 1), false,
  'cannot cancel another patient''s appointment');
select is(core.cancel_appointment(t.id('a1'), '11111111-0000-0000-0000-0000000000f1', 99), false,
  'cancel with a stale version is refused');

select set_config('t.h5', core.hold_slot('11111111-0000-0000-0000-0000000000f1', '11111111-0000-0000-0000-0000000000e2',
                                         t.at('11:30'), '11111111-0000-0000-0000-0000000000d1', t.id('a1'))::text, true);
select isnt(t.id('h5'), null, 'reschedule hold may overlap the appointment it replaces');
select set_config('t.a3', (select appointment_id from core.confirm_hold(t.id('h5'), '11111111-0000-0000-0000-0000000000f1'))::text, true);
select results_eq(
  $$ select status, rescheduled_from from core.appointments where id in (t.id('a1'), t.id('a3')) order by status $$,
  $$ values ('booked', t.id('a1')), ('cancelled', null::uuid) $$,
  'reschedule cancels the old appointment and links the new one');

select set_config('t.h6', core.hold_slot('11111111-0000-0000-0000-0000000000f1', '11111111-0000-0000-0000-0000000000e1',
                                         t.at('10:45'), '11111111-0000-0000-0000-0000000000d1', t.id('a3'))::text, true);
reset role;
update core.appointments set status = 'confirmed' where id = t.id('a3');   -- staff touches it meanwhile
set local role dentpilot_agent;
select throws_ok(
  $$ select * from core.confirm_hold(t.id('h6'), '11111111-0000-0000-0000-0000000000f1') $$,
  '40001', null, 'reschedule fails if the old appointment changed since the hold');

select is((select version from core.appointments where id = t.id('a3')), 2,
  'every update bumps the version');

select throws_ok(
  $$ update core.appointments set status = 'booked' where id = t.id('a1') $$,
  '23514', null, 'a cancelled appointment cannot be re-activated');

-- =============================================================================
-- Staff (web app)
-- =============================================================================
reset role;
select set_config('app.clinic_id', '', true);
select set_config('app.actor', '', true);
select set_config('request.jwt.claim.sub', 'aaaaaaaa-0000-0000-0000-000000000001', true);
set local role authenticated;

select ok((select count(*) from core.available_slots('11111111-0000-0000-0000-0000000000e1', t.day())) > 0,
  'single-clinic staff can query slots without setting app.clinic_id');
select is(core.approve_appointment(t.id('a2'), 1), true, 'staff can approve a pending appointment');

update core.clinics set slot_step_minutes = 15;
reset role;
select is((select slot_step_minutes from core.clinics where id = '11111111-0000-0000-0000-00000000000a'), 45,
  'a receptionist cannot change booking settings');

select set_config('request.jwt.claim.sub', 'aaaaaaaa-0000-0000-0000-000000000002', true);
set local role authenticated;
update core.clinics set slot_step_minutes = 15;
reset role;
select is((select slot_step_minutes from core.clinics where id = '11111111-0000-0000-0000-00000000000a'), 15,
  'a clinic admin can change the booking grid');

select * from finish();
rollback;

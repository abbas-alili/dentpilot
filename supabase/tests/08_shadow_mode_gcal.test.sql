-- =============================================================================
-- Tests for the 2026-11-02 changes: shadow mode drafts, clinic-wide approval,
-- approve with duration, Google Calendar sync bookkeeping.
-- =============================================================================
begin;
create extension if not exists pgtap;

select plan(27);

create schema t;
create function t.id(p_key text) returns uuid language sql stable as
  $$ select nullif(current_setting('t.' || p_key, true), '')::uuid $$;
grant usage on schema t to dentpilot_agent, authenticated;
grant execute on all functions in schema t to dentpilot_agent, authenticated;

-- Clinic created with defaults: shadow mode must be ON without asking.
insert into core.clinics (id, name) values ('11111111-0000-0000-0000-00000000000a', 'Clinic A');
insert into core.professionals (id, clinic_id, display_name) values
  ('11111111-0000-0000-0000-0000000000d1', '11111111-0000-0000-0000-00000000000a', 'Dr Ayten');
insert into core.services (id, clinic_id, code, name_az, name_ru, duration_minutes, buffer_minutes) values
  ('11111111-0000-0000-0000-0000000000e1', '11111111-0000-0000-0000-00000000000a', 'svc_fill', 'Plomb', 'Пломба', 45, 10);
insert into core.patients (id, clinic_id, wa_id, display_name) values
  ('11111111-0000-0000-0000-0000000000f1', '11111111-0000-0000-0000-00000000000a', '994500000001', 'Leyla M');
insert into auth.users (id) values ('aaaaaaaa-0000-0000-0000-000000000001');
insert into ops.staff (user_id, clinic_id, role, professional_id) values
  ('aaaaaaaa-0000-0000-0000-000000000001', '11111111-0000-0000-0000-00000000000a', 'dentist', '11111111-0000-0000-0000-0000000000d1');

-- =============================================================================
-- Shadow mode
-- =============================================================================
select ok((select shadow_mode from core.clinics where id = '11111111-0000-0000-0000-00000000000a'),
  'new clinics start in shadow mode');

set local role dentpilot_agent;
select set_config('app.clinic_id', '11111111-0000-0000-0000-00000000000a', true);
select set_config('t.d1', (select message_id::text from core.queue_outbound_message(
  '11111111-0000-0000-0000-0000000000f1', 'assistant', 'text', 'Salam!', null, 'k1',
  '{"type":"text","text":{"body":"Salam!"}}')), true);
select is((select delivery_status from core.messages where id = t.id('d1')), 'draft',
  'in shadow mode the assistant''s message becomes a draft');
select is((select delivery_status from core.queue_outbound_message(
  '11111111-0000-0000-0000-0000000000f1', 'system', 'template', null, 'dentpilot_reminder', 'k2',
  '{"type":"template","template":{"name":"dentpilot_reminder"}}')), 'draft',
  'reminders (system) are drafts too');
reset role;

select is((select count(*)::int from ops.staff_notifications where kind = 'draft_waiting'), 1,
  'staff are told a draft is waiting (once per conversation per minute)');
select is((select count(*)::int from ops.background_jobs where kind = 'send_message'), 0,
  'nothing is queued for sending while it is a draft');

select set_config('request.jwt.claim.sub', 'aaaaaaaa-0000-0000-0000-000000000001', true);
set local role authenticated;
select ok(core.approve_draft(t.id('d1'), 'Salam, Leyla xanım!'), 'the doctor approves the draft with edited text');
reset role;
select results_eq(
  $$ select delivery_status, body, edited, outbound_payload #>> '{text,body}' from core.messages where id = t.id('d1') $$,
  $$ values ('pending'::text, 'Salam, Leyla xanım!'::text, true, 'Salam, Leyla xanım!'::text) $$,
  'approved: text and payload updated, marked as edited');
select is((select count(*)::int from ops.background_jobs where kind = 'send_message' and payload ->> 'message_id' = t.id('d1')::text), 1,
  'approval queues exactly one send job');

set local role authenticated;
select ok(not core.approve_draft(t.id('d1')), 'a draft can be approved only once');
select set_config('t.d2', (select id::text from core.messages where send_key = 'k2'), true);
select throws_ok($$ select core.approve_draft(t.id('d2'), 'changed') $$, '23514', null,
  'template wording cannot be edited');
select ok(core.discard_draft(t.id('d2')), 'the doctor discards a draft');
select is((select delivery_status from core.messages where id = t.id('d2')), 'discarded', '…and it is never sent');

select is((select delivery_status from core.queue_outbound_message(
  '11111111-0000-0000-0000-0000000000f1', 'staff', 'text', 'Sabah gəlin', null, null,
  '{"type":"text","text":{"body":"Sabah gəlin"}}')), 'pending', 'the doctor''s own reply is sent directly');
reset role;
select is((select count(*)::int from ops.background_jobs where kind = 'send_message'), 2,
  'the staff reply is queued for sending');

select set_config('request.jwt.claim.sub', '', true);
insert into auth.users (id) values ('bbbbbbbb-0000-0000-0000-000000000009');
select set_config('request.jwt.claim.sub', 'bbbbbbbb-0000-0000-0000-000000000009', true);
set local role authenticated;
select ok(not core.discard_draft(t.id('d1')), 'staff of another clinic cannot touch drafts');
reset role;

-- =============================================================================
-- Clinic-wide approval and approve-with-duration
-- =============================================================================
update core.clinics set all_bookings_need_approval = true where id = '11111111-0000-0000-0000-00000000000a';
insert into core.slot_holds (id, clinic_id, patient_id, professional_id, service_id, start_at, end_at, blocked_until, expires_at)
values ('11111111-0000-0000-0000-0000000000b1', '11111111-0000-0000-0000-00000000000a', '11111111-0000-0000-0000-0000000000f1',
        '11111111-0000-0000-0000-0000000000d1', '11111111-0000-0000-0000-0000000000e1',
        date_trunc('day', now()) + interval '3 days 10 hours', date_trunc('day', now()) + interval '3 days 10 hours 45 minutes',
        date_trunc('day', now()) + interval '3 days 10 hours 55 minutes', now() + interval '10 minutes');

set local role dentpilot_agent;
select set_config('t.a1', (select appointment_id::text from core.confirm_hold('11111111-0000-0000-0000-0000000000b1',
                                                                               '11111111-0000-0000-0000-0000000000f1')), true);
select is((select status from core.appointments where id = t.id('a1')), 'pending_approval',
  'all_bookings_need_approval: a service without its own flag still needs approval');
reset role;

select set_config('request.jwt.claim.sub', 'aaaaaaaa-0000-0000-0000-000000000001', true);
set local role authenticated;
select throws_ok($$ select core.approve_appointment(t.id('a1'), 1, 600) $$, '23514', null, 'duration over 8 h is rejected');
select ok(core.approve_appointment(t.id('a1'), 1, 90), 'the doctor approves with the real duration (90 min)');
reset role;
select results_eq(
  $$ select status, end_at - start_at, blocked_until - start_at from core.appointments where id = t.id('a1') $$,
  $$ values ('booked'::text, interval '90 minutes', interval '100 minutes') $$,
  'end and blocked-until follow the approved duration (+ service buffer)');

-- =============================================================================
-- Google Calendar bookkeeping
-- =============================================================================
select is((select count(*)::int from ops.background_jobs where kind = 'gcal_sync'), 0,
  'no Google link yet: no sync jobs');

set local role dentpilot_agent;
select ops.save_google_link('11111111-0000-0000-0000-0000000000d1', 'ayten@gmail.example', 'refresh-1', null);
select results_eq($$ select calendar_id, refresh_token, status from ops.google_link_for('11111111-0000-0000-0000-0000000000d1') $$,
  $$ values ('primary'::text, 'refresh-1'::text, 'active'::text) $$, 'link stored; token kept in Vault, primary calendar');
reset role;

update core.appointments set start_at = start_at + interval '1 hour', end_at = end_at + interval '1 hour',
                             blocked_until = blocked_until + interval '1 hour' where id = t.id('a1');
select is((select count(*)::int from ops.background_jobs where kind = 'gcal_sync'), 1,
  'a change to a linked dentist''s appointment queues a sync');

set local role dentpilot_agent;
select ops.mark_google_link_broken('11111111-0000-0000-0000-0000000000d1', 'invalid_grant');
reset role;
select is((select count(*)::int from ops.staff_notifications where kind = 'calendar_disconnected'), 1,
  'a revoked Google link is reported to staff');

select set_config('request.jwt.claim.sub', 'aaaaaaaa-0000-0000-0000-000000000001', true);
set local role authenticated;
select throws_ok($$ select refresh_secret_id from ops.google_calendar_links $$, '42501', null,
  'staff cannot see the Vault secret id');
reset role;

set local role dentpilot_agent;
select ok(ops.can_connect_calendar('aaaaaaaa-0000-0000-0000-000000000001', '11111111-0000-0000-0000-0000000000d1'),
  'a dentist may connect their own Google Calendar');
select ok(not ops.can_connect_calendar('bbbbbbbb-0000-0000-0000-000000000009', '11111111-0000-0000-0000-0000000000d1'),
  'someone from another clinic may not');
reset role;
insert into core.professionals (id, clinic_id, display_name) values
  ('11111111-0000-0000-0000-0000000000d2', '11111111-0000-0000-0000-00000000000a', 'Dr Two');
set local role dentpilot_agent;
select ok(not ops.can_connect_calendar('aaaaaaaa-0000-0000-0000-000000000001', '11111111-0000-0000-0000-0000000000d2'),
  'a dentist may not connect a colleague''s calendar');
reset role;

select * from finish();
rollback;

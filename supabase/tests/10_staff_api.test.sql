-- =============================================================================
-- Staff web app API (Step 1) — every screen function, as real staff roles.
-- =============================================================================
begin;
create extension if not exists pgtap;

select plan(27);

create schema t;
create function t.id(p_key text) returns uuid language sql stable as
  $$ select nullif(current_setting('t.' || p_key, true), '')::uuid $$;
create function t.day() returns date language sql stable as
  $$ select current_date + 3 $$;
create function t.at(p_time time) returns timestamptz language sql stable as
  $$ select (t.day() + p_time) at time zone 'Asia/Baku' $$;
grant usage on schema t to dentpilot_agent, authenticated;
grant execute on all functions in schema t to dentpilot_agent, authenticated;

-- Clinic A (shadow mode on by default) and clinic B
insert into core.clinics (id, name) values
  ('11111111-0000-0000-0000-00000000000a', 'Avenue Dent'),
  ('22222222-0000-0000-0000-00000000000b', 'Other Clinic');
insert into core.professionals (id, clinic_id, display_name) values
  ('11111111-0000-0000-0000-0000000000d1', '11111111-0000-0000-0000-00000000000a', 'Dr. Ayten'),
  ('11111111-0000-0000-0000-0000000000d2', '11111111-0000-0000-0000-00000000000a', 'Dr. Two');
insert into core.services (id, clinic_id, code, name_az, name_ru, duration_minutes, buffer_minutes) values
  ('11111111-0000-0000-0000-0000000000e1', '11111111-0000-0000-0000-00000000000a', 'svc_fill', 'Plomb', 'Пломба', 45, 10);
insert into core.patients (id, clinic_id, wa_id, display_name) values
  ('11111111-0000-0000-0000-0000000000f2', '11111111-0000-0000-0000-00000000000a', '994500000002', 'Orxan');
insert into auth.users (id) values
  ('dddddddd-0000-0000-0000-000000000001'),   -- Dr. Ayten (dentist)
  ('cccccccc-0000-0000-0000-000000000001'),   -- receptionist, clinic A
  ('bbbbbbbb-0000-0000-0000-000000000001');   -- receptionist, clinic B
insert into ops.staff (user_id, clinic_id, role, professional_id) values
  ('dddddddd-0000-0000-0000-000000000001', '11111111-0000-0000-0000-00000000000a', 'dentist', '11111111-0000-0000-0000-0000000000d1'),
  ('cccccccc-0000-0000-0000-000000000001', '11111111-0000-0000-0000-00000000000a', 'receptionist', null),
  ('bbbbbbbb-0000-0000-0000-000000000001', '22222222-0000-0000-0000-00000000000b', 'receptionist', null);

-- A patient writes; the bot drafts a reply (shadow mode).
set local role dentpilot_agent;
select set_config('app.clinic_id', '11111111-0000-0000-0000-00000000000a', true);
select set_config('t.c1', (select conversation_id::text from core.record_inbound_message(
  'wamid.1', '994500000001', 'text', 'Sabah yer var?', p_profile_name => 'Leyla Məmmədova')), true);
select set_config('t.p1', (select patient_id::text from core.messages where wa_message_id = 'wamid.1'), true);
select set_config('t.d1', (select message_id::text from core.queue_outbound_message(
  t.id('p1'), 'assistant', 'text', 'Bəli, saat 10:00 boşdur.', null, 'k1',
  '{"type":"text","text":{"body":"Bəli, saat 10:00 boşdur."}}')), true);
select set_config('app.clinic_id', '', true);
reset role;

-- A pending request at 10:00 for Dr. Ayten; her next booking is at 11:30.
insert into core.appointments (id, clinic_id, patient_id, professional_id, service_id, start_at, end_at, blocked_until, status) values
  ('11111111-0000-0000-0000-0000000000a1', '11111111-0000-0000-0000-00000000000a', t.id('p1'), '11111111-0000-0000-0000-0000000000d1',
   '11111111-0000-0000-0000-0000000000e1', t.at('10:00'), t.at('10:45'), t.at('10:55'), 'pending_approval'),
  ('11111111-0000-0000-0000-0000000000a2', '11111111-0000-0000-0000-00000000000a', '11111111-0000-0000-0000-0000000000f2', '11111111-0000-0000-0000-0000000000d1',
   '11111111-0000-0000-0000-0000000000e1', t.at('11:30'), t.at('12:15'), t.at('12:25'), 'booked');

-- =============================================================================
-- As Dr. Ayten
-- =============================================================================
select set_config('request.jwt.claim.sub', 'dddddddd-0000-0000-0000-000000000001', true);
set local role authenticated;

select results_eq($$ select clinic_name, role, professional_name, shadow_mode from ops.my_staff_profile() $$,
  $$ values ('Avenue Dent'::text, 'dentist'::text, 'Dr. Ayten'::text, true) $$, 'profile: clinic, role, own dentist, shadow mode');

select results_eq($$ select drafts, pending_bookings, attention from core.staff_counts() $$,
  $$ values (1, 1, 0) $$, 'badges: one draft, one pending booking, nothing urgent');

select results_eq($$ select body, replying_to, editable, window_open, patient_name from core.staff_draft_inbox() $$,
  $$ values ('Bəli, saat 10:00 boşdur.'::text, 'Sabah yer var?'::text, true, true, 'Leyla Məmmədova'::text) $$,
  'inbox: the draft, the message it answers, editable, inside the 24-h window');

select results_eq($$ select local_start, held_minutes, max_duration_minutes, professional_name from core.staff_pending_bookings() $$,
  $$ values (to_char(t.day(), 'YYYY-MM-DD') || 'T10:00', 45, 80, 'Dr. Ayten'::text) $$,
  'pending: held 45 min; at most 80 min before the 11:30 booking (90 − 10 buffer)');

select results_eq($$ select patient_name, last_preview, drafts from core.staff_conversations('open') $$,
  $$ values ('Leyla Məmmədova'::text, 'Bəli, saat 10:00 boşdur.'::text, 1) $$,
  'conversation list: preview of the latest message and the draft count');
select is((select count(*)::int from core.staff_conversations('attention')), 0, 'nothing needs attention yet');

select results_eq($$ select patient_name, status, window_open from core.staff_conversation_info(t.id('c1')) $$,
  $$ values ('Leyla Məmmədova'::text, 'assistant'::text, true) $$, 'thread header: patient, status, window open');
select results_eq($$ select direction, delivery_status from core.staff_conversation_messages(t.id('c1')) $$,
  $$ values ('in'::text, null::text), ('out', 'draft') $$, 'thread: oldest first, with delivery status');

select set_config('t.r1', core.staff_send_reply(t.id('c1'), '  Salam Leyla xanım, sabah 10:00 uyğundur?  ')::text, true);
select results_eq($$ select source, delivery_status, body from core.messages where id = t.id('r1') $$,
  $$ values ('staff'::text, 'pending'::text, 'Salam Leyla xanım, sabah 10:00 uyğundur?'::text) $$,
  'staff reply: trimmed, sent directly (never a draft)');
select is((select status from core.conversations where id = t.id('c1')), 'handed_to_staff',
  'replying hands the conversation to staff');
select is((select count(*)::int from core.staff_conversations('attention')), 1, 'it now shows under attention');
select throws_ok($$ select core.staff_send_reply(t.id('c1'), '   ') $$, '23514', null, 'empty reply is rejected');
reset role;

select is((select count(*)::int from ops.background_jobs where kind = 'send_message' and payload ->> 'message_id' = t.id('r1')::text), 1,
  'the reply is queued for sending');

update core.patients set last_inbound_at = now() - interval '25 hours' where id = t.id('p1');
select set_config('request.jwt.claim.sub', 'dddddddd-0000-0000-0000-000000000001', true);
select set_config('app.clinic_id', '', true);
set local role authenticated;
select throws_ok($$ select core.staff_send_reply(t.id('c1'), 'Salam') $$, 'DP002', null,
  'outside the 24-h window free text is refused (templates only)');
select ok(not (select window_open from core.staff_draft_inbox() limit 1), 'the inbox shows the window is closed');

select results_eq($$ select local_start, patient_name, status from core.staff_day_schedule(t.day()) $$,
  $$ values ('10:00'::text, 'Leyla Məmmədova'::text, 'pending_approval'::text), ('11:30', 'Orxan', 'booked') $$,
  'today: the day''s bookings in clinic time, pending ones included');
select is((select count(*)::int from core.staff_day_schedule(t.day(), '11111111-0000-0000-0000-0000000000d2')), 0,
  'today: filter by dentist');

select ok(core.staff_set_appointment_status('11111111-0000-0000-0000-0000000000a2', 1, 'checked_in'), 'mark a patient arrived');
select ok(not core.staff_set_appointment_status('11111111-0000-0000-0000-0000000000a2', 1, 'completed'), 'stale version is refused');
select ok(core.staff_set_appointment_status('11111111-0000-0000-0000-0000000000a2', 2, 'completed'), 'then done');
select throws_ok($$ select core.staff_set_appointment_status('11111111-0000-0000-0000-0000000000a2', 3, 'booked') $$,
  '23514', null, 'staff cannot set arbitrary statuses');
select throws_ok($$ select core.staff_set_appointment_status('11111111-0000-0000-0000-0000000000a1', 1, 'checked_in') $$,
  '23514', null, 'the status rules still apply (pending cannot jump to arrived)');
reset role;

-- =============================================================================
-- As staff of another clinic
-- =============================================================================
select set_config('request.jwt.claim.sub', 'bbbbbbbb-0000-0000-0000-000000000001', true);
select set_config('app.clinic_id', '', true);
set local role authenticated;
select results_eq($$ select drafts, pending_bookings, attention from core.staff_counts() $$,
  $$ values (0, 0, 0) $$, 'other clinic: badges show nothing of clinic A');
select is((select count(*)::int from core.staff_draft_inbox()), 0, 'other clinic: no drafts of clinic A');
select is((select count(*)::int from core.staff_day_schedule(t.day())), 0, 'other clinic: no schedule of clinic A');
select throws_ok($$ select core.staff_send_reply(t.id('c1'), 'hi') $$, 'P0002', null,
  'other clinic: cannot reply in clinic A''s conversation');
reset role;

select ok(not has_function_privilege('anon', 'core.staff_draft_inbox()', 'execute'), 'not reachable without signing in');

select * from finish();
rollback;

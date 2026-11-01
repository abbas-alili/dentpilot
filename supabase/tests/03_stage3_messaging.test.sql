-- =============================================================================
-- Stage 3 tests — webhook ingest, dedup, echoes, outbound queue, delivery
-- status, conversation control, Flow tokens, change cutoff, retention.
-- Runs in one transaction (now() is frozen) and is rolled back.
-- =============================================================================
begin;
create extension if not exists pgtap;

select plan(47);

-- -----------------------------------------------------------------------------
-- Helpers and fixtures
-- -----------------------------------------------------------------------------
create schema t;
create function t.id(p_key text) returns uuid language sql stable as
  $$ select nullif(current_setting('t.' || p_key, true), '')::uuid $$;
create function t.txt(p_key text) returns text language sql stable as
  $$ select nullif(current_setting('t.' || p_key, true), '') $$;
grant usage on schema t to dentpilot_agent, authenticated, service_role;
grant execute on all functions in schema t to dentpilot_agent, authenticated, service_role;

-- Live sending (shadow mode off): this file tests the send path itself.
insert into core.clinics (id, name, wa_phone_number_id, shadow_mode) values
  ('11111111-0000-0000-0000-00000000000a', 'Clinic A', 'PN_A', false),
  ('22222222-0000-0000-0000-00000000000b', 'Clinic B', 'PN_B', false);
insert into core.professionals (id, clinic_id, display_name) values
  ('11111111-0000-0000-0000-0000000000d1', '11111111-0000-0000-0000-00000000000a', 'Dr One');
insert into core.services (id, clinic_id, code, name_az, name_ru, duration_minutes) values
  ('11111111-0000-0000-0000-0000000000e1', '11111111-0000-0000-0000-00000000000a', 'svc_exam', 'Müayinə', 'Осмотр', 30);
insert into auth.users (id) values ('aaaaaaaa-0000-0000-0000-000000000001');
insert into ops.staff (user_id, clinic_id, role) values
  ('aaaaaaaa-0000-0000-0000-000000000001', '11111111-0000-0000-0000-00000000000a', 'receptionist');

-- =============================================================================
-- Webhook ingest (as the assistant role)
-- =============================================================================
set local role dentpilot_agent;

select is(core.clinic_for_phone_number('PN_A'), '11111111-0000-0000-0000-00000000000a'::uuid,
  'webhook phone_number_id resolves to its clinic (no clinic context needed)');
select is(core.clinic_for_phone_number('PN_UNKNOWN'), null, 'unknown phone_number_id resolves to null');

select set_config('app.clinic_id', '11111111-0000-0000-0000-00000000000a', true);
select set_config('app.actor', 'assistant', true);

select set_config('t.m1', (select message_id from core.record_inbound_message(
  'wamid.1', '994501112233', 'text', 'Salam, sabah yer var?', p_profile_name => 'Leyla'))::text, true);
select set_config('t.p1', (select patient_id::text from core.messages where id = t.id('m1')), true);
select set_config('t.c1', (select conversation_id::text from core.messages where id = t.id('m1')), true);

select isnt(t.id('m1'), null, 'first inbound message is recorded');
select is((select display_name from core.patients where id = t.id('p1')), 'Leyla',
  'a new patient is created with the WhatsApp profile name');
select ok(core.service_window_open(t.id('p1')), '24h service window is open after an inbound message');

select results_eq(
  $$ select message_id, is_duplicate from core.record_inbound_message('wamid.1', '994501112233', 'text', 'Salam, sabah yer var?') $$,
  $$ values (t.id('m1'), true) $$,
  'a redelivered webhook returns the same message flagged as duplicate');

select is((select conversation_id from core.record_inbound_message('wamid.2', '994501112233', 'text', 'Saat 5?')),
  t.id('c1'), 'the next message joins the open conversation');
select is((select count(*)::int from core.patients where wa_id = '994501112233'), 1, 'no duplicate patient');
select is((select count(*)::int from core.messages where patient_id = t.id('p1')), 2, 'two messages stored once each');

-- =============================================================================
-- Should the assistant reply?
-- =============================================================================
select ok(core.assistant_may_reply(t.id('c1')), 'assistant may reply in a fresh conversation');

-- A dentist reply hands the conversation to staff (Stage 6 behaviour; tested
-- on a second patient so the rest of this file keeps using c1).
select set_config('t.e1', core.record_echo_message('wamid.echo1', '994507770000', 'text', 'Bəli, saat 5-ə yazıram')::text, true);
select isnt(t.id('e1'), null, 'dentist''s Business App reply is recorded as an echo');
select set_config('t.c2', (select conversation_id::text from core.messages where id = t.id('e1')), true);
select ok(not core.assistant_may_reply(t.id('c2')), 'assistant stays silent after a dentist reply');
select is((select status from core.conversations where id = t.id('c2')), 'handed_to_staff',
  'a dentist reply hands the conversation to staff');

-- =============================================================================
-- Outbound queue and delivery status
-- =============================================================================
select set_config('t.o1', (select message_id from core.queue_outbound_message(
  t.id('p1'), 'assistant', 'text', 'Sabah saat 17:00 boşdur.', p_send_key => 'reply:wamid.2'))::text, true);
select is((select delivery_status from core.messages where id = t.id('o1')), 'pending', 'outbound is written before sending');
select is((select message_id from core.queue_outbound_message(
  t.id('p1'), 'assistant', 'text', 'Sabah saat 17:00 boşdur.', p_send_key => 'reply:wamid.2')),
  t.id('o1'), 'same send_key returns the same row (no double send)');

select ok(core.mark_outbound_sent(t.id('o1'), 'wamid.out1'), 'mark sent with Meta''s id');
select ok(core.update_delivery_status('wamid.out1', 'read'), 'status moves forward to read');
select ok(not core.update_delivery_status('wamid.out1', 'delivered'), 'a late "delivered" does not move status back');
select ok(not core.update_delivery_status('wamid.out1', 'failed', 'x'), '"failed" after read is ignored');
select is((select delivery_status from core.messages where id = t.id('o1')), 'read', 'final status is read');

select ok(core.mark_message_processed(t.id('m1')), 'inbound marked processed');
select ok(not core.mark_message_processed(t.id('m1')), 'processing is marked only once');

-- =============================================================================
-- Conversation control
-- =============================================================================
select ok(core.set_conversation_status(t.id('c1'), 'handed_to_staff', 'patient_asked'), 'assistant hands over to staff');
select ok(not core.assistant_may_reply(t.id('c1')), 'assistant is silent after handover');
select throws_ok($$ select core.set_conversation_status(t.id('c1'), 'assistant') $$,
  '42501', null, 'assistant cannot take a conversation back');
select ok(core.set_conversation_status(t.id('c1'), 'escalated', 'emergency:bleeding'), 'assistant can escalate at any time');
select throws_ok($$ select core.set_conversation_status(t.id('c1'), 'handed_to_staff') $$,
  '42501', null, 'assistant cannot de-escalate');

reset role;
select set_config('request.jwt.claim.sub', 'aaaaaaaa-0000-0000-0000-000000000001', true);
set local role authenticated;
select ok(core.set_conversation_status(t.id('c1'), 'assistant'), 'staff return the conversation to the assistant');
select ok(core.set_conversation_status(t.id('c1'), 'closed'), 'staff close the conversation');
select throws_ok($$ update core.conversations set status = 'assistant' where id = t.id('c1') $$,
  '23514', null, 'a closed conversation cannot be reopened');
select throws_ok(
  $$ insert into core.messages (clinic_id, patient_id, conversation_id, direction, source, kind, body, wa_message_id)
     values ('11111111-0000-0000-0000-00000000000a', t.id('p1'), t.id('c1'), 'in', 'patient', 'text', 'fake', 'wamid.fake') $$,
  '42501', null, 'staff cannot forge an inbound patient message');
select is((select delivery_status from core.queue_outbound_message(t.id('p1'), 'staff', 'text', 'Salam, Dr. One sizə yazacaq')),
  'pending', 'staff can queue a reply');

reset role;
set local role dentpilot_agent;
select isnt((select conversation_id from core.record_inbound_message('wamid.3', '994501112233', 'text', 'Yenə salam')),
  t.id('c1'), 'a message after closing opens a new conversation');

-- =============================================================================
-- Flow tokens
-- =============================================================================
select set_config('t.tok', core.issue_flow_token(t.id('p1'), 'az'), true);
select ok(t.txt('tok') ~ '^[0-9a-f]{64}$', 'flow token is 64 random hex characters');
select set_config('app.clinic_id', '', true);
select is(core.clinic_for_flow_token(t.txt('tok')), '11111111-0000-0000-0000-00000000000a'::uuid,
  'Flow endpoint resolves the clinic from the token alone');
select set_config('app.clinic_id', '11111111-0000-0000-0000-00000000000a', true);
select results_eq($$ select patient_id, purpose from core.read_flow_token(t.txt('tok')) $$,
  $$ values (t.id('p1'), 'book') $$, 'token gives back patient and purpose');
select throws_ok($$ select core.issue_flow_token(t.id('p1'), 'az', 'reschedule') $$,
  '23514', null, 'a reschedule token must name the appointment');

-- =============================================================================
-- Change cutoff (4 h default)
-- =============================================================================
reset role;
insert into core.appointments (id, clinic_id, patient_id, professional_id, service_id, start_at, end_at, blocked_until) values
  ('11111111-0000-0000-0000-0000000000a1', '11111111-0000-0000-0000-00000000000a', t.id('p1'), '11111111-0000-0000-0000-0000000000d1',
   '11111111-0000-0000-0000-0000000000e1', now() + interval '2 hours', now() + interval '150 minutes', now() + interval '150 minutes'),
  ('11111111-0000-0000-0000-0000000000a2', '11111111-0000-0000-0000-00000000000a', t.id('p1'), '11111111-0000-0000-0000-0000000000d1',
   '11111111-0000-0000-0000-0000000000e1', now() + interval '2 days',  now() + interval '2 days 30 minutes', now() + interval '2 days 30 minutes');
set local role dentpilot_agent;

select ok(not core.patient_can_change('11111111-0000-0000-0000-0000000000a1'), 'appointment in 2 h: patient can no longer change it');
select throws_ok($$ select core.cancel_appointment('11111111-0000-0000-0000-0000000000a1', t.id('p1'), 1) $$,
  'DP001', null, 'assistant cancel inside the cutoff fails with DP001');
select throws_ok($$ update core.appointments set status = 'no_show' where id = '11111111-0000-0000-0000-0000000000a2' $$,
  '42501', null, 'assistant may not set statuses other than confirmed/cancelled');
select ok(core.cancel_appointment('11111111-0000-0000-0000-0000000000a2', t.id('p1'), 1), 'assistant cancel outside the cutoff works');

reset role;
update core.clinics set patient_change_cutoff_minutes = 60 where id = '11111111-0000-0000-0000-00000000000a';
set local role dentpilot_agent;
select ok(core.patient_can_change('11111111-0000-0000-0000-0000000000a1'), 'cutoff is a setting: at 60 min the 2-h appointment is changeable');

-- =============================================================================
-- Isolation and privacy
-- =============================================================================
select set_config('app.clinic_id', '22222222-0000-0000-0000-00000000000b', true);
select core.record_inbound_message('wamid.b1', '994509999999', 'text', 'Clinic B secret');
select set_config('app.clinic_id', '11111111-0000-0000-0000-00000000000a', true);
select is((select count(*)::int from core.messages where body = 'Clinic B secret'), 0,
  'assistant for clinic A cannot see clinic B messages');
select throws_ok($$ delete from core.messages where id = t.id('m1') $$, '42501', null, 'assistant cannot delete messages');

reset role;
select is((select count(*)::int from ops.audit_events where entity = 'core.messages'), 0,
  'message text never enters the audit trail');

-- Retention: 200-day-old message is purged, 100-day-old one is kept (180-day default).
insert into core.messages (clinic_id, patient_id, conversation_id, direction, source, kind, body, wa_message_id, created_at)
select '11111111-0000-0000-0000-00000000000a', t.id('p1'), t.id('c1'), 'in', 'patient', 'text', v.body, v.wamid, now() - v.age
  from (values ('old body', 'wamid.old', interval '200 days'), ('recent body', 'wamid.recent', interval '100 days')) v(body, wamid, age);

set local role service_role;
select is(core.purge_message_bodies(), 1, 'retention purge erases only messages past 180 days');
reset role;
select results_eq(
  $$ select body, body_purged_at is not null from core.messages where wa_message_id in ('wamid.old', 'wamid.recent') order by wa_message_id $$,
  $$ values (null::text, true), ('recent body', false) $$,
  'purged row keeps its metadata; recent row is untouched');

select * from finish();
rollback;

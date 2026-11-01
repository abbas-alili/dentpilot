-- =============================================================================
-- Stage 6 tests — permanent hand-over + idle close (A7), shared-patient
-- treatment visibility (A11), FAQ knowledge base, iPhone calendar feed.
-- Runs in one transaction (now() is frozen) and is rolled back.
-- =============================================================================
begin;
create extension if not exists pgtap;

select plan(35);

-- -----------------------------------------------------------------------------
-- Helpers and fixtures
-- -----------------------------------------------------------------------------
create schema t;
create function t.id(p_key text) returns uuid language sql stable as
  $$ select nullif(current_setting('t.' || p_key, true), '')::uuid $$;
create function t.txt(p_key text) returns text language sql stable as
  $$ select nullif(current_setting('t.' || p_key, true), '') $$;
create function t.as_staff(p_user uuid) returns void language sql as
  $$ select set_config('request.jwt.claim.sub', p_user::text, true) $$;
grant usage on schema t to dentpilot_agent, authenticated;
grant execute on all functions in schema t to dentpilot_agent, authenticated;

insert into core.clinics (id, name) values ('11111111-0000-0000-0000-00000000000a', 'Clinic A');
insert into core.professionals (id, clinic_id, display_name) values
  ('11111111-0000-0000-0000-0000000000d1', '11111111-0000-0000-0000-00000000000a', 'Dr One'),
  ('11111111-0000-0000-0000-0000000000d2', '11111111-0000-0000-0000-00000000000a', 'Dr Two');
insert into core.services (id, clinic_id, code, name_az, name_ru, duration_minutes, buffer_minutes) values
  ('11111111-0000-0000-0000-0000000000e1', '11111111-0000-0000-0000-00000000000a', 'svc_exam', 'Müayinə', 'Осмотр', 30, 15);
insert into core.patients (id, clinic_id, wa_id, display_name) values
  ('11111111-0000-0000-0000-0000000000f1', '11111111-0000-0000-0000-00000000000a', '994500000001', 'Leyla Məmmədova'),
  ('11111111-0000-0000-0000-0000000000f2', '11111111-0000-0000-0000-00000000000a', '994500000002', null),
  ('11111111-0000-0000-0000-0000000000f3', '11111111-0000-0000-0000-00000000000a', '994500000003', 'Orxan');

insert into auth.users (id) values
  ('dddddddd-0000-0000-0000-000000000001'), ('dddddddd-0000-0000-0000-000000000002'),
  ('cccccccc-0000-0000-0000-000000000001'), ('aaaaaaaa-0000-0000-0000-000000000001');
insert into ops.staff (user_id, clinic_id, role, professional_id) values
  ('dddddddd-0000-0000-0000-000000000001', '11111111-0000-0000-0000-00000000000a', 'dentist',      '11111111-0000-0000-0000-0000000000d1'),
  ('dddddddd-0000-0000-0000-000000000002', '11111111-0000-0000-0000-00000000000a', 'dentist',      '11111111-0000-0000-0000-0000000000d2'),
  ('cccccccc-0000-0000-0000-000000000001', '11111111-0000-0000-0000-00000000000a', 'receptionist', null),
  ('aaaaaaaa-0000-0000-0000-000000000001', '11111111-0000-0000-0000-00000000000a', 'admin',        null);

create function t.book(p_patient uuid, p_dentist uuid, p_in interval, p_status text default 'booked') returns uuid language sql as $$
  insert into core.appointments (clinic_id, patient_id, professional_id, service_id, start_at, end_at, blocked_until, status)
  values ('11111111-0000-0000-0000-00000000000a', p_patient, p_dentist, '11111111-0000-0000-0000-0000000000e1',
          now() + p_in, now() + p_in + interval '30 minutes', now() + p_in + interval '45 minutes', p_status)
  returning id
$$;

-- =============================================================================
-- A7 — a human reply hands the conversation over, idle conversations close
-- =============================================================================
select hasnt_column('core', 'clinics', 'echo_pause_minutes', 'the old echo-pause setting is gone');

set local role dentpilot_agent;
select set_config('app.clinic_id', '11111111-0000-0000-0000-00000000000a', true);
select set_config('app.actor', 'assistant', true);

select set_config('t.c1', (select conversation_id::text from core.record_inbound_message('wamid.1', '994500000001', 'text', 'Salam')), true);
select ok(core.assistant_may_reply(t.id('c1')), 'assistant answers a new conversation');
select core.record_echo_message('wamid.echo1', '994500000001', 'text', 'Salam, Dr. One');
select results_eq($$ select status, status_reason from core.conversations where id = t.id('c1') $$,
  $$ values ('handed_to_staff', 'doctor_reply') $$, 'a dentist reply hands the conversation to staff');
select ok(not core.assistant_may_reply(t.id('c1')), 'the assistant stays silent afterwards (no time limit)');
reset role;
select is((select count(*)::int from ops.staff_notifications where conversation_id = t.id('c1')), 0,
  'no staff notification for a hand-over a dentist caused themself');

set local role dentpilot_agent;
select set_config('t.c3', (select conversation_id::text from core.record_inbound_message('wamid.3', '994500000003', 'text', 'Ağrı var')), true);
select core.set_conversation_status(t.id('c3'), 'escalated', 'emergency:pain');
select core.record_echo_message('wamid.echo3', '994500000003', 'text', 'Gəlin');
select is((select status from core.conversations where id = t.id('c3')), 'escalated', 'an escalated conversation stays escalated after a reply');
reset role;

select t.as_staff('cccccccc-0000-0000-0000-000000000001');
set local role authenticated;
select core.set_conversation_status(t.id('c1'), 'assistant');
select core.queue_outbound_message('11111111-0000-0000-0000-0000000000f1', 'staff', 'text', 'Sabah gəlin');
select is((select status_reason from core.conversations where id = t.id('c1')), 'staff_reply',
  'a staff reply from the web app also hands over');
reset role;

update core.conversations set last_message_at = now() - interval '25 hours' where id in (t.id('c1'), t.id('c3'));
select is(ops.close_idle_conversations(), 1, 'idle close closes one conversation…');
select results_eq($$ select status from core.conversations where id in (t.id('c1'), t.id('c3')) order by status $$,
  $$ values ('closed'), ('escalated') $$, '…the handed-over one; escalated conversations never auto-close');

set local role dentpilot_agent;
-- (two statements: a STABLE function can't see rows inserted earlier in the same statement)
select set_config('t.c4', (select conversation_id::text from core.record_inbound_message('wamid.4', '994500000001', 'text', 'Yenə mən')), true);
select ok(core.assistant_may_reply(t.id('c4')), 'the patient''s next message starts fresh with the assistant');
reset role;

update core.clinics set conversation_idle_close_hours = 48;
update core.conversations set status = 'assistant' where id = t.id('c3');
update core.conversations set last_message_at = now() - interval '25 hours' where id = t.id('c3');
select is(ops.close_idle_conversations(), 0, 'idle period is a setting (48 h keeps a 25-h-old conversation open)');

-- =============================================================================
-- A11 — dentists read all records of their patients, write only their own
-- =============================================================================
select t.book('11111111-0000-0000-0000-0000000000f1', '11111111-0000-0000-0000-0000000000d2', interval '2 days');            -- Dr Two will see Leyla
select t.book('11111111-0000-0000-0000-0000000000f3', '11111111-0000-0000-0000-0000000000d2', interval '3 days', 'cancelled'); -- cancelled: Orxan is not his

insert into clinical.price_list (id, clinic_id, code, name, price_azn) values
  ('11111111-0000-0000-0000-0000000000b1', '11111111-0000-0000-0000-00000000000a', 'exam', 'Müayinə', 20);
insert into clinical.treatment_records (id, clinic_id, patient_id, professional_id, treated_on) values
  ('11111111-0000-0000-0000-0000000000c1', '11111111-0000-0000-0000-00000000000a', '11111111-0000-0000-0000-0000000000f1', '11111111-0000-0000-0000-0000000000d1', current_date),
  ('11111111-0000-0000-0000-0000000000c3', '11111111-0000-0000-0000-00000000000a', '11111111-0000-0000-0000-0000000000f3', '11111111-0000-0000-0000-0000000000d1', current_date);
insert into clinical.treatment_line_items (clinic_id, treatment_id, price_list_id) values
  ('11111111-0000-0000-0000-00000000000a', '11111111-0000-0000-0000-0000000000c1', '11111111-0000-0000-0000-0000000000b1');

select t.as_staff('dddddddd-0000-0000-0000-000000000002');
set local role authenticated;
select results_eq($$ select id from clinical.treatment_records $$,
  $$ values ('11111111-0000-0000-0000-0000000000c1'::uuid) $$,
  'Dr Two reads Dr One''s record of a shared patient, not of a patient he only had a cancelled booking with');
select is((select count(*)::int from clinical.treatment_line_items), 1, 'Dr Two reads its line items');
select is((select total from clinical.treatment_totals), 20.00::numeric(10,2), '…and its total');

update clinical.treatment_records set notes = 'edited by Dr Two' where id = '11111111-0000-0000-0000-0000000000c1';
reset role;
select is((select notes from clinical.treatment_records where id = '11111111-0000-0000-0000-0000000000c1'), null,
  'Dr Two cannot edit Dr One''s record');
set local role authenticated;
select throws_ok($$ insert into clinical.treatment_line_items (clinic_id, treatment_id, price_list_id)
                    values ('11111111-0000-0000-0000-00000000000a', '11111111-0000-0000-0000-0000000000c1',
                            '11111111-0000-0000-0000-0000000000b1') $$,
  '42501', null, 'Dr Two cannot add lines to Dr One''s record');
reset role;

-- =============================================================================
-- FAQ knowledge base (Q14: all staff approve)
-- =============================================================================
select t.as_staff('dddddddd-0000-0000-0000-000000000001');
set local role authenticated;
insert into core.kb_entries (id, clinic_id, language, topic, question, answer) values
  ('11111111-0000-0000-0000-0000000000a9', '11111111-0000-0000-0000-00000000000a', 'az', 'hours',
   'İş saatlarınız?', 'Bazar ertəsi–Şənbə, 10:00–19:00.'),
  ('11111111-0000-0000-0000-0000000000aa', '11111111-0000-0000-0000-00000000000a', 'ru', 'hours',
   'Часы работы?', 'Пн–Сб, 10:00–19:00.');
reset role;

set local role dentpilot_agent;
select is((select count(*)::int from core.kb_for_prompt('az')), 0, 'an unapproved entry is invisible to the assistant');
reset role;

set local role authenticated;
select ok(core.approve_kb_entry('11111111-0000-0000-0000-0000000000a9', 1), 'a dentist approves an entry');
select ok(not core.approve_kb_entry('11111111-0000-0000-0000-0000000000aa', 9), 'approval needs the version that was reviewed');
reset role;
select is((select approved_by from core.kb_entries where id = '11111111-0000-0000-0000-0000000000a9'),
  'dddddddd-0000-0000-0000-000000000001'::uuid, 'approval records who approved');

set local role dentpilot_agent;
select results_eq($$ select answer from core.kb_for_prompt('az') $$,
  $$ values ('Bazar ertəsi–Şənbə, 10:00–19:00.') $$, 'the assistant gets approved entries in the patient''s language only');
select throws_ok($$ update core.kb_entries set answer = 'x' $$, '42501', null, 'the assistant cannot edit the knowledge base');
reset role;

select t.as_staff('cccccccc-0000-0000-0000-000000000001');
set local role authenticated;
update core.kb_entries set answer = 'Bazar ertəsi–Cümə, 09:00–18:00.' where id = '11111111-0000-0000-0000-0000000000a9';
reset role;
select is((select approved_at from core.kb_entries where id = '11111111-0000-0000-0000-0000000000a9'), null,
  'editing an approved answer withdraws its approval');
set local role dentpilot_agent;
select is((select count(*)::int from core.kb_entries), 0, 'the edited, unapproved text never reaches the assistant');
reset role;

select throws_ok($$ insert into core.kb_entries (clinic_id, language, topic, question, answer)
                    values ('11111111-0000-0000-0000-00000000000a', 'az', 'diagnosis', 'q', 'a') $$,
  '23514', null, 'unknown topics are rejected');

-- =============================================================================
-- Calendar feed (Q13: first name + service)
-- =============================================================================
select set_config('t.a1', (select id::text from core.appointments where professional_id = '11111111-0000-0000-0000-0000000000d2' and status = 'booked'), true);
select t.book('11111111-0000-0000-0000-0000000000f2', '11111111-0000-0000-0000-0000000000d2', interval '1 day', 'pending_approval');
select t.book('11111111-0000-0000-0000-0000000000f3', '11111111-0000-0000-0000-0000000000d2', interval '90 days');
select t.book('11111111-0000-0000-0000-0000000000f3', '11111111-0000-0000-0000-0000000000d1', interval '1 day');

select t.as_staff('dddddddd-0000-0000-0000-000000000002');
set local role authenticated;
select set_config('t.tok', ops.create_calendar_feed('11111111-0000-0000-0000-0000000000d2'), true);
select ok(t.txt('tok') ~ '^[0-9a-f]{64}$', 'a dentist creates their own feed and gets a 64-hex token once');
select throws_ok($$ select ops.create_calendar_feed('11111111-0000-0000-0000-0000000000d1') $$,
  '42501', null, 'a dentist cannot create a feed for another dentist');
reset role;
select ok(not exists (select 1 from ops.calendar_feeds where token_sha256 = t.txt('tok')),
  'only the token''s hash is stored');

select t.as_staff('aaaaaaaa-0000-0000-0000-000000000001');
set local role authenticated;
select lives_ok($$ select ops.create_calendar_feed('11111111-0000-0000-0000-0000000000d1') $$,
  'an admin can create a feed for any dentist');
reset role;

set local role dentpilot_agent;
select results_eq(
  $$ select summary, tentative from core.calendar_feed_events(t.txt('tok')) order by starts_at $$,
  $$ values ('Müayinə'::text, true), ('Leyla — Müayinə', false) $$,
  'feed: this dentist''s active bookings in the next 60 days; first name + service; pending = tentative');
select ok((select bool_and(ends_at = starts_at + interval '30 minutes') from core.calendar_feed_events(t.txt('tok'))),
  'events end at chair time (the cleanup buffer is not shown)');
select is((select count(*)::int from core.calendar_feed_events('not-a-token')), 0, 'an unknown token returns nothing');
select throws_ok($$ select * from ops.calendar_feeds $$, '42501', null, 'the assistant cannot read the feed table');
reset role;

select t.as_staff('dddddddd-0000-0000-0000-000000000002');
set local role authenticated;
select ok(ops.revoke_calendar_feed((select id from ops.calendar_feeds
                                     where professional_id = '11111111-0000-0000-0000-0000000000d2')),
  'a dentist revokes their feed');
reset role;
set local role dentpilot_agent;
select is((select count(*)::int from core.calendar_feed_events(t.txt('tok'))), 0, 'a revoked feed returns nothing');
reset role;

select * from finish();
rollback;

-- =============================================================================
-- Stage 4 tests — job queue, reminders, approval flow, staff notifications,
-- web push bookkeeping, reconciler, settings.
-- Runs in one transaction (now() is frozen) and is rolled back.
-- =============================================================================
begin;
create extension if not exists pgtap;

select plan(41);

-- -----------------------------------------------------------------------------
-- Helpers and fixtures
-- -----------------------------------------------------------------------------
create schema t;
create function t.id(p_key text) returns uuid language sql stable as
  $$ select nullif(current_setting('t.' || p_key, true), '')::uuid $$;
grant usage on schema t to dentpilot_agent, authenticated;
grant execute on all functions in schema t to dentpilot_agent, authenticated;

-- Jobs for one appointment, as "kind:status" sorted — handy for assertions.
create function t.jobs_for(p_appointment uuid) returns text[] language sql stable as $$
  select coalesce(array_agg(kind || ':' || status order by kind, status, run_after), '{}')
    from ops.background_jobs where payload ->> 'appointment_id' = p_appointment::text
$$;

insert into core.clinics (id, name) values ('11111111-0000-0000-0000-00000000000a', 'Clinic A');
insert into core.professionals (id, clinic_id, display_name) values
  ('11111111-0000-0000-0000-0000000000d1', '11111111-0000-0000-0000-00000000000a', 'Dr One');
insert into core.services (id, clinic_id, code, name_az, name_ru, duration_minutes) values
  ('11111111-0000-0000-0000-0000000000e1', '11111111-0000-0000-0000-00000000000a', 'svc_exam', 'Müayinə', 'Осмотр', 30);
insert into core.patients (id, clinic_id, wa_id, preferred_language) values
  ('11111111-0000-0000-0000-0000000000f1', '11111111-0000-0000-0000-00000000000a', '994500000001', 'ru');
insert into auth.users (id) values
  ('aaaaaaaa-0000-0000-0000-000000000001'),    -- receptionist
  ('aaaaaaaa-0000-0000-0000-000000000002');    -- admin
insert into ops.staff (user_id, clinic_id, role) values
  ('aaaaaaaa-0000-0000-0000-000000000001', '11111111-0000-0000-0000-00000000000a', 'receptionist'),
  ('aaaaaaaa-0000-0000-0000-000000000002', '11111111-0000-0000-0000-00000000000a', 'admin');

-- Appointment helper: insert at now() + p_in, return id.
create function t.book(p_in interval, p_status text default 'booked') returns uuid language sql as $$
  insert into core.appointments (clinic_id, patient_id, professional_id, service_id, start_at, end_at, blocked_until, status)
  values ('11111111-0000-0000-0000-00000000000a', '11111111-0000-0000-0000-0000000000f1',
          '11111111-0000-0000-0000-0000000000d1', '11111111-0000-0000-0000-0000000000e1',
          now() + p_in, now() + p_in + interval '30 minutes', now() + p_in + interval '30 minutes', p_status)
  returning id
$$;

-- =============================================================================
-- Job queue
-- =============================================================================
select set_config('t.j1', ops.enqueue_job('process_message', null, '{"message_id":"x"}', 'test:1')::text, true);
select is(ops.enqueue_job('process_message', null, '{}', 'test:1'), t.id('j1'), 'same idempotency key ⇒ same job');
select ops.enqueue_job('process_message', null, '{}', 'test:future', now() + interval '1 hour');

set local role dentpilot_agent;
select results_eq($$ select id from ops.claim_jobs(array['process_message'], 10, 'w1') $$,
  $$ values (t.id('j1')) $$, 'claim returns due jobs only (future job left alone)');
select is((select count(*)::int from ops.claim_jobs(array['process_message'], 10, 'w2')), 0,
  'a claimed job is not handed to a second worker');
select is(ops.fail_job(t.id('j1'), 'timeout'), 'pending', 'a failed job goes back to pending');
reset role;
select ok((select run_after > now() and attempts = 1 from ops.background_jobs where id = t.id('j1')),
  'failure applies backoff and counts the attempt');

update ops.background_jobs set run_after = now(), attempts = 4, max_attempts = 5 where id = t.id('j1');
set local role dentpilot_agent;
select ops.claim_jobs(array['process_message'], 10, 'w1');
select is(ops.fail_job(t.id('j1'), 'still failing'), 'dead', 'after the last attempt the job is dead');

reset role;
select set_config('t.j2', ops.enqueue_job('process_message', null, '{}', 'test:2')::text, true);
update ops.background_jobs set status = 'running', locked_at = now() - interval '15 minutes', attempts = 1 where id = t.id('j2');
set local role dentpilot_agent;
select is((select id from ops.claim_jobs(array['process_message'], 10, 'w3')), t.id('j2'),
  'a job whose worker died (lease expired) is claimed again');
select ok(ops.complete_job(t.id('j2')), 'complete a running job');
select throws_ok($$ select * from ops.background_jobs $$, '42501', null,
  'the agent has no direct access to the job table');

-- =============================================================================
-- Reminders (default: one, 24 h before)
-- =============================================================================
reset role;
select set_config('t.a1', t.book(interval '3 days')::text, true);
select is(t.jobs_for(t.id('a1')), array['send_reminder:pending'], 'booking creates one reminder job');
select is((select run_after from ops.background_jobs where payload ->> 'appointment_id' = t.id('a1')::text),
  now() + interval '2 days', 'reminder is due 24 h before the appointment');

update core.appointments set status = 'confirmed' where id = t.id('a1');
select is(t.jobs_for(t.id('a1')), array['send_reminder:pending'], 'confirming does not duplicate the reminder');

update core.appointments set start_at = start_at + interval '1 day',
                             end_at = end_at + interval '1 day',
                             blocked_until = blocked_until + interval '1 day'
 where id = t.id('a1');
select is(t.jobs_for(t.id('a1')), array['send_reminder:cancelled', 'send_reminder:pending'],
  'moving the appointment cancels the old reminder and creates a new one');

update core.appointments set status = 'cancelled' where id = t.id('a1');
select is(t.jobs_for(t.id('a1')), array['send_reminder:cancelled', 'send_reminder:cancelled'],
  'cancelling the appointment cancels its reminders');

select set_config('t.a2', t.book(interval '3 hours')::text, true);
select is(t.jobs_for(t.id('a2')), '{}'::text[], 'a 24-h reminder that would already be past is skipped');

update core.clinics set reminder_offsets_minutes = '{1440,120}' where id = '11111111-0000-0000-0000-00000000000a';
select set_config('t.a3', t.book(interval '5 days')::text, true);
select is(t.jobs_for(t.id('a3')), array['send_reminder:pending', 'send_reminder:pending'],
  'reminder times are a setting: 24 h + 2 h gives two jobs');

select throws_ok($$ update core.clinics set reminder_offsets_minutes = '{10}' $$, '23514', null,
  'reminder offsets below 30 minutes are rejected');
select throws_ok($$ update core.clinics set reminder_offsets_minutes = '{60,120,240,480}' $$, '23514', null,
  'more than three reminder times are rejected');

-- =============================================================================
-- Approval flow
-- =============================================================================
select set_config('t.p1', t.book(interval '4 days', 'pending_approval')::text, true);
select is(t.jobs_for(t.id('p1')), array['approval_reminder:pending'],
  'pending booking: approval reminder scheduled, no patient reminders yet');
select is((select run_after from ops.background_jobs where idempotency_key = 'approval_reminder:' || t.id('p1')),
  now() + interval '2 hours', 'approval reminder is due after 2 h');
select is((select count(*)::int from ops.staff_notifications where appointment_id = t.id('p1') and kind = 'pending_approval'), 2,
  'every staff member is notified of the new pending booking');
select is((select count(*)::int from ops.background_jobs where kind = 'push_notification'
              and (payload ->> 'notification_id')::uuid in (select id from ops.staff_notifications where appointment_id = t.id('p1'))), 2,
  'each notification gets a push job');

select set_config('t.r1', (select id::text from ops.background_jobs where idempotency_key = 'approval_reminder:' || t.id('p1')), true);
set local role dentpilot_agent;
select ok(ops.run_approval_reminder(t.id('r1')),
  'still pending after 2 h ⇒ staff reminded');
reset role;
select is((select count(*)::int from ops.staff_notifications where appointment_id = t.id('p1') and kind = 'approval_reminder'), 2,
  'approval reminder reaches every staff member');

update core.appointments set status = 'booked' where id = t.id('p1');
select is(t.jobs_for(t.id('p1')), array['approval_reminder:cancelled', 'notify_patient:pending', 'send_reminder:pending', 'send_reminder:pending'],
  'approval: approval reminder cancelled, patient told, reminders start');
select is((select payload ->> 'event' from ops.background_jobs where kind = 'notify_patient' and payload ->> 'appointment_id' = t.id('p1')::text),
  'approved', 'patient message says approved');

select set_config('t.p2', t.book(interval '6 days', 'pending_approval')::text, true);
update core.appointments set status = 'rejected' where id = t.id('p2');
select is(t.jobs_for(t.id('p2')), array['approval_reminder:cancelled', 'notify_patient:pending'],
  'rejection: approval reminder cancelled, patient told');

select set_config('t.r2', (select id::text from ops.background_jobs where idempotency_key = 'approval_reminder:' || t.id('p2')), true);
set local role dentpilot_agent;
select ok(not ops.run_approval_reminder(t.id('r2')),
  'an approval reminder for a decided booking does nothing');
reset role;

update core.clinics set approval_reminder_minutes = 0 where id = '11111111-0000-0000-0000-00000000000a';
select set_config('t.p3', t.book(interval '7 days', 'pending_approval')::text, true);
select is(t.jobs_for(t.id('p3')), '{}'::text[], 'approval reminder can be switched off (0)');

-- =============================================================================
-- Patient-facing helpers (assistant role)
-- =============================================================================
set local role dentpilot_agent;
select set_config('app.clinic_id', '11111111-0000-0000-0000-00000000000a', true);
select results_eq(
  $$ select service_name, language, opted_out from core.appointment_message_details(t.id('a3')) $$,
  $$ values ('Осмотр', 'ru', false) $$, 'message details come in the patient''s language');
select ok(core.confirm_attendance(t.id('a3'), '11111111-0000-0000-0000-0000000000f1'), 'patient confirms attendance from a reminder');
select ok(core.set_reminder_opt_out('11111111-0000-0000-0000-0000000000f1', true), 'patient opts out of reminders');
select is((select opted_out from core.appointment_message_details(t.id('a3'))), true, 'worker sees the opt-out and skips sending');

-- =============================================================================
-- Escalation notifications and the staff inbox
-- =============================================================================
select set_config('t.c1', (select conversation_id from core.record_inbound_message('wamid.e1', '994500000001', 'text', 'qan gəlir'))::text, true);
select core.set_conversation_status(t.id('c1'), 'escalated', 'emergency:bleeding');
reset role;
select results_eq(
  $$ select count(*)::int, min(detail) from ops.staff_notifications where conversation_id = t.id('c1') and kind = 'escalation' $$,
  $$ values (2, 'emergency:bleeding') $$, 'escalation notifies all staff with the reason code (no message text)');

select set_config('request.jwt.claim.sub', 'aaaaaaaa-0000-0000-0000-000000000001', true);
set local role authenticated;
select ok((select bool_and(user_id = 'aaaaaaaa-0000-0000-0000-000000000001') from ops.staff_notifications),
  'staff see only their own notifications');
select is(ops.mark_notifications_read(array(select id from ops.staff_notifications where conversation_id = t.id('c1'))), 1,
  'staff mark their notification read');

select set_config('t.s1', ops.register_push_subscription('https://push.example/abc', 'key', 'auth', 'iPhone Safari')::text, true);
select is((select count(*)::int from ops.push_subscriptions), 1, 'staff register this device for push');
reset role;

select set_config('t.n1', (select id::text from ops.staff_notifications
                             where user_id = 'aaaaaaaa-0000-0000-0000-000000000001' and conversation_id = t.id('c1')), true);
set local role dentpilot_agent;
select is((select count(*)::int from ops.push_targets(t.id('n1'))), 1,
  'push worker finds the device for the notification');
select ops.record_push_result(t.id('s1'), false, true);
reset role;
select ok((select disabled_at is not null from ops.push_subscriptions where id = t.id('s1')),
  'a gone subscription (404/410) is disabled');

-- =============================================================================
-- Reconciler
-- =============================================================================
insert into core.messages (clinic_id, patient_id, conversation_id, direction, source, kind, body, wa_message_id, created_at)
values ('11111111-0000-0000-0000-00000000000a', '11111111-0000-0000-0000-0000000000f1', t.id('c1'),
        'in', 'patient', 'text', 'lost', 'wamid.lost', now() - interval '5 minutes');
select ok(ops.enqueue_stale_messages() >= 1, 'unprocessed inbound messages are re-queued');
select is(ops.enqueue_stale_messages(), 0, 'running the reconciler again queues nothing new');

select * from finish();
rollback;

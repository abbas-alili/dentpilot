-- =============================================================================
-- Edge support tests — processing claim and resend after failure.
-- =============================================================================
begin;
create extension if not exists pgtap;

select plan(9);

create schema t;
create function t.id(p_key text) returns uuid language sql stable as
  $$ select nullif(current_setting('t.' || p_key, true), '')::uuid $$;
grant usage on schema t to dentpilot_agent;
grant execute on all functions in schema t to dentpilot_agent;

insert into core.clinics (id, name, shadow_mode) values ('11111111-0000-0000-0000-00000000000a', 'Clinic A', false);

set local role dentpilot_agent;
select set_config('app.clinic_id', '11111111-0000-0000-0000-00000000000a', true);
select set_config('t.m1', (select message_id::text from core.record_inbound_message('wamid.1', '994500000001', 'text', 'Salam')), true);

select ok(core.claim_message_for_processing(t.id('m1')), 'first worker claims the message');
select ok(not core.claim_message_for_processing(t.id('m1')), 'a second worker is refused while the lease is held');
select is(core.mark_message_attempt_failed(t.id('m1')), 1, 'a failed attempt releases the lease (attempt counted once)');
select ok(core.claim_message_for_processing(t.id('m1')), 'after release it can be claimed again');
select ok(core.mark_message_processed(t.id('m1')), 'finish processing');
select ok(not core.claim_message_for_processing(t.id('m1')), 'a processed message cannot be claimed');

reset role;
-- An old message under a fresh lease is not re-queued by the reconciler.
insert into core.messages (clinic_id, patient_id, conversation_id, direction, source, kind, body, wa_message_id, created_at, processing_started_at)
select clinic_id, patient_id, conversation_id, 'in', 'patient', 'text', 'x', 'wamid.busy', now() - interval '5 minutes', now()
  from core.messages where id = t.id('m1');
select is(ops.enqueue_stale_messages(), 0, 'the reconciler skips a message that is being processed');

set local role dentpilot_agent;
select set_config('t.o1', (select message_id::text from core.queue_outbound_message(
  (select patient_id from core.messages where id = t.id('m1')), 'assistant', 'text', 'Salam', p_send_key => 'k1')), true);
select ok(core.mark_outbound_failed(t.id('o1'), '131026 receiver incapable'), 'Meta rejects the send');
select ok(core.mark_outbound_sent(t.id('o1'), 'wamid.out1'), 'a retry after a definite failure can mark it sent');
reset role;

select * from finish();
rollback;
